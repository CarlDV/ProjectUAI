-- The boot indicator, and the one piece of the interface that exists before the
-- interface does.
--
-- Running the loader used to be silent for several seconds. `loadstring(game:HttpGet(...))()`
-- fetches a megabyte, parses it, then loads a hundred modules and mounts a window --
-- on a slow client that is a few seconds of nothing at all, which is
-- indistinguishable from a script that failed.
--
-- Two things made those seconds blank rather than reported. First, a Roblox GUI does
-- not paint until the thread that built it yields, and the whole boot used to run
-- start-to-finish without one -- so the pill was created and then never drawn until
-- the mount was already done. Second, this pill used to pull the theme and the
-- control set to draw itself, and those are most of what a boot is waiting on, so it
-- could not appear until three quarters of the work it was measuring had finished --
-- which is why the count "started at sixty-one".
--
-- So this file now depends on nothing. It draws with raw instances and a hardcoded
-- slice of the dark palette, which lets the bootstrap mount it first, before a single
-- other module loads, and force one paint so it is on screen for the whole boot. The
-- motion is a shimmer on a repeating tween rather than a spinner: it advances on every
-- frame the engine renders, and the bootstrap yields on a small time budget while it
-- loads so those frames actually happen.
--
-- The denominator is every module in the artifact, which a boot deliberately does not
-- reach: a panel's module loads the first time that panel is opened, so a finished
-- boot sits at about four fifths and the closing line says so rather than rounding
-- itself up to a full bar.
return function(env)
	local M = {}

	-- A hardcoded slice of ui/theme's dark ramp. Copied rather than required because
	-- this surface exists before the theme is built; a splash is transient and the
	-- accent is fixed, so the duplication cannot drift in any way a user would see.
	local COLOR = {
		surface = Color3.fromRGB(50, 50, 46),
		track = Color3.fromRGB(62, 62, 57),
		border = Color3.fromRGB(74, 74, 71),
		text = Color3.fromRGB(245, 244, 238),
		dim = Color3.fromRGB(163, 161, 152),
		accent = Color3.fromRGB(217, 119, 87),
		accentHot = Color3.fromRGB(232, 146, 117),
		danger = Color3.fromRGB(240, 132, 124),
	}

	local WIDTH = 188

	-- Where a client GUI can live. gethui is the sturdiest under an executor (nothing
	-- in the game can see it); CoreGui is next; PlayerGui always works but is wiped on
	-- respawn, so it is the last resort. Inlined rather than taken from runtime/caps
	-- so this can mount before caps -- or any module -- has loaded.
	function M.container()
		-- Bare globals, the way runtime/caps probes them: an executor exposes one of
		-- these and a plain client none, and referencing a missing one is nil rather
		-- than an error.
		if type(gethui) == "function" then
			local ok, container = pcall(gethui)
			if ok and typeof(container) == "Instance" then return container end
		end
		local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
		if okCore and coreGui then return coreGui end
		if env.plr then
			local playerGui = env.plr:FindFirstChild("PlayerGui")
			if playerGui then return playerGui end
		end
		return nil
	end

	-- Above the interface's own DisplayOrder, so a slow mount cannot draw over the
	-- thing reporting it.
	local DISPLAY_ORDER = 2147481000

	local function corner(instance, radius)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = instance
		return c
	end

	local function label(parent, opts)
		local text = Instance.new("TextLabel")
		text.BackgroundTransparency = 1
		text.BorderSizePixel = 0
		text.Text = opts.text or ""
		text.TextColor3 = opts.color or COLOR.text
		text.TextSize = opts.size or 13
		text.Font = opts.font or Enum.Font.GothamMedium
		text.TextXAlignment = opts.align or Enum.TextXAlignment.Left
		text.TextYAlignment = Enum.TextYAlignment.Center
		text.TextWrapped = opts.wrap == true
		text.Size = opts.rect or UDim2.new(1, 0, 0, 16)
		text.Position = opts.position or UDim2.new(0, 0, 0, 0)
		text.AnchorPoint = opts.anchor or Vector2.new(0, 0)
		text.Parent = parent
		return text
	end

	function M.show()
		if M.screen then return M end
		local container = M.container()
		if not container then return M end

		local screen = Instance.new("ScreenGui")
		screen.Name = "UAI_Boot"
		screen.ResetOnSpawn = false
		screen.DisplayOrder = DISPLAY_ORDER
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		pcall(function() screen.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets end)
		screen.Parent = container
		M.screen = screen

		-- Bottom centre, which is where this client's own toasts land: it is a
		-- transient notice about the client rather than a dialog to be answered, and
		-- the middle of someone's screen belongs to the game they are in.
		local card = Instance.new("Frame")
		card.Name = "BootPill"
		card.AnchorPoint = Vector2.new(0.5, 1)
		card.Position = UDim2.new(0.5, 0, 1, -40)
		card.Size = UDim2.fromOffset(WIDTH, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.BackgroundColor3 = COLOR.surface
		card.BorderSizePixel = 0
		card.Parent = screen
		corner(card, 9)
		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR.border
		stroke.Thickness = 1
		stroke.Parent = card
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 7)
		pad.PaddingBottom = UDim.new(0, 7)
		pad.PaddingLeft = UDim.new(0, 9)
		pad.PaddingRight = UDim.new(0, 9)
		pad.Parent = card
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Vertical
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 5)
		list.Parent = card
		M.card = card

		-- Header: the mark, the name, and the count on the right.
		local head = Instance.new("Frame")
		head.Name = "BootHead"
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0, 14)
		head.LayoutOrder = 1
		head.Parent = card

		local mark = Instance.new("Frame")
		mark.Name = "BootBrand"
		mark.BackgroundTransparency = 1
		mark.Size = UDim2.fromOffset(14, 14)
		mark.AnchorPoint = Vector2.new(0, 0.5)
		mark.Position = UDim2.new(0, 0, 0.5, 0)
		mark.Parent = head
		pcall(function() env.require("ui/brand").draw(mark, 14) end)

		label(head, {
			text = "UAI",
			color = COLOR.text,
			size = 12,
			font = Enum.Font.GothamBold,
			anchor = Vector2.new(0, 0.5),
			position = UDim2.new(0, 20, 0.5, 0),
			rect = UDim2.new(0.5, 0, 1, 0),
		})
		M.count = label(head, {
			text = "",
			color = COLOR.dim,
			size = 11,
			font = Enum.Font.Gotham,
			align = Enum.TextXAlignment.Right,
			anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, 0, 0.5, 0),
			rect = UDim2.new(0.5, 0, 1, 0),
		})

		-- The bar. A real fraction of a real total underneath, and a shimmer over it
		-- that moves on its own tween so there is motion from the very first frame,
		-- before the count means anything.
		local track = Instance.new("Frame")
		track.Name = "BootTrack"
		track.BackgroundColor3 = COLOR.track
		track.BorderSizePixel = 0
		track.Size = UDim2.new(1, 0, 0, 3)
		track.LayoutOrder = 2
		track.ClipsDescendants = true
		track.Parent = card
		corner(track, 2)

		M.fill = Instance.new("Frame")
		M.fill.Name = "BootFill"
		M.fill.BackgroundColor3 = COLOR.accent
		M.fill.BorderSizePixel = 0
		M.fill.Size = UDim2.new(0, 0, 1, 0)
		M.fill.Parent = track
		corner(M.fill, 2)

		local shimmer = Instance.new("Frame")
		shimmer.Name = "BootShimmer"
		shimmer.BackgroundColor3 = COLOR.accentHot
		shimmer.BackgroundTransparency = 0.15
		shimmer.BorderSizePixel = 0
		shimmer.Size = UDim2.new(0.32, 0, 1, 0)
		shimmer.Position = UDim2.new(-0.4, 0, 0, 0)
		shimmer.Parent = track
		corner(shimmer, 2)
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = shimmer

		-- One repeating tween, so it advances on every frame the engine draws without a
		-- thread of its own to leak. Cancelled in done/fail.
		local ok, sweep = pcall(function()
			return env.tween:Create(shimmer,
				TweenInfo.new(1.15, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, 0),
				{ Position = UDim2.new(1.08, 0, 0, 0) })
		end)
		if ok and sweep then
			M.sweep = sweep
			pcall(function() sweep:Play() end)
		end

		-- One line, truncated. A module id or a phase can be long, and letting it wrap
		-- is what made the pill grow a second and third row and read as bulky.
		M.status = label(card, {
			text = "starting",
			color = COLOR.dim,
			size = 11,
			font = Enum.Font.Gotham,
			rect = UDim2.new(1, 0, 0, 12),
		})
		M.status.TextTruncate = Enum.TextTruncate.AtEnd
		M.status.LayoutOrder = 3

		return M
	end

	-- One module finished. Called from the bootstrap's loader, so it must never raise
	-- and never do enough work to be worth measuring itself.
	function M.step(id, count, total)
		if not M.screen then return end
		if M.count then
			M.count.Text = string.format("%d / %d", count or 0, total or 0)
		end
		if M.fill and total and total > 0 then
			M.fill.Size = UDim2.new(math.min((count or 0) / total, 1), 0, 1, 0)
		end
		if M.status and id then M.status.Text = tostring(id) end
	end

	-- A named phase of the startup that is not module loading: the file migration.
	-- Same card, same bar, a word instead of a module id.
	function M.phase(text, fraction)
		if not M.screen then return end
		if M.status then M.status.Text = tostring(text or "") end
		if M.fill and fraction ~= nil then
			M.fill.Size = UDim2.new(math.max(0, math.min(fraction, 1)), 0, 1, 0)
		end
	end

	local function stopSweep()
		if M.sweep then
			pcall(function() M.sweep:Cancel() end)
			M.sweep = nil
		end
	end

	-- The interface is up. The closing line is the honest version of a full bar: it
	-- says how many of the artifact's modules this boot needed and what the rest are
	-- waiting for.
	function M.done(text)
		if not M.screen then return end
		if M.status then M.status.Text = text or "ready" end
		stopSweep()
		local screen, card = M.screen, M.card
		M.screen, M.card, M.fill, M.count, M.status = nil, nil, nil, nil, nil
		local function drop()
			pcall(function() screen:Destroy() end)
		end

		local reduceMotion = false
		pcall(function() reduceMotion = env.require("ui/responsive").reduceMotion == true end)
		if reduceMotion or not card then
			task.delay(0.4, drop)
			return
		end

		-- Held for a beat rather than cut: the last thing it says is the count, and a
		-- notice that vanishes on the same frame it finishes has not said it.
		task.delay(0.5, function()
			local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			pcall(function()
				env.tween:Create(card, tweenInfo, {
					BackgroundTransparency = 1,
					Position = UDim2.new(0.5, 0, 1, -28),
				}):Play()
			end)
			for _, child in ipairs(card:GetDescendants()) do
				pcall(function()
					if child:IsA("TextLabel") then
						env.tween:Create(child, tweenInfo, { TextTransparency = 1 }):Play()
					elseif child:IsA("GuiObject") then
						env.tween:Create(child, tweenInfo, { BackgroundTransparency = 1 }):Play()
					elseif child:IsA("UIStroke") then
						env.tween:Create(child, tweenInfo, { Transparency = 1 }):Play()
					end
				end)
			end
			-- A cancelled or dropped tween must not leave the notice on screen for the
			-- rest of the session.
			task.delay(0.4, drop)
		end)
	end

	-- A boot that failed leaves nothing behind either, and says what happened while it
	-- is still the only thing on screen.
	function M.fail(why)
		if not M.screen then return end
		stopSweep()
		if M.status then
			M.status.Text = tostring(why or "failed to start")
			M.status.TextColor3 = COLOR.danger
		end
		if M.fill then M.fill.BackgroundColor3 = COLOR.danger end
		local screen = M.screen
		M.screen, M.card, M.fill, M.count, M.status = nil, nil, nil, nil, nil
		task.delay(6, function()
			pcall(function() screen:Destroy() end)
		end)
	end

	return M
end
