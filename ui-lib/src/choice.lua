return function(env)
	local C = env.require("core")
	local Controls = env.require("controls")
	local Overlays = env.require("overlays")
	local M = {}
	local function array(value, limit)
		assert(type(value) == "table" and #value <= limit, "Expected an array with at most " .. limit .. " entries")
		local count = 0
		for key in pairs(value) do
			assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #value, "Expected consecutive array entries")
			count = count + 1
		end
		assert(count == #value, "Expected consecutive array entries")
	end
	local function parseOptions(values)
		array(values, 500)
		local out, seen = {}, {}
		for index, value in ipairs(values) do
			local item = type(value) == "table" and value or { Value = value, Label = tostring(value) }
			local actual = item.Value
			local kind = type(actual)
			assert(kind == "string" or kind == "boolean" or (kind == "number" and C.finite(actual)), "Option Value must be a string, boolean, or finite number")
			local key = kind .. ":" .. tostring(actual)
			assert(not seen[key], "Duplicate option value: " .. tostring(actual))
			seen[key] = true
			local image = item.Image
			if image ~= nil then
				assert(type(image) == "string" and #image > 0 and #image <= 2048, "Option Image must be a nonempty string of at most 2048 characters")
			end
			out[index] = { Value = actual, Label = tostring(item.Label or actual), Disabled = item.Disabled == true, Image = image }
		end
		return out
	end
	local function find(options, value)
		for _, option in ipairs(options) do if option.Value == value then return option end end
	end
	local function has(list, value)
		for _, item in ipairs(list or {}) do if item == value then return true end end
		return false
	end
	-- A round profile image for player-aware option rows and the closed field.
	-- The image sits over a readable initial, so a headshot still loading -- or
	-- one that never resolves -- keeps stating who the row is. The built-in
	-- rbxthumb:// headshot scheme and any uploaded image URL both work.
	local function initialFor(text)
		local first = tostring(text):match("^[%z\1-\127\194-\244][\128-\191]*")
		return first and string.upper(first) or "?"
	end
	local function avatar(owner, parent, diameter, order)
		local frame = C.node(owner, "Frame", parent, {
			Name = "Avatar", Size = UDim2.fromOffset(diameter, diameter), LayoutOrder = order,
		}, { BackgroundColor3 = "Raised" })
		C.corner(frame, diameter / 2)
		C.stroke(owner, frame, "Subtle")
		local initial = C.text(owner, frame, "?", "Small", "Secondary", {
			Name = "AvatarInitial", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd,
		})
		local photo = C.node(owner, "ImageLabel", frame, {
			Name = "AvatarImage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop,
		})
		C.corner(photo, diameter / 2)
		pcall(function()
			owner._scope:Connect(photo:GetPropertyChangedSignal("IsLoaded"), function()
				initial.Visible = photo.IsLoaded ~= true
			end)
		end)
		local function set(image, label)
			photo.Image = image or ""
			initial.Text = initialFor(label)
			initial.Visible = photo.IsLoaded ~= true
		end
		return frame, set
	end
	local function configure(self, options)
		self.Options = parseOptions(options.Options or {})
		self.Multi = options.Multi == true
		self._normalize = function(value)
			if self.Multi then
				array(value, 500)
				for _, selected in ipairs(value) do assert(find(self.Options, selected), "Unknown option: " .. tostring(selected)) end
				local out = {}
				for _, option in ipairs(self.Options) do if has(value, option.Value) then out[#out + 1] = option.Value end end
				return out
			end
			assert(value == nil or find(self.Options, value), "Unknown option: " .. tostring(value))
			return value
		end
		self._value = self._normalize(options.Default == nil and (self.Multi and {} or nil) or options.Default)
		self._encode = function()
			if self._value == nil then return { empty = true } end
			return { value = self:Get() }
		end
		self._decode = function(value)
			assert(type(value) == "table", "Invalid saved selection")
			assert((value.empty == true and value.value == nil) or (value.empty == nil and value.value ~= nil), "Invalid saved selection")
			if value.empty == true then return self._normalize(nil) end
			return self._normalize(value.value)
		end
		function self:SetOptions(values, silent)
			assert(self.Alive, "Control is destroyed")
			local parsed = parseOptions(values)
			local nextValue
			if self.Multi then
				nextValue = {}
				for _, option in ipairs(parsed) do if has(self._value, option.Value) then nextValue[#nextValue + 1] = option.Value end end
			elseif find(parsed, self._value) then nextValue = self._value end
			self:_CancelInteraction()
			self.Options = parsed
			self:Set(nextValue, silent)
			if self.Alive and self._rebuild then self._rebuild() end
			return self
		end
	end
	function M.Dropdown(section, options)
		local self = Controls.base(section, "Dropdown", options, "stack")
		configure(self, options)
		local button, label, refresh = Controls.action(self, "", nil)
		button.Name = "Dropdown"
		label.TextXAlignment, label.Size = Enum.TextXAlignment.Left, UDim2.new(1, -48, 1, 0)
		label.Position = UDim2.fromOffset(12, 0)
		local chevron = C.icon(self, button, "chevron", "Muted", 16)
		chevron.Position, chevron.AnchorPoint = UDim2.new(1, -14, 0.5, 0), Vector2.new(1, 0.5)
		-- The closed field shows the selected profile image at its start, so a
		-- player target reads as a face and a name rather than a name alone.
		local fieldAvatarSize = math.min(24, self._window.Target - 16)
		local fieldAvatar, setFieldAvatar = avatar(self, button, fieldAvatarSize, 0)
		fieldAvatar.AnchorPoint, fieldAvatar.Position = Vector2.new(0, 0.5), UDim2.new(0, 12, 0.5, 0)
		fieldAvatar.Visible = false
		local paintMenu
		self._render = function()
			local captions, image, caption = {}, nil, nil
			for _, option in ipairs(self.Options) do
				if (self.Multi and has(self._value, option.Value)) or (not self.Multi and self._value == option.Value) then
					captions[#captions + 1] = option.Label
					if not image and option.Image then image, caption = option.Image, option.Label end
				end
			end
			label.Text = #captions == 0 and (options.Placeholder or "Select an option") or (#captions > 2 and tostring(#captions) .. " selected" or table.concat(captions, ", "))
			if image then
				fieldAvatar.Visible = true
				setFieldAvatar(image, caption)
				label.Position, label.Size = UDim2.fromOffset(12 + fieldAvatarSize + 10, 0), UDim2.new(1, -(12 + fieldAvatarSize + 10) - 36, 1, 0)
			else
				fieldAvatar.Visible = false
				label.Position, label.Size = UDim2.fromOffset(12, 0), UDim2.new(1, -48, 1, 0)
			end
			refresh()
			if paintMenu then paintMenu() end
		end
		function self:Open()
			if not self:_Interactive() then return nil end
			local target = self._window.Target
			local bodyHeight = #self.Options > 0 and (#self.Options * target + (#self.Options - 1) * 12) or 44
			if options.Searchable ~= false then bodyHeight = bodyHeight + target + 12 end
			local panel = Overlays.panel(self._window, {
				Title = self.Text, Anchor = button, Control = self, Width = math.max(320, button.AbsoluteSize.X),
				Height = math.min(440, math.max(54, target + 12) + 30 + 16 + bodyHeight + (self.Multi and target + 20 or 0)),
				Actions = self.Multi, OnClose = function() paintMenu = nil end,
			})
			local search = C.node(panel, "TextBox", panel.Body, {
				Name = "SearchOptions", Text = "", PlaceholderText = "Search options", Font = C.Font, TextSize = 14,
				ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, self._window.Target), LayoutOrder = 0,
			}, { BackgroundColor3 = "Raised", TextColor3 = "Text", PlaceholderColor3 = "Muted", TextSize = function() return 14 * self._window.TextScale end })
			C.corner(search); C.pad(search, 12, 0); C.stroke(panel, search)
			search.Visible = options.Searchable ~= false
			local rows = {}
			for index, option in ipairs(self.Options) do
				local row = C.node(panel, "TextButton", panel.Body, { Name = "Option_" .. index, Size = UDim2.new(1, 0, 0, self._window.Target), LayoutOrder = index, Selectable = not option.Disabled })
				C.corner(row)
				C.bind(panel, row, { BackgroundColor3 = function(theme)
					local selected = self.Multi and has(self._value, option.Value) or (not self.Multi and self._value == option.Value)
					return selected and theme.Selected or theme.Surface
				end })
				local labelLeft = 12
				if option.Image then
					local rowAvatar = math.min(28, self._window.Target - 12)
					local avatarFrame, setAvatar = avatar(panel, row, rowAvatar, 0)
					avatarFrame.AnchorPoint, avatarFrame.Position = Vector2.new(0, 0.5), UDim2.new(0, 8, 0.5, 0)
					setAvatar(option.Image, option.Label)
					labelLeft = 8 + rowAvatar + 10
				end
				C.text(panel, row, option.Label, "Body", option.Disabled and "Muted" or "Text", {
					Name = "OptionLabel", Position = UDim2.fromOffset(labelLeft, 0), Size = UDim2.new(1, -(labelLeft + 36), 1, 0),
					TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd,
				})
				local check = C.icon(panel, row, "check", "Accent", 16)
				check.Position, check.AnchorPoint = UDim2.new(1, -12, 0.5, 0), Vector2.new(1, 0.5)
				rows[#rows + 1] = { row = row, check = check, option = option }
				panel._scope:Connect(row.Activated, function()
					if option.Disabled or not self.Alive then return end
					if self.Multi then
						local nextValue = self:Get()
						if has(nextValue, option.Value) then
							for valueIndex, value in ipairs(nextValue) do if value == option.Value then table.remove(nextValue, valueIndex); break end end
						else nextValue[#nextValue + 1] = option.Value end
						self:Set(nextValue)
					else self:Set(option.Value); panel:Close() end
				end)
			end
			local empty = C.text(panel, panel.Body, "No matching options", "Body", "Muted", { Name = "EmptyOptions", Size = UDim2.new(1, 0, 0, 44), LayoutOrder = #rows + 1, Visible = #rows == 0 })
			paintMenu = function()
				if panel.Closed then return end
				local count, query = 0, string.lower(search.Text)
				for _, item in ipairs(rows) do
					item.row.Visible = query == "" or string.lower(item.option.Label):find(query, 1, true) ~= nil
					if item.row.Visible then count = count + 1 end
					local selected = self.Multi and has(self._value, item.option.Value) or (not self.Multi and self._value == item.option.Value)
					item.check.Visible = selected
					item.row.BackgroundColor3 = selected and self._window.Theme.Selected or self._window.Theme.Surface
				end
				empty.Visible = count == 0
			end
			panel._scope:Connect(search:GetPropertyChangedSignal("Text"), function()
				paintMenu()
				panel.Body.CanvasPosition = Vector2.new(0, 0)
			end)
			if self.Multi then
				local done = C.node(panel, "TextButton", panel.Actions, { Name = "Done", Size = UDim2.fromScale(1, 1) })
				C.corner(done); C.feedback(panel, done, "Primary")
				C.text(panel, done, "Done", "Body", "OnPrimary", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })
				panel._scope:Connect(done.Activated, function() panel:Close() end)
			end
			paintMenu()
			for _, item in ipairs(rows) do if not item.option.Disabled then panel:Focus(item.row); break end end
			return panel
		end
		self._scope:Connect(button.Activated, function() self:Open() end)
		self._render()
		return self
	end
	function M.Segmented(section, options)
		assert(not options.Multi, "Segmented is single-select")
		assert(type(options.Options) == "table" and #options.Options > 0 and #options.Options <= 8, "Segmented expects 1-8 options")
		local self = Controls.base(section, "Segmented", options, "stack")
		configure(self, options)
		if self._value == nil then
			for _, option in ipairs(self.Options) do if not option.Disabled then self._value = option.Value; break end end
		end
		local rows, childScope = {}, nil
		self._render = function()
			for _, item in ipairs(rows) do
				item.button.BackgroundColor3 = item.option.Value == self._value and self._window.Theme.Selected or self._window.Theme.Raised
				item.stroke.Color = item.option.Value == self._value and self._window.Theme.Accent or self._window.Theme.Subtle
			end
		end
		self._slotHeight = function()
			local width = math.max(1, self._window._contentWidth - 72)
			local columns = math.max(1, math.min(#rows, math.floor(width / (100 * self._window.TextScale))))
			return math.ceil(#rows / columns) * (self._window.Target + 6) - 6
		end
		self._afterLayout = function(width)
			local columns = math.max(1, math.min(#rows, math.floor(width / (100 * self._window.TextScale))))
			local cellWidth = (width - (columns - 1) * 6) / columns
			for index, item in ipairs(rows) do
				item.button.Size = UDim2.fromOffset(cellWidth, self._window.Target)
				item.button.Position = UDim2.fromOffset(((index - 1) % columns) * (cellWidth + 6), math.floor((index - 1) / columns) * (self._window.Target + 6))
			end
		end
		self._rebuild = function()
			if childScope then childScope._scope:Destroy() end
			for _, item in ipairs(rows) do item.button:Destroy() end
			rows, self._inputs = {}, {}
			childScope = C.owner(self._window, self._scope)
			for index, option in ipairs(self.Options) do
				local button = Controls.input(self, "TextButton", self._slot, { Name = "Segment_" .. index })
				C.corner(button)
				local stroke = C.stroke(childScope, button, "Subtle")
				C.bind(childScope, button, { BackgroundColor3 = function(theme) return option.Value == self._value and theme.Selected or theme.Raised end })
				C.bind(childScope, stroke, { Color = function(theme) return option.Value == self._value and theme.Accent or theme.Subtle end })
				C.text(childScope, button, option.Label, "Body", option.Disabled and "Muted" or "Text", { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -16, 1, 0), TextXAlignment = Enum.TextXAlignment.Center })
				childScope._scope:Connect(button.Activated, function() if self:_Interactive() and not option.Disabled then self:Set(option.Value) end end)
				rows[#rows + 1] = { button = button, stroke = stroke, option = option }
			end
			self._layout(); self._render(); self:SetDisabled(self.Disabled)
		end
		local setOptions = self.SetOptions
		function self:SetOptions(values, silent)
			assert(type(values) == "table" and #values > 0 and #values <= 8, "Segmented expects 1-8 options")
			return setOptions(self, values, silent)
		end
		self._rebuild()
		return self
	end
	function M.Keybind(section, options)
		local mode = options.Mode or "Press"
		assert(mode == "Press" or mode == "Hold" or mode == "Toggle", "Keybind Mode must be Press, Hold, or Toggle")
		local self = Controls.base(section, "Keybind", options, "inline", 136)
		self._callback = options.OnChanged
		self.Mode, self.Active = mode, false
		self._normalize = function(value)
			if value == nil or value == false or value == "None" then return nil end
			if type(value) == "string" then
				local ok, key = pcall(function() return Enum.KeyCode[value] end)
				assert(ok and key, "Unknown key: " .. value)
				value = key
			end
			assert(typeof(value) == "EnumItem" and tostring(value):find("Enum.KeyCode.", 1, true) == 1, "Keybind expects an Enum.KeyCode")
			if value == Enum.KeyCode.Unknown then return nil end
			assert(value ~= self._window.ToggleKey, "Key is reserved for showing the window; choose another key")
			return value
		end
		self._value = self._normalize(options.Default)
		self._encode = function() return self._value and self._value.Name or false end
		self._decode = self._normalize
		local button, label, refresh = Controls.action(self, "")
		button.Name = "Keybind"
		local capture, pressed
		self._render = function() label.Text = capture and "Press a key…" or (self._value and self._value.Name or "Not set"); refresh() end
		local function activate(active)
			self.Active = active
			C.call(self._window, options.Callback, active, self._value)
		end
		local function release()
			pressed = false
			if self.Active then activate(false) end
		end
		self._cancel = function()
			if self._window._capture == capture then self._window._capture = nil end
			if self._window._captureControl == self then self._window._captureControl = nil end
			capture = nil
			release()
			if self.Alive then self._render() end
		end
		local setter = self.Set
		function self:Set(value, silent)
			local normalized = self._normalize(value)
			self._cancel()
			return setter(self, normalized, silent)
		end
		self._restore = function(value)
			local active, previous = self.Active, self._value
			self.Active, pressed = false, false
			self._cancel()
			setter(self, value, true)
			if active then return function() C.call(self._window, options.Callback, false, previous) end end
		end
		local binding = { release = release }
		binding.began = function(input)
			if not self.Alive or self.Disabled or not self.Visible or not self._value or pressed then return end
			if not self._window.Visible and not options.ActiveWhenHidden then return end
			if input.KeyCode ~= self._value then return end
			pressed = true
			if mode == "Toggle" then activate(not self.Active)
			elseif mode == "Hold" then activate(true)
			else C.call(self._window, options.Callback, true, self._value) end
		end
		binding.ended = function(input)
			if input.KeyCode == self._value then
				pressed = false
				if mode == "Hold" and self.Active then activate(false) end
			end
		end
		self._window._keys[binding] = true
		self._scope:Add(function() self._cancel(); self._window._keys[binding] = nil end)
		self._scope:Connect(button.Activated, function()
			if not self:_Interactive() then return end
			if capture then self._cancel(); return end
			self._window:_CancelCapture()
			self._window:_ReleaseKeys()
			capture = function(input)
				local key = input.KeyCode
				if key == Enum.KeyCode.Escape or key == Enum.KeyCode.ButtonB then self._cancel(); return end
				if key == Enum.KeyCode.Unknown then return end
				local nextValue = key
				if key == Enum.KeyCode.Backspace or key == Enum.KeyCode.Delete then nextValue = nil end
				local ok, why = pcall(function() self:Set(nextValue) end)
				if not ok then self._window:Notify({ Title = "Choose another key", Content = tostring(why), Kind = "Warning" }) end
			end
			self._window._capture = capture
			self._window._captureControl = self
			self._render()
		end)
		self._render()
		return self
	end
	return M
end
