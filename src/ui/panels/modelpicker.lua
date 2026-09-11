-- The model picker.
--
-- One decision from the user's point of view -- "what is answering me, and how hard is
-- it allowed to think" -- so it is one surface, and it is the surface behind the
-- composer's model chip.
--
-- Revamped for extreme responsiveness and Claude Code desktop aesthetic:
-- - Responsive 2-column master-detail layout on desktop/wide screens (>=640px):
--   left pane hosts endpoints with live health badges and active indicators; right pane
--   hosts the model catalogue with instant in-place filtering, context window pills,
--   and reasoning effort controls.
-- - Fluid responsive stacked layout on narrow/mobile viewports.
-- - Extreme Responsiveness: 0ms real-time in-place filter typing (toggles row visibility
--   without destroying/rebuilding DOM, zero frame drops, zero focus loss).
-- - Elevated visual polish: solid surfaces, hairline borders, warm coral accents,
--   crisp monospace model identifiers, and segmented pill controls.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local icons = env.require("ui/icons")
	local overlay = env.require("ui/overlay")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local providers = env.require("provider/registry")
	local models = env.require("provider/models")
	local traits = env.require("provider/traits")

	local M = {}

	-- Every level the interface can ask for, cheapest first. A model that documents a
	-- shorter scale gets the shorter scale; one that documents none gets no control,
	-- because an effort picker over a model with no effort parameter is a setting that
	-- changes what is sent to nothing.
	local ALL_EFFORT = { "low", "medium", "high", "xhigh", "max" }

	-- Past this many models the list gets a filter. Below it the filter is a control
	-- that costs a line to say "there are six of these".
	local FILTER_AT = 8

	local function titleCase(text)
		return (tostring(text):gsub("^%l", string.upper))
	end

	-- What a provider row says about itself on the right: the health the registry has
	-- actually recorded, not a guess. A record nothing has been sent through says so
	-- rather than claiming to be well.
	local function healthOf(record)
		local state = record.health or {}
		if providers.cooling(record) then
			return "benched", "bad"
		end
		if (state.fail or 0) > 0 and (state.streak or 0) > 0 then
			return util.pluralise(state.streak, "failure"), "warn"
		end
		if (state.ok or 0) > 0 then
			local ms = tonumber(state.lastMs)
			if ms and ms > 0 then
				return string.format("%s  \194\183  %s", util.pluralise(state.ok, "call"),
					util.formatDuration(ms)), "good"
			end
			return util.pluralise(state.ok, "call"), "good"
		end
		return "not tried yet", "neutral"
	end

	-- Opens it. `onChange` is called after anything is selected, so the composer can
	-- repaint its chip without this module knowing what a composer is.
	function M.open(onChange)
		local modal = overlay.modal({
			title = "Model",
			description = "What answers, and how hard it is asked to think. "
				.. "Only endpoints this client has and ids they reported are listed.",
			width = theme.size.dialog,
			height = 620,
			scroll = true,
		})
		if not modal then return nil end

		local function notify()
			if onChange then pcall(onChange) end
		end

		local body = modal.content
		local function clear()
			for _, child in ipairs(body:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
		end

		local filter = ""
		local freeOnly = false
		local render

		-- Selectable row styled with elevated, spacious Claude Code card aesthetic.
		local function pickRow(parent, props)
			local height = math.max(props.height or 56, responsive.minTarget())
			local isSelected = props.selected == true
			local row = P.rowButton(parent, {
				name = props.name,
				height = height,
				size = UDim2.new(1, 0, 0, height),
				bg = isSelected and theme.color.surfaceActive or theme.color.surface,
				stroke = true,
				strokeColor = isSelected and theme.color.accentBorder or theme.color.borderSubtle,
				selected = isSelected,
				radius = theme.radius.md,
				gap = theme.space.md,
				padding = { left = theme.space.md, right = theme.space.md, top = theme.space.sm, bottom = theme.space.sm },
				layoutOrder = props.layoutOrder,
				onClick = props.onClick,
			})

			-- Left accent bar on active selection for instant visual grounding
			local indicator = P.frame(row.row, {
				name = "ActiveIndicator",
				size = UDim2.new(0, 3, 0, height - theme.space.lg),
				bg = isSelected and theme.color.accentHot or theme.color.transparent,
				radius = theme.radius.pill,
				layoutOrder = 0,
			})

			-- Selection mark icon
			local mark = P.frame(row.row, {
				name = "Mark",
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
				layoutOrder = 1,
			})
			if isSelected then
				icons.check(mark, theme.size.icon, theme.color.accentHot)
			end

			local column = P.column(row.row, {
				size = UDim2.new(0, 0, 1, 0),
				flex = "Fill",
				gap = theme.space.xxs,
				alignY = "Center",
				layoutOrder = 2,
			})
			P.text(column, {
				name = "Title",
				text = tostring(props.title or ""),
				role = props.mono and "monoSmall" or "small",
				color = props.tone and theme.toneColor(props.tone)
					or (isSelected and theme.color.text or theme.color.textSecondary),
				size = UDim2.new(1, 0, 0, theme.textRole(props.mono and "monoSmall" or "small").height),
				truncate = true,
				layoutOrder = 1,
			})
			if props.detail then
				P.text(column, {
					name = "Detail",
					text = tostring(props.detail),
					role = "caption",
					color = theme.color.textTertiary,
					size = UDim2.new(1, 0, 0, theme.text.caption.height),
					truncate = true,
					layoutOrder = 2,
				})
			end

			if props.badge then
				P.badge(row.row, {
					text = tostring(props.badge),
					tone = props.badgeTone or "neutral",
					layoutOrder = 3,
				})
			end
			if props.status then
				local label = P.text(row.row, {
					name = "Status",
					text = tostring(props.status),
					role = "caption",
					color = theme.toneColor(props.statusTone or "neutral"),
					align = "Right",
					auto = "X",
					layoutOrder = 4,
				})
				label.Size = UDim2.fromOffset(0, theme.text.caption.height)
			end
			return row
		end

		-- Builds the footer buttons (Fetch, Keep Free, Add ID, Manage, Done)
		local function updateFooter()
			for _, child in ipairs(modal.footer:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end

			local record = providers.active()
			if record then
				P.button(modal.footer, {
					name = "FetchModels",
					text = "Fetch from /models",
					variant = "ghost",
					size = "sm",
					layoutOrder = 1,
					onClick = function()
						overlay.toast("Fetching models from " .. record.label, "info", 2)
						task.spawn(function()
							local found, note = models.discover(record, { force = true })
							overlay.toast(tostring(note), #found > 0 and "good" or "warn", 3)
							notify()
							if not modal.closed then render() end
						end)
					end,
				})

				local freeIds = {}
				for _, id in ipairs(models.list(record)) do
					if tostring(id):lower():find("free", 1, true) then freeIds[#freeIds + 1] = id end
				end
				if #freeIds > 0 then
					P.button(modal.footer, {
						name = "KeepFreeModels",
						text = "Keep only free",
						variant = "ghost",
						size = "sm",
						layoutOrder = 2,
						onClick = function()
							record.models = util.deepCopy(freeIds)
							record.model = freeIds[1]
							providers.save(record, { force = true })
							notify()
							overlay.toast(string.format("Kept %s -- the rest were only fetched, never saved",
								util.pluralise(#freeIds, "free model")), "good", 3)
							if not modal.closed then render() end
						end,
					})
				end

				P.button(modal.footer, {
					name = "AddModel",
					text = "Add an id",
					variant = "ghost",
					size = "sm",
					layoutOrder = 3,
					onClick = function()
						overlay.prompt({
							title = "Add a model to " .. record.label,
							description = "Type the id exactly as the provider expects it. "
								.. "It is saved to this provider and selected.",
							placeholder = "model id",
							confirmText = "Add",
							onConfirm = function(text)
								local ok, result = models.add(record, text)
								if ok then providers.setModel(record.id, util.trim(text)) end
								overlay.toast(tostring(result), ok and "good" or "warn", 3)
								notify()
								if not modal.closed then render() end
							end,
						})
					end,
				})
			end

			P.button(modal.footer, {
				name = "ManageProviders",
				text = "Manage",
				variant = "ghost",
				size = "sm",
				layoutOrder = 4,
				onClick = function()
					modal.close()
					env.require("ui/app").show("providers")
				end,
			})

			P.button(modal.footer, {
				name = "PickerDone",
				text = "Done",
				variant = "primary",
				size = "sm",
				layoutOrder = 5,
				onClick = function() modal.close() end,
			})
		end

		render = function()
			clear()
			updateFooter()

			local record = providers.active()
			local list = providers.list()

			if #list == 0 then
				C.emptyState(body, {
					title = "No provider configured",
					description = "Add an OpenAI-compatible endpoint to start. Anything that speaks "
						.. "/v1/chat/completions works: a hosted API, a relay, or a local server.",
					action = "Open providers",
					onAction = function()
						modal.close()
						env.require("ui/app").show("providers")
					end,
					layoutOrder = 1,
				})
				return
			end

			-- Check wide master-detail layout threshold (>= 640px and not sheet mode)
			local isWide = (responsive.viewport.X >= 640) and (responsive.mode ~= "sheet")

			-- Prepare models & traits state
			local known = record and models.list(record) or {}
			local own = {}
			if record then
				for _, id in ipairs(record.models or {}) do own[id] = true end
			end

			-- Fast model row collection for instant 0ms filtering
			local modelRowEntries = {}
			local modelCountLabel = nil
			local emptySearchCard = nil
			local freeChip = nil
			local freeChipLabel = nil

			local function applyModelFilter()
				local needle = util.trim(filter):lower()
				local visibleCount = 0
				for _, entry in ipairs(modelRowEntries) do
					local match = true
					if needle ~= "" and not entry.idLower:find(needle, 1, true) then
						match = false
					elseif freeOnly and not entry.isFree then
						match = false
					end
					entry.row.instance.Visible = match
					if match then
						visibleCount = visibleCount + 1
					end
				end

				if modelCountLabel then
					local detailText = (visibleCount == #known)
						and util.pluralise(#known, "model")
						or string.format("%d of %s", visibleCount, util.pluralise(#known, "model"))
					modelCountLabel.Text = detailText
				end

				if emptySearchCard then
					emptySearchCard.Visible = (visibleCount == 0 and #known > 0)
				end
			end

			local function renderReasoningAndClaims(container, orderStart)
				local order = orderStart or 10

				-- 3. Reasoning Effort Section
				local levels = record and traits.effortLevels(record.model)
				local wanted = tostring(config.get("agent.effort", "high"))

				local effortCol = P.column(container, {
					name = "Section_ReasoningEffort",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					layoutOrder = order,
				})
				order = order + 1

				if levels then
					local sending = traits.nearestEffort(record.model, wanted) or wanted
					local note = (sending ~= wanted)
						and string.format("%s is the most this model has", titleCase(sending))
						or nil

					local effortHead = P.row(effortCol, {
						size = UDim2.new(1, 0, 0, theme.text.label.height),
						gap = theme.space.xs,
						padding = { x = theme.space.xxs },
						layoutOrder = 1,
					})
					P.text(effortHead, {
						text = "Reasoning effort",
						role = "label",
						color = theme.color.text,
						size = UDim2.new(0, 0, 1, 0),
						flex = "Fill",
						truncate = true,
						layoutOrder = 1,
					})
					if note then
						local noteLabel = P.text(effortHead, {
							text = note,
							role = "caption",
							color = theme.color.textTertiary,
							align = "Right",
							auto = "X",
							layoutOrder = 2,
						})
						noteLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)
					end

					-- Horizontal segmented pill row for effort levels
					local pillRow = P.row(effortCol, {
						name = "EffortPills",
						size = UDim2.new(1, 0, 0, theme.size.controlLarge),
						gap = theme.space.xs,
						layoutOrder = 2,
					})

					for index, level in ipairs(levels) do
						local isSelected = (level == sending)
						local isDefault = traits.defaultEffort(record.model) == level
						local btn = P.rowButton(pillRow, {
							name = "Effort_" .. level,
							height = theme.size.controlLarge,
							flex = "Fill",
							bg = isSelected and theme.color.accentSurface or theme.color.surface,
							stroke = true,
							strokeColor = isSelected and theme.color.accentBorder or theme.color.borderSubtle,
							radius = theme.radius.md,
							selected = isSelected,
							alignX = "Center",
							layoutOrder = index,
							onClick = function()
								config.set("agent.effort", level)
								notify()
								render()
							end,
						})
						P.text(btn.row, {
							text = titleCase(level),
							role = "bodyStrong",
							color = isSelected and theme.color.accentHot or theme.color.textSecondary,
							align = "Center",
							auto = "XY",
						})
					end

					local activeDefault = traits.defaultEffort(record.model) == sending
					if activeDefault then
						P.text(effortCol, {
							name = "EffortCaption",
							text = "Default setting used by the provider API when none is sent",
							role = "caption",
							color = theme.color.textTertiary,
							wrap = true,
							auto = "Y",
							padding = { x = theme.space.xxs },
							layoutOrder = 3,
						})
					end
				else
					local effortHead = P.row(effortCol, {
						size = UDim2.new(1, 0, 0, theme.text.label.height),
						gap = theme.space.xs,
						padding = { x = theme.space.xxs },
						layoutOrder = 1,
					})
					P.text(effortHead, {
						text = "Reasoning effort",
						role = "label",
						color = theme.color.text,
						size = UDim2.new(0, 0, 1, 0),
						flex = "Fill",
						layoutOrder = 1,
					})
					local offLabel = P.text(effortHead, {
						text = "not offered",
						role = "caption",
						color = theme.color.textTertiary,
						align = "Right",
						auto = "X",
						layoutOrder = 2,
					})
					offLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)

					local forced = record and traits.thinkingStyle(record.model) == "adaptive"
					local note = P.text(effortCol, {
						name = "NoEffort",
						text = forced
							and ("%s publishes no effort scale this client knows, but reasoning has been "
								.. "declared by hand, so the setting (%s) is sent as it stands."):format(
								record and record.model ~= "" and record.model or "This model", titleCase(wanted))
							or ("%s publishes no effort scale this client knows, so none is sent and the setting "
								.. "(%s) is not applied to it."):format(
								record and record.model ~= "" and record.model or "This model", titleCase(wanted)),
						role = "caption",
						color = theme.color.textTertiary,
						wrap = true,
						auto = "Y",
						padding = { x = theme.space.sm, y = theme.space.xs },
						layoutOrder = 2,
					})
					note.Size = UDim2.new(1, 0, 0, 0)
				end

				-- 4. Declared by Hand Section
				local id = tostring(record and record.model or ""):lower()
				if id ~= "" then
					local claimCol = P.column(container, {
						name = "Section_DeclaredByHand",
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.xs,
						layoutOrder = order,
					})
					order = order + 1

					local claimHead = P.row(claimCol, {
						size = UDim2.new(1, 0, 0, theme.text.label.height),
						gap = theme.space.xs,
						padding = { x = theme.space.xxs },
						layoutOrder = 1,
					})
					P.text(claimHead, {
						text = "Declared by hand",
						role = "label",
						color = theme.color.text,
						size = UDim2.new(0, 0, 1, 0),
						flex = "Fill",
						layoutOrder = 1,
					})
					local subLabel = P.text(claimHead, {
						text = "for this model only",
						role = "caption",
						color = theme.color.textTertiary,
						align = "Right",
						auto = "X",
						layoutOrder = 2,
					})
					subLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)

					local claimRows = P.column(claimCol, {
						name = "ClaimRows",
						size = UDim2.new(1, 0, 0, 0),
						auto = "Y",
						gap = theme.space.xs,
						layoutOrder = 2,
					})

					local forcedReasoning = (config.get("agent.forceReasoning", {}) or {})[id] == true
					pickRow(claimRows, {
						name = "ForceReasoning",
						title = "Reasoning support",
						detail = forcedReasoning
							and "thinking is asked for, and the effort setting is sent"
							or "no thinking block is sent to this model",
						selected = forcedReasoning,
						layoutOrder = 1,
						onClick = function()
							local claims = config.get("agent.forceReasoning", {}) or {}
							claims[id] = not forcedReasoning
							config.set("agent.forceReasoning", claims)
							notify()
							render()
						end,
					})

					local claimed = tonumber((config.get("agent.forceContext", {}) or {})[id])
					local current = claimed or traits.contextWindow(record.model)
					pickRow(claimRows, {
						name = "ForceContext",
						title = "Context window",
						detail = current
							and (util.formatCompact(current) .. " tokens"
								.. (claimed and "  \194\183  declared by hand" or "  \194\183  documented"))
							or "not known to this client",
						selected = claimed ~= nil,
						layoutOrder = 2,
						onClick = function()
							overlay.prompt({
								title = "Declare the context window",
								description = "Tokens this model can hold, as the provider documents it. "
									.. "This is what the badge shows and the context budget slider works against. "
									.. "Leave it empty to go back to what this client knows on its own.",
								placeholder = "1000000",
								value = claimed and tostring(claimed) or "",
								confirmText = "Declare",
								onConfirm = function(text)
									local claims = config.get("agent.forceContext", {}) or {}
									local clean = util.trim(text)
									local number = tonumber(clean)
									if clean == "" or not number or number <= 0 then
										claims[id] = nil
									else
										claims[id] = math.floor(number)
									end
									config.set("agent.forceContext", claims)
									notify()
									if not modal.closed then render() end
								end,
							})
						end,
					})
				end
			end

			-- ================================================================
			-- Layout: Wide Two-Pane (>=640px) vs Fluid Stacked (<640px)
			-- ================================================================
			if isWide then
				-- Disable outer scroll to avoid nested scroll conflict
				modal.scroll.instance.ScrollingEnabled = false
				body.Size = UDim2.fromScale(1, 1)
				body.AutomaticSize = Enum.AutomaticSize.None

				local splitRow = P.row(body, {
					name = "SplitLayout",
					size = UDim2.fromScale(1, 1),
					gap = theme.space.md,
				})

				-- 1. Left Pane: Endpoints Rail
				local leftCol = P.column(splitRow, {
					name = "Section_Endpoint",
					size = UDim2.new(0, 260, 1, 0),
					gap = theme.space.xs,
					layoutOrder = 1,
				})

				local leftHead = P.row(leftCol, {
					size = UDim2.new(1, 0, 0, theme.text.label.height),
					gap = theme.space.xs,
					padding = { x = theme.space.xxs },
					layoutOrder = 1,
				})
				P.text(leftHead, {
					text = "Endpoints",
					role = "label",
					color = theme.color.text,
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					truncate = true,
					layoutOrder = 1,
				})
				local endpointCount = P.text(leftHead, {
					text = string.format("%d configured", #list),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 2,
				})
				endpointCount.Size = UDim2.fromOffset(0, theme.text.caption.height)

				local endpointScroll = P.scroll(leftCol, {
					name = "EndpointScroll",
					size = UDim2.new(1, 0, 1, -(theme.text.label.height + theme.space.xs)),
					gap = theme.space.xs,
					padding = { right = theme.space.xs, top = theme.space.xxs, bottom = theme.space.sm },
					layoutOrder = 2,
				})

				local endpointRows = P.column(endpointScroll.instance, {
					name = "Rows",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
				})

				for index, entry in ipairs(list) do
					local status, tone = healthOf(entry)
					local isActive = record and record.id == entry.id
					pickRow(endpointRows, {
						name = "Provider_" .. tostring(entry.id),
						title = entry.label,
						detail = entry.baseUrl,
						status = status,
						statusTone = tone,
						selected = isActive,
						layoutOrder = index,
						onClick = function()
							if isActive then return end
							providers.setActive(entry.id)
							notify()
							render()
						end,
					})
				end

				-- Vertical Hairline Divider
				P.frame(splitRow, {
					name = "SplitDivider",
					size = UDim2.new(0, 1, 1, 0),
					bg = theme.color.borderSubtle,
					layoutOrder = 2,
				})

				-- 2. Right Pane: Models, Search Filter & Settings
				local rightCol = P.column(splitRow, {
					name = "RightPane",
					size = UDim2.new(1, -(260 + 1 + theme.space.md), 1, 0),
					gap = theme.space.xs,
					layoutOrder = 3,
				})

				local rightHead = P.row(rightCol, {
					size = UDim2.new(1, 0, 0, theme.text.label.height),
					gap = theme.space.xs,
					padding = { x = theme.space.xxs },
					layoutOrder = 1,
				})
				P.text(rightHead, {
					text = record and ("Model on " .. record.label) or "Models",
					role = "label",
					color = theme.color.text,
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					truncate = true,
					layoutOrder = 1,
				})
				modelCountLabel = P.text(rightHead, {
					text = util.pluralise(#known, "model"),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 2,
				})
				modelCountLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)

				-- Filter & FreeOnly toolbar (pinned above models list)
				local toolbarHeight = 0
				if #known >= FILTER_AT then
					local filterRow = P.row(rightCol, {
						name = "FilterRow",
						size = UDim2.new(1, 0, 0, theme.size.control),
						gap = theme.space.xs,
						layoutOrder = 2,
					})
					toolbarHeight = theme.size.control + theme.space.xs

					local freeCount = 0
					for _, id in ipairs(known) do
						if tostring(id):lower():find("free", 1, true) then freeCount = freeCount + 1 end
					end

					-- Instant 0ms Filter field
					P.field(filterRow, {
						name = "ModelFilter",
						placeholder = "Filter these " .. tostring(#known) .. " ids",
						text = filter,
						height = theme.size.control,
						flex = "Fill",
						layoutOrder = 1,
						onChange = function(text)
							filter = text
							applyModelFilter()
						end,
					})

					if freeCount > 0 then
						freeChip = P.rowButton(filterRow, {
							name = "FreeOnly",
							auto = "X",
							height = theme.size.control,
							bg = freeOnly and theme.color.accentSurface or theme.color.surface,
							stroke = true,
							strokeColor = freeOnly and theme.color.accentBorder or theme.color.borderSubtle,
							radius = theme.radius.md,
							gap = theme.space.xxs,
							padding = { x = theme.space.sm },
							layoutOrder = 2,
							onClick = function()
								freeOnly = not freeOnly
								if freeChip then
									freeChip.setSelected(freeOnly)
								end
								applyModelFilter()
							end,
						})
						freeChip.icon("circleHollow", 1,
							freeOnly and theme.color.accentHot or theme.color.textTertiary,
							theme.size.icon - theme.space.hair)
						freeChipLabel = P.text(freeChip.row, {
							name = "FreeOnlyLabel",
							text = string.format("free only  %d of %d", freeCount, #known),
							role = "caption",
							color = freeOnly and theme.color.accentHot or theme.color.textSecondary,
							auto = "X",
							layoutOrder = 2,
						})
					end
				end

				-- Scrollable content for models and settings
				local rightScroll = P.scroll(rightCol, {
					name = "ModelScroll",
					size = UDim2.new(1, 0, 1, -(theme.text.label.height + theme.space.xs + toolbarHeight)),
					gap = theme.space.md,
					padding = { right = theme.space.xs, top = theme.space.xxs, bottom = theme.space.sm },
					layoutOrder = 3,
				})

				local rightScrollContent = P.column(rightScroll.instance, {
					name = "RightContent",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.md,
				})

				local modelList = P.column(rightScrollContent, {
					name = "Rows",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					layoutOrder = 1,
				})

				for index, id in ipairs(known) do
					local badge = traits.badge(id)
					local where = own[id] and "added on this client" or "reported by /models"
					local isFree = tostring(id):lower():find("free", 1, true) ~= nil
					local row = pickRow(modelList, {
						name = "Model_" .. tostring(id),
						title = id,
						mono = true,
						detail = where,
						badge = badge,
						selected = record and (id == record.model),
						layoutOrder = index,
						onClick = function()
							if record then
								providers.setModel(record.id, id)
								notify()
								render()
							end
						end,
					})
					modelRowEntries[#modelRowEntries + 1] = {
						id = id,
						idLower = tostring(id):lower(),
						isFree = isFree,
						row = row,
					}
				end

				emptySearchCard = P.frame(modelList, {
					name = "EmptySearch",
					size = UDim2.new(1, 0, 0, 48),
					bg = theme.color.surface,
					radius = theme.radius.md,
					padding = { x = theme.space.md },
					layoutOrder = #known + 1,
				})
				emptySearchCard.Visible = false
				P.text(emptySearchCard, {
					text = "No models match your current filter.",
					role = "small",
					color = theme.color.textTertiary,
					align = "Center",
					size = UDim2.fromScale(1, 1),
				})

				-- Divider before Effort & Claims
				P.frame(rightScrollContent, {
					name = "ContentDivider",
					size = UDim2.new(1, 0, 0, 1),
					bg = theme.color.borderSubtle,
					layoutOrder = 2,
				})

				renderReasoningAndClaims(rightScrollContent, 3)

				applyModelFilter()

			else
				-- Fluid stacked single-scroll layout for narrow/mobile screens
				modal.scroll.instance.ScrollingEnabled = true
				body.Size = UDim2.new(1, 0, 0, 0)
				body.AutomaticSize = Enum.AutomaticSize.Y

				local order = 0
				local function nextOrder()
					order = order + 1
					return order
				end

				-- 1. Endpoint Section
				local endpointSection = P.column(body, {
					name = "Section_Endpoint",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xxs,
					layoutOrder = nextOrder(),
				})
				local endpointHead = P.row(endpointSection, {
					size = UDim2.new(1, 0, 0, theme.text.label.height),
					gap = theme.space.xs,
					padding = { x = theme.space.xxs },
					layoutOrder = 1,
				})
				P.text(endpointHead, {
					text = "Endpoint",
					role = "label",
					color = theme.color.text,
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					truncate = true,
					layoutOrder = 1,
				})
				local endpointCount = P.text(endpointHead, {
					text = string.format("%d configured", #list),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 2,
				})
				endpointCount.Size = UDim2.fromOffset(0, theme.text.caption.height)

				local endpointRows = P.column(endpointSection, {
					name = "Rows",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					layoutOrder = 2,
				})
				for index, entry in ipairs(list) do
					local status, tone = healthOf(entry)
					local isActive = record and record.id == entry.id
					pickRow(endpointRows, {
						name = "Provider_" .. tostring(entry.id),
						title = entry.label,
						detail = entry.baseUrl,
						status = status,
						statusTone = tone,
						selected = isActive,
						layoutOrder = index,
						onClick = function()
							if isActive then return end
							providers.setActive(entry.id)
							notify()
							render()
						end,
					})
				end

				if not record then return end

				-- 2. Models Section
				local modelSection = P.column(body, {
					name = "Section_Modelon" .. record.label:gsub("%s+", ""),
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xxs,
					layoutOrder = nextOrder(),
				})
				local modelHead = P.row(modelSection, {
					size = UDim2.new(1, 0, 0, theme.text.label.height),
					gap = theme.space.xs,
					padding = { x = theme.space.xxs },
					layoutOrder = 1,
				})
				P.text(modelHead, {
					text = "Model on " .. record.label,
					role = "label",
					color = theme.color.text,
					size = UDim2.new(0, 0, 1, 0),
					flex = "Fill",
					truncate = true,
					layoutOrder = 1,
				})
				modelCountLabel = P.text(modelHead, {
					text = util.pluralise(#known, "model"),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 2,
				})
				modelCountLabel.Size = UDim2.fromOffset(0, theme.text.caption.height)

				local modelRowsHolder = P.column(modelSection, {
					name = "Rows",
					size = UDim2.new(1, 0, 0, 0),
					auto = "Y",
					gap = theme.space.xs,
					layoutOrder = 2,
				})

				if #known >= FILTER_AT then
					local freeCount = 0
					for _, id in ipairs(known) do
						if tostring(id):lower():find("free", 1, true) then freeCount = freeCount + 1 end
					end

					P.field(modelRowsHolder, {
						name = "ModelFilter",
						placeholder = "Filter these " .. tostring(#known) .. " ids",
						text = filter,
						height = theme.size.control,
						layoutOrder = 0,
						onChange = function(text)
							filter = text
							applyModelFilter()
						end,
					})

					if freeCount > 0 then
						local chipRow = P.row(modelRowsHolder, {
							name = "FreeChipRow",
							size = UDim2.new(1, 0, 0, 0),
							auto = "Y",
							layoutOrder = 0,
						})
						freeChip = P.rowButton(chipRow, {
							name = "FreeOnly",
							auto = "X",
							height = theme.size.chip,
							size = UDim2.fromOffset(0, theme.size.chip),
							bg = freeOnly and theme.color.accentSurface or theme.color.surface,
							stroke = true,
							strokeColor = freeOnly and theme.color.accentBorder or theme.color.borderSubtle,
							radius = theme.radius.sm,
							gap = theme.space.xxs,
							padding = { x = theme.space.xs },
							onClick = function()
								freeOnly = not freeOnly
								if freeChip then freeChip.setSelected(freeOnly) end
								applyModelFilter()
							end,
						})
						freeChip.icon("circleHollow", 1,
							freeOnly and theme.color.accentHot or theme.color.textTertiary,
							theme.size.icon - theme.space.hair)
						freeChipLabel = P.text(freeChip.row, {
							name = "FreeOnlyLabel",
							text = string.format("free only  %d of %d", freeCount, #known),
							role = "caption",
							color = freeOnly and theme.color.accentHot or theme.color.textSecondary,
							auto = "X",
							layoutOrder = 2,
						})
					end
				end

				for index, id in ipairs(known) do
					local badge = traits.badge(id)
					local where = own[id] and "added on this client" or "reported by /models"
					local isFree = tostring(id):lower():find("free", 1, true) ~= nil
					local row = pickRow(modelRowsHolder, {
						name = "Model_" .. tostring(id),
						title = id,
						mono = true,
						detail = where,
						badge = badge,
						selected = record and (id == record.model),
						layoutOrder = index,
						onClick = function()
							if record then
								providers.setModel(record.id, id)
								notify()
								render()
							end
						end,
					})
					modelRowEntries[#modelRowEntries + 1] = {
						id = id,
						idLower = tostring(id):lower(),
						isFree = isFree,
						row = row,
					}
				end

				emptySearchCard = P.frame(modelRowsHolder, {
					name = "EmptySearch",
					size = UDim2.new(1, 0, 0, 48),
					bg = theme.color.surface,
					radius = theme.radius.md,
					padding = { x = theme.space.md },
					layoutOrder = #known + 1,
				})
				emptySearchCard.Visible = false
				P.text(emptySearchCard, {
					text = "No models match your current filter.",
					role = "small",
					color = theme.color.textTertiary,
					align = "Center",
					size = UDim2.fromScale(1, 1),
				})

				renderReasoningAndClaims(body, nextOrder())
				applyModelFilter()
			end
		end

		render()

		-- Reactive signals: update on provider state change or screen resize
		local unsubscribeProviders = providers.changed:connect(function()
			if modal.closed then return end
			render()
		end)

		local unsubscribeResponsive = responsive.changed:connect(function()
			if modal.closed then return end
			render()
		end)

		modal.scrim.Destroying:Connect(function()
			pcall(unsubscribeProviders)
			pcall(unsubscribeResponsive)
		end)

		modal.render = render
		return modal
	end

	return M
end