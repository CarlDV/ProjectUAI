-- Small, dependency-free helpers shared by every layer. Nothing here may
-- require another module: this is the bottom of the tree.
return function(env)
	local M = {}

	-- Strings ---------------------------------------------------------------

	function M.trim(text)
		return (tostring(text or ""):match("^%s*(.-)%s*$"))
	end

	function M.startsWith(text, prefix)
		return tostring(text):sub(1, #prefix) == prefix
	end

	function M.endsWith(text, suffix)
		return suffix == "" or tostring(text):sub(-#suffix) == suffix
	end

	-- Makes a literal safe to drop into a Lua pattern. Forgetting this is the
	-- classic source of "why does searching for a dot match everything".
	function M.escapePattern(text)
		return (tostring(text):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
	end

	function M.split(text, separator)
		local out = {}
		local pattern = "([^" .. M.escapePattern(separator) .. "]+)"
		for piece in tostring(text):gmatch(pattern) do out[#out + 1] = piece end
		return out
	end

	function M.lines(text)
		local out = {}
		for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
		if out[#out] == "" then table.remove(out) end
		return out
	end

	-- Keeps both ends of an over-long value. A tool result that is cut off at the
	-- front loses the summary line and one cut off at the back loses the verdict,
	-- so the middle is what goes.
	function M.truncate(text, limit, note)
		text = tostring(text or "")
		if #text <= limit then return text, false end
		local head = math.floor(limit * 0.7)
		local tail = limit - head - 40
		if tail < 40 then
			return text:sub(1, limit) .. "\n... [truncated]", true
		end
		return string.format(
			"%s\n... [%d characters omitted%s] ...\n%s",
			text:sub(1, head), #text - head - tail, note and (", " .. note) or "", text:sub(-tail)
		), true
	end

	function M.ellipsis(text, limit)
		text = tostring(text or ""):gsub("%s+", " ")
		if #text <= limit then return text end
		return text:sub(1, math.max(limit - 3, 1)) .. "..."
	end

	function M.indent(text, prefix)
		local out = {}
		for _, line in ipairs(M.lines(text)) do out[#out + 1] = prefix .. line end
		return table.concat(out, "\n")
	end

	function M.pluralise(count, word)
		return tostring(count) .. " " .. word .. (count == 1 and "" or "s")
	end

	function M.urlEncode(text)
		return (tostring(text):gsub("[^%w%-_%.~]", function(c)
			return string.format("%%%02X", string.byte(c))
		end))
	end

	function M.urlDecode(text)
		return (tostring(text):gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end))
	end

	function M.htmlEntities(text)
		return (tostring(text)
			:gsub("&nbsp;", " ")
			:gsub("&amp;", "&")
			:gsub("&lt;", "<")
			:gsub("&gt;", ">")
			:gsub("&quot;", '"')
			:gsub("&#x27;", "'")
			:gsub("&#39;", "'")
			:gsub("&#(%d+);", function(n)
				local code = tonumber(n)
				return code and code < 256 and string.char(code) or ""
			end))
	end

	-- Tables ----------------------------------------------------------------

	function M.copy(source)
		local out = {}
		for key, value in pairs(source or {}) do out[key] = value end
		return out
	end

	function M.deepCopy(source, depth)
		depth = (depth or 0) + 1
		if depth > 32 or type(source) ~= "table" then return source end
		local out = {}
		for key, value in pairs(source) do out[key] = M.deepCopy(value, depth) end
		return out
	end

	-- Right wins, and nested tables merge rather than replace, which is what a
	-- persisted config layered over defaults needs.
	function M.merge(base, override)
		local out = M.deepCopy(base)
		for key, value in pairs(override or {}) do
			if type(value) == "table" and type(out[key]) == "table" and not M.isArray(value) then
				out[key] = M.merge(out[key], value)
			else
				out[key] = M.deepCopy(value)
			end
		end
		return out
	end

	function M.isArray(value)
		if type(value) ~= "table" then return false end
		local count = 0
		for key in pairs(value) do
			if type(key) ~= "number" then return false end
			count = count + 1
		end
		return count == #value
	end

	function M.keys(source, sorted)
		local out = {}
		for key in pairs(source or {}) do out[#out + 1] = key end
		if sorted then
			table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
		end
		return out
	end

	function M.count(source)
		local n = 0
		for _ in pairs(source or {}) do n = n + 1 end
		return n
	end

	function M.map(list, fn)
		local out = {}
		for index, value in ipairs(list or {}) do out[index] = fn(value, index) end
		return out
	end

	function M.filter(list, fn)
		local out = {}
		for index, value in ipairs(list or {}) do
			if fn(value, index) then out[#out + 1] = value end
		end
		return out
	end

	function M.find(list, fn)
		for index, value in ipairs(list or {}) do
			if fn(value, index) then return value, index end
		end
		return nil
	end

	function M.slice(list, from, to)
		local out = {}
		for index = math.max(from or 1, 1), math.min(to or #list, #list) do
			out[#out + 1] = list[index]
		end
		return out
	end

	function M.reverse(list)
		local out = {}
		for index = #list, 1, -1 do out[#out + 1] = list[index] end
		return out
	end

	function M.concatKeys(source, separator)
		local parts = {}
		for _, key in ipairs(M.keys(source, true)) do
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(source[key])
		end
		return table.concat(parts, separator or ", ")
	end

	-- Numbers ---------------------------------------------------------------

	function M.clamp(value, low, high)
		if value < low then return low end
		if value > high then return high end
		return value
	end

	function M.round(value, places)
		local factor = 10 ^ (places or 0)
		return math.floor(value * factor + 0.5) / factor
	end

	function M.lerp(from, to, alpha)
		return from + (to - from) * alpha
	end

	function M.formatNumber(value)
		local text = string.format("%d", math.floor(value))
		local sign, digits = text:match("^(%-?)(%d+)$")
		local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
		return sign .. grouped
	end

	function M.formatDuration(ms)
		if ms < 1000 then return string.format("%dms", math.floor(ms)) end
		if ms < 60000 then return string.format("%.1fs", ms / 1000) end
		return string.format("%dm %ds", math.floor(ms / 60000), math.floor((ms % 60000) / 1000))
	end

	function M.uid(prefix)
		M.__counter = (M.__counter or 0) + 1
		return (prefix or "id") .. "_" .. tostring(M.__counter) .. "_" ..
			string.format("%x", math.floor((tonumber(tostring(os.time())) or 0) % 65536))
	end

	-- JSON ------------------------------------------------------------------

	-- JSONEncode turns an empty table into `[]`, which is correct for an empty
	-- list and wrong for an empty object -- and every OpenAI-compatible gateway
	-- rejects `"properties": []`. Rather than patching known key names out of the
	-- finished string, an intentionally empty object is marked here and the marker
	-- is swapped for `{}` after encoding.
	-- The token is deliberately alphanumeric: it is substituted out of the encoded
	-- string with gsub, and a '-' or ':' in it would be read as pattern syntax.
	local EMPTY_MARK = "__uai_empty_object"
	local EMPTY_TOKEN = "uai0e4b1c9fEMPTYOBJECT"

	function M.emptyObject()
		return { [EMPTY_MARK] = true }
	end

	function M.isEmptyObject(value)
		return type(value) == "table" and value[EMPTY_MARK] == true
	end

	local function prepare(value, depth)
		depth = (depth or 0) + 1
		if depth > 48 or type(value) ~= "table" then return value end
		if M.isEmptyObject(value) then return EMPTY_TOKEN end
		local out = {}
		for key, item in pairs(value) do out[key] = prepare(item, depth) end
		return out
	end

	function M.encode(value)
		local body = env.hs:JSONEncode(prepare(value))
		return (body:gsub('"' .. EMPTY_TOKEN .. '"', "{}"))
	end

	-- Never throws. Callers get nil plus the reason, because a malformed body from
	-- a third-party gateway is an expected condition, not a bug.
	function M.decode(text)
		if type(text) ~= "string" or text == "" then return nil, "empty body" end
		local ok, result = pcall(function() return env.hs:JSONDecode(text) end)
		if not ok then return nil, tostring(result) end
		return result
	end

	-- Best-effort read of a value at a dotted path: get(cfg, "ui.window.width").
	function M.get(source, path, fallback)
		local node = source
		for _, part in ipairs(M.split(path, ".")) do
			if type(node) ~= "table" then return fallback end
			node = node[part]
		end
		if node == nil then return fallback end
		return node
	end

	function M.set(source, path, value)
		local parts = M.split(path, ".")
		local node = source
		for index = 1, #parts - 1 do
			local key = parts[index]
			if type(node[key]) ~= "table" then node[key] = {} end
			node = node[key]
		end
		node[parts[#parts]] = value
		return source
	end

	return M
end
