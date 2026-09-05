-- Settings.
--
-- Grouped by what the user is trying to change, not by which module owns the value.
-- Every control writes straight to config, which persists itself and republishes --
-- so the theme, the layout and the agent all pick the change up without this panel
-- knowing they exist.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local permissions = env.require("agent/permissions")
	local state = env.require("agent/state")
	local usage = env.require("agent/usage")
	local ua = env.require("net/ua")
	local bridgeModule = env.require("net/bridge")
	local quickchat = env.require("ui/quickchat")

	local M = {}

	function M.new(parent)
		local panel = {}
		local scroll = P.scroll(parent, {
			name = "Settings",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.md,
			padding = theme.space.md,
		})

		local order = 0
		local function nextOrder()
			order = order + 1
			return order
		end

		local function section(title, description)
			P.sectionHeader(scroll.instance, {
				title = title,
				description = description,
				layoutOrder = nextOrder(),
			})
			return P.card(scroll.instance, { layoutOrder = nextOrder(), gap = theme.space.md })
		end

		local function toggle(parentCard, label, hint, path)
			local row = P.row(parentCard, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm })
			local text = P.column(row, { size = UDim2.new(1, -46, 0, 0), auto = "Y", gap = 0, layoutOrder = 1 })
			P.text(text, { text = label, role = "small" })
			P.text(text, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
			local switch = C.switch(row, {
				value = config.get(path, false) == true,
				onChange = function(value) config.set(path, value) end,
			})
			switch.instance.LayoutOrder = 2
			return switch
		end

		-- A million in a 66px monospace field is a wall of zeroes, and the exact digit
		-- is never what the reader is checking at that size.
		local function formatCount(number)
			number = math.floor(number)
			if number >= 1000000 and number % 100000 == 0 then
				local millions = number / 1000000
				return (millions % 1 == 0) and string.format("%dM", millions) or string.format("%.1fM", millions)
			end
			if number >= 1000 and number % 1000 == 0 then return string.format("%dk", number / 1000) end
			return tostring(number)
		end

		-- `min` may be a list of allowed values rather than a bound. Every row that
		-- counts tokens uses one: the range those rows have to cover is three orders of
		-- magnitude, and a linear track across it cannot resolve the low end where the
		-- useful settings are.
		local function numberRow(parentCard, label, hint, path, min, max, step)
			local stops
			if type(min) == "table" then
				stops, min, max, step = min, min[1], min[#min], nil
			end
			local function display(number)
				return (step and step < 1) and string.format("%.2f", number) or formatCount(number)
			end
			local column = P.column(parentCard, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xxs })
			local head = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			local text = P.text(head, {
				text = label,
				role = "small",
				-- Fills rather than reserving 70 for a 66px value plus a 6px gap, which
				-- overlapped it by two pixels.
				size = UDim2.new(0, 0, 0, theme.text.small.height),
				flex = "Fill",
				layoutOrder = 1,
			})
			local value = P.text(head, {
				text = display(tonumber(config.get(path, min)) or min),
				role = "monoSmall",
				color = theme.color.accent,
				align = "Right",
				layoutOrder = 2,
			})
			value.Size = UDim2.fromOffset(66, theme.text.small.size + 4)
			C.slider(column, {
				-- Named after the setting it writes, so the tree says which slider is
				-- which -- eight of them called "Slider" is unreadable from a dump and
				-- unreachable from a test.
				name = "Slider_" .. tostring(path),
				min = min,
				max = max,
				step = step,
				stops = stops,
				value = tonumber(config.get(path, min)) or min,
				onChange = function(number)
					value.Text = display(number)
				end,
				onCommit = function(number)
					config.set(path, (step and step < 1) and util.round(number, 2) or math.floor(number))
				end,
			})
			P.text(column, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
			return column
		end

		-- A row whose stops are words rather than numbers.
		--
		-- A track is still the right control when the values are not numeric: the stops
		-- are ordered and the reader is picking a position on a scale, which a row of
		-- buttons states less clearly. The value reads in the label's own type rather
		-- than numberRow's monospace, because a word set in code font looks like an
		-- identifier, and both ends are named above the track -- what the scale *means*
		-- is the part neither the numbers nor the level names carry.
		local function choiceRow(parentCard, label, hint, path, values, labels, ends)
			local index, stored = 1, tostring(config.get(path, values[1]))
			for position, value in ipairs(values) do
				if value == stored then index = position end
			end
			local stops = {}
			for position = 1, #values do stops[position] = position end

			local column = P.column(parentCard, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xxs })
			local head = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			P.text(head, {
				text = label,
				role = "small",
				size = UDim2.new(0, 0, 0, theme.text.small.height),
				flex = "Fill",
				layoutOrder = 1,
			})
			local value = P.text(head, {
				text = labels[index],
				role = "label",
				color = theme.color.accent,
				align = "Right",
				auto = "X",
				layoutOrder = 2,
			})

			local feet = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			P.text(feet, {
				text = ends[1],
				role = "caption",
				color = theme.color.textTertiary,
				size = UDim2.new(0, 0, 0, theme.text.caption.height),
				flex = "Fill",
				layoutOrder = 1,
			})
			P.text(feet, {
				text = ends[2],
				role = "caption",
				color = theme.color.textTertiary,
				align = "Right",
				auto = "X",
				layoutOrder = 2,
			})
			C.slider(column, {
				name = "Slider_" .. tostring(path),
				stops = stops,
				value = index,
				onChange = function(number)
					value.Text = labels[math.floor(number)] or value.Text
				end,
				onCommit = function(number)
					local position = math.max(math.min(math.floor(number), #values), 1)
					value.Text = labels[position]
					config.set(path, values[position])
				end,
			})
			P.text(column, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
			return column
		end

		-- Appearance -----------------------------------------------------------
		local appearance = section("Appearance",
			"Layout follows the viewport by default. Pin it if you would rather it did not.")

		local accentOptions = {}
		for key, entry in pairs(theme.ACCENTS) do
			accentOptions[#accentOptions + 1] = { value = key, label = entry.label }
		end
		table.sort(accentOptions, function(a, b) return a.label < b.label end)
		P.text(appearance, { text = "Accent", role = "small" })
		C.segmented(appearance, {
			options = accentOptions,
			value = config.get("ui.accent", "aurora"),
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

		numberRow(appearance, "Text scale", "Multiplies every type size.", "ui.fontScale", 0.85, 1.4, 0.05)
		toggle(appearance, "Show reasoning", "Display the model's chain of thought when it sends one. Applies to the conversation already on screen.", "ui.showReasoning")
		toggle(appearance, "Expand tool detail", "Open tool arguments and results by default.", "ui.showToolDetail")

		-- Built here rather than after the Shortcuts section below it, because nothing in
		-- this card sets a layout order: the rows appear in the order they are created,
		-- and a note constructed later landed wherever the tie-break put it.
		local viewportNote = P.text(appearance, {
			text = "Now: " .. responsive.describe(),
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		viewportNote.Size = UDim2.new(1, 0, 0, 0)
		responsive.changed:connect(function()
			viewportNote.Text = "Now: " .. responsive.describe()
		end)

		-- Shortcuts ------------------------------------------------------------
		local shortcuts = section("Shortcuts",
			"Quick chat opens in the middle of the screen, takes one message to the conversation the Chat panel shows, and closes itself.")		do
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
				width = 132,
				layoutOrder = 2,
				onClick = function()
					keyButton.setText("press a key")
					-- Captured rather than typed: a user thinks "this key", and a
					-- character would not survive a different keyboard layout.
					quickchat.captureNext(function(name)
						keyButton.setText(name)
						describeKey()
					end)
				end,
			})
			keyButton.instance.LayoutOrder = 2
			describeKey()
		end

		-- Agent ----------------------------------------------------------------
		--
		-- The three token rows are the only settings here whose sensible value depends
		-- on something outside this client: the window and the output ceiling of
		-- whatever model the active provider is pointed at. They stop where the widest
		-- models of the moment do -- a million in, a hundred and twenty-eight thousand
		-- out -- rather than where a default conversation needs, because a ceiling that
		-- cannot reach the model is indistinguishable from the model not having it.
		local BUDGET_STOPS = {
			4000, 8000, 12000, 16000, 24000, 32000, 48000, 64000, 96000,
			128000, 160000, 200000, 256000, 320000, 400000, 512000, 750000, 1000000,
		}
		local REPLY_STOPS = { 256, 512, 1024, 2048, 4096, 8192, 16000, 24000, 32000, 64000, 96000, 128000 }
		local RESULT_STOPS = { 1000, 2000, 4000, 6000, 8000, 12000, 16000, 24000, 32000, 48000, 64000, 96000, 128000 }

		local agent = section("Agent", "How hard it works before it stops and answers.")
		numberRow(agent, "Step limit", "Tool rounds allowed in one turn, unless the switch below removes it.", "agent.maxTurns", 4, 60, 1)
		toggle(agent, "Unlimited tool calls",
			"Ignore the step limit and the fifteen-minute turn deadline, and keep calling tools until the answer is written. The repeat breaker, each tool's own timeout and Stop still apply, and subagents keep their own budgets.",
			"agent.unlimitedTurns")
		numberRow(agent, "Parallel tools", "Tool calls run at once within one step.", "agent.toolConcurrency", 1, 8, 1)
		numberRow(agent, "Tool timeout",
			"Seconds before a tool is abandoned. Subagents are exempt: they run to their own budget below.",
			"agent.toolTimeout", 5, 60, 1)
		numberRow(agent, "Subagent budget",
			"Seconds one subagent may work for before it wraps up. The call that dispatched it waits this long plus a minute, so a finished report is never thrown away.",
			"agent.subagentBudget", 30, 900, 30)
		numberRow(agent, "Parallel subagents",
			"Subagents alive at once across the whole tree. Several dispatched in one step run together; this is the ceiling on how many, including the ones a subagent starts itself. Anything over it waits for a slot.",
			"agent.subagentConcurrency", 1, 12, 1)
		numberRow(agent, "Context budget",
			"Estimated tokens kept before older turns are summarised. Set it against the model's own window, not this client: a million-token model can hold the whole session.",
			"agent.contextTokens", BUDGET_STOPS)
		numberRow(agent, "Reply ceiling",
			"max_tokens sent with each request. A value above the model's own limit is lowered to whatever the provider names in its refusal, once, and remembered.",
			"agent.maxTokens", REPLY_STOPS)
		numberRow(agent, "Tool result cap",
			"Characters kept from one tool result, roughly four per token. This is the floor on how much a file read or a page fetch can actually return, whatever the tool's own limit says.",
			"agent.resultCap", RESULT_STOPS)
		choiceRow(agent, "Effort",
			"How hard a reasoning model works before it answers. Sent as the provider's " ..
			"effort level and clamped to what the chosen model offers; models without one ignore it.",
			"agent.effort",
			{ "low", "medium", "high", "xhigh", "max" },
			{ "Low", "Medium", "High", "Very high", "Max" },
			{ "Faster", "Smarter" })
		numberRow(agent, "Temperature", "Lower is steadier; 0 is as deterministic as the provider allows. The current Claude models reject it, and it is not sent to them.", "agent.temperature", 0, 1.5, 0.05)
		numberRow(agent, "Retries", "Attempts per provider before moving to the next.", "agent.retries", 1, 6, 1)
		toggle(agent, "Ask for streams", "Streamed replies carry reasoning text and usage counts.", "agent.stream")
		toggle(agent, "Summarise old turns", "Keeps a long conversation inside the context budget.", "agent.compaction")
		toggle(agent, "Provider fallback", "Try the next enabled provider when one fails.", "agent.fallback")

		-- Permissions ----------------------------------------------------------
		local permission = section("Permissions", permissions.MODE_HINTS[permissions.mode()])
		local modeOptions = {}
		for _, mode in ipairs(permissions.MODES) do
			modeOptions[#modeOptions + 1] = { value = mode, label = permissions.MODE_LABELS[mode] or mode }
		end
		local modeHint
		C.segmented(permission, {
			options = modeOptions,
			value = permissions.mode(),
			onChange = function(value)
				permissions.setMode(value)
				if modeHint then modeHint.Text = permissions.MODE_HINTS[value] or "" end
			end,
		})
		modeHint = P.text(permission, {
			text = permissions.MODE_HINTS[permissions.mode()] or "",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		modeHint.Size = UDim2.new(1, 0, 0, 0)

		toggle(permission, "Offer to remember", "Show the remember switch on each prompt.", "permissions.remember")

		local rulesLabel = P.text(permission, {
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
		permissions.changed:connect(refreshRules)
		P.button(permission, {
			text = "Clear saved rules",
			variant = "ghost",
			size = "sm",
			onClick = function()
				permissions.clearRules()
				refreshRules()
			end,
		})

		-- Identity -------------------------------------------------------------
		local identity = section("Client identity",
			"Requests are sent as the Claude Code CLI. Gateways that gate on it accept them; others ignore the extra headers.")
		toggle(identity, "Send the Claude Code identity", "Applies to every inference request.", "identity.claudeUa")
		P.field(identity, {
			text = config.get("identity.version", ua.DEFAULT_VERSION),
			placeholder = ua.DEFAULT_VERSION,
			onBlur = function(text)
				config.set("identity.version", util.trim(text) ~= "" and util.trim(text) or ua.DEFAULT_VERSION)
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
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		identityText.Size = UDim2.new(1, 0, 0, 0)
		config.changed:connect(function(path)
			if path == nil or util.startsWith(tostring(path), "identity.") then
				identityText.Text = ua.describe()
			end
		end)

		if not caps.uaSupported then
			local warning = P.text(identity, {
				text = "This host has no executor HTTP function, so Roblox sends its own User-Agent and drops ours. Everything else still works.",
				role = "caption",
				color = theme.color.warn,
				wrap = true,
				auto = "Y",
			})
			warning.Size = UDim2.new(1, 0, 0, 0)
		end

		-- Memory ---------------------------------------------------------------
		local memory = section("Memory", "Facts the agent has chosen to keep between sessions.")
		toggle(memory, "Enabled", "When off, nothing new is stored and nothing is injected.", "memory.enabled")
		local memoryText = P.text(memory, {
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
		state.memoryChanged:connect(refreshMemory)
		P.button(memory, {
			text = "Forget everything",
			variant = "ghost",
			size = "sm",
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
		})

		-- Web bridge ------------------------------------------------------------
		local webBridge = section("Web bridge",
			"Chat from a browser on this machine. Run bridge/server.js, paste its token below, and the browser joins whichever conversation is open here.")
		toggle(webBridge, "Enabled", "Polls the local bridge for messages typed in the browser.", "bridge.enabled")

		P.text(webBridge, { text = "Port", role = "small" })
		P.field(webBridge, {
			text = tostring(config.get("bridge.port", 8790)),
			placeholder = "8790",
			onBlur = function(text)
				local port = tonumber(util.trim(text))
				config.set("bridge.port", (port and port > 0 and port < 65536) and math.floor(port) or 8790)
			end,
		})

		P.text(webBridge, { text = "Token", role = "small" })
		P.field(webBridge, {
			text = tostring(config.get("bridge.token", "")),
			placeholder = "paste from the bridge console",
			onBlur = function(text) config.set("bridge.token", util.trim(text)) end,
		})

		local bridgeState = P.text(webBridge, {
			text = "",
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		bridgeState.Size = UDim2.new(1, 0, 0, 0)

		local function describeBridge()
			local status = bridgeModule.status()
			if not status.running then return "Off. Nothing is listening and nothing is polled." end
			if status.online then return "Connected to " .. status.url .. ". Open it in a browser." end
			return "Polling " .. status.url .. " -- " .. (status.error or "no answer yet") ..
				". Is bridge/server.js running?"
		end

		bridgeState.Text = describeBridge()
		bridgeModule.changed:connect(function() bridgeState.Text = describeBridge() end)

		-- Session --------------------------------------------------------------
		local session = section("This session", usage.line())
		local usageText = P.text(session, {
			text = usage.line(),
			role = "monoSmall",
			color = theme.color.textSecondary,
			wrap = true,
			auto = "Y",
		})
		usageText.Size = UDim2.new(1, 0, 0, 0)
		usage.changed:connect(function() usageText.Text = usage.line() end)
		P.button(session, {
			text = "Reset counters",
			variant = "ghost",
			size = "sm",
			onClick = function() usage.reset() end,
		})
		P.button(session, {
			text = "Reset all settings",
			variant = "danger",
			size = "sm",
			onClick = function()
				overlay.confirm({
					title = "Reset every setting?",
					description = "Providers, rules and memory are kept. Appearance and agent settings go back to defaults.",
					confirmText = "Reset",
					danger = true,
					onConfirm = function()
						config.reset("ui")
						config.reset("agent")
						overlay.toast("Settings reset", "good")
					end,
				})
			end,
		})

		P.button(session, {
			text = "Unload UAI",
			variant = "danger",
			size = "sm",
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
							-- No global table on this host: do what can be done from here.
							env.require("runtime/dispose").drain()
							pcall(function() env.require("ui/app").screen:Destroy() end)
						end
					end,
				})
			end,
		})

		panel.scroll = scroll
		return panel
	end

	return M
end
