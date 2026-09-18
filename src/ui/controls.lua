-- Compound controls built from the primitives.
--
-- Each one owns its own state and exposes a handle, so a panel never reaches into
-- an instance to change what a control shows.
return function(env)
	local util = env.require("runtime/util")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local dispose = env.require("runtime/dispose")
	local P = env.require("ui/primitives")

	local C = {}

	-- An open arc with a solid leading cap stays visibly asymmetric at icon size.
	-- The inner rotor moves independently of the layout-owned slot.
	function C.spinner(parent, props)
		props = props or {}
		local size = props.diameter or theme.size.icon
		local holder = P.frame(parent, {
			name = "Spinner",
			size = UDim2.fromOffset(size, size),
			layoutOrder = props.layoutOrder,
			anchor = props.anchor,
			position = props.position,
		})
		local rotor = P.frame(holder, {
			name = "Rotor",
			size = UDim2.fromScale(1, 1),
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5),
		})
		local tint = props.color or theme.color.accent
		local thickness = math.max(math.floor(size / 7 + 0.5), theme.stroke.focus)
		local radius = math.max((size - thickness) / 2 - theme.stroke.hair, thickness)
		local segments = 14
		local sweep = 245
		local step = sweep / (segments - 1)
		local length = radius * math.rad(step) + thickness / 2
		for index = 1, segments do
			local angle = -90 - sweep + (index - 1) * step
			P.frame(rotor, {
				name = "Arc" .. index,
				size = UDim2.fromOffset(length, thickness),
				bg = tint,
				bgTransparency = (1 - (index - 1) / (segments - 1)) * theme.opacity.dim,
				radius = theme.radius.pill,
				anchor = Vector2.new(0.5, 0.5),
				position = UDim2.new(0.5, math.cos(math.rad(angle)) * radius,
					0.5, math.sin(math.rad(angle)) * radius),
				rotation = angle + 90,
			})
		end
		P.frame(rotor, {
			name = "LeadingCap",
			size = UDim2.fromOffset(thickness, thickness),
			bg = tint,
			radius = theme.radius.pill,
			anchor = Vector2.new(0.5, 0.5),
			position = UDim2.new(0.5, 0, 0.5, -radius),
		})

		local stopSpin
		local function syncMotion()
			if responsive.reduceMotion then
				if stopSpin then stopSpin(); stopSpin = nil end
				rotor.Rotation = 0
			elseif not stopSpin then
				rotor.Rotation = 0
				local spin = env.tween:Create(rotor, theme.motion.spin, { Rotation = 360 })
				stopSpin = dispose.tween(spin, "spinner rotation")
				spin:Play()
			end
		end
		local stopPreference = dispose.add(responsive.changed:connect(syncMotion), "spinner motion preference")
		holder.Destroying:Connect(function()
			stopPreference()
			if stopSpin then stopSpin(); stopSpin = nil end
		end)
		syncMotion()
		return holder
	end

	function C.switch(parent, props)
		props = props or {}
		local width = theme.size.switchWide
		local height = theme.size.switch
		local inset = math.max(math.floor(height / 8), 2)
		local knobSize = height - inset * 2
		local button = Instance.new("TextButton", parent)
		button.Text = ""
		button.AutoButtonColor = false
		button.Size = UDim2.fromOffset(math.max(width, responsive.minTarget()), math.max(height, responsive.minTarget()))
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.Selectable = true
		button.LayoutOrder = props.layoutOrder or 0
		local rail = P.frame(button, {
			name = "Rail",
			size = UDim2.fromOffset(width, height),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
			bg = theme.color.surfaceActive,
			radius = theme.radius.pill,
		})
		local stroke = P.stroke(rail, theme.color.border)

		local knob = P.frame(rail, {
			name = "Knob",
			size = UDim2.fromOffset(knobSize, knobSize),
			position = UDim2.new(0, inset + knobSize / 2, 0.5, 0),
			anchor = Vector2.new(0.5, 0.5),
			bg = theme.color.textTertiary,
			radius = theme.radius.pill,
		})

		local handle = { value = props.value == true }

		local hovered, focused, pressed = false, false, false
		local function paint(animate)
			local motion = animate and (pressed and "press" or "hover") or "instant"
			P.animate(rail, motion, {
				BackgroundColor3 = handle.value and ((hovered or pressed) and theme.color.accentHot or theme.color.accent)
					or ((hovered or pressed) and theme.color.surfaceHover or theme.color.surfaceActive),
			})
			P.animate(stroke, motion, {
				Color = focused and theme.color.solid or (handle.value and theme.color.accent or theme.color.borderStrong),
			})
			-- A fixed anchor prevents the thumb jumping before its position tween starts.
			P.animate(knob, motion, {
				Position = handle.value and UDim2.new(1, -(inset + knobSize / 2), 0.5, 0)
					or UDim2.new(0, inset + knobSize / 2, 0.5, 0),
				BackgroundColor3 = handle.value and theme.color.onSolid or theme.color.textSecondary,
			})
		end
		button.MouseEnter:Connect(function() hovered = true; paint(true) end)
		button.MouseLeave:Connect(function() hovered = false; pressed = false; paint(true) end)
		button.MouseButton1Down:Connect(function() pressed = true; paint(true) end)
		button.MouseButton1Up:Connect(function() pressed = false; paint(true) end)
		button.SelectionGained:Connect(function() focused = true; paint(true) end)
		button.SelectionLost:Connect(function() focused = false; paint(true) end)

		function handle.set(value, silent)
			handle.value = value == true
			paint(true)
			if not silent and props.onChange then pcall(props.onChange, handle.value) end
		end

		button.Activated:Connect(function() handle.set(not handle.value) end)
		paint(false)
		handle.instance = button
		return handle
	end

	-- Track, fill and knob, dragged with either pointer or touch. The value is
	-- reported live while dragging and committed on release, so a setting that costs
	-- something to apply can wait for the commit.
	function C.slider(parent, props)
		props = props or {}
		-- `stops` names the allowed values instead of a range, and the knob then moves
		-- one stop per equal slice of the track. A token budget needs that: four
		-- thousand to a million as a linear range puts every value anyone actually
		-- picks inside the first three percent of the control, where one pixel is
		-- several thousand tokens and 24k cannot be told from 32k.
		local stops = props.stops
		if stops and #stops < 2 then stops = nil end
		local min = props.min or (stops and stops[1]) or 0
		local max = props.max or (stops and stops[#stops]) or 1
		local step = props.step
		local height = math.max(responsive.minTarget(), theme.size.controlSmall)

		local shell = P.frame(parent, {
			name = props.name or "Slider",
			size = UDim2.new(1, 0, 0, height),
			layoutOrder = props.layoutOrder,
		})
		local track = P.frame(shell, {
			name = "Track",
			size = UDim2.new(1, -theme.size.knob, 0, theme.size.track),
			position = UDim2.new(0, theme.size.knob / 2, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			bg = theme.color.surfaceActive,
			radius = theme.radius.pill,
		})
		local fill = P.frame(track, {
			name = "Fill",
			size = UDim2.fromScale(0, 1),
			bg = theme.color.accent,
			radius = theme.radius.pill,
		})
		local knob = P.frame(shell, {
			name = "Knob",
			size = UDim2.fromOffset(theme.size.knob, theme.size.knob),
			anchor = Vector2.new(0.5, 0.5),
			bg = theme.color.solid,
			radius = theme.radius.pill,
			zIndex = 3,
		})

		local handle = { value = util.clamp(props.value or min, min, max), instance = shell }

		local function nearestStop(value)
			local bestIndex, bestGap = 1, math.huge
			for index, candidate in ipairs(stops) do
				local gap = math.abs(candidate - value)
				if gap < bestGap then bestIndex, bestGap = index, gap end
			end
			return bestIndex
		end

		local function quantise(value)
			if stops then return stops[nearestStop(value)] end
			if step and step > 0 then
				value = min + math.floor(((value - min) / step) + 0.5) * step
			end
			return util.clamp(value, min, max)
		end

		local function alphaFor(value)
			if stops then return (nearestStop(value) - 1) / (#stops - 1) end
			return (max > min) and ((value - min) / (max - min)) or 0
		end

		local function paint()
			local alpha = alphaFor(handle.value)
			fill.Size = UDim2.fromScale(alpha, 1)
			knob.Position = UDim2.new(alpha, theme.size.knob * (0.5 - alpha), 0.5, 0)
		end

		function handle.set(value, silent)
			handle.value = quantise(tonumber(value) or min)
			paint()
			if not silent and props.onChange then pcall(props.onChange, handle.value) end
		end

		local dragging = false
		local dragInput
		local alive = true

		local function fromInput(input)
			local origin = track.AbsolutePosition.X
			local span = math.max(track.AbsoluteSize.X, 1)
			local alpha = util.clamp((input.Position.X - origin) / span, 0, 1)
			if stops then
				local index = math.floor(alpha * (#stops - 1) + 0.5) + 1
				handle.set(stops[math.max(1, math.min(#stops, index))])
			else
				handle.set(min + alpha * (max - min))
			end
		end

		local hit = Instance.new("TextButton", shell)
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.new(1, 0, 1, 0)
		hit.ZIndex = 4
		hit.AutoButtonColor = false
		hit.Selectable = true

		local hovered, focused = false, false
		local knobOutline = P.stroke(knob, theme.color.accent, theme.stroke.hair)
		knobOutline.Transparency = 1
		local function paintInteraction()
			if not alive then return end
			local diameter = theme.size.knob + ((dragging or hovered or focused) and theme.space.hair or 0)
			P.animate(knob, "press", { Size = UDim2.fromOffset(diameter, diameter) })
			P.animate(knobOutline, "hover", { Transparency = (focused or dragging) and 0 or 1 })
			P.animate(fill, "hover", { BackgroundColor3 = (hovered or dragging) and theme.color.accentHot or theme.color.accent })
		end
		hit.MouseEnter:Connect(function() hovered = true; paintInteraction() end)
		hit.MouseLeave:Connect(function() hovered = false; paintInteraction() end)
		hit.SelectionGained:Connect(function() focused = true; paintInteraction() end)
		hit.SelectionLost:Connect(function() focused = false; paintInteraction() end)
		hit.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if dragging or not alive then return end
			dragging = true
			dragInput = input
			fromInput(input)
			paintInteraction()
		end)

		local function finishDrag(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not dragging or not dragInput then return end
			if kind ~= dragInput.UserInputType then return end
			if kind == Enum.UserInputType.Touch and input ~= dragInput then return end
			dragging = false
			dragInput = nil
			paintInteraction()
			if props.onCommit then pcall(props.onCommit, handle.value) end
		end
		hit.InputEnded:Connect(finishDrag)
		local stopMove = dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not dragging or not dragInput then return end
			local kind = input.UserInputType
			if dragInput.UserInputType == Enum.UserInputType.Touch then
				if input ~= dragInput then return end
			elseif kind ~= Enum.UserInputType.MouseMovement then
				return
			end
			fromInput(input)
		end), "slider drag")
		local stopRelease = dispose.connection(env.uis.InputEnded:Connect(finishDrag), "slider release")
		shell.Destroying:Connect(function()
			alive = false
			dragging = false
			dragInput = nil
			stopMove()
			stopRelease()
		end)

		paint()
		return handle
	end

	-- Segmented control. Used for permission mode, density, log level: anywhere a
	-- dropdown would hide the options that matter.
	--
	-- The width is capped rather than left to fill the parent. Filling is right on a
	-- phone and absurd on a desktop: at 1920 a two-option control stretched across
	-- the whole window and rendered as two words nine hundred pixels apart, which
	-- reads as a layout fault rather than as something to press. The cap comes from
	-- the labels, because a fixed budget per segment either wastes half the control
	-- on "Log" or truncates "Auto (ask for dangerous)".
	local SEGMENT_MIN = 64
	local SEGMENT_CAP = 860

	-- Average glyph advance as a fraction of the font size, for this family at label
	-- weight. Derived rather than hardcoded in pixels, so the measurement follows the
	-- text scale instead of silently mis-measuring every label at 1.4.
	local GLYPH_RATIO = 0.53

	local function segmentedWidth(options)
		local perCharacter = theme.text.label.size * GLYPH_RATIO
		local total = 0
		for _, option in ipairs(options or {}) do
			local text = tostring(option.label or option.value or option)
			total = total + math.max(SEGMENT_MIN, math.floor(#text * perCharacter) + theme.space.md * 2)
		end
		total = total + theme.space.xxs + math.max(#(options or {}) - 1, 0) * theme.space.hair
		return math.min(total, SEGMENT_CAP)
	end

	-- The width a segmented control wants, for a caller that has to state one because
	-- its own row is sizing itself to its contents. Exposed rather than left private
	-- so the header does not have to keep a remembered number in step with the labels.
	function C.segmentedWidth(options)
		return segmentedWidth(options)
	end

	function C.segmented(parent, props)
		props = props or {}
		local height = math.max(theme.size.tab, responsive.minTarget())
		local cap = segmentedWidth(props.options)
		-- An inset well: the container is a step *below* whatever it sits on and has
		-- no outline of its own, so the selected segment reads as raised out of it
		-- rather than as one bordered box inside another.
		local row = P.row(parent, {
			name = props.name or "Segmented",
			-- An explicit width is an offset, because a scale width contributes
			-- nothing to a parent that is sizing itself to its contents.
			size = props.width and UDim2.fromOffset(props.width, height)
				or UDim2.new(1, 0, 0, height),
			maxSize = (not props.width) and Vector2.new(cap, math.huge) or nil,
			bg = theme.color.surface,
			radius = theme.radius.md,
			gap = theme.space.hair,
			padding = theme.space.hair,
			layoutOrder = props.layoutOrder,
			stretch = true,
		})

		local handle = { value = props.value, buttons = {} }

		local function paint()
			for value, entry in pairs(handle.buttons) do
				local selected = value == handle.value
				local active = entry.hovered or entry.focused
				P.animate(entry.button, entry.pressed and "press" or "hover", {
					BackgroundColor3 = (selected or entry.pressed) and theme.color.surfaceActive or theme.color.surfaceHover,
					BackgroundTransparency = (selected or active or entry.pressed) and 0 or 1,
				})
				P.animate(entry.label, "hover", {
					TextColor3 = (selected or active) and theme.color.text or theme.color.textSecondary,
				})
				P.animate(entry.outline, "hover", {
					Color = entry.focused and theme.color.accent or theme.color.borderSubtle,
					Transparency = (entry.focused or selected) and 0 or 1,
				})
			end
		end

		for index, option in ipairs(props.options or {}) do
			local value = option.value or option
			local button = Instance.new("TextButton", row)
			button.Name = "Segment_" .. tostring(value)
			button.Text = ""
			button.AutoButtonColor = false
			button.BackgroundColor3 = theme.color.surface
			button.BackgroundTransparency = 1
			button.BorderSizePixel = 0
			button.Size = UDim2.new(0, 0, 1, 0)
			button.LayoutOrder = index
			button.Selectable = true
			P.corner(button, theme.radius.sm)
			local flex = Instance.new("UIFlexItem", button)
			flex.FlexMode = Enum.UIFlexMode.Fill

			local label = P.text(button, {
				text = option.label or tostring(value),
				truncate = true,
				padding = { x = theme.space.xs },
				role = "label",
				color = theme.color.textTertiary,
				align = "Center",
				size = UDim2.new(1, 0, 1, 0),
			})

			local outline = P.stroke(button, theme.color.borderSubtle)
			outline.Transparency = 1
			local entry = { button = button, label = label, outline = outline }
			handle.buttons[value] = entry
			button.MouseEnter:Connect(function() entry.hovered = true; paint() end)
			button.MouseLeave:Connect(function() entry.hovered = false; entry.pressed = false; paint() end)
			button.MouseButton1Down:Connect(function() entry.pressed = true; paint() end)
			button.MouseButton1Up:Connect(function() entry.pressed = false; paint() end)
			button.SelectionGained:Connect(function() entry.focused = true; paint() end)
			button.SelectionLost:Connect(function() entry.focused = false; entry.pressed = false; paint() end)
			button.Activated:Connect(function()
				handle.value = value
				paint()
				if props.onChange then pcall(props.onChange, value) end
			end)
		end

		function handle.set(value)
			handle.value = value
			paint()
		end

		paint()
		handle.instance = row
		return handle
	end

	function C.progress(parent, props)
		props = props or {}
		local track = P.frame(parent, {
			name = "Progress",
			size = UDim2.new(1, 0, 0, theme.size.track),
			bg = theme.color.surfaceActive,
			radius = theme.radius.pill,
			layoutOrder = props.layoutOrder,
			clip = true,
		})
		local fill = P.frame(track, {
			name = "Fill",
			size = UDim2.fromScale(util.clamp(props.value or 0, 0, 1), 1),
			bg = props.color or theme.color.accent,
			radius = theme.radius.pill,
		})
		local handle = { instance = track }
		function handle.set(value)
			P.animate(fill, "hover", {
				Size = UDim2.fromScale(util.clamp(value or 0, 0, 1), 1),
			})
		end
		return handle
	end

	function C.keyValue(parent, props)
		props = props or {}
		local keyWidth = props.keyWidth or theme.size.keyColumn
		local row = P.row(parent, {
			name = "KeyValue",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			alignY = "Top",
			layoutOrder = props.layoutOrder,
		})
		local key = P.text(row, {
			text = tostring(props.key or ""),
			role = "small",
			color = theme.color.textTertiary,
			size = nil,
			layoutOrder = 1,
			truncate = true,
		})
		key.Size = UDim2.new(0, keyWidth, 0, theme.text.small.height)
		local value = P.text(row, {
			text = tostring(props.value or ""),
			role = props.role or "small",
			color = props.color or theme.color.text,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
		})
		value.Size = UDim2.new(1, -(keyWidth + theme.space.sm), 0, 0)
		return row, value
	end

	function C.emptyState(parent, props)
		props = props or {}
		local column = P.column(parent, {
			name = "Empty",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			alignX = "Center",
			padding = { y = theme.space.xxl, x = theme.space.lg },
			layoutOrder = props.layoutOrder,
		})
		local emblem = P.frame(column, {
			name = "Emblem",
			size = UDim2.fromOffset(theme.size.controlLarge, theme.size.controlLarge),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.lg,
			layoutOrder = 1,
		})
		icons.draw(props.icon or "document", emblem, theme.size.iconLarge or theme.size.icon, theme.color.textSecondary)
		P.text(column, {
			text = tostring(props.title or ""),
			layoutOrder = 2,
			role = "bodyStrong",
			color = theme.color.textSecondary,
			align = "Center",
			auto = "Y",
			wrap = true,
		})
		if props.description then
			P.text(column, {
				text = props.description,
				layoutOrder = 3,
				maxSize = Vector2.new(theme.size.readingNarrow, math.huge),
				role = "small",
				color = theme.color.textTertiary,
				align = "Center",
				wrap = true,
				auto = "Y",
			})
		end
		if props.action then
			local wrapper = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", alignX = "Center", layoutOrder = 4, padding = { top = theme.space.sm } })
			P.button(wrapper, {
				text = props.action,
				variant = "secondary",
				size = "sm",
				onClick = props.onAction,
			})
		end
		return column
	end

	return C
end
