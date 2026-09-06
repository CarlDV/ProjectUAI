-- The boot indicator, and the one piece of the interface that exists before the
-- interface does.
--
-- Running the loader used to be silent. `loadstring(game:HttpGet(...))()` fetches a
-- megabyte, parses it, then loads sixty modules and mounts a window -- on a slow
-- client that is a few seconds of nothing at all, which is indistinguishable from a
-- script that failed. What was actually missing is the only thing this can honestly
-- report: modules finishing. The loader in the bootstrap counts them and this draws
-- the count.
--
-- The denominator is every module in the artifact, which a boot deliberately does not
-- reach: a panel's module loads the first time that panel is opened, so a finished
-- boot sits at about four fifths and the closing line says so rather than rounding
-- itself up to a full bar.
--
-- Its dependencies are the two cheapest surfaces in the project on purpose. This has
-- to be on screen before the work it is measuring, so it cannot pull the icon set (an
-- asset table and a filesystem probe) or the control set behind it -- which is also
-- why the progress here is a bar and a number rather than a spinner.
return function(env)
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")

	local M = {}

	-- Where a client GUI can live. gethui is the sturdiest under an executor (nothing
	-- in the game can see it); CoreGui is next; PlayerGui always works but is wiped on
	-- respawn, so it is the last resort.
	--
	-- It lives here rather than in ui/app because this is the first surface mounted and
	-- app is the second, and two copies of the fallback chain would be two things to
	-- keep in step.
	function M.container()
		local caps = env.require("runtime/caps")
		if caps.fn.gethui then
			local ok, container = pcall(caps.fn.gethui)
			if ok and container then return container end
		end
		local okCore, coreGui = pcall(function() return env.services.CoreGui end)
		if okCore and coreGui then return coreGui end
		if env.plr then
			local playerGui = env.plr:FindFirstChild("PlayerGui") or env.plr:WaitForChild("PlayerGui")
			if playerGui then return playerGui end
		end
		return nil
	end

	-- Above the interface's own DisplayOrder, so a slow mount cannot draw over the
	-- thing reporting it.
	local DISPLAY_ORDER = 2147481000

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

		-- Bottom centre, which is where this client's own toasts land: it is a transient
		-- notice about the client rather than a dialog to be answered, and the middle of
		-- someone's screen belongs to the game they are in.
		local card = P.column(screen, {
			name = "BootPill",
			size = UDim2.fromOffset(theme.size.menuWide, 0),
			auto = "Y",
			anchor = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, -theme.space.huge),
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.lg,
			gap = theme.space.xs,
			padding = { x = theme.space.md, y = theme.space.sm },
		})
		P.stroke(card, theme.color.border)
		M.card = card

		local top = P.row(card, {
			name = "BootHead",
			size = UDim2.new(1, 0, 0, theme.text.label.height),
			gap = theme.space.xs,
			layoutOrder = 1,
		})
		P.text(top, {
			name = "BootTitle",
			text = "UAI",
			role = "label",
			color = theme.color.text,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			truncate = true,
			layoutOrder = 1,
		})
		M.count = P.text(top, {
			name = "BootCount",
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			align = "Right",
			auto = "X",
			layoutOrder = 2,
		})
		M.count.Size = UDim2.fromOffset(0, theme.text.caption.height)

		-- The bar. A real fraction of a real total, so it moves in steps of one module
		-- and stops where the boot stopped.
		local track = P.frame(card, {
			name = "BootTrack",
			size = UDim2.new(1, 0, 0, theme.size.track),
			bg = theme.color.surfaceActive,
			radius = theme.radius.pill,
			layoutOrder = 2,
			clip = true,
		})
		M.fill = P.frame(track, {
			name = "BootFill",
			size = UDim2.new(0, 0, 1, 0),
			bg = theme.color.accent,
			radius = theme.radius.pill,
		})

		M.status = P.text(card, {
			name = "BootStatus",
			text = "starting",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			size = UDim2.new(1, 0, 0, 0),
			layoutOrder = 3,
		})

		return M
	end

	-- One module finished. Called from the bootstrap's loader, so it must never raise
	-- and never do enough work to be worth measuring itself: two property writes.
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

	-- The interface is up. The closing line is the honest version of a full bar: it
	-- says how many of the artifact's modules this boot needed and what the rest are
	-- waiting for.
	function M.done(text)
		if not M.screen then return end
		if M.status then
			M.status.Text = text or "ready"
		end
		local screen = M.screen
		local card = M.card
		M.screen, M.card, M.fill, M.count, M.status = nil, nil, nil, nil, nil
		-- Held for a beat rather than cut: the last thing it says is the count, and a
		-- notice that vanishes on the same frame it finishes has not said it.
		local function drop()
			pcall(function() screen:Destroy() end)
		end
		local responsive = env.require("ui/responsive")
		if responsive.reduceMotion or not card then
			env.require("runtime/clock").delay(0.4, drop)
			return
		end
		env.require("runtime/clock").delay(0.5, function()
			local fade = env.tween:Create(card, theme.tween("exit"), {
				BackgroundTransparency = 1,
				Position = UDim2.new(0.5, 0, 1, -theme.space.lg),
			})
			fade.Completed:Connect(drop)
			fade:Play()
			-- The card's children are separate instances, so the fill and every label
			-- would otherwise hang in the air for the length of the fade.
			for _, child in ipairs(card:GetDescendants()) do
				if child:IsA("TextLabel") then
					env.tween:Create(child, theme.tween("exit"), { TextTransparency = 1 }):Play()
				elseif child:IsA("GuiObject") then
					env.tween:Create(child, theme.tween("exit"), { BackgroundTransparency = 1 }):Play()
				end
			end
			-- A cancelled or dropped tween must not leave the notice on screen for the
			-- rest of the session, which is the failure mode the window's own fade had.
			env.require("runtime/clock").delay(0.6, drop)
		end)
	end

	-- A boot that failed leaves nothing behind either, and says what happened while it
	-- is still the only thing on screen.
	function M.fail(why)
		if not M.screen then return end
		if M.status then
			M.status.Text = tostring(why or "failed to start")
			M.status.TextColor3 = theme.color.danger
		end
		if M.fill then M.fill.BackgroundColor3 = theme.color.danger end
		local screen = M.screen
		M.screen, M.card, M.fill, M.count, M.status = nil, nil, nil, nil, nil
		env.require("runtime/clock").delay(6, function()
			pcall(function() screen:Destroy() end)
		end)
	end

	return M
end
