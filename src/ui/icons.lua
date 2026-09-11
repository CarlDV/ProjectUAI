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
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local fsx = env.require("runtime/fsx")
	local assets = env.require("ui/assets")

	local M = {}

	local LUCIDE_MAP = {
		close = "x",
		minus = "minus",
		plus = "plus",
		check = "check",
		chevron = "chevron-down",
		dot = "dot",
		bars = "menu",
		stop = "square",
		send = "send",
		copy = "copy",
		trash = "trash",
		sidebarToggle = "panel-left",
		search = "search",
		arrowLeft = "arrow-left",
		arrowRight = "arrow-right",
		code = "code",
		windowMinimize = "minus",
		windowMaximize = "maximize-2",
		circleHollow = "circle",
		enter = "send",
		folder = "folder",
		branch = "git-branch",
		worktree = "git-fork",
		terminal = "square-terminal",
		document = "file-text",
		gear = "settings",
		sliders = "sliders-horizontal",
		globe = "globe",
		book = "book-open",
		signOut = "log-out",
		ellipsis = "ellipsis",
		spark = "sparkles",
	}

	local assetCache = {}

	local function getCustomIcon(name)
		local mapped = LUCIDE_MAP[name]
		if not mapped then return nil end
		if assetCache[name] then return assetCache[name] end

		if not (caps.fn.customasset and caps.fs) then
			return nil
		end

		local relPath = "icons/" .. mapped .. ".png"
		local fullPath = fsx.resolve(relPath)
		if not fullPath then return nil end

		local targetVer = (assets and assets.VERSION) or 1
		local currentVer = config.get("assets.icons_version", 0)
		local needsWrite = (not fsx.exists(relPath)) or (currentVer < targetVer)

		if needsWrite and assets and assets.icons and assets.icons[mapped] then
			local decoded = assets.decode(assets.icons[mapped])
			if decoded then
				fsx.write(relPath, decoded)
			end
		end

		if currentVer < targetVer then
			config.set("assets.icons_version", targetVer)
		end

		local ok, asset = pcall(caps.fn.customasset, fullPath)
		if ok and asset and type(asset) == "string" and asset ~= "" then
			assetCache[name] = asset
			return asset
		end

		return nil
	end

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

	local function makeCustom(parent, size, name, asset, colour, rotation)
		local frame = holder(parent, size, name)
		if rotation and rotation ~= 0 then
			frame.Rotation = rotation
		end
		local img = Instance.new("ImageLabel", frame)
		img.Name = "Image"
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(1, 1)
		img.Image = asset
		img.ImageColor3 = colour
		return frame
	end

	local function customOrHolder(parent, size, name, iconKey, colour, rotation)
		local asset = getCustomIcon(iconKey)
		if asset then
			return makeCustom(parent, size, name, asset, colour, rotation), true
		end
		local frame = holder(parent, size, name)
		if rotation and rotation ~= 0 then
			frame.Rotation = rotation
		end
		return frame, false
	end

	local WEIGHT = 0.115

	function M.close(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconClose", "close", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.78, WEIGHT), rotation = 45, color = tint })
		bar(frame, { size = UDim2.fromScale(0.78, WEIGHT), rotation = -45, color = tint })
		return frame
	end

	function M.minus(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconMinus", "minus", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.72, WEIGHT), color = tint })
		return frame
	end

	function M.plus(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconPlus", "plus", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.72, WEIGHT), color = tint })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.72), color = tint })
		return frame
	end

	function M.check(parent, size, colour)
		local tint = colour or theme.color.success
		local frame, custom = customOrHolder(parent, size, "IconCheck", "check", tint)
		if custom then return frame end
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
		local rot = CHEVRON_ROTATION[direction or "down"] or 0
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconChevron", "chevron", tint, rot)
		if custom then return frame end
		frame.Rotation = rot
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
		local tint = colour or theme.color.accent
		local frame, custom = customOrHolder(parent, size, "IconDot", "dot", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.42, 0.42), color = tint })
		return frame
	end

	function M.bars(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconBars", "bars", tint)
		if custom then return frame end
		for index, offset in ipairs({ 0.26, 0.5, 0.74 }) do
			bar(frame, {
				size = UDim2.fromScale(0.74, WEIGHT * 0.9), color = tint,
				position = UDim2.fromScale(0.5, offset), zIndex = index + 1,
			})
		end
		return frame
	end

	function M.stop(parent, size, colour)
		local tint = colour or theme.color.text
		local frame, custom = customOrHolder(parent, size, "IconStop", "stop", tint)
		if custom then return frame end
		local square = bar(frame, { size = UDim2.fromScale(0.5, 0.5), color = tint, radius = 0 })
		Instance.new("UICorner", square).CornerRadius = UDim.new(0, theme.radius.sm)
		return frame
	end

	-- A send affordance: the return arrow ↵ matching Claude Code Desktop.
	function M.send(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconSend", "send", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.accent
		local frame, custom = customOrHolder(parent, size, "IconSpark", "spark", tint)
		if custom then return frame end
		for _, rotation in ipairs({ 0, 45, 90, 135 }) do
			bar(frame, { size = UDim2.fromScale(0.82, WEIGHT), rotation = rotation, color = tint })
		end
		return frame
	end

	function M.copy(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconCopy", "copy", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.danger
		local frame, custom = customOrHolder(parent, size, "IconTrash", "trash", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconSidebarToggle", "sidebarToggle", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconSearch", "search", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconArrowLeft", "arrowLeft", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.56, WEIGHT), color = tint, position = UDim2.fromScale(0.52, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.35, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.35, 0.62) })
		return frame
	end

	function M.arrowRight(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconArrowRight", "arrowRight", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.56, WEIGHT), color = tint, position = UDim2.fromScale(0.48, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.65, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.65, 0.62) })
		return frame
	end

	function M.code(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconCode", "code", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconWindowMaximize", "windowMaximize", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textTertiary
		local frame, custom = customOrHolder(parent, size, "IconCircleHollow", "circleHollow", tint)
		if custom then return frame end
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
	-- Claude Code Desktop Companion Mascot:
	-- A friendly, high-tech animated companion perched atop the composer.
	--
	-- Designed with sleek rounded geometry, dark curved visor, dual glowing cybernetic
	-- eyes, and smooth physics-based motion:
	--  - Idle: Gentle anti-gravity hover float (Sine.InOut), antiphase breathing shadow,
	--          subtle antenna sway, and natural lifelike eye blinks.
	--  - Busy: Energetic rhythmic bouncy hover with perky antennae and visor glance.
	function M.mascot(parent, size, colour)
		local frame = holder(parent, size, "IconMascot")
		local tint = colour or theme.color.accent
		local bg = theme.color.canvas
		local eyeColor = Color3.fromRGB(255, 255, 255)

		-- Soft dynamic ground shadow (scales in antiphase with the hover)
		local shadow = bar(frame, {
			size = UDim2.fromScale(0.60, 0.08),
			color = bg,
			position = UDim2.fromScale(0.5, 0.94),
			radius = 1,
			zIndex = 1,
		})
		shadow.BackgroundTransparency = 0.55

		-- Antenna stem & glowing orb tip
		local antennaStem = bar(frame, {
			size = UDim2.fromScale(0.08, 0.16),
			color = tint,
			position = UDim2.fromScale(0.5, 0.18),
			radius = 2,
			zIndex = 2,
		})
		local antennaTip = bar(frame, {
			size = UDim2.fromScale(0.16, 0.16),
			color = tint,
			position = UDim2.fromScale(0.5, 0.10),
			radius = 1,
			zIndex = 3,
		})

		-- Rounded side pods / arms
		local leftArm = bar(frame, {
			size = UDim2.fromScale(0.12, 0.26),
			color = tint,
			position = UDim2.fromScale(0.14, 0.54),
			radius = 3,
			zIndex = 2,
		})
		local rightArm = bar(frame, {
			size = UDim2.fromScale(0.12, 0.26),
			color = tint,
			position = UDim2.fromScale(0.86, 0.54),
			radius = 3,
			zIndex = 2,
		})

		-- Main rounded bot body
		local body = bar(frame, {
			size = UDim2.fromScale(0.72, 0.58),
			color = tint,
			position = UDim2.fromScale(0.5, 0.52),
			radius = 7,
			zIndex = 3,
		})

		-- Curved dark visor screen
		local visor = bar(frame, {
			size = UDim2.fromScale(0.56, 0.30),
			color = bg,
			position = UDim2.fromScale(0.5, 0.44),
			radius = 5,
			zIndex = 4,
		})

		-- Dual expressive glowing eyes inside the visor
		local leftEye = bar(frame, {
			size = UDim2.fromScale(0.12, 0.16),
			color = eyeColor,
			position = UDim2.fromScale(0.38, 0.44),
			radius = 2,
			zIndex = 5,
		})
		local rightEye = bar(frame, {
			size = UDim2.fromScale(0.12, 0.16),
			color = eyeColor,
			position = UDim2.fromScale(0.62, 0.44),
			radius = 2,
			zIndex = 5,
		})

		-- Tiny feet
		local leftFoot = bar(frame, {
			size = UDim2.fromScale(0.16, 0.12),
			color = tint,
			position = UDim2.fromScale(0.32, 0.84),
			radius = 3,
			zIndex = 2,
		})
		local rightFoot = bar(frame, {
			size = UDim2.fromScale(0.16, 0.12),
			color = tint,
			position = UDim2.fromScale(0.68, 0.84),
			radius = 3,
			zIndex = 2,
		})

		local responsive = env.require("ui/responsive")
		local clock = env.require("runtime/clock")
		local handle = { instance = frame, busy = false }
		local tweens, stopBlink = {}, nil

		local rest = {
			{ part = frame, key = "Position", value = UDim2.fromScale(0.5, 0.5) },
			{ part = frame, key = "Rotation", value = 0 },
			{ part = antennaStem, key = "Rotation", value = 0 },
			{ part = antennaTip, key = "Position", value = UDim2.fromScale(0.5, 0.10) },
			{ part = shadow, key = "Size", value = UDim2.fromScale(0.60, 0.08) },
			{ part = shadow, key = "BackgroundTransparency", value = 0.55 },
			{ part = leftArm, key = "Position", value = UDim2.fromScale(0.14, 0.54) },
			{ part = rightArm, key = "Position", value = UDim2.fromScale(0.86, 0.54) },
			{ part = leftEye, key = "Position", value = UDim2.fromScale(0.38, 0.44) },
			{ part = rightEye, key = "Position", value = UDim2.fromScale(0.62, 0.44) },
			{ part = leftEye, key = "Size", value = UDim2.fromScale(0.12, 0.16) },
			{ part = rightEye, key = "Size", value = UDim2.fromScale(0.12, 0.16) },
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

			local busy = handle.busy == true
			local floatPeriod = busy and 0.55 or 1.8
			local floatDistance = busy and -4 or -2.5

			-- Smooth anti-gravity hover float & gentle rocking
			local floatInfo = TweenInfo.new(floatPeriod, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			play(frame, floatInfo, { Position = UDim2.new(0.5, 0, 0.5, floatDistance) })

			local rockAngle = busy and 6 or 3
			frame.Rotation = -rockAngle
			local rockInfo = TweenInfo.new(floatPeriod, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			play(frame, rockInfo, { Rotation = rockAngle })

			-- Antiphase dynamic shadow scaling
			local shadowInfo = TweenInfo.new(floatPeriod, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			play(shadow, shadowInfo, {
				Size = UDim2.fromScale(busy and 0.50 or 0.54, 0.08),
				BackgroundTransparency = busy and 0.70 or 0.65,
			})

			-- Gentle antenna tilt & sway
			local swayInfo = TweenInfo.new(floatPeriod * 1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			local swayAngle = busy and 8 or 4
			antennaStem.Rotation = -swayAngle * 0.5
			play(antennaStem, swayInfo, { Rotation = swayAngle })

			if busy then
				-- Playful glance when thinking
				local glanceInfo = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true)
				play(leftEye, glanceInfo, { Position = UDim2.fromScale(0.42, 0.44) })
				play(rightEye, glanceInfo, { Position = UDim2.fromScale(0.66, 0.44) })
			end

			-- Natural eye blink cycle
			stopBlink = clock.interval(busy and 1.8 or 3.6, function()
				if not frame.Parent then return end
				local function setBlink(shut)
					leftEye.Size = UDim2.fromScale(0.12, shut and 0.02 or 0.16)
					rightEye.Size = UDim2.fromScale(0.12, shut and 0.02 or 0.16)
				end
				setBlink(true)
				clock.delay(0.10, function()
					setBlink(false)
					-- Occasional cute double-blink when idle
					if not busy and math.random() > 0.6 then
						clock.delay(0.12, function()
							setBlink(true)
							clock.delay(0.08, function() setBlink(false) end)
						end)
					end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconEnter", "enter", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.34), color = tint, position = UDim2.fromScale(0.68, 0.44) })
		bar(frame, { size = UDim2.fromScale(0.42, WEIGHT), color = tint, position = UDim2.fromScale(0.5, 0.6) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.38, 0.52) })
		bar(frame, { size = UDim2.fromScale(0.22, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.38, 0.68) })
		return frame
	end

	function M.folder(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconFolder", "folder", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconBranch", "branch", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.66), color = tint, position = UDim2.fromScale(0.34, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.32, WEIGHT), rotation = -40, color = tint, position = UDim2.fromScale(0.5, 0.44) })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.32), color = tint, position = UDim2.fromScale(0.66, 0.32) })
		return frame
	end

	function M.worktree(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconWorktree", "worktree", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconTerminal", "terminal", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconDocument", "document", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconGear", "gear", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconSliders", "sliders", tint)
		if custom then return frame end
		for index, pos in ipairs({ 0.28, 0.5, 0.72 }) do
			bar(frame, { size = UDim2.fromScale(WEIGHT * 0.8, 0.68), color = tint, position = UDim2.fromScale(pos, 0.5) })
			local knobY = (index == 1) and 0.38 or ((index == 2) and 0.62 or 0.44)
			bar(frame, { size = UDim2.fromScale(0.2, WEIGHT * 1.2), color = tint, position = UDim2.fromScale(pos, knobY) })
		end
		return frame
	end

	function M.globe(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconGlobe", "globe", tint)
		if custom then return frame end
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
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconBook", "book", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.3, 0.54), color = tint, position = UDim2.fromScale(0.34, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.3, 0.54), color = tint, position = UDim2.fromScale(0.66, 0.5) })
		bar(frame, { size = UDim2.fromScale(WEIGHT * 0.8, 0.58), color = theme.color.canvas, position = UDim2.fromScale(0.5, 0.5), zIndex = 3 })
		return frame
	end

	function M.signOut(parent, size, colour)
		local tint = colour or theme.color.textSecondary
		local frame, custom = customOrHolder(parent, size, "IconSignOut", "signOut", tint)
		if custom then return frame end
		bar(frame, { size = UDim2.fromScale(0.48, WEIGHT), color = tint, position = UDim2.fromScale(0.44, 0.5) })
		bar(frame, { size = UDim2.fromScale(0.24, WEIGHT), rotation = -45, color = tint, position = UDim2.fromScale(0.58, 0.38) })
		bar(frame, { size = UDim2.fromScale(0.24, WEIGHT), rotation = 45, color = tint, position = UDim2.fromScale(0.58, 0.62) })
		bar(frame, { size = UDim2.fromScale(WEIGHT, 0.62), color = tint, position = UDim2.fromScale(0.24, 0.5) })
		return frame
	end

	function M.ellipsis(parent, size, colour)
		local tint = colour or theme.color.textTertiary
		local frame, custom = customOrHolder(parent, size, "IconEllipsis", "ellipsis", tint)
		if custom then return frame end
		for index, offset in ipairs({ 0.2, 0.5, 0.8 }) do
			bar(frame, {
				size = UDim2.fromScale(0.18, 0.18), color = tint,
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
