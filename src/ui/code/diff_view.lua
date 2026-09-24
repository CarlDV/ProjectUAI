-- A bounded, scrollable source comparison for inline reviews.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local diff = env.require("runtime/code_diff")
	local M = {}
	function M.new(parent, before, after)
		local root = P.frame(parent, { name = "InlineSourceDiff", size = UDim2.fromScale(1, 1), bg = theme.color.codeSurface, clip = true })
		local comparison = diff.compare(before, after)
		local bar = common.toolbar(root)
		local summary = bar.add("+" .. comparison.added .. "  −" .. comparison.removed, function() end, { flex = true, trailing = false })
		summary.setEnabled(false)
		local list = common.virtualList(root, { name = "DiffLines", position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 1, -common.barHeight()),
			role = "mono", passive = true, rowHeight = theme.text.mono.height + 2, horizontal = true, bg = theme.color.codeSurface,
			label = function(row) return string.format("%4s %4s %s %s", row.oldLine or "", row.newLine or "", row.kind == "add" and "+" or row.kind == "remove" and "−" or " ", row.text) end,
			background = function(row) return row.kind == "add" and theme.color.codeAddSurface or row.kind == "remove" and theme.color.codeRemoveSurface or nil end,
		})
		for index, row in ipairs(comparison.rows) do
			row.id, row.color = "line:" .. index, row.kind == "add" and theme.color.codeAddText or row.kind == "remove" and theme.color.codeRemoveText or theme.color.codeText
		end
		list.set(comparison.rows)
		local empty = P.text(root, { name = "DiffEmpty", text = "This version matches the current source.", wrap = true, color = theme.color.codeGutter, position = UDim2.fromOffset(16, common.barHeight() + 20), size = UDim2.new(1, -32, 0, 60), visible = #comparison.rows == 0 })
		local current = 0
		local function nextChange(delta)
			if #comparison.hunks == 0 then return end
			current = ((current + delta - 1) % #comparison.hunks) + 1
			local index = comparison.hunks[current].first
			list.root.CanvasPosition = Vector2.new(list.root.CanvasPosition.X, math.max(0, (index - 3) * list.rowHeight))
		end
		bar.add("", function() nextChange(-1) end, { name = "PreviousSourceChange", icon = "arrowLeft", iconOnly = true, enabled = #comparison.hunks > 0 })
		bar.add("Next change", function() nextChange(1) end, { name = "NextSourceChange", tight = true, enabled = #comparison.hunks > 0 })
		if #comparison.hunks > 0 then nextChange(1) end
		return { root = root, comparison = comparison, list = list, destroy = function() root:Destroy() end }
	end
	return M
end
