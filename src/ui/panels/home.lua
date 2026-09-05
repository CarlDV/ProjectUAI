-- The home card: the greeting, the activity summary and the contribution grid.
--
-- Every number on this surface is read from agent/stats, which counts what the
-- client actually observed. There are no placeholders here and no sample data: a
-- figure with nothing behind it is rendered as a zero and the card says why, because
-- an invented number on a dashboard is worse than an empty one -- it cannot be told
-- from a real one.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local stats = env.require("agent/stats")

	local M = {}

	-- How much of the grid fits. Twenty-six weeks is six months and is what the card
	-- is designed around, but a cell is a fixed eleven pixels and the card is only as
	-- wide as the window: at 340 the full grid is seventy pixels wider than the space
	-- it has, and a grid that overflows is clipped rather than scaled.
	local function heatmapWeeks()
		if responsive.mode == "sheet" then return 13 end
		if responsive.mode == "panel" then return 18 end
		return 26
	end

	-- Four tiles to a row on anything with room, two on a phone. Eight tiles of a
	-- quarter width each on a 276px card leaves 53px for "Longest streak".
	local function tilesPerRow()
		if responsive.mode == "sheet" then return 2 end
		return 4
	end

	local function levelColour(level)
		if level >= 4 then return theme.color.activityBlueDark end
		if level >= 3 then return theme.color.activityBlue end
		if level >= 2 then return theme.color.activityBlueLight end
		if level >= 1 then return theme.color.accentMuted end
		return theme.color.activityCell
	end

	-- The four sentences a cell can say, all of them about a real day.
	local function describeCell(cell, todayKey)
		local when = clock.describeDay(cell.key, todayKey)
		if not cell.active then
			return when .. " -- nothing recorded", "info"
		end
		local parts = {}
		if cell.messages > 0 then parts[#parts + 1] = util.pluralise(cell.messages, "message") end
		if cell.requests > 0 then parts[#parts + 1] = util.pluralise(cell.requests, "request") end
		if cell.tokens > 0 then parts[#parts + 1] = util.formatCompact(cell.tokens) .. " tokens" end
		return when .. " -- " .. table.concat(parts, ", "), "good"
	end

	-- One metric. The tile shows the short form; the exact figure and what it counts
	-- live in the Usage pane, which is where the click goes.
	local function tile(parent, spec, order, perRow)
		local holder = P.rowButton(parent, {
			name = "Metric_" .. tostring(spec.key),
			vertical = true,
			-- The gap is shared out across the tiles rather than subtracted whole from
			-- each: n children of (W/n - g) plus (n-1) gaps comes to W - g, so the row
			-- stopped a gap short of the well it sits in and the right edge never lined up
			-- with the card above it. The share is (n-1)/n of one gap per tile.
			size = UDim2.new(1 / (perRow or 4),
				-math.floor(theme.space.hair * ((perRow or 4) - 1) / (perRow or 4)),
				0, theme.size.statTile),
			height = theme.size.statTile,
			bg = theme.color.surfaceRaised,
			radius = theme.radius.none,
			gap = theme.space.hair,
			padding = { x = theme.space.sm, y = theme.space.xs },
			alignY = "Center",
			layoutOrder = order,
			onClick = function()
				env.require("ui/app").showSettingsDialog("usage")
			end,
		})
		P.text(holder.row, {
			name = "Title",
			text = spec.label,
			role = "caption",
			color = theme.color.textTertiary,
			truncate = true,
			size = UDim2.new(1, 0, 0, theme.text.caption.height),
			layoutOrder = 1,
		})
		P.text(holder.row, {
			name = "Value",
			text = spec.value,
			role = "title",
			color = spec.tone or theme.color.text,
			truncate = true,
			size = UDim2.new(1, 0, 0, theme.text.title.height),
			layoutOrder = 2,
		})
		return holder
	end

	-- A small pill that is either the selected one or not. Used for both the tab pair
	-- and the range triple, because they are the same control with different contents.
	local function pill(parent, label, selected, order, onClick)
		local handle = P.rowButton(parent, {
			name = "Pill_" .. tostring(label),
			auto = "X",
			height = theme.size.chip,
			size = UDim2.fromOffset(0, theme.size.chip),
			bg = selected and theme.color.surfaceActive or nil,
			radius = theme.radius.sm,
			padding = { x = theme.space.sm },
			selected = selected,
			onClick = onClick,
		})
		P.text(handle.row, {
			text = label,
			role = "caption",
			color = selected and theme.color.text or theme.color.textTertiary,
			auto = "X",
			layoutOrder = 1,
		})
		return handle
	end

	-- The eight figures the overview shows, in the order the reference client puts
	-- them in. Each one names the window it was computed over, because "4 active days"
	-- means something different under All than under 7d.
	local function overviewTiles(window)
		local model = window.topModel
		local modelName = "--"
		if model then modelName = model.id end
		local peak = "--"
		if window.peakHour then peak = clock.describeHour(window.peakHour) end
		return {
			{ key = "sessions", label = "Sessions", value = util.formatNumber(window.sessions) },
			{ key = "messages", label = "Messages", value = util.formatNumber(window.messages) },
			{ key = "tokens", label = "Total tokens", value = util.formatCompact(window.tokens) },
			{ key = "days", label = "Active days", value = util.formatNumber(window.activeDays) },
			{ key = "streak", label = "Current streak", value = tostring(window.currentStreak) .. "d" },
			{ key = "longest", label = "Longest streak", value = tostring(window.longestStreak) .. "d" },
			{ key = "peak", label = "Peak hour", value = peak },
			{ key = "model", label = "Favorite model", value = modelName },
		}
	end

	local function buildOverview(parent, window)
		local box = P.column(parent, {
			name = "MetricsBox",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.md,
			padding = theme.space.hair,
			layoutOrder = 1,
		})
		P.stroke(box, theme.color.borderSubtle)

		local specs = overviewTiles(window)
		local perRow = tilesPerRow()
		local rows = math.ceil(#specs / perRow)
		for rowIndex = 1, rows do
			local row = P.row(box, {
				name = "MetricRow" .. tostring(rowIndex),
				size = UDim2.new(1, 0, 0, theme.size.statTile),
				gap = theme.space.hair,
				layoutOrder = rowIndex,
			})
			for column = 1, perRow do
				local spec = specs[(rowIndex - 1) * perRow + column]
				if spec then tile(row, spec, column, perRow) end
			end
		end
		return box
	end

	local function buildModels(parent, window)
		local box = P.column(parent, {
			name = "ModelsBox",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.hair,
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.md,
			padding = theme.space.hair,
			layoutOrder = 1,
		})
		P.stroke(box, theme.color.borderSubtle)

		if #window.models == 0 then
			local empty = P.text(box, {
				name = "NoModels",
				text = "No requests recorded in this window. A model appears here once it has answered something.",
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				padding = { x = theme.space.sm, y = theme.space.sm },
				layoutOrder = 1,
			})
			empty.Size = UDim2.new(1, 0, 0, 0)
			return box
		end

		for index, row in ipairs(window.models) do
			local entry = P.column(box, {
				name = "Model_" .. tostring(index),
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				bg = theme.color.surfaceRaised,
				gap = theme.space.hair,
				padding = { x = theme.space.sm, y = theme.space.xs },
				layoutOrder = index,
			})
			local head = P.row(entry, {
				size = UDim2.new(1, 0, 0, theme.text.small.height),
				gap = theme.space.xs,
				layoutOrder = 1,
			})
			P.text(head, {
				name = "Id",
				text = row.id,
				role = "small",
				color = theme.color.text,
				truncate = true,
				size = UDim2.new(0, 0, 0, theme.text.small.height),
				flex = "Fill",
				layoutOrder = 1,
			})
			P.text(head, {
				name = "Share",
				text = string.format("%d%%", math.floor((row.share or 0) * 100 + 0.5)),
				role = "monoSmall",
				color = theme.color.accent,
				align = "Right",
				auto = "X",
				layoutOrder = 2,
			})

			local track = P.frame(entry, {
				name = "Bar",
				size = UDim2.new(1, 0, 0, theme.size.track),
				bg = theme.color.surfaceActive,
				radius = theme.radius.pill,
				layoutOrder = 2,
			})
			P.frame(track, {
				name = "Fill",
				size = UDim2.fromScale(util.clamp(row.share or 0, 0, 1), 1),
				bg = theme.color.accent,
				radius = theme.radius.pill,
			})

			local facts = { util.formatCompact(row.tokens) .. " tokens",
				util.pluralise(row.requests, "request") }
			local cost = env.require("agent/usage").formatCost(row.cost)
			if cost ~= "" then facts[#facts + 1] = cost end
			local detail = P.text(entry, {
				name = "Detail",
				text = table.concat(facts, "  ") .. (window.estimated and "  (some estimated)" or ""),
				role = "caption",
				color = theme.color.textTertiary,
				truncate = true,
				size = UDim2.new(1, 0, 0, theme.text.caption.height),
				layoutOrder = 3,
			})
			detail.Name = "Detail"
		end
		return box
	end

	local function buildHeatmap(parent, order)
		local map = stats.heatmap(heatmapWeeks())
		local todayKey = clock.dayKey()
		local holder = P.column(parent, {
			name = "Heatmap",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			bg = theme.color.surfaceOverlay,
			radius = theme.radius.md,
			padding = theme.space.sm,
			gap = theme.space.hair,
			layoutOrder = order,
		})
		P.stroke(holder, theme.color.borderSubtle)

		-- Rows are weekdays and columns are weeks, which is the arrangement that makes
		-- a habit visible: a column is a week of work, a row is "every Tuesday".
		for weekday = 1, 7 do
			local row = P.row(holder, {
				name = "Week_" .. clock.weekdayName(weekday),
				size = UDim2.new(1, 0, 0, theme.size.cell),
				gap = theme.space.hair,
				layoutOrder = weekday,
			})
			for column = 1, #map.columns do
				local cell = map.columns[column][weekday]
				local button = P.rowButton(row, {
					name = "Cell_" .. cell.key,
					size = UDim2.fromOffset(theme.size.cell, theme.size.cell),
					height = theme.size.cell,
					bg = cell.future and theme.color.surfaceOverlay or levelColour(cell.level),
					bgHover = theme.color.solid,
					radius = theme.radius.xs,
					padding = theme.space.none,
					layoutOrder = column,
					onClick = function()
						if cell.future then
							overlay.toast(clock.describeDay(cell.key, todayKey) .. " -- not yet", "info", 2)
							return
						end
						local text, tone = describeCell(cell, todayKey)
						overlay.toast(text, tone, 2.5)
					end,
				})
				-- A cell is eleven pixels square: the hit-target floor would make it a
				-- button the size of the whole row, so this one control opts out and the
				-- grid stays a grid.
				button.instance.Size = UDim2.fromOffset(theme.size.cell, theme.size.cell)
			end
		end
		return holder
	end

	-- The card, and the greeting above it. `order` is the layout order inside whatever
	-- column it is being dropped into -- the transcript, in practice.
	function M.card(parent, order)
		local name = "there"
		local okName, display = pcall(function()
			return env.plr and env.plr.DisplayName
		end)
		if okName and type(display) == "string" and util.trim(display) ~= "" then
			name = display
		elseif env.plr and type(env.plr.Name) == "string" and env.plr.Name ~= "" then
			name = env.plr.Name
		end

		local holder = P.column(parent, {
			name = "Home",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			alignX = "Center",
			gap = theme.space.xl,
			padding = { y = theme.space.lg },
			layoutOrder = order,
		})

		local greeting = P.row(holder, {
			name = "Greeting",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			alignX = "Center",
			gap = theme.space.md,
			layoutOrder = 1,
		})
		local sparkSlot = P.frame(greeting, {
			size = UDim2.fromOffset(theme.size.iconLarge, theme.size.iconLarge),
			layoutOrder = 1,
		})
		icons.spark(sparkSlot, theme.size.iconLarge, theme.color.accent)
		P.text(greeting, {
			name = "GreetingText",
			text = string.format("What's up next, %s?", name),
			role = "display",
			color = theme.color.text,
			auto = "XY",
			layoutOrder = 2,
		})

		if config.get("ui.showActivity", true) ~= true then return holder end

		local card = P.column(holder, {
			name = "ActivityCard",
			-- Fills the column up to the card's own width, rather than being a fixed
			-- 560 that overflows a phone.
			size = UDim2.new(1, 0, 0, 0),
			maxSize = Vector2.new(theme.size.statCard, math.huge),
			auto = "Y",
			bg = theme.color.surfaceRaised,
			radius = theme.radius.xl,
			gap = theme.space.md,
			padding = theme.space.lg,
			layoutOrder = 2,
		})
		P.stroke(card, theme.color.borderSubtle)

		local state = {
			tab = "overview",
			range = config.get("ui.activityRange", "all"),
		}
		local body = nil

		local function render()
			if body then pcall(function() body:Destroy() end) end
			body = P.column(card, {
				name = "ActivityBody",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.md,
				layoutOrder = 2,
			})

			local window = stats.window(state.range)
			if state.tab == "models" then
				buildModels(body, window)
			else
				buildOverview(body, window)
			end
			buildHeatmap(body, 2)

			local footer = stats.comparison(window.tokens)
			if not footer then
				if window.messages == 0 and window.requests == 0 then
					footer = "Nothing recorded in this window yet. Everything here is counted from what this client does, so it fills in as you use it."
				else
					footer = string.format("%s in, %s out across %s.",
						util.formatCompact(window.tokensIn), util.formatCompact(window.tokensOut),
						util.pluralise(window.requests, "request"))
				end
			end
			local note = P.text(body, {
				name = "Comparison",
				text = footer,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 3,
			})
			note.Size = UDim2.new(1, 0, 0, 0)
		end

		local header = P.row(card, {
			name = "CardHeader",
			size = UDim2.new(1, 0, 0, math.max(theme.size.chip, theme.size.controlSmall)),
			gap = theme.space.xs,
			layoutOrder = 1,
		})

		local tabs, ranges = {}, {}

		local function repaint()
			for value, handle in pairs(tabs) do
				handle.setSelected(value == state.tab)
				handle.text.TextColor3 = (value == state.tab) and theme.color.text or theme.color.textTertiary
			end
			for value, handle in pairs(ranges) do
				handle.setSelected(value == state.range)
				handle.text.TextColor3 = (value == state.range) and theme.color.text or theme.color.textTertiary
			end
		end

		local tabRow = P.row(header, {
			name = "Tabs",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.hair,
			layoutOrder = 1,
		})
		for index, entry in ipairs({ { value = "overview", label = "Overview" }, { value = "models", label = "Models" } }) do
			local handle = pill(tabRow, entry.label, entry.value == state.tab, index, function()
				state.tab = entry.value
				repaint()
				render()
			end)
			handle.text = handle.row:FindFirstChildOfClass("TextLabel")
			tabs[entry.value] = handle
		end

		P.spacer(header, { grow = true, layoutOrder = 2 })

		local rangeRow = P.row(header, {
			name = "Ranges",
			size = UDim2.new(0, 0, 1, 0),
			auto = "X",
			gap = theme.space.hair,
			layoutOrder = 3,
		})
		for index, entry in ipairs(stats.RANGES) do
			local handle = pill(rangeRow, entry.label, entry.value == state.range, index, function()
				state.range = entry.value
				config.set("ui.activityRange", entry.value, { quiet = true })
				repaint()
				render()
			end)
			handle.text = handle.row:FindFirstChildOfClass("TextLabel")
			ranges[entry.value] = handle
		end

		render()
		repaint()

		-- The card is built once per transcript, and a turn that finishes while it is on
		-- screen changes every number on it. Debounced because a turn records a message,
		-- a request and a tool result within the same few frames, and rebuilding the
		-- grid three times for one turn is three times the work for one result.
		local refresh = clock.debounce(function()
			if not card.Parent then return end
			render()
		end, theme.motion.slow)
		local unsubscribe = stats.changed:connect(refresh)
		card.Destroying:Connect(function() pcall(unsubscribe) end)

		return holder
	end

	return M
end
