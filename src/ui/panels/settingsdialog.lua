-- The settings dialog: a category list on the left, one pane on the right.
--
-- The same panes the Settings panel stacks, shown one at a time -- so this is a
-- different arrangement of the same settings rather than a second set. The one it is
-- modelled on opens from the profile menu and from Customize, and both of those land
-- here on a named category.
return function(env)
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local panes = env.require("ui/settingspanes")

	local M = {}

	function M.open(initial)
		local dialog = overlay.dialog({ name = "SettingsDialog" })
		if not dialog then return nil end

		-- On a phone the two panes do not fit side by side, so the list collapses to a
		-- row of categories above the pane rather than being cut off.
		local narrow = dialog.width < (theme.size.dialogNav * 3)
		local navWidth = narrow and dialog.width or theme.size.dialogNav
		-- The height of the collapsed category strip, and therefore the offset of
		-- everything under it. It was this same sum written out four times.
		local tabHeight = math.max(theme.size.controlLarge, responsive.minTarget(), theme.text.small.height + theme.space.xs * 2)
		local stripHeight = tabHeight + theme.space.xs * 2 + theme.size.scrollbar
		-- The corner the dialog's own close button occupies. Reserved rather than drawn
		-- under: with the strip spanning the full width, the button sat on top of the last
		-- category and nothing could reach it.
		local closeInset = dialog.closeInset or theme.space.xxl

		local navHolder = P.frame(dialog.card, {
			name = "DialogNav",
			size = narrow and UDim2.new(1, 0, 0, stripHeight)
				or UDim2.new(0, navWidth, 1, 0),
			bg = theme.color.sidebar,
		})
		local nav = P.scroll(navHolder, {
			name = "Categories",
			size = UDim2.new(1, narrow and -closeInset or 0, 1, 0),
			gap = theme.space.hair,
			padding = {
				left = theme.space.xs,
				right = theme.space.xs,
				y = theme.space.xs,
			},
			horizontal = narrow,
			alignX = "Left",
		})

		local divider = P.frame(dialog.card, {
			name = "DialogDivider",
			size = narrow and UDim2.new(1, 0, 0, theme.stroke.hair) or UDim2.new(0, theme.stroke.hair, 1, 0),
			position = narrow and UDim2.new(0, 0, 0, stripHeight)
				or UDim2.new(0, navWidth, 0, 0),
			bg = theme.color.borderSubtle,
		})

		local bodyHolder = P.frame(dialog.card, {
			name = "DialogBody",
			size = narrow and UDim2.new(1, 0, 1, -(stripHeight + theme.stroke.hair))
				or UDim2.new(1, -(navWidth + theme.stroke.hair), 1, 0),
			position = narrow and UDim2.new(0, 0, 0, stripHeight + theme.stroke.hair)
				or UDim2.new(0, navWidth + theme.stroke.hair, 0, 0),
		})
		local body = P.scroll(bodyHolder, {
			name = "PaneScroll",
			size = UDim2.fromScale(1, 1),
			gap = theme.space.md,
			padding = {
				left = theme.space.lg,
				-- Wide layouts put the close button over the top of this pane, so the first
				-- row's right edge has to clear it.
				right = narrow and theme.space.lg or closeInset,
				top = theme.space.lg,
				bottom = theme.space.xl,
			},
		})

		local rows = {}
		local active = nil

		local function select(id)
			if dialog.closed or not panes.pane(id) or active == id then return end
			active = id
			for key, row in pairs(rows) do
				row.setSelected(key == id)
				row.text.TextColor3 = (key == id) and theme.color.text or theme.color.textSecondary
			end
			body.clear()
			local column = P.column(body.instance, {
				name = "Pane_" .. id,
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.md,
				layoutOrder = 1,
			})
			panes.render(id, column)
			body.instance.CanvasPosition = Vector2.new(0, 0)
		end

		local function renderNav()
			nav.clear()
			rows = {}
			local order = 0
			local function nextOrder()
				order = order + 1
				return order
			end

			if not narrow then
				P.text(nav.instance, {
					name = "SettingsTitle", text = "Settings", role = "title",
					size = UDim2.new(1, 0, 0, theme.text.title.height + theme.space.lg),
					padding = { x = theme.space.sm, y = theme.space.sm },
					layoutOrder = nextOrder(),
				})
			end

			for _, section in ipairs(panes.sections()) do
				-- Section headings belong to the vertical list, not the tab strip.
				if not narrow then
					P.text(nav.instance, {
						name = "Section_" .. section.title, text = section.title, role = "caption",
						color = theme.color.textTertiary, truncate = true,
						size = UDim2.new(1, 0, 0, theme.text.caption.height + theme.space.xs),
						padding = { x = theme.space.xs, top = theme.space.xs }, layoutOrder = nextOrder(),
					})
				end
				for _, entry in ipairs(section.panes) do
					local row = P.rowButton(nav.instance, {
						name = "Category_" .. entry.id,
						size = narrow and UDim2.fromOffset(0, tabHeight) or nil,
						auto = narrow and "X" or nil,
						selected = active == entry.id,
						layoutOrder = nextOrder(),
						onClick = function() select(entry.id) end,
					})
					row.icon(entry.icon, 1, theme.color.textSecondary, theme.size.icon)
					if narrow then
						row.text = P.text(row.row, { name = "Label", text = entry.label, role = "small",
							auto = "X", truncate = true, maxSize = Vector2.new(theme.size.menuMin, math.huge),
							color = theme.color.textSecondary, layoutOrder = 2 })
					else
						row.text = row.label(entry.label, 2, theme.color.textSecondary, "small")
					end
					row.text.TextColor3 = active == entry.id and theme.color.text or theme.color.textSecondary
					rows[entry.id] = row
				end
			end
		end

		local function reflow()
			if dialog.closed then return end
			local width = dialog.card.AbsoluteSize.X
			if width <= 0 then width = dialog.width end
			local nextNarrow = width < theme.size.dialogNav * 3
			local changed = narrow ~= nextNarrow
			narrow = nextNarrow
			navWidth = theme.size.dialogNav
			navHolder.Size = narrow and UDim2.new(1, 0, 0, stripHeight) or UDim2.new(0, navWidth, 1, 0)
			nav.instance.Size = UDim2.new(1, narrow and -closeInset or 0, 1, 0)
			nav.layout.FillDirection = narrow and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
			nav.instance.AutomaticCanvasSize = narrow and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
			nav.instance.ScrollingDirection = narrow and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
			nav.instance.VerticalScrollBarInset = narrow and Enum.ScrollBarInset.None or Enum.ScrollBarInset.ScrollBar
			nav.instance.HorizontalScrollBarInset = narrow and Enum.ScrollBarInset.ScrollBar or Enum.ScrollBarInset.None
			divider.Size = narrow and UDim2.new(1, 0, 0, theme.stroke.hair) or UDim2.new(0, theme.stroke.hair, 1, 0)
			divider.Position = narrow and UDim2.new(0, 0, 0, stripHeight) or UDim2.new(0, navWidth, 0, 0)
			bodyHolder.Size = narrow and UDim2.new(1, 0, 1, -(stripHeight + theme.stroke.hair))
				or UDim2.new(1, -(navWidth + theme.stroke.hair), 1, 0)
			bodyHolder.Position = narrow and UDim2.new(0, 0, 0, stripHeight + theme.stroke.hair)
				or UDim2.new(0, navWidth + theme.stroke.hair, 0, 0)
			body.instance:FindFirstChildOfClass("UIPadding").PaddingRight = UDim.new(0, narrow and theme.space.lg or closeInset)
			if changed then
				nav.instance.CanvasPosition = Vector2.new(0, 0)
				renderNav()
			end
		end
		renderNav()
		dialog.card:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow)
		reflow()

		select(panes.pane(initial) and initial or panes.PANES[1].id)

		dialog.select = select
		dialog.activeCategory = function() return active end
		return dialog
	end

	return M
end
