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

	local CODE_LINES = 40
	local ARG_PREVIEW = 90

	local M = {}

	-- Bubble width. A message that reaches the far edge reads as a wall; leaving a
	-- gutter on the opposite side is what makes the two speakers legible as a
	-- conversation. The agent gets more room than the user because its replies are
	-- longer and often contain code.
	local function widthFor(kind)
		if responsive.mode == "sheet" then
			return kind == "user" and 0.86 or 0.96
		end
		return kind == "user" and 0.76 or 0.94
	end

	local function wrapper(parent, props)
		return P.frame(parent, {
			name = props.name or "Message",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			layoutOrder = props.layoutOrder or 0,
		})
	end

	-- Code block: monospace on the darkest surface, with the language and a copy
	-- control. Over-long blocks are cut with an explicit count rather than silently.
	function M.codeBlock(parent, props)
		local caps = env.require("runtime/caps")
		local lines = util.lines(props.text)
		local shown = lines
		local omitted = 0
		if #lines > CODE_LINES then
			shown = util.slice(lines, 1, CODE_LINES)
			omitted = #lines - CODE_LINES
		end

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
			size = UDim2.new(1, 0, 0, theme.size.controlSmall),
			bg = theme.color.surfaceRaised,
			gap = theme.space.xs,
			padding = { x = theme.space.sm },
			layoutOrder = 1,
		})
		local label = P.text(bar, {
			text = (props.lang and props.lang:lower() or "code") .. (props.unterminated and " (incomplete)" or ""),
			role = "caption",
			color = theme.color.textTertiary,
			layoutOrder = 1,
		})
		label.Size = UDim2.new(1, -(theme.size.controlSmall + theme.space.xs), 1, 0)

		if caps.clipboard then
			local copy = P.iconButton(bar, {
				name = "Copy",
				icon = "copy",
				diameter = theme.size.controlSmall,
				variant = "ghost",
				layoutOrder = 2,
				onClick = function(handle)
					pcall(caps.fn.clipboard, props.text)
					env.require("ui/overlay").toast("Copied to clipboard", "good", 2)
				end,
			})
			copy.instance.LayoutOrder = 2
		end

		local body = P.text(card, {
			text = table.concat(shown, "\n"),
			role = "mono",
			color = theme.color.text,
			wrap = true,
			auto = "Y",
			alignY = "Top",
			layoutOrder = 2,
			padding = { x = theme.space.md, y = theme.space.sm },
		})
		body.Size = UDim2.new(1, 0, 0, 0)

		if omitted > 0 then
			P.text(card, {
				text = string.format("%d more line%s not shown", omitted, omitted == 1 and "" or "s"),
				role = "caption",
				color = theme.color.textTertiary,
				layoutOrder = 3,
				padding = { x = theme.space.md, bottom = theme.space.sm },
				auto = "Y",
			})
		end

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
				local label = P.text(column, {
					text = markdown.inline(block.text),
					role = block.level == 1 and "title" or "heading",
					rich = true,
					wrap = true,
					auto = "Y",
					layoutOrder = index,
				})
				label.Size = UDim2.new(1, 0, 0, 0)
			elseif block.kind == "rule" then
				P.divider(column, { layoutOrder = index })
			elseif block.kind == "bullets" then
				local list = P.column(column, {
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xxs,
					layoutOrder = index,
				})
				for position, item in ipairs(block.items) do
					local row = P.row(list, {
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.xs,
						alignY = "Top",
						layoutOrder = position,
					})
					local dot = P.frame(row, {
						size = UDim2.fromOffset(theme.space.sm, theme.text.body.size + 2),
						layoutOrder = 1,
					})
					P.statusDot(dot, {
						diameter = 4,
						color = theme.color.textTertiary,
						anchor = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
					})
					local text = P.text(row, {
						text = markdown.inline(item),
						role = "body",
						rich = true,
						wrap = true,
						auto = "Y",
						layoutOrder = 2,
					})
					text.Size = UDim2.new(1, -(theme.space.sm + theme.space.xs), 0, 0)
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

	function M.user(parent, text, order)
		local holder = wrapper(parent, { name = "User", layoutOrder = order })
		local bubble = P.column(holder, {
			name = "Bubble",
			size = UDim2.new(widthFor("user"), 0, 0, 0),
			auto = "Y",
			anchor = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			bg = theme.color.bubbleUser,
			radius = theme.radius.lg,
			gap = theme.space.xxs,
			padding = { x = theme.space.md, y = theme.space.sm },
		})
		P.stroke(bubble, theme.color.bubbleUserBorder)
		local label = P.text(bubble, {
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
			size = UDim2.new(widthFor("agent"), 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
		})
		local handle = { root = holder, column = column }
		function handle.setText(value)
			M.renderBlocks(column, value)
		end
		handle.setText(text or "")
		return handle
	end

	-- Reasoning is collapsed by default: it is interesting once and noise
	-- afterwards, and on a phone it would push the answer off screen.
	function M.reasoning(parent, text, order)
		local holder = wrapper(parent, { name = "Reasoning", layoutOrder = order })
		local card = P.column(holder, {
			size = UDim2.new(widthFor("agent"), 0, 0, 0),
			auto = "Y",
			bg = theme.color.surface,
			radius = theme.radius.md,
			gap = theme.space.xs,
			padding = { x = theme.space.sm, y = theme.space.xs },
		})
		P.stroke(card, theme.color.borderSubtle)

		local header = Instance.new("TextButton", card)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, theme.text.label.size + 6)
		header.LayoutOrder = 1
		header.Selectable = true

		local row = P.row(header, { size = UDim2.fromScale(1, 1), gap = theme.space.xs })
		local caret = P.frame(row, {
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 1,
		})
		icons.chevron(caret, theme.size.icon, theme.color.textTertiary, "right")
		local title = P.text(row, {
			text = "reasoning",
			role = "label",
			color = theme.color.textTertiary,
			layoutOrder = 2,
		})
		title.Size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 1, 0)

		local body = P.text(card, {
			text = markdown.plain(text),
			role = "small",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
			visible = false,
		})
		body.Size = UDim2.new(1, 0, 0, 0)

		local open = false
		local function toggle()
			open = not open
			body.Visible = open
			caret.Rotation = open and 90 or 0
		end
		header.Activated:Connect(toggle)
		if config.get("ui.showReasoning", true) == false then card.Visible = false end

		local handle = { root = holder, body = body }
		function handle.append(more)
			body.Text = markdown.plain(body.Text .. more)
		end
		return handle
	end

	-- A tool call row: risk dot, name, argument preview, timing, and an expandable
	-- detail pane holding the full arguments and the result.
	function M.toolCall(parent, info, order)
		local holder = wrapper(parent, { name = "Tool", layoutOrder = order })
		local card = P.column(holder, {
			size = UDim2.new(widthFor("agent"), 0, 0, 0),
			auto = "Y",
			bg = theme.color.bubbleTool,
			radius = theme.radius.md,
			gap = 0,
			clip = true,
		})
		P.stroke(card, theme.color.borderSubtle)

		local header = Instance.new("TextButton", card)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, math.max(theme.size.row - 4, responsive.minTarget() - 8))
		header.LayoutOrder = 1
		header.Selectable = true

		local row = P.row(header, {
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
			padding = { x = theme.space.sm },
		})

		local spinner = C.spinner(row, { diameter = theme.size.icon - 2, layoutOrder = 1 })
		local dot = P.statusDot(row, {
			color = theme.riskColor(info.risk),
			diameter = 7,
			layoutOrder = 1,
		})
		dot.Visible = false

		local name = P.text(row, {
			text = tostring(info.name or "tool"),
			role = "monoSmall",
			color = theme.color.text,
			layoutOrder = 2,
		})
		name.Size = UDim2.fromOffset(0, theme.text.monoSmall.size + 4)
		name.AutomaticSize = Enum.AutomaticSize.X

		local preview = P.text(row, {
			text = util.ellipsis(tostring(info.arguments or ""):gsub("[\n\r]", " "), ARG_PREVIEW),
			role = "caption",
			color = theme.color.textTertiary,
			truncate = true,
			layoutOrder = 3,
		})
		preview.Size = UDim2.new(1, -(theme.size.icon + 90), 1, 0)

		local timing = P.text(row, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			layoutOrder = 4,
		})
		timing.Size = UDim2.fromOffset(52, theme.text.caption.size + 4)

		local detail = P.column(card, {
			name = "Detail",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			padding = { x = theme.space.sm, bottom = theme.space.sm },
			layoutOrder = 2,
			visible = config.get("ui.showToolDetail", false) == true,
		})

		local argsLabel = P.text(detail, {
			text = "arguments\n" .. tostring(info.arguments or "{}"),
			role = "monoSmall",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = 1,
		})
		argsLabel.Size = UDim2.new(1, 0, 0, 0)

		local resultLabel = P.text(detail, {
			text = "",
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
			visible = false,
		})
		resultLabel.Size = UDim2.new(1, 0, 0, 0)

		local open = detail.Visible
		header.Activated:Connect(function()
			open = not open
			detail.Visible = open
		end)

		local handle = { root = holder, card = card }

		function handle.progress(text)
			preview.Text = util.ellipsis(tostring(text), ARG_PREVIEW)
		end

		function handle.finish(result)
			spinner:Destroy()
			dot.Visible = true
			if result.ok then
				dot.BackgroundColor3 = theme.riskColor(info.risk)
			else
				dot.BackgroundColor3 = result.denied and theme.color.warn or theme.color.danger
			end
			timing.Text = result.ms and util.formatDuration(result.ms) or ""
			local text = tostring(result.text or "")
			preview.Text = util.ellipsis(text:gsub("[\n\r]+", " "), ARG_PREVIEW)
			preview.TextColor3 = result.ok and theme.color.textTertiary or theme.color.danger
			resultLabel.Text = "result\n" .. text
			resultLabel.Visible = true
			if result.truncated then
				resultLabel.Text = resultLabel.Text .. "\n[result was trimmed before the model saw it]"
			end
		end

		return handle
	end

	function M.notice(parent, props, order)
		local holder = wrapper(parent, { name = "Notice", layoutOrder = order })
		local row = P.row(holder, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.toneSurface(props.tone or "info"),
			radius = theme.radius.md,
			gap = theme.space.xs,
			padding = { x = theme.space.sm, y = theme.space.xs },
			alignY = "Top",
		})
		P.statusDot(row, { color = theme.toneColor(props.tone or "info"), diameter = 7, layoutOrder = 1 })
		local label = P.text(row, {
			text = tostring(props.text),
			role = "small",
			color = props.tone == "bad" and theme.color.danger or theme.color.textSecondary,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
		})
		label.Size = UDim2.new(1, -(theme.space.xs + 8), 0, 0)
		return { root = holder, label = label }
	end

	-- The working indicator: one row that reports the current status text, replaced
	-- by the answer when the turn ends.
	function M.working(parent, order)
		local holder = wrapper(parent, { name = "Working", layoutOrder = order })
		local row = P.row(holder, {
			size = UDim2.new(1, 0, 0, theme.size.row - 6),
			gap = theme.space.xs,
		})
		C.spinner(row, { diameter = theme.size.icon - 2, layoutOrder = 1 })
		local label = P.text(row, {
			text = "Thinking",
			role = "small",
			color = theme.color.textSecondary,
			layoutOrder = 2,
		})
		label.Size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 1, 0)
		local handle = { root = holder, label = label }
		function handle.set(text) label.Text = tostring(text) end
		return handle
	end

	return M
end
