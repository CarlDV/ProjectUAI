-- Icons drawn from primitives.
--
-- No image assets and no icon font: an asset id can fail to load or be moderated,
-- and Roblox's bundled fonts have patchy glyph coverage, so a client that leans on
-- either shows empty boxes on someone's machine. These are built from thin frames,
-- which cost nothing, scale with the type ramp and are always exactly the accent
-- colour they were asked for.
--
-- Navigation deliberately uses words rather than icons. A hand-drawn glyph set
-- reads as homemade at any size; a small-caps label does not.
return function(env)
	local theme = env.require("ui/theme")

	local M = {}

	local function bar(parent, props)
		local piece = Instance.new("Frame", parent)
		piece.BorderSizePixel = 0
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = props.position or UDim2.fromScale(0.5, 0.5)
		piece.Size = props.size
		piece.Rotation = props.rotation or 0
		piece.BackgroundColor3 = props.color
		piece.ZIndex = props.zIndex or 2
		if props.radius ~= 0 then
			Instance.new("UICorner", piece).CornerRadius = UDim.new(1, 0)
		end
		return piece
	end

	-- Every icon is a square container the caller sizes; the shapes inside are
	-- expressed in scale so one implementation serves every size.
	local function holder(parent, size, name)
		local frame = Instance.new("Frame", parent)
		frame.Name = name or "Icon"
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromOffset(size, size)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		Instance.new("UIAspectRatioConstraint", frame).AspectRatio = 1
		return frame
	end

	local WEIGHT = 0.115

	function M.close(parent, size, colour)
		local frame = holder(parent, size, "IconClose")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.78, WEIGHT), rotation = 45, color = tint })
		bar(frame, { size = UDim2.fromScale(0.78, WEIGHT), rotation = -45, color = tint })
		return frame
	end

	function M.minus(parent, size, colour)
		local frame = holder(parent, size, "IconMinus")
		bar(frame, { size = UDim2.fromScale(0.72, WEIGHT), color = colour or theme.color.textSecondary })
		return frame
	end

	function M.plus(parent, size, colour)
		local frame = holder(parent, size, "IconPlus")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.72, WEIGHT), color = tint })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.72), color = tint })
		return frame
	end

	function M.check(parent, size, colour)
		local frame = holder(parent, size, "IconCheck")
		local tint = colour or theme.color.success
		bar(frame, {
			size = UDim2.fromScale(0.34, WEIGHT), rotation = 45, color = tint,
			position = UDim2.fromScale(0.3, 0.62),
		})
		bar(frame, {
			size = UDim2.fromScale(0.62, WEIGHT), rotation = -45, color = tint,
			position = UDim2.fromScale(0.58, 0.45),
		})
		return frame
	end

	-- direction: "up" | "down" | "left" | "right"
	local CHEVRON_ROTATION = { up = 180, down = 0, left = 90, right = -90 }

	function M.chevron(parent, size, colour, direction)
		local frame = holder(parent, size, "IconChevron")
		frame.Rotation = CHEVRON_ROTATION[direction or "down"] or 0
		local tint = colour or theme.color.textSecondary
		bar(frame, {
			size = UDim2.fromScale(0.46, WEIGHT), rotation = 45, color = tint,
			position = UDim2.fromScale(0.34, 0.44),
		})
		bar(frame, {
			size = UDim2.fromScale(0.46, WEIGHT), rotation = -45, color = tint,
			position = UDim2.fromScale(0.66, 0.44),
		})
		return frame
	end

	function M.dot(parent, size, colour)
		local frame = holder(parent, size, "IconDot")
		bar(frame, { size = UDim2.fromScale(0.42, 0.42), color = colour or theme.color.accent })
		return frame
	end

	function M.bars(parent, size, colour)
		local frame = holder(parent, size, "IconBars")
		local tint = colour or theme.color.textSecondary
		for index, offset in ipairs({ 0.26, 0.5, 0.74 }) do
			bar(frame, {
				size = UDim2.fromScale(0.74, WEIGHT * 0.9), color = tint,
				position = UDim2.fromScale(0.5, offset), zIndex = index + 1,
			})
		end
		return frame
	end

	function M.stop(parent, size, colour)
		local frame = holder(parent, size, "IconStop")
		local square = bar(frame, { size = UDim2.fromScale(0.5, 0.5), color = colour or theme.color.text, radius = 0 })
		Instance.new("UICorner", square).CornerRadius = UDim.new(0, theme.radius.sm)
		return frame
	end

	-- A send affordance: the return arrow ↵ matching Claude Code Desktop.
	function M.send(parent, size, colour)
		local frame = holder(parent, size, "IconSend")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.34), color = tint, position = UDim2.fromScale(0.68, 0.44) })
		bar(frame, { size = UDim2.fromScale(0.42, WEIGHT), color = tint, position = UDim2.fromScale(0.5, 0.6) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.38, 0.52) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.38, 0.68) })
		return frame
	end

	-- An eight-pointed asterisk: four bars through the centre at forty-five degree
	-- steps. It is the mark this interface is modelled on, and it is the one glyph
	-- here that carries brand rather than function -- so it gets the accent by
	-- default rather than the secondary text tone every other icon uses.
	function M.spark(parent, size, colour)
		local frame = holder(parent, size, "IconSpark")
		local tint = colour or theme.color.accent
		for _, rotation in ipairs({ 0, 45, 90, 135 }) do
			bar(frame, { size = UDim2.fromScale(0.82, WEIGHT), rotation = rotation, color = tint })
		end
		return frame
	end

	function M.copy(parent, size, colour)
		local frame = holder(parent, size, "IconCopy")
		local tint = colour or theme.color.textSecondary
		for index, spec in ipairs({
			{ position = UDim2.fromScale(0.38, 0.38), size = UDim2.fromScale(0.5, 0.5) },
			{ position = UDim2.fromScale(0.6, 0.6), size = UDim2.fromScale(0.5, 0.5) },
		}) do
			local box = Instance.new("Frame", frame)
			box.BackgroundTransparency = 1
			box.BorderSizePixel = 0
			box.AnchorPoint = Vector2.new(0.5, 0.5)
			box.Position = spec.position
			box.Size = spec.size
			box.ZIndex = index + 1
			Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.sm)
			local stroke = Instance.new("UIStroke", box)
			stroke.Color = tint
			stroke.Thickness = theme.stroke.hair
		end
		return frame
	end

	function M.trash(parent, size, colour)
		local frame = holder(parent, size, "IconTrash")
		local tint = colour or theme.color.danger
		bar(frame, { size = UDim2.fromScale(0.66, WEIGHT), color = tint, position = UDim2.fromScale(0.5, 0.26) })
		local body = Instance.new("Frame", frame)
		body.BackgroundTransparency = 1
		body.BorderSizePixel = 0
		body.AnchorPoint = Vector2.new(0.5, 0)
		body.Position = UDim2.fromScale(0.5, 0.34)
		body.Size = UDim2.fromScale(0.5, 0.5)
		Instance.new("UICorner", body).CornerRadius = UDim.new(0, theme.radius.sm)
		local stroke = Instance.new("UIStroke", body)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		return frame
	end

	function M.sidebarToggle(parent, size, colour)
		local frame = holder(parent, size, "IconSidebarToggle")
		local tint = colour or theme.color.textSecondary
		local box = Instance.new("Frame", frame)
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.76, 0.68)
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.xs + 1)
		local stroke = Instance.new("UIStroke", box)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(box, {
			size = UDim2.new(0, 1, 1, 0),
			position = UDim2.fromScale(0.38, 0.5),
			color = tint,
			radius = 0,
		})
		return frame
	end

	function M.search(parent, size, colour)
		local frame = holder(parent, size, "IconSearch")
		local tint = colour or theme.color.textSecondary
		local glass = Instance.new("Frame", frame)
		glass.BackgroundTransparency = 1
		glass.BorderSizePixel = 0
		glass.AnchorPoint = Vector2.new(0.5, 0.5)
		glass.Position = UDim2.fromScale(0.42, 0.42)
		glass.Size = UDim2.fromScale(0.46, 0.46)
		Instance.new("UICorner", glass).CornerRadius = UDim.new(1, 0)
		local stroke = Instance.new("UIStroke", glass)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(frame, {
			size = UDim2.fromScale(0.32, WEIGHT * 0.9),
			rotation = 45,
			color = tint,
			position = UDim2.fromScale(0.68, 0.68),
		})
		return frame
	end

	function M.arrowLeft(parent, size, colour)
		local frame = holder(parent, size, "IconArrowLeft")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.56, WEIGHT), color = tint, position = UDim2.fromScale(0.52, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.35, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.35, 0.62) })
		return frame
	end

	function M.arrowRight(parent, size, colour)
		local frame = holder(parent, size, "IconArrowRight")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.56, WEIGHT), color = tint, position = UDim2.fromScale(0.48, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.65, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.65, 0.62) })
		return frame
	end

	function M.code(parent, size, colour)
		local frame = holder(parent, size, "IconCode")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.28, WEIGHT * 0.85), rotation = 55, color = tint, position = UDim2.fromScale(0.32, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.28, WEIGHT * 0.85), rotation = -55, color = tint, position = UDim2.fromScale(0.32, 0.62) })
		bar(frame, { size = UDim2.fromScale(0.28, WEIGHT * 0.85), rotation = -55, color = tint, position = UDim2.fromScale(0.68, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.28, WEIGHT * 0.85), rotation = 55, color = tint, position = UDim2.fromScale(0.68, 0.62) })
		bar(frame, { size = UDim2.fromScale(0.5, WEIGHT * 0.75), rotation = -68, color = tint, position = UDim2.fromScale(0.5, 0.5) })
		return frame
	end

	function M.windowMinimize(parent, size, colour)
		return M.minus(parent, size, colour)
	end

	function M.windowMaximize(parent, size, colour)
		local frame = holder(parent, size, "IconWindowMaximize")
		local tint = colour or theme.color.textSecondary
		local box = Instance.new("Frame", frame)
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.62, 0.62)
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.xs)
		local stroke = Instance.new("UIStroke", box)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		return frame
	end

	function M.circleHollow(parent, size, colour)
		local frame = holder(parent, size, "IconCircleHollow")
		local tint = colour or theme.color.textTertiary
		local circle = Instance.new("Frame", frame)
		circle.BackgroundTransparency = 1
		circle.BorderSizePixel = 0
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.Position = UDim2.fromScale(0.5, 0.5)
		circle.Size = UDim2.fromScale(0.48, 0.48)
		Instance.new("UICorner", circle).CornerRadius = UDim.new(1, 0)
		local stroke = Instance.new("UIStroke", circle)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		return frame
	end

	-- Claude Code Retro Mascot: pixel-art crab/robot character.
	--
	-- It marches. A static sprite perched on the composer is a sticker, and a sprite
	-- that only breathes two pixels is a sticker somebody nudged -- at twenty pixels
	-- nobody notices it. So this is the arcade animation the shape is quoting: a
	-- two-frame invader. The whole body hops and rocks, the feet alternate, the arms
	-- pull in and push out on the same beat, the antennae swing against it, and the
	-- eyes glance and blink.
	--
	-- It is the only decoration in this interface, so what it does is tied to something
	-- true rather than invented: while a turn is running it marches at roughly twice the
	-- speed with wider swings, which makes it a second, peripheral answer to "is it
	-- still going?" for someone whose eyes are on the field they just typed in.
	--
	-- Returns the frame, and a handle for the state. Reduced motion gets the sprite and
	-- nothing else: the handle is still there and still answers, it simply does not move.
	local MARCH = { idle = 0.9, busy = 0.4 }
	local HOP = { idle = 3, busy = 4 }
	local ROCK = { idle = 5, busy = 9 }
	local TILT = { idle = 16, busy = 30 }
	local BLINK = { idle = 2.4, busy = 0.9 }

	function M.mascot(parent, size, colour)
		local frame = holder(parent, size, "IconMascot")
		local tint = colour or theme.color.accent
		local bg = theme.color.canvas

		-- Antennae
		local leftAntenna = bar(frame, { size = UDim2.fromScale(0.12, 0.16), color = tint, position = UDim2.fromScale(0.26, 0.16), radius = 0 })
		local rightAntenna = bar(frame, { size = UDim2.fromScale(0.12, 0.16), color = tint, position = UDim2.fromScale(0.74, 0.16), radius = 0 })

		-- Head / upper body
		bar(frame, { size = UDim2.fromScale(0.68, 0.28), color = tint, position = UDim2.fromScale(0.5, 0.38), radius = 0 })
		-- Inset eyes
		local leftEye = bar(frame, { size = UDim2.fromScale(0.12, 0.12), color = bg, position = UDim2.fromScale(0.34, 0.38), radius = 0, zIndex = 3 })
		local rightEye = bar(frame, { size = UDim2.fromScale(0.12, 0.12), color = bg, position = UDim2.fromScale(0.66, 0.38), radius = 0, zIndex = 3 })

		-- Mid body & arms
		local arms = bar(frame, { size = UDim2.fromScale(0.88, 0.22), color = tint, position = UDim2.fromScale(0.5, 0.6), radius = 0 })

		-- Feet
		local leftFoot = bar(frame, { size = UDim2.fromScale(0.15, 0.16), color = tint, position = UDim2.fromScale(0.24, 0.8), radius = 0 })
		local rightFoot = bar(frame, { size = UDim2.fromScale(0.15, 0.16), color = tint, position = UDim2.fromScale(0.76, 0.8), radius = 0 })

		local responsive = env.require("ui/responsive")
		local clock = env.require("runtime/clock")
		local handle = { instance = frame, busy = false }
		local tweens, stopBlink = {}, nil

		-- Where every moving part sits when nothing is playing. Kept rather than
		-- recomputed, because reduced motion has to be able to put the sprite back
		-- exactly, and a reversing tween that is cancelled mid-arc leaves it anywhere.
		local rest = {
			{ part = frame, key = "Position", value = UDim2.fromScale(0.5, 0.5) },
			{ part = frame, key = "Rotation", value = 0 },
			{ part = leftAntenna, key = "Rotation", value = 0 },
			{ part = rightAntenna, key = "Rotation", value = 0 },
			{ part = arms, key = "Size", value = UDim2.fromScale(0.88, 0.22) },
			{ part = leftFoot, key = "Position", value = UDim2.fromScale(0.24, 0.8) },
			{ part = rightFoot, key = "Position", value = UDim2.fromScale(0.76, 0.8) },
			{ part = leftEye, key = "Position", value = UDim2.fromScale(0.34, 0.38) },
			{ part = rightEye, key = "Position", value = UDim2.fromScale(0.66, 0.38) },
			{ part = leftEye, key = "BackgroundTransparency", value = 0 },
			{ part = rightEye, key = "BackgroundTransparency", value = 0 },
		}

		local function settle()
			for _, entry in ipairs(rest) do entry.part[entry.key] = entry.value end
		end

		local function clearMotion()
			for _, tween in ipairs(tweens) do pcall(function() tween:Cancel() end) end
			tweens = {}
			if stopBlink then
				pcall(stopBlink)
				stopBlink = nil
			end
		end

		-- One repeating, reversing tween per part. Reversing is what makes two frames out
		-- of one tween: the goal is the second frame, and the way back is the first.
		local function play(part, info, goals)
			local tween = env.tween:Create(part, info, goals)
			tween:Play()
			tweens[#tweens + 1] = tween
			return tween
		end

		local function animate()
			clearMotion()
			settle()
			if responsive.reduceMotion then return end

			local key = handle.busy and "busy" or "idle"
			local beat = MARCH[key]
			local step = TweenInfo.new(beat, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			-- The body's own beat is half the march, so it lands on both feet rather than
			-- floating over the pair of them.
			local hop = TweenInfo.new(beat / 2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, true)

			-- The hop, in offset rather than scale so it is the same movement at every
			-- icon size, and the rock, which is what stops the hop reading as a lift.
			frame.Rotation = -ROCK[key]
			play(frame, hop, { Position = UDim2.new(0.5, 0, 0.5, -HOP[key]) })
			play(frame, step, { Rotation = ROCK[key] })

			-- The feet alternate: they start level and go to different heights, so one
			-- reversing tween gives left-down-right-up and back again.
			play(leftFoot, step, { Position = UDim2.fromScale(0.2, 0.88) })
			play(rightFoot, step, { Position = UDim2.fromScale(0.8, 0.71) })

			-- Arms in and out on the same beat. The widest thing on the sprite changing
			-- width by a quarter is the part that carries at this size.
			play(arms, step, { Size = UDim2.fromScale(0.62, 0.22) })

			-- The antennae swing against the rock, on a beat of their own so the whole
			-- thing does not read as one rigid object being waggled.
			local sway = TweenInfo.new(beat * 1.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			leftAntenna.Rotation = TILT[key] * 0.5
			rightAntenna.Rotation = -TILT[key] * 0.5
			play(leftAntenna, sway, { Rotation = -TILT[key] })
			play(rightAntenna, sway, { Rotation = TILT[key] })

			-- A slow glance, which is the one thing that makes it read as looking at you
			-- rather than vibrating.
			local glance = TweenInfo.new(beat * 3.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
			play(leftEye, glance, { Position = UDim2.fromScale(0.38, 0.38) })
			play(rightEye, glance, { Position = UDim2.fromScale(0.7, 0.38) })

			-- Blinking is a timer rather than a tween: an eye is two frames of the body
			-- colour showing through, and that is a step, not a fade. Twice, quickly,
			-- because one four-pixel square going dark for a moment is easy to miss.
			stopBlink = clock.interval(BLINK[key], function()
				if not frame.Parent then return end
				local function shut(closed)
					leftEye.BackgroundTransparency = closed and 1 or 0
					rightEye.BackgroundTransparency = closed and 1 or 0
				end
				shut(true)
				clock.delay(0.09, function()
					shut(false)
					clock.delay(0.09, function()
						shut(true)
						clock.delay(0.09, function() shut(false) end)
					end)
				end)
			end)
		end

		function handle.setBusy(value)
			local wanted = value == true
			if wanted == handle.busy then return handle end
			handle.busy = wanted
			animate()
			return handle
		end

		function handle.stop()
			clearMotion()
			settle()
		end

		animate()
		frame.Destroying:Connect(clearMotion)
		return frame, handle
	end

	function M.enter(parent, size, colour)
		local frame = holder(parent, size, "IconEnter")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.34), color = tint, position = UDim2.fromScale(0.68, 0.44) })
		bar(frame, { size = UDim2.fromScale(0.42, WEIGHT), color = tint, position = UDim2.fromScale(0.5, 0.6) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.38, 0.52) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.38, 0.68) })
		return frame
	end

	function M.folder(parent, size, colour)
		local frame = holder(parent, size, "IconFolder")
		local tint = colour or theme.color.textSecondary
		local body = Instance.new("Frame", frame)
		body.BackgroundTransparency = 1
		body.BorderSizePixel = 0
		body.AnchorPoint = Vector2.new(0.5, 0.5)
		body.Position = UDim2.fromScale(0.5, 0.54)
		body.Size = UDim2.fromScale(0.74, 0.52)
		Instance.new("UICorner", body).CornerRadius = UDim.new(0, theme.radius.xs)
		local stroke = Instance.new("UIStroke", body)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(frame, { size = UDim2.fromScale(0.34, WEIGHT * 0.8), color = tint, position = UDim2.fromScale(0.32, 0.28) })
		return frame
	end

	function M.branch(parent, size, colour)
		local frame = holder(parent, size, "IconBranch")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.66), color = tint, position = UDim2.fromScale(0.34, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -40, color = tint, position = UDim2.fromScale(0.5, 0.44) })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.32), color = tint, position = UDim2.fromScale(0.66, 0.32) })
		return frame
	end

	function M.worktree(parent, size, colour)
		local frame = holder(parent, size, "IconWorktree")
		local tint = colour or theme.color.textSecondary
		local box = Instance.new("Frame", frame)
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.64, 0.64)
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.xs)
		local stroke = Instance.new("UIStroke", box)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		return frame
	end

	function M.terminal(parent, size, colour)
		local frame = holder(parent, size, "IconTerminal")
		local tint = colour or theme.color.textSecondary
		local box = Instance.new("Frame", frame)
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.72, 0.58)
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.xs)
		local stroke = Instance.new("UIStroke", box)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(frame, { size = UDim2.fromScale(0.2, WEIGHT * 0.7), rotation = 40, color = tint, position = UDim2.fromScale(0.36, 0.44) })
		bar(frame, { size = UDim2.fromScale(0.2, WEIGHT * 0.7), rotation = -40, color = tint, position = UDim2.fromScale(0.36, 0.56) })
		bar(frame, { size = UDim2.fromScale(0.2, WEIGHT * 0.7), color = tint, position = UDim2.fromScale(0.58, 0.58) })
		return frame
	end

	function M.document(parent, size, colour)
		local frame = holder(parent, size, "IconDocument")
		local tint = colour or theme.color.textSecondary
		local box = Instance.new("Frame", frame)
		box.BackgroundTransparency = 1
		box.BorderSizePixel = 0
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.54, 0.68)
		Instance.new("UICorner", box).CornerRadius = UDim.new(0, theme.radius.xs)
		local stroke = Instance.new("UIStroke", box)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(frame, { size = UDim2.fromScale(0.3, WEIGHT * 0.7), color = tint, position = UDim2.fromScale(0.48, 0.42) })
		bar(frame, { size = UDim2.fromScale(0.3, WEIGHT * 0.7), color = tint, position = UDim2.fromScale(0.48, 0.56) })
		return frame
	end

	function M.gear(parent, size, colour)
		local frame = holder(parent, size, "IconGear")
		local tint = colour or theme.color.textSecondary
		local outer = Instance.new("Frame", frame)
		outer.BackgroundTransparency = 1
		outer.BorderSizePixel = 0
		outer.AnchorPoint = Vector2.new(0.5, 0.5)
		outer.Position = UDim2.fromScale(0.5, 0.5)
		outer.Size = UDim2.fromScale(0.58, 0.58)
		Instance.new("UICorner", outer).CornerRadius = UDim.new(1, 0)
		local stroke = Instance.new("UIStroke", outer)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair * 1.5
		for _, rot in ipairs({ 0, 45, 90, 135 }) do
			bar(frame, { size = UDim2.fromScale(0.78, WEIGHT * 0.9), rotation = rot, color = tint })
		end
		return frame
	end

	function M.sliders(parent, size, colour)
		local frame = holder(parent, size, "IconSliders")
		local tint = colour or theme.color.textSecondary
		for index, pos in ipairs({ 0.28, 0.5, 0.72 }) do
			bar(frame, { size = UDim2.fromScale(WEIGHT * 0.8, 0.68), color = tint, position = UDim2.fromScale(pos, 0.5) })
			local knobY = (index == 1) and 0.38 or ((index == 2) and 0.62 or 0.44)
			bar(frame, { size = UDim2.fromScale(0.2, WEIGHT * 1.2), color = tint, position = UDim2.fromScale(pos, knobY) })
		end
		return frame
	end

	function M.globe(parent, size, colour)
		local frame = holder(parent, size, "IconGlobe")
		local tint = colour or theme.color.textSecondary
		local circle = Instance.new("Frame", frame)
		circle.BackgroundTransparency = 1
		circle.BorderSizePixel = 0
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.Position = UDim2.fromScale(0.5, 0.5)
		circle.Size = UDim2.fromScale(0.68, 0.68)
		Instance.new("UICorner", circle).CornerRadius = UDim.new(1, 0)
		local stroke = Instance.new("UIStroke", circle)
		stroke.Color = tint
		stroke.Thickness = theme.stroke.hair
		bar(frame, { size = UDim2.fromScale(0.68, WEIGHT * 0.7), color = tint, position = UDim2.fromScale(0.5, 0.5) })
		bar(frame, { size = UDim2.fromScale(WEIGHT * 0.7, 0.68), color = tint, position = UDim2.fromScale(0.5, 0.5) })
		return frame
	end

	function M.book(parent, size, colour)
		local frame = holder(parent, size, "IconBook")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.3, 0.54), color = tint, position = UDim2.fromScale(0.34, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.3, 0.54), color = tint, position = UDim2.fromScale(0.66, 0.5) })
		bar(frame, { size = UDim2.fromScale(WEIGHT * 0.8, 0.58), color = theme.color.canvas, position = UDim2.fromScale(0.5, 0.5), zIndex = 3 })
		return frame
	end

	function M.signOut(parent, size, colour)
		local frame = holder(parent, size, "IconSignOut")
		local tint = colour or theme.color.textSecondary
		bar(frame, { size = UDim2.fromScale(0.48, WEIGHT), color = tint, position = UDim2.fromScale(0.44, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.24, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.58, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.24, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.58, 0.62) })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.62), color = tint, position = UDim2.fromScale(0.24, 0.5) })
		return frame
	end

	function M.ellipsis(parent, size, colour)
		local frame = holder(parent, size, "IconEllipsis")
		local tint = colour or theme.color.textTertiary
		for index, offset in ipairs({ 0.24, 0.5, 0.76 }) do
			bar(frame, {
				size = UDim2.fromScale(0.16, 0.16), color = tint,
				position = UDim2.fromScale(offset, 0.5), zIndex = index + 1,
			})
		end
		return frame
	end

	-- Named lookup so a caller can pick an icon from config or data.
	M.byName = {
		close = M.close, minus = M.minus, plus = M.plus, check = M.check,
		dot = M.dot, bars = M.bars, stop = M.stop, send = M.send,
		copy = M.copy, trash = M.trash, chevron = M.chevron, spark = M.spark,
		sidebarToggle = M.sidebarToggle, search = M.search,
		arrowLeft = M.arrowLeft, arrowRight = M.arrowRight,
		code = M.code, windowMinimize = M.windowMinimize, windowMaximize = M.windowMaximize,
		circleHollow = M.circleHollow, mascot = M.mascot, enter = M.enter,
		folder = M.folder, branch = M.branch, worktree = M.worktree,
		terminal = M.terminal, document = M.document, gear = M.gear,
		sliders = M.sliders, globe = M.globe, book = M.book, signOut = M.signOut,
		ellipsis = M.ellipsis,
	}

	function M.draw(name, parent, size, colour, extra)
		local fn = M.byName[name]
		if not fn then return nil end
		return fn(parent, size, colour, extra)
	end

	return M
end
