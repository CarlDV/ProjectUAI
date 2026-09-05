-- The composer: the scope chips, the prompt field, send/stop, and the meta row.
--
-- Send behaviour differs by platform on purpose. With a keyboard, Enter sends --
-- that is what everyone expects and reaching for a button breaks the typing rhythm.
-- On touch there is no Enter worth the name, so the button is the primary action and
-- the field grows instead. The expand toggle switches to a multi-line field where
-- Enter inserts a newline and only the button sends.
--
-- Everything on the two rows around the field states something the client knows and
-- changes something when pressed. That is worth saying because it was not true: the
-- chips were a list of invented project and branch names, the permission chip
-- announced "Full Auto" while the agent was actually prompting for every write, and
-- the model name was a literal that no provider had ever reported.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local fsx = env.require("runtime/fsx")
	local place = env.require("runtime/place")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local sessions = env.require("agent/session")
	local permissions = env.require("agent/permissions")
	local providers = env.require("provider/registry")
	local models = env.require("provider/models")
	local traits = env.require("provider/traits")

	local M = {}

	-- How much of an attached file travels with the message. The agent can read the
	-- rest with its own tools; this is context, not a transfer.
	local ATTACH_CAP = 4000

	function M.new(parent, props)
		props = props or {}

		-- One bordered box holding the field and the send control, sitting on the
		-- canvas rather than in a bar of its own. There is no rule above it: the box's
		-- own outline is what separates it from the transcript, and a rule as well
		-- draws two lines where the eye needs one. That is also why the field goes in
		-- `bare` -- a bordered input inside a bordered bar was two nested rectangles
		-- for one input.
		local shell = P.column(parent, {
			name = "Composer",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			-- One step of air between the three rows rather than six pixels. The meta row
			-- sat close enough to the input box to read as part of it, so "Allow
			-- everything" and the token count looked like status inside the field.
			gap = theme.space.sm,
			-- Matches the transcript's own horizontal inset, so the composer's box and the
			-- reading column above it share a left edge instead of missing it by four.
			padding = { x = theme.space.xl, top = theme.space.sm, bottom = theme.space.md },
			zIndex = theme.z.raised,
		})

		local composer = { expanded = false, busy = false, attachments = {} }

		-- Scope chips ---------------------------------------------------------

		local scopeRow = P.row(shell, {
			name = "ScopeRow",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			wrap = true,
			layoutOrder = 1,
		})

		local function chip(name, iconName, labelText, order, onClick)
			local handle = P.rowButton(scopeRow, {
				name = "Chip_" .. name,
				auto = "X",
				height = theme.size.chip,
				size = UDim2.fromOffset(0, theme.size.chip),
				bg = theme.color.surface,
				stroke = true,
				strokeColor = theme.color.borderSubtle,
				radius = theme.radius.sm,
				gap = theme.space.xxs,
				padding = { x = theme.space.xs },
				layoutOrder = order,
				onClick = onClick,
			})
			handle.iconSlot = handle.icon(iconName, 1, theme.color.textTertiary, theme.size.icon - theme.space.hair)
			if labelText ~= nil then
				handle.text = P.text(handle.row, {
					name = "ChipLabel",
					text = labelText,
					role = "caption",
					color = theme.color.textSecondary,
					auto = "X",
					layoutOrder = 2,
				})
			end
			return handle
		end

		-- 1. What this client is running on. Not a choice -- it is the host -- so the
		-- menu is the capability report, which is the thing anyone clicking it wants.
		local runtimeLabel = caps.executor
		if runtimeLabel == "unknown" then
			runtimeLabel = caps.studio and "Studio" or "Client"
		end
		chip("runtime", "terminal", runtimeLabel, 1, function(handle)
			local options = {}
			local function fact(label, value, tone)
				options[#options + 1] = { label = label, value = tostring(value), detail = tostring(value), tone = tone }
			end
			fact("Transport", caps.http .. (caps.requestName and (" (" .. caps.requestName .. ")") or ""))
			fact("Claude Code identity", caps.uaSupported and "can be sent" or "cannot be sent here",
				caps.uaSupported and "good" or "warn")
			fact("Filesystem", caps.fs and "available" or "unavailable", caps.fs and "good" or "warn")
			fact("Code execution", caps.exec and "available" or "unavailable", caps.exec and "good" or "warn")
			fact("WebSocket", caps.ws and "available" or "unavailable")
			fact("Clipboard", caps.clipboard and "available" or "unavailable")
			overlay.menu({
				target = handle.instance,
				width = theme.size.menuWide,
				options = options,
				onSelect = function(value)
					if caps.clipboard then
						pcall(caps.fn.clipboard, tostring(value))
						overlay.toast("Copied", "good", 1.5)
					else
						overlay.toast(tostring(value), "info", 3)
					end
				end,
			})
		end)

		-- 2. The place, which is this client's project: it is what the work is in and
		-- what the conversation list groups by.
		local placeChip = chip("place", "folder", place.label(), 2, function(handle)
			local options = {}
			for _, group in ipairs(sessions.groups()) do
				options[#options + 1] = {
					label = group.label,
					value = "place:" .. tostring(group.placeId),
					detail = util.pluralise(#group.sessions, "conversation"),
					selected = group.current,
				}
			end
			if #options > 0 then options[#options + 1] = { divider = true } end
			options[#options + 1] = { label = "Place details", value = "details", icon = "document", tone = "info" }
			overlay.menu({
				target = handle.instance,
				width = theme.size.menuWide,
				options = options,
				onSelect = function(value)
					if value == "details" then
						local facts = place.facts()
						overlay.menu({
							target = handle.instance,
							width = theme.size.menuWide,
							options = (function()
								local out = {}
								for _, entry in ipairs(facts) do
									out[#out + 1] = { label = entry.key, value = entry.value, detail = entry.value }
								end
								return out
							end)(),
							onSelect = function(fact)
								if caps.clipboard then
									pcall(caps.fn.clipboard, tostring(fact))
									overlay.toast("Copied", "good", 1.5)
								else
									overlay.toast(tostring(fact), "info", 3)
								end
							end,
						})
					elseif util.startsWith(tostring(value), "place:") then
						local wanted = tostring(value):sub(7)
						for _, group in ipairs(sessions.groups()) do
							if tostring(group.placeId) == wanted and group.sessions[1] then
								env.require("ui/app").openSession(group.sessions[1].id)
							end
						end
					end
				end,
			})
		end)

		-- 3. The place version, which is the closest thing a running client has to a
		-- revision: it is what changes when the game is republished under you.
		if place.version > 0 then
			chip("version", "branch", "v" .. tostring(place.version), 3, function(handle)
				overlay.toast(place.describe(), "info", 3)
			end)
		end

		-- 4. Isolation. A conversation marked this way is never written to disk, which
		-- is the same reason a worktree exists: somewhere to try something without it
		-- becoming part of the history.
		local isolateChip
		local function paintIsolate()
			local session = sessions.current()
			local on = session.ephemeral == true
			isolateChip.instance.BackgroundColor3 = on and theme.color.accentSurface or theme.color.surface
			if isolateChip.text then
				isolateChip.text.Text = on and "isolated" or "worktree"
				isolateChip.text.TextColor3 = on and theme.color.accentHot or theme.color.textSecondary
			end
		end
		isolateChip = chip("isolate", "worktree", "worktree", 4, function()
			local session = sessions.current()
			local now = session.setEphemeral(not session.ephemeral)
			paintIsolate()
			overlay.toast(now
				and "This conversation will not be saved to disk."
				or "This conversation is saved again.", "info", 2.5)
		end)
		paintIsolate()

		-- 5. Attach. Real files from the client's own folder, and the memory it keeps.
		local attachRow
		local function renderAttachments()
			for _, child in ipairs(attachRow:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			attachRow.Visible = #composer.attachments > 0
			for index, entry in ipairs(composer.attachments) do
				local handle = P.rowButton(attachRow, {
					name = "Attachment_" .. tostring(index),
					auto = "X",
					height = theme.size.chip,
					size = UDim2.fromOffset(0, theme.size.chip),
					bg = theme.color.surfaceRaised,
					radius = theme.radius.sm,
					gap = theme.space.xxs,
					padding = { x = theme.space.xs },
					layoutOrder = index,
					onClick = function()
						table.remove(composer.attachments, index)
						renderAttachments()
					end,
				})
				handle.icon("document", 1, theme.color.accent, theme.size.icon - theme.space.hair)
				P.text(handle.row, {
					text = entry.label,
					role = "caption",
					color = theme.color.textSecondary,
					auto = "X",
					layoutOrder = 2,
				})
				handle.icon("close", 3, theme.color.textTertiary, theme.size.icon - theme.space.xxs)
			end
		end

		local function attachMenu(target)
			local options = {}
			local files = fsx.enabled and fsx.list("") or {}
			for _, entry in ipairs(files) do
				if not entry.isDir then
					options[#options + 1] = {
						label = entry.name,
						value = "file:" .. entry.path,
						detail = entry.path,
						icon = "document",
					}
				end
			end
			local state = env.require("agent/state")
			for _, entry in ipairs(state.memoryList()) do
				options[#options + 1] = {
					label = entry.key,
					value = "memory:" .. entry.key,
					detail = util.ellipsis(entry.value, 60),
					icon = "book",
				}
			end
			if #options > 0 then options[#options + 1] = { divider = true } end
			options[#options + 1] = { label = "A path in " .. fsx.root, value = "path", icon = "folder", tone = "info" }

			overlay.menu({
				target = target,
				width = theme.size.menuWide,
				options = options,
				onSelect = function(value)
					local function attachFile(path)
						local body, err = fsx.read(path)
						if not body then
							overlay.toast(tostring(err), "warn", 3)
							return
						end
						composer.attachments[#composer.attachments + 1] = {
							label = path,
							path = path,
							text = util.truncate(body, ATTACH_CAP, "attach a narrower slice if you need the rest"),
						}
						renderAttachments()
					end
					if util.startsWith(tostring(value), "file:") then
						attachFile(tostring(value):sub(6))
					elseif util.startsWith(tostring(value), "memory:") then
						local key = tostring(value):sub(8)
						composer.attachments[#composer.attachments + 1] = {
							label = "memory/" .. key,
							text = tostring(state.recall(key) or ""),
						}
						renderAttachments()
					elseif value == "path" then
						overlay.prompt({
							title = "Attach a file",
							description = "A path inside " .. fsx.root .. ". Its contents travel with the message.",
							placeholder = "notes/plan.txt",
							confirmText = "Attach",
							onConfirm = function(path)
								if util.trim(path) ~= "" then attachFile(util.trim(path)) end
							end,
						})
					end
				end,
			})
		end

		chip("attach", "document", nil, 5, function(handle)
			attachMenu(handle.instance)
		end)

		attachRow = P.row(shell, {
			name = "Attachments",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			wrap = true,
			layoutOrder = 2,
		})
		attachRow.Visible = false

		-- The field ------------------------------------------------------------

		-- A wrapper with no layout of its own, so the mascot can perch on the input
		-- box's top edge without becoming a layout item -- a positioned child inside a
		-- list layout takes a slot of its own and pushes everything after it out.
		local inputHolder = P.frame(shell, {
			name = "InputHolder",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			layoutOrder = 3,
		})

		local inputRow = P.row(inputHolder, {
			name = "InputRow",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.surfaceRaised,
			radius = theme.radius.lg,
			gap = theme.space.xs,
			padding = { x = theme.space.sm, y = theme.space.xxs },
			alignY = "Center",
		})
		local boxStroke = P.stroke(inputRow, theme.color.borderSubtle)

		-- Decoration, and the only thing in this interface that is. It has no handler,
		-- because a mascot that announced "Ready to code!" in a toast was pretending to
		-- be a control.
		local mascotSlot = P.frame(inputHolder, {
			name = "Mascot",
			size = UDim2.fromOffset(theme.size.iconLarge + theme.space.xs, theme.size.iconLarge),
			anchor = Vector2.new(0.5, 1),
			position = UDim2.new(1, -(theme.size.control + theme.space.xl), 0, theme.space.hair),
			zIndex = theme.z.raised + 1,
		})
		icons.mascot(mascotSlot, theme.size.iconLarge, theme.color.accent)

		local fieldHolder = P.frame(inputRow, {
			name = "FieldHolder",
			size = UDim2.new(0, 0, 0, 0),
			auto = "Y",
			flex = "Fill",
			layoutOrder = 1,
		})

		-- An attachment is context, so it travels ahead of the question in a block the
		-- model can tell from prose. It is dropped after the send: leaving it attached
		-- would silently re-send the same file with every following message.
		local function compose(text)
			if #composer.attachments == 0 then return text end
			local parts = {}
			for _, entry in ipairs(composer.attachments) do
				parts[#parts + 1] = string.format("<attached name=\"%s\">\n%s\n</attached>",
					tostring(entry.label), tostring(entry.text))
			end
			parts[#parts + 1] = text
			return table.concat(parts, "\n\n")
		end

		local function submit()
			local text = util.trim(composer.field.get())
			if text == "" then return end
			local payload = compose(text)
			composer.field.clear()
			composer.attachments = {}
			renderAttachments()
			if props.onSend then props.onSend(payload) end
		end

		local function paintFocus(focused)
			env.tween:Create(boxStroke, theme.tween("hover"), {
				Color = focused and theme.color.accentBorder or theme.color.borderSubtle,
			}):Play()
		end

		local function buildField(carried)
			return P.field(fieldHolder, {
				name = "Prompt",
				bare = true,
				placeholder = props.placeholder or "Describe a task or ask a question",
				multiline = composer.expanded,
				height = composer.expanded and (theme.size.control * 3) or nil,
				text = carried,
				onFocus = function() paintFocus(true) end,
				onBlur = function() paintFocus(false) end,
				onSubmit = function()
					if not composer.expanded then submit() end
				end,
			})
		end

		composer.field = buildField(nil)

		local sendButton = P.iconButton(inputRow, {
			name = "Send",
			icon = "send",
			variant = "ghost",
			diameter = theme.size.control,
			layoutOrder = 2,
			onClick = function()
				if composer.busy then
					if props.onStop then props.onStop() end
				else
					submit()
				end
			end,
		})
		sendButton.instance.LayoutOrder = 2

		-- The meta row ---------------------------------------------------------

		-- Wraps rather than overflows. Six controls -- a permission label that can read
		-- "Auto (ask for dangerous)", a model id, a context dot and two text buttons --
		-- do not fit on one line in a 340px window, and a row that cannot wrap puts the
		-- last of them past the edge where the CanvasGroup clips them away.
		local metaRow = P.row(shell, {
			name = "Meta",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			wrap = true,
			gap = theme.space.xs,
			padding = { x = theme.space.xxs },
			layoutOrder = 4,
		})

		-- Permission mode, which is what the reference client's "Bypass permissions"
		-- control is. It reads the real mode and writes the real mode: the label used to
		-- say "Bypass permissions" on a client that was set to ask for every write,
		-- which is the one place in this interface where a lie was also a safety
		-- problem.
		local permissionChip = P.rowButton(metaRow, {
			name = "PermissionMode",
			auto = "X",
			height = theme.size.chip,
			size = UDim2.fromOffset(0, theme.size.chip),
			radius = theme.radius.sm,
			gap = theme.space.xxs,
			padding = { x = theme.space.xs },
			layoutOrder = 1,
			onClick = function(handle)
				local options = {}
				for _, mode in ipairs(permissions.MODES) do
					options[#options + 1] = {
						label = permissions.MODE_LABELS[mode] or mode,
						value = mode,
						detail = permissions.MODE_HINTS[mode],
						selected = permissions.mode() == mode,
						tone = mode == "full" and "warn" or nil,
					}
				end
				overlay.menu({
					target = handle.instance,
					width = theme.size.menuWide,
					options = options,
					onSelect = function(mode)
						permissions.setMode(mode)
						composer.syncContext()
					end,
				})
			end,
		})
		local permissionLabel = P.text(permissionChip.row, {
			name = "PermissionLabel",
			text = "",
			role = "caption",
			color = theme.color.textSecondary,
			auto = "X",
			layoutOrder = 1,
		})

		local plusButton = P.iconButton(metaRow, {
			name = "AddContext",
			icon = "plus",
			variant = "ghost",
			diameter = theme.size.chip,
			layoutOrder = 2,
			onClick = function(handle)
				attachMenu(handle.instance)
			end,
		})
		plusButton.instance.LayoutOrder = 2

		local statusLabel = P.text(metaRow, {
			name = "Status",
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			truncate = true,
			-- An explicit height, not a scale one: the row wraps, so it sizes itself to
			-- its contents and a (0, 0, 1, 0) child inside it resolves to nothing.
			size = UDim2.new(0, 0, 0, math.max(theme.size.chip, responsive.minTarget())),
			flex = "Fill",
			layoutOrder = 3,
		})

		-- The model, the effort it is being asked for, and how full the context is. All
		-- three come from the provider record and the session; the menu behind them is
		-- the real provider and model picker.
		local modelChip = P.rowButton(metaRow, {
			name = "ModelChip",
			auto = "X",
			height = theme.size.chip,
			size = UDim2.fromOffset(0, theme.size.chip),
			radius = theme.radius.sm,
			gap = theme.space.xxs,
			padding = { x = theme.space.xs },
			layoutOrder = 4,
			onClick = function(handle)
				M.providerMenu(handle.instance, composer)
			end,
		})
		local modelLabel = P.text(modelChip.row, {
			name = "ModelLabel",
			text = "",
			role = "caption",
			color = theme.color.textSecondary,
			auto = "X",
			layoutOrder = 1,
		})
		local effortLabel = P.text(modelChip.row, {
			name = "EffortLabel",
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			auto = "X",
			layoutOrder = 2,
		})
		local contextDot = P.statusDot(modelChip.row, {
			diameter = theme.size.dot,
			color = theme.color.textTertiary,
			layoutOrder = 3,
		})

		local expandButton = P.button(metaRow, {
			name = "Expand",
			text = "multiline",
			variant = "ghost",
			size = "sm",
			tight = true,
			layoutOrder = 5,
			onClick = function()
				composer.setExpanded(not composer.expanded)
			end,
		})
		expandButton.instance.LayoutOrder = 5

		local clearButton = P.button(metaRow, {
			name = "Clear",
			text = "clear",
			variant = "ghost",
			size = "sm",
			tight = true,
			layoutOrder = 6,
			onClick = function()
				if props.onClear then props.onClear() end
			end,
		})
		clearButton.instance.LayoutOrder = 6

		-- Everything on the meta row, from the real records ---------------------

		function composer.syncContext()
			permissionLabel.Text = permissions.MODE_LABELS[permissions.mode()] or permissions.mode()
			permissionLabel.TextColor3 = permissions.mode() == "full"
				and theme.color.warn or theme.color.textSecondary

			local record = providers.active()
			if not record then
				modelLabel.Text = "no provider"
				modelLabel.TextColor3 = theme.color.warn
				effortLabel.Text = ""
			else
				local model = util.trim(tostring(record.model or ""))
				if model == "" then
					modelLabel.Text = record.label .. "  no model"
					modelLabel.TextColor3 = theme.color.warn
				else
					local badge = traits.badge(model)
					modelLabel.Text = model .. (badge and ("  " .. badge) or "")
					modelLabel.TextColor3 = theme.color.textSecondary
				end
				-- The effort actually sent, which is the setting clamped to what this
				-- model offers -- "Max" on a model whose scale stops at high is high, and
				-- saying Max would be reporting the setting rather than the request.
				local wanted = tostring(config.get("agent.effort", "high"))
				local levels = traits.effortLevels(model)
				local sending = wanted
				if levels then sending = traits.nearestEffort(model, wanted) or wanted end
				if levels == nil and model ~= "" then
					effortLabel.Text = ""
				else
					effortLabel.Text = (sending:gsub("^%l", string.upper))
				end
			end

			-- Context pressure, from the conversation the composer is attached to.
			local session = sessions.current()
			local stats = session.ctx.stats()
			local budget = math.max(tonumber(config.get("agent.contextTokens", 24000)) or 24000, 1)
			local share = util.clamp(stats.tokens / budget, 0, 1)
			composer.contextShare = share
			local tone = theme.color.success
			if share > 0.85 then
				tone = theme.color.danger
			elseif share > 0.6 then
				tone = theme.color.warn
			end
			contextDot.BackgroundColor3 = tone
		end

		-- Rebuilding the field is the honest way to switch MultiLine: changing the
		-- property on a live TextBox leaves its alignment and height wrong.
		function composer.setExpanded(value)
			composer.expanded = value == true
			local carried = composer.field.get()
			pcall(function() composer.field.shell:Destroy() end)
			composer.field = buildField(carried)
			expandButton.setText(composer.expanded and "single line" or "multiline")
		end

		function composer.setBusy(value)
			composer.busy = value == true
			-- ClearAllChildren would take the UICorner that P.button attached along
			-- with the icon, and since this runs once at build time that is why the
			-- send button has been square from the moment it existed. Only the drawn
			-- content is replaced.
			for _, child in ipairs(sendButton.instance:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			-- The primary action becomes Stop while a turn is running, in place
			-- rather than as a second control, so there is only ever one thing to
			-- press.
			local content = P.row(sendButton.instance, {
				size = UDim2.fromScale(1, 1),
				alignX = "Center",
			})
			local holder = P.frame(content, {
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
			})
			if composer.pulse then
				pcall(function() composer.pulse:Cancel() end)
				composer.pulse = nil
			end
			if composer.busy then
				-- Danger is outline-and-text rather than a fill, so the glyph is the
				-- danger colour: drawing it in the on-accent tone left a near-black
				-- square on a transparent button.
				icons.stop(holder, theme.size.icon, theme.color.danger)
				-- setVariant tweens the background over 0.12s, so assigning
				-- BackgroundColor3 here as well only started a race the tween won.
				sendButton.setVariant("danger")
				-- A breathing outline. It is the one piece of motion visible with the
				-- transcript scrolled away, which is where a long turn is usually spent.
				if not responsive.reduceMotion then
					composer.busyStroke = composer.busyStroke
						or P.stroke(sendButton.instance, theme.color.danger, theme.stroke.focus)
					composer.busyStroke.Color = theme.color.danger
					composer.busyStroke.Transparency = theme.opacity.dim
					composer.pulse = env.tween:Create(composer.busyStroke, theme.motion.pulse,
						{ Transparency = 0 })
					composer.pulse:Play()
				end
			else
				icons.send(holder, theme.size.icon, theme.color.textSecondary)
				sendButton.setVariant("ghost")
				if composer.busyStroke then composer.busyStroke.Transparency = 1 end
			end
		end

		function composer.setStatus(text)
			statusLabel.Text = tostring(text or "")
		end

		-- The running token line, which is a setting rather than progress: it is the one
		-- thing on this row that is about cost, and not everyone wants it in front of
		-- them. Kept separate from setStatus so turning it off cannot also hide "Working
		-- (step 3)".
		function composer.setUsage(text)
			if config.get("ui.showUsage", true) ~= true then
				statusLabel.Text = ""
				return
			end
			statusLabel.Text = tostring(text or "")
		end

		function composer.focus()
			composer.field.focus()
		end

		-- The keyboard covering the field is the classic mobile bug. The window moves
		-- itself; this only has to stop showing the meta row when there is no height
		-- left for it.
		local unsubscribeResponsive = responsive.changed:connect(function()
			if not metaRow.Parent then return end
			metaRow.Visible = not responsive.isCompactHeight()
		end)
		metaRow.Visible = not responsive.isCompactHeight()

		-- The chips are a view of state that other surfaces change: the permission mode
		-- from a menu, the model from the Providers panel, the place name when it
		-- resolves.
		local unsubscribeProviders = providers.changed:connect(function()
			if not metaRow.Parent then return end
			composer.syncContext()
		end)
		local unsubscribePermissions = permissions.changed:connect(function()
			if not metaRow.Parent then return end
			composer.syncContext()
		end)
		local unsubscribePlace = place.changed:connect(function()
			if not scopeRow.Parent then return end
			if placeChip.text then placeChip.text.Text = place.label() end
		end)
		local unsubscribeSessions = sessions.listChanged:connect(function()
			if not scopeRow.Parent then return end
			paintIsolate()
		end)
		shell.Destroying:Connect(function()
			pcall(unsubscribeResponsive)
			pcall(unsubscribeProviders)
			pcall(unsubscribePermissions)
			pcall(unsubscribePlace)
			pcall(unsubscribeSessions)
		end)

		composer.shell = shell
		composer.setBusy(false)
		composer.syncContext()
		return composer
	end

	-- Picks a provider, or a model within the active one. Both live behind the same
	-- chip because they are the same decision from the user's point of view. Models
	-- listed here are the ones the endpoint reported plus the ones the user added --
	-- never a guess, so the menu can legitimately be empty until one of those has
	-- happened.
	function M.providerMenu(target, composer)
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
			for _, id in ipairs(models.list(record)) do
				-- The window is the one thing about a model worth reading at a glance,
				-- and no endpoint publishes it -- so where it is known, it rides on the
				-- label. The value stays the bare id, which is what goes on the wire.
				local badge = traits.badge(id)
				options[#options + 1] = {
					label = badge and (id .. " (" .. badge .. ")") or id,
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
		options[#options + 1] = { divider = true }
		for _, level in ipairs({ "low", "medium", "high", "xhigh", "max" }) do
			options[#options + 1] = {
				label = "Effort: " .. (level:gsub("^%l", string.upper)),
				value = "effort:" .. level,
				selected = tostring(config.get("agent.effort", "high")) == level,
			}
		end
		options[#options + 1] = { divider = true }
		options[#options + 1] = { label = "Manage providers", value = "manage", tone = "info" }

		overlay.menu({
			target = target,
			width = theme.size.menuWide,
			options = options,
			onSelect = function(value)
				local app = env.require("ui/app")
				if value == "manage" then
					app.show("providers")
				elseif value == "fetch" and record then
					overlay.toast("Fetching models from " .. record.label, "info", 2)
					task.spawn(function()
						local found, note = models.discover(record, { force = true })
						overlay.toast(tostring(note), #found > 0 and "good" or "warn")
						if composer then composer.syncContext() end
					end)
				elseif value == "addmodel" and record then
					overlay.prompt({
						title = "Add a model to " .. record.label,
						description = "Type the id exactly as the provider expects it. It is saved to this provider and selected.",
						placeholder = "model id",
						onConfirm = function(text)
							local ok, result = models.add(record, text)
							overlay.toast(tostring(result), ok and "good" or "warn")
							if composer then composer.syncContext() end
						end,
					})
				elseif util.startsWith(tostring(value), "provider:") then
					providers.setActive(tostring(value):sub(10))
				elseif util.startsWith(tostring(value), "model:") and record then
					providers.setModel(record.id, tostring(value):sub(7))
				elseif util.startsWith(tostring(value), "effort:") then
					config.set("agent.effort", tostring(value):sub(8))
					if composer then composer.syncContext() end
				end
			end,
		})
	end

	return M
end
