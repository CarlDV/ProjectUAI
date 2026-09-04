-- Compound controls built from the primitives.
--
-- Each one owns its own state and exposes a handle, so a panel never reaches into
-- an instance to change what a control shows.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")

	local C = {}

	-- A rotating arc, approximated with three dots at descending opacity. Rotation
	-- is the one property Roblox will tween indefinitely, so this costs one tween
	-- rather than a per-frame connection.
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
		local tint = props.color or theme.color.accent
		for index = 1, 3 do
			local dot = P.frame(holder, {
				name = "Dot" .. index,
				size = UDim2.fromOffset(math.max(math.floor(size / 5), 2), math.max(math.floor(size / 5), 2)),
				bg = tint,
				radius = theme.radius.pill,
				anchor = Vector2.new(0.5, 0.5),
			})
			dot.BackgroundTransparency = (index - 1) * 0.32
			local angle = (index - 1) * 40
			dot.Position = UDim2.fromScale(
				0.5 + math.cos(math.rad(angle)) * 0.38,
				0.5 + math.sin(math.rad(angle)) * 0.38)
		end
		if not responsive.reduceMotion then
			local spin = env.tween:Create(holder,
				TweenInfo.new(0.9, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
				{ Rotation = 360 })
			spin:Play()
			holder.Destroying:Connect(function() pcall(function() spin:Cancel() end) end)
		end
		return holder
	end

	function C.switch(parent, props)
		props = props or {}
		local width = 38
		local height = 22
		local button = Instance.new("TextButton", parent)
		button.Text = ""
		button.AutoButtonColor = false
		button.Size = UDim2.fromOffset(width, height)
		button.BackgroundColor3 = theme.color.surfaceActive
		button.BorderSizePixel = 0
		button.Selectable = true
		button.LayoutOrder = props.layoutOrder or 0
		P.corner(button, theme.radius.pill)
		local stroke = P.stroke(button, theme.color.border)

		local knob = P.frame(button, {
			name = "Knob",
			size = UDim2.fromOffset(height - 6, height - 6),
			position = UDim2.new(0, 3, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			bg = theme.color.textSecondary,
			radius = theme.radius.pill,
		})

		local handle = { value = props.value == true }

		local function paint(animate)
			local info = animate and theme.tween("hover") or TweenInfo.new(0.01)
			env.tween:Create(button, info, {
				BackgroundColor3 = handle.value and theme.color.accentMuted or theme.color.surfaceActive,
			}):Play()
			env.tween:Create(stroke, info, {
				Color = handle.value and theme.color.accentBorder or theme.color.border,
			}):Play()
			env.tween:Create(knob, info, {
				Position = handle.value and UDim2.new(1, -3, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
				BackgroundColor3 = handle.value and theme.color.accentHot or theme.color.textSecondary,
			}):Play()
			knob.AnchorPoint = handle.value and Vector2.new(1, 0.5) or Vector2.new(0, 0.5)
		end

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
		local min = props.min or 0
		local max = props.max or 1
		local step = props.step
		local height = math.max(responsive.minTarget(), 24)

		local shell = P.frame(parent, {
			name = props.name or "Slider",
			size = UDim2.new(1, 0, 0, height),
			layoutOrder = props.layoutOrder,
		})
		local track = P.frame(shell, {
			name = "Track",
			size = UDim2.new(1, 0, 0, 4),
			position = UDim2.fromScale(0, 0.5),
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
			size = UDim2.fromOffset(14, 14),
			anchor = Vector2.new(0.5, 0.5),
			bg = theme.color.text,
			radius = theme.radius.pill,
			zIndex = 3,
		})
		P.stroke(knob, theme.color.borderStrong)

		local handle = { value = util.clamp(props.value or min, min, max), instance = shell }

		local function quantise(value)
			if step and step > 0 then
				value = min + math.floor(((value - min) / step) + 0.5) * step
			end
			return util.clamp(value, min, max)
		end

		local function paint()
			local alpha = (max > min) and ((handle.value - min) / (max - min)) or 0
			fill.Size = UDim2.fromScale(alpha, 1)
			knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		end

		function handle.set(value, silent)
			handle.value = quantise(tonumber(value) or min)
			paint()
			if not silent and props.onChange then pcall(props.onChange, handle.value) end
		end

		local dragging = false

		local function fromInput(input)
			local origin = track.AbsolutePosition.X
			local span = math.max(track.AbsoluteSize.X, 1)
			local alpha = util.clamp((input.Position.X - origin) / span, 0, 1)
			handle.set(min + alpha * (max - min))
		end

		local hit = Instance.new("TextButton", shell)
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.new(1, 0, 1, 0)
		hit.ZIndex = 4
		hit.AutoButtonColor = false
		hit.Selectable = true

		hit.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			dragging = true
			fromInput(input)
			env.tween:Create(knob, theme.tween("press"), { Size = UDim2.fromOffset(18, 18) }):Play()
		end)

		hit.InputEnded:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not dragging then return end
			dragging = false
			env.tween:Create(knob, theme.tween("press"), { Size = UDim2.fromOffset(14, 14) }):Play()
			if props.onCommit then pcall(props.onCommit, handle.value) end
		end)

		env.uis.InputChanged:Connect(function(input)
			if not dragging then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			fromInput(input)
		end)

		paint()
		return handle
	end

	-- Segmented control. Used for permission mode, density, log level: anywhere a
	-- dropdown would hide the options that matter.
	function C.segmented(parent, props)
		props = props or {}
		local row = P.row(parent, {
			name = props.name or "Segmented",
			size = UDim2.new(1, 0, 0, math.max(theme.size.tab, responsive.minTarget())),
			bg = theme.color.surfaceRaised,
			radius = theme.radius.md,
			gap = 2,
			padding = 2,
			layoutOrder = props.layoutOrder,
			stretch = true,
		})
		P.stroke(row, theme.color.borderSubtle)

		local handle = { value = props.value, buttons = {} }

		local function paint()
			for value, entry in pairs(handle.buttons) do
				local selected = value == handle.value
				env.tween:Create(entry.button, theme.tween("hover"), {
					BackgroundColor3 = selected and theme.color.surfaceActive or theme.color.surfaceRaised,
					BackgroundTransparency = selected and 0 or 1,
				}):Play()
				env.tween:Create(entry.label, theme.tween("hover"), {
					TextColor3 = selected and theme.color.text or theme.color.textTertiary,
				}):Play()
			end
		end

		for index, option in ipairs(props.options or {}) do
			local value = option.value or option
			local button = Instance.new("TextButton", row)
			button.Name = "Segment_" .. tostring(value)
			button.Text = ""
			button.AutoButtonColor = false
			button.BackgroundColor3 = theme.color.surfaceRaised
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
				role = "label",
				color = theme.color.textTertiary,
				align = "Center",
				size = UDim2.new(1, 0, 1, 0),
			})

			handle.buttons[value] = { button = button, label = label }
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
			size = UDim2.new(1, 0, 0, 3),
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
			env.tween:Create(fill, theme.tween("hover"), {
				Size = UDim2.fromScale(util.clamp(value or 0, 0, 1), 1),
			}):Play()
		end
		return handle
	end

	function C.keyValue(parent, props)
		props = props or {}
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
		key.Size = UDim2.new(0, props.keyWidth or 108, 0, theme.text.small.size + 4)
		local value = P.text(row, {
			text = tostring(props.value or ""),
			role = props.role or "small",
			color = props.color or theme.color.text,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
		})
		value.Size = UDim2.new(1, -(props.keyWidth or 108) - theme.space.sm, 0, 0)
		return row, value
	end

	function C.emptyState(parent, props)
		props = props or {}
		local column = P.column(parent, {
			name = "Empty",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			alignX = "Center",
			padding = { y = theme.space.xxl, x = theme.space.lg },
			layoutOrder = props.layoutOrder,
		})
		P.text(column, {
			text = tostring(props.title or ""),
			role = "bodyStrong",
			color = theme.color.textSecondary,
			align = "Center",
			auto = "Y",
			wrap = true,
		})
		if props.description then
			P.text(column, {
				text = props.description,
				role = "small",
				color = theme.color.textTertiary,
				align = "Center",
				wrap = true,
				auto = "Y",
			})
		end
		if props.action then
			local wrapper = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", alignX = "Center" })
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
