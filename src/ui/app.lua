-- The application shell: the ScreenGui, the launcher, the window, navigation, and
-- the wiring between the session and the interface.
--
-- Surfaces here are pure functions of state, which is what makes the rebuild on a
-- layout-mode change safe: the transcript replays from the session log, every
-- panel re-reads config, and nothing is lost by throwing the tree away.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local place = env.require("runtime/place")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local dispose = env.require("runtime/dispose")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")
	local quickchat = env.require("ui/quickchat")
	local windowModule = env.require("ui/window")
	local sidebarModule = env.require("ui/sidebar")
	local sessions = env.require("agent/session")
	local providers = env.require("provider/registry")
	local usage = env.require("agent/usage")

	-- Chat and Cowork are the two the sidebar's mode switch offers; the rest are
	-- reached from the app menu or from the sidebar's More section.
	local PANELS = {
		{ id = "chat", label = "Chat", icon = "code" },
		{ id = "cowork", label = "Cowork", icon = "terminal" },
		{ id = "code", label = "Code", icon = "terminal" },
		{ id = "agents", label = "Subagents", icon = "spark" },
		{ id = "providers", label = "Providers", icon = "sliders" },
		{ id = "tools", label = "Tools", icon = "worktree" },
		{ id = "settings", label = "Settings", icon = "gear" },
		{ id = "logs", label = "Logs", icon = "document" },
	}

	local M = { panel = "chat", built = false, history = { entries = {}, index = 0 } }

	local DISCORD_INVITE = "https://discord.gg/9xYyyYuKap"

	-- A client GUI cannot open external links, so the invite goes to the clipboard
	-- and a toast confirms it. Without a clipboard, the toast shows the link itself.
	function M.joinDiscord()
		if caps.clipboard then
			local ok = pcall(caps.fn.clipboard, DISCORD_INVITE)
			overlay.toast(ok and "Discord invite copied" or DISCORD_INVITE, ok and "good" or "info", ok and 2 or 4)
		else
			overlay.toast(DISCORD_INVITE, "info", 4)
		end
	end

	-- Where a client GUI can live. gethui is the sturdiest under an executor
	-- (nothing in the game can see it); CoreGui is next; PlayerGui always works but
	-- is wiped on respawn, so it is the last resort.
	local function parentGui()
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

	function M.mount()
		if M.screen and M.screen.Parent then return M end

		local container = parentGui()
		if not container then
			log.error("app", "nowhere to parent the interface")
			return M
		end

		local screen = Instance.new("ScreenGui")
		screen.Name = "UAI_" .. tostring(math.floor(clock.ms() % 100000))
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = false
		screen.DisplayOrder = 2147480000
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		-- Safe-area handling: on a notched phone the interface must not sit under the
		-- cutout, and on a console it must stay inside the title-safe region.
		pcall(function() screen.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets end)
		pcall(function() screen.SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension end)
		screen.Parent = container
		M.screen = screen
		env.root = screen

		responsive.init(screen)
		overlay.mount(screen)

		-- Quick chat lives on the overlay layer and outlives every rebuild: it holds no
		-- transcript of its own, only a field, so there is nothing in it to rebuild.
		quickchat.mount(overlay.layer)
		quickchat.bind()

		M.buildLauncher()
		M.buildWindow()

		-- A real layout switch rebuilds; a resize does not. Debounced inside
		-- responsive, so a desktop drag does not thrash. Theme changes (accent,
		-- density, text scale, either font, the code palette, the reading width)
		-- rebuild too: colours and metrics are read at build time by design, which
		-- keeps every component free of subscription bookkeeping.
		--
		-- Both are registered for disposal, because after an unload a config write must
		-- not rebuild an interface that is no longer there.
		dispose.add(responsive.modeChanged:connect(function()
			-- Phone/tablet chrome is identical across breakpoints. Relayout keeps
			-- the live caret, selection, scroll position and provider edits intact.
			if M.window and M.window.mobile and responsive.isMobile() then return end
			M.rebuild("mode")
		end), "app.modeChanged")

		dispose.add(theme.changed:connect(clock.debounce(function()
			M.rebuild("theme")
		end, 0.2)), "app.themeChanged")

		-- Two settings decide what a transcript row *shows* rather than how it looks, so
		-- the theme's token list does not cover them and nothing else would notice they
		-- moved. Every row reads them at build time like everything else here, which
		-- meant the switch did nothing to the rows already on screen: turning reasoning
		-- on left the conversation exactly as it was, which reads as a broken toggle
		-- rather than as a setting that applies from the next turn.
		local VIEW_KEYS = {
			["ui.showReasoning"] = true,
			["ui.showToolDetail"] = true,
			["ui.showToolCode"] = true,
			["ui.showActivity"] = true,
			-- Collapsing the sidebar is a layout change the interface has to answer, and
			-- the switch in the appearance pane writes this path without the quiet flag.
			-- Without it here, that switch changed a field in config.json and nothing
			-- else until the next full reload.
			["ui.sidebarCollapsed"] = true,
		}
		local rebuildForView = clock.debounce(function()
			M.rebuild("view setting")
		end, 0.2)
		dispose.add(config.changed:connect(function(path)
			if VIEW_KEYS[tostring(path)] then rebuildForView() end
		end), "app.viewSettings")

		-- Ctrl-comma opens the settings, which is the shortcut the profile menu
		-- advertises. It is bound here because a menu that names a key it has not bound
		-- is the same kind of decoration as a label that names a mode it is not in.
		dispose.connection(env.uis.InputBegan:Connect(function(input, processed)
			if processed then return end
			if input.KeyCode ~= Enum.KeyCode.Comma then return end
			local ok, held = pcall(function()
				return env.uis:IsKeyDown(Enum.KeyCode.LeftControl)
					or env.uis:IsKeyDown(Enum.KeyCode.RightControl)
			end)
			if not ok or not held then return end
			M.showSettingsDialog("general")
		end), "app.settingsShortcut")

		-- Any conversation working is worth the launcher's dot, not just the open one:
		-- switching conversation does not stop the one you left. The list fires on every
		-- busy transition. Unread replies have their own badge, so the pulse only
		-- represents work that is actually still running.
		dispose.add(sessions.listChanged:connect(function()
			if not M.window then return end
			M.setLauncherBusy(sessions.busyCount() > 0 and not M.window.visible)
			M.syncNav()
		end), "app.busyPulse")

		-- Notifications for background conversations -----------------------------
		--
		-- The window can be closed for the whole of a long turn, and until now the only
		-- sign anything happened was a dot that was already pulsing while it ran. A
		-- finished answer, a failed request and a stopped turn are the three things
		-- someone minimized is waiting on, and they can come from any conversation --
		-- switching away does not stop the one you left.
		--
		-- Two outputs: a toast (the overlay layer sits on the ScreenGui, not the window,
		-- so it shows over the game with the window closed) and a count on the launcher
		-- that survives however long the user takes to look.
		M.notifications = {}
		local function note(kind, text, tone, session)
			local entry = {
				kind = kind,
				text = text,
				tone = tone,
				-- Keep navigation and acknowledgement tied to this conversation.
				sessionId = session and session.id or nil,
				at = clock.ms(),
			}
			M.notifications[#M.notifications + 1] = entry
			-- Bounded, same reasoning as the request history: an overnight session
			-- would otherwise pile hundreds onto a list nobody scrolls.
			while #M.notifications > 30 do
				local oldest = table.remove(M.notifications, 1)
				if oldest.toast then oldest.toast.close(true) end
			end
			M.setLauncherBadge(#M.notifications)
			if config.get("ui.notifications", true) ~= false then
				local heading = ({ turn = "Reply ready", error = "Task failed", stop = "Task stopped" })[kind] or "Project UAI"
				entry.toast = overlay.toast(text, tone, 6, {
					title = heading .. (session and session.title and ("  ·  " .. session.title) or ""),
					actionText = "Open chat",
					onActivate = function()
						if not M.openSession(entry.sessionId) then
							M.readNotifications(entry.sessionId)
							overlay.toast("This conversation is no longer available.", "info")
						end
					end,
				})
			end
			return entry
		end

		local function notificationFor(session, event)
			local kind = event.kind
			if kind == "turn:end" then
				-- Failed turns already emitted an error; do not follow it with a
				-- second notification calling the failed work a successful reply.
				if event.failed then return end
				local reply = util.trim(tostring(event.text or ""))
				local short = util.ellipsis(env.require("ui/markdown").plain(reply ~= "" and reply or "Task finished."), 160)
				note("turn", short, "good", session)
			elseif kind == "error" then
				note("error", "Could not finish: " .. util.ellipsis(tostring(event.message or "error"), 160),
				"bad", session)
			elseif kind == "abort" then
				note("stop", "Task stopped.", "warn", session)
			end
		end

		dispose.add(sessions.anyEvent:connect(function(session, event)
			if not M.window then return end
			if not session or session.headless then return end
			-- A visible conversation is already reporting its own progress. Other
			-- conversations still need a notice, including while Settings is open.
			if M.window.visible and M.panel == "chat" and sessions.activeId == session.id then return end
			notificationFor(session, event)
		end), "app.notifications")

		-- The prompt watch is client-wide and starts with the interface, so a
		-- conversation that asks for permission before anything has been opened is still
		-- answered.
		env.require("ui/panels/permission").watch()
		-- Same shape, same reason: a question can arrive from a conversation nobody is
		-- looking at, and the turn it belongs to is parked until it is answered.
		env.require("ui/panels/ask").watch()

		log.info("app", "interface mounted in " .. tostring(container.Name) .. " as " .. responsive.mode)
		return M
	end

	-- Launcher ---------------------------------------------------------------

	-- How far a press has to travel before it counts as a drag rather than a click.
	-- The window uses the same number for the same reason; both are here rather than
	-- shared because a shared one would be a module for one integer.
	local DRAG_SLOP = 6

	function M.buildLauncher()
		if M.launcher and M.launcher.Parent then return end
		local diameter = math.max(theme.size.launcher, responsive.minTarget())

		local button = Instance.new("TextButton", M.screen)
		button.Name = "Launcher"
		button.Text = ""
		button.AutoButtonColor = false
		button.BackgroundColor3 = theme.color.surfaceRaised
		button.BorderSizePixel = 0
		button.Size = UDim2.fromOffset(diameter, diameter)
		button.AnchorPoint = Vector2.new(0, 0)
		button.ZIndex = theme.z.header
		button.Selectable = true
		-- A rounded tile rather than a circle, with the mark in it: the same shape an
		-- application icon is, which reads as a thing you open rather than as a bubble
		-- someone left on the screen.
		P.corner(button, theme.radius.lg)
		local outline = P.stroke(button, theme.color.border)

		local preferred
		if config.get("ui.launcher.placed", false) then
			preferred = Vector2.new(config.get("ui.launcher.x", 0), config.get("ui.launcher.y", 0))
		end
		local function positionAt(x, y)
			local bounds = responsive.usableRect(M.screen, theme.space.xs, false)
			button.Position = UDim2.fromOffset(
				math.floor(util.clamp(x, bounds.x, math.max(bounds.x, bounds.x + bounds.width - diameter))),
				math.floor(util.clamp(y, bounds.y, math.max(bounds.y, bounds.y + bounds.height - diameter))))
		end
		local function layout()
			diameter = math.max(theme.size.launcher, responsive.minTarget())
			button.Size = UDim2.fromOffset(diameter, diameter)
			local bounds = responsive.usableRect(M.screen, theme.space.lg)
			positionAt(preferred and preferred.X or bounds.x + bounds.width - diameter,
				preferred and preferred.Y or bounds.y + bounds.height - diameter)
		end
		layout()

		icons.brand(button, theme.size.iconLarge)

		local pulse = P.statusDot(button, {
			diameter = theme.size.dot,
			color = theme.color.accent,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, theme.space.hair, 0, -theme.space.hair),
		})
		pulse.Visible = false

		-- The missed-notification count, on the edge the pulse is not: a small filled
		-- pill with the number in it, which says "three things happened" where a dot
		-- says only "something did". Built here so it exists before the first note
		-- lands, and hidden until there is a count to show.
		local badge = P.frame(button, {
			name = "LauncherBadge",
			bg = theme.color.danger,
			radius = theme.radius.pill,
			anchor = Vector2.new(0, 1),
			position = UDim2.new(0, -theme.space.hair, 1, theme.space.hair),
			size = UDim2.fromOffset(0, 0),
			zIndex = theme.z.header + 2,
		})
		local badgeCount = P.text(badge, {
			name = "LauncherBadgeCount",
			text = "",
			role = "caption",
			line = theme.line.tight,
			color = theme.color.textOnAccent,
			size = UDim2.new(1, 0, 1, 0),
			align = "Center",
			alignY = "Center",
			zIndex = theme.z.header + 3,
		})
		badge.Visible = false

		local capture = env.require("runtime/remote_capture")
		local captureBadge = P.frame(button, {
			name = "LauncherCapture", bg = theme.color.danger, radius = theme.radius.sm,
			anchor = Vector2.new(0.5, 1), position = UDim2.new(0.5, 0, 1, 0),
			size = UDim2.new(1, 0, 0, theme.text.caption.height + theme.space.xxs), zIndex = theme.z.header + 4,
		})
		local captureLabel = P.text(captureBadge, { text = "REC", role = "caption", color = theme.color.textOnAccent,
			size = UDim2.fromScale(1, 1), align = "Center", alignY = "Center", zIndex = theme.z.header + 5 })
		local function captureStatus()
			local state = capture.status
			captureBadge.Visible = state == "running" or state == "paused" or state == "starting" or #capture.rules > 0
			captureLabel.Text = #capture.rules > 0 and "RULES" or state == "paused" and "PAUSED" or "REC"
			captureBadge.BackgroundColor3 = state == "paused" and theme.color.warn or theme.color.danger
		end
		local offCapture = capture.changed:connect(captureStatus)
		captureStatus()

		-- Keep the original grab offset in parent coordinates throughout a gesture.
		-- AbsolutePosition includes the ScreenGui inset; copying it into Position
		-- and changing anchors on the first move made the launcher jump.
		local alive, hovered = true, false
		local gesture, dragConnection
		local blockedInputs = setmetatable({}, { __mode = "k" })
		local suppressActivation = false
		local fillTween, outlineTween
		local releases = {}
		local function feedback()
			if not alive then return end
			if fillTween then fillTween:Cancel() end
			if outlineTween then outlineTween:Cancel() end
			fillTween = env.tween:Create(button, theme.tween("hover"), {
				BackgroundColor3 = gesture and theme.color.accentSurface
					or (hovered and theme.color.surfaceHover or theme.color.surfaceRaised),
			})
			outlineTween = env.tween:Create(outline, theme.tween("hover"), {
				Color = gesture and theme.color.accent or (hovered and theme.color.accentBorder or theme.color.border),
			})
			fillTween:Play()
			outlineTween:Play()
		end
		local function finish(cancelled)
			if not gesture then return end
			if gesture.moved or cancelled then
				suppressActivation = true
				if cancelled and gesture.input then blockedInputs[gesture.input] = true end
			end
			if gesture.moved and not cancelled then
				preferred = Vector2.new(button.Position.X.Offset, button.Position.Y.Offset)
				config.set("ui.launcher.x", preferred.X, { quiet = true })
				config.set("ui.launcher.y", preferred.Y, { quiet = true })
				config.set("ui.launcher.placed", true, { quiet = true })
			end
			gesture = nil
			if dragConnection then dragConnection:Disconnect(); dragConnection = nil end
			feedback()
		end
		button.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			if not alive then return end
			if gesture then
				blockedInputs[input] = true
				return
			end
			blockedInputs[input] = nil
			suppressActivation = false
			gesture = { input = input, origin = input.Position, position = button.Position, moved = false }
			dragConnection = input.Changed:Connect(function()
				local state = input.UserInputState
				if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
					finish(state == Enum.UserInputState.Cancel)
				end
			end)
			feedback()
		end)

		local function matchesGestureInput(input)
			if not gesture or not input then return false end
			if input == gesture.input then return true end
			local kind = input.UserInputType
			local gkind = gesture.input and gesture.input.UserInputType
			return kind == gkind and (kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch)
		end

		releases[#releases + 1] = dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not alive or not gesture then return end
			local kind = input.UserInputType
			if gesture.input.UserInputType == Enum.UserInputType.Touch then
				if input ~= gesture.input then return end
			elseif kind ~= Enum.UserInputType.MouseMovement then return end
			local delta = input.Position - gesture.origin
			if delta.X * delta.X + delta.Y * delta.Y > DRAG_SLOP * DRAG_SLOP then gesture.moved = true end
			if not gesture.moved then return end
			suppressActivation = true
			positionAt(gesture.position.X.Offset + delta.X, gesture.position.Y.Offset + delta.Y)
		end), "launcher.move")
		releases[#releases + 1] = dispose.connection(env.uis.InputEnded:Connect(function(input)
			if gesture and matchesGestureInput(input) then
				finish(input.UserInputState == Enum.UserInputState.Cancel)
			end
		end), "launcher.release")
		releases[#releases + 1] = dispose.connection(env.uis.WindowFocusReleased:Connect(function()
			hovered = false
			finish(true)
			feedback()
		end), "launcher.focus")
		releases[#releases + 1] = responsive.changed:connect(function()
			if not alive then return end
			finish(true)
			layout()
		end)

		button.MouseEnter:Connect(function()
			hovered = true
			feedback()
		end)
		button.MouseLeave:Connect(function()
			hovered = false
			feedback()
		end)
		button.Activated:Connect(function(input)
			if not alive then return end
			if gesture and gesture.moved then return end
			local isPointer = (not input) or (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
			if (input and blockedInputs[input]) or (isPointer and suppressActivation) then
				suppressActivation = false
				if input then blockedInputs[input] = nil end
				return
			end
			if gesture and not gesture.moved then
				finish(false)
			end
			M.toggle()
		end)
		local release = dispose.add(function()
			alive = false
			offCapture()
			finish(true)
			for _, stop in ipairs(releases) do stop() end
			if fillTween then fillTween:Cancel() end
			if outlineTween then outlineTween:Cancel() end
			if M.launcher == button then
				if M.launcherTween then M.launcherTween:Cancel(); M.launcherTween = nil end
				M.launcher, M.launcherPulse, M.launcherBadge, M.launcherBadgeCount = nil, nil, nil, nil
			end
		end, "launcher")
		button.Destroying:Connect(release)

		M.launcher = button
		M.launcherPulse = pulse
		M.launcherBadge = badge
		M.launcherBadgeCount = badgeCount
		M.setLauncherBadge(#(M.notifications or {}))
	end

	-- The missed-notification count on the launcher. Called whenever the list grows;
	-- acknowledged when its conversation is opened.
	function M.readNotifications(sessionId)
		local kept = {}
		for _, entry in ipairs(M.notifications or {}) do
			if entry.sessionId == sessionId then
				if entry.toast then entry.toast.close(true) end
			else kept[#kept + 1] = entry end
		end
		M.notifications = kept
		M.setLauncherBadge(#kept)
	end

	function M.setLauncherBadge(count)
		if not M.launcherBadge then return end
		local n = math.floor(tonumber(count) or 0)
		if n <= 0 then
			M.launcherBadge.Visible = false
			return
		end
		-- Sized to the digits: a one-digit pill is a circle, a two-digit one a pill,
		-- and "9+" is where a count stops meaning anything precise.
		local shown = n > 9 and "9+" or tostring(n)
		local height = math.max(theme.size.dot * 2, theme.text.caption.height + theme.space.xxs)
		local width = math.max(height, math.ceil(P.measureText(shown, { role = "caption" }).X) + theme.space.xs * 2)
		M.launcherBadge.Size = UDim2.fromOffset(width, height)
		if M.launcherBadgeCount then M.launcherBadgeCount.Text = shown end
		M.launcherBadge.Visible = true
	end

	-- A dot named "pulse" that had never pulsed: the only thing on screen saying a
	-- turn is still running with the window closed, and it was a static toggle.
	function M.setLauncherBusy(value)
		if not M.launcherPulse then return end
		local on = value == true
		M.launcherPulse.Visible = on
		if M.launcherTween then
			pcall(function() M.launcherTween:Cancel() end)
			M.launcherTween = nil
		end
		if not on or responsive.reduceMotion then
			M.launcherPulse.BackgroundTransparency = 0
			return
		end
		M.launcherPulse.BackgroundTransparency = theme.opacity.dim
		M.launcherTween = env.tween:Create(M.launcherPulse, theme.motion.pulse,
			{ BackgroundTransparency = 0 })
		M.launcherTween:Play()
	end

	-- Window -----------------------------------------------------------------

	function M.buildWindow()
		M.window = windowModule.new(M.screen, {
			name = "UAI_Window",
			minWidth = M.sidebarVisible()
				and (theme.size.sidebar + theme.size.modalMin + theme.space.xl * 2)
				or theme.size.modalMin + theme.space.xl * 2,
			minHeight = 300,
		})
		M.buildChrome()
		-- The body is the heavy half of the mount: it builds the open panel, and the
		-- chat panel's composer and transcript are the single largest synchronous chunk
		-- of the whole boot. The window is still hidden here, so the boot indicator can
		-- yield across this break and keep animating rather than freezing on the last
		-- stretch. The hook is only set during the first mount, so a rebuild does not
		-- pay for it.
		if env.onMountPhase then env.onMountPhase("building the interface") end
		M.buildBody()
		M.window.onLayout = function()
			M.syncNav()
		end
		-- Returning to the conversation should land on the newest message. The
		-- transcript pins itself only while it is at the bottom, and a hidden
		-- scroll frame loses its canvas position to the engine -- so re-showing
		-- the window with pinned stale read as "you were reading up" and the view
		-- stayed wherever the engine left it. Re-pinning on show is the whole fix:
		-- the user was at the bottom when they minimized, so they are at the
		-- bottom when they come back.
		M.window.onShow = function()
			local panel = M.panels and M.panels[M.panel]; if panel and panel.setVisible then panel.setVisible(true) end
			if responsive.isMobile() and M.launcher then M.launcher.Visible = false end
			M.setLauncherBusy(false)
			if M.panel == "chat" then M.readNotifications(sessions.activeId) end
			if M.chatPanel and M.chatPanel.view then
				M.chatPanel.view.repin()
			end
		end
		M.window.onHide = function()
			local panel = M.panels and M.panels[M.panel]; if panel and panel.setVisible then panel.setVisible(false) end
			if responsive.isMobile() then
				if M.launcher then M.launcher.Visible = true end
				pcall(function()
					local field = env.uis:GetFocusedTextBox()
					if field and field:IsDescendantOf(M.window.root) then field:ReleaseFocus() end
				end)
			end
			M.setLauncherBusy(sessions.busyCount() > 0)
		end
	end

	-- Config is the only source of truth for this.
	--
	-- It used to be a field on the module seeded once inside mount, which mount returns
	-- early from on re-entry -- so the field and `ui.sidebarCollapsed` could diverge and
	-- never reconcile, and the switch in the appearance pane wrote a value nothing read.
	function M.sidebarVisible()
		return not responsive.isMobile() and (responsive.mode == "window") and (config.get("ui.sidebarCollapsed", false) ~= true)
	end

	-- The header reads left to right as what you are looking at, then the window
	-- controls. Navigation itself lives in the sidebar, which is where the interface
	-- this follows puts it -- and when there is no sidebar, the hamburger on the left
	-- is the whole of it. That branch used to be "sheet or narrower than 500", which
	-- left a tablet in portrait and a console with no way to change panel at all.
	function M.buildChrome()
		local header = M.window.header
		local mobile = responsive.isMobile()
		local sidebarWidth = theme.size.sidebar
		local showSidebar = M.sidebarVisible()
		local headerHeight = M.window.headerHeight or theme.size.header

		if showSidebar then
			header.Position = UDim2.new(0, sidebarWidth + 1, 0, 0)
			header.Size = UDim2.new(1, -sidebarWidth - 1, 0, headerHeight)
		else
			header.Position = UDim2.new(0, 0, 0, 0)
			header.Size = UDim2.new(1, 0, 0, headerHeight)
		end

		local left = P.row(header, {
			name = "Left",
			size = UDim2.new(0, 0, 1, 0),
			gap = theme.space.sm,
			flex = "Fill",
			layoutOrder = 1,
		})

		if not showSidebar then
			local menuButton = P.iconButton(left, {
				name = "Nav_menu",
				icon = "bars",
				diameter = theme.size.control,
				layoutOrder = 1,
			})
			menuButton.instance.LayoutOrder = 1
			menuButton.instance.Activated:Connect(function()
				M.showAppMenu(menuButton.instance)
			end)
			-- The way back. In window mode the sidebar is hidden because someone
			-- collapsed it, and the only control that could bring it back lived *inside*
			-- the sidebar -- so collapsing it was a one-way trip, and the appearance pane
			-- promised a header toggle that was not there. In sheet, panel and tv mode
			-- there is no sidebar to restore, so no button is offered.
			if responsive.mode == "window" and not mobile then
				local expand = P.iconButton(left, {
					name = "Nav_collapse",
					icon = "sidebarToggle",
					diameter = theme.size.control,
					layoutOrder = 2,
					onClick = function() M.toggleSidebar() end,
				})
				expand.instance.LayoutOrder = 2
			end
		else
			local collapse = P.iconButton(left, {
				name = "Nav_collapse",
				icon = "sidebarToggle",
				diameter = theme.size.control,
				layoutOrder = 1,
				onClick = function() M.toggleSidebar() end,
			})
			collapse.instance.LayoutOrder = 1
		end

		-- What is on screen, named. The title is the conversation on the chat panel and
		-- the panel's own name everywhere else, with the place under it -- which is the
		-- one piece of context a window floating over a game needs.
		--
		-- Both lines are set at a UI line height rather than the reading one. At body's
		-- 1.6 the pair measured 40px inside a 42px header, so the title sat one pixel
		-- under the window's top edge and the subtitle one pixel above the transcript --
		-- which is what "some stuff isn't aligned" looks like from the outside.
		--
		-- The column fills and both lines truncate, so a long provider name in the
		-- subtitle eats its own label rather than the window controls beside it: the
		-- right cluster is anchored to the header's edge, not to how wide the longest
		-- line happened to measure.
		local brandSlot = P.frame(left, {
			name = "HeaderBrand",
			size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			visible = not mobile,
			layoutOrder = 3,
		})
		icons.brand(brandSlot, theme.size.icon)

		local titleColumn = P.column(left, {
			name = "Title",
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			gap = theme.space.hair,
			alignY = "Center",
			clip = true,
			layoutOrder = 4,
		})
		M.titleLabel = P.text(titleColumn, {
			name = "TitleText",
			text = "",
			role = "bodyStrong",
			line = theme.line.tight,
			color = theme.color.text,
			truncate = true,
			size = UDim2.new(1, 0, 0, math.ceil(theme.text.bodyStrong.size * theme.line.tight)),
			layoutOrder = 1,
		})
		M.subtitleLabel = P.text(titleColumn, {
			name = "TitleDetail",
			text = "",
			role = "caption",
			line = theme.line.tight,
			color = theme.color.textTertiary,
			truncate = true,
			size = UDim2.new(1, 0, 0, math.ceil(theme.text.caption.size * theme.line.tight)),
			layoutOrder = 2,
		})
		M.subtitleLabel.Visible = not mobile

		local right = P.row(header, {
			name = "Right",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.xxs,
			layoutOrder = 3,
			-- Anchors the control cluster to the header's right edge regardless of
			-- what the title column beside it measures. Without it the row's own
			-- auto-width order could hand the cluster's slot to whichever sibling
			-- measured widest first.
			alignX = "Right",
		})

		if mobile then
			-- The old 44px corner hit area covered Send on a phone. Put resizing in
			-- the header so the entire composer remains available for typing/tapping.
			local grip = M.window.resizeGrip
			grip.Parent = right
			grip.AnchorPoint = Vector2.new(0, 0)
			grip.Position = UDim2.fromOffset(0, 0)
			grip.LayoutOrder = 1
			P.iconButton(right, {
				name = "ExpandPanel",
				icon = M.window.maximised and "minus" or "windowMaximize",
				diameter = responsive.minTarget(),
				layoutOrder = 2,
				onClick = function(button)
					M.window.toggleMaximised()
					button.setIcon(M.window.maximised and "minus" or "windowMaximize")
				end,
			})
		elseif responsive.mode == "window" then
			local minimize = P.iconButton(right, {
				name = "Minimize",
				icon = "minus",
				diameter = theme.size.control,
				layoutOrder = 1,
				onClick = function() M.hide() end,
			})
			minimize.instance.LayoutOrder = 1

			local maximise = P.iconButton(right, {
				name = "Maximise",
				icon = M.window.maximised and "minus" or "windowMaximize",
				diameter = theme.size.control,
				layoutOrder = 2,
			})
			maximise.instance.LayoutOrder = 2
			maximise.instance.Activated:Connect(function()
				M.window.toggleMaximised()
				M.rebuild("maximise")
			end)
		end

		local close = P.iconButton(right, {
			name = "Close",
			icon = "close",
			diameter = theme.size.control,
			layoutOrder = 3,
			onClick = function() M.hide() end,
		})
		close.instance.LayoutOrder = 3
	end

	-- Flips the stored flag.
	--
	-- It used to read `M.sidebarCollapsed = not M.sidebarVisible()`, which is a fixed
	-- point in both directions and therefore did nothing at all: visible means collapsed
	-- is false, and `not true` is false again, so the flag was written back unchanged.
	-- The rebuild underneath it still ran, which is what made the button look wired --
	-- the whole tree was torn down and rebuilt byte-identical.
	function M.toggleSidebar()
		local collapsed = config.get("ui.sidebarCollapsed", false) == true
		config.set("ui.sidebarCollapsed", not collapsed, { quiet = true })
		M.rebuild("sidebar")
	end

	function M.buildBody()
		local sidebarWidth = theme.size.sidebar
		local showSidebar = M.sidebarVisible()

		local host = M.window.body
		if showSidebar then
			local sideHolder = P.frame(host, {
				name = "SidebarHolder",
				size = UDim2.new(0, sidebarWidth, 1, 0),
				position = UDim2.new(0, 0, 0, 0),
				bg = theme.color.sidebar,
			})
			M.sidebar = sidebarModule.new(sideHolder, M)

			P.frame(host, {
				name = "SidebarDivider",
				size = UDim2.new(0, 1, 1, 0),
				position = UDim2.new(0, sidebarWidth, 0, 0),
				bg = theme.color.borderSubtle,
			})

			host = P.frame(host, {
				name = "MainHolder",
				size = UDim2.new(1, -sidebarWidth - 1, 1, 0),
				position = UDim2.new(0, sidebarWidth + 1, 0, 0),
			})
		else
			M.sidebar = nil
		end

		local headerHeight = M.window.headerHeight or theme.size.header
		P.frame(host, {
			name = "HeaderDivider",
			size = UDim2.new(1, 0, 0, theme.stroke.hair),
			position = UDim2.new(0, 0, 0, headerHeight - theme.stroke.hair),
			bg = theme.color.borderSubtle,
		})
		M.body = P.frame(host, {
			name = "Panels",
			size = UDim2.new(1, 0, 1, -headerHeight),
			maxSize = Vector2.new(theme.size.reading, math.huge),
			anchor = Vector2.new(0.5, 0),
			position = UDim2.new(0.5, 0, 0, headerHeight),
		})

		M.panels = {}
		M.showPanel(M.panel)
	end

	-- Panels -----------------------------------------------------------------

	local function buildChatPanel(parent)
		local panel = {}
		local column = P.frame(parent, {
			name = "Chat",
			size = UDim2.fromScale(1, 1),
		})

		panel.todos = env.require("ui/chat/todo").new(column, {
			layoutOrder = 1,
			session = sessions.current(),
		})
		panel.loops = env.require("ui/chat/loops").new(column)

		local middle = P.frame(column, {
			name = "TranscriptHolder",
			size = UDim2.new(1, 0, 1, 0),
			layoutOrder = 2,
		})

		if env.onMountPhase then env.onMountPhase("building the transcript") end
		panel.view = env.require("ui/chat/view").new(middle, {
			onInsert = function(text) if panel.composer then panel.composer.insert(text) end end,
		})

		if env.onMountPhase then env.onMountPhase("building the composer") end
		panel.composer = env.require("ui/chat/composer").new(column, {
			layoutOrder = 3,
			onSend = function(text, files)
				local session = sessions.current()
				local ok, reason = session.send(text, nil, files)
				if not ok then overlay.toast(tostring(reason), "warn", 2) end
				return ok
			end,
			onStop = function()
				sessions.current().abort()
			end,
			onClear = function()
				overlay.confirm({
					title = "Clear this conversation?",
					description = "The transcript and the model's context are both discarded.",
					confirmText = "Clear",
					onConfirm = function() sessions.current().clear() end,
				})
			end,
		})
		-- Lifted off the panel's bottom edge by the same inset the sidebar gives its
		-- own bottom row, so the composer's bottom lines up with the profile bar's
		-- rather than sitting flush against the window edge below it.
		local BOTTOM_GAP = responsive.isMobile() and 0 or 3
		panel.composer.shell.AnchorPoint = Vector2.new(0, 1)
		panel.composer.shell.Position = UDim2.new(0, 0, 1, -BOTTOM_GAP)

		-- Pin the input to the panel edge. Auto-height rows inside a filling list
		-- can grow the flex basis and leave a dead region beneath the composer.
		local function sizeTranscript()
			if not middle.Parent then return end
			local planHeight = panel.todos.shell.Visible and panel.todos.shell.AbsoluteSize.Y or 0
			local loopHeight = panel.loops.shell.Visible and panel.loops.shell.Size.Y.Offset or 0
			panel.loops.shell.Position = UDim2.fromOffset(0, planHeight)
			planHeight = planHeight + loopHeight
			local composerHeight = panel.composer.shell.AbsoluteSize.Y + BOTTOM_GAP
			middle.Position = UDim2.fromOffset(0, planHeight)
			middle.Size = UDim2.new(1, 0, 1, -(planHeight + composerHeight))
		end
		panel.composer.shell:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeTranscript)
		panel.todos.shell:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeTranscript)
		panel.todos.shell:GetPropertyChangedSignal("Visible"):Connect(sizeTranscript)
		panel.loops.shell:GetPropertyChangedSignal("Visible"):Connect(sizeTranscript)
		sizeTranscript()

		function panel.destroy()
			if panel.view then panel.view.destroy() end
			if panel.todos then panel.todos.destroy() end
		end

		return panel
	end

	local BUILDERS = {
		chat = buildChatPanel,
		cowork = function(parent) return env.require("ui/panels/cowork").new(parent) end,
		code = function(parent) return env.require("ui/panels/code").new(parent) end,
		agents = function(parent) return env.require("ui/panels/agents").new(parent) end,
		providers = function(parent) return env.require("ui/panels/providers").new(parent) end,
		tools = function(parent) return env.require("ui/panels/tools").new(parent) end,
		settings = function(parent) return env.require("ui/panels/settings").new(parent) end,
		logs = function(parent) return env.require("ui/panels/logs").new(parent) end,
	}

	function M.panelLabel(id)
		for _, entry in ipairs(PANELS) do
			if entry.id == id then return entry.label end
		end
		return tostring(id)
	end

	function M.showPanel(id)
		if not M.body then return end
		if not BUILDERS[id] then id = "chat" end
		for key, panel in pairs(M.panels or {}) do
			if panel.root then panel.root.Visible = key == id end
			if panel.setVisible then panel.setVisible(key == id) end
		end
		if not M.panels[id] then
			local holder = P.frame(M.body, {
				name = "Panel_" .. id,
				size = UDim2.fromScale(1, 1),
			})
			local ok, panel = pcall(BUILDERS[id], holder)
			if not ok then
				log.error("app", "panel '" .. id .. "' failed to build", panel)
				holder:Destroy()
				return
			end
			panel.root = holder
			M.panels[id] = panel
			if id == "chat" then M.chatPanel = panel end
		end
		M.panels[id].root.Visible = true
		if M.panels[id].setVisible then M.panels[id].setVisible(true) end
		M.panel = id
		config.set("ui.panel", id, { quiet = true })
		if id == "chat" then M.attachSession() end
		M.record()
		M.syncNav()
	end

	function M.show(id)
		if not M.screen then M.mount() end
		M.showPanel(id or M.panel)
		M.window.show()
		M.setLauncherBusy(false)
		if M.panel == "chat" then M.readNotifications(sessions.activeId) end
	end

	function M.hide()
		if M.window then M.window.hide() end
	end

	function M.toggle()
		if M.window and M.window.visible then M.hide() else M.show() end
	end

	-- Opens a conversation: switches the thread, points the transcript at it, and
	-- lands on the chat panel. This is what a row in the sidebar does, and it is the
	-- thing those rows used to fake by typing their own label into the composer.
	function M.openSession(id)
		if id and sessions.activeId ~= id then
			if not sessions.switch(id) then return false end
		end
		M.show("chat")
		if not responsive.isMobile() and M.chatPanel and M.chatPanel.composer then M.chatPanel.composer.focus() end
		return true
	end

	-- Navigation history -----------------------------------------------------

	-- Where you have been, so the two arrows in the sidebar mean something. An entry
	-- is a panel plus the conversation that was open, which is what "back" has to
	-- restore for the pair to be useful in a client whose main panel has several
	-- states.
	local HISTORY_LIMIT = 40

	function M.record()
		if M.navigating then return end
		local entry = { panel = M.panel, sessionId = sessions.activeId }
		local current = M.history.entries[M.history.index]
		if current and current.panel == entry.panel and current.sessionId == entry.sessionId then
			return
		end
		-- Anything forward of here is a branch that was not taken.
		for index = #M.history.entries, M.history.index + 1, -1 do
			table.remove(M.history.entries, index)
		end
		M.history.entries[#M.history.entries + 1] = entry
		while #M.history.entries > HISTORY_LIMIT do
			table.remove(M.history.entries, 1)
		end
		M.history.index = #M.history.entries
		if M.sidebar then M.sidebar.refresh() end
	end

	local function applyHistory(entry)
		if not entry then return end
		M.navigating = true
		if entry.sessionId and sessions.threads[entry.sessionId] then
			sessions.switch(entry.sessionId)
		end
		M.showPanel(entry.panel)
		M.navigating = false
		if M.sidebar then M.sidebar.refresh() end
	end

	function M.canBack()
		return M.history.index > 1
	end

	function M.canForward()
		return M.history.index < #M.history.entries
	end

	function M.back()
		if not M.canBack() then return false end
		M.history.index = M.history.index - 1
		applyHistory(M.history.entries[M.history.index])
		return true
	end

	function M.forward()
		if not M.canForward() then return false end
		M.history.index = M.history.index + 1
		applyHistory(M.history.entries[M.history.index])
		return true
	end

	function M.syncNav()
		local session = sessions.current()
		if M.titleLabel then
			if M.panel == "chat" then
				M.titleLabel.Text = session.title
			else
				M.titleLabel.Text = M.panelLabel(M.panel)
			end
		end
		if M.subtitleLabel then
			local parts = { place.label() }
			local record = providers.active()
			if record then
				local model = util.trim(tostring(record.model or ""))
				parts[#parts + 1] = model ~= "" and (record.label .. "  " .. model) or record.label
			else
				parts[#parts + 1] = "no provider"
			end
			-- More than one conversation running is the fact this header was missing:
			-- with the transcript showing one of them, nothing else on screen said the
			-- others were still going.
			local working = sessions.busyCount()
			if working > 1 or (working == 1 and not session.busy) then
				parts[#parts + 1] = util.pluralise(working, "conversation") .. " working"
			end
			M.subtitleLabel.Text = table.concat(parts, "  \194\183  ")
		end
		if M.sidebar then M.sidebar.refresh() end
	end

	-- Menus and dialogs -------------------------------------------------------

	function M.showSettingsDialog(category)
		return env.require("ui/panels/settingsdialog").open(category)
	end

	-- The hamburger. Every panel, plus the two things that are not panels: a new
	-- conversation and the search.
	function M.showAppMenu(target)
		if responsive.isMobile() then
			return env.require("ui/mobilenav").open(M, PANELS)
		end
		local options = {}
		for _, entry in ipairs(PANELS) do
			options[#options + 1] = {
				label = entry.label,
				value = entry.id,
				icon = entry.icon,
				selected = entry.id == M.panel,
			}
		end
		options[#options + 1] = { divider = true }
		options[#options + 1] = { label = "New conversation", value = "new", icon = "plus" }
		options[#options + 1] = { label = "Search conversations", value = "search", icon = "search" }
		-- The one thing a phone has no other road to: with no sidebar there is no
		-- profile row, and Settings is several taps deeper. Unload is offered here
		-- so every layout mode can reach the same exit.
		options[#options + 1] = { label = "Unload UAI", value = "unload", icon = "signOut", tone = "bad" }

		-- With no sidebar there is nowhere else the conversation list can be, and a
		-- phone is exactly where someone is most likely to be picking up an older one.
		-- Every conversation carries the same actions its sidebar row has -- open,
		-- rename, delete -- because a phone without them is a phone that can look at
		-- its history but never manage it. The submenu is one level deep, opened from
		-- the row it belongs to, rather than a fourth flat option per conversation.
		if not M.sidebarVisible() then
			local recent = sessions.list()
			if #recent > 0 then options[#options + 1] = { divider = true } end
			for index, session in ipairs(recent) do
				if index > 8 then break end
				options[#options + 1] = {
					label = session.title,
					value = "session:" .. session.id,
					detail = session.placeName,
					selected = session.id == sessions.activeId,
					icon = "circleHollow",
					chevron = true,
				}
			end
		end

		-- A conversation row with a chevron opens its own menu: the same actions the
		-- sidebar's ellipsis offers, from the place a phone has them. Renaming and
		-- deleting are not desktop-only features; a phone is where the history is
		-- most likely to need pruning.
		local function sessionActions(session, target)
			overlay.menu({
				target = target,
				width = theme.size.menu,
				options = {
					{ isHeader = true, title = session.title, subtitle = session.placeName },
					{ label = "Open", value = "open", icon = "arrowRight" },
					{ label = "Rename", value = "rename", icon = "document" },
					{ label = "Delete", value = "delete", icon = "trash", tone = "bad" },
				},
				onSelect = function(value)
					if value == "open" then
						M.openSession(session.id)
					elseif value == "rename" then
						overlay.prompt({
							title = "Rename this conversation",
							description = "The transcript is untouched; only what the list calls it changes.",
							placeholder = "a short title",
							value = session.title,
							confirmText = "Rename",
							onConfirm = function(text)
								local ok, why = session.rename(text)
								if not ok then overlay.toast(tostring(why), "warn", 2) end
							end,
						})
					elseif value == "delete" then
						overlay.confirm({
							title = "Delete this conversation?",
							description = "The transcript and its file are both removed. This cannot be undone.",
							confirmText = "Delete",
							danger = true,
							onConfirm = function()
								sessions.remove(session.id)
								M.openSession(sessions.current().id)
							end,
						})
					end
				end,
			})
		end

		overlay.menu({
			target = target,
			width = theme.size.menuWide,
			options = options,
			onSelect = function(value, option)
				if value == "new" then
					M.openSession(sessions.newThread().id)
				elseif value == "search" then
					M.showSearch()
				elseif value == "unload" then
					overlay.confirm({
						title = "Unload UAI?",
						description = "Stops the current turn, drains every timer and input handler, "
							.. "saves your settings and removes the interface. Run the loader again to come back.",
						confirmText = "Unload",
						danger = true,
						onConfirm = function()
							local globals = (type(getgenv) == "function") and getgenv() or nil
							local live = globals and globals.UAI
							if live and live.destroy then
								live.destroy()
							else
								dispose.drain()
								pcall(function() M.screen:Destroy() end)
							end
						end,
					})
				elseif util.startsWith(tostring(value), "session:") then
					local id = tostring(value):sub(9)
					local session = sessions.threads[id]
					-- A row with a chevron is a folder of actions rather than a straight
					-- open; the menu it opens is anchored to this one, so it has a target.
					if session and option and option.chevron and target then
						sessionActions(session, target)
					else
						M.openSession(id)
					end
				else
					M.show(value)
				end
			end,
		})
	end

	function M.showProfileMenu(target, onClose)
		local menu = overlay.menu({
			target = target,
			width = theme.size.menuWide,
			rowHeight = theme.size.controlLarge,
			-- This short menu fits its contents on desktop; the overlay still clamps
			-- it to usable screen space and scrolls when the viewport is smaller.
			maxHeight = math.huge,
			onClose = onClose,
			options = {
				env.require("ui/profile").menuHeader(),
				{ label = "Settings", value = "settings", icon = "gear", shortcut = "Ctrl ," },
				{ label = "Providers & models", value = "providers", icon = "sliders" },
				{ divider = true },
				{ label = env.require("ui/changelog").menuLabel(), value = "changelog", icon = "spark" },
				{ label = "About this build", value = "about", icon = "book" },
				{ label = "Join Discord", value = "discord", icon = "globe" },
				{ divider = true },
				{ label = "Unload UAI", value = "unload", icon = "signOut", tone = "bad" },
			},
			onSelect = function(value)
				if value == "settings" then
					M.showSettingsDialog("general")
				elseif value == "providers" then
					M.show("providers")
				elseif value == "changelog" then
					M.showChangelog()
				elseif value == "about" then
					M.showAbout()
				elseif value == "discord" then
					M.joinDiscord()
				elseif value == "unload" then
					overlay.confirm({
						title = "Unload UAI?",
						description = "Stops the current turn, drains every timer and input handler, "
							.. "saves your settings and removes the interface. Run the loader again to come back.",
						confirmText = "Unload",
						danger = true,
						onConfirm = function()
							local globals = (type(getgenv) == "function") and getgenv() or nil
							local live = globals and globals.UAI
							if live and live.destroy then
								live.destroy()
							else
								dispose.drain()
								pcall(function() M.screen:Destroy() end)
							end
						end,
					})
				end
			end,
		})
		-- A slightly quieter card lets the standard hover surface remain visible.
		if menu then menu.card.BackgroundColor3 = theme.color.surfaceRaised end
		return menu
	end

	-- What this build actually is. Read rather than written: the version, the identity
	-- that goes on the wire, what the host can do, and where it is running.
	function M.showAbout()
		local ua = env.require("net/ua")
		local registry = env.require("agent/registry")
		local modal = overlay.modal({
			title = "UAI " .. tostring(env.info and env.info.version or ""),
			description = "An agent running inside a Roblox client, identifying itself on the wire "
				.. "as the Claude Code CLI.",
			width = theme.size.modalWide,
		})
		if not modal then return nil end
		local rows = {
			{ key = "Identity", value = ua.userAgent() },
			{ key = "Transport", value = caps.http .. (caps.requestName and (" (" .. caps.requestName .. ")") or "") },
			{ key = "Capabilities", value = caps.summary() },
			{ key = "Tools", value = util.pluralise(registry.stats().total, "tool") },
			{ key = "Viewport", value = responsive.describe() },
			{ key = "Place", value = place.describe() },
		}
		env.require("ui/settingsrows").facts(modal.content, rows, { name = "AboutFacts", layoutOrder = 1 })
		if caps.clipboard then
			P.button(modal.footer, {
				text = "Copy",
				variant = "ghost",
				size = "sm",
				layoutOrder = 1,
				onClick = function()
					local lines = {}
					for _, row in ipairs(rows) do lines[#lines + 1] = row.key .. ": " .. row.value end
					pcall(caps.fn.clipboard, table.concat(lines, "\n"))
					overlay.toast("Copied", "good", 2)
				end,
			})
		end
		-- The other half of this modal's job: what this version changed, one tap
		-- away. Closes About first so two modals never stack on the same scrim.
		P.button(modal.footer, {
				text = "Discord",
				variant = "secondary",
				size = "sm",
				layoutOrder = 2,
				onClick = function() M.joinDiscord() end,
			})
		P.button(modal.footer, {
				text = "What's new",
				variant = "secondary",
				size = "sm",
				layoutOrder = 3,
				onClick = function()
					modal.close()
					M.showChangelog()
				end,
			})
		P.button(modal.footer, {
			text = "Close",
			variant = "primary",
			size = "sm",
			layoutOrder = 4,
			onClick = function() modal.close() end,
			})
		return modal
	end

	-- The release notes. Reachable from the app menu and from About, and marked
	-- read the moment it opens -- the marker on the menu row is what brought
	-- the reader here, and leaving it after the fact would be a stale flag.
	function M.showChangelog()
		return env.require("ui/changelog").show()
	end

	-- Search across every conversation: titles first, then what was said in them. The
	-- results are rows that open the conversation, which is the only thing a search
	-- result can usefully be.
	function M.showSearch()
		local modal = overlay.modal({
			title = "Search conversations",
			description = "Matches a title, a message or a reply. " ..
				util.pluralise(#sessions.list(), "conversation") .. " on this client.",
			width = theme.size.dialog,
		})
		if not modal then return nil end
		local results = P.column(modal.content, {
			name = "SearchResults",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			layoutOrder = 2,
		})

		local function render(query)
			for _, child in ipairs(results:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			local clean = util.trim(query)
			if clean == "" then
				local hint = P.text(results, {
					name = "SearchHint",
					text = "Type to search.",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					layoutOrder = 1,
				})
				hint.Size = UDim2.new(1, 0, 0, 0)
				return
			end
			local matches = sessions.search(clean)
			if #matches == 0 then
				local none = P.text(results, {
					name = "SearchEmpty",
					text = "Nothing matched " .. clean .. ".",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					layoutOrder = 1,
				})
				none.Size = UDim2.new(1, 0, 0, 0)
				return
			end
			for index, match in ipairs(matches) do
				if index > 12 then break end
				local row = P.rowButton(results, {
					name = "Result_" .. tostring(index),
					vertical = true,
					height = theme.size.bar,
					size = UDim2.new(1, 0, 0, theme.size.bar),
					padding = { x = theme.space.sm },
					alignY = "Center",
					gap = 0,
					layoutOrder = index,
					onClick = function()
						modal.close()
						M.openSession(match.session.id)
					end,
				})
				P.text(row.row, {
					text = match.session.title,
					role = "small",
					color = theme.color.text,
					truncate = true,
					size = UDim2.new(1, 0, 0, theme.text.small.height),
					layoutOrder = 1,
				})
				P.text(row.row, {
					text = string.format("%s  \194\183  %s%s", match.session.placeName or "",
						match.where, match.snippet and ("  \194\183  " .. match.snippet) or ""),
					role = "caption",
					color = theme.color.textTertiary,
					truncate = true,
					size = UDim2.new(1, 0, 0, theme.text.caption.height),
					layoutOrder = 2,
				})
			end
			if #matches > 12 then
				local more = P.text(results, {
					name = "SearchMore",
					text = string.format("%d more not shown.", #matches - 12),
					role = "caption",
					color = theme.color.textTertiary,
					auto = "Y",
					layoutOrder = 100,
				})
				more.Size = UDim2.new(1, 0, 0, 0)
			end
		end

		local field = P.field(modal.content, {
			name = "SearchField",
			placeholder = "Search",
			layoutOrder = 1,
			onChange = function(text) render(text) end,
			onSubmit = function(text) render(text) end,
		})
		render("")
		clock.delay(theme.motion.fast, function() field.focus() end)

		P.button(modal.footer, {
			text = "Close",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			onClick = function() modal.close() end,
		})
		return modal
	end

	-- Session wiring ---------------------------------------------------------

	function M.attachSession()
		local session = sessions.current()
		if M.chatPanel and M.chatPanel.composer then M.chatPanel.composer.attach(session) end
		if M.chatPanel and M.chatPanel.view then M.chatPanel.view.attach(session) end
		-- The plan the strip shows belongs to this conversation, so it moves with it.
		if M.chatPanel and M.chatPanel.todos then M.chatPanel.todos.attach(session) end
		if M.window and M.window.visible and M.panel == "chat" then M.readNotifications(session.id) end
		-- Starts the client-wide prompt watch. It is not per-session any more: a
		-- conversation left running in the background still has to be able to ask.
		env.require("ui/panels/permission").watch()
		env.require("ui/panels/ask").watch()

		if M.sessionUnsubscribe then M.sessionUnsubscribe() end
		M.sessionUnsubscribe = session.events:connect(function(event)
			local panel = M.chatPanel
			if event.kind == "status" then
				-- "Ready" is the loop's own idle text and it is emitted from inside the
				-- turn, one line after turn:end and before session.send clears the flag.
				-- Reading session.busy here would therefore re-arm the composer a moment
				-- after turn:end had just disarmed it, which is what left the send button
				-- showing Stop for the rest of the conversation.
				local ready = event.text == "Ready"
				if panel and panel.composer then
					if ready then
						panel.composer.setUsage(usage.line())
					else
						panel.composer.setStatus(event.text)
					end
					panel.composer.setBusy(not ready and session.busy)
				end
				M.syncNav()
			elseif event.kind == "turn:end" or event.kind == "error" or event.kind == "abort" then
				if panel and panel.composer then
					panel.composer.setBusy(false)
					panel.composer.setUsage(usage.line())
				end
				M.syncNav()
				M.setLauncherBusy(not M.window.visible and sessions.busyCount() > 0)
			elseif event.kind == "usage" then
				if panel and panel.composer and not session.busy then
					panel.composer.setUsage(usage.line())
				end
				if panel and panel.composer then panel.composer.syncContext() end
			elseif event.kind == "user" then
				-- The first message names the conversation, and the sidebar is what shows
				-- that name.
				M.syncNav()
			end
		end)

		if M.chatPanel and M.chatPanel.composer then
			M.chatPanel.composer.setBusy(session.busy)
			M.chatPanel.composer.setUsage(usage.line())
			M.chatPanel.composer.syncContext()
		end
		M.syncNav()
	end

	-- Rebuild ----------------------------------------------------------------

	-- Throws the tree away and builds it again for the current mode and tokens.
	-- Cheap enough to be the answer to every discrete change, and it means no
	-- component has to know how to re-theme itself in place.
	function M.rebuild(reason)
		if not M.screen then return end
		local wasVisible = M.window and M.window.visible
		local panel = M.panel

		if M.sessionUnsubscribe then
			M.sessionUnsubscribe()
			M.sessionUnsubscribe = nil
		end
		for _, existing in pairs(M.panels or {}) do
			if existing.destroy then pcall(existing.destroy) end
		end
		M.panels = {}
		M.chatPanel = nil
		M.sidebar = nil
		M.titleLabel = nil
		M.subtitleLabel = nil
		if M.window then M.window.destroy() end
		if M.launcher then
			M.launcher:Destroy()
			M.launcher = nil
		end

		M.panel = panel
		M.buildLauncher()
		M.buildWindow()
		if wasVisible then M.window.show() end
		M.setLauncherBusy(not wasVisible and sessions.busyCount() > 0)
		log.debug("app", "rebuilt for " .. tostring(reason) .. " as " .. responsive.mode)
	end

	return M
end
