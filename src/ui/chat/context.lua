-- A live view of the next request, using the same estimates as compaction.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local usage = env.require("agent/usage")
	local providers = env.require("provider/registry")
	local traits = env.require("provider/traits")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")
	local M = {}

	function M.open(session)
		if not session then return nil end
		local unsubscribes = {}
		local function cleanup()
			for _, unsubscribe in ipairs(unsubscribes) do unsubscribe() end
			unsubscribes = {}
		end
		local modal = overlay.modal({
			title = "Context usage",
			description = "What the next request will include",
			width = theme.size.modalWide,
			height = theme.size.modalWide + theme.space.xl * 2,
			onClose = cleanup,
		})
		if not modal then return nil end
		modal.card.Name = "ContextInspector"
		local total = P.text(modal.content, {
			name = "ContextTotal", text = "", role = "bodyStrong", wrap = true, auto = "Y", layoutOrder = 1,
		})
		local pressure = P.text(modal.content, {
			name = "ContextPressure", text = "", role = "small", wrap = true, auto = "Y", layoutOrder = 2,
		})
		local chart = P.frame(modal.content, {
			name = "ContextBar", size = UDim2.new(1, 0, 0, theme.size.knob),
			bg = theme.color.contextUnused, radius = theme.radius.sm, clip = true, layoutOrder = 3,
		})
		local categories = {
			{ id = "system", label = "System prompt + tool schemas", color = theme.color.contextSystem },
			{ id = "messages", label = "Messages", color = theme.color.contextMessages },
			{ id = "summary", label = "Rolling summary", color = theme.color.contextSummary },
			{ id = "unused", label = "Unused context", color = theme.color.contextUnused },
		}
		for index, category in ipairs(categories) do
			if category.id ~= "unused" then
				category.segment = P.frame(chart, {
					name = "ContextSegment_" .. category.id, size = UDim2.fromScale(0, 1), bg = category.color,
				})
			end
			local row = P.row(modal.content, {
				name = "ContextCategory_" .. category.id, size = UDim2.new(1, 0, 0, 0), auto = "Y",
				gap = theme.space.sm, alignY = "Top", layoutOrder = 4 + index,
			})
			local swatch = P.frame(row, {
				size = UDim2.fromOffset(theme.size.dot, theme.text.small.size), layoutOrder = 1,
			})
			P.statusDot(swatch, { color = category.color, diameter = theme.size.dot,
				anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5) })
			category.labelNode = P.text(row, {
				text = category.label, role = "small", wrap = true, auto = "Y",
				size = UDim2.new(0, 0, 0, 0), flex = "Fill", layoutOrder = 2,
			})
			category.valueNode = P.text(row, {
				name = "ContextValue_" .. category.id, text = "", role = "caption", color = theme.color.textSecondary,
				align = "Right", wrap = true, auto = "Y", size = UDim2.new(0, theme.size.keyColumn, 0, 0), layoutOrder = 3,
			})
		end
		local marker = P.frame(chart, {
			name = "CompactionMarker", size = UDim2.new(0, theme.stroke.focus, 1, 0),
			anchor = Vector2.new(1, 0), bg = theme.color.text, zIndex = chart.ZIndex + 1,
		})
		local scaleLabel = P.text(modal.content, {
			name = "ContextScale", text = "", role = "caption", color = theme.color.textSecondary,
			wrap = true, auto = "Y", layoutOrder = 4,
		})
		P.divider(modal.content, { layoutOrder = 9 })
		local limits = P.text(modal.content, {
			name = "ContextLimits", text = "", role = "small", wrap = true, auto = "Y", layoutOrder = 10,
		})
		local estimates = P.text(modal.content, {
			name = "ContextEstimates", text = "", role = "caption", color = theme.color.textSecondary,
			wrap = true, auto = "Y", layoutOrder = 11,
		})

		local function tokens(value) return util.formatNumber(value) .. " tokens" end
		local function refresh()
			if modal.closed then return end
			local ctx, record = session.ctx, providers.active()
			local model = record and record.model
			local window = traits.contextWindow(model)
			local compactAt = math.max(ctx.limitFor(model), 1)
			local scale = math.max(window or compactAt, 1)
			local used = ctx.pressure()
			local values = {
				system = math.max(ctx.overhead or 0, 0),
				messages = usage.estimateMessages(ctx.messages),
				summary = ctx.summary and usage.estimateText(ctx.summary) or 0,
				unused = math.max(0, scale - used),
			}
			total.Text = "Next request: about " .. tokens(used)
			pressure.Text = string.format("%d%% of the compaction point", math.floor(used / compactAt * 100 + 0.5))
			pressure.TextColor3 = used >= compactAt and theme.color.warn or theme.color.textSecondary
			local offset = 0
			for _, category in ipairs(categories) do
				local count = values[category.id]
				category.valueNode.Text = tokens(count) .. string.format("\n%.1f%%", count / scale * 100)
				if category.id == "system" and not ctx.calibrated and count == 0 then
					category.valueNode.Text = "After first reply"
				elseif category.id == "unused" then
					category.labelNode.Text = window and "Unused context" or "Until compaction"
				end
				if category.segment then
					local share = math.min(count / scale, math.max(0, 1 - offset))
					category.segment.Position = UDim2.fromScale(offset, 0)
					category.segment.Size = UDim2.fromScale(share, 1)
					category.segment.Visible = share > 0
					offset = offset + share
				end
			end
			marker.Position = UDim2.fromScale(math.min(compactAt / scale, 1), 0)
			scaleLabel.Text = window and "Full bar = model window. White marker = compaction point."
				or "Model window unknown. Full bar = compaction point."
			limits.Text = "Compaction point: " .. tokens(compactAt) .. "\nModel window: "
				.. (window and tokens(window) or "unknown; learned automatically from a context-length error")
			estimates.Text = "Message and summary counts are estimates. "
				.. (ctx.calibrated and "System prompt and tool schemas are estimated from the last provider reply."
					or "System prompt and tool schemas will be counted after the first provider reply; totals are partial until then.")
		end
		refresh()
		unsubscribes[#unsubscribes + 1] = session.events:connect(refresh)
		unsubscribes[#unsubscribes + 1] = config.changed:connect(refresh)
		unsubscribes[#unsubscribes + 1] = providers.changed:connect(refresh)
		modal.scrim.Destroying:Connect(cleanup)
		return modal
	end
	return M
end
