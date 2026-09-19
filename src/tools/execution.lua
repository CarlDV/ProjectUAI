-- Bounded Luau execution. The wrapper captures output without replacing the
-- executor's globals; checkpoints are inserted only into executable loop bodies.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")
	local M = { DEFAULT_TIMEOUT = 10, MAX_TIMEOUT = 60 }
	local active = {}
	local OUTPUT_BYTES, OUTPUT_LINES = 16000, 120
	local STOP = {}

	local function pack(...)
		return { n = select("#", ...), ... }
	end

	local function clip(text, limit)
		text = tostring(text)
		if #text <= limit then return text, false end
		if limit <= 3 then return string.rep(".", math.max(0, limit)), true end
		local last = limit - 3
		while last > 0 do
			local byte = text:byte(last + 1)
			if not byte or byte < 128 or byte >= 192 then break end
			last = last - 1
		end
		return text:sub(1, last) .. "...", true
	end

	-- Skip literals and comments, including long brackets and nested interpolated
	-- strings. Inserting into a quoted example would change the program's data.
	local skipQuoted
	local function skipLong(code, at)
		local equals = code:match("^%[(=*)%[", at)
		if not equals then return nil end
		local _, finish = code:find("]" .. equals .. "]", at + #equals + 2, true)
		return finish and finish + 1 or #code + 1
	end
	local function skipComment(code, at)
		return skipLong(code, at + 2) or code:find("\n", at + 2, true) or #code + 1
	end
	local function skipExpression(code, at)
		local depth = 1
		while at <= #code do
			local char = code:sub(at, at)
			if char == "'" or char == '"' or char == "`" then
				at = skipQuoted(code, at)
			elseif code:sub(at, at + 1) == "--" then
				at = skipComment(code, at)
			elseif char == "[" and skipLong(code, at) then
				at = skipLong(code, at)
			elseif char == "{" then
				depth = depth + 1
				at = at + 1
			elseif char == "}" then
				depth = depth - 1
				at = at + 1
				if depth == 0 then return at end
			else
				at = at + 1
			end
		end
		return at
	end
	function skipQuoted(code, at)
		local quote = code:sub(at, at)
		at = at + 1
		while at <= #code do
			local char = code:sub(at, at)
			if char == "\\" then
				at = at + 2
			elseif char == quote then
				return at + 1
			elseif quote == "`" and char == "{" then
				at = skipExpression(code, at + 1)
			else
				at = at + 1
			end
		end
		return at
	end

	function M.instrument(code)
		local name = "__uai_checkpoint"
		while code:find(name, 1, true) do name = name .. "_" end
		local parts, at, copied = {}, 1, 1
		while at <= #code do
			local char = code:sub(at, at)
			if char == "'" or char == '"' or char == "`" then
				at = skipQuoted(code, at)
			elseif code:sub(at, at + 1) == "--" then
				at = skipComment(code, at)
			elseif char == "[" and skipLong(code, at) then
				at = skipLong(code, at)
			elseif char:match("[%a_]") then
				local _, last = code:find("^[%w_]+", at)
				local word = code:sub(at, last)
				if word == "do" or word == "repeat" then
					parts[#parts + 1] = code:sub(copied, last) .. " " .. name .. "();"
					copied = last + 1
				end
				at = last + 1
			else
				at = at + 1
			end
		end
		parts[#parts + 1] = code:sub(copied)
		return table.concat(parts), name
	end

	function M.timeout(args)
		local seconds = tonumber(args and args.timeout) or M.DEFAULT_TIMEOUT
		if seconds ~= seconds then seconds = M.DEFAULT_TIMEOUT end
		return util.clamp(seconds, 1, M.MAX_TIMEOUT)
	end

	local function compile(code)
		if not caps.fn.loadstring then return nil, caps.reason("exec") end
		local ok, fn, err = pcall(caps.fn.loadstring, code, "UAI run_luau")
		if not ok then return nil, tostring(fn) end
		return fn, err
	end

	function M.check(code)
		if util.trim(code) == "" then return { ok = false, text = "Nothing to compile." } end
		local fn, err = compile(code)
		if not fn then return { ok = false, text = "Compile error: " .. tostring(err) } end
		return { ok = true, text = "Luau compiled successfully. No code was executed." }
	end

	-- Tables are useful results, not the opaque "{table}" that used to reach the
	-- model. Bound both traversal and text, and never recurse through a cycle.
	local function display(value)
		local seen, visited, omitted = {}, 0, false
		local function bounded(text, limit)
			local value, cropped = clip(text, limit)
			omitted = omitted or cropped
			return value
		end
		local function show(item, depth)
			visited = visited + 1
			if visited > 128 then omitted = true; return "..." end
			if type(item) == "table" and typeof(item) == "table" then
				if seen[item] then return "<cycle>" end
				if depth >= 4 then omitted = true; return "{...}" end
				seen[item] = true
				local parts, count = {}, 0
				for key, child in pairs(item) do
					count = count + 1
					if count > 24 or visited > 128 then omitted = true; parts[#parts + 1] = "..."; break end
					parts[#parts + 1] = show(key, depth + 1) .. " = " .. show(child, depth + 1)
				end
				seen[item] = nil
				return "{" .. table.concat(parts, ", ") .. "}"
			end
			if type(item) == "string" then return bounded(item, depth == 0 and 2048 or 256) end
			local ok, text = pcall(H.show, item)
			return ok and bounded(text, 256) or "<unprintable value>"
		end
		local ok, text = pcall(show, value, 0)
		local result = ok and bounded(text, 4096) or "<unprintable value>"
		return result, omitted
	end

	local function cancel(thread)
		if thread and type(task.cancel) == "function" then
			local ok, result = pcall(task.cancel, thread)
			return ok and result ~= false
		end
		return false
	end

	env.require("runtime/dispose").add(function()
		for execution in pairs(active) do execution.stop("aborted") end
	end, "Luau executions")

	function M.run(args, ctx)
		local code = tostring(args.code or "")
		local checked = M.check(code)
		if not checked.ok then return checked end
		local patched, guard = M.instrument(code)
		-- Parameters provide capture and managed scheduling even on hosts where
		-- setfenv is absent. No extra leading newline: error line numbers stay useful.
		local factory, err = compile("return function(print, warn, task, wait, " .. guard .. ", ...) " .. patched .. "\nend")
		if not factory then return { ok = false, text = "Compile error: " .. tostring(err) } end
		local built, fn = pcall(factory)
		if not built then return { ok = false, text = "Compile error: " .. tostring(fn) } end

		local started, seconds = clock.ms(), M.timeout(args)
		local deadline = started + seconds * 1000
		local root, done, returns, failure, stopped
		local released = false
		local fullyCancelled = true
		local children, cancelled = {}, {}
		local logs, bytes, truncated = {}, 0, false
		local execution = {}
		function execution.stop(reason)
			stopped = stopped or reason
			if root and coroutine.status(root) ~= "dead" and not cancel(root) then fullyCancelled = false end
			for thread in pairs(children) do
				if coroutine.status(thread) ~= "dead" and not cancel(thread) then fullyCancelled = false end
			end
		end
		active[execution] = true

		local function check()
			-- A successful parent releases engine callbacks, but must never release
			-- a child whose host could only cancel it cooperatively.
			if cancelled[coroutine.running()] then error(STOP, 0) end
			if released then return end
			if not stopped and ctx and ctx.aborted and ctx.aborted() then stopped = "aborted" end
			if not stopped and clock.ms() >= deadline then stopped = "timeout" end
			if stopped or failure then error(STOP, 0) end
		end
		local function capture(prefix, ...)
			check()
			if released then return end
			if #logs >= OUTPUT_LINES or bytes >= OUTPUT_BYTES then truncated = true; return end
			local parts = { prefix }
			for index = 1, math.min(select("#", ...), 32) do
				local text, cropped = display((select(index, ...)))
				parts[#parts + 1] = text
				truncated = truncated or cropped
			end
			if select("#", ...) > 32 then parts[#parts + 1] = "..."; truncated = true end
			local line = table.concat(parts, "\t"):gsub("^\t", "")
			local bounded = clip(line, math.min(4096, OUTPUT_BYTES - bytes))
			if bounded ~= line then truncated = true end
			logs[#logs + 1] = bounded
			bytes = bytes + #bounded + 1
		end
		local function wait(secondsToWait)
			check()
			if released then return task.wait(secondsToWait) end
			local requested = math.max(tonumber(secondsToWait) or 0, 0)
			local elapsed = 0
			repeat
				elapsed = elapsed + (task.wait(math.min(math.max(requested - elapsed, 0), 0.1)) or 0)
				check()
			until elapsed >= requested
			return elapsed
		end
		local ticks, lastYield = 0, started
		local function checkpoint()
			if released then check(); return end
			ticks = ticks + 1
			if ticks % 128 ~= 0 then return end
			check()
			if ticks >= 8192 or clock.since(lastYield) >= 16 then
				wait()
				ticks, lastYield = 0, clock.ms()
			end
		end
		local function launch(kind, delay, callback, ...)
			check()
			-- A callback the script registered on an engine signal can fire after a
			-- successful call returned. It is outside this execution's lifetime; do
			-- not keep collecting it into a result that has already been delivered.
			if released then
				if kind == "delay" then return task.delay(delay, callback, ...) end
				return task[kind](callback, ...)
			end
			if type(callback) ~= "function" then error("managed task." .. kind .. " expects a function", 2) end
			local values = pack(...)
			local function work()
				local current = coroutine.running()
				if stopped or cancelled[current] then children[current] = nil; return end
				local ok, why = pcall(function()
					check()
					callback(unpack(values, 1, values.n))
				end)
				children[current] = nil
				if not ok and why ~= STOP then failure = display(why) end
			end
			local thread
			if kind == "delay" then thread = task.delay(delay, work)
			else thread = task[kind](work) end
			if coroutine.status(thread) ~= "dead" then children[thread] = true end
			return thread
		end
		local managed = setmetatable({
			wait = wait,
			spawn = function(callback, ...) return launch("spawn", nil, callback, ...) end,
			defer = function(callback, ...) return launch("defer", nil, callback, ...) end,
			delay = function(delay, callback, ...) return launch("delay", delay, callback, ...) end,
			cancel = function(thread)
				if released then return task.cancel(thread) end
				cancelled[thread] = true
				if not cancel(thread) then fullyCancelled = false end
				children[thread] = nil
				if thread == coroutine.running() then error(STOP, 0) end
			end,
		}, { __index = task })
		root = task.spawn(function()
			local result = pack(pcall(function()
				check()
				return fn(function(...) capture("", ...) end, function(...) capture("[warn]", ...) end,
					managed, wait, checkpoint)
			end))
			if result[1] then returns = result
			elseif result[2] ~= STOP then failure = display(result[2]) end
			done = true
		end)

		while not done or next(children) do
			if ctx and ctx.aborted and ctx.aborted() then stopped = "aborted" end
			if clock.ms() >= deadline then stopped = stopped or "timeout" end
			if stopped or failure then break end
			task.wait()
		end
		if stopped or failure then execution.stop(stopped or "error") end
		active[execution] = nil

		local output, status = {}, "completed"
		if stopped == "aborted" then
			status = "aborted"
			output[1] = "Stopped. Changes already made were not undone."
		elseif stopped == "timeout" then
			status = "timeout"
			output[1] = string.format("Timed out after %gs. Inspect any changes before retrying.", seconds)
		elseif failure then
			status = "runtime_error"
			output[1] = "Runtime error: " .. failure
		else
			output[1] = "Ran in " .. util.formatDuration(clock.since(started)) .. "."
			if returns and returns.n > 1 then
				local values = {}
				for index = 2, math.min(returns.n, 33) do
					local text, cropped = display(returns[index])
					values[#values + 1] = text
					truncated = truncated or cropped
				end
				if returns.n > 33 then values[#values + 1] = "..."; truncated = true end
				output[#output + 1] = "Returned: " .. table.concat(values, "\t")
			end
		end
		if stopped or not fullyCancelled then
			output[#output + 1] = fullyCancelled and "Managed Luau tasks were cancelled."
				or "Cooperative cancellation requested. This host cannot cancel every suspended task; code blocked outside managed waits may still resume. Do not retry the same code."
		end
		if #logs > 0 then output[#output + 1] = "Output:\n" .. table.concat(logs, "\n") end
		if truncated then output[#output + 1] = "(output truncated to the capture limit)" end
		released = status == "completed"
		return { ok = status == "completed", text = table.concat(output, "\n"),
			data = { status = status, ms = clock.since(started), outputTruncated = truncated } }
	end

	return M
end
