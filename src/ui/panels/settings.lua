-- The Settings panel: every pane, stacked in one scroll.
--
-- The panes themselves live in ui/settingspanes, because the settings dialog the
-- sidebar opens shows the same ones behind a category list. This surface is the one
-- that shows all of them at once, which is what a panel in a five-panel client is
-- for -- and it means a setting cannot exist in one place and not the other.
return function(env)
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local panes = env.require("ui/settingspanes")

	local M = {}

	function M.new(parent)
		local panel = {}
		local scroll = P.scroll(parent, {
			name = "Settings",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.lg,
			padding = theme.space.md,
		})

		for index, entry in ipairs(panes.PANES) do
			local column = P.column(scroll.instance, {
				name = "Pane_" .. entry.id,
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.md,
				layoutOrder = index,
			})
			panes.render(entry.id, column)
		end

		panel.scroll = scroll
		return panel
	end

	return M
end
