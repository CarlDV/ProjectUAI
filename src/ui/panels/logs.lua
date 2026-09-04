-- Logs panel: the request history and the application log.
--
-- Two views over the same question -- what did this thing just do -- kept separate
-- because they answer different halves of it. Requests explain a provider failure;
-- the log explains everything else.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local http = env.require("net/http")
	local log = env.require("runtime/log")

	local M = {}

	local LEVEL_TONE = { debug = "info", info = "info", warn = "warn", error = "bad" }

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
			padding = { x = theme.space.md, top = theme.space.md, bottom = theme.space.sm },
			layoutOrder = 1,
		})

		local tabs
		local scroll
		local function render() end

		tabs = C.segmented(head, {
			options = {
				{ value = "requests", label = "Requests" },
				{ value = "log", label = "Log" },
			},
			value = panel.view,
			onChange = function(value)
				panel.view = value
				render()
			end,
		})

		local actions = P.row(head, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
		local countLabel = P.text(actions, {
			text = "",
			role = "caption",
			color = theme.color.textTertiary,
			layoutOrder = 1,
		})
		countLabel.Size = UDim2.new(1, -170, 0, theme.text.caption.size + 6)

		if caps.clipboard then
			local copy = P.button(actions, {
				text = "Copy",
				variant = "ghost",
				size = "sm",
				layoutOrder = 2,
				onClick = function()
					pcall(caps.fn.clipboard, log.export())
					overlay.toast("Log copied", "good", 2)
				end,
			})
			copy.instance.LayoutOrder = 2
		end
		local clear = P.button(actions, {
			text = "Clear",
			variant = "ghost",
			size = "sm",
			layoutOrder = 3,
			onClick = function()
				if panel.view == "requests" then http.clearHistory() else log.clear() end
				render()
			end,
		})
		clear.instance.LayoutOrder = 3

		scroll = P.scroll(column, {
			name = "LogList",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.xs,
			padding = { x = theme.space.md, bottom = theme.space.md },
			layoutOrder = 2,
		})
		local flex = Instance.new("UIFlexItem", scroll.instance)
		flex.FlexMode = Enum.UIFlexMode.Fill

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
			P.statusDot(top, { color = theme.toneColor(tone), diameter = 7, layoutOrder = 1 })
			local title = P.text(top, {
				text = string.format("%s %s", entry.method, entry.tag or ""),
				role = "monoSmall",
				layoutOrder = 2,
			})
			title.Size = UDim2.new(1, -150, 0, theme.text.monoSmall.size + 4)
			local meta = P.text(top, {
				text = string.format("%s %s", entry.status > 0 and tostring(entry.status) or "-",
					util.formatDuration(entry.ms or 0)),
				role = "caption",
				color = theme.color.textTertiary,
				align = "Right",
				layoutOrder = 3,
			})
			meta.Size = UDim2.fromOffset(96, theme.text.caption.size + 4)

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
			local row = P.row(scroll.instance, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				alignY = "Top",
				layoutOrder = order,
			})
			P.statusDot(row, {
				color = theme.toneColor(LEVEL_TONE[entry.level] or "info"),
				diameter = 6,
				layoutOrder = 1,
			})
			local stamp = P.text(row, {
				text = entry.stamp or "",
				role = "caption",
				color = theme.color.textTertiary,
				layoutOrder = 2,
			})
			stamp.Size = UDim2.fromOffset(58, theme.text.caption.size + 4)
			local source = P.text(row, {
				text = entry.source,
				role = "caption",
				color = theme.color.textTertiary,
				layoutOrder = 3,
				truncate = true,
			})
			source.Size = UDim2.fromOffset(74, theme.text.caption.size + 4)
			local body = P.text(row, {
				text = entry.message .. (entry.detail and ("  " .. entry.detail) or ""),
				role = "caption",
				color = entry.level == "error" and theme.color.danger or theme.color.textSecondary,
				wrap = true,
				auto = "Y",
				layoutOrder = 4,
			})
			body.Size = UDim2.new(1, -(58 + 74 + 6 + theme.space.xs * 3), 0, 0)
			return row
		end

		render = function()
			scroll.clear()
			if panel.view == "requests" then
				local entries = util.reverse(http.history)
				countLabel.Text = util.pluralise(#entries, "request") .. " kept"
				if #entries == 0 then
					C.emptyState(scroll.instance, {
						title = "No requests yet",
						description = "Every outbound call lands here with its status, timing and whether the client identity made it onto the wire.",
						layoutOrder = 1,
					})
					return
				end
				for index, entry in ipairs(entries) do requestRow(entry, index) end
			else
				local entries = util.reverse(log.entries)
				countLabel.Text = util.pluralise(#entries, "line") .. " kept"
				if #entries == 0 then
					C.emptyState(scroll.instance, { title = "Log is empty", layoutOrder = 1 })
					return
				end
				for index, entry in ipairs(entries) do logRow(entry, index) end
			end
		end

		render()
		panel.refresh = render
		-- Live, but throttled: a burst of log lines must not rebuild the list per
		-- line while the user is reading it.
		local clock = env.require("runtime/clock")
		local throttled = clock.throttle(render, 0.4)
		panel.unsubscribeLog = log.changed:connect(function()
			if panel.view == "log" then throttled() end
		end)
		panel.unsubscribeHttp = http.changed:connect(function()
			if panel.view == "requests" then throttled() end
		end)
		return panel
	end

	return M
end
