return function(env)
	local C = env.require("core")
	local Controls = env.require("controls")
	local Overlays = env.require("overlays")
	local M = {}
	local function hsv(color)
		local r, g, b = color.R, color.G, color.B
		local high, low = math.max(r, g, b), math.min(r, g, b)
		local delta, hue = high - low, 0
		if delta > 0 then
			if high == r then hue = ((g - b) / delta) % 6
			elseif high == g then hue = (b - r) / delta + 2
			else hue = (r - g) / delta + 4 end
			hue = hue / 6
		end
		return hue, high == 0 and 0 or delta / high, high
	end
	local function hex(color)
		return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
	end
	local function fromHex(value)
		value = value:gsub("^#", "")
		if #value == 3 then value = value:gsub(".", function(char) return char .. char end) end
		if #value ~= 6 or value:find("[^%x]") then return nil end
		return Color3.fromRGB(tonumber(value:sub(1, 2), 16), tonumber(value:sub(3, 4), 16), tonumber(value:sub(5, 6), 16))
	end
	function M.ColorPicker(section, options)
		local self = Controls.base(section, "ColorPicker", options, "inline", 144)
		local showAlpha = options.Alpha ~= nil or options.ShowAlpha == true
		self._normalize = function(value)
			local color, alpha
			if typeof(value) == "Color3" then color, alpha = value, self._value and self._value.Alpha or C.number(options.Alpha, 1, 0, 1)
			elseif type(value) == "table" then color, alpha = value.Color, value.Alpha end
			assert(typeof(color) == "Color3" and C.finite(color.R) and C.finite(color.G) and C.finite(color.B), "ColorPicker expects a Color3")
			assert(color.R >= 0 and color.R <= 1 and color.G >= 0 and color.G <= 1 and color.B >= 0 and color.B <= 1, "ColorPicker RGB components must be between 0 and 1")
			assert(C.finite(alpha), "Alpha must be a finite number")
			return { Color = color, Alpha = C.clamp(alpha, 0, 1) }
		end
		self._value = self._normalize(options.Default or self._window.Theme.Accent)
		function self:Get() return self._value.Color, self._value.Alpha end
		function self:GetAlpha() return self._value.Alpha end
		function self:SetAlpha(alpha, silent) return self:Set({ Color = self._value.Color, Alpha = alpha }, silent) end
		function self:_Emit()
			C.call(self._window, options.Callback, self:Get())
			if not self.Alive then return end
			for callback in pairs(self._listeners) do C.call(self._window, callback, self:Get()); if not self.Alive then break end end
		end
		self._encode = function()
			local color, alpha = self:Get()
			return { rgb = { color.R, color.G, color.B }, alpha = alpha }
		end
		self._decode = function(value)
			assert(type(value) == "table" and type(value.rgb) == "table", "Invalid saved color")
			for index = 1, 3 do assert(C.finite(value.rgb[index]) and value.rgb[index] >= 0 and value.rgb[index] <= 1, "Invalid RGB component") end
			assert(C.finite(value.alpha) and value.alpha >= 0 and value.alpha <= 1, "Invalid alpha")
			return self._normalize({ Color = Color3.new(value.rgb[1], value.rgb[2], value.rgb[3]), Alpha = value.alpha })
		end
		local button, label, refresh = Controls.action(self, "")
		button.Name = "ColorPicker"
		label.Size, label.Position, label.TextXAlignment = UDim2.new(1, -48, 1, 0), UDim2.fromOffset(40, 0), Enum.TextXAlignment.Left
		local swatch = C.node(self, "Frame", button, { Name = "Swatch", Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
		C.corner(swatch, 4); C.stroke(self, swatch)
		self._render = function()
			label.Text = hex(self._value.Color)
			swatch.BackgroundColor3, swatch.BackgroundTransparency = self._value.Color, 1 - self._value.Alpha
			refresh()
		end
		function self:Open()
			if not self:_Interactive() then return nil end
			local panel = Overlays.panel(self._window, { Title = self.Text, Control = self, Width = 380, Height = showAlpha and 640 or 580, Actions = true })
			local hue, saturation, brightness = hsv(self._value.Color)
			local draft, alpha = self._value.Color, self._value.Alpha
			local painting, invalid, pending = false, false, nil
			local fields = {}
			local sv = C.node(panel, "TextButton", panel.Body, { Name = "SaturationBrightness", Size = UDim2.new(1, 0, 0, 200), ClipsDescendants = true, LayoutOrder = 0 })
			C.corner(sv, 6)
			local saturationLayer = C.node(panel, "Frame", sv, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1) })
			C.node(panel, "UIGradient", saturationLayer, { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }) })
			local valueLayer = C.node(panel, "Frame", sv, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0) })
			C.node(panel, "UIGradient", valueLayer, { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }) })
			local cursor = C.node(panel, "Frame", sv, { Name = "Cursor", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12) })
			C.corner(cursor, 6)
			local cursorBorder = C.node(panel, "UIStroke", cursor, { Color = Color3.new(1, 1, 1), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
			local hueHit = C.node(panel, "TextButton", panel.Body, { Name = "Hue", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, self._window.Target), LayoutOrder = 1 })
			local hueTrack = C.node(panel, "Frame", hueHit, { Size = UDim2.new(1, -12, 0, 14), Position = UDim2.new(0, 6, 0.5, -7), BackgroundColor3 = Color3.new(1, 1, 1) })
			C.corner(hueTrack, 7)
			local stops = {}
			for index = 0, 6 do stops[#stops + 1] = ColorSequenceKeypoint.new(index / 6, Color3.fromHSV(index / 6, 1, 1)) end
			C.node(panel, "UIGradient", hueTrack, { Color = ColorSequence.new(stops) })
			local hueCursor = C.node(panel, "Frame", hueTrack, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(8, 22), BackgroundColor3 = Color3.new(1, 1, 1) })
			C.corner(hueCursor, 3); C.stroke(panel, hueCursor)
			local sample = C.node(panel, "Frame", panel.Body, { Name = "Preview", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 58), LayoutOrder = 2 })
			C.text(panel, sample, "Current", "Caption", "Muted", { Size = UDim2.new(0.5, -4, 0, 20) })
			C.text(panel, sample, "New", "Caption", "Muted", { Position = UDim2.new(0.5, 4, 0, 0), Size = UDim2.new(0.5, -4, 0, 20) })
			local oldColor = C.node(panel, "Frame", sample, { Position = UDim2.fromOffset(0, 24), Size = UDim2.new(0.5, -4, 0, 30), BackgroundColor3 = self._value.Color, BackgroundTransparency = 1 - self._value.Alpha })
			C.corner(oldColor, 5)
			local newColor = C.node(panel, "Frame", sample, { Position = UDim2.new(0.5, 4, 0, 24), Size = UDim2.new(0.5, -4, 0, 30) })
			C.corner(newColor, 5)
			local hexField = C.node(panel, "TextBox", panel.Body, { Name = "Hex", Text = hex(draft), PlaceholderText = "#RRGGBB", ClearTextOnFocus = false, Font = Enum.Font.Code, TextSize = 14, Size = UDim2.new(1, 0, 0, self._window.Target), LayoutOrder = 3 }, { BackgroundColor3 = "Raised", TextColor3 = "Text", PlaceholderColor3 = "Muted" })
			C.corner(hexField); C.stroke(panel, hexField)
			C.bind(panel, hexField, { TextSize = function() return 14 * self._window.TextScale end })
			local rgb = C.node(panel, "Frame", panel.Body, { Name = "RGB", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, self._window.Target + 22), LayoutOrder = 4 })
			for index, name in ipairs({ "R", "G", "B" }) do
				local cell = C.node(panel, "Frame", rgb, { BackgroundTransparency = 1, Position = UDim2.new((index - 1) / 3, (index - 1) * 3, 0, 0), Size = UDim2.new(1 / 3, -6, 1, 0) })
				C.text(panel, cell, name, "Caption", "Muted", { Size = UDim2.new(1, 0, 0, 18) })
				fields[index] = C.node(panel, "TextBox", cell, { Name = name, Text = "", ClearTextOnFocus = false, Font = Enum.Font.Code, TextSize = 14, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, self._window.Target) }, { BackgroundColor3 = "Raised", TextColor3 = "Text" })
				C.corner(fields[index]); C.stroke(panel, fields[index])
				C.bind(panel, fields[index], { TextSize = function() return 14 * self._window.TextScale end })
			end
			local alphaFill, alphaLabel, alphaTrack, alphaHit
			if showAlpha then
				alphaHit = C.node(panel, "TextButton", panel.Body, { Name = "Alpha", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, self._window.Target + 18), LayoutOrder = 5 })
				alphaLabel = C.text(panel, alphaHit, "", "Caption", "Secondary", { Size = UDim2.new(1, 0, 0, 18) })
				alphaTrack = C.node(panel, "Frame", alphaHit, { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 4) }, { BackgroundColor3 = "Border" })
				alphaFill = C.node(panel, "Frame", alphaTrack, { Size = UDim2.fromScale(alpha, 1) }, { BackgroundColor3 = "Accent" })
				C.corner(alphaTrack, 2); C.corner(alphaFill, 2)
			end
			local errorLabel = C.text(panel, panel.Body, "", "Caption", "Danger", { Name = "Validation", Size = UDim2.new(1, 0, 0, 34), Visible = false, LayoutOrder = 6 })
			local function render()
				painting, invalid, pending = true, false, nil
				draft = Color3.fromHSV(hue, saturation, brightness)
				sv.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
				cursor.Position = UDim2.fromScale(saturation, 1 - brightness)
				cursorBorder.Color = brightness > 0.7 and saturation < 0.5 and Color3.new(0.1, 0.1, 0.1) or Color3.new(1, 1, 1)
				hueCursor.Position = UDim2.fromScale(hue, 0.5)
				newColor.BackgroundColor3, newColor.BackgroundTransparency = draft, 1 - alpha
				hexField.Text = hex(draft)
				fields[1].Text, fields[2].Text, fields[3].Text = tostring(math.floor(draft.R * 255 + 0.5)), tostring(math.floor(draft.G * 255 + 0.5)), tostring(math.floor(draft.B * 255 + 0.5))
				if alphaLabel then alphaLabel.Text = "Opacity · " .. tostring(math.floor(alpha * 100 + 0.5)) .. "%"; alphaFill.Size = UDim2.fromScale(alpha, 1) end
				errorLabel.Visible = false
				painting = false
			end
			local function bad(message) invalid = true; errorLabel.Text, errorLabel.Visible = message, true end
			local function pickSV(input)
				saturation = C.clamp((input.Position.X - sv.AbsolutePosition.X) / math.max(1, sv.AbsoluteSize.X), 0, 1)
				brightness = 1 - C.clamp((input.Position.Y - sv.AbsolutePosition.Y) / math.max(1, sv.AbsoluteSize.Y), 0, 1)
				render()
			end
			C.pointer(panel, sv, pickSV, pickSV)
			local function pickHue(input)
				hue = C.clamp((input.Position.X - hueTrack.AbsolutePosition.X) / math.max(1, hueTrack.AbsoluteSize.X), 0, 1)
				render()
			end
			C.pointer(panel, hueHit, pickHue, pickHue)
			if alphaHit then
				local function pickAlpha(input)
					alpha = C.clamp((input.Position.X - alphaTrack.AbsolutePosition.X) / math.max(1, alphaTrack.AbsoluteSize.X), 0, 1)
					render()
				end
				C.pointer(panel, alphaHit, pickAlpha, pickAlpha)
				panel._scope:Connect(alphaHit.InputBegan, function(input)
					if input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then alpha = math.max(0, alpha - 0.01)
					elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then alpha = math.min(1, alpha + 0.01)
					else return end
					render()
				end)
			end
			panel._scope:Connect(sv.InputBegan, function(input)
				local key = input.KeyCode
				if key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft then saturation = math.max(0, saturation - 0.01)
				elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight then saturation = math.min(1, saturation + 0.01)
				elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.DPadUp then brightness = math.min(1, brightness + 0.01)
				elseif key == Enum.KeyCode.Down or key == Enum.KeyCode.DPadDown then brightness = math.max(0, brightness - 0.01)
				else return end
				render()
			end)
			panel._scope:Connect(hueHit.InputBegan, function(input)
				if input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.DPadLeft then hue = (hue - 1 / 360) % 1
				elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.DPadRight then hue = (hue + 1 / 360) % 1
				else return end
				render()
			end)
			local function commitHex()
				if painting then return end
				local color = fromHex(hexField.Text)
				if not color then bad("Use a 3- or 6-digit hex color."); return end
				hue, saturation, brightness = hsv(color); render()
			end
			local function commitRGB()
				if painting then return end
				local values = {}
				for index, item in ipairs(fields) do
					local number = tonumber(item.Text)
					if not C.finite(number) or number < 0 or number > 255 or number % 1 ~= 0 then bad("Use whole RGB values from 0 to 255."); return end
					values[index] = number
				end
				hue, saturation, brightness = hsv(Color3.fromRGB(values[1], values[2], values[3])); render()
			end
			panel._scope:Connect(hexField.FocusLost, commitHex)
			panel._scope:Connect(hexField:GetPropertyChangedSignal("Text"), function() if not painting then pending = "hex" end end)
			for _, field in ipairs(fields) do
				panel._scope:Connect(field.FocusLost, commitRGB)
				panel._scope:Connect(field:GetPropertyChangedSignal("Text"), function() if not painting then pending = "rgb" end end)
			end
			for index, spec in ipairs({ { "Cancel", nil }, { "Apply", "Primary" } }) do
				local action = C.node(panel, "TextButton", panel.Actions, { Name = spec[1], Size = UDim2.new(0.5, -4, 1, 0), LayoutOrder = index })
				C.corner(action); C.feedback(panel, action, spec[2])
				C.text(panel, action, spec[1], "Body", spec[2] and "OnPrimary" or "Text", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
				panel._scope:Connect(action.Activated, function()
					if index == 1 then panel:Close(); return end
					if pending == "hex" then commitHex() elseif pending == "rgb" then commitRGB() end
					if invalid then return end
					panel:Close()
					if self.Alive then self:Set({ Color = draft, Alpha = alpha }) end
				end)
			end
			panel.OnLayout = function(width)
				local reserved = showAlpha and (4 * self._window.Target + 174) or (3 * self._window.Target + 144)
				sv.Size = UDim2.new(1, 0, 0, math.min(210, math.max(112, math.min(width - 40, panel.Body.Size.Y.Offset - reserved))))
			end
			self._window:_Layout()
			render()
			panel:Focus(sv)
			return panel
		end
		self._scope:Connect(button.Activated, function() self:Open() end)
		self._render()
		return self
	end
	return M
end
