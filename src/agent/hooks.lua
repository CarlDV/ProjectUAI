-- Hook bus.
--
-- Extension points around the loop so a host script can observe or amend what
-- happens without patching the loop: rewrite a request before it is sent, veto a
-- tool call, post-process a result, or log an error to somewhere else. The host
-- gets at this through env.context.hooks.
return function(env)
	local util = env.require("runtime/util")
	local log = env.require("runtime/log")

	local KINDS = {
		preRequest = true,   -- (payload) -> may mutate payload.body / payload.record
		postResponse = true, -- (payload) -> may mutate payload.result
		preTool = true,      -- (payload) -> return false to veto; payload.reason explains
		postTool = true,     -- (payload) -> may mutate payload.text
		onError = true,      -- (payload) observer only
		onEvent = true,      -- (payload) every session event, observer only
	}

	local M = { handlers = {} }

	function M.register(kind, fn, opts)
		if not KINDS[kind] then
			log.warn("hooks", "unknown hook kind: " .. tostring(kind))
			return function() end
		end
		M.handlers[kind] = M.handlers[kind] or {}
		local entry = { fn = fn, alive = true, order = (opts and opts.order) or 0, name = (opts and opts.name) or "hook" }
		table.insert(M.handlers[kind], entry)
		table.sort(M.handlers[kind], function(a, b) return a.order < b.order end)
		return function() entry.alive = false end
	end

	-- Runs every handler for a kind. A handler that errors is logged and skipped:
	-- a broken host hook must not take the agent down with it. Returns false when
	-- any handler vetoed, which only preTool acts on.
	function M.run(kind, payload)
		local allowed = true
		for _, entry in ipairs(M.handlers[kind] or {}) do
			if entry.alive then
				local ok, result = pcall(entry.fn, payload)
				if not ok then
					log.warn("hooks", entry.name .. " (" .. kind .. ") failed", result)
				elseif result == false then
					allowed = false
				end
			end
		end
		return allowed, payload
	end

	function M.count(kind)
		local total = 0
		for _, entry in ipairs(M.handlers[kind] or {}) do
			if entry.alive then total = total + 1 end
		end
		return total
	end

	-- A host may pass hooks in at boot: env.context.hooks = { preTool = fn, ... }.
	function M.adoptContext()
		local provided = env.context and env.context.hooks
		if type(provided) ~= "table" then return 0 end
		local adopted = 0
		for kind, fn in pairs(provided) do
			if KINDS[kind] and type(fn) == "function" then
				M.register(kind, fn, { name = "host" })
				adopted = adopted + 1
			end
		end
		if adopted > 0 then log.info("hooks", util.pluralise(adopted, "host hook") .. " registered") end
		return adopted
	end

	M.KINDS = KINDS

	return M
end
