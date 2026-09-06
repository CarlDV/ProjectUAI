-- Providers panel: a list on the left, one provider's whole configuration on the
-- right.
--
-- This is the screen that makes the client universal, so it is deliberately plain: a
-- base URL, a key, an auth style and a model. Anything that speaks
-- /v1/chat/completions is a first-class citizen here, and the presets are only a way
-- to avoid typing a URL.
--
-- It was a list of cards plus one modal holding nine rows of form, and four things
-- were wrong with that beyond the density. The modal was the only way to see any of a
-- record's configuration, and it printed the API key in clear text while the hint
-- underneath said the key was redacted. Picking a different preset inside it rebuilt
-- the record from scratch and threw away whatever had been typed, with no warning. The
-- record's headers, params, query, order and note -- five fields the registry keeps,
-- two of which decide whether Azure and OpenRouter work at all -- had no
-- representation anywhere in the interface. And every completion fired a health event
-- that rebuilt the entire panel mid-turn, scroll position included.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local caps = env.require("runtime/caps")
	local config = env.require("runtime/config")
	local theme = env.require("ui/theme")
	local responsive = env.require("ui/responsive")
	local P = env.require("ui/primitives")
	local C = env.require("ui/controls")
	local R = env.require("ui/settingsrows")
	local overlay = env.require("ui/overlay")
	local catalog = env.require("provider/catalog")
	local registry = env.require("provider/registry")
	local models = env.require("provider/models")
	local chat = env.require("provider/chat")
	local traits = env.require("provider/traits")

	local M = {}

	local AUTH_OPTIONS = {
		{ value = "bearer", label = "Bearer" },
		{ value = "x-api-key", label = "x-api-key" },
		{ value = "api-key", label = "api-key" },
		{ value = "both", label = "Both" },
		{ value = "none", label = "None" },
	}

	local function labelOf(options, value)
		for _, option in ipairs(options) do
			if option.value == value then return option.label end
		end
		return tostring(value)
	end

	-- Never the key itself.
	--
	-- The editor rendered record.apiKey into an ordinary field, so opening Edit on any
	-- saved provider printed the whole secret on screen -- while the hint under it said
	-- "redacted in the log", the privacy pane promised only the last four characters
	-- were kept, and the export path reduced it to exactly that.
	local function maskedKey(record)
		local key = util.trim(record.apiKey or "")
		if key == "" then return "not set", "warn" end
		if #key <= 4 then return "set", nil end
		return string.rep("\226\128\162", 4) .. " " .. key:sub(-4), nil
	end

	-- Everything the registry knows about a record and the panel never said.
	--
	-- `chat.endpointOf` and `registry.endpoint` both existed for this and both had zero
	-- call sites; the comment on endpointOf says "for the Providers panel to show".
	local function factsFor(record)
		local health = record.health or {}
		local key, keyTone = maskedKey(record)
		local out = {
			{ key = "Endpoint", value = chat.endpointOf(record) },
			{ key = "Model list", value = registry.endpoint(record, "/models") },
			{ key = "Protocol", value = labelOf(chat.STYLES, chat.styleOf(record)) },
			{ key = "Auth", value = labelOf(AUTH_OPTIONS, record.authStyle or "bearer")
				.. "  \194\183  " .. key, tone = keyTone },
			-- The one fact that decides whether a long reply can arrive at all. No Roblox
			-- HTTP transport reads a body incrementally and the host abandons a request
			-- after about a minute, so without a socket a large completion cannot land.
			{ key = "Streaming", value = util.trim(record.wsUrl or "") ~= ""
				and "socket, no length ceiling"
				or "HTTP only, replies capped near a minute" },
		}
		if (health.ok or 0) + (health.fail or 0) > 0 then
			out[#out + 1] = {
				key = "Health",
				value = string.format("%d ok, %d failed", health.ok or 0, health.fail or 0),
				tone = (health.streak or 0) > 0 and "warn" or "good",
			}
		end
		-- Recorded on every success and shown nowhere until now.
		if (health.lastMs or 0) > 0 then
			out[#out + 1] = { key = "Last reply", value = util.formatDuration(health.lastMs) }
		end
		-- The bench was a red dot with no words: no label, no remaining time, and no
		-- statement of the three-failure rule that put it there.
		if registry.cooling(record) then
			local left = math.max((health.cooldownUntil or 0) - clock.ms(), 0)
			out[#out + 1] = {
				key = "Benched",
				value = string.format("%s left, after 3 failures in a row", util.formatDuration(left)),
				tone = "bad",
			}
		end
		if record.requires == "executor" then
			local have = caps.http == "executor"
			out[#out + 1] = {
				key = "Requires",
				value = have and "an executor HTTP function, which this host has"
					or "an executor HTTP function, which this host does not have",
				tone = have and "good" or "bad",
			}
		end
		return out
	end

	-- The connection modal: preset, name, URL, protocol, auth, key. Six rows, not nine.
	--
	-- Everything else a record carries -- its models, its behaviour switches, its extra
	-- headers -- is edited in the detail pane, which is a surface that does not have to
	-- be dismissed to see the rest of the screen. This modal exists for the one moment
	-- when none of that is reachable yet: there is no record to select.
	function M.editor(record, onSaved)
		local editing = util.deepCopy(record)
		local adding = util.trim(editing.id) == ""
		local modal = overlay.modal({
			title = adding and "Add a provider" or ("Connection for " .. tostring(editing.label)),
			description = "Any endpoint that speaks /v1/chat/completions, or Anthropic's Messages API.",
			width = theme.size.modalWide,
			height = 620,
			-- Six labelled rows, two segmented pickers and a footer do not fit on a phone,
			-- and an unbounded modal is centred -- so what did not fit went off the top and
			-- the bottom at once, taking the title and the Save button with it. Bounded and
			-- scrolled, the header and the footer stay put and the form moves.
			scroll = true,
		})
		if not modal then return end

		local form = P.column(modal.content, {
			name = "Form",
			size = UDim2.new(1, 0, 0, 0),
			auto = "Y",
			gap = theme.space.lg,
			layoutOrder = 1,
		})

		local problemLabel
		local presetButton, urlField, keyRow
		-- Assigned with the model row below, called from applyPreset above it: a preset
		-- change moves the endpoint, so anything a previous fetch turned up belongs to a
		-- different server and must not still be on offer.
		local forgetFetchedModels

		local function showProblems()
			local ok, problems = registry.validate(editing)
			problemLabel.Text = ok and "" or (problems[1]:gsub("^%l", string.upper) .. ".")
			problemLabel.Visible = not ok
			return ok
		end

		local function row(label, hint, build)
			local column = P.column(form, {
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.xs,
			})
			P.text(column, { text = tostring(label), role = "label", color = theme.color.text })
			local handle = build(column)
			if hint then
				local note = P.text(column, {
					text = hint,
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
				})
				note.Size = UDim2.new(1, 0, 0, 0)
			end
			return handle
		end

		-- Applied in place, not by rebuilding the record.
		--
		-- Choosing a preset used to call registry.blank, replace `editing` wholesale,
		-- close the modal and re-open it -- so a name typed, a key pasted and a URL
		-- corrected were all discarded the moment someone realised they had picked the
		-- wrong vendor. Only the fields the preset actually describes move; the label is
		-- carried over when it still matches the old preset's own name, which is the case
		-- where it was never edited.
		local function applyPreset(id)
			local preset = catalog.get(id)
			if not preset then return end
			local previous = catalog.get(editing.preset)
			if previous and util.trim(editing.label) == util.trim(previous.label) then
				editing.label = preset.label
			end
			if util.trim(editing.label) == "" then editing.label = preset.label end
			editing.preset = preset.id
			editing.baseUrl = preset.baseUrl or ""
			editing.authStyle = preset.authStyle or "bearer"
			editing.api = preset.api or "openai"
			editing.headers = util.deepCopy(preset.headers or {})
			editing.params = util.deepCopy(preset.params or {})
			editing.query = util.deepCopy(preset.query or {})
			editing.note = preset.note
			editing.requires = preset.requires
			if presetButton then presetButton.setText(preset.label) end
			if urlField then urlField.set(editing.baseUrl) end
			if forgetFetchedModels then forgetFetchedModels() end
			showProblems()
		end

		row("Preset", "A base URL and an auth style, nothing more. Picking one keeps the name and "
			.. "the key you have already typed.", function(column)
			presetButton = P.button(column, {
				name = "Preset",
				text = (catalog.get(editing.preset) or {}).label or "Custom endpoint",
				variant = "secondary",
				fill = true,
				align = "Left",
				onClick = function(handle)
					local options = {}
					for _, preset in ipairs(catalog.presets) do
						options[#options + 1] = {
							label = preset.label,
							value = preset.id,
							detail = (preset.baseUrl ~= "" and preset.baseUrl) or "any URL you supply",
							selected = preset.id == editing.preset,
						}
					end
					overlay.menu({
						target = handle.instance,
						width = theme.size.menuWide,
						options = options,
						onSelect = applyPreset,
					})
				end,
			})
			return presetButton
		end)

		row("Name", nil, function(column)
			return P.field(column, {
				name = "ProviderName",
				text = editing.label,
				placeholder = "My provider",
				onChange = function(text) editing.label = text end,
				onBlur = showProblems,
			})
		end)

		local normalisedNote
		row("Base URL", nil, function(column)
			urlField = P.field(column, {
				name = "BaseUrl",
				text = editing.baseUrl,
				placeholder = "https://api.example.com/v1",
				onChange = function(text)
					editing.baseUrl = text
					-- What will actually be stored, before it is stored.
					--
					-- registry.save normalises the URL *and then* validates, so a rejected
					-- save had already rewritten the value while the field still showed the
					-- old text. Saying what the rule does to the input is better than
					-- describing the rule.
					local normalised = registry.normaliseBaseUrl(text)
					if normalisedNote then
						normalisedNote.Text = (normalised ~= "" and normalised ~= util.trim(text))
							and ("Saved as " .. normalised) or ""
					end
				end,
				onBlur = showProblems,
			})
			normalisedNote = P.text(column, {
				text = "",
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			normalisedNote.Size = UDim2.new(1, 0, 0, 0)
			return urlField
		end)

		row("Protocol", "Chat completions is the universal one. Anthropic's own Messages API keeps "
			.. "reasoning and tool calls in their real shape instead of translating them twice.",
			function(column)
				return C.segmented(column, {
					name = "Protocol",
					options = chat.STYLES,
					value = chat.styleOf(editing),
					onChange = function(value) editing.api = value end,
				})
			end)

		row("Auth header", nil, function(column)
			return C.segmented(column, {
				name = "AuthStyle",
				options = AUTH_OPTIONS,
				value = editing.authStyle,
				onChange = function(value)
					editing.authStyle = value
					showProblems()
				end,
			})
		end)

		-- The key goes in through a prompt and never comes back out.
		--
		-- A masked field would need a new primitive; a prompt needs none, and it has the
		-- better property that the secret is on screen only while it is being typed.
		local keyLabel
		row("API key", "Kept on this device, sent only to the endpoint above, and redacted in "
			.. "the request log.", function(column)
			local line = P.row(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm })
			local shown, tone = maskedKey(editing)
			keyLabel = P.text(line, {
				name = "KeyState",
				text = shown,
				role = "monoSmall",
				color = tone and theme.color.warn or theme.color.textSecondary,
				size = UDim2.new(0, 0, 0, math.max(theme.size.control, responsive.minTarget())),
				flex = "Fill",
				truncate = true,
				layoutOrder = 1,
			})
			local set = P.button(line, {
				name = "SetKey",
				text = util.trim(editing.apiKey or "") == "" and "Add key" or "Replace",
				variant = "secondary",
				size = "sm",
				layoutOrder = 2,
				onClick = function(handle)
					overlay.prompt({
						title = "API key",
						description = "Paste the key for " .. tostring(editing.label) ..
							". It replaces whatever is stored now.",
						placeholder = (catalog.get(editing.preset) or {}).keyHint or "sk-...",
						confirmText = "Save key",
						onConfirm = function(text)
							editing.apiKey = util.trim(text)
							local value, warn = maskedKey(editing)
							keyLabel.Text = value
							keyLabel.TextColor3 = warn and theme.color.warn or theme.color.textSecondary
							handle.setText("Replace")
							showProblems()
						end,
					})
				end,
			})
			set.instance.LayoutOrder = 2
			return keyLabel
		end)

		-- Model.
		--
		-- The one field a record cannot be saved without, and the editor had none. The
		-- picker lives on the detail pane, which you reach by selecting a provider that has
		-- already been saved -- and `registry.validate` refuses to save a record with no
		-- model. So adding a provider ended at "fetch the model list or add a model id"
		-- with nothing on screen that could do either, and Test asked the endpoint for a
		-- completion with no model named, which comes back as the provider's own wording
		-- for that and reads as a broken connection.
		local modelButton, modelNote
		local fetched = {}

		-- What the picker offers: the ids already on the record, plus whatever this
		-- editor's own fetch turned up. The session-wide discovery cache is deliberately
		-- not read here -- it is keyed by provider id and a record being added has none,
		-- so a second "Add a provider" would be offered the last endpoint's models.
		local function knownModels()
			local out, seen = {}, {}
			for _, id in ipairs(editing.models or {}) do
				if util.trim(id) ~= "" and not seen[id] then
					seen[id] = true
					out[#out + 1] = id
				end
			end
			for _, id in ipairs(fetched) do
				if not seen[id] then
					seen[id] = true
					out[#out + 1] = id
				end
			end
			return out
		end

		local DEFAULT_MODEL_NOTE = "The endpoint is the only authority on this, so nothing here "
			.. "guesses one. Fetch the list, or type the id exactly as the provider expects it."

		local function setModelNote(text, bad)
			if not modelNote then return end
			modelNote.Text = tostring(text)
			modelNote.TextColor3 = bad and theme.color.warn or theme.color.textTertiary
		end

		local function paintModel()
			local current = util.trim(editing.model)
			if modelButton then
				modelButton.setText(current ~= "" and current or "Choose a model")
			end
		end

		local openModelMenu

		-- Fetches against the record as it would be saved, not as it is typed: the URL is
		-- normalised the same way `save` normalises it, so what is asked for is the
		-- endpoint the provider will actually use.
		local function fetchModels(handle)
			local target = util.deepCopy(editing)
			target.baseUrl = registry.normaliseBaseUrl(target.baseUrl)
			if target.baseUrl == "" then
				setModelNote("Add the base URL first -- there is nothing to ask.", true)
				return
			end
			handle.setEnabled(false)
			setModelNote("Asking " .. registry.endpoint(target, "/models") .. "...", false)
			task.spawn(function()
				local found, note = models.discover(target, { force = true })
				fetched = found
				handle.setEnabled(true)
				setModelNote(note, #found == 0)
				-- Straight back into the list. Picking one is the reason to fetch, and a
				-- notice that says "42 models" while the menu stays shut makes someone press
				-- the same control twice for one decision.
				if #found > 0 then openModelMenu(handle) end
			end)
		end

		local function typeModel()
			overlay.prompt({
				title = "Model id",
				description = "Type it exactly as the provider expects it. It is saved with this "
					.. "provider and selected.",
				placeholder = "model id",
				confirmText = "Use it",
				onConfirm = function(text)
					-- Not persisted: the record is still being edited and may never be saved.
					local ok, result = models.add(editing, text, { persist = false, select = true })
					setModelNote(ok and ("Using " .. tostring(result)) or tostring(result), not ok)
					paintModel()
					showProblems()
				end,
			})
		end

		openModelMenu = function(handle)
			local options = {}
			local own = {}
			for _, id in ipairs(editing.models or {}) do own[id] = true end
			for _, id in ipairs(knownModels()) do
				local badge = traits.badge(id)
				local bits = {}
				if badge then bits[#bits + 1] = badge end
				if not own[id] then bits[#bits + 1] = "from /models" end
				options[#options + 1] = {
					label = id,
					value = "model:" .. id,
					detail = #bits > 0 and table.concat(bits, "  \194\183  ") or nil,
					selected = id == editing.model,
				}
			end
			if #options > 0 then options[#options + 1] = { divider = true } end
			options[#options + 1] = {
				label = "Fetch from /models",
				value = "fetch",
				detail = registry.endpoint(editing, "/models"),
				tone = "info",
			}
			options[#options + 1] = { label = "Type an id", value = "add", tone = "info" }
			overlay.menu({
				target = handle.instance,
				width = theme.size.menuWide,
				options = options,
				onSelect = function(value)
					if value == "fetch" then
						fetchModels(handle)
					elseif value == "add" then
						typeModel()
					elseif util.startsWith(tostring(value), "model:") then
						local id = tostring(value):sub(7)
						models.add(editing, id, { persist = false, select = true })
						editing.model = id
						setModelNote(DEFAULT_MODEL_NOTE, false)
						paintModel()
						showProblems()
					end
				end,
			})
		end

		row("Model", nil, function(column)
			modelButton = P.button(column, {
				name = "ActiveModel",
				text = "Choose a model",
				variant = "secondary",
				fill = true,
				align = "Left",
				onClick = openModelMenu,
			})
			modelNote = P.text(column, {
				name = "ModelNote",
				text = DEFAULT_MODEL_NOTE,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			modelNote.Size = UDim2.new(1, 0, 0, 0)
			paintModel()
			return modelButton
		end)

		forgetFetchedModels = function()
			fetched = {}
			setModelNote(DEFAULT_MODEL_NOTE, false)
		end

		-- Where the key comes from, when the preset knows. Thirteen of the seventeen
		-- presets carry a docs URL and not one of them was ever rendered.
		local presetRecord = catalog.get(editing.preset)
		if presetRecord and presetRecord.docs then
			R.paragraph(form, "Keys for this provider are issued at " .. presetRecord.docs .. ".")
		end
		if presetRecord and presetRecord.note then
			R.paragraph(form, presetRecord.note)
		end

		problemLabel = P.text(modal.content, {
			name = "Problem",
			text = "",
			role = "small",
			color = theme.color.danger,
			wrap = true,
			auto = "Y",
			visible = false,
			layoutOrder = 2,
		})
		problemLabel.Size = UDim2.new(1, 0, 0, 0)

		local testButton
		testButton = P.button(modal.footer, {
			name = "TestConnection",
			text = "Test",
			variant = "ghost",
			size = "sm",
			layoutOrder = 1,
			-- Through onClick, not a raw Activated connection: that is what P.button's own
			-- re-entry guard hangs off, and connecting to Activated directly meant a double
			-- tap fired two concurrent completions.
			onClick = function(handle)
				-- A completion needs a model named, so testing without one asks the endpoint
				-- a question it cannot answer -- and what comes back is that provider's own
				-- wording for "no model", which reads as a broken connection rather than as
				-- an empty field one row up.
				if editing.preset ~= "azure" and util.trim(editing.model) == "" then
					problemLabel.Text = "Choose a model first: fetch the list, or type the id."
					problemLabel.Visible = true
					return
				end
				handle.setEnabled(false)
				handle.setText("Testing")
				task.spawn(function()
					local candidate = util.deepCopy(editing)
					candidate.baseUrl = registry.normaliseBaseUrl(candidate.baseUrl)
					local result, err = chat.complete(candidate, {
						messages = { { role = "user", content = "Reply with the single word: ready" } },
						stream = false,
						maxTokens = 12,
						attempts = 1,
					})
					handle.setText("Test")
					handle.setEnabled(true)
					if result then
						overlay.toast(string.format("Reached %s in %s",
							candidate.label, util.formatDuration(result.ms)), "good")
					else
						problemLabel.Text = tostring(err)
						problemLabel.Visible = true
					end
				end)
			end,
		})

		P.button(modal.footer, {
			name = "SaveProvider",
			text = adding and "Add" or "Save",
			variant = "primary",
			size = "sm",
			layoutOrder = 2,
			onClick = function()
				local ok, problems = registry.save(editing)
				if not ok then
					-- Sentence-cased and one per line. It was table.concat(problems, ". "),
					-- which turned two lowercase fragments into "give the provider a name.
					-- base URL is required".
					local lines = {}
					for index, problem in ipairs(problems) do
						lines[index] = problem:gsub("^%l", string.upper) .. "."
					end
					problemLabel.Text = table.concat(lines, "\n")
					problemLabel.Visible = true
					return
				end
				modal.close()
				overlay.toast("Saved " .. editing.label, "good", 2)
				if onSaved then onSaved(editing.id) end
			end,
		})

		showProblems()
		-- Nothing is wrong yet on a brand-new record; it is simply incomplete.
		if adding then problemLabel.Visible = false end
	end

	-- List and detail ---------------------------------------------------------

	function M.new(parent)
		local panel = {}
		local selected = nil

		-- Two columns where there is room for two, stacked where there is not. Same rule
		-- and same threshold as the settings dialog, which solved this first.
		local wide = responsive.mode == "window"
			and parent.AbsoluteSize.X >= (theme.size.dialogNav * 3)

		local root
		if wide then
			root = P.row(parent, { name = "ProvidersRoot", size = UDim2.fromScale(1, 1), gap = 0 })
		else
			root = P.column(parent, { name = "ProvidersRoot", size = UDim2.fromScale(1, 1), gap = 0 })
		end

		local railHolder = P.frame(root, {
			name = "ProviderRail",
			size = wide and UDim2.new(0, theme.size.dialogNav, 1, 0)
				or UDim2.new(1, 0, 0, theme.size.controlLarge + theme.space.md),
			bg = theme.color.sidebar,
			layoutOrder = 1,
		})
		local rail = P.column(railHolder, {
			size = UDim2.fromScale(1, 1),
			gap = theme.space.xs,
			padding = theme.space.xs,
		})
		local railScrollHolder = P.frame(rail, {
			size = UDim2.new(1, 0, 1, 0),
			flex = "Fill",
			layoutOrder = 1,
		})
		local railScroll = P.scroll(railScrollHolder, {
			name = "ProviderList",
			size = UDim2.fromScale(1, 1),
			gap = theme.space.hair,
			horizontal = not wide,
		})
		-- Under the list where there is a column to put it under, and at the end of the
		-- strip where there is not -- so there is exactly one of it either way.
		if wide then
			local addButton = P.button(rail, {
				name = "AddProvider",
				text = "Add a provider",
				variant = "secondary",
				size = "sm",
				fill = true,
				layoutOrder = 2,
				onClick = function()
					M.editor(registry.blank("custom"), function(id) panel.select(id) end)
				end,
			})
			addButton.instance.LayoutOrder = 2
		end

		P.divider(root, {
			vertical = wide,
			color = theme.color.borderSubtle,
			layoutOrder = 2,
		})

		local detailHolder = P.frame(root, {
			name = "ProviderDetail",
			size = wide and UDim2.new(0, 0, 1, 0) or UDim2.new(1, 0, 0, 0),
			flex = "Fill",
			layoutOrder = 3,
		})
		local detail = P.scroll(detailHolder, {
			name = "DetailScroll",
			size = UDim2.fromScale(1, 1),
			gap = theme.space.lg,
			padding = { x = theme.space.lg, top = theme.space.lg, bottom = theme.space.xl },
		})

		-- Rail -----------------------------------------------------------------

		local railRows = {}

		local function dotFor(record, isActive)
			if registry.cooling(record) then return theme.color.danger end
			if record.enabled == false then return theme.color.textDisabled end
			if isActive then return theme.color.accent end
			return theme.color.textTertiary
		end

		function panel.renderRail()
			railScroll.clear()
			railRows = {}
			local list = registry.list()
			local active = registry.active()
			for index, record in ipairs(list) do
				local isActive = active and active.id == record.id
				local row = P.rowButton(railScroll.instance, {
					name = "Provider_" .. tostring(record.id),
					size = (not wide) and UDim2.fromOffset(theme.size.menu, theme.size.controlLarge) or nil,
					height = theme.size.controlLarge,
					padding = { x = theme.space.sm },
					radius = theme.radius.md,
					selected = record.id == selected,
					layoutOrder = index,
					onClick = function() panel.select(record.id) end,
				})
				local dotSlot = P.frame(row.row, {
					name = "Health",
					size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
					layoutOrder = 1,
				})
				local dot = P.statusDot(dotSlot, {
					diameter = theme.size.dot,
					color = dotFor(record, isActive),
					anchor = Vector2.new(0.5, 0.5),
					position = UDim2.fromScale(0.5, 0.5),
				})
				row.label(record.label, 2,
					record.id == selected and theme.color.text or theme.color.textSecondary, "small")
				-- A badge, not text appended to the title. It used to be "  (active)"
				-- concatenated into a truncating label, so on a narrow rail the one fact
				-- that says which endpoint is in use was the first thing cut.
				if isActive then
					local badge = P.badge(row.row, { text = "Active", tone = "accent", layoutOrder = 3 })
					badge.LayoutOrder = 3
				end
				railRows[record.id] = { row = row, dot = dot }
			end
			if #list == 0 then
				local empty = P.text(railScroll.instance, {
					name = "NoProviders",
					text = "Nothing configured yet.",
					role = "caption",
					color = theme.color.textTertiary,
					wrap = true,
					auto = "Y",
					padding = { x = theme.space.sm, y = theme.space.xs },
					layoutOrder = 1,
				})
				empty.Size = UDim2.new(1, 0, 0, 0)
			end
			if not wide then
				-- With the rail collapsed to a strip there is no room under it for the
				-- button, so it rides at the end of the strip instead.
				local add = P.button(railScroll.instance, {
					name = "AddProvider",
					text = "Add",
					variant = "secondary",
					size = "sm",
					layoutOrder = #list + 1,
					onClick = function()
						M.editor(registry.blank("custom"), function(id) panel.select(id) end)
					end,
				})
				add.instance.LayoutOrder = #list + 1
			end
		end

		-- Detail ---------------------------------------------------------------

		local statusBox = nil

		local function order()
			panel.__order = (panel.__order or 0) + 1
			return panel.__order
		end

		local function modelMenu(record, target, onDone)
			local options = {}
			local own = {}
			for _, id in ipairs(record.models or {}) do own[id] = true end
			for _, id in ipairs(models.list(record)) do
				local badge = traits.badge(id)
				local bits = {}
				if badge then bits[#bits + 1] = badge end
				if not own[id] then bits[#bits + 1] = "from /models" end
				options[#options + 1] = {
					label = id,
					value = "model:" .. id,
					detail = #bits > 0 and table.concat(bits, "  \194\183  ") or nil,
					selected = id == record.model,
				}
			end
			if #options > 0 then options[#options + 1] = { divider = true } end
			options[#options + 1] = {
				label = "Fetch from /models",
				value = "fetch",
				detail = registry.endpoint(record, "/models"),
				tone = "info",
			}
			options[#options + 1] = { label = "Add a model by id", value = "add", tone = "info" }
			overlay.menu({
				target = target,
				width = theme.size.menuWide,
				options = options,
				onSelect = function(value)
					if value == "fetch" then
						overlay.toast("Fetching models from " .. record.label, "info", 2)
						task.spawn(function()
							local found, note = models.discover(record, { force = true })
							overlay.toast(tostring(note), #found > 0 and "good" or "warn", 3)
							if onDone then pcall(onDone) end
						end)
					elseif value == "add" then
						overlay.prompt({
							title = "Add a model to " .. record.label,
							description = "Type the id exactly as the provider expects it. "
								.. "It is saved to this provider and selected.",
							placeholder = "model id",
							confirmText = "Add",
							onConfirm = function(text)
								local ok, result = models.add(record, text)
								if ok then registry.setModel(record.id, util.trim(text)) end
								overlay.toast(tostring(result), ok and "good" or "warn", 3)
								if onDone then pcall(onDone) end
							end,
						})
					elseif util.startsWith(tostring(value), "model:") then
						registry.setModel(record.id, tostring(value):sub(7))
						if onDone then pcall(onDone) end
					end
				end,
			})
		end

		function panel.renderDetail()
			detail.clear()
			statusBox = nil
			panel.__order = 0
			local record = selected and registry.get(selected) or nil
			if not record then
				C.emptyState(detail.instance, {
					title = registry.count() == 0 and "No provider configured"
						or "Pick a provider on the left",
					description = registry.count() == 0
						and "Add an endpoint to start. Anything that speaks /v1/chat/completions works: "
							.. "a hosted API, a relay, or a local server reachable from this host."
						or "Its endpoint, key, model and health are all edited here.",
					action = registry.count() == 0 and "Add a provider" or nil,
					onAction = function()
						M.editor(registry.blank("custom"), function(id) panel.select(id) end)
					end,
					layoutOrder = order(),
				})
				return
			end

			local active = registry.active()
			local isActive = active and active.id == record.id

			-- Header. The window chrome already names the panel and the active provider, so
			-- this names the record being edited instead of repeating either.
			local head = P.row(detail.instance, {
				name = "DetailHead",
				size = UDim2.new(1, 0, 0, 0),
				auto = "Y",
				gap = theme.space.sm,
				layoutOrder = order(),
			})
			local titleColumn = P.column(head, {
				size = UDim2.new(0, 0, 0, 0),
				auto = "Y",
				flex = "Fill",
				gap = theme.space.hair,
				layoutOrder = 1,
			})
			local title = P.text(titleColumn, {
				name = "ProviderTitle",
				text = record.label,
				role = "display",
				color = theme.color.text,
				wrap = true,
				auto = "Y",
			})
			title.Size = UDim2.new(1, 0, 0, 0)
			local subtitle = P.text(titleColumn, {
				text = record.baseUrl,
				role = "caption",
				color = theme.color.textTertiary,
				wrap = true,
				auto = "Y",
			})
			subtitle.Size = UDim2.new(1, 0, 0, 0)
			if isActive then
				local badge = P.badge(head, { text = "Active", tone = "accent", layoutOrder = 2 })
				badge.LayoutOrder = 2
			end

			-- Status ------------------------------------------------------------
			local status = R.section(detail.instance, {
				name = "Status",
				title = "Status",
				description = "What this client will actually send, and how the endpoint has "
					.. "been answering.",
				layoutOrder = order(),
			})
			statusBox = R.facts(status, factsFor(record), { name = "StatusFacts", layoutOrder = 1 })

			local health = record.health or {}
			if util.trim(health.lastError or "") ~= "" then
				R.paragraph(status, health.lastError, { color = theme.color.danger, layoutOrder = 2 })
			end
			-- The preset's own guidance, which the registry copies onto every record and
			-- nothing has ever rendered: Azure's deployment-path rule, Ollama's loopback
			-- warning, DeepSeek's reasoning field.
			if util.trim(record.note or "") ~= "" then
				R.paragraph(status, record.note, { layoutOrder = 3 })
			end
			-- Fallback is a global switch, and the old header claimed the chain was always
			-- in use. Saying which it is beats asserting one of them.
			R.paragraph(status, config.get("agent.fallback", true)
				and "Requests try the active provider first, then every other enabled one."
				or "Fallback is off under Settings, so only the active provider is tried.",
				{ layoutOrder = 4 })

			local actions = {}
			if not isActive then
				actions[#actions + 1] = {
					name = "UseProvider",
					text = "Use this provider",
					variant = "primary",
					onClick = function()
						registry.setActive(record.id)
						overlay.toast(record.label .. " is now the active provider", "good", 2)
					end,
				}
			end
			actions[#actions + 1] = {
				name = "EditConnection",
				text = "Connection",
				variant = "secondary",
				onClick = function() M.editor(record, function() panel.select(record.id) end) end,
			}
			if caps.clipboard then
				actions[#actions + 1] = {
					name = "CopyEndpoint",
					text = "Copy endpoint",
					variant = "ghost",
					onClick = function()
						pcall(caps.fn.clipboard, chat.endpointOf(record))
						overlay.toast("Copied", "good", 1.5)
					end,
				}
			end
			R.actions(status, actions, { name = "StatusActions", layoutOrder = 5 })

			-- Model -------------------------------------------------------------
			local modelSection = R.section(detail.instance, {
				name = "Model",
				title = "Model",
				description = "Only what the endpoint reported and what you added -- never a guess, "
					.. "so this can legitimately be empty until one of those has happened.",
				layoutOrder = order(),
			})
			local known = models.list(record)
			R.select(modelSection, {
				name = "ActiveModel",
				label = "Active model",
				hint = #known == 0 and "Nothing known yet. Fetch the list, or add an id by hand."
					or (traits.badge(record.model) and ("Context window " .. traits.badge(record.model))
						or "No published context window for this id."),
				options = (function()
					local out = {}
					for _, id in ipairs(known) do out[#out + 1] = { value = id, label = id } end
					if #out == 0 then
						out[#out + 1] = { value = record.model, label = record.model ~= "" and record.model or "none" }
					end
					return out
				end)(),
				value = record.model ~= "" and record.model or (known[1] or ""),
				width = theme.size.menu,
				onChange = function(value) registry.setModel(record.id, value) end,
			})
			R.actions(modelSection, {
				{
					name = "ManageModels",
					text = #known == 0 and "Fetch or add a model" or "Fetch, add or remove",
					variant = "secondary",
					onClick = function(handle)
						modelMenu(record, handle.instance, function() panel.select(record.id) end)
					end,
				},
			}, { name = "ModelActions" })

			local own = {}
			for _, id in ipairs(record.models or {}) do own[id] = true end
			for index, id in ipairs(known) do
				local row = P.rowButton(modelSection, {
					name = "Model_" .. tostring(index),
					height = theme.size.rowSmall,
					padding = { x = theme.space.sm },
					radius = theme.radius.sm,
					selected = id == record.model,
					layoutOrder = 100 + index,
					onClick = function()
						registry.setModel(record.id, id)
						panel.select(record.id)
					end,
				})
				local slot = P.frame(row.row, {
					size = UDim2.fromOffset(theme.size.icon, theme.size.icon),
					layoutOrder = 1,
				})
				P.statusDot(slot, {
					diameter = theme.size.dot,
					color = id == record.model and theme.color.accent or theme.color.borderStrong,
					anchor = Vector2.new(0.5, 0.5),
					position = UDim2.fromScale(0.5, 0.5),
				})
				row.label(id, 2, id == record.model and theme.color.text or theme.color.textSecondary,
					"monoSmall")
				if not own[id] then
					local mark = P.badge(row.row, { text = "fetched", layoutOrder = 3 })
					mark.LayoutOrder = 3
				end
				if own[id] and #known > 1 then
					local remove = P.iconButton(row.row, {
						name = "RemoveModel",
						icon = "close",
						diameter = theme.size.rowSmall,
						variant = "ghost",
						layoutOrder = 4,
						onClick = function()
							models.remove(record, id)
							panel.select(record.id)
						end,
					})
					remove.instance.LayoutOrder = 4
				end
			end

			-- Behaviour ---------------------------------------------------------
			local behaviour = R.section(detail.instance, {
				name = "Behaviour",
				title = "Behaviour",
				description = "Per-provider switches. Each one can only narrow what the matching "
					.. "global setting allows: turning one off always takes effect, turning it on "
					.. "needs the global on as well.",
				layoutOrder = order(),
			})
			R.toggle(behaviour, {
				name = "Enabled",
				label = "Enabled",
				hint = "A disabled provider is skipped by the fallback chain. Disabling the active "
					.. "one leaves it flagged active while requests go elsewhere.",
				value = record.enabled ~= false,
				layoutOrder = 1,
				onChange = function(value)
					record.enabled = value
					registry.save(record, { force = true })
				end,
			})
			R.toggle(behaviour, {
				name = "Stream",
				label = "Ask for a stream",
				hint = "Streamed replies carry reasoning text and token counts. Turning this off "
					.. "always takes effect; turning it on only does while Settings has streaming on.",
				value = record.stream ~= false,
				layoutOrder = 2,
				onChange = function(value)
					record.stream = value
					registry.save(record, { force = true })
				end,
			})
			R.toggle(behaviour, {
				name = "ClaudeUa",
				label = "Send the Claude Code identity",
				hint = "The claude-cli User-Agent and its client headers. Turning this off suppresses "
					.. "the whole set for this endpoint whatever the global switch says, which is the "
					.. "one lever this client has when a CDN in front of an API refuses the request.",
				value = record.claudeUa ~= false,
				layoutOrder = 3,
				onChange = function(value)
					record.claudeUa = value
					registry.save(record, { force = true })
				end,
			})

			-- Transport and the three invisible maps -----------------------------
			local advanced = R.section(detail.instance, {
				name = "Advanced",
				title = "Transport",
				description = "The socket URL, and the extra headers, body fields and query "
					.. "parameters this record sends. All three were stored and none were shown, "
					.. "which is why Azure's api-version and OpenRouter's attribution headers "
					.. "could not be inspected or corrected from here.",
				layoutOrder = order(),
			})
			R.field(advanced, {
				name = "SocketUrl",
				label = "Socket URL",
				hint = "Optional. A wss:// endpoint for streamed completions, which is what lifts "
					.. "the one-minute ceiling on a long reply.",
				value = record.wsUrl or "",
				placeholder = "wss://api.example.com/v1",
				layoutOrder = 1,
				onChange = function(text)
					record.wsUrl = util.trim(text)
					registry.save(record, { force = true })
				end,
			})

			local extras = {}
			for _, group in ipairs({
				{ field = "headers", label = "header" },
				{ field = "params", label = "body field" },
				{ field = "query", label = "query" },
			}) do
				for _, key in ipairs(util.keys(record[group.field] or {}, true)) do
					extras[#extras + 1] = {
						key = group.label .. " " .. tostring(key),
						value = tostring(record[group.field][key]),
					}
				end
			end
			if #extras > 0 then
				R.facts(advanced, extras, { name = "ExtraFacts", layoutOrder = 4 })
			else
				R.paragraph(advanced, "No extra headers, body fields or query parameters.",
					{ layoutOrder = 4 })
			end

			-- Fallback order ----------------------------------------------------
			local list = registry.list()
			if #list > 1 then
				local position = 1
				for index, entry in ipairs(list) do
					if entry.id == record.id then position = index end
				end
				local ordering = R.section(detail.instance, {
					name = "Order",
					title = "Fallback order",
					description = string.format(
						"Position %d of %d. When the active provider fails, the chain walks this list "
						.. "in order. registry.reorder has existed since the beginning with no control "
						.. "attached to it.", position, #list),
					layoutOrder = order(),
				})
				local moves = {}
				if position > 1 then
					moves[#moves + 1] = {
						name = "MoveUp",
						text = "Move up",
						variant = "secondary",
						onClick = function() registry.reorder(record.id, -1) end,
					}
				end
				if position < #list then
					moves[#moves + 1] = {
						name = "MoveDown",
						text = "Move down",
						variant = "secondary",
						onClick = function() registry.reorder(record.id, 1) end,
					}
				end
				R.actions(ordering, moves, { name = "OrderActions" })
			end

			-- Removal -----------------------------------------------------------
			local danger = R.section(detail.instance, {
				name = "Remove",
				title = "Remove",
				description = "The endpoint and its key are deleted from this device. This cannot "
					.. "be undone.",
				layoutOrder = order(),
			})
			R.actions(danger, {
				{
					name = "RemoveProvider",
					text = "Remove " .. record.label,
					-- The danger variant, which exists for exactly this and which every other
					-- destructive control in the app already uses. This one was a ghost button
					-- sitting between Edit and nothing.
					variant = "danger",
					onClick = function()
						-- Says what happens next. registry.remove silently promotes the first
						-- remaining record when the active one goes, and the old confirmation
						-- did not mention it.
						local successor = nil
						for _, entry in ipairs(registry.list()) do
							if entry.id ~= record.id and not successor then successor = entry end
						end
						local description = "The endpoint and its key are deleted from this device."
						if isActive and successor then
							description = description .. " " .. successor.label
								.. " becomes the active provider."
						elseif isActive then
							description = description .. " No provider will be configured afterwards."
						end
						overlay.confirm({
							title = "Remove " .. record.label .. "?",
							description = description,
							confirmText = "Remove",
							danger = true,
							onConfirm = function()
								registry.remove(record.id)
								panel.select(successor and successor.id or nil)
							end,
						})
					end,
				},
			}, { name = "DangerActions" })
		end

		-- Wiring ---------------------------------------------------------------

		function panel.select(id)
			local list = registry.list()
			if id and registry.get(id) then
				selected = id
			else
				local active = registry.active()
				selected = (active and active.id) or (list[1] and list[1].id) or nil
			end
			panel.renderRail()
			panel.renderDetail()
			detail.instance.CanvasPosition = Vector2.new(0, 0)
		end

		-- Health arrives on every single completion, and the panel used to rebuild
		-- itself from scratch each time -- header, rail, detail, scroll position, and the
		-- enable switch mid-animation. Only the facts block and the rail dots can change
		-- for a health event, so only those are repainted.
		local function repaintHealth()
			local record = selected and registry.get(selected) or nil
			local active = registry.active()
			for id, entry in pairs(railRows) do
				local candidate = registry.get(id)
				if candidate and entry.dot.Parent then
					entry.dot.BackgroundColor3 = dotFor(candidate, active and active.id == id)
				end
			end
			if record and statusBox and statusBox.Parent then
				local replacement = R.facts(statusBox.Parent, factsFor(record),
					{ name = "StatusFacts", layoutOrder = 1 })
				pcall(function() statusBox:Destroy() end)
				statusBox = replacement
			end
		end

		panel.select(nil)

		panel.unsubscribe = registry.changed:connect(function(reason)
			if not root.Parent then return end
			if reason == "health" then
				repaintHealth()
			else
				panel.select(selected)
			end
		end)
		root.Destroying:Connect(function() pcall(panel.unsubscribe) end)

		panel.root = root
		panel.scroll = detail
		return panel
	end

	return M
end
