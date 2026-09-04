-- The task-list strip.
--
-- The model keeps a plan; this is where the user can see it. It collapses to a
-- single line when there is nothing active, because a permanent panel for a
-- three-item list wastes the height a phone does not have.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local state = env.require("agent/state")

	local M = {}

	local MARKS = {
		pending = { colour = "textTertiary", glyph = nil },
		active = { colour = "accent", glyph = "dot" },
		done = { colour = "success", glyph = "check" },
		dropped = { colour = "textDisabled", glyph = "minus" },
	}

	function M.new(parent, props)
		props = props or {}

		local shell = P.column(parent, {
			name = "Todos",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.surfaceRaised,
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
			size = UDim2.new(1, 0, 0, 1),
			bg = theme.color.borderSubtle,
			layoutOrder = 3,
		})

		local header = Instance.new("TextButton", shell)
		header.Text = ""
		header.AutoButtonColor = false
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget() - 8))
		header.LayoutOrder = 1
		header.Selectable = true

		local headerRow = P.row(header, {
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
			padding = { x = theme.space.md },
		})
		local caret = P.frame(headerRow, {
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 1,
		})
		icons.chevron(caret, theme.size.icon, theme.color.textTertiary, "right")
		local summary = P.text(headerRow, {
			text = "",
			role = "label",
			color = theme.color.textSecondary,
			truncate = true,
			layoutOrder = 2,
		})
		summary.Size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 1, 0)

		local list = P.column(shell, {
			name = "Items",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xxs,
			padding = { x = theme.space.md, bottom = theme.space.sm },
			layoutOrder = 2,
			visible = false,
		})

		local open = false
		header.Activated:Connect(function()
			open = not open
			list.Visible = open
			caret.Rotation = open and 90 or 0
		end)

		local function rebuild(items)
			for _, child in ipairs(list:GetChildren()) do
				if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
			end

			if #items == 0 then
				shell.Visible = false
				return
			end
			shell.Visible = true

			local counts = state.todoCounts()
			local activeText
			for _, item in ipairs(items) do
				if item.status == "active" then activeText = item.text end
			end
			summary.Text = string.format("%d of %d done%s",
				counts.done, counts.total,
				activeText and ("  -  " .. util.ellipsis(activeText, 60)) or "")

			for index, item in ipairs(items) do
				local mark = MARKS[item.status] or MARKS.pending
				local row = P.row(list, {
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					alignY = "Top",
					layoutOrder = index,
				})
				local glyphHolder = P.frame(row, {
					size = UDim2.fromOffset(theme.size.icon, theme.text.small.size + 4),
					layoutOrder = 1,
				})
				if mark.glyph then
					icons.draw(mark.glyph, glyphHolder, theme.size.icon - 2, theme.color[mark.colour])
				else
					P.statusDot(glyphHolder, {
						diameter = 5,
						color = theme.color[mark.colour],
						anchor = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
					})
				end
				local label = P.text(row, {
					text = item.text,
					role = item.status == "active" and "bodyStrong" or "small",
					color = theme.color[mark.colour],
					wrap = true,
					auto = "Y",
					layoutOrder = 2,
				})
				label.Size = UDim2.new(1, -(theme.size.icon + theme.space.xs), 0, 0)
			end

			-- An active item is worth showing without a click; a finished list is not.
			if activeText and not open then
				open = true
				list.Visible = true
				caret.Rotation = 90
			end
		end

		local unsubscribe = state.todosChanged:connect(rebuild)
		rebuild(state.todos)

		return {
			shell = shell,
			destroy = function()
				unsubscribe()
				pcall(function() shell:Destroy() end)
			end,
		}
	end

	return M
end
