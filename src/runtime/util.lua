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

	-- UTF-8 -----------------------------------------------------------------

	-- Written by hand rather than against the `utf8` library, which is a 5.3 addition:
	-- the client has it, the LuaJIT the test suite runs under does not, and a helper
	-- this far down the tree has to work in both.
	--
	-- Why any of this exists: HttpService:JSONEncode raises "Can't convert to JSON" the
	-- moment a single string anywhere in the payload is not valid UTF-8. It is a C
	-- function, so the error carries no position and no clue. Three separate things in
	-- here used to produce such bytes -- an HTML entity above 127 decoded with
	-- string.char, a percent-escape decoded the same way, and every cut in truncate and
	-- ellipsis, which index in bytes and will happily bisect an em dash. Any one of them
	-- poisons the conversation *permanently*, because the tool result is appended to the
	-- message history and every following request re-encodes the whole history.
	--
	-- U+FFFD written as its three bytes so this file stays ASCII.
	local REPLACEMENT = "\239\191\189"

	-- Valid lead bytes and their sequence lengths, per RFC 3629. 0xC0, 0xC1 and
	-- anything above 0xF4 are never legal leads, and a bare 0x80..0xBF is a
	-- continuation with nothing in front of it.
	local function sequenceWidth(byte)
		if byte < 0x80 then return 1 end
		if byte >= 0xC2 and byte <= 0xDF then return 2 end
		if byte >= 0xE0 and byte <= 0xEF then return 3 end
		if byte >= 0xF0 and byte <= 0xF4 then return 4 end
		return 0
	end

	-- The second byte is the one with a narrowed range: it is what rejects overlong
	-- encodings, the UTF-16 surrogate block, and codepoints past U+10FFFF.
	local function secondRange(lead)
		if lead == 0xE0 then return 0xA0, 0xBF end
		if lead == 0xED then return 0x80, 0x9F end
		if lead == 0xF0 then return 0x90, 0xBF end
		if lead == 0xF4 then return 0x80, 0x8F end
		return 0x80, 0xBF
	end

	local function widthAt(text, index, size)
		local byte = text:byte(index)
		if not byte then return 0 end
		local width = sequenceWidth(byte)
		if width == 0 then return 0 end
		if width == 1 then return 1 end
		if index + width - 1 > size then return 0 end
		local low, high = secondRange(byte)
		local second = text:byte(index + 1)
		if not second or second < low or second > high then return 0 end
		for offset = 2, width - 1 do
			local continuation = text:byte(index + offset)
			if not continuation or continuation < 0x80 or continuation > 0xBF then return 0 end
		end
		return width
	end

	function M.validUtf8(text)
		text = tostring(text or "")
		local size = #text
		local index = 1
		while index <= size do
			local width = widthAt(text, index, size)
			if width == 0 then return false, index end
			index = index + width
		end
		return true
	end

	-- Returns the repaired string and whether anything had to change. The valid case --
	-- which is nearly every string -- allocates nothing and returns the original.
	function M.sanitise(text)
		text = tostring(text or "")
		local size = #text
		local index = 1
		local out = nil
		while index <= size do
			local width = widthAt(text, index, size)
			if width > 0 then
				if out then out[#out + 1] = text:sub(index, index + width - 1) end
				index = index + width
			else
				if not out then out = { text:sub(1, index - 1) } end
				out[#out + 1] = REPLACEMENT
				index = index + 1
			end
		end
		if not out then return text, false end
		return table.concat(out), true
	end

	-- The largest cut point at or below `index` that does not land inside a character.
	-- A cut at `index` keeps text:sub(1, index), which is legal exactly when the byte
	-- after it is not a continuation byte.
	local function cutBefore(text, index)
		if index >= #text then return #text end
		if index < 1 then return 0 end
		local floor = math.max(index - 3, 0)
		while index > floor do
			local byte = text:byte(index + 1)
			if not byte or byte < 0x80 or byte >= 0xC0 then return index end
			index = index - 1
		end
		return index
	end

	-- The same, for a tail slice: shrinks `tail` until text:sub(-tail) starts on a lead
	-- byte.
	local function cutAfter(text, tail)
		local size = #text
		if tail >= size then return size end
		if tail < 1 then return 0 end
		local floor = math.max(tail - 3, 0)
		while tail > floor do
			local byte = text:byte(size - tail + 1)
			if not byte or byte < 0x80 or byte >= 0xC0 then return tail end
			tail = tail - 1
		end
		return tail
	end

	-- Keeps both ends of an over-long value. A tool result that is cut off at the
	-- front loses the summary line and one cut off at the back loses the verdict,
	-- so the middle is what goes.
	--
	-- Both cuts land on a character boundary. They did not, and a limit that happened
	-- to fall inside a curly quote produced a string JSONEncode would not accept --
	-- which killed the turn several seconds later, in the provider adapter, with an
	-- error naming neither this function nor the tool whose output it had cut.
	function M.truncate(text, limit, note)
		text = tostring(text or "")
		if #text <= limit then return text, false end
		local head = math.floor(limit * 0.7)
		local tail = limit - head - 40
		if tail < 40 then
			return text:sub(1, cutBefore(text, limit)) .. "\n... [truncated]", true
		end
		head = cutBefore(text, head)
		tail = cutAfter(text, tail)
		return string.format(
			"%s\n... [%d characters omitted%s] ...\n%s",
			text:sub(1, head), #text - head - tail, note and (", " .. note) or "", text:sub(-tail)
		), true
	end

	function M.ellipsis(text, limit)
		text = tostring(text or ""):gsub("%s+", " ")
		if #text <= limit then return text end
		return text:sub(1, cutBefore(text, math.max(limit - 3, 1))) .. "..."
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
		-- Sanitised on the way out. A percent-escaped UTF-8 URL decodes back to valid
		-- UTF-8, but a Latin-1 escaped one -- %E9 for an accented e -- decodes to a
		-- single byte that is not a legal character on its own, and DuckDuckGo's
		-- redirect parameter is percent-escaped by whoever published the link.
		return (M.sanitise(tostring(text):gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)))
	end

	-- One codepoint as UTF-8 bytes. Hand-rolled for the same reason as the validator
	-- above: `utf8.char` is not there under LuaJIT.
	function M.utf8Char(code)
		code = tonumber(code)
		if not code or code < 0 or code > 0x10FFFF then return "" end
		-- The surrogate block is not a character and encoding it produces bytes
		-- JSONEncode refuses.
		if code >= 0xD800 and code <= 0xDFFF then return "" end
		if code < 0x80 then return string.char(code) end
		if code < 0x800 then
			return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
		end
		if code < 0x10000 then
			return string.char(
				0xE0 + math.floor(code / 0x1000),
				0x80 + (math.floor(code / 0x40) % 0x40),
				0x80 + (code % 0x40))
		end
		return string.char(
			0xF0 + math.floor(code / 0x40000),
			0x80 + (math.floor(code / 0x1000) % 0x40),
			0x80 + (math.floor(code / 0x40) % 0x40),
			0x80 + (code % 0x40))
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
			-- Both numeric forms, encoded properly. This was `string.char(code)` under a
			-- `code < 256` guard, which is exactly backwards: 128..255 became a single
			-- raw byte -- never valid UTF-8 on its own, and `&#160;` alone was enough to
			-- take down every subsequent request in the conversation -- while anything
			-- above 255, such as a curly apostrophe, was silently deleted.
			:gsub("&#x(%x+);", function(hex) return M.utf8Char(tonumber(hex, 16)) end)
			:gsub("&#(%d+);", function(digits) return M.utf8Char(tonumber(digits)) end))
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

	-- Grouped digits are right for a count someone might read out -- five thousand
	-- messages -- and wrong for one they only need the magnitude of: a billion tokens
	-- as thirteen characters of digits is a number nobody parses at a glance, and it
	-- is what a fixed-width tile has to fit.
	function M.formatCompact(value)
		local number = tonumber(value) or 0
		local sign = ""
		if number < 0 then
			sign = "-"
			number = -number
		end
		local function trim(text)
			return (text:gsub("%.0$", ""))
		end
		if number >= 1000000000 then
			return sign .. trim(string.format("%.1f", number / 1000000000)) .. "B"
		end
		if number >= 1000000 then
			return sign .. trim(string.format("%.1f", number / 1000000)) .. "M"
		end
		if number >= 10000 then
			return sign .. trim(string.format("%.1f", number / 1000)) .. "K"
		end
		return sign .. M.formatNumber(number)
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

	-- The one place every outbound value passes through, and therefore the one place
	-- worth scrubbing at.
	--
	-- JSONEncode raises on four kinds of value, and the walker used to hand all four
	-- straight to it: a string that is not valid UTF-8, a NaN or an infinity, a
	-- function/userdata/thread, and a table key that is neither string nor number. The
	-- first is the one that actually happened -- a web search's scraped snippet -- and
	-- because the offending string was already in the message history by then, the
	-- retry, the retry's retry and every later turn all died at the same line with the
	-- same positionless error.
	--
	-- Strings are handled *before* the depth bail-out below, or a string nested deeper
	-- than the limit would slip past unscrubbed.
	local function prepare(value, depth)
		local kind = type(value)
		if kind == "string" then return (M.sanitise(value)) end
		if kind == "number" then
			-- NaN is the only value not equal to itself; the infinities compare equal to
			-- math.huge. All three encode as bare NaN/Infinity tokens, which is not JSON.
			if value ~= value then return 0 end
			if value == math.huge or value == -math.huge then return 0 end
			return value
		end
		if kind == "function" or kind == "userdata" or kind == "thread" then
			-- Replaced rather than dropped: dropping a value leaves a hole in an array and
			-- silently loses a field from an object, and this is a bug worth being able to
			-- see in the payload.
			return "<" .. kind .. ">"
		end
		depth = (depth or 0) + 1
		if depth > 48 or kind ~= "table" then return value end
		if M.isEmptyObject(value) then return EMPTY_TOKEN end
		local out = {}
		for key, item in pairs(value) do
			local keyKind = type(key)
			if keyKind == "string" then
				out[(M.sanitise(key))] = prepare(item, depth)
			elseif keyKind == "number" then
				out[key] = prepare(item, depth)
			end
		end
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
