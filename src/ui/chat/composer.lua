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
	-- UI-only drafts survive conversation switches and layout/theme rebuilds.
	local drafts = {}
	local draftViews = {}
	local pendingSends = {}
	local function copyAttachments(list)
		local out = {}
		for index, entry in ipairs(list or {}) do out[index] = entry end
		return out
	end
	function M.hasDrafts()
		for id, draft in pairs(drafts) do
			if sessions.threads[id] and (util.trim(draft.text or "") ~= "" or #(draft.attachments or {}) > 0) then return true end
		end
		return false
	end

	-- How much of an attached file travels with the message. The agent can read the
	-- rest with its own tools; this is context, not a transfer.
	local ATTACH_CAP = 4000

	function M.new(parent, props)
		props = props or {}
		local mobile = responsive.isMobile()
		local chipHeight = math.max(theme.size.chip, responsive.minTarget())

		local controlHeight = math.max(theme.size.control, responsive.minTarget())
		local inset = mobile and theme.space.xxs or theme.space.sm
		local sideInset = mobile and theme.space.sm or theme.space.lg
		local topInset = mobile and theme.space.hair or theme.space.xxs
		local bottomInset = mobile and theme.space.hair or theme.space.sm
		local controlGap = mobile and theme.space.xxs or theme.space.sm
		local resizeComposer
		local shell = P.frame(parent, {
			name = "Composer", size = UDim2.new(1, 0, 0, controlHeight + inset * 3 + theme.space.xxs),
			zIndex = theme.z.raised,
		})
		local composer = { expanded = false, busy = false, attachments = {} }
		local draftId
		local restoring = false
		local destroyed = false
		local draftView
		local function alive() return not destroyed and shell.Parent ~= nil end
		composer.isAlive = alive
		local function saveDraft()
			if not destroyed and draftId and sessions.threads[draftId] and composer.field and not restoring then
				local previous = drafts[draftId] or {}
				local text = composer.field.get()
				drafts[draftId] = {
					text = text, attachments = copyAttachments(composer.attachments), expanded = composer.expanded,
					-- Rebuilds retain this version; real edits (even edit-away-and-back)
					-- advance it so a returning send cannot erase a newer question.
					textVersion = (previous.textVersion or 0) + (previous.text ~= text and 1 or 0),
				}
			end
		end
		local surface = P.frame(shell, {
			name = "ComposerSurface", size = UDim2.new(1, -sideInset * 2, 0, controlHeight + inset * 2),
			position = UDim2.fromOffset(sideInset, topInset),
			bg = theme.color.surface, radius = mobile and theme.radius.md or theme.radius.lg,
		})
		local boxStroke = P.stroke(surface, theme.color.border)
		local sendButton
		local function syncSend()
			if alive() and sendButton then
				sendButton.setEnabled(not pendingSends[draftId] and (composer.busy
					or (composer.field and util.trim(composer.field.get()) ~= "")))
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

		local scopeChips = {}
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
			scopeChips[#scopeChips + 1] = handle
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
		local attachmentHandles = {}
		local function fitAttachments()
			if not alive() then return end
			local width = math.max(0, surface.AbsoluteSize.X - inset * 2)
			for _, item in ipairs(attachmentHandles) do
				local reserve = theme.space.xs * 2 + theme.space.xxs * 2
					+ item.leading.Size.X.Offset + item.close.Size.X.Offset
				local wanted = math.ceil(P.measureText(item.label.Text, { role = "caption" }).X) + reserve
				item.button.instance.Size = UDim2.fromOffset(math.min(width, math.max(chipHeight, wanted)), chipHeight)
			end
		end
		local function renderAttachments()
			if not alive() then return end
			for _, child in ipairs(attachRow:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			attachmentHandles = {}
			attachRow.Visible = #composer.attachments > 0
			for index, entry in ipairs(composer.attachments) do
				local handle = P.rowButton(attachRow, {
					name = "Attachment_" .. tostring(index),
					height = chipHeight,
					size = UDim2.fromOffset(chipHeight, chipHeight),
					bg = theme.color.surfaceRaised,
					radius = theme.radius.sm,
					gap = theme.space.xxs,
					padding = { x = theme.space.xs },
					layoutOrder = index,
					onClick = function()
						if not alive() then return end
						for position, attachment in ipairs(composer.attachments) do
							if attachment == entry then
								table.remove(composer.attachments, position)
								renderAttachments()
								break
							end
						end
					end,
				})
				local leading = handle.icon("document", 1, theme.color.accent, theme.size.icon - theme.space.hair)
				local label = P.text(handle.row, {
					text = entry.label,
					role = "caption",
					color = theme.color.textSecondary,
					size = UDim2.new(0, 0, 0, theme.text.caption.height),
					flex = "Fill",
					truncate = true,
					layoutOrder = 2,
				})
				local close = handle.icon("close", 3, theme.color.textTertiary, theme.size.icon - theme.space.xxs)
				-- The whole chip remains the removal target, including the close icon.
				attachmentHandles[#attachmentHandles + 1] = { button = handle, label = label, leading = leading, close = close }
			end
			fitAttachments()
			if resizeComposer then resizeComposer() end
			saveDraft()
		end

		local function attachMenu(target)
			if not alive() then return end
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
					if not alive() then return end
					local function attachFile(path)
						if not alive() then return end
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
			if not alive() or composer.busy or not draftId or pendingSends[draftId] then return false end
			local id = draftId
			if not sessions.threads[id] or sessions.current().id ~= id then return false end
			local text = util.trim(composer.field.get())
			if text == "" then return end
			local payload = compose(text)
			if not props.onSend then return false end
			saveDraft()
			local sent = drafts[id]
			pendingSends[id] = true
			syncSend()
			-- The callback may yield, switch conversations, or destroy and replace
			-- this composer before it returns. Settle against the session's draft.
			local ok, accepted = pcall(props.onSend, payload)
			local live = draftViews[id]
			if live then live.capture() end
			if ok and accepted ~= false and sessions.threads[id] and drafts[id] then
				local current = drafts[id]
				local clearText = current.textVersion == sent.textVersion and current.text == sent.text
				local submitted, kept = {}, {}
				for _, entry in ipairs(sent.attachments) do submitted[entry] = true end
				for _, entry in ipairs(current.attachments) do
					if not submitted[entry] then kept[#kept + 1] = entry end
				end
				drafts[id] = {
					text = clearText and "" or current.text,
					textVersion = current.textVersion + (clearText and 1 or 0),
					attachments = kept,
					expanded = current.expanded and not (clearText and #kept == 0 and current.expanded == sent.expanded),
				}
				if live then live.restore() end
			end
			pendingSends[id] = nil
			if draftViews[id] then draftViews[id].sync() end
			if not ok then error(accepted, 0) end
			if accepted == false then return false end
			return true
		end

		-- Focus is the box lifting a step and taking the accent on its outline, not just
		-- the outline. On a dark ramp a hairline changing hue is easy to miss, and this is
		-- the one control in the app whose focus state has to be unmistakable -- the
		-- keyboard shortcut that opens quick chat is a printable character, so "is this
		-- focused" decides where the next keystroke goes.
		local function paintFocus(focused)
			if not alive() then return end
			P.animate(boxStroke, "hover", {
				Color = focused and theme.color.accent or theme.color.border,
				Thickness = focused and theme.stroke.focus or theme.stroke.hair,
			})
			P.animate(surface, "hover", {
				BackgroundColor3 = focused and theme.color.surfaceRaised or theme.color.surface,
			})
		end

		local function stackedInput()
			return composer.expanded and (not mobile or parent.AbsoluteSize.Y >=
				controlHeight * 2 + inset * 2 + topInset + bottomInset + theme.space.xs + theme.space.sm)
		end
		local function promptHeight()
			if stackedInput() then
				local wanted = math.max(theme.text.body.height * 2 + theme.space.md,
					math.min(theme.size.composerExpanded, responsive.viewport.Y * 0.25))
				if mobile then
					local remaining = parent.AbsoluteSize.Y - controlHeight - theme.space.xs
						- inset * 2 - topInset - bottomInset - theme.text.body.height * 2
					wanted = math.min(wanted, math.max(controlHeight, remaining))
				end
				return wanted
			end
			return math.max(theme.size.control, theme.text.body.height, responsive.minTarget())
		end
		local function buildField(carried)
			local previousLength = #(carried or "")
			return P.field(fieldHolder, {
				name = "Prompt",
				bare = true,
				placeholder = props.placeholder or "Message UAI…",
				multiline = composer.expanded,
				height = promptHeight(),
				text = carried,
				onFocus = function() paintFocus(true) end,
				onBlur = function() paintFocus(false) end,
				onChange = function(text)
					if not alive() or type(text) ~= "string" then return end
					syncSend()
					saveDraft()
					if restoring then previousLength = #text; return end
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

		local metaRow = P.frame(inputRow, { name = "Meta", size = UDim2.fromScale(1, 1) })
		sendButton = P.iconButton(metaRow, {
			name = "Send",
			icon = "send",
			variant = "primary",
			diameter = controlHeight,
			radius = mobile and theme.radius.md or theme.radius.lg,
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

		local details = P.frame(shell, { name = "ComposerState", size = UDim2.fromOffset(0, 0), visible = false })
		local permissionLabel = P.text(scopeRow, { name = "PermissionLabel", text = "", role = "caption", auto = "X", layoutOrder = 6 })
		local statusLabel = P.text(details, { name = "Status", text = "", role = "caption", color = theme.color.textTertiary,
			size = UDim2.fromScale(1, 1), truncate = true })
		local plusButton = P.iconButton(metaRow, {
			name = "AddContext", icon = "plus", variant = "ghost", diameter = theme.size.chip,
			onClick = function(handle) attachMenu(handle.instance) end,
		})
		local modelChip = P.rowButton(metaRow, {
			name = "ModelChip", size = UDim2.fromOffset(theme.size.composerModel, chipHeight), height = chipHeight,
			radius = theme.radius.sm, gap = theme.space.xs, padding = { x = theme.space.xs },
			onClick = function(handle) M.providerMenu(handle.instance, composer) end,
		})
		local modelLabel = P.text(modelChip.row, {
			name = "ModelLabel", text = "", role = "caption", color = theme.color.textSecondary,
			size = UDim2.new(0, 0, 0, theme.text.caption.height), flex = "Fill",
			truncate = true, layoutOrder = 2,
		})
		local effortLabel = P.text(scopeRow, { name = "EffortLabel", text = "", role = "caption", auto = "X", layoutOrder = 7 })
		local contextDot = P.statusDot(modelChip.row, {
			diameter = theme.size.dot, color = theme.color.textTertiary, layoutOrder = 1,
		})
		modelChip.icon("chevron", 3, theme.color.textTertiary, theme.size.icon)
		local function promptMenu(target)
			local options = {}
			for _, entry in ipairs(env.require("ui/chat/prompts").items) do
				options[#options + 1] = { label = entry.label, detail = entry.detail, icon = entry.icon, value = entry.id }
			end
			overlay.menu({ target = target, width = theme.size.menuWide, options = options, onSelect = function(value)
				for _, entry in ipairs(env.require("ui/chat/prompts").items) do
					if entry.id == value then composer.insert(entry.text) end
				end
			end })
		end
		local moreButton = P.iconButton(metaRow, {
			name = "ComposerOptions", icon = "ellipsis", variant = "ghost", diameter = theme.size.chip,
			onClick = function(handle)
				local options = {
					{ label = "Chat loops", detail = "Status, quiz scores, and stop controls", value = "loops", icon = "sliders" },
					{ label = "Prompt library", detail = "Explore, create, or diagnose", value = "prompts", icon = "spark" },
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
					if value == "prompts" then promptMenu(handle.instance)
					elseif value == "loops" then env.require("ui/chat/loops").open(handle.instance)
					elseif value == "model" then M.providerMenu(handle.instance, composer)
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
			if not alive() then return end
			local expanded = stackedInput()
			local width = math.max(surface.AbsoluteSize.X - inset * 2, 0)
			local left = chipHeight + (mobile and controlGap or theme.space.xs)
			local right = controlHeight + chipHeight + controlGap * 2
			-- Size to the actual label, not a permanent 144px slot around 'big-pickle'.
			local measured = math.max(P.measureText(modelLabel.Text, { role = "caption" }).X, modelLabel.TextBounds.X)
			local wanted = math.ceil(measured) + theme.size.dot + theme.size.icon + theme.space.xs * 4
			local available = width - left - right - (expanded and 0 or theme.size.composerFieldMin)
			local modelWidth = math.max(0, math.min(wanted, theme.size.composerModel, available))
			if modelWidth < math.min(wanted, theme.size.composerModelMin) then modelWidth = 0 end
			modelChip.instance.Visible = modelWidth > 0
			modelChip.instance.Size = UDim2.fromOffset(modelWidth, chipHeight)
			modelChip.instance.AnchorPoint = expanded and Vector2.new(0, 0.5) or Vector2.new(1, 0.5)
			modelChip.instance.Position = expanded and UDim2.new(0, left, 0.5, 0) or UDim2.new(1, -right, 0.5, 0)
			plusButton.instance.AnchorPoint = Vector2.new(0, 0.5)
			plusButton.instance.Position = UDim2.fromScale(0, 0.5)
			moreButton.instance.AnchorPoint = Vector2.new(1, 0.5)
			moreButton.instance.Position = UDim2.new(1, -(controlHeight + controlGap), 0.5, 0)
			sendButton.instance.AnchorPoint = Vector2.new(1, 0.5)
			sendButton.instance.Position = UDim2.fromScale(1, 0.5)
			fieldHolder.Position = UDim2.fromOffset(expanded and 0 or left, 0)
			fieldHolder.Size = UDim2.new(1, expanded and 0
				or -(left + right + (modelWidth > 0 and modelWidth + theme.space.sm or 0)), 0, promptHeight())
		end
		local resizing = false
		resizeComposer = function()
			if not alive() or resizing then return end
			resizing = true
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
			local fieldHeight = promptHeight()
			local expanded = stackedInput()
			inputHolder.Position = UDim2.fromOffset(inset, top)
			local inputHeight = fieldHeight + (expanded and controlHeight + theme.space.xs or 0)
			inputHolder.Size = UDim2.new(1, -inset * 2, 0, inputHeight)
			composer.field.shell.Size = UDim2.new(1, 0, 0, fieldHeight)
			metaRow.Position = UDim2.fromOffset(0, expanded and fieldHeight + theme.space.xs or 0)
			metaRow.Size = UDim2.new(1, 0, 0, controlHeight)
			local surfaceHeight = top + inputHeight + inset
			surface.Size = UDim2.new(1, -sideInset * 2, 0, surfaceHeight)
			shell.Size = UDim2.new(1, 0, 0, surfaceHeight + topInset + bottomInset)
			fitLabels()
			fitAttachments()
			resizing = false
		end
		surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			fitLabels()
			fitAttachments()
		end)
		modelLabel:GetPropertyChangedSignal("TextBounds"):Connect(fitLabels)
		attachRow:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() resizeComposer() end)
		if mobile then parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() resizeComposer() end) end

		-- Everything on the meta row, from the real records ---------------------

		function composer.syncContext()
			if not alive() then return end
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
			if not record or util.trim(tostring(record.model or "")) == "" then
				contextDot.BackgroundColor3 = theme.color.warn
			end
			fitLabels()
		end

		-- Rebuilding the field is the honest way to switch MultiLine: changing the
		-- property on a live TextBox leaves its alignment and height wrong.
		function composer.setExpanded(value, keepFocus)
			if not alive() then return end
			composer.expanded = value == true
			paintFocus(false)
			local carried = composer.field.get()
			pcall(function() composer.field.shell:Destroy() end)
			composer.field = buildField(carried)
			if keepFocus ~= false then composer.field.focus() end
			resizeComposer()
			syncSend()
			saveDraft()
		end

		function composer.insert(text)
			if not alive() then return end
			local previous = composer.field.get()
			composer.field.set(previous == "" and text or (previous .. "\n\n" .. text))
			if previous ~= "" or tostring(text):find("\n") then composer.setExpanded(true) end
			composer.focus()
		end

		local function restoreDraft()
			if not alive() then return end
			restoring = true
			local draft = drafts[draftId] or {}
			composer.attachments = copyAttachments(draft.attachments)
			composer.field.set(draft.text or "")
			if composer.expanded ~= (draft.expanded == true) then composer.setExpanded(draft.expanded == true, false) end
			renderAttachments()
			restoring = false
			syncSend()
		end
		draftView = { capture = saveDraft, restore = restoreDraft, sync = syncSend }
		function composer.attach(session)
			if not alive() or not session or draftId == session.id then return end
			saveDraft()
			if draftId and draftViews[draftId] == draftView then draftViews[draftId] = nil end
			draftId = session.id
			draftViews[draftId] = draftView
			restoreDraft()
		end

		function composer.setBusy(value)
			if not alive() then return end
			composer.busy = value == true
			if composer.mascot then pcall(composer.mascot.setBusy, composer.busy) end
			sendButton.setIcon(composer.busy and "stop" or "send")
			sendButton.setVariant(composer.busy and "danger" or "primary")
			composer.field.instance.PlaceholderText = composer.busy and "Write a follow-up…"
				or props.placeholder or "Message UAI…"
			syncSend()
		end

		function composer.setStatus(text)
			if not alive() then return end
			statusLabel.Text = tostring(text or "")
			statusLabel.TextColor3 = theme.color.accentHot
		end

		-- The running token line, which is a setting rather than progress: it is the one
		-- thing on this row that is about cost, and not everyone wants it in front of
		-- them. Kept separate from setStatus so turning it off cannot also hide "Working
		-- (step 3)".
		function composer.setUsage(text)
			if not alive() then return end
			statusLabel.TextColor3 = theme.color.textTertiary
			if config.get("ui.showUsage", true) ~= true then
				statusLabel.Text = ""
				return
			end
			statusLabel.Text = tostring(text or "")
		end

		function composer.focus()
			if alive() then composer.field.focus() end
		end

		-- Keep model and permission controls usable when the keyboard reduces height.
		local unsubscribeResponsive = responsive.changed:connect(function()
			if not alive() then return end
			chipHeight = math.max(theme.size.chip, responsive.minTarget())
			controlHeight = math.max(theme.size.control, responsive.minTarget())
			plusButton.instance.Size = UDim2.fromOffset(chipHeight, chipHeight)
			moreButton.instance.Size = UDim2.fromOffset(chipHeight, chipHeight)
			sendButton.instance.Size = UDim2.fromOffset(controlHeight, controlHeight)
			scopeRow.Size = UDim2.fromOffset(0, chipHeight)
			mascotSlot.Size = UDim2.fromOffset(mascotSize, chipHeight)
			for _, handle in ipairs(scopeChips) do
				handle.instance.Size = UDim2.fromOffset(0, chipHeight)
				handle.row.Size = UDim2.fromOffset(0, chipHeight)
			end
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
		local unsubscribeConfig = config.changed:connect(function(path)
			if path == nil or path == "agent" or path == "agent.effort"
				or path == "agent.forceReasoning" or path == "agent.forceContext" or path == "agent.contextTokens" then
				composer.syncContext()
			end
		end)
		local unsubscribePlace = place.changed:connect(function()
			if not scopeRow.Parent then return end
			if placeChip.text then placeChip.text.Text = util.ellipsis(place.label(), 24) end
		end)
		local unsubscribeSessions = sessions.listChanged:connect(function()
			if not scopeRow.Parent then return end
			for id in pairs(drafts) do
				if not sessions.threads[id] then drafts[id] = nil; draftViews[id] = nil end
			end
			paintIsolate()
		end)
		shell.Destroying:Connect(function()
			saveDraft()
			destroyed = true
			if draftId and draftViews[draftId] == draftView then draftViews[draftId] = nil end
			pcall(unsubscribeResponsive)
			pcall(unsubscribeProviders)
			pcall(unsubscribePermissions)
			pcall(unsubscribeConfig)
			pcall(unsubscribePlace)
			pcall(unsubscribeSessions)
		end)

		composer.shell = shell
		composer.attach(sessions.current())
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
			if composer and composer.isAlive() then composer.syncContext() end
		end)
	end

	return M
end
