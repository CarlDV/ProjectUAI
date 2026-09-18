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
	local traits = env.require("provider/traits")

	local M = {}

	-- How much of an attached file travels with the message. The agent can read the
	-- rest with its own tools; this is context, not a transfer.
	local ATTACH_CAP = 4000

	function M.new(parent, props)
		props = props or {}
		local chipHeight = math.max(theme.size.chip, responsive.minTarget())

		local controlHeight = math.max(theme.size.control, responsive.minTarget())
		local inset = theme.space.sm
		local resizeComposer
		local shell = P.frame(parent, {
			name = "Composer", size = UDim2.new(1, 0, 0, controlHeight + inset * 3 + theme.space.xxs),
			zIndex = theme.z.raised,
		})
		local composer = { expanded = false, busy = false, attachments = {} }
		local surface = P.frame(shell, {
			name = "ComposerSurface", size = UDim2.new(1, -theme.space.lg * 2, 0, controlHeight + inset * 2),
			position = UDim2.fromOffset(theme.space.lg, theme.space.xxs),
			bg = theme.color.surfaceRaised, radius = theme.radius.md,
		})
		local boxStroke = P.stroke(surface, theme.color.border)
		local sendButton
		local function syncSend()
			if sendButton then
				sendButton.setEnabled(composer.busy or (composer.field and util.trim(composer.field.get()) ~= ""))
			end
		end

		-- Scope chips ---------------------------------------------------------

		local scopeScroll = P.scroll(surface, {
			name = "ContextStrip",
			visible = false,
			horizontal = true,
			size = UDim2.new(1, 0, 0, math.max(theme.size.chip, responsive.minTarget()) + theme.size.scrollbar),
			gap = 0,
			layoutOrder = 1,
		})
		local scopeRow = P.row(scopeScroll.instance, {
			name = "ScopeRow",
			size = UDim2.new(0, 0, 0, math.max(theme.size.chip, responsive.minTarget())),
			auto = "X",
			gap = theme.space.xxs,
			layoutOrder = 2,
		})

		local function chip(name, iconName, labelText, order, onClick)
			local handle = P.rowButton(scopeRow, {
				name = "Chip_" .. name,
				auto = "X",
				height = chipHeight,
				size = UDim2.fromOffset(0, chipHeight),
				bg = nil,
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
					text = util.ellipsis(labelText, 24),
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
					height = chipHeight,
					size = UDim2.fromOffset(0, chipHeight),
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
					text = util.ellipsis(entry.label, 32),
					role = "caption",
					color = theme.color.textSecondary,
					auto = "X",
					layoutOrder = 2,
				})
				handle.icon("close", 3, theme.color.textTertiary, theme.size.icon - theme.space.xxs)
			end
			if resizeComposer then resizeComposer() end
		end

		local function attachMenu(target)
			local options = {}
			-- The agent's workspace, which is where the model's own files live and where
			-- an attached note is expected to be.
			local files = fsx.enabled and fsx.list("", { scope = "files" }) or {}
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
						-- The agent's workspace first, then pastes, so a path the toast
						-- just showed ("pastes/composer-...") is attachable as-is.
						local body, err = fsx.read(path, { scope = "files" })
						if not body then
							body, err = fsx.read(path, { scope = "pastes" })
						end
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
						description = "A path inside " .. fsx.root .. "/files. Its contents travel with the message.",
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

		attachRow = P.row(surface, {
			name = "Attachments",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xs,
			wrap = true,
			layoutOrder = 2,
		})
		attachRow.Visible = false

		-- The field ------------------------------------------------------------

		-- Explicit geometry avoids circular AutomaticSize/flex measurements.
		local inputHolder = P.frame(surface, {
			name = "InputHolder", size = UDim2.new(1, -inset * 2, 0, controlHeight),
			position = UDim2.fromOffset(inset, inset),
		})
		local inputRow = P.frame(inputHolder, {
			name = "InputRow", size = UDim2.fromScale(1, 1),
		})

		-- The existing mascot stays in the quiet context row, away from the caret.
		local mascotSize = theme.size.iconLarge
		local mascotSlot = P.frame(scopeRow, {
			name = "Mascot",
			size = UDim2.fromOffset(mascotSize, theme.size.chip),
			layoutOrder = 99,
		})
		local _, mascot = icons.mascot(mascotSlot, mascotSize, theme.color.accent)
		composer.mascot = mascot

		local fieldHolder = P.frame(inputRow, {
			name = "FieldHolder", size = UDim2.new(1, 0, 1, 0),
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
			if composer.busy then return false end
			local text = util.trim(composer.field.get())
			if text == "" then return end
			local payload = compose(text)
			if not props.onSend then return false end
			local accepted = props.onSend(payload)
			if accepted == false then return false end
			composer.field.clear()
			composer.attachments = {}
			renderAttachments()
			return true
		end

		-- Focus is the box lifting a step and taking the accent on its outline, not just
		-- the outline. On a dark ramp a hairline changing hue is easy to miss, and this is
		-- the one control in the app whose focus state has to be unmistakable -- the
		-- keyboard shortcut that opens quick chat is a printable character, so "is this
		-- focused" decides where the next keystroke goes.
		local function paintFocus(focused)
			P.animate(boxStroke, "hover", {
				Color = focused and theme.color.accent or theme.color.border,
				Thickness = focused and theme.stroke.focus or theme.stroke.hair,
			})
			P.animate(surface, "hover", {
				BackgroundColor3 = focused and theme.color.surfaceOverlay or theme.color.surfaceRaised,
			})
		end

		-- One line at rest, which is what a single-line field is.
		--
		-- It was briefly two, on the theory that the primary surface of the app deserves
		-- the room. It does not: `multiline` is false at rest, so the second line was
		-- empty space under one line of text with the caret at the top of it -- a tall
		-- grey box, which is exactly what it looked like. The expand toggle is what asks
		-- for room, and that is the mode where the extra lines can actually be typed
		-- into.
		local function buildField(carried)
			local previousLength = #(carried or "")
			return P.field(fieldHolder, {
				name = "Prompt",
				bare = true,
				placeholder = props.placeholder or "Describe a task or ask a question…",
				multiline = composer.expanded,
				height = composer.expanded and math.max(theme.text.body.height * 2 + theme.space.md,
					math.min(theme.text.body.height * 5 + theme.space.md, responsive.viewport.Y * 0.25)) or theme.size.control,
				text = carried,
				onFocus = function() paintFocus(true) end,
				onBlur = function() paintFocus(false) end,
				onChange = function(text)
					if type(text) ~= "string" then return end
					syncSend()
					local cap = sessions.PASTE_CAP
					local jumped = #text > cap and (#text - previousLength) > cap
					previousLength = #text
					if not (jumped and fsx.enabled) then return end
					local stamp = os.date("!%Y%m%d-%H%M%S")
					local path = "composer-" .. stamp .. "-" .. util.uid("p") .. ".txt"
					if fsx.write(path, text, { scope = "pastes" }) then
						composer.attachments[#composer.attachments + 1] = {
							label = "pastes/" .. path .. " (" .. tostring(#text) .. " chars)",
							path = path,
							text = util.truncate(text, ATTACH_CAP, "the full text is in this file; read it with file_read"),
						}
						renderAttachments()
						composer.field.clear()
						previousLength = 0
						overlay.toast("Long paste saved to pastes/" .. path .. " and attached", "good", 3)
					end
				end,
				onSubmit = function()
					if not composer.expanded then submit() end
				end,
			})
		end
		composer.field = buildField(nil)

		sendButton = P.iconButton(inputRow, {
			name = "Send",
			icon = "send",
			variant = "primary",
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

		-- All primary input controls share one line. More holds secondary controls.
		local metaRow = P.frame(inputRow, { name = "Meta", size = UDim2.fromScale(1, 1) })
		local details = P.frame(shell, { name = "ComposerState", size = UDim2.fromOffset(0, 0), visible = false })
		local permissionLabel = P.text(details, { name = "PermissionLabel", text = "", role = "caption" })
		local statusLabel = P.text(details, { name = "Status", text = "", role = "caption" })
		local plusButton = P.iconButton(inputRow, {
			name = "AddContext", icon = "plus", variant = "ghost", diameter = theme.size.chip,
			onClick = function(handle) attachMenu(handle.instance) end,
		})
		local modelChip = P.rowButton(metaRow, {
			name = "ModelChip", size = UDim2.fromOffset(140, chipHeight), height = chipHeight,
			radius = theme.radius.sm, gap = theme.space.xxs, padding = { x = theme.space.xs },
			onClick = function(handle) M.providerMenu(handle.instance, composer) end,
		})
		local modelLabel = P.text(modelChip.row, {
			name = "ModelLabel", text = "", role = "caption", color = theme.color.textSecondary,
			size = UDim2.new(1, -(theme.size.dot + theme.space.xxs + theme.space.xs * 2), 0, theme.text.caption.height),
			truncate = true, layoutOrder = 1,
		})
		local effortLabel = P.text(details, { name = "EffortLabel", text = "", role = "caption" })
		local contextDot = P.statusDot(modelChip.row, {
			diameter = theme.size.dot, color = theme.color.textTertiary, layoutOrder = 2,
		})
		local moreButton = P.iconButton(metaRow, {
			name = "ComposerOptions", icon = "ellipsis", variant = "ghost", diameter = theme.size.chip,
			onClick = function(handle)
				local options = {
					{ label = "Model and effort", detail = modelLabel.Text, value = "model", icon = "spark" },
					{ label = "Permissions", detail = permissionLabel.Text, value = "permissions", icon = "sliders" },
					{ label = scopeScroll.instance.Visible and "Hide context details" or "Show context details", value = "context", icon = "folder" },
					{ label = composer.expanded and "Single-line input" or "Multiline input", value = "expand", icon = "code" },
				}
				if statusLabel.Text ~= "" then
					options[#options + 1] = { label = "Usage and status", detail = statusLabel.Text, value = "status" }
				end
				options[#options + 1] = { divider = true }
				options[#options + 1] = { label = "Clear conversation", value = "clear", icon = "trash", tone = "bad" }
				overlay.menu({ target = handle.instance, options = options, onSelect = function(value)
					if value == "model" then M.providerMenu(handle.instance, composer)
					elseif value == "permissions" then
						local modes = {}
						for _, mode in ipairs(permissions.MODES) do
							modes[#modes + 1] = { label = permissions.MODE_LABELS[mode] or mode, value = mode,
								detail = permissions.MODE_HINTS[mode], selected = permissions.mode() == mode,
								tone = mode == "full" and "warn" or nil }
						end
						overlay.menu({ target = handle.instance, options = modes, onSelect = function(mode)
							permissions.setMode(mode); composer.syncContext()
						end })
					elseif value == "context" then
						scopeScroll.instance.Visible = not scopeScroll.instance.Visible; resizeComposer()
					elseif value == "expand" then composer.setExpanded(not composer.expanded)
					elseif value == "status" then overlay.toast(statusLabel.Text, "info", 5)
					elseif value == "clear" and props.onClear then props.onClear() end
				end })
			end,
		})
		local function fitLabels()
			local width = math.max(surface.AbsoluteSize.X - inset * 2, 0)
			local modelWidth = width >= 560 and math.min(160, width * 0.22) or 0
			modelChip.instance.Visible = modelWidth > 0
			modelChip.instance.Size = UDim2.fromOffset(modelWidth, chipHeight)
			modelChip.instance.AnchorPoint = Vector2.new(1, 0.5)
			modelChip.instance.Position = UDim2.new(1, -(controlHeight + chipHeight + inset * 2), 0.5, 0)
			plusButton.instance.AnchorPoint = Vector2.new(0, 0.5)
			plusButton.instance.Position = UDim2.fromScale(0, 0.5)
			moreButton.instance.AnchorPoint = Vector2.new(1, 0.5)
			moreButton.instance.Position = UDim2.new(1, -(controlHeight + inset), 0.5, 0)
			sendButton.instance.AnchorPoint = Vector2.new(1, 0.5)
			sendButton.instance.Position = UDim2.fromScale(1, 0.5)
			local left = chipHeight + inset
			local right = controlHeight + chipHeight + inset * 2 + (modelWidth > 0 and modelWidth + inset or 0)
			fieldHolder.Position = UDim2.fromOffset(left, 0)
			fieldHolder.Size = UDim2.new(1, -(left + right), 1, 0)
		end
		resizeComposer = function()
			local top = inset
			if scopeScroll.instance.Visible then
				scopeScroll.instance.Position = UDim2.fromOffset(inset, top)
				scopeScroll.instance.Size = UDim2.new(1, -inset * 2, 0, chipHeight + theme.size.scrollbar)
				top = top + chipHeight + theme.size.scrollbar + inset
			end
			if attachRow.Visible then
				attachRow.Position = UDim2.fromOffset(inset, top)
				attachRow.Size = UDim2.new(1, -inset * 2, 0, 0)
				top = top + math.max(attachRow.AbsoluteSize.Y, chipHeight) + inset
			end
			local fieldHeight = composer.expanded and math.max(theme.text.body.height * 2 + theme.space.md,
				math.min(theme.text.body.height * 5 + theme.space.md, responsive.viewport.Y * 0.25)) or controlHeight
			inputHolder.Position = UDim2.fromOffset(inset, top)
			inputHolder.Size = UDim2.new(1, -inset * 2, 0, fieldHeight)
			local surfaceHeight = top + fieldHeight + inset
			surface.Size = UDim2.new(1, -theme.space.lg * 2, 0, surfaceHeight)
			shell.Size = UDim2.new(1, 0, 0, surfaceHeight + theme.space.xxs + inset)
			fitLabels()
		end
		surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitLabels)
		attachRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() resizeComposer() end)

		-- Everything on the meta row, from the real records ---------------------

		function composer.syncContext()
			local shortModes = { ask = "Ask first", auto = "Auto", full = "Full access" }
			permissionLabel.Text = shortModes[permissions.mode()] or permissions.MODE_LABELS[permissions.mode()] or permissions.mode()
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
				-- saying Max would be reporting the setting rather than the request. A
				-- model marked by hand as a reasoner has no documented scale to clamp
				-- against, so the setting is the request exactly as it stands.
				local wanted = tostring(config.get("agent.effort", "high"))
				local levels = traits.effortLevels(model)
				local sending = wanted
				if levels then sending = traits.nearestEffort(model, wanted) or wanted end
				if levels == nil and model ~= "" and not traits.thinkingStyle(model) then
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
			fitLabels()
		end

		-- Rebuilding the field is the honest way to switch MultiLine: changing the
		-- property on a live TextBox leaves its alignment and height wrong.
		function composer.setExpanded(value)
			composer.expanded = value == true
			paintFocus(false)
			local carried = composer.field.get()
			pcall(function() composer.field.shell:Destroy() end)
			composer.field = buildField(carried)
			composer.field.focus()
			resizeComposer()
			syncSend()
		end

		function composer.setBusy(value)
			composer.busy = value == true
			if composer.mascot then pcall(composer.mascot.setBusy, composer.busy) end
			sendButton.setIcon(composer.busy and "stop" or "send")
			sendButton.setVariant(composer.busy and "danger" or "primary")
			syncSend()
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

		-- Keep model and permission controls usable when the keyboard reduces height.
		local unsubscribeResponsive = responsive.changed:connect(function()
			if not metaRow.Parent then return end
			resizeComposer()
		end)
		resizeComposer()

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
			if placeChip.text then placeChip.text.Text = util.ellipsis(place.label(), 24) end
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

	-- Picks the endpoint, the model on it, and the effort it is asked for. All three
	-- live behind the same chip because they are one decision from the user's point of
	-- view -- and behind ui/panels/modelpicker rather than an anchored menu, because a
	-- menu is the right shape for six rows and this list is as long as the endpoint's
	-- catalogue. `target` is unused now and kept in the signature: it is what an
	-- anchored menu needed, and the chip still passes it.
	function M.providerMenu(target, composer)
		return env.require("ui/panels/modelpicker").open(function()
			if composer then composer.syncContext() end
		end)
	end

	return M
end
