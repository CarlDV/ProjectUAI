-- Markdown, as much of it as a chat reply actually uses.
--
-- Model output arrives with fences, inline code, emphasis, bullets and the
-- occasional heading. Stripping all of it -- which is what the reference client
-- did -- turns a code answer into an unreadable run of text; rendering it with a
-- full parser is far more machinery than a transcript needs.
--
-- So: a block splitter that pulls fenced code out intact, and an inline pass that
-- converts the rest to RichText. Everything that goes into RichText is escaped
-- first, because a reply containing a literal < would otherwise silently eat the
-- text after it.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")

	local M = {}

	function M.escape(text)
		return (tostring(text)
			:gsub("&", "&amp;")
			:gsub("<", "&lt;")
			:gsub(">", "&gt;")
			:gsub('"', "&quot;")
			:gsub("'", "&apos;"))
	end

	-- Index exact-length backtick runs once. Unmatched openers stay literal; a
	-- backslash inside a code span cannot escape its closing delimiter. Sharing
	-- this index with pipe splitting keeps the two interpretations in agreement.
	local function codeRuns(text)
		local runs, following, indexed = {}, {}, {}
		for start, ticks, after in text:gmatch("()(`+)()") do
			runs[#runs + 1] = { start = start, after = after, width = #ticks }
		end
		for index = #runs, 1, -1 do
			local run = runs[index]
			run.close = following[run.width]
			-- Escaping the first tick leaves the rest of a run eligible to open a
			-- span. Closers still have to match a complete, unshortened run.
			if run.width > 1 then
				indexed[run.start + 1] = { after = run.after, close = following[run.width - 1] }
			end
			following[run.width] = run
			indexed[run.start] = run
		end
		return indexed
	end

	-- Inline spans, applied to already-escaped text. Order matters: the two-marker
	-- forms are consumed before the one-marker forms, or **bold** turns into an
	-- italic asterisk.
	function M.inline(text)
		text = tostring(text or "")
		local codeColour = "#" .. theme.color.accentHot:ToHex()

		-- Protect both code and backslash escapes before emphasis. Pick a sentinel
		-- absent from the input so literal control characters cannot forge a slot.
		local sentinel = "\1"
		while text:find(sentinel, 1, true) do sentinel = sentinel .. "\1" end
		local spans, parts, runs = {}, {}, codeRuns(text)
		local function protect(value)
			spans[#spans + 1] = value
			parts[#parts + 1] = sentinel .. tostring(#spans) .. sentinel
		end
		local index = 1
		while index <= #text do
			local char, nextChar = text:sub(index, index), text:sub(index + 1, index + 1)
			local run = runs[index]
			if char == "\\" and nextChar:match("%p") then
				protect(M.escape(nextChar))
				index = index + 2
			elseif run and run.close then
				local inner = text:sub(run.after, run.close.start - 1):gsub("[\r\n]", " ")
				if inner:sub(1, 1) == " " and inner:sub(-1) == " " and inner:find("[^ ]") then
					inner = inner:sub(2, -2)
				end
				protect(string.format('<font color="%s"><font face="%s">%s</font></font>',
					codeColour, theme.codeFontEnumName or "Code", M.escape(inner)))
				index = run.close.after
			else
				local after = run and run.after or (index + 1)
				parts[#parts + 1] = M.escape(text:sub(index, after - 1))
				index = after
			end
		end
		local out = table.concat(parts)

		out = out:gsub("%*%*%*(.-)%*%*%*", "<b><i>%1</i></b>")
		out = out:gsub("%*%*(.-)%*%*", "<b>%1</b>")
		-- Word-internal underscores are literal identifier separators. A frontier
		-- around underscore alone does not distinguish foo_bar_baz from emphasis.
		local function underscoreSpans(marker, innerPattern, opening, closing)
			local padded = " " .. out .. " "
			local pattern = "([^%w_])" .. marker .. innerPattern .. marker .. "([^%w_])"
			while true do
				local nextText, count = padded:gsub(pattern, function(left, inner, right)
					return left .. opening .. inner .. closing .. right
				end)
				padded = nextText
				if count == 0 then break end
				-- Adjacent spans share boundary whitespace; another pass picks up
				-- the neighbour without swallowing the separator.
			end
			out = padded:sub(2, -2)
		end
		underscoreSpans("___", "(.-)", "<b><i>", "</i></b>")
		underscoreSpans("__", "(.-)", "<b>", "</b>")
		out = out:gsub("%f[%*]%*([^%*\n]+)%*%f[^%*]", "<i>%1</i>")
		underscoreSpans("_", "([^_\n]+)", "<i>", "</i>")
		out = out:gsub("~~(.-)~~", "<s>%1</s>")

		-- Links render as their label plus the target, because nothing in a Roblox
		-- text label can be clicked.
		out = out:gsub("%[([^%]]+)%]%((%S-)%)", function(label, href)
			return string.format("<b>%s</b> <font color=\"%s\">%s</font>", label, "#" .. theme.color.textTertiary:ToHex(), href)
		end)

		out = out:gsub(sentinel .. "(%d+)" .. sentinel, function(slot)
			return spans[tonumber(slot)]
		end)

		return out
	end

	-- A small lexical pass for code readability. Source is always escaped, including
	-- unknown languages and large listings. Copying still uses the original string.
	local KEYWORDS = {}
	for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while "
		.. "export type typeof continue const let var async await class extends import from new null undefined "
		.. "try catch finally throw switch case default def elif except pass with as is None True False"):gmatch("%S+") do
		KEYWORDS[word] = true
	end

	local LUA_KEYWORDS = {}
	for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while "
		.. "export type typeof continue"):gmatch("%S+") do
		LUA_KEYWORDS[word] = true
	end

	function M.highlight(source, language)
		local text = tostring(source or "")
		local lang = tostring(language or ""):lower()
		local lua = lang == "lua" or lang == "luau"
		local json = lang == "json" or lang == "jsonc"
		local python = lang == "python" or lang == "py"
		local js = lang == "javascript" or lang == "js" or lang == "typescript" or lang == "ts"
		if #text > 32000 or not (lua or json or python or js) then return M.escape(text) end
		local out, index = {}, 1
		local function emit(value, tone)
			local escaped = M.escape(value)
			if tone then
				escaped = '<font color="#' .. theme.code[tone]:ToHex() .. '">' .. escaped .. '</font>'
			end
			out[#out + 1] = escaped
			index = index + #value
		end
		local function longEnd(start)
			local equals = text:sub(start):match("^%[(=*)%[")
			if equals == nil then return nil end
			local closing = "]" .. equals .. "]"
			local _, finish = text:find(closing, start + #equals + 2, true)
			return finish or #text
		end
		while index <= #text do
			local rest = text:sub(index)
			local first, pair = rest:sub(1, 1), rest:sub(1, 2)
			local comment = (lua and pair == "--") or (js and pair == "//")
				or (python and first == "#") or (lang == "jsonc" and pair == "//")
			if comment then
				local finish = lua and longEnd(index + 2) or nil
				finish = finish or ((text:find("\n", index, true) or (#text + 1)) - 1)
				emit(text:sub(index, finish), "comment")
			elseif js and pair == "/*" then
				local _, finish = text:find("*/", index + 2, true)
				emit(text:sub(index, finish or #text), "comment")
			elseif first == '"' or first == "'" or (js and first == string.char(96)) then
				local finish = index + 1
				while finish <= #text do
					local char = text:sub(finish, finish)
					if char == "\\" then
						finish = finish + 2
					elseif char == first then
						finish = finish + 1
						break
					else
						finish = finish + 1
					end
				end
				emit(text:sub(index, finish - 1), "string")
			elseif lua and longEnd(index) then
				emit(text:sub(index, longEnd(index)), "string")
			elseif first:match("%d") then
				local number = rest:match("^0[xX][%da-fA-F]+")
					or rest:match("^%d+%.?%d*[eE][%+%-]?%d+") or rest:match("^%d+%.?%d*")
				emit(number, "number")
			elseif first:match("[%a_]") then
				local word = rest:match("^[%w_]+")
				local keyword = lua and LUA_KEYWORDS[word] or (not lua and KEYWORDS[word])
				if json then keyword = word == "true" or word == "false" or word == "null" end
				local tone = keyword and "keyword" or nil
				if not tone and not json and rest:sub(#word + 1):match("^%s*%(") then tone = "call" end
				emit(word, tone)
			else
				emit(rest:match("^%s+") or first)
			end
		end
		return table.concat(out)
	end

	-- Cells keep inline source, including escapes, until M.inline renders them.
	-- Only structural pipes split a row. Optional outer pipes remove precisely one
	-- empty cell each, so || still represents an empty cell rather than disappearing.
	local function pipeCells(line)
		local text = util.trim(line)
		local cells, parts, pipes, runs = {}, {}, {}, codeRuns(text)
		local index = 1
		while index <= #text do
			local char = text:sub(index, index)
			local run = runs[index]
			if char == "\\" and text:sub(index + 1, index + 1):match("%p") then
				parts[#parts + 1] = text:sub(index, index + 1)
				index = index + 2
			elseif run and run.close then
				-- GFM allows \| inside code cells too; remove that table-level escape.
				parts[#parts + 1] = text:sub(index, run.close.after - 1):gsub("\\|", "|")
				index = run.close.after
			elseif char == "|" then
				cells[#cells + 1] = util.trim(table.concat(parts))
				parts = {}
				pipes[#pipes + 1] = index
				index = index + 1
			else
				local after = run and run.after or (index + 1)
				parts[#parts + 1] = text:sub(index, after - 1)
				index = after
			end
		end
		cells[#cells + 1] = util.trim(table.concat(parts))
		if pipes[#pipes] == #text then table.remove(cells) end
		if pipes[1] == 1 then table.remove(cells, 1) end
		return cells, #pipes > 0
	end

	local function fenceOf(line)
		local fence, tail = line:match("^%s*(```+)(.*)$")
		if not fence then fence, tail = line:match("^%s*(~~~+)(.*)$") end
		return fence, tail
	end

	local function interruptsTable(line)
		return util.trim(line) == "" or fenceOf(line) ~= nil
			or line:match("^%s*#+%s+") or line:match("^%s*>")
			or line:match("^%s*[%-%*%+]%s+") or line:match("^%s*%d+[%.%)]%s+")
			or (line:match("^%s*[%-%*_][%s%-%*_]*$") and #util.trim(line) >= 3)
	end

	local function tableAt(lines, index)
		if not lines[index + 1] then return nil end
		local header, headerPipes = pipeCells(lines[index])
		local delimiter, delimiterPipes = pipeCells(lines[index + 1])
		if #header == 0 or #header ~= #delimiter or not (headerPipes or delimiterPipes) then return nil end
		local align = {}
		for column, cell in ipairs(delimiter) do
			-- GFM permits one or more hyphens, with at most one colon per edge.
			if not cell:match("^:?-+:?$") then return nil end
			local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
			align[column] = right and (left and "center" or "right") or "left"
		end
		local rows, source, columns = {}, { lines[index], lines[index + 1] }, #header
		local after = index + 2
		while lines[after] and not interruptsTable(lines[after]) do
			local cells = pipeCells(lines[after])
			rows[#rows + 1] = cells
			source[#source + 1] = lines[after]
			columns = math.max(columns, #cells)
			after = after + 1
		end
		-- Missing cells are empty. Unlike GFM's lossy extra-cell rule, retain excess
		-- cells in unnamed columns: model output must never silently lose values.
		for column = #header + 1, columns do header[column], align[column] = "", "left" end
		for _, row in ipairs(rows) do
			for column = #row + 1, columns do row[column] = "" end
		end
		return { kind = "table", header = header, rows = rows, align = align,
			columns = columns, text = table.concat(source, "\n") }, after
	end

	-- Splits a reply into blocks the renderer can lay out:
	--   { kind = "text",    text = "..." }             inline markdown, RichText-ready
	--   { kind = "code",    text = "...", lang = "" }  verbatim, monospace
	--   { kind = "bullets", items = { { text, marker, depth }, ... } }
	--   { kind = "quote",   text = "..." }             an aside, inline markdown
	--   { kind = "heading", text = "...", level = 1 }
	--   { kind = "table", header = { ... }, rows = { { ... }, ... },
	--     align = { "left", "center", "right", ... }, columns = N, text = source }
	--   { kind = "rule" }
	--
	-- A bullet item is a table rather than a string because a numbered list has to keep
	-- its numbers. It used to drop them: `1.` and `-` both landed in the same array of
	-- bare strings and both painted as a dot, so every ordered list in a reply came out
	-- as an unordered one -- which is a real loss of meaning when the list is steps.
	function M.blocks(source)
		local blocks = {}
		local lines = util.lines(tostring(source or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))

		local paragraph, bullets, code, quote = {}, nil, nil, nil
		local codeLang, codeFence = nil, nil

		local function flushParagraph()
			if #paragraph == 0 then return end
			local text = util.trim(table.concat(paragraph, "\n"))
			if text ~= "" then blocks[#blocks + 1] = { kind = "text", text = text } end
			paragraph = {}
		end

		local function flushBullets()
			if not bullets or #bullets == 0 then
				bullets = nil
				return
			end
			blocks[#blocks + 1] = { kind = "bullets", items = bullets }
			bullets = nil
		end

		local function flushQuote()
			if not quote or #quote == 0 then
				quote = nil
				return
			end
			blocks[#blocks + 1] = { kind = "quote", text = util.trim(table.concat(quote, "\n")) }
			quote = nil
		end

		-- Two spaces per level, which is what every generator emits and what the
		-- renderer indents by.
		local function depthOf(line)
			local indent = line:match("^([ \t]*)") or ""
			indent = indent:gsub("\t", "  ")
			return math.min(math.floor(#indent / 2), 3)
		end

		local index = 1
		while index <= #lines do
			local line = lines[index]
			local fence, tail = fenceOf(line)
			if code then
				if fence and fence:sub(1, 1) == codeFence:sub(1, 1)
					and #fence >= #codeFence and util.trim(tail) == "" then
					blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n"), lang = codeLang }
					code, codeLang, codeFence = nil, nil, nil
				else
					code[#code + 1] = line
				end
			elseif fence then
				flushParagraph()
				flushBullets()
				flushQuote()
				code, codeLang, codeFence = {}, tail:match("^%s*(%S+)"), fence
			else
				local heading, headingText = line:match("^%s*(#+)%s+(.*)$")
				local quoted = line:match("^%s*>%s?(.*)$")
				local bullet = line:match("^%s*[%-%*%+]%s+(.*)$")
				local number, ordered = line:match("^%s*(%d+)[%.%)]%s+(.*)$")
				local tabular, after
				if not interruptsTable(line) then tabular, after = tableAt(lines, index) end
				if tabular then
					flushParagraph()
					flushBullets()
					flushQuote()
					blocks[#blocks + 1] = tabular
					index = after - 1
				elseif heading then
					flushParagraph()
					flushBullets()
					flushQuote()
					blocks[#blocks + 1] = { kind = "heading", text = headingText, level = math.min(#heading, 3) }
				elseif line:match("^%s*[%-%*_][%s%-%*_]*$") and #util.trim(line) >= 3 then
					flushParagraph()
					flushBullets()
					flushQuote()
					blocks[#blocks + 1] = { kind = "rule" }
				elseif quoted then
					flushParagraph()
					flushBullets()
					quote = quote or {}
					quote[#quote + 1] = quoted
				elseif bullet or ordered then
					flushParagraph()
					flushQuote()
					bullets = bullets or {}
					bullets[#bullets + 1] = {
						text = bullet or ordered,
						marker = number and (number .. ".") or nil,
						depth = depthOf(line),
					}
				elseif util.trim(line) == "" then
					flushParagraph()
					flushBullets()
					flushQuote()
				else
					flushBullets()
					flushQuote()
					paragraph[#paragraph + 1] = line
				end
			end
			index = index + 1
		end

		-- An unterminated fence is normal when a reply was cut off by a token limit;
		-- what is in hand still renders as code.
		if code then
			blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n"), lang = codeLang, unterminated = true }
		end
		flushParagraph()
		flushBullets()
		flushQuote()

		return blocks
	end

	-- Plain text, for a toast or a title where RichText is not wanted.
	function M.plain(source)
		local out = tostring(source or "")
			:gsub("```%a*\n?", "")
			:gsub("`", "")
			:gsub("%*%*", "")
			:gsub("^#+%s*", "")
			:gsub("\n#+%s*", "\n")
			:gsub("^>%s?", "")
			:gsub("\n>%s?", "\n")
			:gsub("%[([^%]]+)%]%(%S-%)", "%1")
		out = out:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
		return util.trim(out)
	end

	return M
end
