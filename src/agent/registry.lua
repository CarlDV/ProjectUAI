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

	-- Groups the user has switched off.
	--
	-- A whole family of tools is a coarser thing to turn off than a permission rule
	-- and it answers a different question: a rule decides whether a call is allowed,
	-- this decides whether the model is told the tool exists at all. Somebody who does
	-- not want the agent touching remotes in this game wants the second one.
	local GROUP_LABELS = {
		agentself = "Agent",
		instance = "Instance tree",
		script = "Code",
		fs = "Files",
		net = "HTTP",
		web = "Web",
		players = "Players",
		character = "Character",
		world = "World",
		remotes = "Remotes",
		gui = "Interface",
		perf = "Diagnostics",
		meta = "Metadata",
		chat = "In-game chat",
		input = "Virtual input",
	}

	M.GROUP_LABELS = GROUP_LABELS

	function M.groupLabel(group)
		return GROUP_LABELS[group] or tostring(group)
	end

	local function disabledGroups()
		local stored = config.get("agent.disabledGroups", {})
		if type(stored) ~= "table" then return {} end
		return stored
	end

	function M.groupEnabled(group)
		return disabledGroups()[tostring(group)] ~= true
	end

	function M.setGroupEnabled(group, enabled)
		local list = util.copy(disabledGroups())
		if enabled == false then
			list[tostring(group)] = true
		else
			list[tostring(group)] = nil
		end
		config.set("agent.disabledGroups", list)
		return enabled ~= false
	end

	-- Every group the registry knows about, with what is in it and whether it is on.
	function M.groups()
		M.load()
		local byGroup, order = {}, {}
		for _, tool in ipairs(M.list()) do
			local entry = byGroup[tool.group]
			if not entry then
				entry = {
					id = tool.group,
					label = M.groupLabel(tool.group),
					total = 0,
					unavailable = 0,
					enabled = M.groupEnabled(tool.group),
				}
				byGroup[tool.group] = entry
				order[#order + 1] = entry
			end
			entry.total = entry.total + 1
			if M.missingCapability(tool) then entry.unavailable = entry.unavailable + 1 end
		end
		table.sort(order, function(a, b) return a.label < b.label end)
		return order
	end

	-- Keywords whose value is a JSON array. Everything else in a schema that is an
	-- empty table wants to encode as {}, not [].
	local SCHEMA_ARRAYS = {
		required = true, enum = true, examples = true,
		allOf = true, anyOf = true, oneOf = true, prefixItems = true,
	}

	-- An empty Luau table encodes as [], and a strict validator -- draft 2020-12,
	-- which Anthropic-on-Bedrock enforces and which answers with a bare
	-- TOOL_SCHEMA_INVALID -- rejects [] anywhere a schema or a property map belongs.
	-- Marking the empty table fixes it, but doing that only for a top-level
	-- `properties` leaves `items` and every nested schema broken, and relies on each
	-- of sixty-odd tool authors remembering. So the whole tree is walked here once,
	-- on the way out, and the tools stay free to write the obvious `{}`.
	local function normaliseSchema(node, depth)
		depth = (depth or 0) + 1
		if depth > 32 or type(node) ~= "table" or util.isEmptyObject(node) then return node end
		local out = {}
		for key, value in pairs(node) do
			if type(value) ~= "table" or util.isEmptyObject(value) then
				out[key] = value
			elseif util.count(value) == 0 and not SCHEMA_ARRAYS[key] then
				out[key] = util.emptyObject()
			else
				out[key] = normaliseSchema(value, depth)
			end
		end
		return out
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
			if not M.groupEnabled(tool.group) then allow = false end
			if opts.only and not opts.only[name] then allow = false end
			if opts.groups and not opts.groups[tool.group] then allow = false end
			if allow then
				out[#out + 1] = {
					type = "function",
					["function"] = {
						name = tool.name,
						description = tool.description,
						parameters = normaliseSchema(tool.parameters),
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

		-- A tool may state its own timeout, as a number or as a function of nothing --
		-- dispatch_agent computes one from the subagent budget, which is a setting and
		-- so cannot be a constant on the definition.
		local timeout = tool.timeout
		if type(timeout) == "function" then
			local okTimeout, value = pcall(timeout, coerced, ctx)
			timeout = okTimeout and tonumber(value) or nil
		end
		timeout = tonumber(timeout) or config.get("agent.toolTimeout", 25)

		-- The call's id travels with the context so a tool that emits events of its own
		-- can address the row it belongs to. dispatch_agent needs it: its subagent's
		-- live feed has to appear under the call that started it. Shallow, deliberately:
		-- ctx carries the session and the module env, and a deep copy of either would be
		-- both enormous and wrong.
		local scoped = ctx
		if type(ctx) == "table" then
			scoped = util.copy(ctx)
			scoped.callId = call.id
		end
		local finished, ok, value = clock.timeout(timeout, function()
			return tool.run(coerced, scoped)
		end)

		if not finished then
			result.text = string.format(
				"%s did not finish within %ds. It may still be running, but nothing will collect its result, so treat it as lost. Do not retry the same call.",
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
