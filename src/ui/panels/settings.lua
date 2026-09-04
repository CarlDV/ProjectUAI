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

		local function numberRow(parentCard, label, hint, path, min, max, step)
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
				text = tostring(config.get(path, min)),
				role = "monoSmall",
				color = theme.color.accent,
				align = "Right",
				layoutOrder = 2,
			})
			value.Size = UDim2.fromOffset(66, theme.text.small.size + 4)
			C.slider(column, {
				min = min,
				max = max,
				step = step,
				value = tonumber(config.get(path, min)) or min,
				onChange = function(number)
					value.Text = (step and step < 1) and string.format("%.2f", number) or tostring(math.floor(number))
				end,
				onCommit = function(number)
					config.set(path, (step and step < 1) and util.round(number, 2) or math.floor(number))
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
		toggle(appearance, "Show reasoning", "Display the model's chain of thought when it sends one.", "ui.showReasoning")
		toggle(appearance, "Expand tool detail", "Open tool arguments and results by default.", "ui.showToolDetail")

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

		-- Agent ----------------------------------------------------------------
		local agent = section("Agent", "How hard it works before it stops and answers.")
		numberRow(agent, "Step limit", "Tool rounds allowed in one turn.", "agent.maxTurns", 4, 60, 1)
		numberRow(agent, "Parallel tools", "Tool calls run at once within one step.", "agent.toolConcurrency", 1, 8, 1)
		numberRow(agent, "Tool timeout", "Seconds before a tool is abandoned.", "agent.toolTimeout", 5, 60, 1)
		numberRow(agent, "Context budget", "Estimated tokens kept before older turns are summarised.", "agent.contextTokens", 4000, 120000, 1000)
		numberRow(agent, "Reply ceiling", "max_tokens sent with each request.", "agent.maxTokens", 256, 16000, 256)
		numberRow(agent, "Temperature", "Lower is steadier; 0 is as deterministic as the provider allows.", "agent.temperature", 0, 1.5, 0.05)
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

		panel.scroll = scroll
		return panel
	end

	return M
end
