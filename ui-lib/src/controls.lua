return function(env)
	local C = env.require("core")
	local M, Control = {}, {}
	Control.__index = Control

	function Control:Get() return C.copy(self._value) end
	function Control:Set(value, silent)
		assert(self.Alive, "Control is destroyed")
		if self._normalize then value = self._normalize(value) end
		local changed = not C.equal(value, self._value)
		self._value = C.copy(value)
		if self._render then self._render() end
		if changed and not silent then self:_Emit() end
		return self
	end
	function Control:Reset(silent) return self:Set(self._default, silent) end
	function Control:_Emit()
		C.call(self._window, self._callback, self:Get())
		if not self.Alive then return end
		for callback in pairs(self._listeners) do
			C.call(self._window, callback, self:Get())
			if not self.Alive then break end
		end
	end
	function Control:OnChanged(callback)
		assert(self.Alive, "Control is destroyed")
		assert(type(callback) == "function", "OnChanged expects a function")
		self._listeners[callback] = true
		return function() self._listeners[callback] = nil end
	end
	function Control:_Interactive()
		return self.Alive and self._window.Alive and self._window.Visible and self.Visible and not self.Disabled
			and self._section.Visible and self.Frame.Visible and self._section._body.Visible and self._section._tab.Frame.Visible
	end
	function Control:_CancelInteraction()
		local window = self._window
		if window._gesture and window._gesture.owner == self then window._gesture = nil end
		if self._cancel then self._cancel() end
		if window._overlay and window._overlay.Control == self then window:_CloseOverlay() end
	end
	function Control:SetDisabled(disabled)
		self.Disabled = disabled == true
		if self.Disabled then self:_CancelInteraction() end
		for _, input in ipairs(self._inputs) do
			input.Active, input.Selectable = not self.Disabled, not self.Disabled
			if input:IsA("TextBox") then input.TextEditable = not self.Disabled end
		end
		if self._render then self._render() end
		self._window:_Refresh()
		return self
	end
	function Control:SetVisible(visible)
		self.Visible = visible == true
		if not self.Visible then self:_CancelInteraction() end
		self._window:_Filter()
		return self
	end
	function Control:SetText(text)
		self.Text = tostring(text)
		self._label.Text = self.Text
		self._layout()
		self._window:_Filter()
		return self
	end
	function Control:SetDescription(text)
		self.Description = tostring(text)
		self._description.Text = self.Description
		self._layout()
		self._window:_Filter()
		return self
	end
	function Control:Destroy()
		if not self.Alive then return end
		self:_CancelInteraction()
		self.Alive = false
		if self.Id then self._window.Controls[self.Id] = nil end
		for index, control in ipairs(self._section.Controls) do if control == self then table.remove(self._section.Controls, index); break end end
		self._scope:Destroy()
		self._listeners = {}
		self.Frame:Destroy()
	end
	function M.base(section, kind, options, mode, slotWidth)
		assert(section.Alive and section._window.Alive, "Section is destroyed")
		options = options or {}
		local window = section._window
		if options.Id then
			assert(type(options.Id) == "string" and #options.Id > 0, "Control Id must be a nonempty string")
			assert(not window.Controls[options.Id], "Duplicate control Id: " .. options.Id)
		end
		assert(options.Callback == nil or type(options.Callback) == "function", "Callback must be a function")
		local self = setmetatable(C.owner(window, section._scope), Control)
		self.Kind, self.Id, self.Text, self.Description = kind, options.Id, tostring(options.Text or kind), tostring(options.Description or "")
		self.Alive, self.Visible, self.Disabled = true, options.Visible ~= false, options.Disabled == true
		self.Persist = options.Persist ~= false
		self._section, self._callback, self._listeners, self._inputs = section, options.Callback, {}, {}
		self._scope:Add(function() self.Alive = false; self._listeners = {} end)
		self._mode, self._slotWidth = mode or "inline", slotWidth or 120
		self.Frame = C.node(self, "Frame", section._body, {
			Name = options.Id and ("Control_" .. options.Id) or kind, BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 64), LayoutOrder = #section.Controls + 1, Visible = self.Visible,
		})
		self._scope:Connect(self.Frame.Destroying, function() self:Destroy() end)
		if #section.Controls > 0 then
			C.node(self, "Frame", self.Frame, { Name = "RowRule", Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -32, 0, 1) }, { BackgroundColor3 = "Subtle" })
		end
		self._label = C.text(self, self.Frame, self.Text, "Body", "Text", { Name = "Label", TextYAlignment = Enum.TextYAlignment.Top })
		C.bind(self, self._label, { TextColor3 = function(theme) return self.Disabled and theme.Muted or theme.Text end })
		self._description = C.text(self, self.Frame, self.Description, "Caption", "Muted", { Name = "Description", TextYAlignment = Enum.TextYAlignment.Top })
		self._slot = C.node(self, "Frame", self.Frame, { Name = "Value", BackgroundTransparency = 1 })
		self._layout = function()
			if not self.Alive then return end
			local width = math.max(1, window._contentWidth - 72)
			local stacked = self._mode == "stack" or (self._mode == "inline" and self._slotWidth > 64 and width < 280 * window.TextScale)
			self._stacked = stacked
			local content = self._mode == "content"
			local slot = math.min(self._slotWidth, width * 0.48)
			local labelWidth = (stacked or content) and width or math.max(1, width - slot - 16)
			if self._labelReserve then labelWidth = math.max(1, labelWidth - self._labelReserve) end
			local titleHeight = self.Text ~= "" and C.measure(self.Text, 14 * window.TextScale, labelWidth) or 0
			local descriptionHeight = self.Description ~= "" and C.measure(self.Description, 12 * window.TextScale, labelWidth) or 0
			local captionHeight = titleHeight + (descriptionHeight > 0 and descriptionHeight + 5 or 0)
			local slotHeight = self._slotHeight and self._slotHeight() or window.Target
			local height = 28 + ((stacked and captionHeight + 10 + slotHeight) or (content and captionHeight) or math.max(captionHeight, slotHeight))
			self.Frame.Size = UDim2.new(1, 0, 0, math.ceil(height))
			local textTop = 14 + math.max(0, (slotHeight - captionHeight) / 2)
			if stacked or content then textTop = 14 end
			self._label.Position = UDim2.fromOffset(16, textTop)
			self._label.Size = UDim2.fromOffset(labelWidth, titleHeight)
			self._description.Position = UDim2.fromOffset(16, textTop + titleHeight + 5)
			self._description.Size = UDim2.fromOffset(labelWidth, descriptionHeight)
			self._description.Visible = descriptionHeight > 0
			self._slot.Visible = not content
			self._slot.Position = stacked and UDim2.fromOffset(16, 14 + captionHeight + 10) or UDim2.new(1, -16 - slot, 0, 14 + math.max(0, (captionHeight - slotHeight) / 2))
			self._slot.Size = UDim2.fromOffset(stacked and width or slot, slotHeight)
			if self._afterLayout then self._afterLayout(width, slotHeight) end
		end
		C.reflow(self, self._layout)
		section.Controls[#section.Controls + 1] = self
		if self.Id then window.Controls[self.Id] = self end
		return self
	end
	function M.input(control, class, parent, properties)
		local node = C.node(control, class, parent or control._slot, properties)
		control._inputs[#control._inputs + 1] = node
		return node
	end
	function M.action(control, text, style)
		local button = M.input(control, "TextButton", control._slot, { Name = "Action", Size = UDim2.fromScale(1, 1) })
		C.corner(button)
		local refresh = C.feedback(control, button, style, function() return not control.Disabled and not control.Loading end)
		local label = C.text(control, button, text, "Body", "Text", { Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		C.bind(control, label, { TextColor3 = function(theme)
			if control.Disabled or control.Loading then return theme.Muted end
			return (style == "Primary" or style == "Danger") and theme.OnPrimary or theme.Text
		end })
		return button, label, refresh
	end
	function M.Button(section, options)
		local self = M.base(section, "Button", options, "inline", 116)
		self.Loading = false
		local button, label, refresh = M.action(self, options.ActionText or "Run", options.Style)
		self._render = function()
			label.Text = self.Loading and (options.LoadingText or "Working…") or options.ActionText or "Run"
			refresh()
		end
		function self:SetLoading(loading) self.Loading = loading == true; self._render(); return self end
		function self:Press()
			if not self:_Interactive() or self.Loading then return false end
			self:SetLoading(true)
			self._scope:Spawn(function()
				C.call(self._window, options.Callback)
				if self.Alive then self:SetLoading(false) end
			end)
			return true
		end
		self._scope:Connect(button.Activated, function() self:Press() end)
		return self
	end
	local function booleanControl(section, options, checkbox)
		local self = M.base(section, checkbox and "Checkbox" or "Toggle", options, "inline", 48)
		self._normalize = function(value) assert(type(value) == "boolean", "Expected a boolean"); return value end
		local default = options.Default
		if default == nil then default = false end
		self._value = self._normalize(default)
		local hit = M.input(self, "TextButton", self._slot, { Name = "Toggle", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
		local track = C.node(self, "Frame", hit, {
			Name = "Track", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(checkbox and 22 or 38, 22),
		})
		C.corner(track, checkbox and 5 or 11)
		C.stroke(self, track)
		C.bind(self, track, { BackgroundColor3 = function(theme) return self._value and not self.Disabled and theme.Accent or theme.Raised end })
		local thumb
		if checkbox then
			thumb = C.icon(self, track, "check", "OnAccent", 18)
			thumb.Position = UDim2.fromOffset(2, 2)
		else
			thumb = C.node(self, "Frame", track, { Name = "Thumb", AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(16, 16) }, {
				BackgroundColor3 = function(theme) return self._value and not self.Disabled and theme.OnAccent or theme.Secondary end,
			})
			C.corner(thumb, 8)
		end
		self._render = function()
			if checkbox then thumb.Visible = self._value
			else
				thumb.Position = UDim2.new(0, self._value and 19 or 3, 0.5, 0)
				thumb.BackgroundColor3 = self._value and not self.Disabled and self._window.Theme.OnAccent or self._window.Theme.Secondary
			end
			track.BackgroundColor3 = self._value and not self.Disabled and self._window.Theme.Accent or self._window.Theme.Raised
		end
		local focus = C.stroke(self, hit, "Accent")
		focus.Transparency = 1
		self._scope:Connect(hit.SelectionGained, function() focus.Transparency = 0 end)
		self._scope:Connect(hit.SelectionLost, function() focus.Transparency = 1 end)
		self._scope:Connect(hit.Activated, function() if self:_Interactive() then self:Set(not self._value) end end)
		self._render()
		return self
	end
	function M.Toggle(section, options) return booleanControl(section, options, false) end
	function M.Checkbox(section, options) return booleanControl(section, options, true) end
	function M.Slider(section, options)
		local minimum, maximum = options.Min or 0, options.Max or 100
		local step = options.Step or 1
		assert(C.finite(minimum) and C.finite(maximum) and maximum > minimum, "Slider Max must exceed Min")
		assert(C.finite(step) and step > 0, "Slider Step must be positive")
		local self = M.base(section, "Slider", options, "stack")
		self._labelReserve, self.Min, self.Max, self.Step = 96, minimum, maximum, step
		self._normalize = function(value)
			assert(C.finite(value), "Slider value must be a finite number")
			value = C.clamp(value, minimum, maximum)
			if value == maximum then return maximum end
			local result = C.clamp(minimum + math.floor((value - minimum) / step + 0.5) * step, minimum, maximum)
			return tonumber(string.format("%.10g", result))
		end
		self._value = self._normalize(options.Default == nil and minimum or options.Default)
		local value = C.text(self, self.Frame, "", "Caption", "Secondary", { Name = "Readout", TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		self._afterLayout = function(width)
			value.Position = UDim2.new(1, -112, 0, 14)
			value.Size = UDim2.fromOffset(96, 20 * self._window.TextScale)
		end
		local hit = M.input(self, "TextButton", self._slot, { Name = "Slider", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
		local track = C.node(self, "Frame", hit, { Name = "Track", Position = UDim2.new(0, 8, 0.5, -2), Size = UDim2.new(1, -16, 0, 4) }, { BackgroundColor3 = "Border" })
		C.corner(track, 2)
		local fill = C.node(self, "Frame", track, { Name = "Fill", Size = UDim2.fromScale(0, 1) }, { BackgroundColor3 = function(theme) return self.Disabled and theme.Muted or theme.Accent end })
		C.corner(fill, 2)
		local knob = C.node(self, "Frame", track, { Name = "Thumb", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromScale(0, 0.5) }, { BackgroundColor3 = "Text" })
		C.corner(knob, 8); C.stroke(self, knob, "Subtle")
		local focus = C.stroke(self, hit, "Accent"); focus.Transparency = 1; C.corner(hit)
		self._scope:Connect(hit.SelectionGained, function() focus.Transparency = 0 end)
		self._scope:Connect(hit.SelectionLost, function() focus.Transparency = 1 end)
		self._render = function()
			local share = (self._value - minimum) / (maximum - minimum)
			fill.Size, knob.Position = UDim2.fromScale(share, 1), UDim2.fromScale(share, 0.5)
			value.Text = string.format("%.10g", self._value) .. tostring(options.Suffix or "")
			fill.BackgroundColor3 = self.Disabled and self._window.Theme.Muted or self._window.Theme.Accent
		end
		local function update(input)
			if not self:_Interactive() then return end
			local share = C.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
			self:Set(minimum + share * (maximum - minimum))
		end
		C.pointer(self, hit, function(input)
			if not self:_Interactive() then return false end
			update(input)
			return self:_Interactive()
		end, update, function()
			if self:_Interactive() then C.call(self._window, options.OnCommit, self:Get()) end
		end)
		self._scope:Connect(hit.InputBegan, function(input)
			if not self:_Interactive() or env.services.UserInputService:GetFocusedTextBox() then return end
			local key, nextValue = input.KeyCode, nil
			if key == Enum.KeyCode.Left or key == Enum.KeyCode.Down or key == Enum.KeyCode.DPadLeft then nextValue = self._value - step end
			if key == Enum.KeyCode.Right or key == Enum.KeyCode.Up or key == Enum.KeyCode.DPadRight then nextValue = self._value + step end
			if key == Enum.KeyCode.Home then nextValue = minimum end
			if key == Enum.KeyCode.End then nextValue = maximum end
			if nextValue ~= nil then self:Set(nextValue); if self.Alive then C.call(self._window, options.OnCommit, self:Get()) end end
		end)
		self._render(); self._layout()
		return self
	end
	function M.Input(section, options)
		if options.Numeric then
			assert(options.Min == nil or C.finite(options.Min), "Input Min must be finite")
			assert(options.Max == nil or C.finite(options.Max), "Input Max must be finite")
			assert(options.Min == nil or options.Max == nil or options.Min <= options.Max, "Input Max must not be below Min")
		end
		local self = M.base(section, "Input", options, "stack")
		local maxLength = math.floor(C.number(options.MaxLength, 4096, 1, 65536))
		self._normalize = function(value)
			if options.Numeric then
				assert(C.finite(value), "Enter a valid number")
				return C.clamp(value, options.Min or -math.huge, options.Max or math.huge)
			end
			assert(type(value) == "string", "Input value must be a string")
			return C.truncate(value, maxLength)
		end
		self._value = self._normalize(options.Default == nil and (options.Numeric and 0 or "") or options.Default)
		local field = M.input(self, "TextBox", self._slot, {
			Name = "Input", Text = tostring(self._value), PlaceholderText = tostring(options.Placeholder or ""),
			Size = UDim2.fromScale(1, 1), ClearTextOnFocus = false, Font = C.Font, TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left, MultiLine = options.MultiLine == true,
			TextWrapped = options.MultiLine == true, TextYAlignment = options.MultiLine and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
		})
		C.bind(self, field, { BackgroundColor3 = "Raised", TextColor3 = "Text", PlaceholderColor3 = "Muted", TextSize = function() return 14 * self._window.TextScale end })
		C.corner(field); C.pad(field, 12, options.MultiLine and 10 or 0)
		local border = C.stroke(self, field)
		local errorLabel = C.text(self, self._slot, "", "Caption", "Danger", { Name = "Validation", Visible = false })
		local editing, painting = false, false
		self._error = nil
		self._slotHeight = function() return self._window.Target * (options.MultiLine and C.number(options.Lines, 3, 2, 8) or 1) + (self._error and 24 or 0) end
		self._afterLayout = function(_, height)
			field.Size = UDim2.new(1, 0, 0, height - (self._error and 24 or 0))
			errorLabel.Position = UDim2.new(0, 0, 1, -22); errorLabel.Size = UDim2.new(1, 0, 0, 22)
		end
		self._render = function(preserveDraft)
			if not preserveDraft then painting = true; field.Text = tostring(self._value); painting = false end
			self._error, errorLabel.Visible = nil, false
			border.Color = editing and self._window.Theme.Accent or self._window.Theme.Border
			self._layout()
		end
		local function commit(live)
			if painting or not self:_Interactive() then return end
			local raw = options.Numeric and tonumber(field.Text) or field.Text
			local ok, value = pcall(self._normalize, raw)
			if not ok then
				self._error = options.Numeric and "Enter a valid number." or tostring(value)
				errorLabel.Text, errorLabel.Visible, border.Color = self._error, true, self._window.Theme.Danger
				self._layout()
				return
			end
			if live then
				-- Keep the user's draft/caret (for example, "1." or "-0") while
				-- publishing valid state. A normal Set still paints immediately.
				local changed = not C.equal(value, self._value)
				self._value = value
				self._render(true)
				if changed then self:_Emit() end
			else self:Set(value) end
			if self.Alive then C.call(self._window, options.OnCommit, self:Get()) end
		end
		self._scope:Connect(field.Focused, function() editing = true; border.Color = self._window.Theme.Accent end)
		self._scope:Connect(field.FocusLost, function()
			editing = false
			commit()
			if self.Alive then border.Color = self._error and self._window.Theme.Danger or self._window.Theme.Border end
		end)
		self._scope:Connect(field:GetPropertyChangedSignal("Text"), function()
			if painting then return end
			local text = C.truncate(field.Text, maxLength)
			if text ~= field.Text then painting = true; field.Text = text; painting = false end
			if options.Live then commit(true) end
		end)
		function self:Focus() if self:_Interactive() then field:CaptureFocus() end; return self end
		self._layout()
		return self
	end
	function M.Label(section, options)
		return M.base(section, "Label", options, "content")
	end
	function M.Paragraph(section, options)
		local copy = C.copy(options)
		copy.Description = options.Content or options.Description or ""
		return M.base(section, "Paragraph", copy, "content")
	end
	function M.Divider(section, options)
		local self = M.base(section, "Divider", options, "content")
		self._label.Text = string.upper(self.Text)
		return self
	end
	function M.Badge(section, options)
		assert(options.Kind == nil or ({ Success = true, Warning = true, Danger = true, Secondary = true })[options.Kind], "Unknown badge Kind")
		local self = M.base(section, "Badge", options, "inline", 120)
		self._normalize = function(value) assert(type(value) == "string", "Badge value must be a string"); return value end
		self._value = self._normalize(options.Default or options.Value or "Ready")
		local badge = C.node(self, "Frame", self._slot, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(1, 0, 0, 28) }, { BackgroundColor3 = "Raised" })
		C.corner(badge, 5)
		self._afterLayout = function(width)
			badge.AnchorPoint = Vector2.new(self._stacked and 0 or 1, 0.5)
			badge.Position = UDim2.fromScale(self._stacked and 0 or 1, 0.5)
			badge.Size = UDim2.fromOffset(math.min(120, width), 28)
		end
		local label = C.text(self, badge, self._value, "Caption", options.Kind or "Secondary", { Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		self._render = function() label.Text = self._value end
		self._layout()
		return self
	end
	function M.Progress(section, options)
		local self = M.base(section, "Progress", options, "stack")
		local minimum, maximum = options.Min or 0, options.Max or 100
		assert(C.finite(minimum) and C.finite(maximum) and maximum > minimum, "Progress Max must exceed Min")
		self._normalize = function(value) assert(C.finite(value), "Progress expects a finite number"); return C.clamp(value, minimum, maximum) end
		self._value = self._normalize(options.Default or options.Value or minimum)
		self._slotHeight = function() return 12 end
		local track = C.node(self, "Frame", self._slot, { Size = UDim2.new(1, 0, 0, 4), Position = UDim2.fromOffset(0, 4) }, { BackgroundColor3 = "Border" })
		C.corner(track, 2)
		local fill = C.node(self, "Frame", track, { Size = UDim2.fromScale(0, 1) }, { BackgroundColor3 = "Accent" })
		C.corner(fill, 2)
		local value = C.text(self, self.Frame, "", "Caption", "Secondary", { Position = UDim2.new(1, -96, 0, 14), Size = UDim2.fromOffset(80, 20), TextXAlignment = Enum.TextXAlignment.Right })
		self._labelReserve = 96
		self._render = function()
			local fraction = (self._value - minimum) / (maximum - minimum)
			fill.Size = UDim2.fromScale(fraction, 1)
			value.Text = tostring(math.floor(fraction * 100 + 0.5)) .. "%"
		end
		self._render(); self._layout()
		return self
	end
	function M.create(section, kind, options)
		options = type(options) == "string" and { Text = options } or options or {}
		local factory = M[kind]
		if kind == "Dropdown" or kind == "Segmented" or kind == "Keybind" then factory = env.require("choice")[kind]
		elseif kind == "ColorPicker" then factory = env.require("color")[kind] end
		assert(factory, "Unknown control " .. tostring(kind))
		local before = #section.Controls
		local ok, control = pcall(factory, section, options)
		if not ok then
			for index = #section.Controls, before + 1, -1 do section.Controls[index]:Destroy() end
			error(control, 2)
		end
		control._default = C.copy(control._value)
		control:SetDisabled(control.Disabled)
		section._window:_Filter()
		return control
	end
	return M
end
