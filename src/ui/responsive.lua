-- Responsiveness.
--
-- The reference client decided phone-or-desktop once at boot from
-- TouchEnabled-and-not-KeyboardEnabled, and baked two tables of pixel metrics off
-- that. It gets the common cases right and everything else wrong: a tablet, a
-- phone that rotates, a desktop window resized to half width, a console, a device
-- with both touch and a keyboard.
--
-- This module holds no metrics. It reports what the viewport is right now and
-- republishes when that changes, so a surface either adapts continuously (scale
-- based layout, list layouts, automatic sizing) or rebuilds itself when the layout
-- mode genuinely changes -- and the second is debounced, because a desktop window
-- drag fires viewport changes every frame.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")
	local log = env.require("runtime/log")

	local BREAKPOINTS = {
		{ name = "xs", max = 520 },
		{ name = "sm", max = 900 },
		{ name = "md", max = 1280 },
		{ name = "lg", max = 1700 },
		{ name = "xl", max = math.huge },
	}

	local M = {
		viewport = Vector2.new(1280, 720),
		breakpoint = "md",
		mode = "window",
		orientation = "landscape",
		touch = false,
		pointer = true,
		gamepad = false,
		console = false,
		reduceMotion = false,
		transparency = 1,
		keyboardHeight = 0,
		inset = Vector2.new(0, 0),
		bottomInset = 0,
		changed = signal.new("responsive"),
		modeChanged = signal.new("responsive:mode"),
		ready = false,
	}

	local function breakpointFor(width)
		for _, entry in ipairs(BREAKPOINTS) do
			if width < entry.max then return entry.name end
		end
		return "xl"
	end

	-- Layout mode is the only thing surfaces branch on, and it is derived rather
	-- than configured: a console is gamepad-first regardless of resolution, a
	-- narrow viewport is a sheet whether it is a phone or a small window, and the
	-- user can still pin it by hand in settings.
	--
	-- Orientation matters as much as width. A tablet held portrait is 834 points
	-- wide and 1112 tall; a floating window in that space is a tall thin box, while
	-- a full-height dock reads properly.
	local function modeFor(breakpoint, forced)
		if forced and forced ~= "auto" then return forced end
		if M.console then return "tv" end
		if breakpoint == "xs" then return "sheet" end
		if breakpoint == "sm" then return "panel" end
		if M.orientation == "portrait" then return "panel" end
		return "window"
	end

	local function sample()
		local width, height = 1280, 720

		-- The camera's viewport is the honest number: a ScreenGui's AbsoluteSize is
		-- zero until it renders, and IgnoreGuiInset changes it underneath you.
		local okCamera, camera = pcall(function() return env.services.Workspace.CurrentCamera end)
		if okCamera and camera and camera.ViewportSize and camera.ViewportSize.Y > 0 then
			width, height = camera.ViewportSize.X, camera.ViewportSize.Y
		elseif M.screen and M.screen.AbsoluteSize and M.screen.AbsoluteSize.Y > 0 then
			width, height = M.screen.AbsoluteSize.X, M.screen.AbsoluteSize.Y
		end

		M.viewport = Vector2.new(width, height)
		M.orientation = (height > width) and "portrait" or "landscape"

		local okInput = pcall(function()
			M.touch = env.uis.TouchEnabled == true
			M.pointer = env.uis.MouseEnabled == true
			M.gamepad = env.uis.GamepadEnabled == true
		end)
		if not okInput then M.touch, M.pointer = false, true end

		pcall(function()
			M.console = env.guisvc:IsTenFootInterface() == true
		end)
		pcall(function()
			M.reduceMotion = env.guisvc.ReducedMotionEnabled == true
		end)
		-- The platform preference is the default, not the last word: someone who wants
		-- the motion off in this client and on everywhere else has to be able to say so,
		-- and someone whose platform reports it wrongly has to be able to say the
		-- opposite. "auto" is the setting that defers.
		do
			local wanted = tostring(env.require("runtime/config").get("ui.reduceMotion", "auto"))
			if wanted == "on" then
				M.reduceMotion = true
			elseif wanted == "off" then
				M.reduceMotion = false
			end
		end
		pcall(function()
			local value = tonumber(env.guisvc.PreferredTransparency)
			M.transparency = value and util.clamp(value, 0, 1) or 1
		end)

		-- The topbar overlaps the top of the screen; GetGuiInset reports by how much.
		pcall(function()
			local top = env.guisvc:GetGuiInset()
			if top then M.inset = Vector2.new(top.X, top.Y) end
		end)

		-- Mobile chat and the jump button sit at the bottom on a touch device.
		M.bottomInset = M.touch and 24 or 0

		pcall(function()
			if env.uis.OnScreenKeyboardVisible then
				local size = env.uis.OnScreenKeyboardSize
				M.keyboardHeight = (size and size.Y or 0)
			else
				M.keyboardHeight = 0
			end
		end)

		local config = env.require("runtime/config")
		local previousBreakpoint, previousMode = M.breakpoint, M.mode
		M.breakpoint = breakpointFor(width)
		M.mode = modeFor(M.breakpoint, config.get("ui.layout", "auto"))

		return previousBreakpoint ~= M.breakpoint or previousMode ~= M.mode
	end

	-- Continuous changes fire `changed`; a real mode switch also fires
	-- `modeChanged`, which is the only one that triggers a rebuild.
	local function refresh(reason)
		local switched = sample()
		M.changed:fire({ reason = reason, mode = M.mode, breakpoint = M.breakpoint, viewport = M.viewport })
		if switched then
			log.debug("responsive", string.format("%s -> %s at %dx%d (%s)",
				M.breakpoint, M.mode, M.viewport.X, M.viewport.Y, tostring(reason)))
			M.modeChanged:fire({ mode = M.mode, breakpoint = M.breakpoint })
		end
	end

	local debouncedRefresh

	function M.init(screenGui)
		M.screen = screenGui
		sample()
		M.ready = true

		debouncedRefresh = clock.debounce(function() refresh("viewport") end, 0.12)

		local okCamera, camera = pcall(function() return env.services.Workspace.CurrentCamera end)
		if okCamera and camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(debouncedRefresh)
		end
		-- The camera instance itself is replaced on respawn in some games, so the
		-- workspace is watched too.
		pcall(function()
			env.services.Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
				local okNew, newCamera = pcall(function() return env.services.Workspace.CurrentCamera end)
				if okNew and newCamera then
					newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(debouncedRefresh)
				end
				refresh("camera")
			end)
		end)

		-- The on-screen keyboard is not a resize: the viewport does not change, so
		-- it has to be watched separately or the composer ends up behind it.
		for _, property in ipairs({ "OnScreenKeyboardVisible", "OnScreenKeyboardSize" }) do
			pcall(function()
				env.uis:GetPropertyChangedSignal(property):Connect(function()
					sample()
					M.changed:fire({ reason = "keyboard", mode = M.mode, breakpoint = M.breakpoint })
				end)
			end)
		end

		for _, property in ipairs({ "ReducedMotionEnabled", "PreferredTransparency" }) do
			pcall(function()
				env.guisvc:GetPropertyChangedSignal(property):Connect(function() refresh(property) end)
			end)
		end

		pcall(function()
			env.uis.LastInputTypeChanged:Connect(function(inputType)
				local name = tostring(inputType and inputType.Name or "")
				local wasGamepad = M.gamepad
				if name:find("Gamepad") then M.gamepad = true end
				if wasGamepad ~= M.gamepad then refresh("input") end
			end)
		end)

		local config = env.require("runtime/config")
		config.changed:connect(function(path)
			if path == "ui.layout" or path == "ui.reduceMotion" then refresh("setting") end
		end)

		log.info("responsive", string.format("%s / %s at %dx%d, touch %s, gamepad %s",
			M.breakpoint, M.mode, M.viewport.X, M.viewport.Y,
			M.touch and "yes" or "no", M.gamepad and "yes" or "no"))
		return M
	end

	function M.refresh(reason)
		refresh(reason or "manual")
	end

	-- Hit targets. Apple and Google both land on ~44pt for touch; a pointer can be
	-- served by much less, and cramming a mouse interface to 44px wastes the space
	-- a desktop is buying us.
	function M.minTarget()
		if M.console then return 48 end
		return M.touch and 44 or 28
	end

	function M.isNarrow()
		return M.mode == "sheet"
	end

	function M.isCompactHeight()
		return M.viewport.Y < 520 or M.keyboardHeight > 0
	end

	-- Default geometry per mode, in pixels, clamped to the viewport so the window
	-- can never open larger than the screen it is on.
	function M.geometry()
		local width, height = M.viewport.X, M.viewport.Y
		if M.mode == "sheet" then
			return {
				width = width,
				height = math.floor(height * (M.orientation == "portrait" and 0.72 or 0.9)),
				anchored = "bottom",
			}
		end
		if M.mode == "panel" then
			return {
				width = math.floor(util.clamp(width * 0.52, 320, 460)),
				height = math.floor(height - M.inset.Y - 24),
				anchored = "right",
			}
		end
		if M.mode == "tv" then
			return {
				width = math.floor(util.clamp(width * 0.62, 720, 1200)),
				height = math.floor(util.clamp(height * 0.7, 420, 760)),
				anchored = "center",
			}
		end
		return {
			width = math.floor(util.clamp(width * 0.44, 460, 780)),
			height = math.floor(util.clamp(height * 0.68, 360, 620)),
			anchored = "center",
		}
	end

	-- How much of the bottom of the screen is unusable: the on-screen keyboard when
	-- it is up, otherwise the platform's own bottom furniture.
	function M.bottomObstruction()
		if M.keyboardHeight > 0 then return M.keyboardHeight end
		return M.bottomInset
	end

	function M.describe()
		return string.format("%s / %s  %dx%d  %s%s%s",
			M.breakpoint, M.mode, M.viewport.X, M.viewport.Y,
			M.touch and "touch " or "",
			M.gamepad and "gamepad " or "",
			M.reduceMotion and "reduced-motion" or "")
	end

	return M
end
