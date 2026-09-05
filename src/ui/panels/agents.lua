-- Subagents: what has been delegated, what is still running, and the ceilings.
--
-- A dispatch is the longest-lived and least visible thing this client does. It runs
-- for minutes on its own context, calls its own tools, and the only trace of it was a
-- card in one conversation's transcript -- which scrolls away, belongs to whichever
-- conversation started it, and offered no way to stop one child without stopping the
-- whole turn. Three subagents working at once were three spinners in three places.
--
-- So this panel is the register: every dispatch in this session, running ones first,
-- with what it was asked to do, where it came from, what it has called, and a stop for
-- each. Nothing here is computed for display -- it is `agent/subagent`'s own record.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local subagent = env.require("agent/subagent")
	local registry = env.require("agent/registry")

	local M = {}

	local STATUS = {
		queued = { label = "waiting for a slot", colour = "warn" },
		running = { label = "working", colour = "accent" },
		done = { label = "reported back", colour = "success" },
		stopped = { label = "stopped", colour = "warn" },
		failed = { label = "failed", colour = "danger" },
	}

	local function isLive(record)
		return record.status == "running" or record.status == "queued"
	end

	-- What a preset actually grants, in the group names the Tools panel uses. `full` is
	-- the absence of a filter rather than a list, which is worth saying in those words:
	-- it is the one preset that can change the game.
	local function describePreset(id)
		local groups = subagent.PRESETS[id]
		if groups == nil then return "every tool this client has" end
		local names = {}
		for group in pairs(groups) do names[#names + 1] = registry.groupLabel(group) end
		table.sort(names)
		return table.concat(names, ", ")
	end

	function M.new(parent)
		local panel = {}

		local scroll = P.scroll(parent, {
			name = "Agents",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.md,
			padding = theme.space.md,
		})

		P.sectionHeader(scroll.instance, {
			title = "Subagents",
			description = "The agent hands self-contained work to a subagent with dispatch_agent: "
				.. "its own context, a subset of the tools, and a written report at the end. "
				.. "Everything dispatched in this session is here, whichever conversation started it.",
			layoutOrder = 1,
		})

		-- Capacity ------------------------------------------------------------

		local capacityCard = P.card(scroll.instance, { layoutOrder = 2, gap = theme.space.sm })
		local capacityRow = P.row(capacityCard, {
			name = "Capacity",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 1,
		})
		local capacityText = P.text(capacityRow, {
			name = "CapacityText",
			text = "",
			role = "small",
			color = theme.color.text,
			wrap = true,
			auto = "Y",
			size = UDim2.new(0, 0, 0, 0),
			flex = "Fill",
			layoutOrder = 1,
		})
		local stopAll = P.button(capacityRow, {
			name = "StopAll",
			text = "Stop all",
			variant = "danger",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				local stopped = subagent.stopAll()
				overlay.toast(stopped == 0 and "Nothing was running"
					or ("Stopping " .. util.pluralise(stopped, "subagent")), "info", 2)
			end,
		})
		stopAll.instance.LayoutOrder = 2
		local capacityBar = C.progress(capacityCard, { value = 0, layoutOrder = 2 })
		local capacityHint = P.text(capacityCard, {
			name = "CapacityHint",
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = 3,
		})

		-- The register --------------------------------------------------------

		local list = P.column(scroll.instance, {
			name = "Dispatches",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			layoutOrder = 3,
		})

		-- Declared here, defined with the card it draws into. The redraw covers both,
		-- and the card is built below the list it sits under.
		local renderLimits = function() end

		local function reportModal(record)
			local modal = overlay.modal({
				title = record.label,
				description = string.format("%s  \194\183  %s  \194\183  %s%s",
					(STATUS[record.status] or STATUS.done).label,
					record.ms and util.formatDuration(record.ms) or "",
					util.pluralise(record.calls or 0, "tool call"),
					(record.runs or 1) > 1
						and ("  \194\183  " .. util.pluralise(record.runs, "turn")) or ""),
				width = theme.size.modalWide,
			})
			if not modal then return end
			-- The id, because it is the handle the agent addresses a follow-up to. Reading
			-- it here is how you can tell from the transcript which dispatch a follow-up
			-- went to when three of them are open.
			C.keyValue(modal.content, {
				key = "Id",
				value = tostring(record.id),
				role = "monoSmall",
				layoutOrder = 1,
			})
			C.keyValue(modal.content, { key = "Task", value = record.task, layoutOrder = 2 })
			C.keyValue(modal.content, {
				key = "Tools",
				value = describePreset(record.preset),
				layoutOrder = 3,
			})
			if #(record.tools or {}) > 0 then
				C.keyValue(modal.content, {
					key = "Called",
					value = table.concat(record.tools, ", "),
					role = "monoSmall",
					layoutOrder = 4,
				})
			end
			C.keyValue(modal.content, {
				key = "Report",
				value = util.trim(tostring(record.report or "")) ~= "" and record.report
					or "Nothing was reported.",
				layoutOrder = 5,
			})
			P.button(modal.footer, {
				text = "Close",
				variant = "primary",
				size = "sm",
				layoutOrder = 1,
				onClick = function() modal.close() end,
			})
		end

		local function renderRecord(record, order)
			local live = isLive(record)
			local status = STATUS[record.status] or STATUS.done
			local card = P.card(list, { layoutOrder = order, gap = theme.space.xs })

			local head = P.row(card, {
				name = "Head",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 1,
			})
			if live then
				C.spinner(head, { diameter = theme.size.icon, layoutOrder = 1 })
			else
				local slot = P.frame(head, {
					name = "DotSlot",
					size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
					layoutOrder = 1,
				})
				P.statusDot(slot, {
					diameter = theme.size.dot,
					color = theme.color[status.colour],
					anchor = Vector2.new(0.5, 0.5),
					position = UDim2.fromScale(0.5, 0.5),
				})
			end
			P.text(head, {
				name = "Label",
				text = record.label,
				role = "small",
				color = theme.color.text,
				truncate = true,
				size = UDim2.new(0, 0, 0, theme.text.small.height),
				flex = "Fill",
				layoutOrder = 2,
			})
			local elapsed = record.ms or clock.since(record.startedAt or clock.ms())
			P.text(head, {
				name = "Elapsed",
				text = elapsed >= 1000 and util.formatDuration(elapsed) or "",
				role = "caption",
				color = theme.color.textTertiary,
				align = "Right",
				size = UDim2.fromOffset(theme.size.metaColumn, theme.text.small.height),
				layoutOrder = 3,
			})

			-- One line of provenance. Which conversation asked, how deep it sits, and
			-- what it is allowed to touch: none of that is on the transcript card, and
			-- all three decide whether a dispatch is worth stopping.
			local facts = {
				record.stopping and "stopping" or status.label,
				record.preset .. " tools",
			}
			if (record.depth or 1) > 1 then
				facts[#facts + 1] = "depth " .. tostring(record.depth)
			end
			if record.parentTitle then facts[#facts + 1] = "from " .. record.parentTitle end
			if record.unlimited then facts[#facts + 1] = "unlimited" end
			if (record.runs or 1) > 1 then
				facts[#facts + 1] = util.pluralise(record.runs, "turn")
			end
			if (record.calls or 0) > 0 then
				facts[#facts + 1] = string.format("%d of %s",
					record.finishedCalls or 0, util.pluralise(record.calls, "call"))
			end
			if record.messages then
				facts[#facts + 1] = util.pluralise(record.messages, "message")
			end
			-- Whether the agent can still talk to this one. A finished dispatch keeps its
			-- context for a while, and a follow-up into it is the cheapest thing here --
			-- so which ones are still open is worth a word.
			if not live and record.session then
				facts[#facts + 1] = "open for a follow-up"
			end
			local detail = P.text(card, {
				name = "Facts",
				text = table.concat(facts, "  \194\183  "),
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 2,
			})
			detail.TextColor3 = live and theme.color.textSecondary or theme.color.textTertiary

			-- What it is doing now, or what it said at the end.
			local note = live and (record.currentTool
					and ("running " .. record.currentTool)
					or record.statusText)
				or util.trim(tostring(record.report or ""))
			if note and util.trim(note) ~= "" then
				P.text(card, {
					name = "Note",
					text = util.ellipsis(tostring(note):gsub("%s+", " "), 220),
					role = live and "caption" or "small",
					color = record.status == "failed" and theme.color.danger
						or theme.color.textSecondary,
					wrap = true,
					auto = "Y",
					layoutOrder = 3,
				})
			end

			local actions = P.row(card, {
				name = "Actions",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 4,
			})
			P.spacer(actions, { grow = true, layoutOrder = 1 })
			P.button(actions, {
				name = "Open",
				text = "Details",
				variant = "ghost",
				size = "sm",
				layoutOrder = 2,
				onClick = function() reportModal(record) end,
			})
			if live then
				P.button(actions, {
					name = "Stop",
					text = record.stopping and "Stopping" or "Stop",
					variant = "danger",
					size = "sm",
					layoutOrder = 3,
					onClick = function()
						if subagent.stop(record.id) then
							-- It stops between steps, not on the instant: saying so is the
							-- difference between a slow control and a broken one.
							overlay.toast("Asked it to stop. It finishes the step it is on.",
								"info", 3)
						end
					end,
				})
			end
			return card
		end

		local function render()
			for _, child in ipairs(list:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			renderLimits()

			local records = subagent.list()
			local running = #subagent.running()
			local ceiling = subagent.concurrencyLimit()

			capacityText.Text = running == 0
				and "Nothing is delegated right now."
				or string.format("%d of %d slots in use", running, ceiling)
			capacityBar.set(ceiling > 0 and (running / ceiling) or 0)
			if subagent.unlimited() then
				capacityHint.Text = string.format(
					"Subagents run unlimited: no step limit, no clock, and the call that dispatched one "
					.. "waits as long as it takes. Anything over the ceiling waits for a slot; a subagent "
					.. "may dispatch its own up to %s deep. Stop is the bound that still applies.",
					util.pluralise(tonumber(config.get("agent.subagentDepth", 2)) or 2, "level"))
			else
				capacityHint.Text = string.format(
					"Each one may work for %s and take up to %s. Anything over the ceiling waits for a slot; "
					.. "a subagent may dispatch its own up to %s deep.",
					util.formatDuration(subagent.budgetSeconds() * 1000),
					util.pluralise(tonumber(config.get("agent.subagentTurns", 14)) or 14, "step"),
					util.pluralise(tonumber(config.get("agent.subagentDepth", 2)) or 2, "level"))
			end
			stopAll.instance.Visible = running > 0

			if #records == 0 then
				C.emptyState(list, {
					title = "No subagents yet",
					description = "When the agent delegates -- a wide search, a sweep of the instance "
						.. "tree, anything repetitive -- the dispatch shows up here while it works "
						.. "and stays afterwards with its report.",
					layoutOrder = 1,
				})
				return
			end

			for index, record in ipairs(records) do
				renderRecord(record, index)
			end
		end

		-- Limits --------------------------------------------------------------

		-- Stated here, changed in Settings. Both surfaces read the same four keys, and a
		-- slider is built with the value it had at build time -- so a second set of
		-- sliders here would sit next to the first and be able to disagree with it. The
		-- facts are redrawn with the list, so what this says is always what is in force.
		local limits = P.card(scroll.instance, { layoutOrder = 4, gap = theme.space.sm })
		P.text(limits, {
			name = "LimitsTitle",
			text = "Limits",
			role = "label",
			color = theme.color.textSecondary,
			layoutOrder = 1,
		})
		local limitFacts = P.column(limits, {
			name = "LimitFacts",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.xxs,
			layoutOrder = 2,
		})
		P.button(limits, {
			name = "OpenAgentSettings",
			text = "Change these",
			variant = "secondary",
			size = "sm",
			layoutOrder = 3,
			onClick = function()
				env.require("ui/app").showSettingsDialog("agent")
			end,
		})

		local function renderLimitsInto()
			for _, child in ipairs(limitFacts:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
			-- The button's own layout order is stated above; a P.card is a column, so the
			-- facts sit between the title and it.
			local unlimited = subagent.unlimited()
			local rows = {
				{
					key = "Budget",
					value = unlimited
						and "no clock -- a subagent runs until it answers, and the call that started it waits"
						or (util.formatDuration(subagent.budgetSeconds() * 1000)
							.. " of work each, then it wraps up"),
				},
				{
					key = "At once",
					value = util.pluralise(subagent.concurrencyLimit(), "subagent")
						.. " across the whole tree; the rest wait for a slot",
				},
				{
					key = "Steps",
					value = unlimited
						and "no limit -- only the repeat breaker and Stop end a run"
						or (util.pluralise(tonumber(config.get("agent.subagentTurns", 14)) or 14, "tool round")
							.. " before it has to answer with what it has"),
				},
				{
					key = "Depth",
					value = (function()
						local depth = tonumber(config.get("agent.subagentDepth", 2)) or 2
						if depth <= 0 then
							return "delegation is off -- the agent does the work in the conversation"
						end
						return util.pluralise(depth, "level") .. " of delegation"
					end)(),
				},
				{
					key = "Follow-ups",
					value = "the agent can send a finished subagent another message with agent_followup; "
						.. "the newest few keep their context for it",
				},
			}
			for index, row in ipairs(rows) do
				C.keyValue(limitFacts, {
					key = row.key,
					value = row.value,
					color = theme.color.textSecondary,
					layoutOrder = index,
				})
			end
		end

		-- Now that the card exists, the forward declaration points at the real one.
		renderLimits = renderLimitsInto

		-- Presets -------------------------------------------------------------

		local presets = P.card(scroll.instance, { layoutOrder = 5, gap = theme.space.xs })
		P.text(presets, {
			name = "PresetsTitle",
			text = "What a subagent is given",
			role = "label",
			color = theme.color.textSecondary,
			layoutOrder = 1,
		})
		P.text(presets, {
			name = "PresetsHint",
			text = "The model picks one of these per dispatch. 'read' is the default and cannot "
				.. "change anything; a delegated write is hard to attribute afterwards, which is "
				.. "why it has to be asked for.",
			role = "caption",
			color = theme.color.textTertiary,
			wrap = true,
			auto = "Y",
			layoutOrder = 2,
		})
		local presetOrder = { "read", "web", "game", "full" }
		for index, id in ipairs(presetOrder) do
			C.keyValue(presets, {
				key = id,
				value = describePreset(id),
				color = id == "full" and theme.color.warn or theme.color.textSecondary,
				layoutOrder = index + 2,
			})
		end

		render()

		-- Live. The register changes on every tool call a child makes, so the redraw is
		-- debounced rather than throttled: a leading-edge throttle drops the last change
		-- in a burst, and the last change is the one that says it finished -- the panel
		-- kept a record on screen as running after it had reported back. The clock on a
		-- running card needs a tick of its own, and stops costing anything once nothing
		-- is running.
		local redraw = clock.debounce(function()
			if not scroll.instance.Parent then return end
			render()
		end, 0.2)
		local unsubscribe = subagent.changed:connect(redraw)
		local stop = clock.interval(0.5, function()
			if not scroll.instance.Parent then return end
			if #subagent.running() == 0 then return end
			render()
		end)
		scroll.instance.Destroying:Connect(function()
			pcall(unsubscribe)
			pcall(stop)
		end)

		panel.scroll = scroll
		panel.render = render
		return panel
	end

	return M
end
