-- What is in the settings, as a list of panes.
--
-- Two surfaces render these: the Settings panel stacks every pane in one scroll, and
-- the settings dialog the sidebar opens shows one at a time behind a category list.
-- Declaring them once is what keeps the two from drifting -- the dialog used to hold
-- its own copy of three appearance rows, none of which were wired to anything, while
-- the panel held the real ones.
--
-- A pane is `{ id, section, label, icon, build(container) }`. `build` is handed a
-- column to fill and returns nothing; everything it puts there reads and writes
-- config, so nothing has to be re-read when it is shown again.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local fsx = env.require("runtime/fsx")
	local place = env.require("runtime/place")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local overlay = env.require("ui/overlay")
	local quickchat = env.require("ui/quickchat")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local R = env.require("ui/settingsrows")
	local permissions = env.require("agent/permissions")
	local state = env.require("agent/state")
	local usage = env.require("agent/usage")
	local stats = env.require("agent/stats")
	local registry = env.require("agent/registry")
	local sessions = env.require("agent/session")
	local providers = env.require("provider/registry")
	local ua = env.require("net/ua")
	local http = env.require("net/http")
	local bridgeModule = env.require("net/bridge")

	local M = {}

	-- The token budgets. They stop where the widest models of the moment do -- a
	-- million in, a hundred and twenty-eight thousand out -- rather than where a
	-- default conversation needs, because a ceiling that cannot reach the model is
	-- indistinguishable from the model not having it.
	local BUDGET_STOPS = {
		4000, 8000, 12000, 16000, 24000, 32000, 48000, 64000, 96000,
		128000, 160000, 200000, 256000, 320000, 400000, 512000, 750000, 1000000,
	}
	local REPLY_STOPS = { 256, 512, 1024, 2048, 4096, 8192, 16000, 24000, 32000, 64000, 96000, 128000 }
	local RESULT_STOPS = { 1000, 2000, 4000, 6000, 8000, 12000, 16000, 24000, 32000, 48000, 64000, 96000, 128000 }

	-- Each pane builds into a fresh column, so the layout order it needs is just a
	-- running count. This is the only bookkeeping a pane does.
	local function builder(container)
		local order = 0
		local api = {}
		function api.order()
			order = order + 1
			return order
		end
		-- A heading and its card go in one wrapper with a tight gap.
		--
		-- They used to be two siblings of the pane's own column, which means the distance
		-- from a heading to the card it labels was the pane's uniform gap -- exactly the
		-- distance from that heading to the card *above* it. Nothing in the layout said
		-- which block a heading belonged to, and a pane of six sections read as twelve
		-- unrelated things.
		function api.section(title, description)
			local group = P.column(container, {
				name = "Group",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = api.order(),
			})
			P.sectionHeader(group, { title = title, description = description, layoutOrder = 1 })
			return P.card(group, { layoutOrder = 2, gap = theme.space.md })
		end
		function api.note(text, colour)
			return R.paragraph(container, text, { color = colour, layoutOrder = api.order() })
		end
		return api
	end

	local function accentOptions()
		local out = {}
		for key, entry in pairs(theme.ACCENTS) do
			out[#out + 1] = { value = key, label = entry.label }
		end
		table.sort(out, function(a, b) return a.label < b.label end)
		return out
	end

	-- General -----------------------------------------------------------------

	local function paneGeneral(container)
		local build = builder(container)

		local appearance = build.section("Appearance",
			"Layout follows the viewport by default. Pin it if you would rather it did not.")

		P.text(appearance, { text = "Accent", role = "small" })
		C.segmented(appearance, {
			options = accentOptions(),
			value = config.get("ui.accent", "claude"),
			onChange = function(value) config.set("ui.accent", value) end,
		})

		P.text(appearance, { text = "Density", role = "small" })
		C.segmented(appearance, {
			options = {
				{ value = "comfortable", label = "Comfortable" },
				{ value = "compact", label = "Compact" },
			},
			value = config.get("ui.density", "comfortable"),
			onChange = function(value) config.set("ui.density", value) end,
		})

		P.text(appearance, { text = "Layout", role = "small" })
		C.segmented(appearance, {
			options = {
				{ value = "auto", label = "Auto" },
				{ value = "sheet", label = "Sheet" },
				{ value = "panel", label = "Panel" },
				{ value = "window", label = "Window" },
			},
			value = config.get("ui.layout", "auto"),
			onChange = function(value) config.set("ui.layout", value) end,
		})

		R.number(appearance, "Text scale", "Multiplies every type size.", "ui.fontScale", 0.85, 1.4, 0.05)
		R.segmented(appearance, {
			name = "ReduceMotion",
			label = "Reduce motion",
			hint = "Auto follows the platform's own accessibility preference.",
			path = "ui.reduceMotion",
			options = {
				{ value = "auto", label = "Auto" },
				{ value = "on", label = "On" },
				{ value = "off", label = "Off" },
			},
		})
		R.toggle(appearance, {
			label = "Show reasoning",
			hint = "Display the model's chain of thought when it sends one. Applies to the conversation already on screen.",
			path = "ui.showReasoning",
		})
		R.toggle(appearance, {
			label = "Show the code a tool was given",
			hint = "Draws the Luau, the file body or the property map a tool call carries under its "
				.. "row, outside the fold. Off, it is still there behind the row's own caret.",
			path = "ui.showToolCode",
		})
		R.toggle(appearance, {
			label = "Expand tool detail",
			hint = "Open the remaining arguments and the result by default, rather than on the first click.",
			path = "ui.showToolDetail",
		})
		R.toggle(appearance, {
			label = "Show token counts",
			hint = "The running token and cost line under the composer.",
			path = "ui.showUsage",
		})
		R.toggle(appearance, {
			label = "Show the activity card",
			hint = "The greeting and the counters an empty conversation opens with.",
			path = "ui.showActivity",
		})

		-- Built here rather than after the section below it, because nothing in this
		-- card sets a layout order: the rows appear in the order they are created, and a
		-- note constructed later landed wherever the tie-break put it.
		local viewportNote = P.text(appearance, {
			text = "Now: " .. responsive.describe(),
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		viewportNote.Size = UDim2.new(1, 0, 0, 0)
		local unsubscribe = responsive.changed:connect(function()
			if not viewportNote.Parent then return end
			viewportNote.Text = "Now: " .. responsive.describe()
		end)
		viewportNote.Destroying:Connect(function() pcall(unsubscribe) end)

		local shortcuts = build.section("Shortcuts",
			"Quick chat opens in the middle of the screen, takes one message to the conversation the Chat panel shows, and closes itself.")
		local row = P.row(shortcuts, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm })
		local text = P.column(row, {
			size = UDim2.new(0, 0, 0, 0), auto = "Y", flex = "Fill", gap = 0, layoutOrder = 1,
		})
		P.text(text, { text = "Quick chat key", role = "small" })
		local keyHint = P.text(text, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		local keyButton
		local function describeKey()
			keyHint.Text = "Currently " .. quickchat.keyName()
				.. ". Press the button, then the key you want it to be."
		end
		keyButton = P.button(row, {
			name = "QuickKey",
			text = quickchat.keyName(),
			variant = "secondary",
			size = "sm",
			width = theme.size.keyColumn + theme.space.xxl,
			layoutOrder = 2,
			onClick = function()
				keyButton.setText("press a key")
				-- Captured rather than typed: a user thinks "this key", and a character
				-- would not survive a different keyboard layout.
				quickchat.captureNext(function(name)
					keyButton.setText(name)
					describeKey()
				end)
			end,
		})
		keyButton.instance.LayoutOrder = 2
		describeKey()
	end

	-- Privacy -----------------------------------------------------------------

	local function paneprivacy(container)
		local build = builder(container)

		local where = build.section("Where your data goes",
			"This client has no telemetry and no home to call. The only outbound requests it "
			.. "makes are the ones listed here, and every one of them is somewhere you added.")

		local list = {}
		for _, record in ipairs(providers.list()) do
			if record.enabled ~= false then
				list[#list + 1] = {
					key = record.label,
					value = record.baseUrl,
					tone = record.id == (providers.active() or {}).id and "good" or nil,
				}
			end
		end
		if config.get("bridge.enabled", false) == true then
			list[#list + 1] = { key = "Web bridge", value = bridgeModule.status().url }
		end
		if #list == 0 then
			build.note("Nothing is configured, so nothing leaves this machine at all.")
		else
			R.facts(container, list, { name = "Endpoints", layoutOrder = build.order() })
		end

		local secrets = build.section("Keys and logs",
			"An API key is stored in the settings file so a request can be signed with it. "
			.. "Everywhere else -- the request log, the diagnostics, an exported copy of the "
			.. "settings -- only the last four characters are kept.")
		R.toggle(secrets, {
			label = "Mirror the log to the console",
			hint = "Also print every entry with print/warn, which a developer console can read.",
			path = "logs.mirror",
			onChange = function(value) log.mirror = value == true end,
		})
		P.text(secrets, { text = "Level", role = "small" })
		C.segmented(secrets, {
			options = {
				{ value = "debug", label = "Debug" },
				{ value = "info", label = "Info" },
				{ value = "warn", label = "Warn" },
				{ value = "error", label = "Error" },
			},
			value = config.get("logs.level", "info"),
			onChange = function(value)
				config.set("logs.level", value)
				log.setLevel(value)
			end,
		})

		local clear = build.section("Clear what is stored",
			"Each of these is immediate and cannot be undone.")
		R.actions(clear, {
			{
				name = "ClearRequests",
				text = "Request history",
				variant = "ghost",
				onClick = function()
					http.clearHistory()
					overlay.toast("Request history cleared", "good", 2)
				end,
			},
			{
				name = "ClearLog",
				text = "Log",
				variant = "ghost",
				onClick = function()
					log.clear()
					overlay.toast("Log cleared", "good", 2)
				end,
			},
			{
				name = "ClearConversations",
				text = "All conversations",
				variant = "danger",
				onClick = function()
					overlay.confirm({
						title = "Delete every conversation?",
						description = "Every transcript on disk is removed. The activity counters are kept.",
						confirmText = "Delete",
						danger = true,
						onConfirm = function()
							for _, session in ipairs(sessions.list()) do
								sessions.remove(session.id)
							end
							overlay.toast("Conversations deleted", "good", 2)
						end,
					})
				end,
			},
			{
				name = "ClearActivity",
				text = "Activity history",
				variant = "danger",
				onClick = function()
					overlay.confirm({
						title = "Reset the activity history?",
						description = "Every day, model and token count this client has recorded is discarded. "
							.. "The conversations themselves are kept.",
						confirmText = "Reset",
						danger = true,
						onConfirm = function()
							stats.reset()
							overlay.toast("Activity history reset", "good", 2)
						end,
					})
				end,
			},
		})
	end

	-- Usage -------------------------------------------------------------------

	local function paneUsage(container)
		local build = builder(container)

		local live = build.section("This session",
			"What the client has spent since it started, as the provider reported it.")
		local liveText = P.text(live, {
			name = "UsageLine",
			text = usage.line(),
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		liveText.Size = UDim2.new(1, 0, 0, 0)
		local unsubscribe = usage.changed:connect(function()
			if not liveText.Parent then return end
			liveText.Text = usage.line()
		end)
		liveText.Destroying:Connect(function() pcall(unsubscribe) end)
		R.actions(live, { {
			name = "ResetCounters",
			text = "Reset counters",
			variant = "ghost",
			onClick = function() usage.reset() end,
		} })

		local window = stats.window("all")
		local totals = build.section("Everything recorded",
			"Counted from what this client observed and kept on disk, so it survives a restart.")
		local facts = {
			{ key = "Conversations", value = util.formatNumber(window.sessions) },
			{ key = "Messages", value = util.formatNumber(window.messages) },
			{ key = "Requests", value = util.formatNumber(window.requests) },
			{ key = "Tokens in", value = util.formatNumber(window.tokensIn) },
			{ key = "Tokens out", value = util.formatNumber(window.tokensOut) },
			{ key = "Tool calls", value = util.formatNumber(window.toolCalls) },
			{ key = "Active days", value = util.formatNumber(window.activeDays) },
		}
		local cost = usage.formatCost(window.cost)
		if cost ~= "" then
			facts[#facts + 1] = { key = "Cost", value = cost .. (window.estimated and " (some estimated)" or "") }
		end
		if window.tokensFrom then
			facts[#facts + 1] = { key = "Tokens since", value = clock.describeDay(clock.dayKey(window.tokensFrom)) }
		end
		R.facts(totals, facts, { name = "Totals" })
		if not window.tokensFrom then
			R.paragraph(totals,
				"No request has been recorded yet, so there are no token counts. Messages and "
				.. "conversations from before counting began were read back out of the transcripts "
				.. "already on disk; tokens could not be, because nothing recorded them.")
		end

		if #window.models > 0 then
			local models = build.section("By model", "Which model spent what.")
			for index, row in ipairs(window.models) do
				C.keyValue(models, {
					key = row.id,
					value = string.format("%s tokens  %s  %d%%",
						util.formatCompact(row.tokens), util.pluralise(row.requests, "request"),
						math.floor((row.share or 0) * 100 + 0.5)),
					layoutOrder = index,
				})
			end
		end

		local tools = stats.topTools(8)
		if #tools > 0 then
			local toolCard = build.section("Most used tools", "Across every conversation.")
			for index, entry in ipairs(tools) do
				C.keyValue(toolCard, {
					key = entry.name,
					value = util.formatNumber(entry.count),
					layoutOrder = index,
				})
			end
		end
	end

	-- Claude Code -------------------------------------------------------------

	-- A live sample of one code palette, drawn in that palette's own colours rather
	-- than the active one -- which is what lets both be shown side by side and picked
	-- by pressing the one you want, the way the reference client does it.
	local function codePreview(parent, name, order, onPick)
		local palette = theme.CODE_THEMES[name] or theme.CODE_THEMES.dark
		local selected = theme.codeThemeName == name
		local lineHeight = theme.text.monoSmall.height + theme.space.hair
		-- Four sample lines, a bar, and the two hair-thin paddings around them. Stated
		-- once and passed as the card's own size: P.rowButton takes `size` when it is
		-- given one and ignores `height` unless the button is auto-sizing, so passing
		-- both -- with a zero height in the size -- gave the card no height at all and
		-- spilled a hundred pixels of preview over the control below it.
		local cardHeight = lineHeight * 4 + theme.size.rowTight + theme.space.hair * 2
		local card = P.rowButton(parent, {
			name = "CodePreview_" .. name,
			vertical = true,
			size = UDim2.new(0.5, -theme.space.sm, 0, cardHeight),
			height = cardHeight,
			bg = palette.surface,
			radius = theme.radius.md,
			gap = 0,
			padding = theme.space.hair,
			alignY = "Top",
			clip = true,
			stroke = true,
			strokeColor = selected and theme.color.accent or palette.border,
			bgHover = palette.surface,
			bgPress = palette.surface,
			bgSelected = palette.surface,
			selected = selected,
			layoutOrder = order,
			onClick = function()
				config.set("ui.codeTheme", name)
				if onPick then pcall(onPick, name) end
			end,
		})

		local head = P.row(card.row, {
			name = "PreviewBar",
			size = UDim2.new(1, 0, 0, theme.size.rowTight),
			bg = palette.bar,
			padding = { x = theme.space.xs },
			gap = theme.space.xs,
			layoutOrder = 1,
		})
		P.text(head, {
			text = palette.label,
			role = "caption",
			color = palette.gutter,
			size = UDim2.new(0, 0, 1, 0),
			flex = "Fill",
			truncate = true,
			layoutOrder = 1,
		})
		if selected then
			local mark = P.frame(head, {
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
				layoutOrder = 2,
			})
			icons.check(mark, theme.size.icon, theme.color.accent)
		end

		local lines = {
			{ number = 1, prefix = " ", text = "local function greet(name)" },
			{ number = 2, prefix = "-", text = 'return "Hello, " .. name', tone = "remove" },
			{ number = 2, prefix = "+", text = 'return string.format("Hi %s!", name)', tone = "add" },
			{ number = 3, prefix = " ", text = "end" },
		}
		for index, line in ipairs(lines) do
			local fill, ink = nil, palette.text
			if line.tone == "add" then
				fill, ink = palette.addSurface, palette.addText
			elseif line.tone == "remove" then
				fill, ink = palette.removeSurface, palette.removeText
			end
			local row = P.row(card.row, {
				name = "Line" .. tostring(index),
				size = UDim2.new(1, 0, 0, lineHeight),
				bg = fill,
				gap = theme.space.xs,
				padding = { x = theme.space.xs },
				layoutOrder = index + 1,
			})
			P.text(row, {
				text = tostring(line.number),
				role = "monoSmall",
				color = palette.gutter,
				align = "Right",
				size = UDim2.fromOffset(theme.space.md, theme.text.monoSmall.height),
				layoutOrder = 1,
			})
			P.text(row, {
				text = line.prefix,
				role = "monoSmall",
				color = ink,
				size = UDim2.fromOffset(theme.space.sm, theme.text.monoSmall.height),
				layoutOrder = 2,
			})
			P.text(row, {
				text = line.text,
				role = "monoSmall",
				color = ink,
				size = UDim2.new(0, 0, 0, theme.text.monoSmall.height),
				flex = "Fill",
				truncate = true,
				layoutOrder = 3,
			})
		end
		return card
	end

	local function paneClaudeCode(container)
		local build = builder(container)

		local appearance = build.section("Code appearance",
			"How a fenced code block is drawn, in the transcript and everywhere else. "
			.. "Press one to use it.")
		local row = P.row(appearance, {
			name = "CodeThemes",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.md,
			alignY = "Top",
		})
		for index, key in ipairs(theme.CODE_THEME_ORDER) do
			codePreview(row, key, index)
		end

		local fontOptions = {}
		for _, key in ipairs(theme.CODE_ORDER) do
			fontOptions[#fontOptions + 1] = { value = key, label = theme.CODE_FONTS[key].label }
		end
		R.segmented(appearance, {
			name = "CodeFont",
			label = "Code font",
			hint = "The monospace family for code and diagnostics. Roblox renders from a fixed "
				.. "set of families, so this offers the ones that exist rather than a box to type "
				.. "a font name into that could not be loaded.",
			path = "ui.codeFont",
			options = fontOptions,
		})

		local interface = build.section("Appearance",
			"The type the interface itself is set in.")
		local interfaceOptions = {}
		for _, key in ipairs(theme.INTERFACE_ORDER) do
			interfaceOptions[#interfaceOptions + 1] = { value = key, label = theme.INTERFACE_FONTS[key].label }
		end
		R.select(interface, {
			name = "InterfaceFont",
			label = "Interface font",
			hint = "Menus, the sidebar and the transcript. Only the families this client can "
				.. "actually load are listed -- the list is probed against the engine rather than "
				.. "declared, so it is shorter on an older client than a longer one.",
			path = "ui.interfaceFont",
			options = interfaceOptions,
		})
		-- What is being rendered, as opposed to what is selected. Two clients can resolve
		-- the same setting differently: the weight axis needs the modern type stack, and
		-- without it every "medium" role falls back to whichever legacy member pairs that
		-- family with a heavier weight. Saying so is cheaper than someone wondering why
		-- their headings look the same as their body text.
		R.paragraph(interface, string.format("Now: %s, %s.",
			theme.interfaceFontName,
			theme.hasFontFace and "with the regular/medium/semibold weight axis"
				or "weights from the legacy font set on this client"))

		-- Text size is the same setting as the scale slider under General, expressed the
		-- way the reference client expresses it. One value, two controls: the segmented
		-- one reads the scale back rather than keeping a second copy of it.
		local scale = tonumber(config.get("ui.fontScale", 1)) or 1
		local currentSize = "medium"
		if scale < 0.95 then currentSize = "small" end
		if scale > 1.08 then currentSize = "large" end
		R.segmented(interface, {
			name = "TranscriptSize",
			label = "Transcript text size",
			hint = "The same value as the text scale under General.",
			value = currentSize,
			options = {
				{ value = "small", label = "Small" },
				{ value = "medium", label = "Medium" },
				{ value = "large", label = "Large" },
			},
			onChange = function(value)
				local scales = { small = 0.9, medium = 1, large = 1.15 }
				config.set("ui.fontScale", scales[value] or 1)
			end,
		})

		R.segmented(interface, {
			name = "TranscriptWidth",
			label = "Transcript width",
			hint = "The widest the transcript and the composer will grow on a large screen.",
			path = "ui.transcriptWidth",
			options = {
				{ value = "narrow", label = "Narrow" },
				{ value = "medium", label = "Medium" },
				{ value = "wide", label = "Wide" },
			},
		})
	end

	-- Cowork ------------------------------------------------------------------

	local function paneCowork(container)
		local build = builder(container)
		build.section("Cowork",
			"A browser on this machine can join the conversation that is open here. Both sides "
			.. "dial out to a small local process, because a Roblox client cannot accept a "
			.. "connection.")
		env.require("ui/panels/cowork").rows(container, { layoutOrder = build.order() })
		build.order()
	end

	-- Import and export -------------------------------------------------------

	local EXPORT_DIR = "export"

	-- What an export contains, and what it deliberately does not.
	local function exportPayload()
		local settings = util.deepCopy(config.data)
		-- The keys are the one thing that must not be copied into a second file. Kept as
		-- their last four characters so an exported provider list is still readable as a
		-- list of providers.
		for _, record in ipairs(util.get(settings, "providers.list", {}) or {}) do
			local key = tostring(record.apiKey or "")
			if key ~= "" then record.apiKey = "..." .. key:sub(-4) end
		end
		settings.bridge = settings.bridge or {}
		if util.trim(tostring(settings.bridge.token or "")) ~= "" then
			settings.bridge.token = "(removed)"
		end
		return {
			exportedAt = clock.ms(),
			version = env.info and env.info.version or "",
			place = place.facts(),
			settings = settings,
			activity = stats.data,
		}
	end

	local function paneImportExport(container)
		local build = builder(container)

		local out = build.section("Export",
			"Writes a copy of your settings and the activity history into the client's own "
			.. "folder. API keys are reduced to their last four characters and the bridge token "
			.. "is dropped, so the file can be shared.")
		local outPath = EXPORT_DIR .. "/uai-export.json"
		local result = P.text(out, {
			name = "ExportResult",
			text = fsx.enabled and ("Will write " .. fsx.root .. "/" .. outPath)
				or "This host has no filesystem, so an export can only go to the clipboard.",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		result.Size = UDim2.new(1, 0, 0, 0)

		local actions = {}
		if fsx.enabled then
			actions[#actions + 1] = {
				name = "ExportFile",
				text = "Export to a file",
				variant = "secondary",
				onClick = function()
					local ok, err = fsx.writeJson(outPath, exportPayload())
					result.Text = ok and ("Written to " .. fsx.root .. "/" .. outPath)
						or ("Could not write it: " .. tostring(err))
					overlay.toast(ok and "Exported" or "Export failed", ok and "good" or "warn", 2)
				end,
			}
		end
		if caps.clipboard then
			actions[#actions + 1] = {
				name = "ExportClipboard",
				text = "Copy to clipboard",
				variant = "ghost",
				onClick = function()
					local okEncode, body = pcall(util.encode, exportPayload())
					if not okEncode then
						overlay.toast("Could not encode the export", "warn", 2)
						return
					end
					local ok = pcall(caps.fn.clipboard, body)
					overlay.toast(ok and "Copied" or "Could not reach the clipboard",
						ok and "good" or "warn", 2)
				end,
			}
		end
		if #actions > 0 then R.actions(out, actions) end

		local inbound = build.section("Import",
			"Reads a file from the client's folder and applies the settings in it. Providers, "
			-- Being explicit about this: an import that silently replaced a working key
			-- with "...abcd" from an export would break the client in a way that looks
			-- like the provider rejecting you.
			.. "keys and the bridge token are never imported, because an export does not "
			.. "contain them.")
		local importResult = P.text(inbound, {
			name = "ImportResult",
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		importResult.Size = UDim2.new(1, 0, 0, 0)
		R.actions(inbound, { {
			name = "ImportFile",
			text = "Import from a file",
			variant = "secondary",
			onClick = function()
				overlay.prompt({
					title = "Import settings",
					description = "A path inside " .. fsx.root .. ", as it appears in the folder.",
					placeholder = EXPORT_DIR .. "/uai-export.json",
					value = outPath,
					confirmText = "Import",
					onConfirm = function(path)
						local data = fsx.readJson(path, nil)
						local incoming = type(data) == "table" and (data.settings or data) or nil
						if type(incoming) ~= "table" then
							importResult.Text = "Nothing readable at " .. tostring(path)
							return
						end
						local applied = 0
						for _, section in ipairs({ "ui", "agent", "logs", "identity" }) do
							if type(incoming[section]) == "table" then
								config.set(section, util.merge(config.get(section, {}), incoming[section]))
								applied = applied + 1
							end
						end
						importResult.Text = applied > 0
							and (util.pluralise(applied, "section") .. " imported")
							or "That file had no settings in it"
						overlay.toast(importResult.Text, applied > 0 and "good" or "warn", 2)
					end,
				})
			end,
		} })
	end

	-- Desktop app -------------------------------------------------------------

	local function paneDesktop(container)
		local build = builder(container)

		local shell = build.section("Window",
			"Where the interface opens and how much of the screen it takes.")
		R.segmented(shell, {
			name = "OpenPanel",
			label = "Open on",
			hint = "Which surface the interface shows when it is opened.",
			path = "ui.panel",
			options = {
				{ value = "chat", label = "Chat" },
				{ value = "cowork", label = "Cowork" },
				{ value = "providers", label = "Providers" },
				{ value = "tools", label = "Tools" },
				{ value = "logs", label = "Logs" },
			},
		})
		R.toggle(shell, {
			label = "Start with the sidebar collapsed",
			hint = "The conversation list can always be brought back with the toggle in the header.",
			path = "ui.sidebarCollapsed",
		})
		R.toggle(shell, {
			label = "Keep the panel list open",
			hint = "Whether the sidebar's More section starts expanded.",
			path = "ui.sidebarExpanded",
		})
		R.actions(shell, {
			{
				name = "ResetWindow",
				text = "Reset window position",
				variant = "ghost",
				onClick = function()
					config.set("ui.window", util.deepCopy(util.get(config.defaults, "ui.window")))
					overlay.toast("Window position reset", "good", 2)
				end,
			},
			{
				name = "ResetLauncher",
				text = "Reset the launcher",
				variant = "ghost",
				onClick = function()
					config.set("ui.launcher", util.deepCopy(util.get(config.defaults, "ui.launcher")))
					overlay.toast("Launcher reset", "good", 2)
				end,
			},
		})

		local host = build.section("This host",
			"What the client found when it started. None of it is configurable; all of it "
			.. "decides what works.")
		local facts = {
			{ key = "Client", value = tostring(env.info and env.info.version or "") },
			{ key = "Transport", value = caps.http .. (caps.requestName and (" (" .. caps.requestName .. ")") or "") },
			{ key = "Identity", value = caps.uaSupported and "can be sent" or "cannot be sent here", tone = caps.uaSupported and "good" or "warn" },
			{ key = "Filesystem", value = caps.fs and "yes" or "no", tone = caps.fs and "good" or "warn" },
			{ key = "Executor", value = caps.executor },
			{ key = "Viewport", value = responsive.describe() },
		}
		if caps.studio then facts[#facts + 1] = { key = "Studio", value = "yes" } end
		for _, entry in ipairs(place.facts()) do facts[#facts + 1] = entry end
		R.facts(host, facts, { name = "HostFacts" })
	end

	-- Developer ---------------------------------------------------------------

	local function paneDeveloper(container)
		local build = builder(container)

		local logs = build.section("Diagnostics",
			"Every request and every log line the client has kept, and what it keeps them for.")
		local counts = P.text(logs, {
			name = "LogCounts",
			text = "",
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		counts.Size = UDim2.new(1, 0, 0, 0)
		local function describeCounts()
			counts.Text = string.format("%s in the request history\n%s in the log\n%s registered for cleanup",
				util.pluralise(#http.history, "entry"),
				util.pluralise(#log.entries, "line"),
				util.pluralise(env.require("runtime/dispose").count(), "handle"))
		end
		describeCounts()
		R.actions(logs, {
			{
				name = "OpenLogs",
				text = "Open the log",
				variant = "secondary",
				onClick = function()
					env.require("ui/app").show("logs")
				end,
			},
			{
				name = "RefreshCounts",
				text = "Refresh",
				variant = "ghost",
				onClick = describeCounts,
			},
			{
				name = "CopyDiagnostics",
				text = "Copy diagnostics",
				variant = "ghost",
				onClick = function()
					local report = table.concat({
						"UAI " .. tostring(env.info and env.info.version or ""),
						caps.summary(),
						responsive.describe(),
						place.describe(),
						ua.describe(),
						usage.line(),
						log.export(),
					}, "\n")
					if caps.clipboard then
						local ok = pcall(caps.fn.clipboard, report)
						overlay.toast(ok and "Diagnostics copied" or "Could not reach the clipboard",
							ok and "good" or "warn", 2)
					else
						log.info("diagnostics", report)
						overlay.toast("No clipboard here, so it went to the log", "info", 3)
					end
				end,
			},
		})

		local identity = build.section("Client identity",
			"Requests are sent as the Claude Code CLI. Gateways that gate on it accept them; "
			.. "others ignore the extra headers.")
		R.toggle(identity, {
			label = "Send the Claude Code identity",
			hint = "Applies to every inference request.",
			path = "identity.claudeUa",
		})
		R.field(identity, {
			name = "IdentityVersion",
			path = "identity.version",
			placeholder = ua.DEFAULT_VERSION,
			transform = function(text)
				if util.trim(text) == "" then return ua.DEFAULT_VERSION end
				return util.trim(text)
			end,
		})
		local identityBox = P.frame(identity, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.codeSurface,
			radius = theme.radius.md,
			padding = theme.space.sm,
		})
		P.stroke(identityBox, theme.color.codeBorder)
		local identityText = P.text(identityBox, {
			text = ua.describe(),
			role = "monoSmall",
			color = theme.color.codeText,
			wrap = true,
			auto = "Y",
		})
		identityText.Size = UDim2.new(1, 0, 0, 0)
		local unsubscribe = config.changed:connect(function(path)
			if not identityText.Parent then return end
			if path == nil or util.startsWith(tostring(path), "identity.") then
				identityText.Text = ua.describe()
			end
		end)
		identityText.Destroying:Connect(function() pcall(unsubscribe) end)
		if not caps.uaSupported then
			R.paragraph(identity,
				"This host has no executor HTTP function, so Roblox sends its own User-Agent and "
				.. "drops ours. Everything else still works.", { color = theme.color.warn })
		end

		local danger = build.section("Reset",
			"Providers, permission rules and memory are kept unless you say otherwise.")
		R.actions(danger, {
			{
				name = "ResetSettings",
				text = "Reset all settings",
				variant = "danger",
				onClick = function()
					overlay.confirm({
						title = "Reset every setting?",
						description = "Appearance and agent settings go back to defaults. Providers, rules and memory are kept.",
						confirmText = "Reset",
						danger = true,
						onConfirm = function()
							config.reset("ui")
							config.reset("agent")
							overlay.toast("Settings reset", "good")
						end,
					})
				end,
			},
			{
				name = "UnloadUai",
				text = "Unload UAI",
				variant = "danger",
				onClick = function()
					overlay.confirm({
						title = "Unload UAI?",
						description = "Stops the current turn, drains every timer and input handler, saves your settings and removes the interface. Run the loader again to come back.",
						confirmText = "Unload",
						danger = true,
						onConfirm = function()
							-- The handle the bootstrap published, which is the only thing
							-- holding the disposer registry and the ScreenGui together.
							local globals = (type(getgenv) == "function") and getgenv() or nil
							local live = globals and globals.UAI
							if live and live.destroy then
								live.destroy()
							else
								env.require("runtime/dispose").drain()
								pcall(function() env.require("ui/app").screen:Destroy() end)
							end
						end,
					})
				end,
			},
		})
	end

	-- Agent -------------------------------------------------------------------

	local function paneAgent(container)
		local build = builder(container)

		local agent = build.section("Agent", "How hard it works before it stops and answers.")
		R.number(agent, "Step limit", "Tool rounds allowed in one turn, unless the switch below removes it.",
			"agent.maxTurns", 4, 60, 1)
		R.toggle(agent, {
			label = "Unlimited tool calls",
			hint = "Ignore the step limit and the fifteen-minute turn deadline, and keep calling tools until the answer is written. The repeat breaker, each tool's own timeout and Stop still apply, and subagents keep their own budgets.",
			path = "agent.unlimitedTurns",
		})
		R.number(agent, "Parallel tools", "Tool calls run at once within one step.",
			"agent.toolConcurrency", 1, 8, 1)
		R.number(agent, "Tool timeout",
			"Seconds before a tool is abandoned. Subagents are exempt: they run to their own budget below.",
			"agent.toolTimeout", 5, 60, 1)
		R.number(agent, "Subagent budget",
			"Seconds one subagent may work for before it wraps up. The call that dispatched it waits this long plus a minute, so a finished report is never thrown away.",
			"agent.subagentBudget", 30, 900, 30)
		R.number(agent, "Parallel subagents",
			"Subagents alive at once across the whole tree. Several dispatched in one step run together; this is the ceiling on how many, including the ones a subagent starts itself. Anything over it waits for a slot.",
			"agent.subagentConcurrency", 1, 12, 1)
		R.number(agent, "Context budget",
			"Estimated tokens kept before older turns are summarised. Set it against the model's own window, not this client: a million-token model can hold the whole session.",
			"agent.contextTokens", BUDGET_STOPS)
		R.number(agent, "Reply ceiling",
			"max_tokens sent with each request. A value above the model's own limit is lowered to whatever the provider names in its refusal, once, and remembered.",
			"agent.maxTokens", REPLY_STOPS)
		R.number(agent, "Tool result cap",
			"Characters kept from one tool result, roughly four per token. This is the floor on how much a file read or a page fetch can actually return, whatever the tool's own limit says.",
			"agent.resultCap", RESULT_STOPS)
		R.choice(agent, "Effort",
			"How hard a reasoning model works before it answers. Sent as the provider's "
			.. "effort level and clamped to what the chosen model offers; models without one ignore it.",
			"agent.effort",
			{ "low", "medium", "high", "xhigh", "max" },
			{ "Low", "Medium", "High", "Very high", "Max" },
			{ "Faster", "Smarter" })
		R.number(agent, "Temperature",
			"Lower is steadier; 0 is as deterministic as the provider allows. The current Claude models reject it, and it is not sent to them.",
			"agent.temperature", 0, 1.5, 0.05)
		R.number(agent, "Retries", "Attempts per provider before moving to the next.",
			"agent.retries", 1, 6, 1)
		R.toggle(agent, {
			label = "Ask for streams",
			hint = "Streamed replies carry reasoning text and usage counts.",
			path = "agent.stream",
		})
		R.toggle(agent, {
			label = "Summarise old turns",
			hint = "Keeps a long conversation inside the context budget.",
			path = "agent.compaction",
		})
		R.toggle(agent, {
			label = "Provider fallback",
			hint = "Try the next enabled provider when one fails.",
			path = "agent.fallback",
		})
		-- One field, and the only half of the old language picker that was ever wired to
		-- anything. That control was a grid of eleven tiles behind a modal behind a menu
		-- entry, and it advertised two effects: the language the agent answers in, which
		-- src/agent/prompt.lua does read, and the locale dates are formatted with, which
		-- nothing reads at all. What survives is the effect that exists.
		R.field(agent, {
			name = "ReplyLanguage",
			label = "Reply language",
			hint = "Added to the system prompt as one line: answer in this language, leaving code "
				.. "and identifiers alone. Empty means whatever the conversation is already in, "
				.. "which is what a model does by default.",
			path = "agent.replyLanguage",
			placeholder = "Japanese",
		})
	end

	-- Permissions -------------------------------------------------------------

	local function panePermissions(container)
		local build = builder(container)
		local card = build.section("Permissions", permissions.MODE_HINTS[permissions.mode()])

		local modeOptions = {}
		for _, mode in ipairs(permissions.MODES) do
			modeOptions[#modeOptions + 1] = { value = mode, label = permissions.MODE_LABELS[mode] or mode }
		end
		local modeHint
		C.segmented(card, {
			options = modeOptions,
			value = permissions.mode(),
			onChange = function(value)
				permissions.setMode(value)
				if modeHint then modeHint.Text = permissions.MODE_HINTS[value] or "" end
			end,
		})
		modeHint = P.text(card, {
			text = permissions.MODE_HINTS[permissions.mode()] or "",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		modeHint.Size = UDim2.new(1, 0, 0, 0)

		R.toggle(card, {
			label = "Offer to remember",
			hint = "Show the remember switch on each prompt.",
			path = "permissions.remember",
		})

		local rulesLabel = P.text(card, {
			text = "",
			role = "caption",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		rulesLabel.Size = UDim2.new(1, 0, 0, 0)
		local function refreshRules()
			local rules = permissions.listRules()
			if #rules == 0 then
				rulesLabel.Text = "No per-tool rules saved."
				return
			end
			local parts = {}
			for _, rule in ipairs(rules) do
				parts[#parts + 1] = rule.pattern .. " = " .. rule.verdict
			end
			rulesLabel.Text = util.pluralise(#rules, "saved rule") .. ": " .. table.concat(parts, ", ")
		end
		refreshRules()
		local unsubscribe = permissions.changed:connect(function()
			if not rulesLabel.Parent then return end
			refreshRules()
		end)
		rulesLabel.Destroying:Connect(function() pcall(unsubscribe) end)
		R.actions(card, { {
			name = "ClearRules",
			text = "Clear saved rules",
			variant = "ghost",
			onClick = function()
				permissions.clearRules()
				refreshRules()
			end,
		} })
	end

	-- Skills ------------------------------------------------------------------

	local function paneSkills(container)
		local build = builder(container)

		local memory = build.section("Memory",
			"Facts the agent has chosen to keep between sessions. It writes these itself, with "
			.. "the memory tool; this is where they can be read and removed.")
		R.toggle(memory, {
			label = "Enabled",
			hint = "When off, nothing new is stored and nothing is injected.",
			path = "memory.enabled",
		})
		local memoryText = P.text(memory, {
			name = "MemoryList",
			text = "",
			role = "caption",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		memoryText.Size = UDim2.new(1, 0, 0, 0)
		local function refreshMemory()
			local list = state.memoryList()
			if #list == 0 then
				memoryText.Text = "Nothing stored."
				return
			end
			local lines = {}
			for _, entry in ipairs(list) do
				lines[#lines + 1] = entry.key .. ": " .. util.ellipsis(entry.value, 120)
			end
			memoryText.Text = table.concat(lines, "\n")
		end
		refreshMemory()
		local unsubscribe = state.memoryChanged:connect(function()
			if not memoryText.Parent then return end
			refreshMemory()
		end)
		memoryText.Destroying:Connect(function() pcall(unsubscribe) end)
		R.actions(memory, { {
			name = "ForgetEverything",
			text = "Forget everything",
			variant = "ghost",
			onClick = function()
				overlay.confirm({
					title = "Clear memory?",
					description = "Every stored fact is deleted.",
					confirmText = "Clear",
					danger = true,
					onConfirm = function()
						state.clearMemory()
						refreshMemory()
					end,
				})
			end,
		} })

		local host = build.section("Host instructions",
			"A script that embeds this client can add its own instructions and hooks. This is "
			.. "what the current host provided.")
		local hostPrompt = env.context and env.context.prompt
		local hooks = env.require("agent/hooks")
		local hookCounts = {}
		for kind in pairs(hooks.KINDS) do
			local count = hooks.count(kind)
			if count > 0 then hookCounts[#hookCounts + 1] = { key = kind, value = tostring(count) } end
		end
		if type(hostPrompt) == "string" and util.trim(hostPrompt) ~= "" then
			R.paragraph(host, util.ellipsis(hostPrompt, 600), { role = "small", color = theme.color.text })
		else
			R.paragraph(host, "No host instructions: this client was loaded on its own.")
		end
		if #hookCounts > 0 then
			table.sort(hookCounts, function(a, b) return a.key < b.key end)
			R.facts(host, hookCounts, { name = "Hooks" })
		end
	end

	-- Connectors --------------------------------------------------------------

	local function paneConnectors(container)
		local build = builder(container)

		local card = build.section("Inference",
			"Where requests go. A provider is a base URL, an auth style, a key and a model.")
		local list = providers.list()
		if #list == 0 then
			R.paragraph(card, "Nothing configured yet.")
		else
			local facts = {}
			for _, record in ipairs(list) do
				local detail = record.baseUrl
				if util.trim(tostring(record.model or "")) ~= "" then
					detail = record.model .. "  " .. record.baseUrl
				end
				facts[#facts + 1] = {
					key = record.label,
					value = detail,
					tone = (providers.active() or {}).id == record.id and "good" or nil,
				}
			end
			R.facts(card, facts, { name = "Providers" })
		end
		R.actions(card, { {
			name = "OpenInference",
			text = "Configure third-party inference",
			variant = "secondary",
			onClick = function()
				env.require("ui/app").show("providers")
			end,
		} })

		local bridgeCard = build.section("Web bridge",
			"The one connector that is not a model: a browser on this machine sharing the "
			.. "conversation.")
		local status = bridgeModule.status()
		R.facts(bridgeCard, {
			{ key = "State", value = status.running and (status.online and "connected" or "polling") or "off",
				tone = status.running and (status.online and "good" or "warn") or nil },
			{ key = "Address", value = status.url },
		}, { name = "BridgeFacts" })
		R.actions(bridgeCard, { {
			name = "OpenCowork",
			text = "Open Cowork",
			variant = "ghost",
			onClick = function()
				env.require("ui/app").show("cowork")
			end,
		} })
	end

	-- Plugins -----------------------------------------------------------------

	local function panePlugins(container)
		local build = builder(container)
		local card = build.section("Tool groups",
			"A family of tools can be withheld from the model entirely. That is a different "
			.. "thing from denying a call: a tool that is not offered is one the model will not "
			.. "spend a turn discovering it cannot use.")

		for _, group in ipairs(registry.groups()) do
			local row = P.row(card, {
				name = "Group_" .. group.id,
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
			})
			local text = P.column(row, {
				size = UDim2.new(0, 0, 0, 0), auto = "Y", flex = "Fill", gap = 0, layoutOrder = 1,
			})
			P.text(text, { text = group.label, role = "small" })
			local detail = util.pluralise(group.total, "tool")
			if group.unavailable > 0 then
				detail = detail .. ", " .. tostring(group.unavailable) .. " unavailable on this host"
			end
			P.text(text, {
				text = detail,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			local switch = C.switch(row, {
				value = group.enabled,
				onChange = function(value)
					registry.setGroupEnabled(group.id, value)
				end,
			})
			switch.instance.LayoutOrder = 2
		end

		R.actions(card, { {
			name = "OpenTools",
			text = "See every tool",
			variant = "secondary",
			onClick = function()
				env.require("ui/app").show("tools")
			end,
		} })
	end

	-- The list -----------------------------------------------------------------

	-- Grouped the way the reference client groups them. "Agent" is the one section it
	-- does not have, and it is not optional here: the step limit, the context budget
	-- and the permission mode are the settings this client is actually about, and
	-- filing them under Developer to preserve a menu shape would hide them.
	M.PANES = {
		{ id = "general", section = "Settings", label = "General", icon = "gear", build = paneGeneral },
		{ id = "privacy", section = "Settings", label = "Privacy", icon = "worktree", build = paneprivacy },
		{ id = "usage", section = "Settings", label = "Usage", icon = "sliders", build = paneUsage },
		{ id = "claude_code", section = "Settings", label = "Claude Code", icon = "code", build = paneClaudeCode },
		{ id = "cowork", section = "Settings", label = "Cowork", icon = "terminal", build = paneCowork },
		{ id = "import_export", section = "Settings", label = "Import & export", icon = "document", build = paneImportExport },
		{ id = "agent", section = "Agent", label = "Behaviour", icon = "spark", build = paneAgent },
		{ id = "permissions", section = "Agent", label = "Permissions", icon = "check", build = panePermissions },
		{ id = "desktop_general", section = "Desktop app", label = "General", icon = "windowMaximize", build = paneDesktop },
		{ id = "developer", section = "Desktop app", label = "Developer", icon = "terminal", build = paneDeveloper },
		{ id = "skills", section = "Customize", label = "Skills", icon = "book", build = paneSkills },
		{ id = "connectors", section = "Customize", label = "Connectors", icon = "branch", build = paneConnectors },
		{ id = "plugins", section = "Customize", label = "Plugins", icon = "worktree", build = panePlugins },
	}

	function M.pane(id)
		for _, entry in ipairs(M.PANES) do
			if entry.id == id then return entry end
		end
		return nil
	end

	-- The dialog's nav, in declaration order, with the section headings kept.
	function M.sections()
		local out, seen = {}, {}
		for _, entry in ipairs(M.PANES) do
			if not seen[entry.section] then
				seen[entry.section] = { title = entry.section, panes = {} }
				out[#out + 1] = seen[entry.section]
			end
			local group = seen[entry.section]
			group.panes[#group.panes + 1] = entry
		end
		return out
	end

	-- One pane into a container of its own. Used by the dialog when a category is
	-- chosen, and by the Settings panel for every pane in turn.
	function M.render(id, container)
		local entry = M.pane(id)
		if not entry then return false end
		local ok, err = pcall(entry.build, container)
		if not ok then
			log.warn("settings", "the " .. tostring(id) .. " pane failed to build", err)
			R.paragraph(container, "This pane could not be built: " .. tostring(err),
				{ color = theme.color.danger })
		end
		return ok
	end

	return M
end
