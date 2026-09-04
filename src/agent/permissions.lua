-- Permission engine.
--
-- The tools here can rewrite a game, run arbitrary code and delete files, so the
-- default is to ask. The interesting part is the asking: the loop runs on its own
-- thread and the answer comes from the interface, so a request yields until the
-- user decides, with a deadline so an unattended session cannot hang forever.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")

	local ASK_TIMEOUT = 180

	local M = {
		pending = {},
		changed = signal.new("permissions"),
	}

	-- mode -> what each risk level resolves to before rules are consulted.
	local MATRIX = {
		readonly = { read = "allow", write = "deny", danger = "deny" },
		ask = { read = "allow", write = "ask", danger = "ask" },
		auto = { read = "allow", write = "allow", danger = "ask" },
		full = { read = "allow", write = "allow", danger = "allow" },
	}

	M.MODES = { "readonly", "ask", "auto", "full" }

	M.MODE_LABELS = {
		readonly = "Read only",
		ask = "Ask first",
		auto = "Auto (ask for dangerous)",
		full = "Allow everything",
	}

	M.MODE_HINTS = {
		readonly = "Inspection only. Nothing is changed, executed or written.",
		ask = "Reads run freely. Anything that changes the game waits for you.",
		auto = "Reads and writes run freely. Code execution and deletion still ask.",
		full = "No prompts at all. Only sensible when you trust the provider.",
	}

	function M.mode()
		local value = config.get("permissions.mode", "ask")
		return MATRIX[value] and value or "ask"
	end

	function M.setMode(mode)
		if not MATRIX[mode] then return false end
		config.set("permissions.mode", mode)
		M.changed:fire("mode", mode)
		return true
	end

	local function rules()
		local stored = config.get("permissions.rules", {})
		return type(stored) == "table" and stored or {}
	end

	-- A rule may name a tool exactly or end in '*' to cover a group. The most
	-- specific match wins, so `instance_*` = allow with `instance_destroy` = deny
	-- behaves the way it reads.
	function M.ruleFor(name)
		local best, bestLength = nil, -1
		for pattern, verdict in pairs(rules()) do
			local matches = false
			local length = #pattern
			if pattern == name then
				matches = true
				length = math.huge
			elseif pattern:sub(-1) == "*" and util.startsWith(name, pattern:sub(1, -2)) then
				matches = true
			end
			if matches and length > bestLength then
				best, bestLength = verdict, length
			end
		end
		return best
	end

	function M.setRule(pattern, verdict)
		local list = util.copy(rules())
		if verdict == nil or verdict == "default" then
			list[pattern] = nil
		else
			list[pattern] = verdict
		end
		config.set("permissions.rules", list)
		M.changed:fire("rule", pattern)
	end

	function M.listRules()
		local out = {}
		for pattern, verdict in pairs(rules()) do
			out[#out + 1] = { pattern = pattern, verdict = verdict }
		end
		table.sort(out, function(a, b) return a.pattern < b.pattern end)
		return out
	end

	function M.clearRules()
		config.set("permissions.rules", {})
		M.changed:fire("rules", nil)
	end

	-- "allow" | "ask" | "deny", without any user interaction.
	function M.check(tool)
		local rule = M.ruleFor(tool.name)
		if rule == "allow" or rule == "deny" or rule == "ask" then return rule, "rule" end
		local risk = tool.risk or "write"
		return (MATRIX[M.mode()][risk] or "ask"), "mode"
	end

	-- Yields until answered. `emit` is the session's event emitter; the interface
	-- subscribes to permission:ask and calls the resolve function it is handed.
	--
	-- Nothing here trusts the interface to exist: with no subscriber the request
	-- times out and is denied, which is the safe direction.
	function M.request(tool, args, ctx)
		local verdict, source = M.check(tool)
		if verdict ~= "ask" then
			return verdict == "allow", source
		end

		local id = util.uid("perm")
		local answered, allowed, remembered = false, false, false

		local function resolve(decision, remember)
			if answered then return end
			answered = true
			allowed = decision == true
			remembered = remember == true
			M.pending[id] = nil
			if remembered and config.get("permissions.remember", true) then
				M.setRule(tool.name, allowed and "allow" or "deny")
			end
		end

		M.pending[id] = { tool = tool, args = args, at = clock.ms(), resolve = resolve }

		if ctx and ctx.emit then
			ctx.emit("permission:ask", {
				id = id,
				name = tool.name,
				group = tool.group,
				risk = tool.risk or "write",
				description = tool.description,
				args = args,
				resolve = resolve,
			})
		end

		local waited = 0
		while not answered and waited < ASK_TIMEOUT do
			if ctx and ctx.aborted and ctx.aborted() then
				resolve(false, false)
				return false, "aborted"
			end
			waited = waited + (clock.wait(0.1) or 0.1)
		end

		if not answered then
			resolve(false, false)
			log.warn("permissions", "no answer for " .. tool.name .. ", denied after " .. tostring(ASK_TIMEOUT) .. "s")
			return false, "timeout"
		end

		return allowed, remembered and "remembered" or "asked"
	end

	-- Called when a session is torn down mid-prompt: an unanswered request must not
	-- leave a thread parked forever.
	function M.denyAll(reason)
		for _, entry in pairs(M.pending) do
			entry.resolve(false, false)
		end
		M.pending = {}
		if reason then log.info("permissions", "cleared pending prompts: " .. reason) end
	end

	function M.pendingCount()
		return util.count(M.pending)
	end

	return M
end
