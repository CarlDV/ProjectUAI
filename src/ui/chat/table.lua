-- Markdown tables use one measured grid inside a two-axis viewport. Column
-- widths are shared by every row; labels own their wrapped height, never their
-- parent's height. No row or cell is truncated, including malformed wide rows.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local markdown = env.require("ui/markdown")
	local M = {}

	local ALIGN = { left = "Left", center = "Center", right = "Right" }
	local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

	-- Strip only our generated tags, then decode once. In particular, a literal
	-- &lt;b&gt; in the reply is not a tag and must contribute to the measurement.
	local function visibleText(rich)
		return (rich:gsub("<[^>]*>", ""):gsub("&(%a+);", function(name)
			return ENTITIES[name] or ("&" .. name .. ";")
		end))
	end

	local function measure(text, role, width)
		local ok, bounds = pcall(function()
			return env.services.TextService:GetTextSize(text, role.size, role.font,
				Vector2.new(width, theme.size.reading))
		end)
		if ok and bounds then return bounds end
		-- An initial estimate only; engine TextBounds/AutomaticSize replace it.
		-- Count UTF-8 leading bytes rather than charging every byte as a glyph.
		local _, count = text:gsub("[^\128-\191]", "")
		local advance = count * role.size
		return Vector2.new(math.min(advance, width), math.max(1, math.ceil(advance / width)) * role.size)
	end

	-- props: { block = markdown table block, layoutOrder = number, maxHeight? }.
	-- Returning the root matches message.codeBlock; destruction owns all listeners.
	function M.render(parent, props)
		local block = assert(props.block, "table block required")
		local columnCount = math.max(#block.header, block.columns or 0, 1)
		for _, row in ipairs(block.rows) do columnCount = math.max(columnCount, #row) end
		local padX, padY, hair = theme.space.md, theme.space.sm, theme.stroke.hair
		local bar = theme.size.scrollbar
		local minWidth = math.max(theme.size.tableColumnMin or theme.size.keyColumn, padX * 2 + theme.text.body.size)
		local maxWidth = math.max(minWidth, theme.size.tableColumnMax or theme.size.menuWide)
		local root = P.column(parent, {
			name = "MarkdownTable", size = UDim2.new(1, 0, 0, 0), auto = "Y",
			gap = theme.space.xxs, layoutOrder = props.layoutOrder,
		})
		local scroll = P.scroll(root, {
			name = "TableViewport", size = UDim2.new(1, 0, 0, theme.size.row),
			horizontal = true, gap = 0, bg = theme.color.canvas, layoutOrder = 1,
		}).instance
		scroll.ScrollingDirection = Enum.ScrollingDirection.XY
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
		-- Stable gutters avoid a resize/rewrap loop when a scrollbar appears.
		scroll.VerticalScrollBarInset = Enum.ScrollBarInset.Always
		scroll.HorizontalScrollBarInset = Enum.ScrollBarInset.Always
		P.corner(scroll, theme.radius.sm)
		P.stroke(scroll, theme.color.borderSubtle)
		local grid = P.frame(scroll, { name = "TableGrid", size = UDim2.fromOffset(0, 0) })
		local hint = P.text(root, {
			name = "TableHint", text = "", role = "caption", color = theme.color.textTertiary,
			wrap = true, auto = "Y", alignY = "Top", layoutOrder = 2, visible = false,
		})
		local connections, rows, preferred = {}, {}, {}
		local destroyed, queued, layingOut = false, false, false
		local layout
		local function requestLayout()
			if destroyed or queued or layingOut then return end
			queued = true
			task.defer(function()
				queued = false
				if not destroyed then layout() end
			end)
		end
		local function watch(node, property, callback)
			connections[#connections + 1] = node:GetPropertyChangedSignal(property):Connect(callback or requestLayout)
		end
		for column = 1, columnCount do preferred[column] = minWidth end
		local function addRow(cells, header)
			local row = { cells = {}, header = header }
			row.frame = P.frame(grid, {
				name = header and "TableHeader" or ("TableRow_" .. tostring(#rows)),
				bg = header and theme.color.surfaceRaised or (#rows % 2 == 0 and theme.color.surface or theme.color.canvas),
				size = UDim2.fromOffset(0, 0),
			})
			local roleName = header and "bodyStrong" or "body"
			local role = theme.textRole(roleName)
			for column = 1, columnCount do
				local rich = markdown.inline(cells[column] or "")
				local text = visibleText(rich)
				local label = P.text(row.frame, {
					name = "Cell_" .. column, text = rich, role = roleName, rich = true,
					wrap = true, auto = "Y", alignY = "Top",
					align = ALIGN[(block.align or {})[column]] or "Left",
					size = UDim2.fromOffset(minWidth - padX * 2, 0),
				})
				row.cells[column] = { label = label, text = text, role = role }
				preferred[column] = math.max(preferred[column], math.min(maxWidth,
					math.ceil(measure(text, role, theme.size.reading).X) + padX * 2))
				watch(label, "AbsoluteSize")
				watch(label, "TextBounds")
			end
			row.rule = P.frame(row.frame, { name = "RowRule", bg = theme.color.borderSubtle })
			rows[#rows + 1] = row
		end
		addRow(block.header, true)
		for _, cells in ipairs(block.rows) do addRow(cells, false) end

		local previousWidth = -1
		layout = function()
			if destroyed then return end
			layingOut = true
			local width = math.floor(root.AbsoluteSize.X)
			if width <= 0 then width = math.min(theme.size.reading, responsive.viewport.X) end
			previousWidth = width
			local available = math.max(1, width - bar)
			local wanted = 0
			for _, value in ipairs(preferred) do wanted = wanted + value end
			local totalWidth = math.max(available, minWidth * columnCount)
			local widths, allocated = {}, 0
			local flex = wanted - minWidth * columnCount
			for column = 1, columnCount do
				local value
				if totalWidth >= wanted then
					value = preferred[column] + (totalWidth - wanted) / columnCount
				else
					value = minWidth + (flex > 0 and ((totalWidth - minWidth * columnCount)
						* (preferred[column] - minWidth) / flex) or 0)
				end
				widths[column] = column == columnCount and (totalWidth - allocated) or math.floor(value)
				allocated = allocated + widths[column]
			end
			local y, resized = 0, false
			for _, row in ipairs(rows) do
				local height, x = 0, 0
				for column, cell in ipairs(row.cells) do
					local label, textWidth = cell.label, widths[column] - padX * 2
					local changedWidth = label.Size.X.Offset ~= textWidth
					if changedWidth then
						label.Size = UDim2.fromOffset(textWidth, 0)
						resized = true
					end
					label.Position = UDim2.fromOffset(x + padX, padY)
					-- Until the engine publishes bounds for this width, use TextService.
					-- The live bounds include RichText fonts, UTF-8 and actual word wrap.
					local measured = not changedWidth and math.max(label.TextBounds.Y, label.AbsoluteSize.Y) or 0
					if measured <= 0 then
						measured = measure(cell.text, cell.role, textWidth).Y * cell.role.line
					end
					height = math.max(height, math.ceil(measured), cell.role.height)
					x = x + widths[column]
				end
				height = height + padY * 2 + hair
				row.frame.Position = UDim2.fromOffset(0, y)
				row.frame.Size = UDim2.fromOffset(totalWidth, height)
				row.rule.Position = UDim2.fromOffset(0, height - hair)
				row.rule.Size = UDim2.fromOffset(totalWidth, hair)
				y = y + height
			end
			local cap = math.max(theme.size.row + bar, math.min(props.maxHeight
				or theme.size.tableViewport or theme.size.codeViewport, math.floor(responsive.viewport.Y / 2)))
			local height = math.min(y + bar, cap)
			grid.Size = UDim2.fromOffset(totalWidth, y)
			scroll.Size = UDim2.new(1, 0, 0, height)
			scroll.CanvasSize = UDim2.fromOffset(totalWidth, y)
			local horizontal, vertical = totalWidth > available, y > height - bar
			scroll.ScrollingEnabled = horizontal or vertical
			local old = scroll.CanvasPosition
			scroll.CanvasPosition = Vector2.new(math.max(0, math.min(old.X, totalWidth - available)),
				math.max(0, math.min(old.Y, y - (height - bar))))
			hint.Visible = horizontal or vertical
			hint.Text = string.format("%d %s%s", #block.rows, #block.rows == 1 and "row" or "rows",
				horizontal and (vertical and " · Scroll across and down" or " · Scroll across")
				or (vertical and " · Scroll for more" or ""))
			layingOut = false
			-- Some clients publish TextBounds during the size assignment, while the
			-- re-entry guard is active. One coalesced follow-up consumes those bounds.
			if resized then requestLayout() end
		end
		watch(root, "AbsoluteSize", function()
			if math.floor(root.AbsoluteSize.X) ~= previousWidth then requestLayout() end
		end)
		local disconnectResponsive = responsive.changed:connect(requestLayout)
		local destroyConnection
		destroyConnection = root.Destroying:Connect(function()
			destroyed = true
			for _, connection in ipairs(connections) do connection:Disconnect() end
			disconnectResponsive()
			destroyConnection:Disconnect()
		end)
		layout()
		return root
	end

	return M
end
