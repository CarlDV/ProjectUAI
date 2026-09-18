-- A compact picker: provider, persistent search, a flat model list, and effort.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local providers = env.require("provider/registry")
	local models = env.require("provider/models")
	local traits = env.require("provider/traits")
	local M = {}
	local opened

	function M.open(onChange)
		if opened and not opened.closed then return opened end
		local modalProps = { title = "Models", width = theme.size.modelPicker,
			height = theme.size.modelPickerHeight, scroll = true }
		local modal = overlay.modal(modalProps)
		if not modal then return end
		opened = modal
		modal.scroll.instance.ScrollingEnabled = false
		modal.content.AutomaticSize = Enum.AutomaticSize.None
		modal.content.Size = UDim2.fromScale(1, 1)
		local root = P.frame(modal.content, { name = "ModelPicker", size = UDim2.fromScale(1, 1) })
		local control = math.max(theme.size.control, responsive.minTarget())
		local filter, freeOnly, fetching = "", false, false
		local visibleCount = 0
		local rows, render, filterRows, renderEffort, fit = {}, nil, nil, nil, nil
		local signature, fitting = nil, false
		local function notify() if not modal.closed and onChange then onChange() end end

		local providerButton = P.rowButton(root, { name = "Section_Endpoint", height = control,
			size = UDim2.new(1, 0, 0, control), padding = { x = theme.space.xs }, gap = theme.space.xs,
			onClick = function(button)
				local options = {}
				for _, provider in ipairs(providers.list()) do
					options[#options + 1] = { label = provider.label, detail = provider.baseUrl, value = provider.id,
						selected = providers.active() and providers.active().id == provider.id }
				end
				options[#options + 1] = { divider = true }
				options[#options + 1] = { label = "Manage providers", value = "manage", icon = "sliders" }
				overlay.menu({ target = button.instance, width = theme.size.menuWide, options = options, onSelect = function(id)
					if id == "manage" then modal.close(); env.require("ui/app").show("providers")
					else providers.setActive(id); notify() end
				end })
			end,
		})
		providerButton.icon("globe", 1, theme.color.textTertiary)
		local providerLabel = providerButton.label("Select provider", 2, theme.color.textSecondary, "small")
		providerButton.icon("chevron", 3, theme.color.textTertiary)
		local searchRow = P.frame(root, { name = "FilterRow", position = UDim2.fromOffset(0, control + theme.space.sm),
			size = UDim2.new(1, 0, 0, control) })
		local search = P.field(searchRow, { name = "ModelFilter", placeholder = "Search models…",
			size = UDim2.new(1, -(theme.size.metaColumn + theme.space.sm), 0, control),
			onChange = function(text) filter = text; if filterRows then filterRows() end end })
		local freeButton = P.button(searchRow, { name = "FreeOnly", text = "Free", width = theme.size.metaColumn,
			position = UDim2.new(1, -theme.size.metaColumn, 0, 0), size = "md", variant = "ghost",
			onClick = function(button)
				freeOnly = not freeOnly
				button.setVariant(freeOnly and "secondary" or "ghost")
				filterRows()
			end })
		local count = P.text(root, { name = "ModelCount", text = "", role = "caption", color = theme.color.textTertiary,
			position = UDim2.fromOffset(0, control * 2 + theme.space.sm * 2), size = UDim2.new(1, 0, 0, theme.text.caption.height) })
		local listTop = control * 2 + theme.space.sm * 3 + theme.text.caption.height
		local list = P.scroll(root, { name = "ModelScroll", position = UDim2.fromOffset(0, listTop),
			size = UDim2.new(1, 0, 1, -listTop), gap = theme.space.hair,
			padding = { left = theme.space.xxs, right = theme.space.sm, top = theme.space.xxs, bottom = theme.space.xxs },
			bg = theme.color.surface })
		P.corner(list.instance, theme.radius.md)
		local empty = P.text(list.instance, { name = "EmptySearch", text = "No models yet. Use Refresh or add a model ID.",
			role = "small", color = theme.color.textTertiary, wrap = true, auto = "Y", size = UDim2.new(1, 0, 0, 0) })
		local effort = P.column(root, { name = "Section_ReasoningEffort", anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1), size = UDim2.new(1, 0, 0, control + theme.text.caption.height + theme.space.sm),
			gap = theme.space.xs })

		filterRows = function()
			local visible = 0
			local needle = util.trim(filter):lower()
			for _, entry in ipairs(rows) do
				local match = (needle == "" or entry.id:lower():find(needle, 1, true) ~= nil) and (not freeOnly or entry.free)
				entry.button.instance.Visible = match
				if match then visible = visible + 1 end
			end
			count.Text = visible == #rows and util.pluralise(#rows, "model") or string.format("%d of %s", visible, util.pluralise(#rows, "model"))
			visibleCount = visible
			empty.Visible = visible == 0
			empty.Text = #rows == 0 and "No models yet. Use Refresh or add a model ID." or "No matching models. Try another search."
			if fit then fit() end
		end

		renderEffort = function()
			for _, child in ipairs(effort:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
			local record = providers.active()
			local levels = record and traits.effortLevels(record.model)
			local wanted = config.get("agent.effort", "high")
			local sending = record and traits.nearestEffort(record.model, wanted) or wanted
			P.text(effort, { text = levels and "Reasoning effort" or "No documented effort control", name = levels and "EffortLabel" or "NoEffort",
				role = "caption", color = theme.color.textTertiary, size = UDim2.new(1, 0, 0, theme.text.caption.height), layoutOrder = 1 })
			if levels then
				local strip = P.scroll(effort, { name = "EffortPills", horizontal = true, gap = theme.space.xs,
					size = UDim2.new(1, 0, 0, control), layoutOrder = 2, bar = 0 })
				for index, level in ipairs(levels) do
					P.button(strip.instance, { name = "Effort_" .. level, text = level:gsub("^%l", string.upper),
						variant = level == sending and "secondary" or "ghost", size = "sm", layoutOrder = index,
						onClick = function() config.set("agent.effort", level); notify(); renderEffort() end })
				end
			end
			local height = levels and (control + theme.text.caption.height + theme.space.sm) or 0
			effort.Visible = levels ~= nil
			effort.Size = UDim2.new(1, 0, 0, height)
			if fit then fit() end
		end
		fit = function()
			if modal.closed or fitting then return end
			fitting = true
			local height = effort.Size.Y.Offset
			local room = math.max(0, modal.scroll.viewportSize().Y)
			local footerSpace = height > 0 and height + theme.space.md or 0
			local natural = math.max(1, visibleCount) * (control + theme.space.hair) + theme.space.sm
			local compact = room < listTop + footerSpace + control * 2
			-- One scrolling owner: short/keyboard layouts scroll the whole body;
			-- ordinary layouts pin the search and scroll only the catalogue.
			local listHeight = compact and natural or math.max(control, room - listTop - footerSpace)
			local contentHeight = compact and listTop + natural + footerSpace or room
			modal.content.Size = UDim2.new(1, 0, 0, contentHeight)
			modal.scroll.instance.ScrollingEnabled = compact
			list.instance.ScrollingEnabled = not compact
			list.instance.Size = UDim2.new(1, 0, 0, listHeight)
			if compact then list.instance.CanvasPosition = Vector2.new(0, 0) end
			local providerWidth = math.ceil(P.measureText(providerLabel.Text, { role = "small" }).X)
				+ theme.size.icon * 2 + theme.space.xs * 4
			providerButton.instance.Size = UDim2.new(0, math.min(math.max(control, providerWidth),
				math.max(control, modal.scroll.viewportSize().X)), 0, control)
			fitting = false
		end
		modal.scroll.instance:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() if fit then fit() end end)

		render = function()
			if modal.closed then return end
			local record = providers.active()
			providerLabel.Text = record and record.label or "Add a provider"
			local known = record and models.list(record) or {}
			local nextSignature = (record and record.id or "") .. "\0" .. table.concat(known, "\0")
			if signature ~= nextSignature then
				for _, entry in ipairs(rows) do entry.button.instance:Destroy() end
				rows = {}
				list.instance.CanvasPosition = Vector2.new(0, 0)
				for index, id in ipairs(known) do
					local selected = id == record.model
					local button = P.rowButton(list.instance, { name = "Model_" .. id, height = control,
						selected = selected, bgSelected = theme.color.surfaceActive, radius = theme.radius.sm,
						padding = { x = theme.space.sm }, gap = theme.space.sm, layoutOrder = index,
						onClick = function() providers.setModel(record.id, id); notify() end })
					local label = button.label(id, 1, selected and theme.color.text or theme.color.textSecondary, "small")
					local badge = traits.badge(id)
					local meta = P.text(button.row, { text = badge or "", role = "caption", color = theme.color.textTertiary, auto = "X", layoutOrder = 2 })
					local mark = button.icon("check", 3, theme.color.accentHot)
					mark.Visible = selected
					rows[#rows + 1] = { id = id, free = models.isFree(record, id), button = button, label = label, mark = mark, meta = meta }
				end
				signature = nextSignature
			end
			for _, entry in ipairs(rows) do
				local selected = record and entry.id == record.model
				entry.button.setSelected(selected)
				entry.label.TextColor3 = selected and theme.color.text or theme.color.textSecondary
				entry.mark.Visible = selected == true
				entry.meta.Text = traits.badge(entry.id) or ""
			end
			filterRows()
			renderEffort()
			local chrome = modal.card.Size.Y.Offset - modal.scroll.instance.Size.Y.Offset
			modalProps.height = math.min(theme.size.modelPickerHeight, chrome + listTop
				+ math.min(math.max(#rows, 2), 7) * (control + theme.space.hair) + theme.space.lg
				+ (effort.Visible and effort.Size.Y.Offset + theme.space.md or 0))
			modal.relayout()
			fit()
		end

		P.button(modal.footer, { name = "FetchModels", text = "Refresh", variant = "ghost", size = "sm", layoutOrder = 1,
			onClick = function(button)
				local record = providers.active()
				if not record or fetching then return end
				fetching = true; button.setEnabled(false); button.setText("Fetching…")
				task.spawn(function()
					local ok, found, note = pcall(models.discover, record, { force = true })
					fetching = false
					if modal.closed then return end
					button.setEnabled(true); button.setText("Refresh")
					overlay.toast(tostring(ok and note or found), ok and #found > 0 and "good" or "warn", 3)
					render(); notify()
				end)
			end })
		P.button(modal.footer, { name = "ModelOptions", text = "Options", variant = "ghost", size = "sm", layoutOrder = 2,
			onClick = function(button)
				local record = providers.active()
				local id = record and tostring(record.model):lower() or ""
				local forced = (config.get("agent.forceReasoning", {}) or {})[id] == true
				local options = {
					{ label = "Add model ID", value = "add", icon = "plus" },
					{ label = "Reasoning support", value = "reasoning", selected = forced, detail = "Override for the selected model" },
					{ label = "Context window", value = "context", detail = "Override for the selected model" },
					{ label = "Manage providers", value = "manage", icon = "sliders" },
				}
				overlay.menu({ target = button.instance, options = options, onSelect = function(value)
					if value == "manage" then modal.close(); env.require("ui/app").show("providers"); return end
					if not record then overlay.toast("Add a provider first", "info", 2); return end
					if value == "add" then
						overlay.prompt({ title = "Add a model ID", placeholder = "Exact model ID", confirmText = "Add", onConfirm = function(text)
							local ok, note = models.add(record, text)
							if ok then providers.setModel(record.id, util.trim(text)) end
							overlay.toast(tostring(note), ok and "good" or "warn", 3); notify()
						end })
					elseif id ~= "" and value == "reasoning" then
						local claims = config.get("agent.forceReasoning", {}) or {}
						claims[id] = not forced; config.set("agent.forceReasoning", claims); renderEffort(); notify()
					elseif id ~= "" and value == "context" then
						local claims = config.get("agent.forceContext", {}) or {}
						overlay.prompt({ title = "Context window", description = "Token limit. Leave empty to use the documented value.",
							placeholder = "1000000", value = claims[id] and tostring(claims[id]) or "", confirmText = "Save",
							onConfirm = function(text)
								local number = tonumber(text)
								if util.trim(text) ~= "" and (not number or number <= 0 or number == math.huge) then
									overlay.toast("Enter a positive token count", "warn", 2); return
								end
								claims[id] = number and math.floor(number) or nil
								config.set("agent.forceContext", claims); if not modal.closed then render(); notify() end
							end })
					end
				end })
			end })
		P.button(modal.footer, { name = "PickerDone", text = "Done", variant = "primary", size = "sm", layoutOrder = 3,
			onClick = function() modal.close() end })
		local unsubscribe = providers.changed:connect(function(kind) if kind ~= "health" then render() end end)
		local unsubscribeResponsive = responsive.changed:connect(function()
			if modal.closed then return end
			local target = math.max(theme.size.control, responsive.minTarget())
			if target == control then fit(); return end
			control = target
			searchRow.Position = UDim2.fromOffset(0, control + theme.space.sm)
			searchRow.Size = UDim2.new(1, 0, 0, control)
			search.shell.Size = UDim2.new(1, -(theme.size.metaColumn + theme.space.sm), 0, control)
			freeButton.instance.Size = UDim2.fromOffset(math.max(theme.size.metaColumn, target), control)
			count.Position = UDim2.fromOffset(0, control * 2 + theme.space.sm * 2)
			listTop = control * 2 + theme.space.sm * 3 + theme.text.caption.height
			list.instance.Position = UDim2.fromOffset(0, listTop)
			for _, entry in ipairs(rows) do entry.button.instance.Size = UDim2.new(1, 0, 0, control) end
			render()
		end)
		modal.scrim.Destroying:Connect(function() unsubscribe(); unsubscribeResponsive() end)
		render()
		modal.render = render
		return modal
	end
	return M
end
