-- Running and reading Luau.
--
-- Execution is the most dangerous thing in the toolset and the least reviewable,
-- so it is marked accordingly and it is deliberately awkward: output is captured
-- rather than printed, the thread is abandoned on timeout rather than pretended
-- to be stopped, and the two loop forms that cannot yield are rewritten so the
-- client stays interruptible.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local EXEC_TIMEOUT = 10
	local LOG_CAP = 120

	return {
		{
			name = "run_luau",
			risk = "danger",
			needs = { "exec" },
			description = "Compile and run Luau on the local client. Returns anything printed plus the return value. Every loop must call task.wait() or the client freezes. Prefer a specific tool when one exists.",
			parameters = {
				type = "object",
				properties = {
					code = { type = "string", description = "The source to run. Use print() for output; return a value to report it." },
				},
				required = { "code" },
			},
			run = function(args, ctx)
				local code = tostring(args.code or "")
				if util.trim(code) == "" then return "Nothing to run." end

				-- A loop with no body cannot yield, so no timeout, thread or stop
				-- button can reach it -- the scheduler itself is blocked. These two
				-- forms have no legitimate use, so they get a yield. Loops with a real
				-- body are left alone: injecting a wait into one that already yields
				-- would silently halve its speed.
				local patched = code
					:gsub("while%s+true%s+do%s*end", "while true do task.wait() end")
					:gsub("repeat%s*until%s+false", "repeat task.wait() until false")

				local compile = caps.fn.loadstring
				local fn, compileErr = compile(patched)
				if not fn then return "Compile error: " .. tostring(compileErr) end

				local logs = {}
				local truncatedLogs = false
				local globals = (caps.fn.getgenv and caps.fn.getgenv()) or _G
				local sandbox = setmetatable({
					print = function(...)
						if #logs >= LOG_CAP then
							truncatedLogs = true
							return
						end
						local parts = {}
						for index = 1, select("#", ...) do
							parts[#parts + 1] = H.show((select(index, ...)))
						end
						logs[#logs + 1] = table.concat(parts, "\t")
					end,
					warn = function(...)
						if #logs >= LOG_CAP then
							truncatedLogs = true
							return
						end
						local parts = {}
						for index = 1, select("#", ...) do
							parts[#parts + 1] = H.show((select(index, ...)))
						end
						logs[#logs + 1] = "[warn] " .. table.concat(parts, "\t")
					end,
				}, { __index = globals, __newindex = globals })
				if setfenv then pcall(setfenv, fn, sandbox) end

				local started = clock.ms()
				local finished, ok, result = clock.timeout(EXEC_TIMEOUT, fn)

				local output = {}
				if not finished then
					output[#output + 1] = string.format(
						"Timed out after %ds and was left running in the background. It was not stopped -- Luau cannot kill a thread. Do not retry the same code; make it finish or yield.",
						EXEC_TIMEOUT)
				elseif not ok then
					output[#output + 1] = "Runtime error: " .. tostring(result)
				else
					output[#output + 1] = string.format("Ran in %s.", util.formatDuration(clock.since(started)))
					if result ~= nil then output[#output + 1] = "Returned: " .. H.show(result) end
				end

				if #logs > 0 then
					output[#output + 1] = "Output:\n" .. table.concat(logs, "\n")
					if truncatedLogs then
						output[#output + 1] = string.format("(output stopped after %d lines)", LOG_CAP)
					end
				end
				return table.concat(output, "\n")
			end,
		},
		{
			name = "script_list",
			risk = "read",
			description = "List script instances in the place, with their paths. Useful for finding where behaviour lives before reading it.",
			parameters = {
				type = "object",
				properties = {
					root = { type = "string", description = "Where to search. Defaults to game." },
					kind = { type = "string", enum = { "any", "Script", "LocalScript", "ModuleScript" } },
					limit = { type = "integer", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = function(args)
				local root, err = H.resolve(args.root or "game")
				if not root then return H.fail(err) end
				local wanted = args.kind
				if not wanted or wanted == "any" then wanted = "LuaSourceContainer" end

				local ok, descendants = pcall(function() return root:GetDescendants() end)
				if not ok then return H.fail("could not read that subtree") end

				local hits = {}
				for _, node in ipairs(descendants) do
					local okA, isA = pcall(function() return node:IsA(wanted) end)
					if okA and isA then hits[#hits + 1] = node end
				end
				if #hits == 0 then return "No scripts found under " .. H.pathOf(root) .. "." end
				return string.format("%d script(s):\n%s", #hits,
					H.list(hits, H.limit(args.limit, 30, 100), function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "]"
					end))
			end,
		},
		{
			name = "script_source",
			risk = "read",
			description = "Read a script's source. Works when the host can read or decompile it; many live scripts cannot be read at all.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to the script instance." },
					limit = { type = "integer", description = "Maximum characters to return. Default 3000.", minimum = 200, maximum = 64000 },
				},
				required = { "path" },
			},
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local okA, isScript = pcall(function() return instance:IsA("LuaSourceContainer") end)
				if not okA or not isScript then
					return H.fail(instance.ClassName .. " is not a script")
				end

				local source
				local okSource, value = pcall(function() return instance.Source end)
				if okSource and type(value) == "string" and value ~= "" then
					source = value
				elseif caps.fn.decompile then
					local okDecomp, decompiled = pcall(caps.fn.decompile, instance)
					if okDecomp and type(decompiled) == "string" then source = decompiled end
				end

				if not source or util.trim(source) == "" then
					return "The source is not readable from here. Roblox hides Source from client scripts, and this host has no decompiler."
				end

				local limit = tonumber(args.limit) or 3000
				local text, truncated = util.truncate(source, limit)
				return string.format("%s (%d characters%s):\n%s",
					H.pathOf(instance), #source, truncated and ", trimmed" or "", text)
			end,
		},
	}
end
