-- Versioned private configuration transfer; previews never change live state.
-- Clipboard output occurs only through an explicit copyToClipboard call.
-- Validation completes before config.replace swaps any live state.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local M = { FORMAT = "project-uai-config", VERSION = 1 }
	local MAX_BYTES = 8 * 1024 * 1024

	local function object(value, path)
		if type(value) ~= "table" or (next(value) ~= nil and util.isArray(value)) then
			return false, path .. " must be an object"
		end
		for key in pairs(value) do
			if type(key) ~= "string" then return false, path .. " must use named fields" end
		end
		return true
	end

	local function jsonValue(value, path, seen, depth)
		local kind = type(value)
		if kind == "string" or kind == "boolean" then return true end
		if kind == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return false, path .. " must contain finite numbers"
			end
			return true
		end
		if kind ~= "table" then return false, path .. " is not a JSON value" end
		if depth > 24 then return false, path .. " is nested too deeply" end
		if seen[value] then return false, path .. " contains a cycle" end
		seen[value] = true
		local array = util.isArray(value)
		for key, child in pairs(value) do
			if not array and type(key) ~= "string" then return false, path .. " has mixed or sparse keys" end
			local ok, err = jsonValue(child, path .. (array and "[item]" or ".field"), seen, depth + 1)
			if not ok then return false, err end
		end
		seen[value] = nil
		return true
	end

	local function typed(value, defaults, path)
		if type(value) ~= type(defaults) then return false, path .. " must be a " .. type(defaults) end
		if type(defaults) ~= "table" then return true end
		if next(defaults) == nil then return true end
		local ok, err = object(value, path)
		if not ok then return false, err end
		for key, default in pairs(defaults) do
			if value[key] ~= nil then
				ok, err = typed(value[key], default, path .. "." .. key)
				if not ok then return false, err end
			end
		end
		return true
	end

	local function stringMap(value, path, allowed)
		local ok, err = object(value, path)
		if not ok then return false, err end
		for _, item in pairs(value) do
			if not allowed[type(item)] then return false, path .. " has an invalid value type" end
		end
		return true
	end

	local function array(value, path, verify)
		if not util.isArray(value) then return false, path .. " must be a list" end
		for index, item in ipairs(value) do
			local ok, err = verify(item, path .. "[" .. tostring(index) .. "]")
			if not ok then return false, err end
		end
		return true
	end

	local function stringValue(value, path)
		if type(value) ~= "string" then return false, path .. " must be text" end
		return true
	end

	local function provider(record, path)
		local ok, err = object(record, path)
		if not ok then return false, err end
		for _, key in ipairs({ "id", "label", "baseUrl", "apiKey", "model" }) do
			if type(record[key]) ~= "string" then return false, path .. "." .. key .. " must be text" end
		end
		if util.trim(record.id) == "" then return false, path .. ".id must not be empty" end
		for _, key in ipairs({ "preset", "authStyle", "api", "wsUrl", "note", "requires", "opencodeSession" }) do
			if record[key] ~= nil and type(record[key]) ~= "string" then
				return false, path .. "." .. key .. " must be text"
			end
		end
		for _, key in ipairs({ "stream", "claudeUa", "enabled" }) do
			if record[key] ~= nil and type(record[key]) ~= "boolean" then
				return false, path .. "." .. key .. " must be a boolean"
			end
		end
		if record.order ~= nil and type(record.order) ~= "number" then return false, path .. ".order must be a number" end
		ok, err = array(record.models, path .. ".models", stringValue)
		if not ok then return false, err end
		for _, key in ipairs({ "headers", "query" }) do
			if record[key] ~= nil then
				ok, err = stringMap(record[key], path .. "." .. key, { string = true, number = true, boolean = true })
				if not ok then return false, err end
			end
		end
		if record.params ~= nil then
			ok, err = object(record.params, path .. ".params")
			if not ok then return false, err end
		end
		if record.health ~= nil then
			ok, err = typed(record.health, { ok = 0, fail = 0, streak = 0, lastError = "", cooldownUntil = 0, lastMs = 0 }, path .. ".health")
			if not ok then return false, err end
		end
		if record.keyRotation ~= nil then
			ok, err = typed(record.keyRotation, { index = 1, cooldowns = {} }, path .. ".keyRotation")
			if not ok then return false, err end
			if type(record.keyRotation.index) ~= "number" or record.keyRotation.index < 1
				or record.keyRotation.index % 1 ~= 0 then
				return false, path .. ".keyRotation.index must be a positive whole number"
			end
			if record.keyRotation.cooldowns == nil then
				return false, path .. ".keyRotation.cooldowns must be an object"
			end
			if record.keyRotation.cooldowns ~= nil then
				ok, err = stringMap(record.keyRotation.cooldowns, path .. ".keyRotation.cooldowns", { number = true })
				if not ok then return false, err end
			end
		end
		return true
	end

	local function withDefaults(defaults, values)
		local result = util.deepCopy(defaults)
		for key, value in pairs(values) do
			if type(defaults[key]) == "table" and next(defaults[key]) ~= nil and type(value) == "table" then
				result[key] = withDefaults(defaults[key], value)
			else
				result[key] = util.deepCopy(value)
			end
		end
		return result
	end

	-- Unknown JSON fields are preserved for compatibility, while every known
	-- field and runtime-indexed map/list is checked before it reaches consumers.
	function M.validate(snapshot)
		local ok, err = jsonValue(snapshot, "config", {}, 0)
		if not ok then return nil, err end
		ok, err = typed(snapshot, config.defaults, "config")
		if not ok then return nil, err end
		if snapshot.version ~= config.defaults.version then return nil, "Unsupported configuration version" end
		for _, section in ipairs({ "ui", "agent", "providers", "permissions" }) do
			if type(snapshot[section]) ~= "table" then return nil, "config." .. section .. " is required" end
		end
		local merged = withDefaults(config.defaults, snapshot)
		local p = merged.providers
		ok, err = array(p.list, "config.providers.list", provider)
		if not ok then return nil, err end
		local seen = {}
		for _, record in ipairs(p.list) do
			if seen[record.id] then return nil, "Provider ids must be unique" end
			seen[record.id] = true
		end
		if p.active ~= "" and not seen[p.active] then return nil, "The active provider is not in the provider list" end

		local maps = {
			{ "agent.forceReasoning", { boolean = true } },
			{ "agent.forceContext", { number = true } },
			{ "agent.disabledGroups", { boolean = true } },
			{ "permissions.rules", { string = true } },
			{ "skills.disabled", { boolean = true } },
			{ "identity.extraHeaders", { string = true, number = true, boolean = true } },
		}
		for _, spec in ipairs(maps) do
			ok, err = stringMap(util.get(merged, spec[1]), "config." .. spec[1], spec[2])
			if not ok then return nil, err end
		end
		for _, verdict in pairs(merged.permissions.rules) do
			if verdict ~= "allow" and verdict ~= "ask" and verdict ~= "deny" then
				return nil, "Permission rules must be allow, ask, or deny"
			end
		end
		local enums = {
			["permissions.mode"] = { readonly = true, ask = true, auto = true, full = true },
			["ui.density"] = { comfortable = true, compact = true },
			["ui.reduceMotion"] = { auto = true, on = true, off = true },
			["ui.layout"] = { auto = true, sheet = true, panel = true, window = true, tv = true },
			["ui.codeTheme"] = { dark = true, light = true },
			["ui.transcriptWidth"] = { narrow = true, medium = true, wide = true },
			["iy.mode"] = { off = true, hidden = true, visible = true },
		}
		for path, choices in pairs(enums) do
			if not choices[util.get(merged, path)] then return nil, "config." .. path .. " is not a supported choice" end
		end
		ok, err = array(merged.memory.entries, "config.memory.entries", function(entry, path)
			local valid, why = object(entry, path)
			if not valid then return false, why end
			if type(entry.key) ~= "string" or type(entry.value) ~= "string" then
				return false, path .. " needs text key and value fields"
			end
			if entry.at ~= nil and type(entry.at) ~= "number" then return false, path .. ".at must be a number" end
			return true
		end)
		if not ok then return nil, err end
		return merged
	end

	local function summary(snapshot)
		local keyCount = 0
		local active = "None"
		for _, record in ipairs(snapshot.providers.list) do
			local seen = {}
			for key in record.apiKey:gmatch("[^\r\n,]+") do
				key = util.trim(key)
				if key ~= "" and not seen[key] then keyCount = keyCount + 1; seen[key] = true end
			end
			if record.id == snapshot.providers.active then active = record.label end
		end
		return {
			providers = #snapshot.providers.list,
			keys = keyCount,
			active = active,
			permissionMode = snapshot.permissions.mode,
			rules = util.count(snapshot.permissions.rules),
			memory = #snapshot.memory.entries,
			bridgeEnabled = snapshot.bridge.enabled,
		}
	end

	function M.export()
		local snapshot, err = M.validate(config.data)
		if not snapshot then return nil, err end
		local ok, body = pcall(util.encode, {
			format = M.FORMAT,
			version = M.VERSION,
			appVersion = env.info and env.info.version or "",
			exportedAt = clock.ms(),
			config = snapshot,
		})
		if not ok then return nil, "Could not encode the configuration" end
		return body, summary(snapshot)
	end

	function M.copyToClipboard(write)
		if type(write) ~= "function" then return false, "This host cannot write to the clipboard" end
		local body, err = M.export()
		if not body then return false, err end
		local ok, result = pcall(write, body)
		if not ok or result == false then return false, "Could not reach the clipboard" end
		return true
	end

	function M.preview(body)
		if type(body) ~= "string" or util.trim(body) == "" then return nil, "Paste a full configuration export first" end
		if #body > MAX_BYTES then return nil, "This configuration is larger than the 8 MB transfer limit" end
		-- Null is not a persisted setting. JSONDecode drops null object fields,
		-- which would otherwise silently turn an invalid value into a default.
		local quoted, escaped = false, false
		for index = 1, #body do
			local character = body:sub(index, index)
			if quoted then
				if escaped then escaped = false
				elseif character == "\\" then escaped = true
				elseif character == '"' then quoted = false end
			elseif character == '"' then quoted = true
			elseif body:sub(index, index + 3) == "null" then
				return nil, "Null is not a valid configuration value"
			end
		end
		local envelope = util.decode(body)
		if type(envelope) ~= "table" then return nil, "That is not valid configuration JSON" end
		if envelope.format ~= M.FORMAT then return nil, "Use a full configuration export, not a diagnostic export" end
		if envelope.version ~= M.VERSION then return nil, "Unsupported transfer version" end
		local snapshot, err = M.validate(envelope.config)
		if not snapshot then return nil, err end
		return { config = snapshot, summary = summary(snapshot) }
	end

	function M.apply(preview)
		local snapshot, err = M.validate(type(preview) == "table" and preview.config or nil)
		if not snapshot then return false, err end
		local ok, persisted = config.replace(snapshot)
		if not ok then return false, persisted end
		return true, persisted
	end

	return M
end
