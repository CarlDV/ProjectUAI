-- JSON-schema validation, argument coercion, and repair of malformed tool
-- arguments.
--
-- Models emit arguments as a JSON string, and that string is sometimes wrong: cut
-- off mid-object when the completion hit its token limit, wrapped in a code
-- fence, carrying a trailing comma, or using a number where the schema says
-- string. Rejecting those outright wastes a whole turn, so each is repaired where
-- the repair is unambiguous and reported where it is not.
return function(env)
	local util = env.require("runtime/util")

	local M = {}

	-- Repair -----------------------------------------------------------------

	-- Walks the text tracking string state, so a brace inside a string literal
	-- does not count towards the balance. Returns the closers needed, and whether
	-- a string was left open.
	local function scanBalance(text)
		local stack, inString, escaped = {}, false, false
		for index = 1, #text do
			local char = text:sub(index, index)
			if inString then
				if escaped then
					escaped = false
				elseif char == "\\" then
					escaped = true
				elseif char == '"' then
					inString = false
				end
			else
				if char == '"' then
					inString = true
				elseif char == "{" or char == "[" then
					stack[#stack + 1] = char
				elseif char == "}" or char == "]" then
					table.remove(stack)
				end
			end
		end
		local closers = {}
		for index = #stack, 1, -1 do
			closers[#closers + 1] = (stack[index] == "{") and "}" or "]"
		end
		return table.concat(closers), inString
	end

	function M.repairJson(raw)
		local text = util.trim(raw)
		if text == "" then return {}, "empty arguments treated as {}" end

		-- Fenced output happens when a model narrates its tool call.
		text = text:gsub("^```%a*%s*", ""):gsub("```%s*$", "")
		text = util.trim(text)

		local direct = util.decode(text)
		if type(direct) == "table" then return direct, nil end

		-- Prose around the object is common; take the outermost bracketed span.
		local first = text:find("[%{%[]")
		local last = text:match(".*()[%}%]]")
		if first and last and last > first then
			local slice = text:sub(first, last)
			local attempt = util.decode(slice)
			if type(attempt) == "table" then return attempt, "stripped text around the JSON object" end
			text = slice
		end

		local noTrailing = text:gsub(",%s*([%}%]])", "%1")
		local attempt = util.decode(noTrailing)
		if type(attempt) == "table" then return attempt, "removed a trailing comma" end
		text = noTrailing

		-- Python-flavoured literals show up from some fine-tunes.
		local pythonic = text:gsub("%f[%w]None%f[%W]", "null")
			:gsub("%f[%w]True%f[%W]", "true")
			:gsub("%f[%w]False%f[%W]", "false")
		if pythonic ~= text then
			attempt = util.decode(pythonic)
			if type(attempt) == "table" then return attempt, "converted Python literals" end
			text = pythonic
		end

		local closers, openString = scanBalance(text)
		if openString or closers ~= "" then
			local patched = text
			if openString then patched = patched .. '"' end
			-- A truncated object usually ends mid-value; dropping the dangling
			-- key-value pair is more likely to parse than closing around it.
			local candidates = {
				patched .. closers,
				(patched:gsub(",%s*\"[^\"]*\"%s*:%s*$", "") .. closers),
				(patched:gsub(",[^,]*$", "") .. closers),
			}
			for _, candidate in ipairs(candidates) do
				local repaired = util.decode(candidate)
				if type(repaired) == "table" then
					return repaired, "completed a truncated JSON object"
				end
			end
		end

		return nil, "arguments were not valid JSON"
	end

	-- Validation -------------------------------------------------------------

	local function typeOf(value)
		if type(value) == "table" then
			return util.isArray(value) and "array" or "object"
		end
		return type(value)
	end

	-- Coercion is one-directional and lossless-ish: a model that answers "5" for a
	-- number, or 5 for a string, meant the obvious thing. Anything ambiguous is a
	-- validation error instead.
	local function coerce(value, wanted)
		local actual = typeOf(value)
		if wanted == nil or wanted == actual then return value, false end
		if wanted == "number" or wanted == "integer" then
			local number = tonumber(value)
			if number == nil then return value, false end
			if wanted == "integer" then number = math.floor(number) end
			return number, true
		end
		if wanted == "string" then
			if actual == "number" or actual == "boolean" then return tostring(value), true end
			return value, false
		end
		if wanted == "boolean" then
			if value == "true" or value == 1 then return true, true end
			if value == "false" or value == 0 then return false, true end
			return value, false
		end
		if wanted == "array" and actual ~= "table" then
			return { value }, true
		end
		if wanted == "object" and actual == "array" and #value == 0 then
			return {}, true
		end
		return value, false
	end

	local function checkValue(schema, value, path, out)
		if type(schema) ~= "table" then return value end
		local wanted = schema.type
		if type(wanted) == "table" then wanted = wanted[1] end

		local coerced, didCoerce = coerce(value, wanted)
		if didCoerce then out.coercions[#out.coercions + 1] = path end
		value = coerced

		local actual = typeOf(value)
		-- An empty Lua table is both an empty array and an empty object, and a model
		-- that sends `[]` for a tool with no arguments is common enough that
		-- rejecting it would waste a turn on nothing.
		if wanted == "object" and actual == "array" and next(value) == nil then
			actual = "object"
		end
		if wanted and actual ~= wanted then
			if not (wanted == "integer" and actual == "number") then
				out.errors[#out.errors + 1] = string.format("%s should be %s, got %s", path, wanted, actual)
				return value
			end
		end

		if schema.enum then
			local allowed = false
			for _, option in ipairs(schema.enum) do
				if option == value then allowed = true end
			end
			if not allowed then
				out.errors[#out.errors + 1] = string.format("%s must be one of: %s",
					path, table.concat(util.map(schema.enum, tostring), ", "))
			end
		end

		if wanted == "number" or wanted == "integer" then
			if schema.minimum and value < schema.minimum then
				out.errors[#out.errors + 1] = string.format("%s must be at least %s", path, tostring(schema.minimum))
			end
			if schema.maximum and value > schema.maximum then
				out.errors[#out.errors + 1] = string.format("%s must be at most %s", path, tostring(schema.maximum))
			end
		end

		if wanted == "string" and schema.maxLength and #value > schema.maxLength then
			out.errors[#out.errors + 1] = string.format("%s is longer than %d characters", path, schema.maxLength)
		end

		if actual == "object" and type(schema.properties) == "table" then
			for _, key in ipairs(schema.required or {}) do
				if value[key] == nil then
					out.errors[#out.errors + 1] = string.format("%s is required", path .. "." .. key)
				end
			end
			for key, child in pairs(schema.properties) do
				if value[key] ~= nil then
					value[key] = checkValue(child, value[key], path .. "." .. key, out)
				end
			end
		end

		if actual == "array" and type(schema.items) == "table" then
			for index, item in ipairs(value) do
				value[index] = checkValue(schema.items, item, string.format("%s[%d]", path, index), out)
			end
		end

		return value
	end

	-- Returns coerced, errors, notes. The caller decides whether a non-empty error
	-- list is fatal; for a tool call it is, and the message goes back to the model
	-- as a tool error so it can correct itself on the next turn.
	function M.validate(schema, value)
		local out = { errors = {}, coercions = {} }
		local coerced = checkValue(schema or {}, value, "arguments", out)
		return coerced, out.errors, out.coercions
	end

	-- Human-readable parameter list, for the tools panel.
	function M.describe(schema)
		if type(schema) ~= "table" or type(schema.properties) ~= "table" then return "no parameters" end
		local required = {}
		for _, key in ipairs(schema.required or {}) do required[key] = true end
		local parts = {}
		for _, key in ipairs(util.keys(schema.properties, true)) do
			local field = schema.properties[key]
			parts[#parts + 1] = string.format("%s%s: %s", key, required[key] and "" or "?",
				(type(field) == "table" and field.type) or "any")
		end
		if #parts == 0 then return "no parameters" end
		return table.concat(parts, ", ")
	end

	return M
end
