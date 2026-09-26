return function(env)
	local C = env.require("core")
	local T = env.require("theme")
	local Window = {}
	Window.__index = Window
	local function parentScreen(screen, requested)
		if requested then
			assert(typeof(requested) == "Instance", "Parent must be a Roblox instance")
			screen.Parent = requested
			return
		end
		if type(gethui) == "function" then
			local ok, parent = pcall(gethui)
			if ok and parent and pcall(function() screen.Parent = parent end) then return end
		end
		if pcall(function() screen.Parent = env.services.CoreGui end) then return end
		local player = env.services.Players.LocalPlayer
		assert(player, "UI LIB requires a local player or an explicit Parent")
		screen.Parent = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
		assert(screen.Parent, "UI LIB could not find PlayerGui")
	end
	function Window:Give(resource) return self._scope:Add(resource) end
	function Window:OnDestroy(callback) return self:Give(callback) end
	function Window:Get(id) return self.Controls[id] end
	function Window:Tab(options) return env.require("containers").tab(self, options) end
	function Window:Notify(options) return env.require("overlays").notify(self, options) end
	function Window:Dialog(options) return env.require("overlays").dialog(self, options) end
	function Window:Confirm(options)
		options = options or {}
		return self:Dialog({
			Title = options.Title or "Confirm action", Content = options.Content,
			Buttons = {
				{ Text = options.CancelText or "Cancel" },
				{ Text = options.ConfirmText or "Confirm", Style = options.Danger and "Danger" or "Primary", Callback = options.Callback },
			},
		})
	end
	function Window:_CloseOverlay()
		if self._overlay then self._overlay:Close() end
	end
	function Window:_Refresh()
		if not self.Alive then return end
		for binding in pairs(self._paint) do
			if binding.node.Parent then
				for key, value in pairs(binding.properties) do
					if type(value) == "function" then binding.node[key] = value(self.Theme)
					else binding.node[key] = self.Theme[value] end
				end
			end
		end
	end
	function Window:SetTheme(name, accent)
		self.Theme = T.resolve(name, accent)
		self._themeName, self._accent = name or "Dark", accent
		self:_Refresh()
		return self
	end
	function Window:SetTextScale(value)
		assert(C.finite(value), "TextScale must be a finite number")
		self.TextScale = C.clamp(value, 0.85, 1.5)
		self:_Refresh()
		self:_Layout()
		return self
	end
	function Window:SetTitle(title, subtitle)
		assert(self.Alive, "Window is destroyed")
		self.Title = tostring(title)
		self._title.Text, self._launcherTitle.Text = self.Title, self.Title
		if subtitle ~= nil then self._subtitle.Text = tostring(subtitle) end
		self:_Layout()
		return self
	end
	function Window:_ReleaseKeys()
		for binding in pairs(self._keys) do if binding.release then binding.release() end end
	end
	function Window:_CancelCapture()
		if self._captureControl then self._captureControl:_CancelInteraction() end
		self._capture, self._captureControl = nil, nil
	end
	function Window:Show()
		if not self.Alive then return self end
		self.Visible = true
		self.Frame.Visible, self._launcher.Visible = true, false
		self:_Layout()
		return self
	end
	function Window:Hide()
		if not self.Alive then return self end
		self:_CloseOverlay()
		self:_CancelCapture()
		self:_ReleaseKeys()
		self._gesture = nil
		self.Visible = false
		self.Frame.Visible, self._launcher.Visible = false, false
		pcall(function()
			local selected = env.services.GuiService.SelectedObject
			if selected and selected:IsDescendantOf(self.ScreenGui) then env.services.GuiService.SelectedObject = nil end
		end)
		return self
	end
	function Window:Minimize()
		self:Hide()
		if self.Alive then self._launcher.Visible = true end
		return self
	end
	function Window:Toggle()
		if self.Visible then return self:Minimize() end
		return self:Show()
	end
	function Window:Destroy()
		if not self.Alive then return end
		self:_CloseOverlay()
		self:_CancelCapture()
		self:_ReleaseKeys()
		self.Alive, self.Visible = false, false
		self._gesture, self._capture = nil, nil
		if env.windows[self.Id] == self then env.windows[self.Id] = nil end
		self._scope:Destroy()
		self.ScreenGui:Destroy()
		self.Controls, self.Tabs, self._toasts = {}, {}, {}
	end
	function Window:SelectTab(target)
		local tab = target
		if type(target) == "string" then
			tab = nil
			for _, candidate in ipairs(self.Tabs) do
				if candidate.Id == target then tab = candidate; break end
			end
		end
		assert(tab and tab._window == self and tab.Alive, "Unknown tab")
		if not tab.Visible then return self end
		self:_CloseOverlay()
		self:_CancelCapture()
		self:_ReleaseKeys()
		self._gesture = nil
		self._activeTab = tab
		for _, candidate in ipairs(self.Tabs) do candidate.Frame.Visible = candidate == tab and candidate.Visible end
		self:_Refresh()
		self:_Filter()
		return self
	end
	function Window:_Filter()
		local query = string.lower(self._search and self._search.Text or "")
		local count = 0
		for _, tab in ipairs(self.Tabs) do
			for _, section in ipairs(tab.Sections) do
				local matches = 0
				for _, control in ipairs(section.Controls) do
					local haystack = string.lower(control.Text .. " " .. control.Description .. " " .. section.Title)
					local visible = control.Visible and (query == "" or haystack:find(query, 1, true) ~= nil)
					control.Frame.Visible = visible
					if visible then matches = matches + 1 end
				end
				section.Frame.Visible = section.Visible and (matches > 0 or query == "")
				section._body.Visible = not section.Collapsed or query ~= ""
				if section.Visible and tab == self._activeTab then count = count + matches end
			end
		end
		self._empty.Visible = query ~= "" and count == 0
	end
	function Window:_RevealFocused()
		local focused = env.services.UserInputService:GetFocusedTextBox()
		if not focused or not focused:IsDescendantOf(self.ScreenGui) then return end
		local ancestor = focused.Parent
		while ancestor and ancestor ~= self.ScreenGui do
			if ancestor:IsA("ScrollingFrame") then
				local top = focused.AbsolutePosition.Y - ancestor.AbsolutePosition.Y
				local bottom = top + focused.AbsoluteSize.Y
				local height = ancestor.AbsoluteSize.Y
				local y = ancestor.CanvasPosition.Y
				if top < 8 then y = y + top - 8
				elseif bottom > height - 8 then y = y + bottom - height + 8 end
				ancestor.CanvasPosition = Vector2.new(ancestor.CanvasPosition.X, math.max(0, y))
			end
			ancestor = ancestor.Parent
		end
	end
	function Window:_Layout()
		if not self.Alive then return end
		local uis = env.services.UserInputService
		self.Touch = uis.TouchEnabled == true
		self.Target = math.max(self.Touch and T.Size.TouchTarget or T.Size.Target, math.ceil(36 * self.TextScale))
		local size, origin = self._viewport.AbsoluteSize, self._viewport.AbsolutePosition
		if size.X < 1 or size.Y < 1 then
			local camera = env.services.Workspace.CurrentCamera
			size = camera and camera.ViewportSize or Vector2.new(800, 600)
		end
		local availableHeight = size.Y
		pcall(function()
			if uis.OnScreenKeyboardVisible then
				local keyboard = uis.OnScreenKeyboardSize
				local top = uis.OnScreenKeyboardPosition.Y
				availableHeight = top > 0 and math.min(size.Y, top - origin.Y) or size.Y - keyboard.Y
			end
		end)
		availableHeight = math.max(1, availableHeight)
		local margin = math.min(self.Touch and 8 or 16, size.X / 10, availableHeight / 10)
		local width = math.max(1, math.min(self._requestedWidth, size.X - margin * 2))
		local height = math.max(1, math.min(self._requestedHeight, availableHeight - margin * 2))
		if self.Touch and width < T.Size.Compact and self._autoHeight then height = math.max(1, availableHeight - margin * 2) end
		local x = self._position and self._position.X or (size.X - width) / 2
		local y = self._position and self._position.Y or (availableHeight - height) / 2
		x = C.clamp(x, margin, math.max(margin, size.X - width - margin))
		y = C.clamp(y, margin, math.max(margin, availableHeight - height - margin))
		self._rect = { x = margin, y = margin, width = math.max(1, size.X - margin * 2), height = math.max(1, availableHeight - margin * 2) }
		self._width, self._height = width, height
		self._compact = width < T.Size.Compact or height < 380
		local short = height < 380
		local titleHeight = math.ceil(26 * self.TextScale)
		local subtitleHeight = math.ceil(18 * self.TextScale)
		local header = short and math.max(52, self.Target + 8) or math.max(T.Size.Header, 14 + titleHeight + 3 + subtitleHeight + 12)
		local nav = self._compact and math.max(T.Size.Tabs, self.Target + 8) or 0
		local sidebar = self._compact and 0 or math.floor(T.Size.Sidebar * math.min(1.28, self.TextScale))
		local searchVisible = self._search and (height >= 300 or uis:GetFocusedTextBox() == self._search)
		local search = searchVisible and self.Target + 12 or 0
		local footer = T.Size.Footer
		if self._compact and height < 240 then nav = 0 end
		if height < header + footer + self.Target then header = 0 end
		self.Frame.Size = UDim2.fromOffset(math.floor(width), math.floor(height))
		self.Frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
		self._header.Size = UDim2.new(1, 0, 0, header)
		self._header.Visible = header > 0
		self._title.Position = UDim2.fromOffset(20, short and 12 or 14)
		self._title.Size = UDim2.new(1, -2 * self.Target - 52, 0, titleHeight)
		self._subtitle.Visible = not short and self._subtitle.Text ~= ""
		self._subtitle.Position = UDim2.fromOffset(20, 17 + titleHeight)
		self._subtitle.Size = UDim2.new(1, -2 * self.Target - 52, 0, subtitleHeight)
		self._headerActions.Position = UDim2.new(1, -self.Target * 2 - 20, 0, (header - self.Target) / 2)
		self._headerActions.Size = UDim2.fromOffset(self.Target * 2 + 4, self.Target)
		self._minimize.Size, self._close.Size = UDim2.fromOffset(self.Target, self.Target), UDim2.fromOffset(self.Target, self.Target)
		self._nav.Position = UDim2.fromOffset(0, header)
		self._nav.Visible = not self._compact or nav > 0
		self._nav.Size = self._compact and UDim2.new(1, 0, 0, nav) or UDim2.new(0, sidebar, 1, -header - footer)
		self._navLayout.FillDirection = self._compact and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
		self._nav.ScrollingDirection = self._compact and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
		self._nav.AutomaticCanvasSize = self._compact and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
		self._nav.ScrollBarThickness = self._compact and 0 or T.Size.Scrollbar
		self._navPad.PaddingTop = UDim.new(0, self._compact and 4 or 14)
		for _, tab in ipairs(self.Tabs) do
			local tabWidth = self._compact and math.max(96, math.min(220, #tab.Title * 8 * self.TextScale + 52)) or sidebar - 24
			tab._button.Size = UDim2.fromOffset(tabWidth, self.Target)
		end
		local top = header + nav
		self._contentWidth = math.max(1, width - sidebar)
		self._content.Position = UDim2.fromOffset(sidebar, top + search)
		self._content.Size = UDim2.fromOffset(self._contentWidth, math.max(0, height - top - search - footer))
		if self._search then
			self._search.Visible = searchVisible == true
			self._search.Position = UDim2.fromOffset(sidebar + 20, top + 6)
			self._search.Size = UDim2.new(1, -sidebar - 40, 0, self.Target)
		end
		self._resize.Visible = not self.Touch
		self._launcher.Position = UDim2.fromOffset(margin, math.max(margin, availableHeight - 64 - margin))
		self._launcher.Size = UDim2.fromOffset(math.min(240, size.X - margin * 2), 64)
		self._toastHost.Position = UDim2.new(1, -margin, 1, -margin - (size.Y - availableHeight))
		self._toastHost.Size = UDim2.fromOffset(math.min(360, size.X - margin * 2), math.max(1, availableHeight - margin * 2))
		for callback in pairs(self._reflow) do callback() end
	end
	function Window.new(options)
		options = options or {}
		local id = options.Id or options.Title or "project-uai"
		assert(type(id) == "string" and #id > 0 and #id <= 100, "Window Id must contain 1-100 characters")
		local theme = T.resolve(options.Theme, options.Accent)
		if options.Parent ~= nil then assert(typeof(options.Parent) == "Instance", "Parent must be a Roblox instance") end
		if options.ToggleKey ~= nil and options.ToggleKey ~= false then
			assert(typeof(options.ToggleKey) == "EnumItem" and tostring(options.ToggleKey):find("Enum.KeyCode.", 1, true) == 1, "ToggleKey must be an Enum.KeyCode or false")
		end
		local toggleKey = options.ToggleKey
		if toggleKey == nil then toggleKey = Enum.KeyCode.RightShift end
		if env.windows[id] then env.windows[id]:Destroy() end
		local self = setmetatable({
			Id = id, Title = tostring(options.Title or "Project UAI"), Alive = true, Visible = true,
			Theme = theme, TextScale = C.number(options.TextScale, 1, 0.85, 1.5),
			_themeName = options.Theme or "Dark", _accent = options.Accent,
			_scope = C.scope(), _paint = {}, _paintNodes = {}, _reflow = {}, _keys = {}, Controls = {}, Tabs = {}, _toasts = {},
			_requestedWidth = C.number(options.Width, T.Size.Width, 280, 1600),
			_requestedHeight = C.number(options.Height, T.Size.Height, 240, 1200),
			_autoHeight = options.Height == nil,
			ToggleKey = toggleKey,
		}, Window)
		self._window = self
		self.ScreenGui = Instance.new("ScreenGui")
		self.ScreenGui.Name = "ProjectUAI_UI_" .. id
		self.ScreenGui.ResetOnSpawn = false
		self.ScreenGui.IgnoreGuiInset = false
		self.ScreenGui.DisplayOrder = C.number(options.DisplayOrder, 80, 0, 10000)
		self.ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		pcall(function() self.ScreenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets end)
		local ok, why = pcall(parentScreen, self.ScreenGui, options.Parent)
		if not ok then self.ScreenGui:Destroy(); error(why, 0) end
		self._viewport = C.node(self, "Frame", self.ScreenGui, { Name = "SafeViewport", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
		self.Frame = C.node(self, "Frame", self._viewport, { Name = "Window", Active = true, ClipsDescendants = true }, { BackgroundColor3 = "Canvas" })
		C.corner(self.Frame, T.Size.Radius)
		C.stroke(self, self.Frame, "Border")
		self._header = C.node(self, "Frame", self.Frame, { Name = "Header", BackgroundTransparency = 1, Active = true })
		self._title = C.text(self, self._header, self.Title, "Title", "Text", { TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		self._subtitle = C.text(self, self._header, options.Subtitle or "", "Caption", "Muted", { TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		C.node(self, "Frame", self._header, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1) }, { BackgroundColor3 = "Subtle" })
		self._headerActions = C.node(self, "Frame", self._header, { BackgroundTransparency = 1 })
		C.list(self._headerActions, true, 4)
		local function headerButton(name, icon, callback)
			local button = C.node(self, "TextButton", self._headerActions, { Name = name })
			C.corner(button)
			C.feedback(self, button)
			local glyph = C.icon(self, button, icon)
			glyph.AnchorPoint, glyph.Position = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
			self._scope:Connect(button.Activated, callback)
			return button
		end
		self._minimize = headerButton("Minimize", "minus", function() self:Minimize() end)
		self._close = headerButton("Close", "close", function() self:Destroy() end)
		self._nav = C.scroll(self, self.Frame, "Tabs")
		C.bind(self, self._nav, { BackgroundColor3 = "Sidebar" })
		self._nav.BackgroundTransparency = 0
		self._navLayout = C.list(self._nav, false, 6)
		self._navPad = C.pad(self._nav, 12, 14)
		self._content = C.node(self, "Frame", self.Frame, { Name = "Content", BackgroundTransparency = 1, ClipsDescendants = true })
		self._empty = C.text(self, self._content, "No matching controls", "Body", "Muted", { Name = "EmptySearch", Visible = false, Position = UDim2.fromOffset(20, 28), Size = UDim2.new(1, -40, 0, 40) })
		if options.Search ~= false then
			self._search = C.node(self, "TextBox", self.Frame, {
				Name = "Search", Text = "", PlaceholderText = "Search this tab", ClearTextOnFocus = false,
				Font = C.Font, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
			}, { BackgroundColor3 = "Surface", TextColor3 = "Text", PlaceholderColor3 = "Muted", TextSize = function() return 14 * self.TextScale end })
			C.corner(self._search); C.pad(self._search, 12, 0); C.stroke(self, self._search)
			self._scope:Connect(self._search:GetPropertyChangedSignal("Text"), function()
				self:_Filter()
				if self._activeTab then self._activeTab.Frame.CanvasPosition = Vector2.new(0, 0) end
			end)
		end
		C.footer(self, self.Frame)
		self._resize = C.node(self, "TextButton", self.Frame, {
			Name = "Resize", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(24, 24), Selectable = false,
		})
		for index = 1, 3 do
			C.node(self, "Frame", self._resize, { Position = UDim2.fromOffset(8 + index * 3, 20), Size = UDim2.fromOffset(2, 2 + index * 3), Rotation = 45 }, { BackgroundColor3 = "Muted" })
		end
		self._launcher = C.node(self, "TextButton", self._viewport, { Name = "Restore", Visible = false, ClipsDescendants = true }, { BackgroundColor3 = "Canvas" })
		C.corner(self._launcher, 10); C.stroke(self, self._launcher)
		self._launcherTitle = C.text(self, self._launcher, self.Title, "Heading", "Text", { Position = UDim2.fromOffset(12, 4), Size = UDim2.new(1, -24, 0, 28), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		C.footer(self, self._launcher)
		self._scope:Connect(self._launcher.Activated, function() self:Show() end)
		self._toastHost = C.node(self, "Frame", self._viewport, { Name = "Notifications", AnchorPoint = Vector2.new(1, 1), BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 200 })
		local toastLayout = C.list(self._toastHost, false, 8)
		toastLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		self:_Layout()

		local dragStart, frameStart, sizeStart
		C.pointer(self, self._header, function(input)
			if C.isInside(self._headerActions, input.Position.X, input.Position.Y) then return false end
			dragStart, frameStart = input.Position, self.Frame.Position
		end, function(input)
			self._position = Vector2.new(frameStart.X.Offset + input.Position.X - dragStart.X, frameStart.Y.Offset + input.Position.Y - dragStart.Y)
			self:_Layout()
		end)
		C.pointer(self, self._resize, function(input)
			dragStart, sizeStart = input.Position, self.Frame.AbsoluteSize
			self._position = Vector2.new(self.Frame.Position.X.Offset, self.Frame.Position.Y.Offset)
		end, function(input)
			self._requestedWidth = math.max(280, sizeStart.X + input.Position.X - dragStart.X)
			self._requestedHeight = math.max(240, sizeStart.Y + input.Position.Y - dragStart.Y)
			self:_Layout()
		end)
		local uis = env.services.UserInputService
		self._scope:Connect(uis.InputChanged, function(input)
			local gesture = self._gesture
			if not gesture then return end
			local touch = gesture.input.UserInputType == Enum.UserInputType.Touch
			if (touch and input == gesture.input) or (not touch and input.UserInputType == Enum.UserInputType.MouseMovement) then
				if gesture.owner._scope.alive and gesture.move then gesture.move(input) end
			end
		end)
		self._scope:Connect(uis.InputEnded, function(input)
			local gesture = self._gesture
			if gesture then
				local touch = gesture.input.UserInputType == Enum.UserInputType.Touch
				if (touch and input == gesture.input) or (not touch and input.UserInputType == Enum.UserInputType.MouseButton1) then
					self._gesture = nil
					if gesture.owner._scope.alive and gesture.finish then gesture.finish(input) end
				end
			end
			for binding in pairs(self._keys) do if binding.ended then binding.ended(input) end end
		end)
		self._scope:Connect(uis.InputBegan, function(input, processed)
			if self._capture then self._capture(input); return end
			if self._overlay and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB) then
				if self._overlay.Dismissible then self:_CloseOverlay() end
				return
			end
			if processed or uis:GetFocusedTextBox() then return end
			if self.ToggleKey and input.KeyCode == self.ToggleKey then self:Toggle(); return end
			if self._overlay then return end
			for binding in pairs(self._keys) do if binding.began then binding.began(input) end end
		end)
		self._scope:Connect(uis.WindowFocusReleased, function() self._gesture = nil; self:_CancelCapture(); self:_ReleaseKeys() end)
		self._scope:Connect(self._viewport:GetPropertyChangedSignal("AbsoluteSize"), function() self:_Layout() end)
		local cameraRelease
		local function cameraChanged()
			if cameraRelease then cameraRelease(); cameraRelease = nil end
			local camera = env.services.Workspace.CurrentCamera
			if camera then cameraRelease = self._scope:Add(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function() self:_Layout() end)) end
			self:_Layout()
		end
		self._scope:Connect(env.services.Workspace:GetPropertyChangedSignal("CurrentCamera"), cameraChanged)
		cameraChanged()
		for _, property in ipairs({ "OnScreenKeyboardVisible", "OnScreenKeyboardSize", "OnScreenKeyboardPosition", "TouchEnabled" }) do
			pcall(function()
				self._scope:Connect(uis:GetPropertyChangedSignal(property), function()
					self:_Layout()
					self._scope:Delay(0.05, function() self:_RevealFocused() end)
				end)
			end)
		end
		self._scope:Connect(uis.TextBoxFocused, function() self._scope:Delay(0.05, function() self:_RevealFocused() end) end)
		self._scope:Connect(self.ScreenGui.Destroying, function() self:Destroy() end)
		self._scope:Connect(self.Frame.Destroying, function() self:Destroy() end)
		env.windows[id] = self
		if options.OnDestroy then self:OnDestroy(options.OnDestroy) end
		return self
	end
	return Window
end
