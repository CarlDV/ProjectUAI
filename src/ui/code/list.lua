-- Recycled Code rows keep interaction identity across live data refreshes.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local clock = env.require("runtime/clock")
	local icons = env.require("ui/icons")
	local instanceIcons = env.require("ui/instance_icons")
	local M = {}
	function M.new(parent, options)
		options = options or {}
		local scroll = P.scroll(parent, { name = options.name or "CodeList", size = options.size, position = options.position, gap = 0 })
		scroll.layout:Destroy(); scroll.instance.AutomaticCanvasSize = Enum.AutomaticSize.None
		local horizontal = options.horizontal or options.indent ~= nil
		if horizontal then scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY end
		if options.bg then scroll.instance.BackgroundColor3, scroll.instance.BackgroundTransparency = options.bg, 0 end
		local labelHeight, detailHeight = theme.textRole(options.role or "small").height, theme.text.caption.height
		local textHeight = options.detail and labelHeight + detailHeight + 12 or labelHeight + 8
		local rowHeight = math.max(options.rowHeight or (options.detail and 50 or options.dense and 28 or 34), options.passive and 1 or responsive.minTarget(), textHeight)
		local chevronWidth = math.max(24, responsive.minTarget())
		local list = { root = scroll.instance, items = {}, rows = {}, selected = 1, visible = true, rowHeight = rowHeight }
		local rendering, contentWidth, measurements = false, 0, {}
		local function indent(item) return math.max(0, options.indent and options.indent(item) or 0) * 16 end
		local function labelOf(item, index) return options.label and options.label(item, index) or item.label or tostring(item) end
		local function measureItems()
			contentWidth = 0; if not horizontal then return end
			local nextMeasurements = {}
			local function measure(text, role)
				local key = role .. ":" .. text
				local width = measurements[key] or P.measureText(text, { role = role }).X
				nextMeasurements[key] = width; return width
			end
			for index, item in ipairs(list.items) do
				local left = 8 + indent(item) + (options.chevron and chevronWidth or 0) + (options.icon and theme.size.icon + 6 or 0)
				local width = measure(labelOf(item, index), options.role or "small") + (options.meta and (options.metaWidth or 60) + 6 or 0)
				if options.detail then width = math.max(width, measure(options.detail(item, index) or "", "caption")) end
				contentWidth = math.max(contentWidth, left + width + 16 + theme.size.scrollbar)
			end
			measurements = nextMeasurements
		end
		local function key(item, index)
			return options.key and options.key(item, index) or item.id or item.instanceId or item.path or item.key or item.more or (tostring(index) .. ":" .. tostring(item.label))
		end
		local function paint(row)
			local selected = row.item and row.item.selected
			local background = row.item and (row.item.background or (options.background and options.background(row.item)))
			row.button.instance.BackgroundColor3 = selected and theme.color.surfaceSelected or (row.hovered or row.focused) and theme.color.surfaceHover or background or theme.color.surfaceHover
			row.button.instance.BackgroundTransparency = (selected or row.hovered or row.focused or background) and 0 or 1
			row.mark.Visible = selected == true
		end
		local function activate(row)
			if row.pressed and row.pressed ~= row.key then row.pressed = nil; return end
			row.pressed = nil
			local item = row.item; if not item then return end
			list.selected, list.selectedKey = row.index, row.key
			local now = clock.ms()
			local double = row.lastKey == row.key and row.lastClick ~= nil and now - row.lastClick < 350
			row.lastClick, row.lastKey = now, row.key
			if double and options.onDoubleClick then
				row.lastClick = nil; options.onDoubleClick(item, row.index, row.button)
			elseif options.onSelect then options.onSelect(item, row.index, row.button) end
		end
		local function createRow()
			local row = {}
			local button = Instance.new("TextButton", list.root)
			button.Name, button.Text, button.AutoButtonColor = "VirtualRow", "", false
			button.BackgroundTransparency, button.BorderSizePixel = 1, 0
			button.Active, button.Selectable, button.ClipsDescendants = not options.passive, not options.passive, true
			local label = P.text(button, { name = "Label", text = "", role = options.role or "small", truncate = not horizontal })
			label.Active = false
			row.button = { instance = button, label = label, setText = function(value) label.Text = tostring(value) end }
			row.mark = P.frame(button, { name = "SelectedMark", size = UDim2.new(0, 2, 1, 0), bg = theme.color.accent, visible = false })
			if options.detail then row.detail = P.text(button, { name = "Detail", text = "", role = "caption", color = theme.color.textSecondary, truncate = true }); row.detail.Active = false end
			if options.meta then row.meta = P.text(button, { name = "Meta", text = "", role = "caption", color = theme.color.textTertiary, align = "Right", truncate = true }); row.meta.Active = false end
			if options.value then row.value = P.text(button, { name = "Value", text = "", role = "small", truncate = true }); row.value.Active = false end
			if options.icon then
				row.iconImage = Instance.new("ImageLabel", button)
				row.iconImage.Name, row.iconImage.BackgroundTransparency, row.iconImage.BorderSizePixel = "ClassIcon", 1, 0
				row.iconImage.Size, row.iconImage.ScaleType = UDim2.fromOffset(theme.size.icon, theme.size.icon), Enum.ScaleType.Fit
				row.iconImage.Active = false
			end
			if options.chevron then
				-- A sibling, not a nested button: expanding cannot also activate the row.
				local expand = Instance.new("TextButton", list.root)
				expand.Name, expand.Text, expand.AutoButtonColor = "ChevronSlot", "", false
				expand.BackgroundTransparency, expand.BorderSizePixel, expand.ZIndex = 1, 0, button.ZIndex + 2
				expand.Active, expand.Selectable = true, true
				row.chevronSlot, row.chevronIcon = expand, icons.draw("chevron", expand, theme.size.icon, theme.color.textSecondary)
				row.chevronIcon.AnchorPoint = Vector2.new(0.5, 0.5); row.chevronIcon.Position = UDim2.fromScale(0.5, 0.5)
				expand.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then row.expandPressed = row.key end
				end)
				expand.Activated:Connect(function()
					if row.expandPressed and row.expandPressed ~= row.key then row.expandPressed = nil; return end
					row.expandPressed = nil
					if row.item and options.onToggle then options.onToggle(row.item, row.index) end
				end)
			end
			if options.onClose then
				-- A sibling of the row, not a child of it, so removing an entry cannot
				-- also select it. Mirrors the chevron slot on the opposite edge.
				local close = Instance.new("TextButton", list.root)
				close.Name, close.Text, close.AutoButtonColor = "RowClose", "×", false
				close.Font, close.TextSize, close.TextColor3 = theme.text.small.font, theme.text.small.size + 3, theme.color.textSecondary
				close.BackgroundTransparency, close.BorderSizePixel, close.ZIndex = 1, 0, button.ZIndex + 2
				close.Active, close.Selectable = true, true
				row.closeSlot = close
				close.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then row.closePressed = row.key end
				end)
				close.Activated:Connect(function()
					if row.closePressed and row.closePressed ~= row.key then row.closePressed = nil; return end
					row.closePressed = nil
					if row.item and options.onClose then options.onClose(row.item, row.index, row.button) end
				end)
			end
			button.MouseEnter:Connect(function() row.hovered = not options.passive; paint(row) end)
			button.MouseLeave:Connect(function() row.hovered = false; paint(row) end)
			button.SelectionGained:Connect(function() row.focused = true; paint(row); if row.item and options.onFocus then options.onFocus(row.item) end end)
			button.SelectionLost:Connect(function() row.focused = false; paint(row) end)
			button.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then row.pressed = row.key end
			end)
			button.Activated:Connect(function() activate(row) end)
			button.MouseButton2Click:Connect(function()
				if row.item and options.onContextMenu then
					list.selected, list.selectedKey = row.index, row.key
					options.onContextMenu(row.item, row.index, row.button)
				end
			end)
			return row
		end
		local function render()
			if rendering or not list.visible then return end
			rendering = true
			local viewport = math.max(rowHeight, list.root.AbsoluteSize.Y)
			local maxY = math.max(0, #list.items * rowHeight - viewport)
			local canvasWidth = math.max(list.root.AbsoluteSize.X, contentWidth)
			list.root.CanvasSize = UDim2.fromOffset(horizontal and canvasWidth or 0, #list.items * rowHeight)
			local position = list.root.CanvasPosition
			local x, y = math.min(position.X, math.max(0, canvasWidth - list.root.AbsoluteSize.X)), math.min(position.Y, maxY)
			if position.X ~= x or position.Y ~= y then list.root.CanvasPosition = Vector2.new(x, y) end
			local first = math.max(1, math.floor(list.root.CanvasPosition.Y / rowHeight) + 1 - theme.size.codeOverscan)
			local count = math.min(160, math.ceil(viewport / rowHeight) + theme.size.codeOverscan * 2)
			for slot = 1, count do
				local row = list.rows[slot]
				if not row then row = createRow(); list.rows[slot] = row end
				local index = first + slot - 1; local item = list.items[index]
				local identity = item and key(item, index)
				if row.key ~= identity then row.lastClick, row.lastKey, row.hovered = nil, nil, false end
				row.item, row.index, row.key = item, index, identity
				row.button.instance.Visible = item ~= nil
				if row.chevronSlot then row.chevronSlot.Visible = false end
				if row.closeSlot then row.closeSlot.Visible = false end
				if item then
					local top = (index - 1) * rowHeight
					row.button.instance.Position, row.button.instance.Size = UDim2.fromOffset(0, top), UDim2.fromOffset(canvasWidth - theme.size.scrollbar, rowHeight)
					row.button.instance.SelectionOrder = index
					local left = 8 + indent(item)
					local closeWidth = math.max(24, responsive.minTarget())
					local closing = row.closeSlot ~= nil and (options.closable == nil or options.closable(item) ~= false)
					local rightReserve = closing and closeWidth or 0
					if row.closeSlot then
						row.closeSlot.Visible = closing
						row.closeSlot.Position, row.closeSlot.Size = UDim2.fromOffset(canvasWidth - theme.size.scrollbar - closeWidth, top), UDim2.fromOffset(closeWidth, rowHeight)
					end
					if row.chevronSlot then
						local state = options.chevron(item)
						row.chevronSlot.Visible = state ~= nil
						row.chevronSlot.Position, row.chevronSlot.Size = UDim2.fromOffset(left, top), UDim2.fromOffset(chevronWidth, rowHeight)
						row.chevronIcon.Rotation = state == "open" and 0 or -90
						left = left + chevronWidth
					end
					if row.iconImage then
						local class = options.icon(item)
						row.iconImage.Visible = class ~= nil
						row.iconImage.Position = UDim2.fromOffset(left, math.floor((rowHeight - theme.size.icon) / 2))
						if class then instanceIcons.paint(row.iconImage, class) end
						left = left + theme.size.icon + 6
					end
					local metaWidth = row.meta and (options.metaWidth or 60) or 0
					local label = row.button.label
					label.RichText = options.richLabel ~= nil
					label.Text = options.richLabel and options.richLabel(item, index) or labelOf(item, index)
					label.TextColor3 = item.color or theme.color.text
					label.Position = UDim2.fromOffset(left, row.detail and 4 or 0)
					label.Size = UDim2.new(1, -left - 8 - metaWidth - (row.meta and 6 or 0) - rightReserve, 0, row.detail and labelHeight or rowHeight)
					if row.value then
						label.Size = UDim2.new(0.43, -left - 6, 1, 0)
						row.value.Text = options.value(item, index) or ""
						row.value.Position, row.value.Size = UDim2.new(0.43, 6, 0, 0), UDim2.new(0.57, -14, 1, 0)
						row.value.TextColor3 = item.writable == false and theme.color.textSecondary or theme.color.text
					end
					if row.detail then
						row.detail.Text = options.detail(item, index) or ""
						row.detail.Position, row.detail.Size = UDim2.fromOffset(left, rowHeight - detailHeight - 4), UDim2.new(1, -left - 8 - rightReserve, 0, detailHeight)
					end
					if row.meta then
						row.meta.Text = options.meta(item, index) or ""
						row.meta.Position, row.meta.Size = UDim2.new(1, -metaWidth - 8 - rightReserve, 0, row.detail and 4 or 0), UDim2.fromOffset(metaWidth, row.detail and labelHeight or rowHeight)
					end
					paint(row)
				end
			end
			for slot = count + 1, #list.rows do
				list.rows[slot].button.instance.Visible = false
				if list.rows[slot].chevronSlot then list.rows[slot].chevronSlot.Visible = false end
				if list.rows[slot].closeSlot then list.rows[slot].closeSlot.Visible = false end
			end
			rendering = false
		end
		function list.set(items, preserve)
			list.items = items or {}
			measureItems()
			list.selected = math.max(1, math.min(list.selected, #list.items))
			for index, item in ipairs(list.items) do if key(item, index) == list.selectedKey then list.selected = index; break end end
			if not preserve then list.root.CanvasPosition = Vector2.new(0, 0) end
			render()
		end
		function list.move(delta)
			list.selected = math.max(1, math.min(#list.items, list.selected + delta))
			local item = list.items[list.selected]; list.selectedKey = item and key(item, list.selected)
			local y = (list.selected - 1) * rowHeight
			if y < list.root.CanvasPosition.Y then list.root.CanvasPosition = Vector2.new(list.root.CanvasPosition.X, y)
			elseif y + rowHeight > list.root.CanvasPosition.Y + list.root.AbsoluteSize.Y then list.root.CanvasPosition = Vector2.new(list.root.CanvasPosition.X, math.max(0, y + rowHeight - list.root.AbsoluteSize.Y)) end
			render()
			for _, row in ipairs(list.rows) do if row.index == list.selected and row.item then pcall(function() env.services.GuiService.SelectedObject = row.button.instance end) end end
		end
		function list.activate()
			local item = list.items[list.selected]
			if item and options.onSelect then options.onSelect(item, list.selected) end
		end
		function list.toggle(expand)
			local item = list.items[list.selected]
			if not item or not options.onToggle or not options.chevron then return end
			local state = options.chevron(item)
			if state and (expand == nil or (expand and state == "closed") or (not expand and state == "open")) then options.onToggle(item, list.selected) end
		end
		function list.focusKey(identity)
			for index, item in ipairs(list.items) do if key(item, index) == identity then list.selected = index; list.move(0); return end end
		end
		list.root:GetPropertyChangedSignal("CanvasPosition"):Connect(render)
		list.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(render)
		list.render = render
		return list
	end
	return M
end
