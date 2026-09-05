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

	-- Inline spans, applied to already-escaped text. Order matters: the two-marker
	-- forms are consumed before the one-marker forms, or **bold** turns into an
	-- italic asterisk.
	function M.inline(text)
		local out = M.escape(text)
		local codeColour = "#" .. theme.color.accentHot:ToHex()

		-- Inline code first: its contents must not then be read as emphasis.
		local codeSpans = {}
		out = out:gsub("`([^`\n]+)`", function(inner)
			codeSpans[#codeSpans + 1] = inner
			return "\1CODE" .. tostring(#codeSpans) .. "\1"
		end)

		out = out:gsub("%*%*%*(.-)%*%*%*", "<b><i>%1</i></b>")
		out = out:gsub("%*%*(.-)%*%*", "<b>%1</b>")
		out = out:gsub("___(.-)___", "<b><i>%1</i></b>")
		out = out:gsub("__(.-)__", "<b>%1</b>")
		-- Single-marker emphasis only when the marker is not part of a word, so
		-- snake_case and a bare 2*3 survive.
		out = out:gsub("%f[%*]%*([^%*\n]+)%*%f[^%*]", "<i>%1</i>")
		out = out:gsub("%f[_]_([^_\n]+)_%f[^_]", "<i>%1</i>")
		out = out:gsub("~~(.-)~~", "<s>%1</s>")

		-- Links render as their label plus the target, because nothing in a Roblox
		-- text label can be clicked.
		out = out:gsub("%[([^%]]+)%]%((%S-)%)", function(label, href)
			return string.format("<b>%s</b> <font color=\"%s\">%s</font>", label, "#" .. theme.color.textTertiary:ToHex(), href)
		end)

		out = out:gsub("\1CODE(%d+)\1", function(index)
			local inner = codeSpans[tonumber(index)] or ""
			-- RichText's `face` attribute takes an Enum.Font name and knows nothing about
			-- FontFace, so the theme publishes the legacy name of whichever code family is
			-- selected. It said "Code" unconditionally before, which meant switching the
			-- code font changed fenced blocks and left every inline span behind.
			return string.format('<font color="%s"><font face="%s">%s</font></font>',
				codeColour, theme.codeFontEnumName or "Code", inner)
		end)

		return out
	end

	-- Splits a reply into blocks the renderer can lay out:
	--   { kind = "text",    text = "..." }             inline markdown, RichText-ready
	--   { kind = "code",    text = "...", lang = "" }  verbatim, monospace
	--   { kind = "bullets", items = { { text, marker, depth }, ... } }
	--   { kind = "quote",   text = "..." }             an aside, inline markdown
	--   { kind = "heading", text = "...", level = 1 }
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

		for _, line in ipairs(lines) do
			local fence, lang = line:match("^%s*(```+)%s*(%a*)")
			if code then
				if fence and #fence >= #codeFence then
					blocks[#blocks + 1] = { kind = "code", text = table.concat(code, "\n"), lang = codeLang }
					code, codeLang, codeFence = nil, nil, nil
				else
					code[#code + 1] = line
				end
			elseif fence then
				flushParagraph()
				flushBullets()
				flushQuote()
				code, codeLang, codeFence = {}, (lang ~= "" and lang or nil), fence
			else
				local heading, headingText = line:match("^%s*(#+)%s+(.*)$")
				local quoted = line:match("^%s*>%s?(.*)$")
				local bullet = line:match("^%s*[%-%*%+]%s+(.*)$")
				local number, ordered = line:match("^%s*(%d+)[%.%)]%s+(.*)$")
				if heading then
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
