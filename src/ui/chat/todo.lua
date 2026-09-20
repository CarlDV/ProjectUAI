-- The task-list strip.
--
-- The model keeps a plan; this is where the user can see it. It collapses to a
-- single line when there is nothing active, because a permanent panel for a
-- three-item list wastes the height a phone does not have.
--
-- It shows one conversation's plan: the strip is attached to a session, and a change
-- announced for a different one is ignored. Before, the store held a single list for
-- the whole client, so opening a second conversation replaced what this was showing
-- with that conversation's steps.
return function(env)
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local state = env.require("agent/state")

	local M = {}

	local MARKS = {
		pending = { colour = "textTertiary", text = "textSecondary" },
		active = { colour = "accent", text = "text" },
		done = { colour = "success", text = "textSecondary", glyph = "check" },
		dropped = { colour = "textDisabled", text = "textTertiary", glyph = "minus" },
	}
	local preferences = setmetatable({}, { __mode = "k" })

	function M.new(parent, props)
		props = props or {}

		local shell = P.column(parent, {
			name = "Todos",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.canvas,
			gap = 0,
			layoutOrder = props.layoutOrder,
			visible = false,
			clip = true,
		})
		-- Last in the stack rather than anchored to the bottom edge: the shell is a
		-- column, and a UIListLayout moves every child it has to its own slot, so an
		-- anchored rule would silently become the first row instead of the last.
		P.frame(shell, {
			name = "Rule",
			size = UDim2.new(1, 0, 0, theme.stroke.hair),
			bg = theme.color.borderSubtle,
			layoutOrder = 4,
		})

		local toggle = P.rowButton(shell, {
			name = "PlanToggle",
			height = math.max(theme.size.control, responsive.minTarget()),
			radius = theme.radius.none,
			gap = theme.space.xs,
			padding = { x = theme.space.xl },
			layoutOrder = 1,
		})
		local header = toggle.instance
		local headerRow = toggle.row
		local caret = P.frame(headerRow, {
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 1,
		})
		icons.chevron(caret, theme.size.icon, theme.color.textTertiary, "right")
		local summary = P.text(headerRow, {
			name = "PlanSummary",
			text = "",
			role = "label",
			color = theme.color.textSecondary,
			truncate = true,
			layoutOrder = 2,
		})
		summary.Size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 1, 0)
		local trackHolder = P.frame(shell, {
			name = "PlanProgress", size = UDim2.new(1, 0, 0, theme.size.track + theme.space.sm), layoutOrder = 2,
		})
		local track = P.frame(trackHolder, {
			name = "Track", size = UDim2.new(1, -theme.space.xl * 2, 0, theme.size.track),
			position = UDim2.fromOffset(theme.space.xl, 0), bg = theme.color.surfaceOverlay, radius = theme.radius.pill,
		})
		local progress = P.frame(track, {
			name = "Completed", size = UDim2.fromScale(0, 1), bg = theme.color.accent, radius = theme.radius.pill,
		})

		local planScroll = P.scroll(shell, {
			name = "Items",
			size = UDim2.new(1, 0, 0, 0),
			gap = theme.space.xs,
			padding = { x = theme.space.xl, top = theme.space.xxs, bottom = theme.space.md },
			layoutOrder = 3,
			visible = false,
		})

		local list = planScroll.instance
		list.Visible = false
		local handle = { shell = shell, session = nil }
		local orphan = {}
		local preference = orphan
		-- A long plan keeps its own scroll area instead of consuming the conversation.
		local function sizePlan()
			if not list.Parent or not planScroll.layout.Parent then return end
			local measured = planScroll.layout.AbsoluteContentSize
			if not measured then return end
			local height = measured.Y + theme.space.xxs + theme.space.md
			local ceiling = math.floor(theme.size.codeViewport * 0.5)
			if parent.AbsoluteSize.Y > 0 then
				ceiling = math.min(ceiling, math.floor(parent.AbsoluteSize.Y / 3))
			end
			list.Size = UDim2.new(1, 0, 0, math.max(0, math.min(height, ceiling)))
		end
		planScroll.layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(sizePlan)
		local resize = parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizePlan)

		local open = false
		local function setOpen(value, animate)
			open = value
			list.Visible = open
			if animate then P.animate(caret, "hover", { Rotation = open and 90 or 0 })
			else caret.Rotation = open and 90 or 0 end
			if open then sizePlan() end
		end
		header.Activated:Connect(function()
			preference.open = not open
			setOpen(preference.open, true)
		end)

		local function rebuild(items)
			for _, child in ipairs(list:GetChildren()) do
				if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
			end

			if #items == 0 then
				shell.Visible = false
				preference.open = nil
				setOpen(false)
				list.CanvasPosition = Vector2.new(0, 0)
				return
			end
			shell.Visible = true

			local counts = state.todoCounts(handle.session)
			local total = counts.total - counts.dropped
			trackHolder.Visible = total > 0
			P.animate(progress, "hover", { Size = UDim2.fromScale(counts.done / math.max(total, 1), 1),
				BackgroundColor3 = counts.done == total and theme.color.success or theme.color.accent })
			local activeText
			for _, item in ipairs(items) do
				if item.status == "active" then activeText = item.text; break end
			end
			summary.Text = "Plan"
				.. (total > 0 and string.format("  ·  %d of %d complete", counts.done, total) or "")
				.. (counts.dropped > 0 and string.format("  ·  %d skipped", counts.dropped) or "")
				.. (activeText and ("  ·  " .. activeText) or "")

			for index, item in ipairs(items) do
				local mark = MARKS[item.status] or MARKS.pending
				local row = P.row(list, {
					name = "TodoItem" .. index,
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					alignY = "Top",
					layoutOrder = index,
				})
				local glyphHolder = P.frame(row, {
					name = "TodoMarker",
					size = UDim2.fromOffset(theme.size.icon, theme.text.small.height),
					layoutOrder = 1,
				})
				if mark.glyph then
					icons.draw(mark.glyph, glyphHolder, theme.size.icon - 2, theme.color[mark.colour])
				else
					P.statusDot(glyphHolder, {
						diameter = item.status == "active" and theme.size.dot or theme.size.dotSmall,
						color = theme.color[mark.colour],
						anchor = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
					})
				end
				-- The marker and the label share one minimum line box. A zero-height
				-- auto label shrank single-line text below its marker; switching active
				-- items to a larger text role moved their centre again.
				P.text(row, {
					name = "TodoText",
					text = item.text,
					role = "small",
					font = item.status == "active" and theme.text.bodyStrong.font or nil,
					face = item.status == "active" and theme.text.bodyStrong.face or nil,
					color = theme.color[mark.text],
					size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 0, theme.text.small.height),
					wrap = true,
					auto = "Y",
					layoutOrder = 2,
				})
			end

			sizePlan()

			-- Follow progress until the user makes a choice, then preserve that choice
			-- across updates and conversation switches.
			local expanded = preference.open
			if expanded == nil then expanded = activeText ~= nil end
			setOpen(expanded)
		end

		-- A change announced for another conversation is somebody else's plan.
		local unsubscribe = state.todosChanged:connect(function(items, session)
			if session ~= handle.session then return end
			rebuild(items)
		end)

		-- Points the strip at a conversation and paints its plan. Called on every
		-- switch, keeping the disclosure choice with the conversation it belongs to.
		function handle.attach(session)
			local changed = handle.session ~= session
			handle.session = session
			if session then
				preferences[session] = preferences[session] or {}
				preference = preferences[session]
			else preference = orphan end
			if changed then list.CanvasPosition = Vector2.new(0, 0) end
			rebuild(state.todoList(session))
		end

		local function cleanup()
			unsubscribe()
			resize:Disconnect()
		end
		shell.Destroying:Connect(cleanup)
		function handle.destroy()
			cleanup()
			pcall(function() shell:Destroy() end)
		end

		handle.attach(props.session)
		return handle
	end

	return M
end
