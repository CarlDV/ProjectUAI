-- Tool registry and dispatch.
--
-- Owns the whole path from "the model asked for a tool" to "here is a string it
-- can read": argument repair, schema validation, capability gating, the
-- permission prompt, hooks, a timeout, error capture and truncation. The loop
-- calls runAll and gets results; it never touches a handler directly.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local schema = env.require("agent/schema")
	local permissions = env.require("agent/permissions")
	local hooks = env.require("agent/hooks")

	local M = {
		tools = {},
		order = {},
		loaded = false,
	}

	function M.register(tool)
		if type(tool) ~= "table" or util.trim(tool.name) == "" or type(tool.run) ~= "function" then
			log.warn("tools", "ignored a malformed tool definition")
			return false
		end
		if M.tools[tool.name] then
			log.warn("tools", "duplicate tool name: " .. tool.name)
			return false
		end
		tool.risk = tool.risk or "write"
		tool.group = tool.group or "misc"
		tool.parameters = tool.parameters or { type = "object", properties = util.emptyObject(), required = {} }
		M.tools[tool.name] = tool
		M.order[#M.order + 1] = tool.name
		return true
	end

	function M.load()
		if M.loaded then return M end
		M.loaded = true
		local groups = env.require("tools/init")
		for _, tool in ipairs(groups.all()) do M.register(tool) end
		log.info("tools", util.pluralise(#M.order, "tool") .. " registered")
		return M
	end

	function M.get(name)
		M.load()
		return M.tools[name]
	end

	function M.list()
		M.load()
		local out = {}
		for _, name in ipairs(M.order) do out[#out + 1] = M.tools[name] end
		return out
	end

	function M.missingCapability(tool)
		for _, key in ipairs(tool.needs or {}) do
			if not caps.has(key) then return key end
		end
		return nil
	end

	-- The definition list the provider sees.
	--
	-- Tools the host cannot run are omitted rather than described-and-refused: a
	-- model shown a tool will use it, and a turn spent learning that writefile does
	-- not exist here is a wasted turn. Read-only mode omits everything that writes,
	-- for the same reason.
	function M.definitions(opts)
		opts = opts or {}
		M.load()
		local readonly = permissions.mode() == "readonly"
		local out = {}
		for _, name in ipairs(M.order) do
			local tool = M.tools[name]
			local allow = true
			if M.missingCapability(tool) then allow = false end
			if readonly and tool.risk ~= "read" then allow = false end
			if permissions.ruleFor(name) == "deny" then allow = false end
			if opts.only and not opts.only[name] then allow = false end
			if opts.groups and not opts.groups[tool.group] then allow = false end
			if allow then
				local params = tool.parameters
				if type(params) == "table" and type(params.properties) == "table"
					and util.count(params.properties) == 0 and not util.isEmptyObject(params.properties) then
					-- An empty Luau table encodes as [], which gateways reject for
					-- `properties`. The marker makes it an object.
					params = util.merge(params, { properties = util.emptyObject() })
				end
				out[#out + 1] = {
					type = "function",
					["function"] = {
						name = tool.name,
						description = tool.description,
						parameters = params,
					},
				}
			end
		end
		return out
	end

	function M.stats()
		M.load()
		local byGroup, byRisk, unavailable = {}, {}, {}
		for _, tool in ipairs(M.list()) do
			byGroup[tool.group] = (byGroup[tool.group] or 0) + 1
			byRisk[tool.risk] = (byRisk[tool.risk] or 0) + 1
			local missing = M.missingCapability(tool)
			if missing then unavailable[#unavailable + 1] = { name = tool.name, needs = missing } end
		end
		return { total = #M.order, byGroup = byGroup, byRisk = byRisk, unavailable = unavailable }
	end

	-- One call. Always returns a result table; never raises.
	function M.dispatch(call, ctx)
		M.load()
		local fn = call["function"] or {}
		local name = fn.name or call.name or "unknown"
		local started = clock.ms()
		local result = { id = call.id, name = name, ok = false, text = "", ms = 0 }

		local tool = M.tools[name]
		if not tool then
			local names = util.slice(M.order, 1, 12)
			result.text = string.format("No tool named '%s'. Available tools include: %s.",
				name, table.concat(names, ", "))
			result.error = "unknown tool"
			result.ms = clock.since(started)
			return result
		end
		result.risk = tool.risk
		result.group = tool.group

		local missing = M.missingCapability(tool)
		if missing then
			result.text = string.format("%s is unavailable: %s. Do not retry this tool.",
				name, caps.reason(missing))
			result.error = "capability missing"
			result.ms = clock.since(started)
			return result
		end

		local args, repairNote = schema.repairJson(fn.arguments or call.arguments or "{}")
		if args == nil then
			result.text = string.format("Could not read the arguments for %s: %s. Send valid JSON.",
				name, tostring(repairNote))
			result.error = "bad arguments"
			result.ms = clock.since(started)
			return result
		end
		if repairNote then log.debug("tools", name .. ": " .. repairNote) end

		local coerced, errors = schema.validate(tool.parameters, args)
		if #errors > 0 then
			result.text = string.format("%s was called with invalid arguments: %s",
				name, table.concat(errors, "; "))
			result.error = "invalid arguments"
			result.args = coerced
			result.ms = clock.since(started)
			return result
		end
		result.args = coerced

		local payload = { tool = tool, args = coerced, ctx = ctx, reason = nil }
		local allowedByHooks = hooks.run("preTool", payload)
		if not allowedByHooks then
			result.text = string.format("%s was blocked by a host hook%s.", name,
				payload.reason and (": " .. tostring(payload.reason)) or "")
			result.error = "vetoed"
			result.ms = clock.since(started)
			return result
		end

		local allowed, source = permissions.request(tool, coerced, ctx)
		if not allowed then
			result.text = string.format("The user did not approve %s (%s). Do not retry it; ask what to do instead.",
				name, source or "denied")
			result.error = "denied"
			result.denied = true
			result.ms = clock.since(started)
			return result
		end

		local timeout = tool.timeout or config.get("agent.toolTimeout", 25)
		local finished, ok, value = clock.timeout(timeout, function()
			return tool.run(coerced, ctx)
		end)

		if not finished then
			result.text = string.format(
				"%s did not finish within %ds and was left running in the background. Do not retry the same call.",
				name, timeout)
			result.error = "timeout"
			result.ms = clock.since(started)
			return result
		end

		if not ok then
			result.text = string.format("%s failed: %s", name, util.ellipsis(tostring(value), 400))
			result.error = "error"
			result.ms = clock.since(started)
			log.warn("tools", name .. " raised", value)
			return result
		end

		local text, data, handlerOk
		if type(value) == "table" then
			text = tostring(value.text or "")
			data = value.data
			-- A handler may report a semantic failure -- a path that does not exist,
			-- a host that cannot do the thing -- without raising. That is not an
			-- error in the tool, but it is not a success either, and the transcript
			-- should say so.
			handlerOk = value.ok ~= false
		else
			text = tostring(value == nil and "Done." or value)
			handlerOk = true
		end

		local after = { tool = tool, args = coerced, text = text, data = data, ctx = ctx }
		hooks.run("postTool", after)
		text = tostring(after.text or text)

		local cap = config.get("agent.resultCap", 4000)
		local capped, truncated = util.truncate(text, cap, "ask for a narrower slice if you need the rest")
		result.ok = handlerOk
		if not handlerOk then result.error = "tool reported a failure" end
		result.text = capped
		result.full = truncated and text or nil
		result.truncated = truncated
		result.data = after.data
		result.ms = clock.since(started)
		return result
	end

	-- Runs a batch with a concurrency cap.
	--
	-- The model is told parallel calls are executed together, and they are: each
	-- runs on its own thread, up to `agent.toolConcurrency` at a time. Dispatch
	-- carries its own timeout, so the batch cannot outlive the slowest permitted
	-- call by more than a poll interval.
	function M.runAll(calls, ctx)
		local total = #calls
		local results = {}
		if total == 0 then return results end

		local cap = math.max(config.get("agent.toolConcurrency", 4), 1)
		local launched, completed = 0, 0

		while completed < total do
			while launched < total and (launched - completed) < cap do
				launched = launched + 1
				local index = launched
				task.spawn(function()
					local ok, value = pcall(M.dispatch, calls[index], ctx)
					if ok then
						results[index] = value
					else
						results[index] = {
							id = calls[index].id,
							name = (calls[index]["function"] or {}).name or "unknown",
							ok = false,
							error = "dispatch failed",
							text = "Internal error running the tool: " .. tostring(value),
							ms = 0,
						}
						log.error("tools", "dispatch crashed", value)
					end
					completed = completed + 1
				end)
			end
			if completed < total then clock.wait() end
		end

		return results
	end

	return M
end
