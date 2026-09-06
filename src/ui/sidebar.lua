-- The sidebar: navigation, the mode switch, and the real conversation list.
--
-- Everything in here reads from `agent/session`. The list used to be three hardcoded
-- project names with eleven invented titles under them, copied from a screenshot --
-- which looked exactly right and told you nothing, and whose rows typed their own
-- label into the composer instead of opening anything. What is here now is the
-- threads the client actually has, grouped by the place they happened in, and
-- clicking one switches to it.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local sessions = env.require("agent/session")
	local subagent = env.require("agent/subagent")
	local providers = env.require("provider/registry")
	local place = env.require("runtime/place")

	local M = {}

	-- The panels the "More" row reveals. Chat is not in it: the mode switch above is
	-- what selects between the conversation and the shared session.
	local MORE_PANELS = {
		{ id = "agents", label = "Subagents", icon = "spark" },
		{ id = "providers", label = "Providers", icon = "sliders" },
		{ id = "tools", label = "Tools", icon = "worktree" },
		{ id = "logs", label = "Logs & traces", icon = "document" },
		{ id = "settings", label = "Settings", icon = "gear" },
	}

	function M.new(parent, host)
		local handle = {}

		-- One inset and one icon size for every row in here.
		--
		-- There were six of each. Row padding ran xxs, xs and md depending on which row
		-- it was, and the icon slot -- whose width is what decides where the label starts
		-- -- was written three different ways as `icon`, `icon - hair` and `icon - xxs`.
		-- The result was six different left text edges down one 240px column, two of them
		-- two pixels apart on adjacent rows. Both are also dimensionally wrong to
		-- subtract from each other: `space` scales by 0.78 under compact density and
		-- `size` by 0.86, so the gaps drifted rather than holding.
		local ROW_INSET = theme.space.xs
		local ROW_ICON = theme.size.icon

		local sidebar = P.column(parent, {
			name = "Sidebar",
			size = UDim2.fromScale(1, 1),
			-- One step of air between groups rather than the same six pixels used inside
			-- them: the nav strip, the mode switch, the new-conversation button, the action
			-- rows and the history are five separate things, and at a uniform xs they read
			-- as one undifferentiated stack.
			gap = theme.space.md,
			padding = { x = theme.space.sm, y = theme.space.sm },
		})

		-- Top row: the app menu, the collapse toggle, search, and the two history
		-- arrows. Every one of them does something; the pair that used to announce
		-- "Navigated to previous session" in a toast now actually goes there.
		--
		-- It wraps because on a touch device every one of these is forced to 44px by the
		-- hit-target floor, and five of those plus their gaps are wider than the sidebar.
		local topNav = P.row(sidebar, {
			name = "TopNav",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			wrap = true,
			gap = theme.space.xxs,
			layoutOrder = 1,
		})

		local function navButton(name, icon, order, onClick, enabled)
			local button = P.iconButton(topNav, {
				name = name,
				icon = icon,
				diameter = theme.size.controlSmall,
				layoutOrder = order,
				onClick = onClick,
			})
			button.instance.LayoutOrder = order
			if enabled == false then button.setEnabled(false) end
			return button
		end

		navButton("Nav_menu", "bars", 1, function()
			host.showAppMenu(topNav)
		end)
		navButton("Nav_sidebar", "sidebarToggle", 2, function()
			host.toggleSidebar()
		end)
		navButton("Nav_search", "search", 3, function()
			host.showSearch()
		end)
		handle.back = navButton("Nav_back", "arrowLeft", 4, function()
			host.back()
		end, host.canBack())
		handle.forward = navButton("Nav_forward", "arrowRight", 5, function()
			host.forward()
		end, host.canForward())

		-- Mode switch. "Cowork" is the browser-shared session -- the local bridge, which
		-- is the one thing in this client that is genuinely two people in one
		-- conversation -- and "Code" is the conversation itself. Both are real surfaces,
		-- so this selects a panel rather than setting a flag nothing reads.
		local modeRow = P.row(sidebar, {
			name = "ModeSwitcher",
			size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget())),
			bg = theme.color.surface,
			radius = theme.radius.pill,
			padding = theme.space.hair,
			gap = theme.space.hair,
			layoutOrder = 2,
			stretch = true,
		})

		local modes = {}
		local function modeButton(id, label, icon, order)
			local selected = host.panel == id
			local button = P.rowButton(modeRow, {
				name = "Segment_" .. id,
				size = UDim2.new(0.5, -theme.space.hair, 1, 0),
				height = theme.size.controlSmall,
				radius = theme.radius.pill,
				bg = selected and theme.color.surfaceActive or nil,
				selected = selected,
				alignX = "Center",
				gap = theme.space.xxs,
				padding = theme.space.none,
				onClick = function()
					host.show(id)
				end,
			})
			button.icon(icon, 1, selected and theme.color.text or theme.color.textTertiary,
				theme.size.icon - theme.space.xxs)
			local label2 = P.text(button.row, {
				text = label,
				role = "caption",
				color = selected and theme.color.text or theme.color.textTertiary,
				auto = "X",
				layoutOrder = 2,
			})
			modes[id] = { button = button, label = label2 }
			return button
		end
		modeButton("cowork", "Cowork", "terminal", 1)
		modeButton("chat", "Code", "code", 2)

		-- New conversation. A real thread rather than a wipe of the current one: the
		-- list below is what makes the difference visible, and clearing in place is what
		-- the composer's own clear control is for.
		local newButton = P.button(sidebar, {
			name = "NewChat",
			text = "+ New",
			variant = "secondary",
			size = "sm",
			fill = true,
			layoutOrder = 3,
			onClick = function()
				host.openSession(sessions.newThread().id)
			end,
		})
		newButton.instance.LayoutOrder = 3

		local actions = P.column(sidebar, {
			name = "ActionRows",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			layoutOrder = 4,
		})

		local customize = P.rowButton(actions, {
			name = "Customize",
			bg = nil,
			padding = { x = ROW_INSET },
			layoutOrder = 1,
			onClick = function()
				host.showSettingsDialog("claude_code")
			end,
		})
		customize.icon("sliders", 1, theme.color.textSecondary, ROW_ICON)
		customize.label("Customize", 2, theme.color.textSecondary)

		local expanded = config.get("ui.sidebarExpanded", false) == true
		local more = P.rowButton(actions, {
			name = "More",
			padding = { x = ROW_INSET },
			layoutOrder = 2,
			onClick = function()
				expanded = not expanded
				config.set("ui.sidebarExpanded", expanded, { quiet = true })
				handle.renderMore()
			end,
		})
		local moreIcon = more.icon("chevron", 1, theme.color.textSecondary, ROW_ICON)
		more.label("More", 2, theme.color.textSecondary)

		local moreList = P.column(actions, {
			name = "MorePanels",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			layoutOrder = 3,
		})

		function handle.renderMore()
			for _, child in ipairs(moreList:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			-- The chevron points at what pressing it will do.
			for _, child in ipairs(moreIcon:GetChildren()) do child:Destroy() end
			icons.chevron(moreIcon, ROW_ICON, theme.color.textSecondary,
				expanded and "up" or "down")
			if not expanded then return end
			for index, entry in ipairs(MORE_PANELS) do
				local selected = host.panel == entry.id
				local row = P.rowButton(moreList, {
					name = "NavRow_" .. entry.id,
					padding = { x = ROW_INSET },
					selected = selected,
					layoutOrder = index,
					onClick = function()
						host.show(entry.id)
					end,
				})
				row.icon(entry.icon, 1, selected and theme.color.text or theme.color.textTertiary, ROW_ICON)
				-- How many subagents are working, on the row that leads to them. A
				-- dispatch runs for minutes with nothing on screen once its card has
				-- scrolled away, so the count is the only standing sign of it.
				local label = entry.label
				if entry.id == "agents" then
					local running = #subagent.running()
					if running > 0 then label = label .. "  " .. tostring(running) end
				end
				row.label(label, 2, selected and theme.color.text or theme.color.textSecondary)
			end
		end

		handle.renderMore()

		-- The conversation list, which takes whatever height is left rather than a
		-- hand-summed remainder: the stack above it changes height with density, with
		-- the platform's hit-target floor and with whether More is open, and a fixed
		-- offset was wrong in all three directions at once.
		local historyHolder = P.frame(sidebar, {
			name = "HistoryHolder",
			size = UDim2.new(1, 0, 0, 0),
			layoutOrder = 5,
		})
		local historyFlex = Instance.new("UIFlexItem", historyHolder)
		historyFlex.FlexMode = Enum.UIFlexMode.Fill

		local history = P.scroll(historyHolder, {
			name = "HistoryScroll",
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
			padding = { y = theme.space.xxs },
		})

		-- Which place groups are folded, by placeId.
		--
		-- Stored rather than kept in a local: the list is rebuilt from scratch on every
		-- new thread, rename, delete, place change and busy transition, so a local would
		-- unfold everything several times a minute. Quiet writes, because this is a
		-- record of what the user folded and not a token anything derives from -- a noisy
		-- one would reach the theme's subscription and rebuild the whole interface.
		local function collapsedKey(placeId)
			return "ui.placeCollapsed." .. tostring(placeId)
		end

		local function isCollapsed(placeId)
			return config.get(collapsedKey(placeId), false) == true
		end

		local function setCollapsed(placeId, value)
			config.set(collapsedKey(placeId), value == true, { quiet = true })
		end

		local function sessionMenu(session, target)
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
						host.openSession(session.id)
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
								host.openSession(sessions.current().id)
							end,
						})
					end
				end,
			})
		end

		function handle.renderHistory()
			history.clear()
			local active = sessions.current()
			local groups = sessions.groups()
			local order = 0

			for _, group in ipairs(groups) do
				order = order + 1
				local column = P.column(history.instance, {
					name = "Place_" .. tostring(group.placeId),
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.hair,
					layoutOrder = order,
				})

				-- The group header is the fold control, so the whole line answers a click
				-- rather than a chevron nobody can hit. The count rides on it because a
				-- folded group has to say how much it is hiding -- otherwise folding one
				-- loses the only sign those conversations exist.
				local collapsed = isCollapsed(group.placeId)
				local head = P.rowButton(column, {
					name = "PlaceHead",
					height = theme.size.rowTight,
					-- The same inset as the rows it heads. It was xxs against their xs, so
					-- a group's name sat two pixels left of every conversation under it.
					padding = { x = ROW_INSET },
					gap = theme.space.xxs,
					layoutOrder = 1,
					onClick = function()
						setCollapsed(group.placeId, not isCollapsed(group.placeId))
						handle.renderHistory()
					end,
				})
				-- Points at what pressing it will do, like the More row above.
				local caret = P.frame(head.row, {
					name = "PlaceCaret",
					size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
					layoutOrder = 1,
				})
				icons.chevron(caret, theme.size.icon, theme.color.textTertiary,
					collapsed and "right" or "down")
				P.text(head.row, {
					name = "PlaceName",
					text = group.label,
					role = "overline",
					color = theme.color.textTertiary,
					size = UDim2.new(0, 0, 0, theme.text.overline.height),
					flex = "Fill",
					truncate = true,
					layoutOrder = 2,
				})
				-- How many are in there, and how many of those are working. The second
				-- number is the reason a fold is safe to leave shut: a group with a turn
				-- running in it still says so from the header.
				local busyCount = 0
				for _, session in ipairs(group.sessions) do
					if session.busy then busyCount = busyCount + 1 end
				end
				if busyCount > 0 then
					local slot = P.frame(head.row, {
						name = "PlaceBusy",
						size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
						layoutOrder = 3,
					})
					C.spinner(slot, {
						diameter = theme.size.icon,
						anchor = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
					})
				end
				local countLabel = P.text(head.row, {
					name = "PlaceCount",
					text = tostring(#group.sessions),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 4,
				})
				countLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)
				-- The place the client is in now is the only one a new conversation can
				-- be started in, so it is the only one that offers.
				if group.current then
					local plus = P.iconButton(head.row, {
						name = "NewInPlace",
						icon = "plus",
						diameter = theme.size.rowTight,
						layoutOrder = 5,
						onClick = function()
							host.openSession(sessions.newThread().id)
						end,
					})
					plus.instance.LayoutOrder = 5
				end

				-- The rows go in a holder of their own so folding hides one frame rather
				-- than each row: a hidden child still takes its slot in a list layout only
				-- if the layout can see it, and hiding thirty of them one at a time is
				-- thirty writes where one will do.
				local body = P.column(column, {
					name = "PlaceSessions",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.hair,
					layoutOrder = 2,
					visible = not collapsed,
				})

				for index, session in ipairs(group.sessions) do
					local selected = session.id == active.id
					local row = P.rowButton(body, {
						name = "SessionRow",
						height = theme.size.rowSmall,
						padding = { x = ROW_INSET },
						selected = selected,
						layoutOrder = index,
						onClick = function()
							host.openSession(session.id)
						end,
					})
					-- The leading slot is always there and usually empty.
					--
					-- It used to hold a hollow circle per row and a filled dot on the active
					-- one: a column of bullets down a 240px list whose only job was to say
					-- which row was selected, which the row's own highlight already says and
					-- says better. The slot itself stays, at the icon's width, because it is
					-- what puts every title on the same left edge as the group name above it
					-- -- and because a spinner has to be able to appear in a row without
					-- moving that row's text.
					--
					-- The spinner is the one thing here that survived: a conversation you are
					-- not looking at can still be working, leaving one does not stop it, and
					-- that is the one fact a row cannot state any other way. It is also the
					-- reason the list refreshes on every busy transition.
					local slot = P.frame(row.row, {
						name = "IconSlot",
						size = UDim2.fromOffset(ROW_ICON, ROW_ICON),
						layoutOrder = 1,
					})
					if session.busy then
						C.spinner(slot, {
							diameter = ROW_ICON,
							anchor = Vector2.new(0.5, 0.5),
							position = UDim2.fromScale(0.5, 0.5),
						})
					end
					local titleText = session.title
					if session.ephemeral then titleText = titleText .. "  (not saved)" end
					row.label(titleText, 2,
						selected and theme.color.text or theme.color.textSecondary,
						selected and "label" or nil)
					local menuButton = P.iconButton(row.row, {
						name = "SessionMenu",
						icon = "ellipsis",
						diameter = theme.size.rowTight,
						layoutOrder = 3,
						onClick = function(button)
							sessionMenu(session, button.instance)
						end,
					})
					menuButton.instance.LayoutOrder = 3
				end
			end

			if order == 0 then
				local empty = P.text(history.instance, {
					name = "NoHistory",
					text = "No conversations yet. Anything you send here is kept, grouped by the place it happened in.",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					padding = { x = ROW_INSET },
					layoutOrder = 1,
				})
				empty.Size = UDim2.new(1, 0, 0, 0)
			end
		end

		handle.renderHistory()

		P.divider(sidebar, { color = theme.color.borderSubtle, layoutOrder = 6 })

		-- The pinned profile row. The subtitle is the provider actually in use, which is
		-- what the reference client puts there and what someone looking at this wants to
		-- know -- it was a literal "Gateway" before, true only by coincidence.
		local profileName = "you"
		local okName, display = pcall(function() return env.plr and env.plr.DisplayName end)
		if okName and type(display) == "string" and util.trim(display) ~= "" then
			profileName = display
		elseif env.plr and type(env.plr.Name) == "string" and env.plr.Name ~= "" then
			profileName = env.plr.Name
		end

		local profile
		profile = P.rowButton(sidebar, {
			name = "ProfileBar",
			height = theme.size.bar,
			bg = theme.color.sidebar,
			padding = { x = ROW_INSET },
			layoutOrder = 7,
			onClick = function()
				host.showProfileMenu(profile.instance)
			end,
		})
		profile.icon("spark", 1, theme.color.accent, ROW_ICON)
		P.text(profile.row, {
			name = "ProfileName",
			text = profileName,
			role = "bodyStrong",
			line = theme.line.tight,
			color = theme.color.text,
			auto = "X",
			layoutOrder = 2,
		})
		local profileDetail = P.text(profile.row, {
			name = "ProfileProvider",
			text = "",
			role = "caption",
			line = theme.line.tight,
			color = theme.color.textTertiary,
			auto = "X",
			layoutOrder = 3,
		})
		P.spacer(profile.row, { grow = true, layoutOrder = 4 })
		local chevronSlot = P.frame(profile.row, {
			size = UDim2.fromOffset(ROW_ICON, ROW_ICON),
			layoutOrder = 5,
		})
		icons.chevron(chevronSlot, ROW_ICON, theme.color.textTertiary, "up")

		local function describeProvider()
			local record = providers.active()
			if not record then return "no provider" end
			local model = util.trim(tostring(record.model or ""))
			if model == "" then return record.label end
			return record.label
		end

		function handle.refresh()
			profileDetail.Text = "\194\183 " .. describeProvider()
			for id, entry in pairs(modes) do
				local selected = host.panel == id
				entry.button.setSelected(selected)
				entry.label.TextColor3 = selected and theme.color.text or theme.color.textTertiary
			end
			handle.back.setEnabled(host.canBack())
			handle.forward.setEnabled(host.canForward())
			handle.renderMore()
			handle.renderHistory()
		end

		handle.refresh()

		-- The list is the app's own state: a new thread, a rename, a delete or a switch
		-- all have to show up here without the panel knowing this exists.
		local unsubscribeSessions = sessions.listChanged:connect(function()
			if not sidebar.Parent then return end
			handle.renderHistory()
		end)
		local unsubscribeProviders = providers.changed:connect(function()
			if not sidebar.Parent then return end
			profileDetail.Text = "\194\183 " .. describeProvider()
		end)
		local unsubscribePlace = place.changed:connect(function()
			if not sidebar.Parent then return end
			handle.renderHistory()
		end)
		-- The count on the Subagents row. Debounced, because the register changes on
		-- every tool call a child makes and this rebuilds a list of rows -- and
		-- debounced rather than throttled so the last change in a burst, which is the
		-- one that drops the count back to nothing, is not the one that gets dropped.
		local unsubscribeAgents = subagent.changed:connect(clock.debounce(function()
			if not sidebar.Parent then return end
			handle.renderMore()
		end, 0.3))

		sidebar.Destroying:Connect(function()
			pcall(unsubscribeSessions)
			pcall(unsubscribeProviders)
			pcall(unsubscribePlace)
			pcall(unsubscribeAgents)
		end)

		handle.instance = sidebar
		return handle
	end

	return M
end
