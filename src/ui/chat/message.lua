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
			-- Fills rather than reserving controlSmall: the copy button is sized to
			-- max(controlSmall, minTarget()), which is 44 on touch, so the reserve was
			-- twelve pixels short on exactly the platform the minimum exists for.
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 1,
		})

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
			-- Takes whatever is left rather than reserving a guess. The guess was
			-- icon + 90, but the row also has to fit an auto-width tool name, so it
			-- over-committed by the width of that name and pushed `timing` out past
			-- the card's clip -- which is why a tool call never showed how long it took.
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 3,
		})

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
			layoutOrder = 3,
			visible = false,
		})
		resultLabel.Size = UDim2.new(1, 0, 0, 0)

		local open = detail.Visible
		header.Activated:Connect(function()
			open = not open
			detail.Visible = open
		end)

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
			open = true
			detail.Visible = true
			return nested
		end

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
			size = opts.nested and UDim2.new(1, 0, 0, 0) or UDim2.new(widthFor("agent"), 0, 0, 0),
			auto = "Y",
			bg = opts.nested and theme.color.surface or theme.color.bubbleTool,
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
		local dot = P.statusDot(row, { color = theme.color.accent, diameter = 7, layoutOrder = 1 })
		dot.Visible = false

		local kindLabel = P.text(row, {
			text = "agent",
			role = "monoSmall",
			color = theme.color.accent,
			layoutOrder = 2,
		})
		kindLabel.Size = UDim2.fromOffset(0, theme.text.monoSmall.size + 4)
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
		meta.Size = UDim2.fromOffset(88, theme.text.caption.size + 4)

		local feed = P.column(card, {
			name = "Feed",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xxs,
			padding = { x = theme.space.sm, bottom = theme.space.sm },
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
		-- result can land on the row that asked for it. The arguments are replaced by a
		-- one-line summary of what came back, which is as much of a subagent's tool
		-- output as belongs in the parent's transcript.
		function handle.tool(event)
			calls = calls + 1
			local toolRow = P.row(feed, {
				size = UDim2.new(1, 0, 0, theme.text.monoSmall.size + 6),
				gap = theme.space.xs,
				layoutOrder = nextSlot(),
			})
			P.statusDot(toolRow, { color = theme.riskColor(event.risk), diameter = 5, layoutOrder = 1 })
			local name = P.text(toolRow, {
				text = tostring(event.name or "tool"),
				role = "monoSmall",
				color = theme.color.textSecondary,
				layoutOrder = 2,
			})
			name.Size = UDim2.fromOffset(0, theme.text.monoSmall.size + 4)
			name.AutomaticSize = Enum.AutomaticSize.X
			local args = P.text(toolRow, {
				text = tostring(event.arguments or ""),
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
			timing.Size = UDim2.fromOffset(46, theme.text.caption.size + 4)
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
			dot.Visible = true
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

		paintMeta()
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
	-- by the answer when the turn ends. It carries the two signals that separate
	-- "thinking" from "hung" -- a label that moves and a clock that counts up --
	-- because the HTTP call it covers can take a minute and says nothing while it
	-- does.
	function M.working(parent, order)
		local holder = wrapper(parent, { name = "Working", layoutOrder = order })
		local row = P.row(holder, {
			size = UDim2.new(1, 0, 0, theme.size.row - 6),
			gap = theme.space.xs,
		})
		C.spinner(row, { diameter = theme.size.icon, layoutOrder = 1 })
		local label = P.text(row, {
			text = "Thinking",
			role = "small",
			color = theme.color.textSecondary,
			layoutOrder = 2,
		})
		local elapsed = P.text(row, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			layoutOrder = 3,
		})
		elapsed.Size = UDim2.fromOffset(52, theme.size.row - 6)
		label.Size = UDim2.new(1, -(theme.size.icon + 52 + theme.space.xs * 2), 1, 0)

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
