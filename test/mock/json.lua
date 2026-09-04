-- JSON that behaves like HttpService's, including the quirks the real client has
-- to work around: an empty table encodes as [] rather than {}, and a decoded
-- null leaves no key behind. Getting those two wrong offline would hide exactly
-- the bugs this harness exists to catch.
local M = {}

local ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(value)
	local out = value:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end)
	return '"' .. out .. '"'
end

local function encodeNumber(value)
	if value ~= value then error("cannot encode NaN to JSON", 0) end
	if value == math.huge or value == -math.huge then error("cannot encode infinity to JSON", 0) end
	if value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return (string.format("%.14g", value))
end

-- Array unless a non-positive-integer key exists. An empty table counts as an
-- array, which is where the "properties":[] problem in the provider payload
-- comes from.
local function isArray(tbl)
	local count = 0
	for key in pairs(tbl) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
		count = count + 1
	end
	return count == #tbl
end

local encodeValue

local function encodeTable(tbl, depth)
	if depth > 60 then error("JSON nesting too deep", 0) end
	if isArray(tbl) then
		local parts = {}
		for i = 1, #tbl do parts[#parts + 1] = encodeValue(tbl[i], depth + 1) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(tbl) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, key in ipairs(keys) do
		local encoded = encodeValue(tbl[key], depth + 1)
		if encoded then
			parts[#parts + 1] = encodeString(tostring(key)) .. ":" .. encoded
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

function encodeValue(value, depth)
	local kind = type(value)
	if value == nil then return "null" end
	if kind == "boolean" then return value and "true" or "false" end
	if kind == "number" then return encodeNumber(value) end
	if kind == "string" then return encodeString(value) end
	if kind == "table" then return encodeTable(value, depth) end
	error("cannot encode " .. kind .. " to JSON", 0)
end

function M.encode(value)
	return encodeValue(value, 0)
end

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
	return setmetatable({ text = text, pos = 1 }, Parser)
end

function Parser:fail(message)
	error(string.format("JSON parse error at %d: %s", self.pos, message), 0)
end

function Parser:skip()
	local _, stop = self.text:find("^[ \t\r\n]+", self.pos)
	if stop then self.pos = stop + 1 end
end

function Parser:literal(word, value)
	if self.text:sub(self.pos, self.pos + #word - 1) == word then
		self.pos = self.pos + #word
		return true, value
	end
	return false
end

function Parser:readString()
	self.pos = self.pos + 1
	local buf = {}
	while true do
		local c = self.text:sub(self.pos, self.pos)
		if c == "" then self:fail("unterminated string") end
		if c == '"' then
			self.pos = self.pos + 1
			return table.concat(buf)
		end
		if c == "\\" then
			local esc = self.text:sub(self.pos + 1, self.pos + 1)
			self.pos = self.pos + 2
			if esc == "n" then buf[#buf + 1] = "\n"
			elseif esc == "t" then buf[#buf + 1] = "\t"
			elseif esc == "r" then buf[#buf + 1] = "\r"
			elseif esc == "b" then buf[#buf + 1] = "\b"
			elseif esc == "f" then buf[#buf + 1] = "\f"
			elseif esc == "/" then buf[#buf + 1] = "/"
			elseif esc == '"' then buf[#buf + 1] = '"'
			elseif esc == "\\" then buf[#buf + 1] = "\\"
			elseif esc == "u" then
				local hex = self.text:sub(self.pos, self.pos + 3)
				self.pos = self.pos + 4
				local code = tonumber(hex, 16) or 63
				if code < 128 then
					buf[#buf + 1] = string.char(code)
				elseif code < 2048 then
					buf[#buf + 1] = string.char(192 + math.floor(code / 64), 128 + (code % 64))
				else
					buf[#buf + 1] = string.char(
						224 + math.floor(code / 4096),
						128 + (math.floor(code / 64) % 64),
						128 + (code % 64)
					)
				end
			else
				self:fail("bad escape \\" .. esc)
			end
		else
			buf[#buf + 1] = c
			self.pos = self.pos + 1
		end
	end
end

function Parser:readValue()
	self:skip()
	local c = self.text:sub(self.pos, self.pos)
	if c == "" then self:fail("unexpected end of input") end
	if c == "{" then
		self.pos = self.pos + 1
		local out = {}
		self:skip()
		if self.text:sub(self.pos, self.pos) == "}" then
			self.pos = self.pos + 1
			return out
		end
		while true do
			self:skip()
			if self.text:sub(self.pos, self.pos) ~= '"' then self:fail("expected object key") end
			local key = self:readString()
			self:skip()
			if self.text:sub(self.pos, self.pos) ~= ":" then self:fail("expected ':'") end
			self.pos = self.pos + 1
			-- A null value leaves no key at all, matching JSONDecode.
			out[key] = self:readValue()
			self:skip()
			local sep = self.text:sub(self.pos, self.pos)
			self.pos = self.pos + 1
			if sep == "}" then return out end
			if sep ~= "," then self:fail("expected ',' or '}'") end
		end
	elseif c == "[" then
		self.pos = self.pos + 1
		local out = {}
		self:skip()
		if self.text:sub(self.pos, self.pos) == "]" then
			self.pos = self.pos + 1
			return out
		end
		local index = 1
		while true do
			out[index] = self:readValue()
			index = index + 1
			self:skip()
			local sep = self.text:sub(self.pos, self.pos)
			self.pos = self.pos + 1
			if sep == "]" then return out end
			if sep ~= "," then self:fail("expected ',' or ']'") end
		end
	elseif c == '"' then
		return self:readString()
	else
		local ok, value = self:literal("true", true)
		if ok then return value end
		ok, value = self:literal("false", false)
		if ok then return value end
		ok = self:literal("null", nil)
		if ok then return nil end
		local numText = self.text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", self.pos)
		if not numText or numText == "" then self:fail("unexpected character '" .. c .. "'") end
		self.pos = self.pos + #numText
		return tonumber(numText)
	end
end

function M.decode(text)
	if type(text) ~= "string" then error("JSONDecode expects a string", 0) end
	local parser = Parser.new(text)
	local value = parser:readValue()
	parser:skip()
	if parser.pos <= #parser.text then parser:fail("trailing content") end
	return value
end

return M
