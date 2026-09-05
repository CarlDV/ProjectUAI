-- The rows a settings surface is made of.
--
-- There are two of those surfaces now -- the Settings panel and the settings dialog
-- the sidebar opens -- and they have to agree about what a toggle looks like, how a
-- token budget is expressed as a track, and which config path a control writes. So
-- the rows live here and both surfaces call them, rather than the dialog growing a
-- second, subtly different set.
--
-- Every builder takes the config path it writes and nothing else about where the
-- value goes: the row reads the current value itself and writes it back itself, which
-- is why none of these return a handle to be wired up afterwards.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")

	local R = {}

	-- A heading with an optional description, followed by the card its rows go in.
	--
	-- Both go inside one wrapper with a tight gap between them, so the heading is
	-- visibly closer to the card it labels than to whatever is above it. As two loose
	-- siblings the two distances were the same number -- the parent's gap -- and a
	-- column of sections read as an alternating stack with no grouping in it.
	function R.section(parent, props)
		props = props or {}
		local group = P.column(parent, {
			name = props.name and (props.name .. "Group") or "Group",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			layoutOrder = props.layoutOrder,
		})
		P.sectionHeader(group, {
			title = props.title,
			description = props.description,
			layoutOrder = 1,
		})
		return P.card(group, {
			name = props.name,
			layoutOrder = 2,
			gap = theme.space.md,
		})
	end

	function R.paragraph(parent, text, props)
		props = props or {}
		local label = P.text(parent, {
			name = props.name,
			text = tostring(text or ""),
			role = props.role or "caption",
			color = props.color or theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = props.layoutOrder,
		})
		label.Size = UDim2.new(1, 0, 0, 0)
		return label
	end

	function R.toggle(parent, props)
		local row = P.row(parent, {
			name = props.name,
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = props.layoutOrder,
		})
		local text = P.column(row, {
			size = UDim2.new(0, 0, 0, 0), auto = "Y", flex = "Fill", gap = 0, layoutOrder = 1,
		})
		P.text(text, { text = props.label, role = "small" })
		if props.hint then
			P.text(text, {
				text = props.hint,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
		end
		local switch = C.switch(row, {
			value = (props.value ~= nil) and props.value or (config.get(props.path, false) == true),
			onChange = function(value)
				if props.path then config.set(props.path, value) end
				if props.onChange then pcall(props.onChange, value) end
			end,
		})
		switch.instance.LayoutOrder = 2
		return switch
	end

	-- A million in a 66px monospace field is a wall of zeroes, and the exact digit
	-- is never what the reader is checking at that size.
	local function formatCount(number)
		number = math.floor(number)
		if number >= 1000000 and number % 100000 == 0 then
			local millions = number / 1000000
			return (millions % 1 == 0) and string.format("%dM", millions) or string.format("%.1fM", millions)
		end
		if number >= 1000 and number % 1000 == 0 then return string.format("%dk", number / 1000) end
		return tostring(number)
	end

	R.formatCount = formatCount

	-- `min` may be a list of allowed values rather than a bound. Every row that
	-- counts tokens uses one: the range those rows have to cover is three orders of
	-- magnitude, and a linear track across it cannot resolve the low end where the
	-- useful settings are.
	function R.number(parent, label, hint, path, min, max, step)
		local stops
		if type(min) == "table" then
			stops, min, max, step = min, min[1], min[#min], nil
		end
		local function display(number)
			return (step and step < 1) and string.format("%.2f", number) or formatCount(number)
		end
		local column = P.column(parent, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xxs })
		local head = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
		P.text(head, {
			text = label,
			role = "small",
			-- Fills rather than reserving 70 for a 66px value plus a 6px gap, which
			-- overlapped it by two pixels.
			size = UDim2.new(0, 0, 0, theme.text.small.height),
			flex = "Fill",
			layoutOrder = 1,
		})
		local value = P.text(head, {
			text = display(tonumber(config.get(path, min)) or min),
			role = "monoSmall",
			color = theme.color.accent,
			align = "Right",
			layoutOrder = 2,
		})
		value.Size = UDim2.fromOffset(theme.size.metaColumn, theme.text.small.height)
		C.slider(column, {
			-- Named after the setting it writes, so the tree says which slider is
			-- which -- eight of them called "Slider" is unreadable from a dump and
			-- unreachable from a test.
			name = "Slider_" .. tostring(path),
			min = min,
			max = max,
			step = step,
			stops = stops,
			value = tonumber(config.get(path, min)) or min,
			onChange = function(number)
				value.Text = display(number)
			end,
			onCommit = function(number)
				config.set(path, (step and step < 1) and util.round(number, 2) or math.floor(number))
			end,
		})
		if hint then
			P.text(column, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
		end
		return column
	end

	-- A row whose stops are words rather than numbers.
	--
	-- A track is still the right control when the values are not numeric: the stops
	-- are ordered and the reader is picking a position on a scale, which a row of
	-- buttons states less clearly. The value reads in the label's own type rather
	-- than numberRow's monospace, because a word set in code font looks like an
	-- identifier, and both ends are named above the track -- what the scale *means*
	-- is the part neither the numbers nor the level names carry.
	function R.choice(parent, label, hint, path, values, labels, ends)
		local index, stored = 1, tostring(config.get(path, values[1]))
		for position, value in ipairs(values) do
			if value == stored then index = position end
		end
		local stops = {}
		for position = 1, #values do stops[position] = position end

		local column = P.column(parent, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xxs })
		local head = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
		P.text(head, {
			text = label,
			role = "small",
			size = UDim2.new(0, 0, 0, theme.text.small.height),
			flex = "Fill",
			layoutOrder = 1,
		})
		local value = P.text(head, {
			text = labels[index],
			role = "label",
			color = theme.color.accent,
			align = "Right",
			auto = "X",
			layoutOrder = 2,
		})

		local feet = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
		P.text(feet, {
			text = ends[1],
			role = "caption",
			color = theme.color.textTertiary,
			size = UDim2.new(0, 0, 0, theme.text.caption.height),
			flex = "Fill",
			layoutOrder = 1,
		})
		P.text(feet, {
			text = ends[2],
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			auto = "X",
			layoutOrder = 2,
		})
		C.slider(column, {
			name = "Slider_" .. tostring(path),
			stops = stops,
			value = index,
			onChange = function(number)
				value.Text = labels[math.floor(number)] or value.Text
			end,
			onCommit = function(number)
				local position = math.max(math.min(math.floor(number), #values), 1)
				value.Text = labels[position]
				config.set(path, values[position])
			end,
		})
		if hint then
			P.text(column, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
		end
		return column
	end

	-- Label and description on the left, one control on the right. The dialog's
	-- appearance pane is a column of these.
	--
	-- The right-hand slot states a width. It used to size itself to its contents,
	-- which for a segmented control -- whose own width is a scale when it is not given
	-- one -- resolved to zero: three controls in that pane were invisible and
	-- unclickable, and nothing about the props said so.
	function R.setting(parent, props)
		local row = P.row(parent, {
			name = props.name,
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			alignY = "Center",
			gap = theme.space.md,
			layoutOrder = props.layoutOrder,
		})
		local left = P.column(row, {
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			flex = "Fill",
			gap = theme.space.hair,
			layoutOrder = 1,
		})
		P.text(left, {
			text = props.label,
			role = "bodyStrong",
			color = theme.color.text,
			auto = "Y",
			wrap = true,
			layoutOrder = 1,
		})
		if props.hint then
			P.text(left, {
				text = props.hint,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 2,
			})
		end
		local right = P.frame(row, {
			name = "Control",
			size = UDim2.fromOffset(props.width or theme.size.menu, 0),
			auto = "Y",
			layoutOrder = 2,
		})
		return right, row
	end

	-- A setting row whose control is a segmented picker over a config path.
	function R.segmented(parent, props)
		local width = C.segmentedWidth(props.options)
		local slot = R.setting(parent, {
			name = props.name,
			label = props.label,
			hint = props.hint,
			width = width,
			layoutOrder = props.layoutOrder,
		})
		local control = C.segmented(slot, {
			name = props.name and ("Segmented_" .. props.name) or nil,
			options = props.options,
			width = width,
			value = (props.value ~= nil) and props.value or config.get(props.path, props.options[1].value),
			onChange = function(value)
				if props.path then config.set(props.path, value) end
				if props.onChange then pcall(props.onChange, value) end
			end,
		})
		return control
	end

	-- A setting row whose control is a menu rather than a row of segments.
	--
	-- Segments stop working somewhere around four options. The interface font list is
	-- eight families wide, and eight segments in a 530px pane give each label sixty
	-- pixels -- which "Titillium Web" does not fit into, and C.segmented neither
	-- truncates nor clips, so the labels would simply run into each other. Same
	-- decision, a control that does not have to show every option at once.
	function R.select(parent, props)
		local options = props.options or {}
		local current = (props.value ~= nil) and props.value
			or config.get(props.path, options[1] and options[1].value)

		local function labelFor(value)
			for _, option in ipairs(options) do
				if option.value == value then return option.label or tostring(value) end
			end
			return tostring(value)
		end

		local slot = R.setting(parent, {
			name = props.name,
			label = props.label,
			hint = props.hint,
			width = props.width or theme.size.menu,
			layoutOrder = props.layoutOrder,
		})

		local control
		control = P.rowButton(slot, {
			name = props.name and ("Select_" .. props.name) or "Select",
			height = math.max(theme.size.control, responsive.minTarget()),
			radius = theme.radius.md,
			stroke = true,
			strokeColor = theme.color.border,
			padding = { x = theme.space.sm },
			onClick = function(handle)
				local menuOptions = {}
				for _, option in ipairs(options) do
					menuOptions[#menuOptions + 1] = {
						label = option.label or tostring(option.value),
						value = option.value,
						detail = option.detail,
						selected = option.value == current,
					}
				end
				env.require("ui/overlay").menu({
					target = handle.instance,
					width = math.max(props.menuWidth or theme.size.menuWide,
						math.floor(handle.instance.AbsoluteSize.X)),
					options = menuOptions,
					onSelect = function(value)
						current = value
						control.text.Text = labelFor(value)
						if props.path then config.set(props.path, value) end
						if props.onChange then pcall(props.onChange, value) end
					end,
				})
			end,
		})
		control.text = control.label(labelFor(current), 1, theme.color.text, "small")
		local caret = P.frame(control.row, {
			name = "Caret",
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			layoutOrder = 2,
		})
		env.require("ui/icons").chevron(caret, theme.size.icon, theme.color.textTertiary, "down")
		return control
	end

	-- A field bound to a config path, written on blur rather than per keystroke: a
	-- port typed one digit at a time would otherwise restart the bridge four times.
	function R.field(parent, props)
		if props.label then
			P.text(parent, { text = props.label, role = "small", layoutOrder = props.layoutOrder })
		end
		local field = P.field(parent, {
			name = props.name,
			text = tostring(props.value ~= nil and props.value or config.get(props.path, "")),
			placeholder = props.placeholder,
			size = props.size,
			layoutOrder = props.layoutOrder and (props.layoutOrder + 1) or nil,
			onBlur = function(text)
				local clean = util.trim(text)
				if props.transform then clean = props.transform(clean) end
				if props.path then config.set(props.path, clean) end
				if props.onChange then pcall(props.onChange, clean) end
			end,
		})
		if props.hint then R.paragraph(parent, props.hint) end
		return field
	end

	-- A row of buttons. Actions rather than settings: a reset, a clear, an unload.
	function R.actions(parent, list, props)
		props = props or {}
		local row = P.row(parent, {
			name = props.name or "Actions",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = props.layoutOrder,
		})
		for index, entry in ipairs(list) do
			local button = P.button(row, {
				name = entry.name,
				text = entry.text,
				variant = entry.variant or "secondary",
				size = "sm",
				layoutOrder = index,
				onClick = entry.onClick,
			})
			button.instance.LayoutOrder = index
		end
		return row
	end

	-- Key/value facts. Read-only by definition: these are things the client observed,
	-- not things it can be told.
	function R.facts(parent, list, props)
		props = props or {}
		local box = P.frame(parent, {
			name = props.name or "Facts",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.canvas,
			radius = theme.radius.md,
			padding = theme.space.sm,
			layoutOrder = props.layoutOrder,
		})
		P.stroke(box, theme.color.borderSubtle)
		local column = P.column(box, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
		})
		for index, entry in ipairs(list) do
			C.keyValue(column, {
				key = entry.key,
				value = entry.value,
				layoutOrder = index,
				color = entry.tone and theme.toneColor(entry.tone) or theme.color.text,
			})
		end
		return box
	end

	return R
end
