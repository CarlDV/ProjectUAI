-- Browser controls use the same stores and validated tool dispatcher as Roblox UI.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local sessions = env.require("agent/session")
	local M = {}
	function M.run(command)
		local kind = command.type
		local session = command.sessionId and sessions.threads[command.sessionId] or sessions.current()
		if not session then error("Conversation no longer exists", 0) end
		if kind == "attachment:upload" then
			local result, err = env.require("runtime/attachments").upload(session.id, command)
			if not result then error(err, 0) end
			return result
		elseif kind == "runtime" then
			if #sessions.busy() > 0 or #env.require("agent/subagent").running() > 0
				or #env.require("runtime/chatloops").running() > 0 then error("Stop running work before switching runtime", 0) end
			if command.value ~= "game" and command.value ~= "web" then error("Unknown runtime", 0) end
			config.set("bridge.runtime", command.value)
		elseif kind == "setting" then
			local path = tostring(command.path or "")
			local section = path:match("^([^.]+)%.")
			if not ({ ui = true, agent = true, logs = true, memory = true, iy = true, identity = true })[section]
				and path ~= "bridge.requestTimeout" then error("Setting is not editable here", 0) end
			local default = util.get(config.defaults, path)
			if default == nil or type(default) == "table" or type(command.value) ~= type(default) then error("Invalid setting value", 0) end
			if type(command.value) == "number" and (command.value ~= command.value or math.abs(command.value) > 10000000 or command.value < 0) then error("Invalid numeric setting", 0) end
			if type(command.value) == "string" and #command.value > 16000 then error("Setting is too long", 0) end
			local choices = {
				["ui.density"] = { comfortable = true, compact = true },
				["ui.accent"] = { claude = true, aurora = true, indigo = true, amber = true, rose = true },
				["ui.reduceMotion"] = { auto = true, on = true, off = true },
				["ui.layout"] = { auto = true, sheet = true, panel = true, window = true, tv = true },
				["ui.codeTheme"] = { dark = true, light = true },
				["ui.transcriptWidth"] = { narrow = true, medium = true, wide = true },
				["iy.mode"] = { off = true, hidden = true, visible = true },
				["agent.effort"] = { low = true, medium = true, high = true, xhigh = true, max = true },
			}
			if choices[path] and not choices[path][command.value] then error("Unsupported setting choice", 0) end
			local ranges = { ["ui.fontScale"] = { 0.85, 1.4 }, ["agent.temperature"] = { 0, 2 },
				["agent.toolConcurrency"] = { 1, 8 }, ["agent.maxTurns"] = { 1, 1000 },
				["agent.toolTimeout"] = { 1, 86400 }, ["agent.requestTimeout"] = { 1, 86400 },
				["bridge.requestTimeout"] = { 10, 86400 }, ["agent.retries"] = { 1, 10 },
				["agent.contextTokens"] = { 1000, 2000000 }, ["agent.contextFraction"] = { 0.3, 0.95 },
				["agent.maxTokens"] = { 1, 1000000 } }
			local range = ranges[path]
			if range and (command.value < range[1] or command.value > range[2]) then error("Setting is outside its supported range", 0) end
			config.set(path, command.value)
		elseif kind == "tool:rule" then
			local rule = command.rule
			if not ({ allow = true, deny = true, ask = true, default = true })[rule] then error("Invalid rule", 0) end
			env.require("agent/permissions").setRule(tostring(command.name), rule)
		elseif kind == "tool:group" then
			env.require("agent/registry").setGroupEnabled(tostring(command.group), command.enabled == true)
		elseif kind == "tool:run" then
			local registry = env.require("agent/registry")
			if session.busy then error("Conversation is already working", 0) end
			local tool = registry.get(command.name)
			if not tool or not registry.groupEnabled(tool.group) then error("Tool unavailable", 0) end
			session.busy, session.abortFlag = true, false
			sessions.listChanged:fire()
			session.emit("tool:call", { id = command.commandId, name = command.name,
				arguments = util.encode(command.arguments or {}) })
			local ok, result = pcall(registry.dispatch, { id = command.commandId, name = command.name,
				arguments = util.encode(command.arguments or {}) }, session.toolContext())
			session.busy = false
			sessions.listChanged:fire()
			if not ok then error(result, 0) end
			session.emit(result.ok and "tool:result" or "tool:error", result)
			session.emit("status", { text = "Ready" })
			sessions.persist(session)
			return result
		elseif kind == "provider:save" then
			local providers = env.require("provider/registry")
			local fields = command.provider or {}
			local record = fields.id and providers.get(fields.id) or providers.blank(fields.preset or "custom")
			if not record then error("Unknown provider", 0) end
			record = util.deepCopy(record)
			for _, name in ipairs({ "label", "baseUrl", "api", "authStyle", "apiKey", "model", "wsUrl" }) do
				if fields[name] ~= nil then record[name] = tostring(fields[name]) end
			end
			for _, name in ipairs({ "models", "headers", "params", "query", "apiKeys" }) do
				if type(fields[name]) == "table" then record[name] = fields[name] end
			end
			if fields.enabled ~= nil then record.enabled = fields.enabled == true end
			local ok, errors = providers.save(record)
			if not ok then error(table.concat(errors or {}, "; "), 0) end
		elseif kind == "provider:remove" then env.require("provider/registry").remove(command.id)
		elseif kind == "provider:test" then
			local record = env.require("provider/registry").get(command.id)
			if not record then error("Unknown provider", 0) end
			local result, err = env.require("provider/chat").complete(record, {
				messages = { { role = "user", content = "Reply with OK." } }, maxTokens = 12, attempts = 1,
			})
			if not result then error(err, 0) end
			return { text = "Connected: " .. tostring(result.content), ms = result.ms }
		elseif kind == "loops:stop" then return { stopped = env.require("runtime/chatloops").stop(command.id or "all") }
		elseif kind == "thread:isolate" then session.setEphemeral(command.value == true)
		elseif kind == "ask:answer" then
			local asks = env.require("ui/panels/ask")
			if not asks.answer(command.id, tostring(command.text or "")) then error("Question is no longer pending", 0) end
		elseif kind == "config:export" then
			local text, err = env.require("runtime/config_transfer").export()
			if not text then error(err, 0) end
			return { text = text }
		elseif kind == "config:import" then
			if #sessions.busy() > 0 then error("Stop running work before importing settings", 0) end
			local transfer = env.require("runtime/config_transfer")
			local preview, err = transfer.preview(command.text)
			if not preview then error(err, 0) end
			-- Connection credentials stay valid until the acknowledgement is delivered.
			preview.config.bridge = util.deepCopy(config.get("bridge"))
			local ok, why = transfer.apply(preview)
			if not ok then error(why, 0) end
		elseif kind == "logs:clear" then env.require("runtime/log").clear(); env.require("net/http").clearHistory()
		else return false end
		return true
	end
	return M
end
