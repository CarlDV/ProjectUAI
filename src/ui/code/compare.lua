return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local diff = env.require("runtime/code_diff")
	local overlay = env.require("ui/overlay")
	local M = {}
	function M.open(before, after, title, apply)
		local comparison = diff.compare(before, after)
		local modal = overlay.modal({ title = title or "Compare source", description = "+" .. comparison.added .. " / −" .. comparison.removed .. (comparison.replacement and " · Full replacement" or ""), width = theme.size.modalWide })
		if not modal then return end
		env.require("ui/code/forms").stopControl(modal)
		local host = P.frame(modal.content, { size = UDim2.new(1, 0, 0, theme.size.codeOutput * 2), name = "SourceComparison" })
		local unified = P.frame(host, { size = UDim2.fromScale(1, 1) })
		local left = P.frame(host, { size = UDim2.new(0.5, -theme.space.xs, 1, 0) })
		local right = P.frame(host, { position = UDim2.fromScale(0.5, 0), size = UDim2.fromScale(0.5, 1) })
		local list = common.virtualList(unified, { label = function(row) return (row.kind == "add" and "+ " or row.kind == "remove" and "− " or "  ") .. row.text end,
			onSelect = function(row) overlay.code({ title = row.kind .. " · line " .. tostring(row.newLine or row.oldLine), code = row.text, text = row.text }) end })
		P.text(left, { text = "Before", role = "small", size = UDim2.new(1, 0, 0, theme.text.small.height) })
		P.text(right, { text = "After", role = "small", size = UDim2.new(1, 0, 0, theme.text.small.height) })
		local beforeList = common.virtualList(left, { position = UDim2.fromOffset(0, theme.text.small.height), size = UDim2.new(1, 0, 1, -theme.text.small.height), label = function(row) return row.kind == "add" and " " or (row.kind == "remove" and "− " or "  ") .. tostring(row.oldLine) .. "  " .. row.text end,
			onSelect = function(row) if row.kind ~= "add" then overlay.code({ title = "Before · line " .. tostring(row.oldLine), code = row.text }) end end })
		local afterList = common.virtualList(right, { position = UDim2.fromOffset(0, theme.text.small.height), size = UDim2.new(1, 0, 1, -theme.text.small.height), label = function(row) return row.kind == "remove" and " " or (row.kind == "add" and "+ " or "  ") .. tostring(row.newLine) .. "  " .. row.text end,
			onSelect = function(row) if row.kind ~= "remove" then overlay.code({ title = "After · line " .. tostring(row.newLine), code = row.text }) end end })
		for _, row in ipairs(comparison.rows) do row.color = row.kind == "add" and theme.color.codeAddText or row.kind == "remove" and theme.color.codeRemoveText or theme.color.codeText end
		list.set(comparison.rows); beforeList.set(comparison.rows); afterList.set(comparison.rows)
		local syncing = false
		for _, pair in ipairs({ { beforeList, afterList }, { afterList, beforeList } }) do pair[1].root:GetPropertyChangedSignal("CanvasPosition"):Connect(function() if syncing then return end; syncing = true; pair[2].root.CanvasPosition = pair[1].root.CanvasPosition; syncing = false end) end
		local function layout() local wide = host.AbsoluteSize.X >= theme.size.codeWide - theme.space.lg * 2; unified.Visible, left.Visible, right.Visible = not wide, wide, wide end
		host:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout); layout()
		local current = 0
		local nav = common.toolbar(modal.content); nav.root.LayoutOrder = 2
		local function nextHunk(delta)
			if #comparison.hunks == 0 then return end
			current = ((current + delta - 1) % #comparison.hunks) + 1
			list.selected = comparison.hunks[current].first; list.move(0)
			beforeList.selected, afterList.selected = list.selected, list.selected; beforeList.move(0); afterList.move(0)
		end
		nav.add("Previous", function() nextHunk(-1) end, { icon = "arrowLeft" })
		nav.add("Next change", function() nextHunk(1) end, { icon = "arrowRight" })
		nav.add("View", function(button) common.menu(button, "Complete source", { { label = "Before", value = "before" }, { label = "After", value = "after" } }, function(value) overlay.code({ title = value == "before" and "Before" or "After", code = value == "before" and before or after }) end) end, { flex = true })
		local errorLabel = P.text(modal.content, { text = "", color = theme.color.warn, wrap = true, auto = "Y", layoutOrder = 3 })
		common.button(modal.footer, { text = "Cancel", size = "sm", variant = "ghost", onClick = function() modal.close() end })
		if apply then common.button(modal.footer, { text = "Apply", size = "sm", variant = "primary", layoutOrder = 2, onClick = function()
			local result, why = apply(); if not result then errorLabel.Text = tostring(why); return end
			modal.close(true)
		end }) end
		return modal
	end
	return M
end
