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
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local windowModule = env.require("ui/window")
	local sessions = env.require("agent/session")
	local providers = env.require("provider/registry")
	local models = env.require("provider/models")
	local usage = env.require("agent/usage")

	local PANELS = {
		{ id = "chat", label = "Chat" },
		{ id = "providers", label = "Providers" },
		{ id = "tools", label = "Tools" },
		{ id = "settings", label = "Settings" },
		{ id = "logs", label = "Logs" },
	}

	local M = { panel = "chat", built = false }

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

		M.buildLauncher()
		M.buildWindow()

		-- A real layout switch rebuilds; a resize does not. Debounced inside
		-- responsive, so a desktop drag does not thrash.
		responsive.modeChanged:connect(function()
			M.rebuild("mode")
		end)

		-- Theme changes (accent, density, text scale) also need a rebuild: colours
		-- and metrics are read at build time by design, which keeps every component
		-- free of subscription bookkeeping.
		theme.changed:connect(clock.debounce(function()
			M.rebuild("theme")
		end, 0.2))

		log.info("app", "interface mounted in " .. tostring(container.Name) .. " as " .. responsive.mode)
		return M
	end

	-- Launcher ---------------------------------------------------------------

	function M.buildLauncher()
		if M.launcher and M.launcher.Parent then return end
		local diameter = math.max(theme.size.launcher, responsive.minTarget())

		local button = Instance.new("TextButton", M.screen)
		button.Name = "Launcher"
		button.Text = ""
		button.AutoButtonColor = false
		button.BackgroundColor3 = theme.color.surfaceOverlay
		button.BorderSizePixel = 0
		button.Size = UDim2.fromOffset(diameter, diameter)
		button.AnchorPoint = Vector2.new(1, 1)
		button.ZIndex = theme.z.header
		button.Selectable = true
		P.corner(button, theme.radius.pill)
		local outline = P.stroke(button, theme.color.border)

		if config.get("ui.launcher.placed", false) then
			button.Position = UDim2.new(0, config.get("ui.launcher.x", 0), 0, config.get("ui.launcher.y", 0))
			button.AnchorPoint = Vector2.new(0, 0)
		else
			button.Position = UDim2.new(1, -theme.space.lg, 1, -(theme.space.lg + responsive.bottomInset))
		end

		P.text(button, {
			text = "UAI",
			role = "label",
			color = theme.color.accent,
			align = "Center",
			size = UDim2.fromScale(1, 1),
		})

		local pulse = P.statusDot(button, {
			diameter = 8,
			color = theme.color.accent,
			anchor = Vector2.new(1, 0),
			position = UDim2.new(1, 2, 0, -2),
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

		env.uis.InputChanged:Connect(function(input)
			if not dragging then return end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseMovement and kind ~= Enum.UserInputType.Touch then return end
			local delta = input.Position - origin
			if math.abs(delta.X) > 6 or math.abs(delta.Y) > 6 then moved = true end
			local viewport = responsive.viewport
			button.AnchorPoint = Vector2.new(0, 0)
			button.Position = UDim2.fromOffset(
				math.floor(util.clamp(startPosition.X + delta.X, 0, viewport.X - diameter)),
				math.floor(util.clamp(startPosition.Y + delta.Y, responsive.inset.Y, viewport.Y - diameter)))
		end)

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

	function M.buildChrome()
		local header = M.window.header
		local compact = responsive.viewport.X < 640 or responsive.mode == "sheet"

		local left = P.row(header, {
			name = "Left",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.sm,
			layoutOrder = 1,
		})

		P.text(left, {
			text = "UAI",
			role = "title",
			color = theme.color.text,
			layoutOrder = 1,
		}).Size = UDim2.fromOffset(40, theme.text.title.size + 4)

		-- The provider chip is the one piece of status worth permanent space: which
		-- endpoint and model a message is about to go to.
		local chip = Instance.new("TextButton", left)
		chip.Text = ""
		chip.AutoButtonColor = false
		chip.BackgroundColor3 = theme.color.surfaceOverlay
		chip.BorderSizePixel = 0
		chip.Size = UDim2.new(0, 0, 0, theme.size.controlSmall)
		chip.AutomaticSize = Enum.AutomaticSize.X
		chip.LayoutOrder = 2
		chip.Selectable = true
		P.corner(chip, theme.radius.pill)
		P.stroke(chip, theme.color.borderSubtle)

		local chipRow = P.row(chip, {
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.xxs,
			padding = { x = theme.space.sm },
		})
		local chipDot = P.statusDot(chipRow, { diameter = 6, layoutOrder = 1 })
		local chipLabel = P.text(chipRow, {
			text = "no provider",
			role = "caption",
			color = theme.color.textSecondary,
			layoutOrder = 2,
		})
		chipLabel.Size = UDim2.fromOffset(0, theme.text.caption.size + 4)
		chipLabel.AutomaticSize = Enum.AutomaticSize.X

		chip.Activated:Connect(function() M.providerMenu(chip) end)
		M.chip = { button = chip, dot = chipDot, label = chipLabel }

		P.spacer(header, { grow = true, size = UDim2.new(0, 0, 1, 0) }).LayoutOrder = 2

		local right = P.row(header, {
			name = "Right",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.xxs,
			layoutOrder = 3,
		})

		if compact then
			local menuButton = P.iconButton(right, {
				name = "Nav",
				icon = "bars",
				diameter = theme.size.control,
				layoutOrder = 1,
			})
			menuButton.instance.LayoutOrder = 1
			menuButton.instance.Activated:Connect(function()
				local options = {}
				for _, entry in ipairs(PANELS) do
					options[#options + 1] = {
						label = entry.label,
						value = entry.id,
						selected = entry.id == M.panel,
					}
				end
				overlay.menu({
					target = menuButton.instance,
					width = 200,
					options = options,
					onSelect = function(value) M.show(value) end,
				})
			end)
		else
			M.nav = C.segmented(right, {
				name = "Nav",
				-- An explicit width, passed in rather than assigned afterwards: `right`
				-- sizes itself to its contents, and a scale-width child contributes
				-- nothing to that, so the nav would collapse to zero without it. Doing
				-- it here means the control also keeps the hit-target height it works
				-- out for the platform.
				width = 360,
				options = PANELS and (function()
					local options = {}
					for _, entry in ipairs(PANELS) do
						options[#options + 1] = { value = entry.id, label = entry.label }
					end
					return options
				end)() or {},
				value = M.panel,
				onChange = function(value) M.show(value) end,
			})
			M.nav.instance.LayoutOrder = 1
		end

		if responsive.mode == "window" then
			local maximise = P.iconButton(right, {
				name = "Maximise",
				icon = M.window.maximised and "minus" or "plus",
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

	-- Content stops widening past this; the window itself does not. Past roughly this
	-- width a transcript line or a log row becomes a single sentence a foot long,
	-- which is unreadable however correct the layout is, and a maximised window at
	-- 1920 is mostly that. The chrome still spans the full width -- it is the reading
	-- column that is measured, and the leftover becomes margin.
	local MAX_CONTENT = 1320

	function M.buildBody()
		M.body = P.frame(M.window.body, {
			name = "Panels",
			size = UDim2.fromScale(1, 1),
			maxSize = Vector2.new(MAX_CONTENT, math.huge),
			anchor = Vector2.new(0.5, 0),
			position = UDim2.fromScale(0.5, 0),
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

		panel.todos = env.require("ui/chat/todo").new(column, { layoutOrder = 1 })

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
		providers = function(parent) return env.require("ui/panels/providers").new(parent) end,
		tools = function(parent) return env.require("ui/panels/tools").new(parent) end,
		settings = function(parent) return env.require("ui/panels/settings").new(parent) end,
		logs = function(parent) return env.require("ui/panels/logs").new(parent) end,
	}

	function M.showPanel(id)
		if not M.body then return end
		for key, panel in pairs(M.panels or {}) do
			if panel.root then panel.root.Visible = key == id end
		end
		if not M.panels[id] then
			local holder = P.frame(M.body, {
				name = "Panel_" .. id,
				size = UDim2.fromScale(1, 1),
			})
			local ok, panel = pcall(BUILDERS[id] or BUILDERS.chat, holder)
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
		M.syncNav()
	end

	function M.show(id)
		if not M.screen then M.mount() end
		M.showPanel(id or M.panel)
		M.window.show()
		if M.launcherPulse then M.launcherPulse.Visible = false end
	end

	function M.hide()
		if M.window then M.window.hide() end
	end

	function M.toggle()
		if M.window and M.window.visible then M.hide() else M.show() end
	end

	function M.syncNav()
		if M.nav and M.nav.set then M.nav.set(M.panel) end
		M.syncChip()
	end

	function M.syncChip()
		if not M.chip then return end
		local record = providers.active()
		if not record then
			M.chip.label.Text = "no provider"
			M.chip.dot.BackgroundColor3 = theme.color.danger
			return
		end
		local session = sessions.current()
		M.chip.label.Text = string.format("%s  %s", record.label,
			record.model ~= "" and record.model or "no model")
		M.chip.dot.BackgroundColor3 = session.busy and theme.color.accent
			or (providers.cooling(record) and theme.color.warn or theme.color.success)
	end

	-- Picks a provider, or a model within the active one. Both live behind the same
	-- chip because they are the same decision from the user's point of view. Models
	-- listed here are the ones the endpoint reported plus the ones the user added --
	-- never a guess, so the menu can legitimately be empty until one of those has
	-- happened.
	function M.providerMenu(target)
		local options = {}
		local record = providers.active()
		for _, entry in ipairs(providers.list()) do
			options[#options + 1] = {
				label = entry.label,
				value = "provider:" .. entry.id,
				detail = entry.model ~= "" and entry.model or entry.baseUrl,
				selected = record and record.id == entry.id,
			}
		end
		if record then
			local known = models.list(record)
			for _, id in ipairs(known) do
				options[#options + 1] = {
					label = id,
					value = "model:" .. id,
					detail = "model on " .. record.label,
					selected = id == record.model,
				}
			end
			options[#options + 1] = {
				label = "Fetch models from /models",
				value = "fetch",
				detail = record.baseUrl .. "/models",
				tone = "info",
			}
			options[#options + 1] = { label = "Add a model by id", value = "addmodel", tone = "info" }
		end
		options[#options + 1] = { label = "Manage providers", value = "manage", tone = "info" }

		overlay.menu({
			target = target,
			width = 320,
			options = options,
			onSelect = function(value)
				if value == "manage" then
					M.show("providers")
				elseif value == "fetch" and record then
					overlay.toast("Fetching models from " .. record.label, "info", 2)
					task.spawn(function()
						local found, note = models.discover(record, { force = true })
						overlay.toast(tostring(note), #found > 0 and "good" or "warn")
						if #found > 0 then M.providerMenu(target) end
					end)
				elseif value == "addmodel" and record then
					overlay.prompt({
						title = "Add a model to " .. record.label,
						description = "Type the id exactly as the provider expects it. It is saved to this provider and selected.",
						placeholder = "model id",
						onConfirm = function(text)
							local ok, result = models.add(record, text)
							if ok then
								overlay.toast("Using " .. tostring(result), "good")
								M.syncChip()
							else
								overlay.toast(tostring(result), "warn")
							end
						end,
					})
				elseif util.startsWith(value, "provider:") then
					providers.setActive(value:sub(10))
					M.syncChip()
				elseif util.startsWith(value, "model:") and record then
					providers.setModel(record.id, value:sub(7))
					M.syncChip()
				end
			end,
		})
	end

	-- Session wiring ---------------------------------------------------------

	function M.attachSession()
		local session = sessions.current()
		if M.chatPanel and M.chatPanel.view then M.chatPanel.view.attach(session) end
		env.require("ui/panels/permission").attach(session)

		if M.sessionUnsubscribe then M.sessionUnsubscribe() end
		M.sessionUnsubscribe = session.events:connect(function(event)
			local panel = M.chatPanel
			if event.kind == "status" then
				if panel and panel.composer then
					panel.composer.setStatus(event.text ~= "Ready" and event.text or usage.line())
					panel.composer.setBusy(session.busy)
				end
				M.syncChip()
			elseif event.kind == "turn:end" or event.kind == "error" or event.kind == "abort" then
				if panel and panel.composer then
					panel.composer.setBusy(false)
					panel.composer.setStatus(usage.line())
				end
				M.syncChip()
				-- A finished turn while the window is closed is worth a hint.
				if not M.window.visible and M.launcherPulse then
					M.launcherPulse.Visible = true
				end
			elseif event.kind == "usage" then
				if panel and panel.composer and not session.busy then
					panel.composer.setStatus(usage.line())
				end
			end
		end)

		if M.chatPanel and M.chatPanel.composer then
			M.chatPanel.composer.setBusy(session.busy)
			M.chatPanel.composer.setStatus(usage.line())
		end
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
		M.nav = nil
		M.chip = nil
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
