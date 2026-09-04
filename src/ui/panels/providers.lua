-- Providers panel: the list, the editor, and the connection test.
--
-- This is the screen that makes the client universal, so it is deliberately plain:
-- a base URL, a key, an auth style and a model. Anything that speaks
-- /v1/chat/completions is a first-class citizen here, and the presets are only a
-- way to avoid typing a URL.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local overlay = env.require("ui/overlay")
	local catalog = env.require("provider/catalog")
	local registry = env.require("provider/registry")
	local models = env.require("provider/models")
	local chat = env.require("provider/chat")

	local M = {}

	local AUTH_OPTIONS = {
		{ value = "bearer", label = "Bearer" },
		{ value = "x-api-key", label = "x-api-key" },
		{ value = "api-key", label = "api-key" },
		{ value = "both", label = "Both" },
		{ value = "none", label = "None" },
	}

	-- Editor -----------------------------------------------------------------

	function M.editor(record, onSaved)
		local editing = util.deepCopy(record)
		local modal = overlay.modal({
			title = (util.trim(editing.id) == "" ) and "Add provider" or ("Edit " .. tostring(editing.label)),
			description = "Any OpenAI-compatible chat completions endpoint.",
			width = 420,
		})
		if not modal then return end

		local body = P.scroll(modal.content, {
			name = "Form",
			size = UDim2.new(1, 0, 0, math.min(responsive.viewport.Y * 0.5, 420)),
			-- Each row is a label, a control and often a hint, so the gap between rows
			-- has to be clearly larger than the gaps inside one or the hint reads as a
			-- caption for the row below it.
			gap = theme.space.lg,
			padding = { right = theme.space.sm },
		})

		local errorLabel

		local function row(label, hint, build)
			local column = P.column(body.instance, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
			})
			P.text(column, {
				text = tostring(label):upper(),
				role = "overline",
				color = theme.color.textTertiary,
			})
			local handle = build(column)
			if hint then
				P.text(column, {
					text = hint,
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
				})
			end
			return handle
		end

		if util.trim(editing.id) == "" then
			row("Preset", nil, function(column)
				local options = {}
				for _, preset in ipairs(catalog.presets) do
					options[#options + 1] = {
						label = preset.label,
						value = preset.id,
						detail = preset.baseUrl ~= "" and preset.baseUrl or "custom endpoint",
						selected = preset.id == editing.preset,
					}
				end
				local button = P.button(column, {
					text = (catalog.get(editing.preset) or {}).label or "Choose",
					variant = "secondary",
					fill = true,
					align = "Left",
					icon = "chevron",
					iconDirection = "down",
				})
				button.instance.Activated:Connect(function()
					overlay.menu({
						target = button.instance,
						width = 320,
						options = options,
						onSelect = function(value)
							local fresh = registry.blank(value)
							fresh.id = ""
							editing = fresh
							modal.close()
							M.editor(editing, onSaved)
						end,
					})
				end)
				return button
			end)
		end

		local labelField = row("Name", nil, function(column)
			return P.field(column, {
				text = editing.label,
				placeholder = "My provider",
				onChange = function(text) editing.label = text end,
			})
		end)

		local urlField = row("Base URL", "A bare host gets /v1 appended. A URL that already ends in /chat/completions is used as-is.", function(column)
			return P.field(column, {
				text = editing.baseUrl,
				placeholder = "https://api.example.com/v1",
				onChange = function(text) editing.baseUrl = text end,
			})
		end)

		row("API", "Chat completions is the universal one. Anthropic's own Messages API keeps reasoning and tool calls in their real shape instead of translating them twice.", function(column)
			return C.segmented(column, {
				options = chat.STYLES,
				value = chat.styleOf(editing),
				onChange = function(value) editing.api = value end,
			})
		end)

		local keyField = row("API key", "Stored on this device only, and redacted in the log.", function(column)
			return P.field(column, {
				text = editing.apiKey,
				placeholder = (catalog.get(editing.preset) or {}).keyHint or "sk-...",
				onChange = function(text) editing.apiKey = text end,
			})
		end)

		row("Auth header", nil, function(column)
			return C.segmented(column, {
				options = AUTH_OPTIONS,
				value = editing.authStyle,
				onChange = function(value) editing.authStyle = value end,
			})
		end)

		-- Models. Nothing is pre-filled: the list is whatever the endpoint reports
		-- plus whatever the user types. Both are editable here before the record is
		-- ever saved, so an endpoint with no /models route is still usable.
		row("Models", "Fetch them from the endpoint, or add an id by hand. Tap one to make it the active model.", function(column)
			local fetchRow = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			local fetch = P.button(fetchRow, {
				text = "Fetch from /models",
				variant = "secondary",
				size = "sm",
				layoutOrder = 1,
			})
			local note = P.text(fetchRow, {
				text = "",
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
				layoutOrder = 2,
			})
			note.Size = UDim2.new(1, -160, 0, 0)

			local list = P.column(column, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = 2,
			})

			local addRow = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			local addField
			local rebuildList

			local function addTyped()
				local ok, result = models.add(editing, addField.get(), { persist = false })
				if not ok then
					note.Text = tostring(result)
					note.TextColor3 = theme.color.warn
					return
				end
				addField.clear()
				note.Text = "added " .. tostring(result)
				note.TextColor3 = theme.color.textTertiary
				rebuildList()
			end

			addField = P.field(addRow, {
				placeholder = "model id, e.g. gpt-4o or llama3.2",
				size = UDim2.new(1, -(80 + theme.space.xs), 0, math.max(theme.size.control, responsive.minTarget())),
				onSubmit = addTyped,
			})
			local addButton = P.button(addRow, {
				text = "Add",
				variant = "secondary",
				size = "md",
				width = 80,
				layoutOrder = 2,
				onClick = addTyped,
			})
			addButton.instance.LayoutOrder = 2

			-- One row per known model: the record's own entries can be removed, and
			-- discovered ones are marked so it is clear where they came from.
			rebuildList = function()
				for _, child in ipairs(list:GetChildren()) do
					if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then child:Destroy() end
				end

				local own = {}
				for _, id in ipairs(editing.models or {}) do own[id] = true end
				local all = models.list(editing)

				if #all == 0 then
					P.text(list, {
						text = "No models known yet. Fetch them, or type one above.",
						role = "caption",
						color = theme.color.textTertiary,
						wrap = true,
						auto = "Y",
					}).Size = UDim2.new(1, 0, 0, 0)
					return
				end

				for index, id in ipairs(all) do
					local selected = id == editing.model
					local entry = Instance.new("TextButton", list)
					entry.Text = ""
					entry.AutoButtonColor = false
					entry.BackgroundColor3 = selected and theme.color.surfaceActive or theme.color.surfaceRaised
					entry.BackgroundTransparency = selected and 0 or 1
					entry.BorderSizePixel = 0
					entry.Size = UDim2.new(1, 0, 0, math.max(theme.size.controlSmall, responsive.minTarget() - 10))
					entry.LayoutOrder = index
					entry.Selectable = true
					P.corner(entry, theme.radius.sm)

					local entryRow = P.row(entry, {
						size = UDim2.fromScale(1, 1),
						gap = theme.space.xs,
						padding = { x = theme.space.sm },
					})
					P.statusDot(entryRow, {
						diameter = 6,
						color = selected and theme.color.accent or theme.color.borderStrong,
						layoutOrder = 1,
					})
					local label = P.text(entryRow, {
						text = id,
						role = "monoSmall",
						color = selected and theme.color.text or theme.color.textSecondary,
						truncate = true,
						layoutOrder = 2,
					})
					label.Size = UDim2.new(1, -(theme.size.controlSmall + 40), 1, 0)
					if not own[id] then
						P.text(entryRow, {
							text = "fetched",
							role = "caption",
							color = theme.color.textTertiary,
							align = "Right",
							layoutOrder = 3,
						}).Size = UDim2.fromOffset(46, theme.text.caption.size + 4)
					end
					if own[id] then
						local remove = P.iconButton(entryRow, {
							name = "Remove",
							icon = "close",
							diameter = theme.size.controlSmall,
							variant = "ghost",
							layoutOrder = 4,
						})
						remove.instance.LayoutOrder = 4
						remove.instance.Activated:Connect(function()
							models.remove(editing, id, { persist = false })
							rebuildList()
						end)
					end

					entry.Activated:Connect(function()
						editing.model = id
						-- Selecting a fetched model keeps it: the record should not
						-- depend on a cache that expires in ten minutes.
						if not own[id] then models.add(editing, id, { persist = false }) end
						rebuildList()
					end)
				end
			end

			fetch.instance.Activated:Connect(function()
				fetch.setText("Fetching")
				note.TextColor3 = theme.color.textTertiary
				note.Text = ""
				task.spawn(function()
					-- Fetch against the in-progress values, not the saved record, so a
					-- URL or key typed a moment ago is what gets tried. The discovery
					-- cache is keyed by record id, and a not-yet-saved record has an
					-- empty one -- which is a perfectly good key for the draft.
					local candidate = util.deepCopy(editing)
					candidate.baseUrl = registry.normaliseBaseUrl(candidate.baseUrl)
					local found, message = models.discover(candidate, { force = true })
					fetch.setText("Fetch from /models")
					note.Text = tostring(message)
					if #found == 0 then note.TextColor3 = theme.color.warn end
					rebuildList()
				end)
			end)

			rebuildList()
			return list
		end)

		row("Behaviour", nil, function(column)
			local grid = P.column(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.xs })
			local function toggleRow(label, hint, value, onChange)
				local line = P.row(grid, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm })
				local text = P.column(line, {
					size = UDim2.new(1, -46, 0, 0), auto = "Y", gap = 0, layoutOrder = 1,
				})
				P.text(text, { text = label, role = "small" })
				P.text(text, { text = hint, role = "caption", color = theme.color.textTertiary, wrap = true, auto = "Y" })
				local switch = C.switch(line, { value = value, onChange = onChange })
				switch.instance.LayoutOrder = 2
				return switch
			end
			toggleRow("Ask for a stream", "Streamed replies carry reasoning text and token counts.",
				editing.stream ~= false, function(value) editing.stream = value end)
			toggleRow("Send the Claude Code identity", "The claude-cli User-Agent and its client headers.",
				editing.claudeUa ~= false, function(value) editing.claudeUa = value end)
			toggleRow("Enabled", "Disabled providers are skipped by the fallback chain.",
				editing.enabled ~= false, function(value) editing.enabled = value end)
			return grid
		end)

		errorLabel = P.text(modal.content, {
			text = "",
			role = "small",
			color = theme.color.danger,
			wrap = true,
			auto = "Y",
			layoutOrder = 9,
		})
		errorLabel.Size = UDim2.new(1, 0, 0, 0)

		local testButton = P.button(modal.footer, {
			text = "Test",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
		})
		testButton.instance.Activated:Connect(function()
			errorLabel.Text = ""
			testButton.setText("testing")
			task.spawn(function()
				local candidate = util.deepCopy(editing)
				candidate.baseUrl = registry.normaliseBaseUrl(candidate.baseUrl)
				local result, err = chat.complete(candidate, {
					messages = { { role = "user", content = "Reply with the single word: ready" } },
					stream = false,
					maxTokens = 12,
					attempts = 1,
				})
				testButton.setText("Test")
				if result then
					overlay.toast("Reached " .. candidate.label .. " in " .. util.formatDuration(result.ms), "good")
				else
					errorLabel.Text = tostring(err)
				end
			end)
		end)

		P.button(modal.footer, {
			text = "Save",
			variant = "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				local ok, problems = registry.save(editing)
				if not ok then
					errorLabel.Text = table.concat(problems, ". ")
					return
				end
				modal.close()
				overlay.toast("Saved " .. editing.label, "good")
				if onSaved then onSaved() end
			end,
		})
	end

	-- List -------------------------------------------------------------------

	function M.new(parent)
		local panel = { }

		local scroll = P.scroll(parent, {
			name = "Providers",
			size = UDim2.new(1, 0, 1, 0),
			gap = theme.space.sm,
			padding = theme.space.md,
		})

		local function card(record, index)
			local card, layout = P.card(scroll.instance, {
				name = record.id,
				layoutOrder = index,
				gap = theme.space.sm,
			})

			local top = P.row(card, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 1,
			})

			local active = registry.active()
			local isActive = active and active.id == record.id
			P.statusDot(top, {
				diameter = 8,
				layoutOrder = 1,
				color = registry.cooling(record) and theme.color.danger
					or (isActive and theme.color.accent or theme.color.textTertiary),
			})

			local titleColumn = P.column(top, {
				size = UDim2.new(1, -(theme.space.xs + 8 + 96), 0, 0),
				auto = "Y",
				gap = 0,
				layoutOrder = 2,
			})
			P.text(titleColumn, {
				text = record.label .. (isActive and "  (active)" or ""),
				role = "bodyStrong",
				truncate = true,
			})
			P.text(titleColumn, {
				text = record.baseUrl,
				role = "caption",
				color = theme.color.textTertiary,
				truncate = true,
			})

			local switch = C.switch(top, {
				value = record.enabled ~= false,
				onChange = function(value)
					record.enabled = value
					registry.save(record, { force = true })
				end,
			})
			switch.instance.LayoutOrder = 3

			local detail = P.row(card, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 2,
				wrap = true,
			})
			P.badge(detail, { text = record.model ~= "" and record.model or "no model", tone = "info", layoutOrder = 1 })
			P.badge(detail, { text = record.authStyle, tone = "info", layoutOrder = 2 })
			if chat.styleOf(record) == "anthropic" then
				P.badge(detail, { text = "messages api", tone = "good", layoutOrder = 3 })
			end
			if record.claudeUa == false then
				P.badge(detail, { text = "no cli identity", tone = "warn", layoutOrder = 3 })
			end
			local health = record.health or {}
			if (health.ok or 0) + (health.fail or 0) > 0 then
				P.badge(detail, {
					text = string.format("%d ok / %d fail", health.ok or 0, health.fail or 0),
					tone = (health.streak or 0) > 0 and "warn" or "good",
					layoutOrder = 4,
				})
			end

			if health.lastError and health.lastError ~= "" then
				local err = P.text(card, {
					text = health.lastError,
					role = "caption",
					color = theme.color.danger,
					wrap = true,
					auto = "Y",
					layoutOrder = 3,
				})
				err.Size = UDim2.new(1, 0, 0, 0)
			end

			local actions = P.row(card, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 4,
			})
			if not isActive then
				P.button(actions, {
					text = "Use",
					variant = "secondary",
					size = "sm",
					layoutOrder = 1,
					onClick = function()
						registry.setActive(record.id)
						panel.refresh()
					end,
				})
			end
			P.button(actions, {
				text = "Edit",
				variant = "ghost",
				size = "sm",
				layoutOrder = 2,
				onClick = function() M.editor(record, panel.refresh) end,
			})
			P.button(actions, {
				text = "Remove",
				variant = "ghost",
				size = "sm",
				layoutOrder = 3,
				onClick = function()
					overlay.confirm({
						title = "Remove " .. record.label .. "?",
						description = "The endpoint and its key are deleted from this device.",
						confirmText = "Remove",
						danger = true,
						onConfirm = function()
							registry.remove(record.id)
							panel.refresh()
						end,
					})
				end,
			})
			return card
		end

		function panel.refresh()
			scroll.clear()
			local list = registry.list()

			local header = P.row(scroll.instance, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
				layoutOrder = 0,
			})
			local text = P.column(header, {
				size = UDim2.new(1, -120, 0, 0), auto = "Y", gap = 0, layoutOrder = 1,
			})
			P.text(text, { text = "Inference providers", role = "heading" })
			P.text(text, {
				text = util.pluralise(#list, "endpoint") .. " configured. The first healthy one is used; the rest are fallbacks.",
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			local add = P.button(header, {
				text = "Add",
				variant = "primary",
				size = "sm",
				layoutOrder = 2,
				onClick = function()
					local blank = registry.blank("openai")
					M.editor(blank, panel.refresh)
				end,
			})
			add.instance.LayoutOrder = 2

			if #list == 0 then
				C.emptyState(scroll.instance, {
					title = "Nothing configured yet",
					description = "Add an endpoint to start. Presets exist for the common hosts, and 'Custom endpoint' takes any OpenAI-compatible URL, including a local server.",
					action = "Add a provider",
					onAction = function() M.editor(registry.blank("openai"), panel.refresh) end,
					layoutOrder = 1,
				})
				return
			end

			for index, record in ipairs(list) do card(record, index) end
		end

		panel.refresh()
		panel.unsubscribe = registry.changed:connect(function() panel.refresh() end)
		panel.scroll = scroll
		return panel
	end

	return M
end
