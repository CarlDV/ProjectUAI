-- Luau -> Lua 5.1 source transform.
--
-- LuaJIT is the only Lua interpreter available offline, so both the syntax
-- checker (test/check.lua) and the headless harness (test/run.lua) parse the
-- real .lua sources through here first.
--
-- The transform is deliberately tiny. The project's authoring rules -- no type
-- annotations, no backtick interpolation, no `continue`, no `//`, compound
-- assignment only as a standalone one-line statement -- exist so that the only
-- rewrite needed is compound assignment, and so that it never moves a line.
-- LuaJIT error line numbers therefore map 1:1 onto the original file.

local M = {}

local OPS = {
	["+="] = "+", ["-="] = "-", ["*="] = "*",
	["/="] = "/", ["%="] = "%", ["^="] = "^",
	["..="] = "..",
}

-- Byte offset -> line number, via a table of line-start offsets.
function M.lineIndex(src)
	local starts = { 1 }
	local pos = 1
	while true do
		local nl = src:find("\n", pos, true)
		if not nl then break end
		starts[#starts + 1] = nl + 1
		pos = nl + 1
	end
	return function(offset)
		local lo, hi = 1, #starts
		while lo < hi do
			local mid = math.floor((lo + hi + 1) / 2)
			if starts[mid] <= offset then lo = mid else hi = mid - 1 end
		end
		return lo
	end
end

-- Replaces every string and comment byte with a space (newlines kept) so that
-- offsets and line numbers survive. Everything left in the returned mask is
-- code, which is what the scanners below are allowed to look at.
--
-- Also returns the comment spans, because the compound-assignment rewrite has
-- to know where a trailing comment starts so it does not swallow it into the
-- parenthesised right-hand side.
function M.mask(src)
	local n = #src
	local out = {}
	for k = 1, n do out[k] = src:sub(k, k) end
	local comments = {}

	local function blank(a, b)
		for k = a, math.min(b, n) do
			if out[k] ~= "\n" then out[k] = " " end
		end
	end

	local i = 1
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i + 1, i + 1) == "-" then
			local eqs = src:match("^%-%-%[(=*)%[", i)
			local stop
			if eqs then
				local close = "]" .. eqs .. "]"
				local hit = src:find(close, i + 4 + #eqs, true)
				stop = hit and (hit + #close - 1) or n
			else
				stop = (src:find("\n", i, true) or (n + 1)) - 1
			end
			comments[#comments + 1] = { a = i, b = stop }
			blank(i, stop)
			i = stop + 1
		elseif c == "[" and src:match("^%[=*%[", i) then
			local eqs = src:match("^%[(=*)%[", i)
			local close = "]" .. eqs .. "]"
			local hit = src:find(close, i + 2 + #eqs, true)
			local stop = hit and (hit + #close - 1) or n
			blank(i, stop)
			i = stop + 1
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then
					j = j + 2
				elseif d == c or d == "\n" then
					break
				else
					j = j + 1
				end
			end
			blank(i, math.min(j, n))
			i = math.min(j, n) + 1
		else
			i = i + 1
		end
	end

	return table.concat(out), comments
end

-- Reads one Luau prefix expression (name, .field, [expr] chains) backwards from
-- `from`, returning the offset it starts at, or nil when what precedes the
-- operator is not an assignable target.
local function readTargetBack(mask, from)
	local k = from
	local function skipSpace()
		while k >= 1 and mask:sub(k, k):match("[ \t]") do k = k - 1 end
	end

	skipSpace()
	for _ = 1, 200 do
		if k < 1 then return nil end
		local c = mask:sub(k, k)
		if c == "]" then
			local depth, j = 0, k
			while j >= 1 do
				local d = mask:sub(j, j)
				if d == "]" then
					depth = depth + 1
				elseif d == "[" then
					depth = depth - 1
					if depth == 0 then break end
				end
				j = j - 1
			end
			if j < 1 then return nil end
			k = j - 1
			skipSpace()
		elseif c:match("[%w_]") then
			while k >= 1 and mask:sub(k, k):match("[%w_]") do k = k - 1 end
			skipSpace()
			if mask:sub(k, k) == "." then
				k = k - 1
				skipSpace()
			else
				return k + 1
			end
		else
			return nil
		end
	end
	return nil
end

-- Rewrites `a += b` into `a = a + (b)`. Returns the new source plus any
-- violations of the standalone-statement rule, which is what makes the rewrite
-- exact: the right-hand side is always "rest of line, minus trailing comment".
function M.expandCompound(src)
	local mask, comments = M.mask(src)
	local lineOf = M.lineIndex(src)
	local n = #mask
	local edits, errs = {}, {}

	local pos = 1
	while pos <= n do
		local op
		if mask:sub(pos, pos + 2) == "..=" then
			op = "..="
		else
			local two = mask:sub(pos, pos + 1)
			if OPS[two] and mask:sub(pos + 2, pos + 2) ~= "=" then op = two end
		end

		if not op then
			pos = pos + 1
		else
			local targetStart = readTargetBack(mask, pos - 1)
			if not targetStart then
				errs[#errs + 1] = { line = lineOf(pos), msg = "cannot read assignment target before '" .. op .. "'" }
				pos = pos + #op
			else
				local lineStart = src:sub(1, targetStart):match("()[^\n]*$") or 1
				local lead = src:sub(lineStart, targetStart - 1)
				local target = src:sub(targetStart, pos - 1):match("^%s*(.-)%s*$")

				local lineEnd = (src:find("\n", pos, true) or (n + 1)) - 1
				local rhsEnd = lineEnd
				for _, span in ipairs(comments) do
					if span.a > pos and span.a <= lineEnd and span.a - 1 < rhsEnd then
						rhsEnd = span.a - 1
					end
				end
				local rhs = src:sub(pos + #op, rhsEnd):match("^%s*(.-)%s*$")

				if lead:match("^%s*$") == nil then
					errs[#errs + 1] = {
						line = lineOf(pos),
						msg = "compound assignment must be a standalone statement on its own line",
					}
				elseif rhs == "" then
					errs[#errs + 1] = { line = lineOf(pos), msg = "compound assignment has an empty right-hand side" }
				else
					edits[#edits + 1] = {
						a = targetStart,
						b = rhsEnd,
						text = target .. " = " .. target .. " " .. OPS[op] .. " (" .. rhs .. ")",
					}
				end
				pos = rhsEnd + 1
			end
		end
	end

	for i = #edits, 1, -1 do
		local e = edits[i]
		src = src:sub(1, e.a - 1) .. e.text .. src:sub(e.b + 1)
	end
	return src, errs
end

-- Authoring rules. Every one of these is Luau-only syntax that LuaJIT cannot
-- parse, or a construct that would defeat the 1:1 line mapping. They are banned
-- project-wide rather than supported, so that 40+ files written by different
-- authors stay uniform and offline-checkable.
local BANS = {
	{ pat = "`", msg = "backtick string interpolation is banned; use string.format" },
	{ pat = "::", msg = "type casts and goto labels are banned" },
	{ pat = "%->", msg = "return type annotations are banned" },
	{ pat = "//", msg = "floor division is banned; use math.floor(a / b)" },
	{ pat = "%f[%w]continue%f[%W]", msg = "`continue` is banned; invert the condition instead" },
	{ pat = "%f[%w]goto%f[%W]", msg = "`goto` is banned" },
	{ pat = "%d_%d", msg = "digit separators are banned" },
	{ pat = "%f[%w]0[bB][01]", msg = "binary literals are banned" },
}

-- `x: Type` in a declaration or parameter list, as opposed to `obj:Method(...)`.
-- A method call is always followed by '(', '{' or a quote, so requiring the
-- character after the type name to be one of , ) = or end-of-line separates the
-- two without a real parser.
local ANNOTATION = ":%s*[%w_%.%[%]<>%|%?]+%s*[,%)=\n]"

function M.lint(src, opts)
	opts = opts or {}
	local mask = M.mask(src)
	local lineOf = M.lineIndex(src)
	local out = {}

	for _, ban in ipairs(BANS) do
		local at = 1
		while true do
			local a = mask:find(ban.pat, at)
			if not a then break end
			out[#out + 1] = { line = lineOf(a), msg = ban.msg }
			at = a + 1
		end
	end

	local at = 1
	while true do
		local a, b = mask:find(ANNOTATION, at)
		if not a then break end
		-- Skip the common false positive: a table constructor key such as
		-- `{ a = 1, b = 2 }` never reaches here, but `t[k]:sub(1, 2)` would if
		-- the closing paren followed immediately, so require no '(' inside.
		local text = mask:sub(a, b)
		if not text:find("%(") then
			out[#out + 1] = { line = lineOf(a), msg = "type annotation is banned: '" .. text:gsub("%s+", " ") .. "'" }
		end
		at = b
	end

	if not opts.entry and not src:find("\nreturn function%(") and not src:find("^return function%(") then
		out[#out + 1] = { line = 1, msg = "module must expose `return function(env)` at the top level" }
	end

	table.sort(out, function(x, y) return x.line < y.line end)
	return out
end

-- src -> loadable Lua 5.1 chunk. Returns nil plus a message when the source
-- breaks an authoring rule or fails to parse.
function M.load(src, chunkName, opts)
	local violations = M.lint(src, opts)
	if #violations > 0 then
		return nil, violations, nil
	end
	local converted, errs = M.expandCompound(src)
	if #errs > 0 then
		return nil, errs, nil
	end
	local loader = loadstring or load
	local fn, err = loader(converted, "@" .. (chunkName or "chunk"))
	if not fn then
		local line = tonumber(tostring(err):match(":(%d+):")) or 0
		return nil, { { line = line, msg = (tostring(err):match(":%d+:%s*(.*)$") or tostring(err)) } }, converted
	end
	return fn, nil, converted
end

-- Every env.require("...") target in the file, with its line, so the checker can
-- verify the module graph resolves before anything runs. A literal followed by
-- '..' is a computed path (the tool groups are loaded that way); it is reported
-- with dynamic = true so the checker treats the prefix as a hint, not a target.
function M.requires(src)
	local mask = M.mask(src)
	local lineOf = M.lineIndex(src)
	local out = {}
	local at = 1
	while true do
		local a, b = mask:find("env%.require%s*%(", at)
		if not a then break end
		-- The path lives in a string, which the mask blanked, so read it from src.
		local path, after = src:match('^%s*["\']([^"\']*)["\']()', b + 1)
		if path then
			local tail = mask:match("^%s*(%.?%.?)", after)
			out[#out + 1] = { path = path, line = lineOf(a), dynamic = tail == ".." }
		end
		at = b + 1
	end
	return out
end

return M
