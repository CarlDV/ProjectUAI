-- The model picker.
--
-- One decision from the user's point of view -- "what is answering me, and how hard is
-- it allowed to think" -- so it is one surface, and it is the surface behind the
-- composer's model chip.
--
-- It used to be an anchored menu with four unrelated kinds of row stacked in it: every
-- provider, then every model on the active one, then a fetch, then five effort levels,
-- then "Manage providers". Twenty-odd rows of one visual weight, no headings, and the
-- only way to tell a provider row from a model row was to recognise the string -- which
-- on a gateway that serves eighty ids meant scrolling a 320px menu past the thing you
-- came for. A menu is the right shape for "pick one of six"; this is not that.
--
-- What is here instead is a modal with the three parts of the decision separated and a
-- filter over the long one. Every row is a real record: a provider this client has, a
-- model the endpoint reported or the user typed, an effort level the model documents.
-- Nothing is listed that cannot be selected, which is why the model list can legitimately
-- be empty until a fetch or an id has happened.
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
					util.formatDuration(ms))
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
			-- The model list is as long as the endpoint's catalogue -- eighty ids on a
			-- gateway -- so this is bounded and scrolled rather than as tall as its
			-- contents. The overlay owns the arithmetic: it knows the inset and the
			-- keyboard, which is more than this surface should have to.
			scroll = true,
		})
		if not modal then return nil end

		local function notify()
			if onChange then pcall(onChange) end
		end

		-- The three sections go in the modal's own scrolling body, which is what
		-- `scroll = true` above bought. `body` is the column inside it; `clear` empties
		-- that column, because a re-render replaces every section rather than patching
		-- rows -- selecting a provider changes which models exist, so there is nothing to
		-- patch.
		local body = modal.content
		local function clear()
			for _, child in ipairs(body:GetChildren()) do
				if child:IsA("GuiObject") then child:Destroy() end
			end
		end

		local filter = ""
		local render

		-- A section: a quiet heading with a count beside it, then the rows under it.
		-- The heading is what the old menu had no way to express, and it is most of the
		-- difference between this and that.
		local function section(order, title, detail)
			local column = P.column(body, {
				name = "Section_" .. title:gsub("%s+", ""),
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xxs,
				layoutOrder = order,
			})
			local head = P.row(column, {
				size = UDim2.new(1, 0, 0, theme.text.label.height),
				gap = theme.space.xs,
				padding = { x = theme.space.xxs },
				layoutOrder = 1,
			})
			P.text(head, {
				text = title,
				role = "label",
				color = theme.color.text,
				size = UDim2.new(0, 0, 1, 0),
				flex = "Fill",
				truncate = true,
				layoutOrder = 1,
			})
			if detail then
				local label = P.text(head, {
					text = tostring(detail),
					role = "caption",
					color = theme.color.textTertiary,
					align = "Right",
					auto = "X",
					layoutOrder = 2,
				})
				label.Size = UDim2.fromOffset(0, theme.text.caption.height)
			end
			-- Not named `body`: that is the modal's own column, one scope up, and shadowing
			-- it here would mean the next person to add a line to this function reaches for
			-- the section's rows and gets them.
			return P.column(column, {
				name = "Rows",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.hair,
				layoutOrder = 2,
			})
		end

		-- One selectable row: a leading mark, a title over a detail line, and an
		-- optional badge. Two lines rather than one because every row in here has a
		-- second fact worth reading -- an endpoint, a context window, what an effort
		-- level costs -- and the old menu put those in a `detail` that only showed on
		-- rows that happened to set it.
		local function pickRow(parent, props)
			local height = math.max(theme.size.controlLarge + theme.space.xs, responsive.minTarget())
			local row = P.rowButton(parent, {
				name = props.name,
				height = height,
				size = UDim2.new(1, 0, 0, height),
				bg = props.selected and theme.color.surfaceActive or nil,
				selected = props.selected,
				radius = theme.radius.md,
				gap = theme.space.sm,
				padding = { x = theme.space.sm },
				layoutOrder = props.layoutOrder,
				onClick = props.onClick,
			})

			-- The selected mark, in a slot that is there whether or not it is filled: a
			-- check that appears only on one row and shifts every other row's text by
			-- sixteen pixels is what makes a list look like it is jumping.
			local mark = P.frame(row.row, {
				name = "Mark",
				size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
				layoutOrder = 1,
			})
			if props.selected then
				icons.check(mark, theme.size.icon, theme.color.accent)
			end

			local column = P.column(row.row, {
				size = UDim2.new(0, 0, 1, 0),
				flex = "Fill",
				gap = 0,
				alignY = "Center",
				layoutOrder = 2,
			})
			P.text(column, {
				name = "Title",
				text = tostring(props.title or ""),
				role = props.mono and "monoSmall" or "small",
				color = props.tone and theme.toneColor(props.tone)
					or (props.selected and theme.color.text or theme.color.textSecondary),
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

		render = function()
			clear()
			local record = providers.active()
			local order = 0
			local function nextOrder()
				order = order + 1
				return order
			end

			-- 1. Where the request goes. Listed even when there is one, because the row is
			-- also where its health is stated and that is the thing worth seeing when a
			-- turn has just failed.
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
					layoutOrder = nextOrder(),
				})
			else
				local providerRows = section(nextOrder(), "Endpoint",
					util.pluralise(#list, "configured"))
				for index, entry in ipairs(list) do
					local status, tone = healthOf(entry)
					local isActive = record and record.id == entry.id
					pickRow(providerRows, {
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
			end

			if not record then
				return
			end

			-- 2. Which model on it. The filter earns its line only on a list long enough
			-- to need one, and it filters rather than searching: everything here is
			-- already local.
			local known = models.list(record)
			local own = {}
			for _, id in ipairs(record.models or {}) do own[id] = true end

			local shown = {}
			local needle = util.trim(filter):lower()
			for _, id in ipairs(known) do
				if needle == "" or tostring(id):lower():find(needle, 1, true) then
					shown[#shown + 1] = id
				end
			end

			local detail = #known == #shown
				and util.pluralise(#known, "model")
				or string.format("%d of %s", #shown, util.pluralise(#known, "model"))
			local modelRows = section(nextOrder(), "Model on " .. record.label, detail)

			if #known >= FILTER_AT then
				local field = P.field(modelRows, {
					name = "ModelFilter",
					placeholder = "Filter these " .. tostring(#known) .. " ids",
					text = filter,
					layoutOrder = 0,
					onChange = function(text)
						filter = text
						render()
					end,
				})
				-- Focus is restored after a re-render, because typing into the filter is
				-- what caused the re-render: without this the field loses focus on the
				-- first keystroke and the second one goes nowhere.
				if util.trim(filter) ~= "" then
					env.require("runtime/clock").delay(theme.motion.fast, function()
						pcall(field.focus)
					end)
				end
			end

			if #known == 0 then
				local note = P.text(modelRows, {
					name = "NoModels",
					text = "Nothing known yet. Ask the endpoint for its list, or add an id by hand -- "
						.. "this client never guesses one.",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					padding = { x = theme.space.sm, y = theme.space.xs },
					layoutOrder = 1,
				})
				note.Size = UDim2.new(1, 0, 0, 0)
			elseif #shown == 0 then
				local note = P.text(modelRows, {
					name = "NoMatch",
					text = "Nothing matched " .. util.trim(filter) .. ".",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					padding = { x = theme.space.sm, y = theme.space.xs },
					layoutOrder = 1,
				})
				note.Size = UDim2.new(1, 0, 0, 0)
			end

			for index, id in ipairs(shown) do
				-- The context window is the one thing about a model worth reading at a
				-- glance and no endpoint publishes it, so where this client documents it,
				-- it rides on the row as a badge. Where it does not, there is no badge --
				-- rather than a badge that says "unknown".
				local badge = traits.badge(id)
				local where = own[id] and "added on this client" or "reported by /models"
				pickRow(modelRows, {
					name = "Model_" .. tostring(id),
					title = id,
					mono = true,
					detail = where,
					badge = badge,
					selected = id == record.model,
					layoutOrder = index,
					onClick = function()
						providers.setModel(record.id, id)
						notify()
						render()
					end,
				})
			end

			-- 3. How hard it is asked to think.
			--
			-- The levels are the model's own where it documents them, and the whole
			-- section is left out where it documents none: sending an effort a model has
			-- no parameter for is a control that does nothing, which is exactly what the
			-- old menu's five rows were on most ids.
			local levels = traits.effortLevels(record.model)
			local wanted = tostring(config.get("agent.effort", "high"))
			if levels then
				local sending = traits.nearestEffort(record.model, wanted) or wanted
				local note = (sending ~= wanted)
					and string.format("%s is the most this model has", titleCase(sending))
					or nil
				local effortRows = section(nextOrder(), "Reasoning effort", note)
				for index, level in ipairs(levels) do
					local isDefault = traits.defaultEffort(record.model) == level
					pickRow(effortRows, {
						name = "Effort_" .. level,
						title = titleCase(level),
						detail = isDefault
							and "what the API itself uses when none is sent"
							or nil,
						selected = level == sending,
						layoutOrder = index,
						onClick = function()
							config.set("agent.effort", level)
							notify()
							render()
						end,
					})
				end
			else
				local effortRows = section(nextOrder(), "Reasoning effort", "not offered")
				local note = P.text(effortRows, {
					name = "NoEffort",
					text = ("%s publishes no effort scale this client knows, so none is sent and the setting "
						.. "(%s) is not applied to it."):format(
						record.model ~= "" and record.model or "This model", titleCase(wanted)),
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					padding = { x = theme.space.sm, y = theme.space.xs },
					layoutOrder = 1,
				})
				note.Size = UDim2.new(1, 0, 0, 0)
			end
		end

		render()

		-- The footer is the three things that are not a selection: ask the endpoint what
		-- it serves, name an id it did not report, and go to the panel where a whole
		-- record is edited.
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
						-- Only if the modal is still open: a fetch runs for as long as the
						-- endpoint takes, and rendering into a destroyed tree is the classic
						-- way an async callback takes the interface down with it.
						if not modal.closed then render() end
					end)
				end,
			})
			P.button(modal.footer, {
				name = "AddModel",
				text = "Add an id",
				variant = "ghost",
				size = "sm",
				layoutOrder = 2,
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
			layoutOrder = 3,
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
			layoutOrder = 4,
			onClick = function() modal.close() end,
		})

		-- The list is a view of state other surfaces write: the Providers panel can add a
		-- record or change a model while this is open, and a fetch started here lands
		-- through the same signal.
		local unsubscribe = providers.changed:connect(function()
			if modal.closed then return end
			render()
		end)
		modal.scrim.Destroying:Connect(function() pcall(unsubscribe) end)

		modal.render = render
		return modal
	end

	return M
end
