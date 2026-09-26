return function(env)
	local C = env.require("core")
	local M, Tab, Section = {}, {}, {}
	Tab.__index, Section.__index = Tab, Section
	function M.tab(window, options)
		assert(window.Alive, "Window is destroyed")
		options = type(options) == "string" and { Title = options } or options or {}
		local title = tostring(options.Title or "Tab")
		local id = tostring(options.Id or title)
		for _, tab in ipairs(window.Tabs) do assert(tab.Id ~= id, "Duplicate tab Id: " .. id) end
		local tab = setmetatable(C.owner(window), Tab)
		tab.Id, tab.Title, tab.Alive, tab.Visible, tab.Sections = id, title, true, true, {}
		tab._scope:Add(function() tab.Alive = false end)
		tab.Frame = C.scroll(tab, window._content, "Tab_" .. id)
		tab._scope:Connect(tab.Frame.Destroying, function() tab:Destroy() end)
		tab.Frame.Visible = false
		C.pad(tab.Frame, 20, 20)
		C.list(tab.Frame, false, 20)
		tab._button = C.node(tab, "TextButton", window._nav, { Name = "Tab_" .. id, LayoutOrder = #window.Tabs + 1 })
		C.corner(tab._button)
		C.bind(tab, tab._button, { BackgroundColor3 = function(theme) return window._activeTab == tab and theme.Selected or theme.Sidebar end })
		local indicator = C.node(tab, "Frame", tab._button, { Size = UDim2.new(0, 2, 0.5, 0), Position = UDim2.fromScale(0, 0.25) }, {
			BackgroundColor3 = "Accent", BackgroundTransparency = function() return window._activeTab == tab and 0 or 1 end,
		})
		C.corner(indicator, 1)
		local glyph = C.icon(tab, tab._button, options.Icon or "grid", "Secondary", 18)
		glyph.Position, glyph.AnchorPoint = UDim2.new(0, 12, 0.5, 0), Vector2.new(0, 0.5)
		C.text(tab, tab._button, title, "Body", "Text", { Position = UDim2.fromOffset(40, 0), Size = UDim2.new(1, -48, 1, 0), TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd })
		tab._scope:Connect(tab._button.Activated, function() window:SelectTab(tab) end)
		window.Tabs[#window.Tabs + 1] = tab
		window:_Layout()
		if not window._activeTab then window:SelectTab(tab) end
		return tab
	end
	function Tab:Select() self._window:SelectTab(self); return self end
	function Tab:SetVisible(visible)
		self.Visible, self._button.Visible = visible == true, visible == true
		self.Frame.Visible = self.Visible and self._window._activeTab == self
		if not self.Visible and self._window._activeTab == self then
			self._window._activeTab = nil
			self._window:_CloseOverlay()
			for _, tab in ipairs(self._window.Tabs) do if tab.Visible then tab:Select(); break end end
		end
		return self
	end
	function Tab:Destroy()
		if not self.Alive then return end
		self:SetVisible(false)
		self.Alive = false
		for index = #self.Sections, 1, -1 do self.Sections[index]:Destroy() end
		for index, tab in ipairs(self._window.Tabs) do if tab == self then table.remove(self._window.Tabs, index); break end end
		self._scope:Destroy()
		self.Frame:Destroy(); self._button:Destroy()
	end
	function Tab:Section(options)
		assert(self.Alive, "Tab is destroyed")
		options = type(options) == "string" and { Title = options } or options or {}
		local window = self._window
		local section = setmetatable(C.owner(window, self._scope), Section)
		section._tab, section.Title, section.Description = self, tostring(options.Title or ""), tostring(options.Description or "")
		section.Alive, section.Visible, section.Collapsed, section.Controls = true, true, options.Collapsed == true, {}
		section._scope:Add(function() section.Alive = false end)
		section.Frame = C.node(section, "Frame", self.Frame, {
			Name = "Section_" .. section.Title, BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = #self.Sections + 1,
		})
		section._scope:Connect(section.Frame.Destroying, function() section:Destroy() end)
		C.list(section.Frame, false, 10)
		section._header = C.node(section, "TextButton", section.Frame, {
			Name = "SectionHeader", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 0,
			Selectable = options.Collapsible == true,
		})
		section._heading = C.text(section, section._header, section.Title, "Heading", "Text", { Size = UDim2.new(1, -24, 0, 22) })
		section._description = C.text(section, section._header, section.Description, "Caption", "Muted", { Position = UDim2.fromOffset(0, 24), TextYAlignment = Enum.TextYAlignment.Top })
		if options.Collapsible then
			local icon = C.icon(section, section._header, "chevron", "Muted", 16)
			icon.Position, icon.AnchorPoint = UDim2.new(1, 0, 0, 12), Vector2.new(1, 0.5)
			C.bind(section, icon, { Rotation = function() return section.Collapsed and -90 or 0 end })
			section._scope:Connect(section._header.Activated, function() section:SetCollapsed(not section.Collapsed) end)
		end
		section._body = C.node(section, "Frame", section.Frame, {
			Name = "Rows", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Visible = not section.Collapsed,
		}, { BackgroundColor3 = "Surface" })
		C.corner(section._body, 8); C.stroke(section, section._body, "Subtle")
		C.list(section._body, false, 0); C.pad(section._body, 0, 4)
		C.reflow(section, function()
			local width = math.max(1, window._contentWidth - 40)
			local descriptionHeight = section.Description ~= "" and C.measure(section.Description, 12 * window.TextScale, width - 24) or 0
			section._header.Visible = section.Title ~= "" or section.Description ~= ""
			section._header.Size = UDim2.new(1, 0, 0, math.max(options.Collapsible and window.Target or 0, 22 * window.TextScale + (descriptionHeight > 0 and descriptionHeight + 4 or 0)))
			section._heading.Size = UDim2.new(1, -24, 0, 22 * window.TextScale)
			section._description.Position = UDim2.fromOffset(0, 22 * window.TextScale + 4)
			section._description.Size = UDim2.new(1, -24, 0, descriptionHeight)
			section._description.Visible = descriptionHeight > 0
		end)
		self.Sections[#self.Sections + 1] = section
		return section
	end
	function Section:SetCollapsed(collapsed)
		self.Collapsed = collapsed == true
		self._window:_Filter()
		self._window:_Refresh()
		return self
	end
	function Section:SetVisible(visible)
		self.Visible = visible == true
		self._window:_Filter()
		return self
	end
	function Section:Destroy()
		if not self.Alive then return end
		self.Alive = false
		for index = #self.Controls, 1, -1 do self.Controls[index]:Destroy() end
		for index, section in ipairs(self._tab.Sections) do if section == self then table.remove(self._tab.Sections, index); break end end
		self._scope:Destroy()
		self.Frame:Destroy()
	end
	for _, kind in ipairs({ "Button", "Toggle", "Checkbox", "Slider", "Input", "Dropdown", "Segmented", "Keybind", "ColorPicker", "Label", "Paragraph", "Divider", "Badge", "Progress" }) do
		Section[kind] = function(section, options)
			return env.require("controls").create(section, kind, options)
		end
	end
	return M
end
