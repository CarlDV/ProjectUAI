-- Transcript message renderers.
--
-- Each kind of thing that can appear in a conversation gets its own builder, and
-- each returns a handle so the view can update it later -- a tool call is created
-- when the model asks for it and completed when the result arrives, which means the
-- row has to be mutable rather than a one-shot render.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local markdown = env.require("ui/markdown")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local usage = env.require("agent/usage")

	-- How many lines of a block are shown before it folds. Generous, because the point
	-- of showing code at all is that it can be read; the fold is for a thousand-line
	-- file, not for a function.
	local CODE_LINES = 60
	local ARG_PREVIEW = 90

	-- Average glyph advance for the mono families, as a fraction of the font size.
	-- Used only to size the line-number gutter, which has to be wide enough for the
	-- largest number in the block and is the one width here that cannot come from a
	-- token: it depends on how many lines the block has.
	local MONO_RATIO = 0.62

	local M = {}

	-- Every row spans the reading column.
	--
	-- It used to leave a gutter -- 0.76 of the width for the user, 0.94 for the agent,
	-- the user's turn anchored to the right edge -- which is the chat-app convention of
	-- two speakers facing each other. This is not that: a turn here is a document with
	-- the questions marked in it, so both sides take the full measure and the
	-- difference between them is a fill, not a side. The column itself is what bounds
	-- the line length, and the panel caps that.
	local function wrapper(parent, props)
		return P.frame(parent, {
			name = props.name or "Message",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			layoutOrder = props.layoutOrder or 0,
		})
	end

	-- A left rule beside a column of wrapped text.
	--
	-- The obvious construction is a row holding a 2px frame sized (0, 2, 1, 0) and a
	-- filling label beside it. That is circular and it does not work: the row is
	-- AutomaticSize.Y, so its height comes from its children, and one of those children
	-- asks for one hundred percent of that height. Roblox excludes scale-sized children
	-- from the measurement, but the UIListLayout's flex pass has already run against an
	-- unsettled height -- which inflates the row and can leave the filling label with no
	-- width at all, so a long message renders as a tall empty box with a coral line down
	-- the side of it.
	--
	-- The holder here has no UIListLayout. The rule is positioned rather than laid out,
	-- nothing measures it, and the text sits in an ordinary column with an explicit
	-- width. Callers get the column.
	local function ruled(parent, props)
		local holder = P.frame(parent, {
			name = props.name or "Ruled",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			layoutOrder = props.layoutOrder,
			bg = props.bg,
			radius = props.radius,
			clip = props.clip,
		})
		if props.strokeColor then P.stroke(holder, props.strokeColor) end
		local width = props.width or theme.stroke.hair
		local body = P.column(holder, {
			name = "Body",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = props.gap or theme.space.xs,
			padding = {
				left = width + (props.inset or theme.space.md),
				right = props.padRight or 0,
				top = props.padY or 0,
				bottom = props.padY or 0,
			},
		})
		P.frame(holder, {
			name = "Rule",
			size = UDim2.new(0, width, 1, 0),
			position = UDim2.new(0, props.ruleAt or 0, 0, 0),
			bg = props.color or theme.color.borderSubtle,
			radius = props.ruleRadius,
			zIndex = 2,
		})
		return body, holder
	end

	-- Code: monospace below the surface of the page, with the language, a line-number
	-- gutter, a copy control and horizontal scrolling.
	--
	-- Three things changed here and each was a real loss of information. Lines wrapped,
	-- so a Luau line past the reading column folded and the indentation of everything
	-- after it read as wrong; there were no line numbers, so an error naming line 40 had
	-- nothing to point at; and anything past the fold was replaced by a dead sentence
	-- saying how much had been hidden, with no way to see it. Code is now what the model
	-- actually wrote, scrolled rather than reflowed, and the fold opens.
	function M.codeBlock(parent, props)
		local caps = env.require("runtime/caps")
		local lines = util.lines(props.text)
		if #lines == 0 then lines = { "" } end
		local numbered = props.numbers ~= false
		local role = theme.textRole("mono")
		local lineHeight = math.ceil(role.size * role.line)

		local card = P.column(parent, {
			name = "Code",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.codeSurface,
			radius = theme.radius.md,
			gap = 0,
			layoutOrder = props.layoutOrder,
			clip = true,
		})
		P.stroke(card, theme.color.codeBorder)

		local bar = P.row(card, {
			name = "Bar",
			-- As tall as the copy button inside it. P.iconButton floors its diameter at
			-- the platform hit target, which is 44 on touch, so a bar fixed at the 26px
			-- token had eighteen pixels of button hanging over the code below it -- on
			-- exactly the platform the floor exists for.
			size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget())),
			bg = theme.color.codeBar,
			gap = theme.space.xs,
			padding = { left = theme.space.md, right = theme.space.xxs },
			layoutOrder = 1,
		})
		P.text(bar, {
			name = "Language",
			text = (props.lang and props.lang:lower() or "code") .. (props.unterminated and " (incomplete)" or ""),
			role = "caption",
			color = theme.color.codeGutter,
			-- Fills rather than reserving controlSmall: the copy button is sized to
			-- max(controlSmall, minTarget()), which is 44 on touch, so the reserve was
			-- twelve pixels short on exactly the platform the minimum exists for.
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 1,
		})
		-- What is in the block, on the right of its own bar. A line count is the one
		-- fact about a block of code that is worth reading before the code itself.
		P.text(bar, {
			name = "Meta",
			text = props.meta or util.pluralise(#lines, "line"),
			role = "caption",
			color = theme.color.codeGutter,
			align = "Right",
			auto = "X",
			layoutOrder = 2,
		})

		if caps.clipboard then
			local copy = P.iconButton(bar, {
				name = "Copy",
				icon = "copy",
				diameter = theme.size.controlSmall,
				variant = "ghost",
				iconColor = theme.color.codeGutter,
				layoutOrder = 3,
				onClick = function()
					pcall(caps.fn.clipboard, props.text)
					env.require("ui/overlay").toast("Copied to clipboard", "good", 2)
				end,
			})
			copy.instance.LayoutOrder = 3
		end

		-- Body. The gutter is outside the scroll so it stays put while the code moves,
		-- which is the whole reason a sticky gutter is worth the extra frame.
		local bodyRow = P.row(card, {
			name = "Body",
			size = UDim2.new(1, 0, 0, 0),
			gap = 0,
			alignY = "Top",
			padding = { top = theme.space.sm, bottom = theme.space.sm },
			layoutOrder = 2,
		})

		local gutter, gutterLabel
		local gutterWidth = 0
		if numbered then
			-- Wide enough for the largest number in this block. It is the one width in
			-- here that cannot come from a token, because it depends on how many lines
			-- there are; the ratio is what keeps it in step with the text scale.
			gutterWidth = math.ceil(#tostring(#lines) * role.size * MONO_RATIO)
				+ theme.space.md + theme.space.sm
			gutter = P.frame(bodyRow, {
				name = "Gutter",
				size = UDim2.fromOffset(gutterWidth, 0),
				layoutOrder = 1,
			})
			gutterLabel = P.text(gutter, {
				name = "Numbers",
				text = "",
				role = "mono",
				color = theme.color.codeGutter,
				align = "Right",
				alignY = "Top",
				size = UDim2.new(1, -theme.space.sm, 1, 0),
			})
		end

		local viewport = P.scroll(bodyRow, {
			name = "Viewport",
			horizontal = true,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			gap = 0,
			padding = { right = theme.space.md },
			bar = theme.size.scrollbar,
		})
		-- Not wrapped, and sized from the text: that is what makes the gutter line up
		-- with the code beside it. A wrapped body puts two visual lines against one
		-- number, and every number below it is then wrong.
		local body = P.text(viewport.instance, {
			name = "Source",
			text = "",
			role = "mono",
			color = theme.color.codeText,
			alignY = "Top",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
		})

		local expanded = false
		local foldRow

		local function paint()
			local shown = lines
			if not expanded and #lines > CODE_LINES then
				shown = util.slice(lines, 1, CODE_LINES)
			end
			body.Text = table.concat(shown, "\n")
			if gutterLabel then
				local numbers = {}
				for index = 1, #shown do numbers[index] = tostring(index) end
				gutterLabel.Text = table.concat(numbers, "\n")
			end
			local height = #shown * lineHeight
			bodyRow.Size = UDim2.new(1, 0, 0, height + theme.space.sm * 2 + theme.size.scrollbar)
			if gutter then gutter.Size = UDim2.fromOffset(gutterWidth, height) end
			if foldRow then
				foldRow.setText(expanded
					and "Show less"
					or string.format("Show all %s", util.pluralise(#lines, "line")))
			end
		end

		if #lines > CODE_LINES then
			foldRow = P.button(card, {
				name = "Fold",
				-- Given its text up front, because P.button only builds a label when it
				-- has one to put in it -- an empty string leaves setText with nothing to
				-- write to.
				text = string.format("Show all %s", util.pluralise(#lines, "line")),
				variant = "ghost",
				size = "sm",
				fill = true,
				align = "Left",
				radius = theme.radius.none,
				layoutOrder = 3,
				onClick = function()
					expanded = not expanded
					paint()
				end,
			})
			foldRow.instance.LayoutOrder = 3
		end

		paint()
		return card
	end

	-- Renders markdown blocks into an existing column. Returned so a streaming or
	-- edited message can clear and re-render.
	function M.renderBlocks(column, text)
		for _, child in ipairs(column:GetChildren()) do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
		end

		local blocks = markdown.blocks(text)
		if #blocks == 0 then
			P.text(column, { text = "", role = "body", wrap = true, auto = "Y" })
			return
		end

		for index, block in ipairs(blocks) do
			if block.kind == "code" then
				M.codeBlock(column, {
					text = block.text,
					lang = block.lang,
					unterminated = block.unterminated,
					layoutOrder = index,
				})
			elseif block.kind == "heading" then
				-- A heading belongs to what is under it, so it needs more air above than
				-- the uniform paragraph gap gives it. Without this a section title sits
				-- exactly as far from the paragraph it introduces as from the one it ends,
				-- and a long reply reads as an undifferentiated run of text.
				local head = P.column(column, {
					name = "Heading",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = 0,
					padding = index > 1 and { top = theme.space.sm } or nil,
					layoutOrder = index,
				})
				local label = P.text(head, {
					text = markdown.inline(block.text),
					role = block.level == 1 and "title" or "heading",
					rich = true,
					wrap = true,
					auto = "Y",
				})
				label.Size = UDim2.new(1, 0, 0, 0)
			elseif block.kind == "rule" then
				P.divider(column, { layoutOrder = index })
			elseif block.kind == "quote" then
				-- An aside gets a rule down its left edge and nothing else. A tinted card
				-- would make a quoted line louder than the prose quoting it.
				local body = ruled(column, {
					name = "Quote",
					layoutOrder = index,
					color = theme.color.border,
					width = theme.stroke.focus,
				})
				local quoted = P.text(body, {
					text = markdown.inline(block.text),
					role = "body",
					color = theme.color.textSecondary,
					rich = true,
					wrap = true,
					auto = "Y",
				})
				quoted.Size = UDim2.new(1, 0, 0, 0)
			elseif block.kind == "bullets" then
				local list = P.column(column, {
					name = "List",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xxs,
					layoutOrder = index,
				})
				-- One marker column for the whole list, wide enough for its longest
				-- marker, so "9." and "10." put their text at the same x.
				local markerWidth = theme.space.md
				for _, item in ipairs(block.items) do
					if item.marker then
						markerWidth = math.max(markerWidth,
							math.ceil(#item.marker * theme.text.body.size * MONO_RATIO))
					end
				end
				for position, item in ipairs(block.items) do
					local row = P.row(list, {
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.sm,
						alignY = "Top",
						layoutOrder = position,
					})
					if (item.depth or 0) > 0 then
						P.frame(row, {
							name = "Indent",
							size = UDim2.fromOffset(item.depth * theme.space.lg, theme.text.body.height),
							layoutOrder = 1,
						})
					end
					local slot = P.frame(row, {
						name = "Marker",
						size = UDim2.fromOffset(markerWidth, theme.text.body.height),
						layoutOrder = 2,
					})
					if item.marker then
						P.text(slot, {
							text = item.marker,
							role = "body",
							color = theme.color.textTertiary,
							align = "Right",
							size = UDim2.fromScale(1, 1),
						})
					else
						P.statusDot(slot, {
							diameter = theme.size.dotSmall,
							color = theme.color.textTertiary,
							anchor = Vector2.new(1, 0.5),
							position = UDim2.fromScale(1, 0.5),
						})
					end
					P.text(row, {
						text = markdown.inline(item.text),
						role = "body",
						rich = true,
						wrap = true,
						auto = "Y",
						size = UDim2.new(0, 0, 0, 0),
						flex = "Fill",
						layoutOrder = 3,
					})
				end
			else
				local label = P.text(column, {
					text = markdown.inline(block.text),
					role = "body",
					rich = true,
					wrap = true,
					auto = "Y",
					layoutOrder = index,
				})
				label.Size = UDim2.new(1, 0, 0, 0)
			end
		end
	end

	-- The user's own turn. A fill, a hairline, and an accent rule down the left edge.
	--
	-- The rule is what makes it unmistakably a sent message. Without it the turn was a
	-- rounded surfaceRaised box with a border and a line of text in it, which is the
	-- exact description of the composer's input field twenty pixels below -- so a
	-- transcript read as a column of empty prompts rather than as a conversation.
	function M.user(parent, text, order)
		local holder = wrapper(parent, { name = "User", layoutOrder = order })
		local body = ruled(holder, {
			name = "Bubble",
			bg = theme.color.bubbleUser,
			strokeColor = theme.color.bubbleUserBorder,
			radius = theme.radius.md,
			color = theme.color.accent,
			width = theme.stroke.focus,
			ruleAt = theme.space.hair,
			ruleRadius = theme.radius.pill,
			inset = theme.space.md,
			padRight = theme.space.md,
			padY = theme.space.sm,
			clip = true,
		})
		local label = P.text(body, {
			text = tostring(text),
			role = "body",
			wrap = true,
			auto = "Y",
		})
		label.Size = UDim2.new(1, 0, 0, 0)
		return { root = holder, label = label }
	end

	function M.agent(parent, text, order)
		local holder = wrapper(parent, { name = "Agent", layoutOrder = order })
		local column = P.column(holder, {
			name = "Body",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			-- Paragraphs need more than eight pixels between them or a long reply
			-- arrives as one grey slab with no shape to it.
			gap = theme.space.md,
		})
		local handle = { root = holder, column = column }
		function handle.setText(value)
			M.renderBlocks(column, value)
		end
		handle.setText(text or "")
		return handle
	end

	-- Reasoning is a quieter register of the same page, not an object on it: a header
	-- row and muted body text, no card and no outline. It used to be a bordered panel,
	-- which gave a paragraph of thinking the same visual weight as a settings group.
	--
	-- The body now sits behind a rule and an indent. Flush left in the same measure as
	-- the reply, at 13px against the reply's 14 and one step down in colour, thinking
	-- and answer were two paragraphs that looked alike -- so a turn read as the model
	-- saying the same thing twice, which is exactly what it looks like when a model
	-- restates its conclusion in prose.
	function M.reasoning(parent, text, order)
		local holder = wrapper(parent, { name = "Reasoning", layoutOrder = order })
		local card = P.column(holder, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
		})

		local header = Instance.new("TextButton", card)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		-- A disclosure control, so it answers to the platform's hit-target floor like
		-- every other one. At max(label.height, icon) it was sixteen pixels tall, which
		-- is under the pointer minimum and well under the 44 a touch device needs.
		header.Size = UDim2.new(1, 0, 0, math.max(theme.text.label.height + theme.space.xs,
			responsive.minTarget() - theme.space.sm))
		header.LayoutOrder = 1
		header.Selectable = true

		local row = P.row(header, { size = UDim2.fromScale(1, 1), gap = theme.space.xs })
		local caret = P.frame(row, {
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 1,
		})
		icons.chevron(caret, theme.size.icon, theme.color.textTertiary, "right")
		local title = P.text(row, {
			text = "Thinking",
			role = "label",
			color = theme.color.textTertiary,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 2,
		})
		-- How much of it there is, in the unit it is billed in. A card that says only
		-- "reasoning" gives no grounds for opening it or for leaving it shut, and this
		-- is the one part of a turn whose size is otherwise invisible: reasoning is
		-- charged as output and never appears in the reply.
		P.text(row, {
			text = "~" .. util.formatNumber(usage.estimateText(text)) .. " tokens",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			auto = "X",
			layoutOrder = 3,
		})

		local asideBody, bodyRow = ruled(card, {
			name = "Aside",
			layoutOrder = 2,
			color = theme.color.borderSubtle,
			width = theme.stroke.hair,
			-- Positioned under the caret's centre line, so the rule continues the
			-- disclosure triangle above it rather than starting at the row's edge.
			ruleAt = math.floor(theme.size.icon / 2),
			inset = theme.space.md,
		})
		local body = P.text(asideBody, {
			text = markdown.plain(text),
			role = "small",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		body.Size = UDim2.new(1, 0, 0, 0)

		-- Open on arrival. The thinking is what explains the answer, and a card that
		-- hides it by default reads as though there were nothing inside; the header
		-- still folds a long one away once it has been read.
		local open = true
		caret.Rotation = 90
		local function toggle()
			open = not open
			bodyRow.Visible = open
			caret.Rotation = open and 90 or 0
		end
		header.Activated:Connect(toggle)
		-- The wrapper, not the card: hiding the card alone left its frame in the list
		-- layout, so a hidden reasoning row still pushed the reply down by its padding.
		if config.get("ui.showReasoning", true) == false then holder.Visible = false end

		return { root = holder, body = body }
	end

	-- Which argument on a call is a listing rather than a value, and what language it
	-- is in.
	--
	-- Ordered, because a call can carry more than one: file_write takes a `path` and a
	-- `content`, run_luau takes only `code`. Anything matched here is drawn as code and
	-- kept out of the key/value list, so the same string is never shown twice.
	local CODE_KEYS = {
		{ key = "code", lang = "lua" },
		{ key = "source", lang = "lua" },
		{ key = "script", lang = "lua" },
		{ key = "expression", lang = "lua" },
		{ key = "patch", lang = "diff" },
		{ key = "diff", lang = "diff" },
		-- Language from the path it is being written to, since a file_write is whatever
		-- the extension says it is.
		{ key = "content" },
		{ key = "body" },
		{ key = "text" },
	}

	local EXTENSION_LANGS = {
		lua = "lua", luau = "lua", json = "json", md = "markdown", markdown = "markdown",
		js = "javascript", ts = "typescript", py = "python", html = "html", css = "css",
		yml = "yaml", yaml = "yaml", toml = "toml", sh = "bash", xml = "xml", csv = "csv",
		rbxmx = "xml", rbxlx = "xml",
	}

	-- The fields worth putting on the header line, most identifying first. Raw JSON
	-- used to go here, which at ninety characters shows the shape of the payload and
	-- none of its meaning: `{"path":"notes/plan.txt","content":"# Pl`.
	local SUMMARY_KEYS = {
		"path", "file", "query", "url", "class", "property", "name", "id",
		"command", "task", "key", "value",
	}

	local function langForPath(path)
		local extension = tostring(path or ""):match("%.([%w]+)$")
		if not extension then return nil end
		return EXTENSION_LANGS[extension:lower()]
	end

	-- Splits decoded arguments into the listings and the scalar facts.
	local function splitArguments(args)
		local code, facts = {}, {}
		if type(args) ~= "table" then return code, facts end
		local taken = {}
		local pathHint = args.path or args.file or args.name
		for _, spec in ipairs(CODE_KEYS) do
			local value = args[spec.key]
			if type(value) == "string" and value ~= "" and not taken[spec.key] then
				-- Only a listing if there is something to look at. A one-line `text` is a
				-- value, and a code card around three words is more chrome than content.
				local multiline = value:find("\n") ~= nil
				if spec.lang or multiline then
					code[#code + 1] = {
						key = spec.key,
						text = value,
						lang = spec.lang or langForPath(pathHint),
					}
					taken[spec.key] = true
				end
			end
		end
		for _, key in ipairs(util.keys(args, true)) do
			if not taken[key] then
				local value = args[key]
				local kind = type(value)
				if kind == "string" or kind == "number" or kind == "boolean" then
					facts[#facts + 1] = { key = tostring(key), value = tostring(value) }
				elseif kind == "table" then
					-- A nested structure is still shown verbatim: it is what an
					-- instance_create property map and a remote_fire argument list are, and
					-- both were previously invisible.
					local ok, encoded = pcall(util.encode, value)
					facts[#facts + 1] = { key = tostring(key), value = ok and encoded or "(not encodable)" }
				end
			end
		end
		return code, facts
	end

	local function summarise(args, raw)
		if type(args) ~= "table" then
			return util.ellipsis(tostring(raw or ""):gsub("[\n\r]+", " "), ARG_PREVIEW)
		end
		local parts = {}
		for _, key in ipairs(SUMMARY_KEYS) do
			local value = args[key]
			if type(value) == "string" or type(value) == "number" then
				parts[#parts + 1] = tostring(value)
			end
		end
		if #parts == 0 then
			for _, key in ipairs(util.keys(args, true)) do
				local value = args[key]
				local kind = type(value)
				if kind == "string" or kind == "number" or kind == "boolean" then
					parts[#parts + 1] = key .. " " .. tostring(value)
				end
				if #parts >= 3 then break end
			end
		end
		return util.ellipsis(table.concat(parts, "  \194\183  "), ARG_PREVIEW)
	end

	-- A tool call row: a disclosure caret, a risk dot, the tool's name, what it is
	-- doing, how long it took -- and underneath, verbatim, the code it was given.
	--
	-- Flat, not a card. A turn that calls six tools was six outlined boxes stacked
	-- between two paragraphs of prose, which made the machinery louder than the answer.
	--
	-- The code is outside the fold on purpose. Every listing the model produced -- the
	-- Luau it is about to execute, the body it is about to write to a file, the property
	-- map it is about to apply -- was reachable only by opening a pane that defaulted
	-- shut and gave no sign it existed, and what showed instead was ninety characters of
	-- the JSON envelope. Arguments that are values still live behind the fold; arguments
	-- that are code do not.
	function M.toolCall(parent, info, order)
		local holder = wrapper(parent, { name = "Tool", layoutOrder = order })
		local card = P.column(holder, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
		})

		local raw = tostring(info.arguments or "")
		local decoded = util.decode(raw)
		local codeParts, facts = splitArguments(decoded)

		local header = Instance.new("TextButton", card)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, math.max(theme.size.row - theme.space.xxs,
			responsive.minTarget() - theme.space.sm))
		header.LayoutOrder = 1
		header.Selectable = true

		local row = P.row(header, {
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
		})

		-- The affordance the row never had. Without it a tool call was a line of text
		-- that happened to answer a click, so the detail pane may as well not have been
		-- there.
		local caret = P.frame(row, {
			name = "Caret",
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 1,
		})
		icons.chevron(caret, theme.size.icon, theme.color.textTertiary, "right")

		local spinner = C.spinner(row, { diameter = theme.size.icon - theme.space.hair, layoutOrder = 2 })
		local dotSlot = P.frame(row, {
			name = "DotSlot",
			size = UDim2.fromOffset(theme.size.icon - theme.space.hair, theme.size.icon - theme.space.hair),
			layoutOrder = 2,
		})
		dotSlot.Visible = false
		local dot = P.statusDot(dotSlot, {
			color = theme.riskColor(info.risk),
			diameter = theme.size.dot,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
		})

		local name = P.text(row, {
			text = tostring(info.name or "tool"),
			role = "monoSmall",
			color = theme.color.textSecondary,
			layoutOrder = 3,
		})
		name.Size = UDim2.fromOffset(0, theme.text.monoSmall.height)
		name.AutomaticSize = Enum.AutomaticSize.X

		local preview = P.text(row, {
			text = summarise(decoded, raw),
			role = "caption",
			color = theme.color.textTertiary,
			truncate = true,
			-- Takes whatever is left rather than reserving a guess. The guess was
			-- icon + 90, but the row also has to fit an auto-width tool name, so it
			-- over-committed by the width of that name and pushed `timing` out past
			-- the card's clip -- which is why a tool call never showed how long it took.
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 4,
		})

		local timing = P.text(row, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			layoutOrder = 5,
		})
		timing.Size = UDim2.fromOffset(theme.size.metaColumn, theme.text.caption.height)

		-- Always-on code, indented to the caret's centre line so it reads as belonging
		-- to the row above it.
		local codeColumn
		if #codeParts > 0 and config.get("ui.showToolCode", true) ~= false then
			codeColumn = P.column(card, {
				name = "Listing",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				padding = { left = theme.size.icon + theme.space.xs },
				layoutOrder = 2,
			})
			for index, part in ipairs(codeParts) do
				M.codeBlock(codeColumn, {
					text = part.text,
					lang = part.lang or part.key,
					layoutOrder = index,
				})
			end
		end

		local detail = P.column(card, {
			name = "Detail",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.surface,
			radius = theme.radius.md,
			gap = theme.space.sm,
			padding = theme.space.sm,
			layoutOrder = 3,
			visible = config.get("ui.showToolDetail", false) == true,
		})

		-- Arguments that are values, as a key column rather than as a wall of JSON.
		if #facts > 0 then
			local factColumn = P.column(detail, {
				name = "Arguments",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xxs,
				layoutOrder = 1,
			})
			for index, fact in ipairs(facts) do
				C.keyValue(factColumn, {
					key = fact.key,
					value = fact.value,
					role = "monoSmall",
					color = theme.color.textSecondary,
					layoutOrder = index,
				})
			end
		elseif #codeParts == 0 and util.trim(raw) ~= "" and util.trim(raw) ~= "{}" then
			-- Nothing decoded and nothing recognised: show what actually arrived. A model
			-- that emits malformed arguments is a thing worth being able to see.
			M.codeBlock(detail, {
				text = raw,
				lang = "json",
				numbers = false,
				layoutOrder = 1,
			})
		end

		local resultHolder = P.column(detail, {
			name = "Result",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xxs,
			layoutOrder = 3,
			visible = false,
		})

		local open = detail.Visible
		local function setOpen(value)
			open = value == true
			detail.Visible = open
			caret.Rotation = open and 90 or 0
		end
		setOpen(open)
		header.Activated:Connect(function() setOpen(not open) end)

		local handle = { root = holder, card = card }
		local nested

		-- Where a tool that runs an agent of its own puts its live feed. Sits between the
		-- arguments and the result, which is the order it happens in, and forces the
		-- detail pane open: a row with something moving inside it should not be the one
		-- thing hiding it.
		function handle.nest()
			if not nested then
				nested = P.column(detail, {
					name = "Nested",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					layoutOrder = 2,
				})
			end
			setOpen(true)
			return nested
		end

		function handle.progress(text)
			preview.Text = util.ellipsis(tostring(text), ARG_PREVIEW)
		end

		-- A call whose result is not in this transcript.
		--
		-- Restored conversations can have one: the stored log keeps the most recent 300
		-- durable events, so a long transcript can begin part-way through a turn. It is
		-- not a failure and must not be drawn as one, but the row cannot be left spinning
		-- either -- a spinner that never stops reads as a hung agent.
		function handle.stale()
			pcall(function() spinner:Destroy() end)
			dotSlot.Visible = true
			dot.BackgroundColor3 = theme.color.textDisabled
			timing.Text = ""
			resultHolder.Visible = true
			local note = P.text(resultHolder, {
				name = "ResultLabel",
				text = "No result in the stored transcript.",
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 1,
			})
			note.Size = UDim2.new(1, 0, 0, 0)
		end

		function handle.finish(result)
			pcall(function() spinner:Destroy() end)
			dotSlot.Visible = true
			if result.ok then
				dot.BackgroundColor3 = theme.riskColor(info.risk)
			else
				dot.BackgroundColor3 = result.denied and theme.color.warn or theme.color.danger
			end
			timing.Text = result.ms and util.formatDuration(result.ms) or ""
			local text = tostring(result.text or "")
			preview.Text = util.ellipsis(text:gsub("[\n\r]+", " "), ARG_PREVIEW)
			preview.TextColor3 = result.ok and theme.color.textTertiary or theme.color.danger

			resultHolder.Visible = true
			local label = P.text(resultHolder, {
				name = "ResultLabel",
				text = result.ok and "result" or "failed",
				role = "label",
				color = result.ok and theme.color.textTertiary or theme.color.danger,
				auto = "Y",
				layoutOrder = 1,
			})
			label.Size = UDim2.new(1, 0, 0, theme.text.label.height)
			-- Multi-line output is a listing -- a file's contents, a print capture, a
			-- stack trace -- and gets the same numbered surface the arguments do. One
			-- line is a sentence and gets read as one.
			if text:find("\n") then
				M.codeBlock(resultHolder, {
					text = text,
					lang = "output",
					layoutOrder = 2,
				})
			else
				local body = P.text(resultHolder, {
					text = text,
					role = "monoSmall",
					color = result.ok and theme.color.textSecondary or theme.color.danger,
					wrap = true,
					auto = "Y",
					layoutOrder = 2,
				})
				body.Size = UDim2.new(1, 0, 0, 0)
			end
			if result.truncated then
				local note = P.text(resultHolder, {
					text = "Trimmed before the model saw it.",
					role = "caption",
					color = theme.color.warn,
					wrap = true,
					auto = "Y",
					layoutOrder = 3,
				})
				note.Size = UDim2.new(1, 0, 0, 0)
			end
			-- A failure the user cannot see is a failure they cannot act on, so an error
			-- opens its own pane. A success does not: that is what the fold is for.
			if not result.ok then setOpen(true) end
		end

		return handle
	end

	-- A subagent's live feed.
	--
	-- The parent pays for one paragraph of report, but the user should still be able to
	-- watch the work. From outside, a delegated task is a spinner on a row that says
	-- nothing, which is indistinguishable from a hang -- and three of them at once are
	-- indistinguishable from each other. So each dispatch gets a card that fills in as
	-- its child works: every tool it calls, what it said between calls, the report at
	-- the end.
	--
	-- Driven by events forwarded onto the parent's stream rather than by reaching into
	-- the child session, so it replays from the log like every other row. Switching
	-- panel mid-dispatch and coming back shows the same feed, not an empty box.
	function M.subagent(parent, info, order, opts)
		opts = opts or {}
		local holder = wrapper(parent, { name = "Subagent", layoutOrder = order })
		local card = P.column(holder, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xxs,
			clip = true,
		})

		local header = Instance.new("TextButton", card)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, math.max(theme.size.row - theme.space.xxs,
			responsive.minTarget() - theme.space.sm))
		header.LayoutOrder = 1
		header.Selectable = true

		local row = P.row(header, {
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
		})

		local spinner = C.spinner(row, { diameter = theme.size.icon - theme.space.hair, layoutOrder = 1 })
		local dotSlot = P.frame(row, {
			name = "DotSlot",
			size = UDim2.fromOffset(theme.size.icon - theme.space.hair, theme.size.icon - theme.space.hair),
			layoutOrder = 1,
		})
		dotSlot.Visible = false
		local dot = P.statusDot(dotSlot, {
			color = theme.color.accent,
			diameter = theme.size.dot,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
		})

		local kindLabel = P.text(row, {
			text = "agent",
			role = "monoSmall",
			color = theme.color.accent,
			layoutOrder = 2,
		})
		kindLabel.Size = UDim2.fromOffset(0, theme.text.monoSmall.height)
		kindLabel.AutomaticSize = Enum.AutomaticSize.X
		local title = P.text(row, {
			text = tostring(info.label or "task"),
			role = "caption",
			color = theme.color.textSecondary,
			truncate = true,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 3,
		})

		local meta = P.text(row, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			layoutOrder = 4,
		})
		meta.Size = UDim2.fromOffset(theme.size.metaColumnWide, theme.text.caption.height)

		local feed = P.column(card, {
			name = "Feed",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			-- A nested card sits inside a tool row's detail pane, which is already on
			-- `surface`, so the feed has to step up again or the two are the same colour
			-- and the card loses its edge.
			bg = opts.nested and theme.color.surfaceRaised or theme.color.surface,
			radius = theme.radius.md,
			gap = theme.space.xxs,
			padding = theme.space.sm,
			layoutOrder = 2,
		})

		local status = P.text(feed, {
			text = "Starting",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = 1,
		})
		status.Visible = false
		status.Size = UDim2.new(1, 0, 0, 0)

		-- The feed is open while the work happens, which is the whole point of it. The
		-- header still toggles, because a finished subagent's feed is history and a
		-- conversation with six of them in it should be collapsible.
		local open = true
		header.Activated:Connect(function()
			open = not open
			feed.Visible = open
		end)
		local rows = {}
		local slot = 1
		local function nextSlot()
			slot = slot + 1
			return slot
		end

		local function line(text, colour, role)
			local label = P.text(feed, {
				text = tostring(text),
				role = role or "caption",
				color = colour or theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = nextSlot(),
			})
			label.Size = UDim2.new(1, 0, 0, 0)
			return label
		end

		local started = clock.ms()
		local calls, finished, finalMs = 0, 0, nil

		local function paintMeta()
			local bits = {}
			if calls > 0 then bits[#bits + 1] = string.format("%d/%d", finished, calls) end
			local waited = finalMs or clock.since(started)
			if waited >= 1000 then bits[#bits + 1] = util.formatDuration(waited) end
			meta.Text = table.concat(bits, "  ")
		end

		-- One timer for the clock, stopped when the subagent reports back. Same reason
		-- the working row has one: a number that moves is what separates "this is taking
		-- a while" from "this is stuck", and a subagent takes minutes.
		local stop = clock.interval(0.5, function()
			if not finalMs then paintMeta() end
		end)
		holder.Destroying:Connect(function() pcall(stop) end)
		local handle = { root = holder, card = card }

		function handle.status(event)
			local text = util.trim(tostring(event.text or ""))
			if text == "" or text == "Ready" then return end
			status.Visible = true
			status.Text = text
			status.TextColor3 = event.bad and theme.color.danger or theme.color.textTertiary
		end

		function handle.say(event)
			local text = util.trim(tostring(event.text or ""))
			if text == "" then return end
			line(text, theme.color.textSecondary, "small")
		end

		-- One line per tool the child calls, keyed by the child's own call id so the
		-- result can land on the row that asked for it -- plus, underneath, whatever code
		-- that call was handed.
		--
		-- The line collapses to a summary and the listing is drawn in full, which is the
		-- same treatment a top-level call gets. Before, the child's arguments arrived
		-- already cut to 160 whitespace-collapsed characters and there was nowhere else to
		-- look: a headless session keeps no log, so a subagent's work was the one thing in
		-- this client that could not be read back.
		function handle.tool(event)
			calls = calls + 1
			local toolRow = P.row(feed, {
				size = UDim2.new(1, 0, 0, theme.text.monoSmall.height),
				gap = theme.space.xs,
				layoutOrder = nextSlot(),
			})
			P.statusDot(toolRow, {
				color = theme.riskColor(event.risk),
				diameter = theme.size.dotSmall,
				layoutOrder = 1,
			})
			local name = P.text(toolRow, {
				text = tostring(event.name or "tool"),
				role = "monoSmall",
				color = theme.color.textSecondary,
				layoutOrder = 2,
			})
			name.Size = UDim2.fromOffset(0, theme.text.monoSmall.height)
			name.AutomaticSize = Enum.AutomaticSize.X
			local raw = tostring(event.arguments or "")
			local decoded = util.decode(raw)
			local args = P.text(toolRow, {
				text = summarise(decoded, raw),
				role = "caption",
				color = theme.color.textTertiary,
				truncate = true,
				size = UDim2.new(0, 0, 1, 0),
				flex = "Fill",
				layoutOrder = 3,
			})
			local timing = P.text(toolRow, {
				text = "",
				role = "caption",
				color = theme.color.textTertiary,
				align = "Right",
				layoutOrder = 4,
			})
			timing.Size = UDim2.fromOffset(theme.size.metaColumn, theme.text.caption.height)
			if config.get("ui.showToolCode", true) ~= false then
				local codeParts = splitArguments(decoded)
				for _, part in ipairs(codeParts) do
					M.codeBlock(feed, {
						text = part.text,
						lang = part.lang or part.key,
						layoutOrder = nextSlot(),
					})
				end
			end
			rows[tostring(event.callId or calls)] = { args = args, timing = timing }
			paintMeta()
		end
		function handle.toolDone(event)
			finished = finished + 1
			local entry = rows[tostring(event.callId or "")]
			if entry then
				entry.timing.Text = event.ms and util.formatDuration(event.ms) or ""
				local summary = util.trim(tostring(event.summary or ""))
				if summary ~= "" then entry.args.Text = summary end
				if not event.ok then entry.args.TextColor3 = theme.color.danger end
			end
			paintMeta()
		end

		function handle.finish(event)
			finalMs = event.ms or clock.since(started)
			pcall(stop)
			pcall(function() spinner:Destroy() end)
			dotSlot.Visible = true
			if event.aborted then
				dot.BackgroundColor3 = theme.color.warn
			elseif event.ok == false then
				dot.BackgroundColor3 = theme.color.danger
			else
				dot.BackgroundColor3 = theme.color.accent
			end
			paintMeta()
			status.Visible = true
			if event.aborted then
				status.Text = "Stopped before it finished."
			elseif event.ok == false then
				status.Text = tostring(event.text or "Failed.")
			else
				status.Text = string.format("Reported back after %s over %s.",
					util.formatDuration(finalMs), util.pluralise(event.messages or 0, "message"))
			end
			if event.ok ~= false and util.trim(tostring(event.text or "")) ~= "" then
				line(tostring(event.text), theme.color.text, "small")
			end
		end

		-- The same sweep the tool rows get: a dispatch whose report is not in the stored
		-- transcript stops spinning and says so, rather than counting up forever.
		function handle.stale()
			pcall(stop)
			pcall(function() spinner:Destroy() end)
			dotSlot.Visible = true
			dot.BackgroundColor3 = theme.color.textDisabled
			finalMs = finalMs or clock.since(started)
			paintMeta()
			status.Visible = true
			status.Text = "No report in the stored transcript."
		end

		paintMeta()
		return handle
	end

	-- An inline note: a retry, a provider switch, a compaction, an error.
	--
	-- Only a bad one gets a fill. The rest are ordinary events in the life of a turn
	-- and were each arriving as a tinted panel, so a conversation that retried twice
	-- and compacted once read as three warnings rather than as three footnotes.
	function M.notice(parent, props, order)
		local tone = props.tone or "info"
		local holder = wrapper(parent, { name = "Notice", layoutOrder = order })
		local bad = tone == "bad"
		local row = P.row(holder, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = bad and theme.color.dangerSurface or nil,
			radius = bad and theme.radius.md or nil,
			gap = theme.space.xs,
			-- Padded either way, so a bad notice does not indent its own text eight pixels
			-- further than the plain one above it. The fill is what marks it, not the inset.
			padding = { x = bad and theme.space.sm or 0, y = bad and theme.space.xs or 0 },
			alignY = "Top",
		})
		-- The same slot width the tool and reasoning rows put their caret in, so every
		-- top-level row in the transcript starts its text at one x. This was a bare 4px
		-- dot: a notice's text began twelve pixels left of the tool call above it.
		local dotSlot = P.frame(row, {
			name = "DotSlot",
			size = UDim2.fromOffset(theme.size.icon, theme.text.small.height),
			layoutOrder = 1,
		})
		P.statusDot(dotSlot, {
			color = theme.toneColor(tone),
			diameter = theme.size.dotSmall,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
		})
		local label = P.text(row, {
			text = tostring(props.text),
			role = "small",
			color = bad and theme.color.danger or theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			size = UDim2.new(0, 0, 0, 0),
			flex = "Fill",
			layoutOrder = 2,
		})
		return { root = holder, label = label }
	end

	-- The working indicator: one row that reports the current status text, replaced
	-- by the answer when the turn ends. It carries the two signals that separate
	-- "thinking" from "hung" -- a label that moves and a clock that counts up --
	-- because the HTTP call it covers can take a minute and says nothing while it
	-- does.
	function M.working(parent, order)
		local holder = wrapper(parent, { name = "Working", layoutOrder = order })
		local rowHeight = math.max(theme.size.row - theme.space.xs, theme.text.small.height)
		local row = P.row(holder, {
			size = UDim2.new(1, 0, 0, rowHeight),
			gap = theme.space.xs,
		})
		C.spinner(row, { diameter = theme.size.icon, layoutOrder = 1 })
		local label = P.text(row, {
			text = "Thinking",
			role = "small",
			color = theme.color.textSecondary,
			-- Fills, rather than subtracting the spinner and the clock by hand. That
			-- remainder was three numbers deep and one of them was a literal 52 that
			-- also appeared, separately, as the clock's own width.
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 2,
		})
		local elapsed = P.text(row, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			layoutOrder = 3,
		})
		elapsed.Size = UDim2.fromOffset(theme.size.metaColumn, rowHeight)

		local handle = { root = holder, label = label }
		local base = "Thinking"
		local started = clock.ms()
		local frame = 0
		-- One timer drives both, so the trailing dots and the clock stay in step.
		local stop = clock.interval(0.4, function()
			frame = frame + 1
			if not responsive.reduceMotion then
				label.Text = base .. string.rep(".", frame % 4)
			end
			local waited = clock.since(started)
			if waited >= 1000 then elapsed.Text = util.formatDuration(waited) end
		end)
		holder.Destroying:Connect(function() pcall(stop) end)

		-- The status text is the base the dots are appended to, not the whole label,
		-- or the next tick would overwrite whatever was just set.
		function handle.set(text)
			base = tostring(text)
			label.Text = base
		end
		return handle
	end

	return M
end
