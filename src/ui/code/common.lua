return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local overlay = env.require("ui/overlay")
	local caps = env.require("runtime/caps")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local M = {}
	function M.inset() return math.max(8, theme.space.sm) end
	function M.gap() return math.max(4, theme.space.xs) end
	function M.controlHeight() return math.max(theme.size.controlSmall, responsive.minTarget(), theme.text.small.height + 12, theme.size.icon + 16) end
	function M.barHeight() return math.max(theme.size.codeToolbar, M.controlHeight() + 8) end
	local function buttonPadding(props) return math.max(8, props.padX or (props.tight and theme.space.sm or theme.space.md)) end
	function M.buttonWidth(label, props)
		props = props or {}
		if props.iconOnly or (props.icon and (not label or label == "")) then return M.controlHeight() end
		local width = P.measureText(label or "", { role = "small" }).X + buttonPadding(props) * 2 + 4
		if props.icon then width = width + theme.size.icon + theme.space.xs end
		if props.trailing then width = width + theme.size.icon + theme.space.xs end
		return math.max(props.minWidth or 0, M.controlHeight(), math.ceil(width))
	end
	function M.button(parent, props)
		props = util.copy(props or {}); props.size = props.size or "sm"; props.padX = buttonPadding(props)
		local button = P.button(parent, props)
		local size = button.instance.Size
		button.instance.Size = UDim2.new(size.X.Scale, size.X.Offset, 0, M.controlHeight())
		return button
	end
	-- Padded controls retain their hit targets. A crowded strip scrolls instead
	-- of removing a title's padding or overlapping the actions beside it.
	function M.toolbar(parent, options)
		options = options or {}
		local root = P.frame(parent, { name = options.name or "WorkspaceToolbar", size = UDim2.new(1, 0, 0, M.barHeight()), clip = true })
		local controls = P.scroll(root, { name = "ToolbarControls", horizontal = true, gap = 0, bar = 0 })
		controls.layout:Destroy(); controls.instance.AutomaticCanvasSize = Enum.AutomaticSize.None
		if options.divider ~= false then
			P.frame(root, { name = "ToolbarRule", size = UDim2.new(1, 0, 0, theme.stroke.hair),
				position = UDim2.new(0, 0, 1, -theme.stroke.hair), bg = theme.color.borderSubtle })
		end
		local buttons = {}
		local gap, padX = math.max(4, options.gap or M.gap()), math.max(8, options.padding or M.inset())
		local function widthOf(item) return M.buttonWidth(item.label, item) end
		local function place(item, x, w)
			local height = M.controlHeight()
			item.button.instance.Position = UDim2.fromOffset(math.floor(x), math.max(4, math.floor((root.AbsoluteSize.Y - height) / 2)))
			item.button.instance.Size = UDim2.fromOffset(math.max(1, math.floor(w)), height)
		end
		local layingOut = false
		local function layout()
			if layingOut then return end
			local width = root.AbsoluteSize.X
			if width <= 0 then return end
			layingOut = true
			local visibleButtons, widths, natural = {}, {}, padX * 2
			for _, item in ipairs(buttons) do
				if item.button.instance.Visible then
					visibleButtons[#visibleButtons + 1] = item
					widths[#visibleButtons] = widthOf(item); natural = natural + widths[#visibleButtons]
				end
			end
			natural = natural + math.max(0, #visibleButtons - 1) * gap
			for index, item in ipairs(visibleButtons) do
				if item.flex and natural > width then
					local minimum = buttonPadding(item) * 2 + 36 + (item.icon and theme.size.icon + theme.space.xs or 0) + (item.trailing and theme.size.icon + theme.space.xs or 0)
					local reduction = math.min(natural - width, math.max(0, widths[index] - minimum))
					widths[index], natural = widths[index] - reduction, natural - reduction
				end
			end
			local canvasWidth = math.max(width, natural)
			local split = #visibleButtons
			if natural <= width then for i, item in ipairs(visibleButtons) do if item.flex then split = i; break end end end
			local x = padX
			for i = 1, split do
				local item = visibleButtons[i]
				local w = widths[i]
				place(item, x, w)
				x = x + w + gap
			end
			local rx = canvasWidth - padX
			for i = #visibleButtons, split + 1, -1 do
				local w = widths[i]
				rx = rx - w
				place(visibleButtons[i], rx, w)
				rx = rx - gap
			end
			controls.instance.CanvasSize = UDim2.fromOffset(canvasWidth, 0)
			controls.instance.ScrollingEnabled = canvasWidth > width
			controls.instance.ScrollBarThickness = canvasWidth > width and 2 or 0
			controls.instance.CanvasPosition = Vector2.new(math.min(controls.instance.CanvasPosition.X, math.max(0, canvasWidth - width)), 0)
			layingOut = false
		end
		local bar = { root = root, controls = controls.instance, buttons = buttons, layout = layout }
		function bar.width()
			local width, count = padX * 2, 0
			for _, item in ipairs(buttons) do if item.button.instance.Visible then width = width + widthOf(item); count = count + 1 end end
			return width + math.max(0, count - 1) * gap
		end
		function bar.add(label, callback, props)
			props = props or {}
			local isDrop = props.flex or props.dropdown
			local trailing = props.trailing
			if isDrop and trailing == nil then trailing = "chevron" end
			local iconOnly = props.iconOnly or (props.icon and (label == "" or label == nil))
			local buttonText = iconOnly and "" or label
			local button = M.button(controls.instance, { text = buttonText, fill = true, size = "sm",
				variant = props.variant or (isDrop and "soft" or "ghost"),
				onClick = callback, name = props.name, enabled = props.enabled,
				icon = props.icon, padX = props.padX, align = isDrop and "Left" or props.align, trailing = trailing,
				trailingColor = isDrop and theme.color.textTertiary or props.trailingColor,
				tight = props.tight or iconOnly })
			local item = { button = button, label = buttonText, flex = props.flex, icon = props.icon,
				trailing = trailing, minWidth = props.minWidth, iconOnly = iconOnly, tight = props.tight,
				padX = buttonPadding(props) }
			buttons[#buttons + 1] = item
			local setText = button.setText
			button.setText = function(text)
				if not item.iconOnly then setText(text); item.label = tostring(text) end
				layout()
			end
			button.instance:GetPropertyChangedSignal("Visible"):Connect(layout)
			button.instance.SelectionGained:Connect(function()
				local at, width = button.instance.Position.X.Offset, button.instance.Size.X.Offset
				local left, viewport = controls.instance.CanvasPosition.X, root.AbsoluteSize.X
				if at < left + padX then left = math.max(0, at - padX)
				elseif at + width > left + viewport - padX then left = math.max(0, at + width + padX - viewport) end
				controls.instance.CanvasPosition = Vector2.new(left, 0)
			end)
			layout(); return button
		end
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		return bar
	end
	function M.clear(parent)
		for _, child in ipairs(parent:GetChildren()) do if not child:IsA("UIComponent") then child:Destroy() end end
	end
	function M.work(fn, completed)
		env.require("runtime/clock").spawn(function()
			local ok, result, why = pcall(fn)
			if not ok then M.message(nil, result)
			elseif M.message(result, why) and completed then completed(result) end
		end)
	end
	function M.message(result, why)
		if not result then overlay.toast(tostring(why or "Operation unavailable"), "bad", 6); return false end
		if type(result) == "table" and result.ok == false then overlay.toast(result.text or result.status, "warn", 6); return false end
		return true
	end
	function M.copy(text)
		if not caps.clipboard then overlay.code({ title = "Select and copy", text = text, code = text }); return end
		local ok, why = pcall(caps.fn.clipboard, text); if not ok then overlay.toast(tostring(why), "bad") end
	end
	function M.menu(target, title, options, onSelect)
		local anchor = target
		if type(target) == "table" and typeof(target) ~= "Instance" then anchor = target.instance or target end
		return overlay.menu({ target = anchor, title = title, options = options, onSelect = onSelect })
	end
	function M.choice(parent, label, choices, value, onChange, order)
		local button
		button = M.button(parent, { text = label .. ": " .. tostring(value), fill = true, size = "sm", layoutOrder = order, onClick = function()
			local options = {}; for _, item in ipairs(choices) do options[#options + 1] = { label = tostring(item), value = item, selected = item == value } end
			M.menu(button, label, options, function(selected) value = selected; button.setText(label .. ": " .. tostring(value)); onChange(value) end)
		end })
		return button
	end
	function M.virtualList(parent, options)
		return env.require("ui/code/list").new(parent, options)
	end
	function M.ask(reference)
		local app = env.require("ui/app"); app.show("chat")
		local composer = app.chatPanel and app.chatPanel.composer
		if composer and composer.field then
			local text = composer.field.get(); composer.field.set(text .. (text ~= "" and "\n" or "") .. reference)
		end
	end
	return M
end
