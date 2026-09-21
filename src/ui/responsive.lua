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
	local dispose = env.require("runtime/dispose")

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
		if M.touch and not M.pointer then return "panel" end
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
		local platformBottom = 0
		pcall(function()
			local top, bottom = env.guisvc:GetGuiInset()
			if top then M.inset = Vector2.new(top.X, top.Y) end
			if bottom then platformBottom = math.max(0, bottom.Y) end
		end)

		-- Mobile chat and the jump button sit at the bottom on a touch device.
		M.bottomInset = math.max(platformBottom, M.touch and 24 or 0)

		M.keyboardHeight = 0
		pcall(function()
			if env.uis.OnScreenKeyboardVisible then
				local size = env.uis.OnScreenKeyboardSize
				M.keyboardHeight = math.max(0, math.min(height, size and size.Y or 0))
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
		local wasMobile = M.isMobile()
		local switched = sample()
		switched = switched or wasMobile ~= M.isMobile()
		M.changed:fire({ reason = reason, mode = M.mode, breakpoint = M.breakpoint, viewport = M.viewport })
		if switched then
			log.debug("responsive", string.format("%s -> %s at %dx%d (%s)",
				M.breakpoint, M.mode, M.viewport.X, M.viewport.Y, tostring(reason)))
			M.modeChanged:fire({ mode = M.mode, breakpoint = M.breakpoint })
		end
	end

	local debouncedRefresh
	local releases = {}
	local cameraRelease
	local generation = 0

	function M.destroy()
		generation = generation + 1
		for _, release in ipairs(releases) do release() end
		releases = {}
		if cameraRelease then cameraRelease(); cameraRelease = nil end
		if M.screenFrame then M.screenFrame:Destroy(); M.screenFrame = nil end
		M.ready = false
		M.screen = nil
	end

	function M.init(screenGui)
		M.destroy()
		M.screen = screenGui
		-- Measure the coordinate space children actually occupy. ScreenGui's own
		-- origin is not a reliable stand-in for its device-safe content origin.
		local frame = Instance.new("Frame")
		frame.Name = "Viewport"
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromScale(1, 1)
		frame.Active = false
		frame.Parent = screenGui
		M.screenFrame = frame
		sample()
		M.ready = true

		local mine = generation
		debouncedRefresh = clock.debounce(function()
			if mine == generation then refresh("viewport") end
		end, 0.12)
		local function watch(connection)
			releases[#releases + 1] = dispose.connection(connection, "responsive")
		end
		local function bindCamera()
			if cameraRelease then cameraRelease(); cameraRelease = nil end
			local okCamera, camera = pcall(function() return env.services.Workspace.CurrentCamera end)
			if okCamera and camera then
				cameraRelease = dispose.connection(camera:GetPropertyChangedSignal("ViewportSize"):Connect(debouncedRefresh), "viewport")
			end
		end

		bindCamera()
		for _, property in ipairs({ "AbsoluteSize", "AbsolutePosition" }) do
			watch(frame:GetPropertyChangedSignal(property):Connect(debouncedRefresh))
		end
		-- The camera instance itself is replaced on respawn in some games, so the
		-- workspace is watched too.
		pcall(function()
			watch(env.services.Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
				bindCamera()
				refresh("camera")
			end))
		end)

		-- The on-screen keyboard is not a resize: the viewport does not change, so
		-- it has to be watched separately or the composer ends up behind it.
		for _, property in ipairs({ "OnScreenKeyboardVisible", "OnScreenKeyboardSize" }) do
			pcall(function()
				watch(env.uis:GetPropertyChangedSignal(property):Connect(function() refresh("keyboard") end))
			end)
		end

		for _, property in ipairs({ "ReducedMotionEnabled", "PreferredTransparency" }) do
			pcall(function()
				watch(env.guisvc:GetPropertyChangedSignal(property):Connect(function() refresh(property) end))
			end)
		end

		pcall(function()
			watch(env.uis.LastInputTypeChanged:Connect(function(inputType)
				local name = tostring(inputType and inputType.Name or "")
				local wasGamepad = M.gamepad
				if name:find("Gamepad") then M.gamepad = true end
				if wasGamepad ~= M.gamepad then refresh("input") end
			end))
		end)

		local config = env.require("runtime/config")
		releases[#releases + 1] = dispose.add(config.changed:connect(function(path)
			if path == "ui.layout" or path == "ui.reduceMotion" then refresh("setting") end
		end), "responsive settings")
		watch(screenGui.Destroying:Connect(function()
			if M.screen == screenGui then M.destroy() end
		end))
		releases[#releases + 1] = dispose.add(function()
			generation = generation + 1
			M.ready = false
			M.screen = nil
			M.screenFrame = nil
		end, "responsive lifetime")

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

	function M.isMobile()
		return M.touch and not M.console
			and (not M.pointer or M.mode == "sheet" or M.mode == "panel")
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
				height = math.floor(height * (M.isMobile() and 0.64 or (M.orientation == "portrait" and 0.72 or 0.9))),
				anchored = "bottom",
			}
		end
		if M.mode == "panel" then
			return {
				width = math.floor(util.clamp(width * 0.52, 320, 460)),
				height = M.isMobile() and math.floor(util.clamp(height * 0.74, 220, 560))
					or math.floor(height - M.inset.Y - 24),
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
		return math.max(M.keyboardHeight, M.bottomInset)
	end

	function M.parentGeometry(relative)
		if relative == M.screen and M.screenFrame then relative = M.screenFrame end
		local origin = relative and relative.AbsolutePosition or Vector2.new(0, 0)
		local size = relative and relative.AbsoluteSize or M.viewport
		if size.X <= 0 or size.Y <= 0 then size = M.viewport end
		return origin, size
	end

	-- Default placement avoids the top bar. Moving a surface can use the entire
	-- device-safe parent: GetGuiInset describes CoreGui's reserved band, not a
	-- physical obstruction across the whole screen. Treating it as a drag limit
	-- strands both the window and launcher far below the top on some clients.
	function M.usableRect(relative, margin, avoidTopbar)
		margin = margin or 0
		local origin, size = M.parentGeometry(relative)
		margin = math.max(0, math.min(margin, (math.min(size.X, size.Y) - 1) / 2))
		local left = (avoidTopbar == false and 0 or math.max(0, M.inset.X - origin.X)) + margin
		local top = (avoidTopbar == false and 0 or math.max(0, M.inset.Y - origin.Y)) + margin
		-- Camera.ViewportSize and GUI pixels can differ under client/display scaling.
		-- Mixing them caps movement at a fraction of the visible screen. Use the
		-- measured GUI extent for both axes, keeping the camera as a boot fallback.
		local screenOrigin, screenSize = M.parentGeometry(M.screen)
		local right = math.min(size.X, screenOrigin.X + screenSize.X - origin.X) - margin
		local bottom = math.min(size.Y, screenOrigin.Y + screenSize.Y - M.bottomObstruction() - origin.Y) - margin
		return { x = left, y = top, width = math.max(1, right - left), height = math.max(1, bottom - top) }
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
