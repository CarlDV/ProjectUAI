-- Action definitions and parameter validation. Values are data, never source.
return function(env)
	local util = env.require("runtime/util")
	local limits = env.require("runtime/code_limits")
	local M = {}
	local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
	function M.value(def, value)
		if value == nil then value = def.default end
		if value == nil then
			if def.required then return false, "Missing input: " .. def.key end
			return true, nil
		end
		if def.type == "number" then
			if not finite(value) then return false, def.key .. " must be a finite number" end
			if (def.min and value < def.min) or (def.max and value > def.max) then return false, def.key .. " is outside its allowed range" end
		elseif def.type == "boolean" then
			if type(value) ~= "boolean" then return false, def.key .. " must be a boolean" end
		elseif def.type == "string" or def.type == "choice" then
			if type(value) ~= "string" or #value > limits.inputString or not util.validUtf8(value) then return false, def.key .. " must be valid text (up to 4096 bytes)" end
			if def.type == "choice" then
				local found = false
				for _, choice in ipairs(def.choices) do if choice == value then found = true end end
				if not found then return false, "Choose one of the allowed values for " .. def.key end
			end
		else return false, "Unsupported input type" end
		return true, value
	end
	function M.definitions(input)
		if type(input) ~= "table" or not util.isArray(input) or #input > limits.inputs then return nil, "Use at most 12 input definitions" end
		local result, keys = {}, {}
		for _, item in ipairs(input) do
			if type(item) ~= "table" or type(item.key) ~= "string" or #item.key > 64 or not item.key:match("^[%a_][%w_]*$") or keys[item.key] then return nil, "Input keys must be unique identifiers, up to 64 bytes" end
			if item.type ~= "string" and item.type ~= "number" and item.type ~= "boolean" and item.type ~= "choice" then return nil, "Unsupported input type" end
			local def = { key = item.key, label = util.ellipsis(item.label or item.key, 100), type = item.type, required = item.required == true }
			if item.min ~= nil then if not finite(item.min) then return nil, "Invalid minimum" end; def.min = item.min end
			if item.max ~= nil then if not finite(item.max) then return nil, "Invalid maximum" end; def.max = item.max end
			if def.min and def.max and def.min > def.max then return nil, "Minimum exceeds maximum" end
			if def.type == "choice" then
				if type(item.choices) ~= "table" or not util.isArray(item.choices) or #item.choices < 1 or #item.choices > 32 then return nil, "Choices require 1–32 values" end
				def.choices = {}; local seen = {}
				for _, choice in ipairs(item.choices) do
					if type(choice) ~= "string" or #choice > limits.inputString or seen[choice] or not util.validUtf8(choice) then return nil, "Invalid or repeated choice" end
					seen[choice] = true; def.choices[#def.choices + 1] = choice
				end
			end
			if item.default ~= nil then
				local ok, value = M.value(def, item.default)
				if not ok then return nil, value end
				def.default = value
			end
			keys[def.key] = true; result[#result + 1] = def
		end
		return result
	end
	function M.parameters(definitions, values)
		if type(values) ~= "table" then return nil, "Inputs must be an object" end
		local result, known = {}, {}
		for _, def in ipairs(definitions) do
			local ok, value = M.value(def, values[def.key])
			if not ok then return nil, value end
			result[def.key], known[def.key] = value, true
		end
		for key in pairs(values) do if not known[key] then return nil, "Unknown input: " .. tostring(key) end end
		return result
	end
	return M
end
