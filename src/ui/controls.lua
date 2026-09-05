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
	local dispose = env.require("runtime/dispose")
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
		-- Three dots spread evenly around the circle rather than bunched into an arc.
		-- At icon size the arc version came out as three two-pixel dots inside eighty
		-- degrees, two of them part-transparent -- a smudge that was hard to tell from
		-- a static one, which rather defeated the point of animating it.
		local dotSize = math.max(math.floor(size / 3.2), 3)
		-- One opacity ramp, used both for the resting state and for the chase. It was
		-- two -- 0.3 at rest and 0.34 animated -- so the dots jumped a step the moment
		-- the first tick landed.
		local FADE_STEP = 0.34
		local dots = {}
		for index = 1, 3 do
			local dot = P.frame(holder, {
				name = "Dot" .. index,
				size = UDim2.fromOffset(dotSize, dotSize),
				bg = tint,
				radius = theme.radius.pill,
				anchor = Vector2.new(0.5, 0.5),
			})
			dots[index] = dot
			dot.BackgroundTransparency = (index - 1) * FADE_STEP
			local angle = (index - 1) * 120
			dot.Position = UDim2.fromScale(
				0.5 + math.cos(math.rad(angle)) * 0.34,
				0.5 + math.sin(math.rad(angle)) * 0.34)
		end
		if not responsive.reduceMotion then
			local spin = env.tween:Create(holder, theme.motion.spin, { Rotation = 360 })
			spin:Play()
			-- The dots chase each other in opacity as well as going round. A single
			-- Rotation tween on a sixteen-pixel box is easy to miss, and if a client
			-- ever declines to tween Rotation there is nothing left at all -- this does
			-- not depend on the tween having taken.
			local phase = 0
			local stop = clock.interval(theme.motion.fast, function()
				phase = (phase + 1) % 3
				for index = 1, 3 do
					dots[index].BackgroundTransparency = ((index + phase) % 3) * FADE_STEP
				end
			end)
			holder.Destroying:Connect(function()
				pcall(function() spin:Cancel() end)
				pcall(stop)
			end)
		end
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
		button.Size = UDim2.fromOffset(width, height)
		button.BackgroundColor3 = theme.color.surfaceActive
		button.BorderSizePixel = 0
		button.Selectable = true
		button.LayoutOrder = props.layoutOrder or 0
		P.corner(button, theme.radius.pill)
		local stroke = P.stroke(button, theme.color.border)

		local knob = P.frame(button, {
			name = "Knob",
			size = UDim2.fromOffset(knobSize, knobSize),
			position = UDim2.new(0, inset, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			bg = theme.color.textTertiary,
			radius = theme.radius.pill,
		})

		local handle = { value = props.value == true }

		-- On is the full accent with a cream knob, not a muted wash: a switch is the
		-- one control whose entire job is to be readable at a glance from across a
		-- settings list, and the muted version could not be told from off.
		local function paint(animate)
			local info = animate and theme.tween("hover") or theme.tween("instant")
			env.tween:Create(button, info, {
				BackgroundColor3 = handle.value and theme.color.accent or theme.color.surfaceActive,
			}):Play()
			env.tween:Create(stroke, info, {
				Color = handle.value and theme.color.accent or theme.color.border,
			}):Play()
			env.tween:Create(knob, info, {
				Position = handle.value and UDim2.new(1, -inset, 0.5, 0) or UDim2.new(0, inset, 0.5, 0),
				BackgroundColor3 = handle.value and theme.color.solid or theme.color.textTertiary,
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
			size = UDim2.new(1, 0, 0, theme.size.track),
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

		hit.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			dragging = true
			fromInput(input)
			env.tween:Create(knob, theme.tween("press"), {
				Size = UDim2.fromOffset(theme.size.knob + theme.space.xxs, theme.size.knob + theme.space.xxs),
			}):Play()
		end)

		hit.InputEnded:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not dragging then return end
			dragging = false
			env.tween:Create(knob, theme.tween("press"), {
				Size = UDim2.fromOffset(theme.size.knob, theme.size.knob),
			}):Play()
			if props.onCommit then pcall(props.onCommit, handle.value) end
		end)

		dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not dragging then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			fromInput(input)
		end))

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
				env.tween:Create(entry.button, theme.tween("hover"), {
					BackgroundColor3 = selected and theme.color.surfaceActive or theme.color.surface,
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
			env.tween:Create(fill, theme.tween("hover"), {
				Size = UDim2.fromScale(util.clamp(value or 0, 0, 1), 1),
			}):Play()
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
