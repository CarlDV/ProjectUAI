-- Logs panel: the request history and the application log.
--
-- Two views over the same question -- what did this thing just do -- kept separate
-- because they answer different halves of it. Requests explain a provider failure;
-- the log explains everything else.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local http = env.require("net/http")
	local log = env.require("runtime/log")

	local M = {}

	local LEVEL_TONE = { debug = "info", info = "info", warn = "warn", error = "bad" }

	-- Copy the same request evidence this panel shows, without including bodies or
	-- credentials from transport records. The application log has a separate export.
	local function requestExport()
		local lines = {}
		for index = #http.history, 1, -1 do
			local entry = http.history[index]
			lines[#lines + 1] = string.format("%s %s %s -> %s (%s)",
				tostring(entry.stamp or ""), tostring(entry.method or "GET"), tostring(entry.url or ""),
				tostring(entry.status or 0), util.formatDuration(entry.ms or 0))
			local details = { tostring(entry.tag or "http"), tostring(entry.via or "unknown"),
				util.formatNumber(entry.bytes or 0) .. " bytes",
				"identity: " .. tostring(entry.identity or "none") }
			if entry.identity ~= "none" then
				details[#details + 1] = entry.uaSent and "user-agent sent" or "user-agent dropped"
			end
			if entry.attempt then details[#details + 1] = "attempt " .. tostring(entry.attempt) end
			if entry.server then details[#details + 1] = "server " .. tostring(entry.server) end
			if entry.trace then details[#details + 1] = "trace " .. tostring(entry.trace) end
			if entry.mitigated then details[#details + 1] = "mitigated " .. tostring(entry.mitigated) end
			lines[#lines + 1] = "  " .. table.concat(details, " | ")
			if entry.error then lines[#lines + 1] = "  " .. tostring(entry.error) end
		end
		return log.redact(table.concat(lines, "\n"))
	end

	function M.new(parent)
		local panel = { view = "requests" }

		local column = P.column(parent, {
			name = "LogsPanel",
			size = UDim2.new(1, 0, 1, 0),
			gap = 0,
		})

		local head = P.column(column, {
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.sm,
			padding = { x = theme.space.lg, top = theme.space.lg, bottom = theme.space.md },
			layoutOrder = 1,
		})

		local scroll
		local function render() end

		P.sectionHeader(head, { title = "Logs & traces", description = "Request activity and application diagnostics.", layoutOrder = 1 })
		C.segmented(head, {
			layoutOrder = 2,
			options = {
				{ value = "requests", label = "Requests" },
				{ value = "log", label = "Log" },
			},
			value = panel.view,
			onChange = function(value)
				panel.view = value
				render()
				scroll.instance.CanvasPosition = Vector2.new(0, 0)
			end,
		})

		local actions = P.row(head, { size = UDim2.new(1, 0, 0, 0), auto = "Y", wrap = true, gap = theme.space.xs, layoutOrder = 3 })
		local countLabel = P.text(actions, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			layoutOrder = 1,
		})
		countLabel.Size = UDim2.fromOffset(0, theme.text.caption.height + theme.space.hair)
		countLabel.AutomaticSize = Enum.AutomaticSize.X
		-- A growing spacer rather than a hardcoded reserve on the label: the buttons
		-- are auto-width and grow with the text scale, so any fixed number is either
		-- short of the right edge or overlapping them.
		P.spacer(actions, { grow = true, size = UDim2.new(0, 0, 0, 1), layoutOrder = 2 })

		if caps.clipboard then
			local copy = P.button(actions, {
				name = "CopyDiagnostics",
				text = "Copy",
				variant = "ghost",
				size = "sm",
				layoutOrder = 3,
				onClick = function(button)
					local exported = panel.view == "requests" and requestExport() or log.export()
					local ok = pcall(caps.fn.clipboard, exported)
					button.setText(ok and "Copied" or "Retry")
					if not ok then overlay.toast("Could not copy diagnostics", "bad", 3) end
					clock.delay(2, function()
						if button.instance.Parent then button.setText("Copy") end
					end)
				end,
			})
			copy.instance.LayoutOrder = 3
		end
		local clear = P.button(actions, {
			name = "ClearDiagnostics",
			text = "Clear",
			variant = "ghost",
			size = "sm",
			layoutOrder = 4,
			onClick = function()
				if panel.view == "requests" then http.clearHistory() else log.clear() end
				render()
			end,
		})
		clear.instance.LayoutOrder = 4

		local listHolder = P.frame(column, { name = "LogListHolder", size = UDim2.new(1, 0, 0, 0),
			flex = "Fill", layoutOrder = 2 })
		scroll = P.scroll(listHolder, {
			name = "LogList",
			size = UDim2.new(1, 0, 1, 0),
			-- Tight, because the rows now carry their own banding and padding; a six
			-- pixel gap between banded rows reads as a gap in the data.
			gap = theme.space.sm,
			padding = { x = theme.space.lg, top = theme.space.sm, bottom = theme.space.xl },
			layoutOrder = 2,
		})

		local function requestRow(entry, order)
			local tone = "good"
			if entry.error then
				tone = "bad"
			elseif entry.status >= 400 then
				tone = entry.status == 429 and "warn" or "bad"
			elseif entry.status == 0 then
				tone = "warn"
			end

			local card = P.card(scroll.instance, {
				layoutOrder = order,
				gap = theme.space.xxs,
				padding = theme.space.sm,
			})
			local top = P.row(card, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			P.statusDot(top, { color = theme.toneColor(tone), diameter = theme.size.dot, layoutOrder = 1 })
			local title = P.text(top, {
				text = string.format("%s %s", entry.method, entry.tag or ""),
				role = "monoSmall",
				-- Fills rather than reserving 150 for a dot and a 96px meta column,
				-- which left thirty-five pixels stranded on every card.
				size = UDim2.new(0, 0, 0, theme.text.monoSmall.height),
				flex = "Fill",
				truncate = true,
				layoutOrder = 2,
			})
			local meta = P.text(top, {
				text = string.format("%s %s", entry.status > 0 and tostring(entry.status) or "-",
					util.formatDuration(entry.ms or 0)),
				role = "caption",
				color = theme.color.textTertiary,
				align = "Right",
				layoutOrder = 3,
			})
			meta.Size = UDim2.fromOffset(theme.size.metaColumnWide + theme.space.sm, theme.text.caption.height)

			local url = P.text(card, {
				text = entry.url,
				role = "caption",
				color = theme.color.textSecondary,
				wrap = true,
				auto = "Y",
			})
			url.Size = UDim2.new(1, 0, 0, 0)

			local bits = {
				entry.via or "?",
				string.format("%s bytes", util.formatNumber(entry.bytes or 0)),
				entry.identity or "claude",
			}
			if entry.identity ~= "none" and not entry.uaSent then
				bits[#bits + 1] = "user-agent dropped by transport"
			end
			if entry.droppedHeaders and #entry.droppedHeaders > 0 then
				bits[#bits + 1] = "dropped: " .. table.concat(entry.droppedHeaders, ", ")
			end
			if entry.attempt and entry.attempt > 1 then
				bits[#bits + 1] = "attempt " .. tostring(entry.attempt)
			end
			-- The evidence for a bodyless refusal. `server` and a trace id say the
			-- response came from an edge rather than from the API, and `cf-mitigated`
			-- says so outright, which is the difference between a key problem and a
			-- filter problem.
			if entry.server then bits[#bits + 1] = "server " .. tostring(entry.server) end
			if entry.mitigated then bits[#bits + 1] = "mitigated " .. tostring(entry.mitigated) end
			if entry.trace then bits[#bits + 1] = tostring(entry.trace) end
			if entry.status >= 400 and (entry.bytes or 0) == 0 then
				bits[#bits + 1] = "empty body"
			end
			local detail = P.text(card, {
				text = table.concat(bits, "  |  "),
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			detail.Size = UDim2.new(1, 0, 0, 0)

			if entry.error then
				local err = P.text(card, {
					text = tostring(entry.error),
					role = "caption",
					color = theme.color.danger,
					wrap = true,
					auto = "Y",
				})
				err.Size = UDim2.new(1, 0, 0, 0)
			end
			return card
		end

		local function logRow(entry, order)
			local tone = LEVEL_TONE[entry.level] or "info"
			local row = P.card(scroll.instance, {
				name = "LogEntry",
				gap = theme.space.xs,
				padding = theme.space.sm,
				layoutOrder = order,
			})
			local metadata = P.row(row, {
				name = "Metadata",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				layoutOrder = 1,
			})
			P.badge(metadata, { text = entry.level or "info", tone = tone, layoutOrder = 1 })
			P.text(metadata, {
				name = "Source", text = entry.source, role = "caption",
				color = theme.color.textSecondary, truncate = true,
				size = UDim2.new(0, 0, 0, theme.text.caption.height),
				flex = "Fill", layoutOrder = 2,
			})
			P.text(metadata, {
				name = "Timestamp", text = entry.stamp or "", role = "monoSmall",
				color = theme.color.textTertiary, auto = "X", layoutOrder = 3,
			})
			P.text(row, {
				name = "Message", text = entry.message, role = "monoSmall",
				color = entry.level == "error" and theme.color.danger or theme.color.textSecondary,
				wrap = true, auto = "Y", layoutOrder = 2,
			})
			if entry.detail then
				P.text(row, {
					name = "Detail", text = tostring(entry.detail), role = "monoSmall",
					color = theme.color.textTertiary, wrap = true, auto = "Y", layoutOrder = 3,
				})
			end
			return row
		end

		render = function()
			if not column.Parent then return end
			local position = scroll.instance.CanvasPosition
			scroll.clear()
			if panel.view == "requests" then
				local entries = util.reverse(http.history)
				countLabel.Text = util.pluralise(#entries, "request") .. " kept"
				if #entries == 0 then
					C.emptyState(scroll.instance, {
						icon = "document",
						title = "No requests yet",
						description = "Requests appear here with status, duration and transport details after you send a message.",
						layoutOrder = 1,
					})
					return
				end
				for index, entry in ipairs(entries) do requestRow(entry, index) end
			else
				local entries = util.reverse(log.entries)
				countLabel.Text = util.pluralise(#entries, "line") .. " kept"
				if #entries == 0 then
					C.emptyState(scroll.instance, { icon = "document", title = "All clear", description = "Application events will appear here as they occur.", layoutOrder = 1 })
					return
				end
				for index, entry in ipairs(entries) do logRow(entry, index) end
			end
			scroll.instance.CanvasPosition = position
		end

		render()
		panel.refresh = render
		-- Coalesce a burst while retaining its final entry. A leading-only throttle
		-- silently left the last requests absent until another event happened.
		local refreshLater, cancelRefresh = clock.debounce(render, 0.2)
		panel.unsubscribeLog = log.changed:connect(function()
			if panel.view == "log" then refreshLater() end
		end)
		panel.unsubscribeHttp = http.changed:connect(function()
			if panel.view == "requests" then refreshLater() end
		end)
		column.Destroying:Connect(function()
			cancelRefresh()
			pcall(panel.unsubscribeLog)
			pcall(panel.unsubscribeHttp)
		end)
		return panel
	end

	return M
end
