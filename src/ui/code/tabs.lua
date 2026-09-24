return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local M = {}
	function M.new(parent, options)
		options = options or {}
		local scroll = P.scroll(parent, { name = options.name or "CodeTabs", size = options.size, position = options.position, horizontal = true, gap = 0, bar = 2 })
		scroll.layout:Destroy(); scroll.instance.AutomaticCanvasSize = Enum.AutomaticSize.None
		local root, cells = scroll.instance, {}
		local handle = { root = root, items = {} }
		local selected, selectedBefore, layingOut
		local function reveal(cell, target)
			if not cell.x then return end
			local padding, viewport = common.inset(), root.AbsoluteSize.X
			local at, width = cell.x, cell.width
			if width + padding * 2 > viewport then
				width = target.AbsoluteSize.X
				if target == cell.close then at = at + cell.width - width end
			end
			local left = root.CanvasPosition.X
			if at < left + padding then left = at - padding
			elseif at + width > left + viewport - padding then left = at + width + padding - viewport end
			root.CanvasPosition = Vector2.new(math.max(0, math.min(left, root.CanvasSize.X.Offset - viewport)), 0)
		end
		local function paint(cell)
			local active = cell.item and cell.item.id == selected
			cell.root.BackgroundColor3 = active and theme.color.surfaceSelected or theme.color.surfaceHover
			cell.root.BackgroundTransparency = (active or cell.hovered) and 0 or 1
			cell.label.TextColor3 = active and theme.color.text or theme.color.textSecondary
			cell.line.Visible = active
		end
		local function create(item)
			local holder = P.frame(root, { name = "Tab" })
			local button = Instance.new("TextButton", holder)
			button.Name, button.Text, button.AutoButtonColor = "TabButton", "", false
			button.Active, button.Selectable, button.BorderSizePixel = true, true, 0
			button.Size, button.BackgroundTransparency = UDim2.fromScale(1, 1), 1
			local cell = { root = holder, button = button, item = item }
			cell.label = P.text(button, { name = "TabLabel", text = item.label, role = "small", truncate = true, position = UDim2.fromOffset(12, 0) })
			cell.label.Active = false
			cell.line = P.frame(holder, { name = "ActiveTab", size = UDim2.new(1, 0, 0, 2), position = UDim2.new(0, 0, 1, -2), bg = theme.color.accent, visible = false })
			button.MouseEnter:Connect(function() cell.hovered = true; paint(cell) end)
			button.MouseLeave:Connect(function() cell.hovered = false; paint(cell) end)
			button.SelectionGained:Connect(function() cell.hovered = true; paint(cell); reveal(cell, button) end)
			button.SelectionLost:Connect(function() cell.hovered = false; paint(cell) end)
			button.Activated:Connect(function() if options.onSelect then options.onSelect(cell.item.id, cell.item) end end)
			if options.onClose then
				local close = Instance.new("TextButton", holder)
				close.Name, close.Text, close.AutoButtonColor = "CloseTab", "×", false
				close.Font, close.TextSize, close.TextColor3 = theme.text.small.font, theme.text.small.size + 3, theme.color.textSecondary
				close.BackgroundTransparency, close.BorderSizePixel, close.ZIndex = 1, 0, button.ZIndex + 1
				close.Active, close.Selectable = true, true
				local target = common.controlHeight()
				close.Position, close.Size = UDim2.new(1, -target, 0, 0), UDim2.new(0, target, 1, 0)
				close.Activated:Connect(function() options.onClose(cell.item.id, cell.item) end)
				cell.close = close
				close.SelectionGained:Connect(function() reveal(cell, close) end)
			end
			return cell
		end
		local function layout(revealSelected)
			if layingOut then return end; layingOut = true
			local padding, gap = common.inset(), 4
			local x, selectedCell = padding, nil
			for index, item in ipairs(handle.items) do
				local cell = cells[item.id]
				local close = cell.close and item.closable ~= false
				local target = common.controlHeight()
				local minimum = math.max(options.minWidth or 44, close and math.max(target, 60) + target or target)
				local maximum = math.max(minimum, math.min(options.maxWidth or 200, root.AbsoluteSize.X - padding * 2))
				local width = math.max(minimum, math.min(maximum, math.ceil(P.measureText(item.label, { role = "small" }).X) + 30 + (close and target or 0)))
				cell.root.Position, cell.root.Size = UDim2.fromOffset(x, 4), UDim2.new(0, width, 1, -8)
				cell.button.SelectionOrder = index
				cell.label.Size = UDim2.new(1, close and -40 or -24, 1, 0)
				if cell.close then
					cell.close.Visible = close
					cell.close.Position, cell.close.Size = UDim2.new(1, -target, 0, 0), UDim2.new(0, target, 1, 0)
					cell.button.Size = UDim2.new(1, close and -target or 0, 1, 0); cell.label.Size = UDim2.new(1, -24, 1, 0)
				end
				cell.x, cell.width = x, width
				if item.id == selected then selectedCell = cell end
				x = x + width + gap
			end
			x = x - (#handle.items > 0 and gap or 0) + padding
			root.CanvasSize = UDim2.fromOffset(x, 0)
			local left = math.min(root.CanvasPosition.X, math.max(0, x - root.AbsoluteSize.X))
			root.CanvasPosition = Vector2.new(left, 0)
			if revealSelected and selectedCell then reveal(selectedCell, selectedCell.button) end
			layingOut = false
		end
		function handle.set(items, active)
			handle.items, selected = items, active
			local present = {}
			for _, item in ipairs(items) do
				local cell = cells[item.id]; if not cell then cell = create(item); cells[item.id] = cell end
				cell.item, cell.label.Text, present[item.id] = item, item.label, true
				paint(cell)
			end
			for id, cell in pairs(cells) do if not present[id] then cell.root:Destroy(); cells[id] = nil end end
			layout(selected ~= selectedBefore); selectedBefore = selected
		end
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() layout(true) end)
		handle.cells, handle.layout = cells, layout
		return handle
	end
	return M
end
