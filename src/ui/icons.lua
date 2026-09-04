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
		Instance.new("UICorner", square).CornerRadius = UDim.new(0, 2)
		return frame
	end

	-- A send affordance: a chevron leaning right, which reads as "go" without
	-- needing an arrowhead we cannot draw cleanly at 16px.
	function M.send(parent, size, colour)
		local frame = holder(parent, size, "IconSend")
		local tint = colour or theme.color.textOnAccent
		bar(frame, {
			size = UDim2.fromScale(0.5, WEIGHT), rotation = -45, color = tint,
			position = UDim2.fromScale(0.46, 0.34),
		})
		bar(frame, {
			size = UDim2.fromScale(0.5, WEIGHT), rotation = 45, color = tint,
			position = UDim2.fromScale(0.46, 0.66),
		})
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
			Instance.new("UICorner", box).CornerRadius = UDim.new(0, 2)
			local stroke = Instance.new("UIStroke", box)
			stroke.Color = tint
			stroke.Thickness = 1
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
		Instance.new("UICorner", body).CornerRadius = UDim.new(0, 2)
		local stroke = Instance.new("UIStroke", body)
		stroke.Color = tint
		stroke.Thickness = 1
		return frame
	end

	-- Named lookup so a caller can pick an icon from config or data.
	M.byName = {
		close = M.close, minus = M.minus, plus = M.plus, check = M.check,
		dot = M.dot, bars = M.bars, stop = M.stop, send = M.send,
		copy = M.copy, trash = M.trash, chevron = M.chevron,
	}

	function M.draw(name, parent, size, colour, extra)
		local fn = M.byName[name]
		if not fn then return nil end
		return fn(parent, size, colour, extra)
	end

	return M
end
