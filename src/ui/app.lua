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
		{ id = "agents", label = "Subagents", icon = "spark" },
		{ id = "providers", label = "Providers", icon = "sliders" },
		{ id = "tools", label = "Tools", icon = "worktree" },
		{ id = "settings", label = "Settings", icon = "gear" },
		{ id = "logs", label = "Logs", icon = "document" },
	}

	local M = { panel = "chat", built = false, history = { entries = {}, index = 0 } }

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
		-- busy transition, which is what makes this cheap. Turning the dot off is
		-- `show`'s job, so a turn that finished while the window was closed still says so.
		dispose.add(sessions.listChanged:connect(function()
			if not M.window then return end
			if sessions.busyCount() > 0 and not M.window.visible then
				M.setLauncherBusy(true)
			end
			M.syncNav()
		end), "app.busyPulse")

		-- The prompt watch is client-wide and starts with the interface, so a
		-- conversation that asks for permission before anything has been opened is still
		-- answered.
		env.require("ui/panels/permission").watch()

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
		button.AnchorPoint = Vector2.new(1, 1)
		button.ZIndex = theme.z.header
		button.Selectable = true
		-- A rounded tile rather than a circle, with the mark in it: the same shape an
		-- application icon is, which reads as a thing you open rather than as a bubble
		-- someone left on the screen.
		P.corner(button, theme.radius.lg)
		local outline = P.stroke(button, theme.color.border)

		if config.get("ui.launcher.placed", false) then
			button.Position = UDim2.new(0, config.get("ui.launcher.x", 0), 0, config.get("ui.launcher.y", 0))
			button.AnchorPoint = Vector2.new(0, 0)
		else
			button.Position = UDim2.new(1, -theme.space.lg, 1, -(theme.space.lg + responsive.bottomInset))
		end

		icons.spark(button, theme.size.iconLarge, theme.color.accent)

		local pulse = P.statusDot(button, {
			diameter = theme.size.dot,
			color = theme.color.accent,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, theme.space.hair, 0, -theme.space.hair),
		})
		pulse.Visible = false

		-- The orb both drags and clicks, and Roblox fires Activated on release even
		-- after a drag, so a moved orb must not also open the window.
		local dragging, moved, origin, startPosition = false, false, nil, nil
		button.InputBegan:Connect(function(input)
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
			dragging, moved = true, false
			origin = input.Position
			startPosition = button.AbsolutePosition
			local connection
			connection = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if connection then connection:Disconnect() end
					if moved then
						config.set("ui.launcher.x", math.floor(button.Position.X.Offset), { quiet = true })
						config.set("ui.launcher.y", math.floor(button.Position.Y.Offset), { quiet = true })
						config.set("ui.launcher.placed", true, { quiet = true })
					end
				end
			end)
		end)

		dispose.connection(env.uis.InputChanged:Connect(function(input)
			if not dragging then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			local delta = input.Position - origin
			if math.abs(delta.X) > DRAG_SLOP or math.abs(delta.Y) > DRAG_SLOP then moved = true end
			local viewport = responsive.viewport
			button.AnchorPoint = Vector2.new(0, 0)
			button.Position = UDim2.fromOffset(
				math.floor(util.clamp(startPosition.X + delta.X, 0, viewport.X - diameter)),
				math.floor(util.clamp(startPosition.Y + delta.Y, responsive.inset.Y, viewport.Y - diameter)))
		end))

		button.MouseEnter:Connect(function()
			env.tween:Create(outline, theme.tween("hover"), { Color = theme.color.accentBorder }):Play()
		end)
		button.MouseLeave:Connect(function()
			env.tween:Create(outline, theme.tween("hover"), { Color = theme.color.border }):Play()
		end)
		button.Activated:Connect(function()
			if moved then
				moved = false
				return
			end
			M.toggle()
		end)

		M.launcher = button
		M.launcherPulse = pulse
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
			minWidth = 340,
			minHeight = 300,
		})
		M.buildChrome()
		M.buildBody()
		M.window.onLayout = function()
			M.syncNav()
		end
	end

	-- Config is the only source of truth for this.
	--
	-- It used to be a field on the module seeded once inside mount, which mount returns
	-- early from on re-entry -- so the field and `ui.sidebarCollapsed` could diverge and
	-- never reconcile, and the switch in the appearance pane wrote a value nothing read.
	function M.sidebarVisible()
		return (responsive.mode == "window") and (config.get("ui.sidebarCollapsed", false) ~= true)
	end

	-- The header reads left to right as what you are looking at, then the window
	-- controls. Navigation itself lives in the sidebar, which is where the interface
	-- this follows puts it -- and when there is no sidebar, the hamburger on the left
	-- is the whole of it. That branch used to be "sheet or narrower than 500", which
	-- left a tablet in portrait and a console with no way to change panel at all.
	function M.buildChrome()
		local header = M.window.header
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
			if responsive.mode == "window" then
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
		local titleColumn = P.column(left, {
			name = "Title",
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			gap = theme.space.hair,
			alignY = "Center",
			layoutOrder = 3,
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

		local right = P.row(header, {
			name = "Right",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.xxs,
			layoutOrder = 3,
		})

		if responsive.mode == "window" then
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
		local column = P.column(parent, {
			name = "Chat",
			size = UDim2.fromScale(1, 1),
			gap = 0,
		})

		panel.todos = env.require("ui/chat/todo").new(column, {
			layoutOrder = 1,
			session = sessions.current(),
		})

		local middle = P.frame(column, {
			name = "TranscriptHolder",
			size = UDim2.new(1, 0, 1, 0),
			layoutOrder = 2,
		})
		local flex = Instance.new("UIFlexItem", middle)
		flex.FlexMode = Enum.UIFlexMode.Fill

		panel.view = env.require("ui/chat/view").new(middle, {})

		panel.composer = env.require("ui/chat/composer").new(column, {
			layoutOrder = 3,
			onSend = function(text)
				local session = sessions.current()
				local ok, reason = session.send(text)
				if not ok then overlay.toast(tostring(reason), "warn", 2) end
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
		panel.composer.shell.LayoutOrder = 3

		function panel.destroy()
			if panel.view then panel.view.destroy() end
			if panel.todos then panel.todos.destroy() end
		end

		return panel
	end

	local BUILDERS = {
		chat = buildChatPanel,
		cowork = function(parent) return env.require("ui/panels/cowork").new(parent) end,
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
		M.showPanel("chat")
		if M.window then M.window.show() end
		if M.chatPanel and M.chatPanel.composer then M.chatPanel.composer.focus() end
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

		-- With no sidebar there is nowhere else the conversation list can be, and a
		-- phone is exactly where someone is most likely to be picking up an older one.
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
				}
			end
		end

		overlay.menu({
			target = target,
			width = theme.size.menuWide,
			options = options,
			onSelect = function(value)
				if value == "new" then
					M.openSession(sessions.newThread().id)
				elseif value == "search" then
					M.showSearch()
				elseif util.startsWith(tostring(value), "session:") then
					M.openSession(tostring(value):sub(9))
				else
					M.show(value)
				end
			end,
		})
	end

	function M.showProfileMenu(target)
		local name = "you"
		local okName, display = pcall(function() return env.plr and env.plr.DisplayName end)
		if okName and type(display) == "string" and util.trim(display) ~= "" then
			name = display
		elseif env.plr and type(env.plr.Name) == "string" and env.plr.Name ~= "" then
			name = env.plr.Name
		end
		local record = providers.active()
		overlay.menu({
			target = target,
			width = theme.size.menuWide,
			options = {
				{ isHeader = true, title = name, subtitle = record and record.label or "no provider" },
				{ label = "Settings", value = "settings", icon = "gear", shortcut = "Ctrl ," },
				{ label = "Inference configuration", value = "providers", icon = "sliders" },
				{ divider = true },
				{ label = "About this build", value = "about", icon = "book" },
				{ divider = true },
				{ label = "Unload UAI", value = "unload", icon = "signOut", tone = "bad" },
			},
			onSelect = function(value)
				if value == "settings" then
					M.showSettingsDialog("general")
				elseif value == "providers" then
					M.show("providers")
				elseif value == "about" then
					M.showAbout()
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
	end

	-- What this build actually is. Read rather than written: the version, the identity
	-- that goes on the wire, what the host can do, and where it is running. There is no
	-- changelog to show -- the client does not ship one -- and inventing release notes
	-- would be worse than not having them.
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
		P.button(modal.footer, {
			text = "Close",
			variant = "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function() modal.close() end,
		})
		return modal
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
		if M.chatPanel and M.chatPanel.view then M.chatPanel.view.attach(session) end
		-- The plan the strip shows belongs to this conversation, so it moves with it.
		if M.chatPanel and M.chatPanel.todos then M.chatPanel.todos.attach(session) end
		-- Starts the client-wide prompt watch. It is not per-session any more: a
		-- conversation left running in the background still has to be able to ask.
		env.require("ui/panels/permission").watch()

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
				-- A finished turn while the window is closed is worth a hint.
				if not M.window.visible then
					M.setLauncherBusy(true)
				end
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
		log.debug("app", "rebuilt for " .. tostring(reason) .. " as " .. responsive.mode)
	end

	return M
end
