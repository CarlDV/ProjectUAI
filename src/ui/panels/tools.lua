-- Tools panel: what the agent can do here, and what it is allowed to do.
--
-- Permission rules live next to the tool they govern rather than in a separate
-- list, because "can it delete files" is a question about file_delete, not about a
-- rules table.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local registry = env.require("agent/registry")
	local permissions = env.require("agent/permissions")
	local schema = env.require("agent/schema")

	local M = {}

	local RULE_OPTIONS = {
		{ value = "default", label = "Default" },
		{ value = "allow", label = "Allow" },
		{ value = "ask", label = "Ask" },
		{ value = "deny", label = "Deny" },
	}

	local GROUP_LABELS = {
		agentself = "Agent",
		instance = "Instance tree",
		script = "Code",
		fs = "Files",
		net = "HTTP",
		web = "Web",
		players = "Players",
		character = "Character",
		world = "World",
		remotes = "Remotes",
		gui = "Interface",
		perf = "Diagnostics",
		meta = "Metadata",
	}

	function M.new(parent)
		local panel = {}
		local filter = ""

		local column = P.column(parent, {
			name = "ToolsPanel",
			size = UDim2.new(1, 0, 1, 0),
			gap = 0,
		})

		local head = P.column(column, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			padding = { x = theme.space.md, top = theme.space.md, bottom = theme.space.sm },
			layoutOrder = 1,
		})

		local stats = registry.stats()
		P.text(head, {
			text = string.format("%d tools in %d groups", stats.total, util.count(stats.byGroup)),
			role = "heading",
		})
		local summary = P.text(head, {
			text = string.format("%d unavailable on this host: %s",
				#stats.unavailable,
				#stats.unavailable > 0 and caps.summary() or "everything is available"),
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
		})
		summary.Size = UDim2.new(1, 0, 0, 0)

		local searchField
		local scroll

		local function rebuild()
			scroll.clear()
			local needle = filter:lower()
			local grouped = {}
			for _, tool in ipairs(registry.list()) do
				if needle == ""
					or tool.name:lower():find(needle, 1, true)
					or tostring(tool.description):lower():find(needle, 1, true) then
					grouped[tool.group] = grouped[tool.group] or {}
					table.insert(grouped[tool.group], tool)
				end
			end

			local order = util.keys(grouped, true)
			if #order == 0 then
				C.emptyState(scroll.instance, {
					title = "No tool matches",
					description = "Try a shorter search.",
					layoutOrder = 1,
				})
				return
			end

			local position = 0
			for _, group in ipairs(order) do
				position = position + 1
				P.sectionHeader(scroll.instance, {
					title = GROUP_LABELS[group] or group,
					layoutOrder = position,
				})

				for _, tool in ipairs(grouped[group]) do
					position = position + 1
					local missing = registry.missingCapability(tool)
					local card = P.card(scroll.instance, {
						name = tool.name,
						layoutOrder = position,
						gap = theme.space.xs,
					})

					local top = P.row(card, {
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.xs,
						layoutOrder = 1,
					})
					local name = P.text(top, {
						text = tool.name,
						role = "monoSmall",
						color = missing and theme.color.textDisabled or theme.color.text,
						layoutOrder = 1,
					})
					name.Size = UDim2.fromOffset(0, theme.text.monoSmall.size + 4)
					name.AutomaticSize = Enum.AutomaticSize.X

					P.badge(top, {
						text = tool.risk,
						tone = tool.risk == "read" and "info" or (tool.risk == "danger" and "bad" or "warn"),
						layoutOrder = 2,
					})
					if missing then
						P.badge(top, { text = "unavailable", tone = "warn", layoutOrder = 3 })
					end

					local description = P.text(card, {
						text = tostring(tool.description),
						role = "caption",
						color = theme.color.textSecondary,
						wrap = true,
						auto = "Y",
						layoutOrder = 2,
					})
					description.Size = UDim2.new(1, 0, 0, 0)

					local params = P.text(card, {
						text = schema.describe(tool.parameters),
						role = "caption",
						color = theme.color.textTertiary,
						wrap = true,
						auto = "Y",
						layoutOrder = 3,
					})
					params.Size = UDim2.new(1, 0, 0, 0)

					if missing then
						local reason = P.text(card, {
							text = caps.reason(missing),
							role = "caption",
							color = theme.color.warn,
							wrap = true,
							auto = "Y",
							layoutOrder = 4,
						})
						reason.Size = UDim2.new(1, 0, 0, 0)
					else
						C.segmented(card, {
							options = RULE_OPTIONS,
							value = permissions.ruleFor(tool.name) or "default",
							layoutOrder = 4,
							onChange = function(value)
								permissions.setRule(tool.name, value)
							end,
						})
					end
				end
			end
		end

		searchField = P.field(head, {
			placeholder = "Search tools",
			onChange = function(text)
				filter = util.trim(text)
				rebuild()
			end,
		})

		scroll = P.scroll(column, {
			name = "ToolList",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.sm,
			padding = { x = theme.space.md, bottom = theme.space.md },
			layoutOrder = 2,
		})
		local flex = Instance.new("UIFlexItem", scroll.instance)
		flex.FlexMode = Enum.UIFlexMode.Fill

		rebuild()
		panel.refresh = rebuild
		panel.unsubscribe = permissions.changed:connect(rebuild)
		return panel
	end

	return M
end
