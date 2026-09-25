return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local compare = env.require("ui/code/compare")
	local overlay = env.require("ui/overlay")
	local store = env.require("runtime/code_store")
	local limits = env.require("runtime/code_limits")
	local actions = env.require("runtime/code_actions")
	local runner = env.require("tools/code_runner")
	local util = env.require("runtime/util")
	local M = {}
	local function inputForm(def, callback)
		def = def or { type = "string", required = false }
		forms.form("Action input", {
			{ key = "key", label = "Input key", required = true, default = def.key },
			{ key = "label", label = "Label", default = def.label },
			{ key = "type", label = "Type", type = "choice", choices = { "string", "number", "boolean", "choice" }, default = def.type },
			{ key = "required", label = "Required", type = "boolean", default = def.required },
			{ key = "hasDefault", label = "Use a default", type = "boolean", default = def.default ~= nil },
			{ key = "default", label = "Default value (true or false for boolean)", default = def.default },
			{ key = "min", label = "Number minimum (optional)", type = "number", default = def.min },
			{ key = "max", label = "Number maximum (optional)", type = "number", default = def.max },
			{ key = "choices", label = "Choice values, one per line", multiline = true, default = table.concat(def.choices or {}, "\n") },
		}, function(data)
			local item = { key = data.key, label = data.label ~= "" and data.label or data.key, type = data.type, required = data.required }
			if data.type == "number" then item.min, item.max = data.min, data.max end
			if data.type == "choice" then item.choices = {}; for line in (data.choices .. "\n"):gmatch("(.-)\n") do if line ~= "" then item.choices[#item.choices + 1] = line end end end
			if data.hasDefault then
				if data.type == "number" then item.default = tonumber(data.default); if not item.default then return nil, "Enter a numeric default" end
				elseif data.type == "boolean" then if data.default ~= "true" and data.default ~= "false" then return nil, "Boolean default must be true or false" end; item.default = data.default == "true"
				else item.default = data.default end
			end
			local valid, why = actions.definitions({ item }); if not valid then return nil, why end
			callback(valid[1]); return true
		end, { description = "Read inputs with local inputs = ...; values are passed as data.", key = "action-input:" .. tostring(def.key or "new") })
	end
	function M.saveAction(doc, existing)
		if not doc then return end
		local key = "action:" .. (existing and existing.id or doc.id)
		local draft, why = forms.draft(key, { name = existing and existing.name or doc.name, description = existing and existing.description or "", inputs = util.deepCopy(existing and existing.inputs or {}), revision = existing and existing.revision })
		if not draft then common.message(nil, why); return end
		local modal = overlay.modal({ title = existing and "Update saved action" or "Save as action", description = "Explicit Run only. Inputs are available as local inputs = ..." })
		if not modal then return end
		forms.holdDraft(key, modal)
		forms.stopControl(modal)
		local column = P.column(modal.content, { size = UDim2.new(1, 0, 0, 0), auto = "Y", gap = theme.space.sm })
		P.text(column, { text = "Action name", auto = "Y", layoutOrder = 1 })
		P.field(column, { text = draft.name, layoutOrder = 2, onChange = function(value) draft.name = value end })
		P.text(column, { text = "Description", auto = "Y", layoutOrder = 3 })
		P.field(column, { text = draft.description, multiline = true, layoutOrder = 4, onChange = function(value) draft.description = value end })
		local inputs = P.column(column, { size = UDim2.new(1, 0, 0, 0), auto = "Y", layoutOrder = 5 })
		local refresh
		refresh = function()
			common.clear(inputs)
			for i, def in ipairs(draft.inputs) do
				local index = i
				common.button(inputs, { text = def.label .. " · " .. def.type, fill = true, size = "sm", layoutOrder = i, onClick = function(button)
					common.menu(button, def.key, { { label = "Edit input", value = "edit" }, { label = "Remove input", value = "remove" } }, function(action)
						if action == "remove" then table.remove(draft.inputs, index); refresh()
						else inputForm(def, function(value) draft.inputs[index] = value; if not modal.closed then refresh() end end) end
					end)
				end })
			end
			common.button(inputs, { text = "Add input (" .. #draft.inputs .. "/12)", fill = true, size = "sm", enabled = #draft.inputs < 12, layoutOrder = 20,
				onClick = function() inputForm(nil, function(value) draft.inputs[#draft.inputs + 1] = value; if not modal.closed then refresh() end end) end })
		end
		local errorLabel = P.text(column, { text = "", auto = "Y", wrap = true, color = theme.color.danger, layoutOrder = 6 })
		common.button(modal.footer, { text = "Cancel", size = "sm", variant = "ghost", onClick = function() modal.close() end })
		common.button(modal.footer, { text = existing and "Review update" or "Save action", size = "sm", variant = "primary", layoutOrder = 2, onClick = function()
			local definitions, why = actions.definitions(draft.inputs); if not definitions then errorLabel.Text = why; return end
			local current = store.resolve(doc.id); if not current then errorLabel.Text = "Source document was deleted"; return end
			local revision, source = current.revision, current.source
			local function save()
				local result, err = store.saveAction(doc.id, draft.name, definitions, { id = existing and existing.id, expected_revision = draft.revision, source_revision = revision, description = draft.description })
				if not result then return nil, err end
				forms.discardDraft(key); return result
			end
			if existing then modal.close(true); compare.open(existing.source, source, "Update " .. existing.name, save)
			else local result, err = save(); if not result then errorLabel.Text = err else modal.close(true) end end
		end })
		refresh()
	end
	function M.runAction(action, navigate)
		local definitions = util.deepCopy(action.inputs)
		for _, definition in ipairs(definitions) do definition.optional = not definition.required and definition.default == nil end
		forms.form("Run " .. action.name, definitions, function(inputs)
			local result, why = runner.startAction(action.id, action.revision, inputs)
			if not result then return nil, why end
			if navigate then navigate("Output") end; return true
		end, { key = "action-run:" .. action.id, submit = "Run", danger = true, description = "Saved action revision " .. action.revision .. ". This executes Luau in the local client." })
	end
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "CodeLibrary", size = UDim2.fromScale(1, 1) })
		local query = store.workspace.libraryQuery or ""
		local bar = common.toolbar(root)
		local mode, search, list
		local function remove(row)
			local item = row.kind == "document" and store.resolve(row.id) or store.action(row.id)
			if not item then return end
			local revision = item.revision
			overlay.confirm({ title = "Delete " .. item.name .. "?",
				description = "This removes the saved " .. row.kind .. ". Closing a script view keeps it in the library.",
				danger = true, confirmText = "Delete", onConfirm = function()
					local current = row.kind == "document" and store.resolve(row.id) or store.action(row.id)
					if not current or current.revision ~= revision then common.message(nil, "This entry changed; review it before deleting."); return end
					if row.kind == "document" then common.message(store.delete(row.id)) else common.message(store.deleteAction(row.id)) end
				end })
		end
		local function render()
			if not list then return end
			local items, needle = {}, query:lower()
			for _, doc in ipairs(store.list()) do if doc.name:lower():find(needle, 1, true) then items[#items + 1] = { kind = "document", id = doc.id, label = "Script · " .. doc.name .. " · r" .. doc.revision .. " · " .. #doc.source .. " bytes" } end end
			for _, action in ipairs(store.actions()) do if action.name:lower():find(needle, 1, true) then items[#items + 1] = { kind = "action", id = action.id, label = "Action · " .. action.name .. " · " .. #action.inputs .. " inputs · r" .. action.revision } end end
			list.set(items, true)
			local scripts, acts = #store.list(), #store.actions()
			mode.setText(scripts .. "/" .. limits.documents .. " scripts · " .. acts .. "/" .. limits.actions .. " actions")
		end
		mode = bar.add("Scripts & actions", function() end, { flex = true })
		bar.add("New", function()
			forms.form("New script", { { key = "name", label = "Name", required = true, default = "Untitled.lua" } }, function(data)
				local doc, why = store.create(data.name, "", { select = true }); if not doc then return nil, why end; navigate("Editor"); return true
			end)
		end, { icon = "plus" })
		search = P.field(root, { name = "LibrarySearch", placeholder = "Search script and action names", text = query, onChange = function(value) query = value; store.workspace.libraryQuery = value; render() end })
		search.shell.Position, search.shell.Size = UDim2.fromOffset(common.inset(), common.barHeight() + theme.space.xs), UDim2.new(1, -common.inset() * 2, 0, common.controlHeight())
		local top = common.barHeight() * 2 + theme.space.sm
		list = common.virtualList(root, { position = UDim2.fromOffset(0, top), size = UDim2.new(1, 0, 1, -top),
			onClose = remove,
			onSelect = function(row, _, button)
			local item = row.kind == "document" and store.resolve(row.id) or store.action(row.id); if not item then render(); return end
			local options = row.kind == "document" and { { label = "Open script", value = "open" }, { label = "Rename", value = "rename" }, { label = "Save as action", value = "save" }, { label = "Export source", value = "export" }, { label = "Delete script", value = "delete" } }
				or { { label = "Run with inputs", value = "run" }, { label = "Inspect / edit source snapshot", value = "open" }, { label = "Update from active script…", value = "save" }, { label = "Delete action", value = "delete" } }
			common.menu(button or mode, item.name, options, function(action)
				if action == "open" then
					local doc, why = item
					if row.kind == "action" then doc, why = store.create(item.name .. " (action)", item.source, { provenance = "Action " .. item.id .. " revision " .. item.revision, bindingId = item.bindingId }) end
					if common.message(doc, why) and common.message(store.select(doc.id)) then store.workspace.sourceId = nil; navigate("Editor") end
				elseif action == "run" then M.runAction(item, navigate)
				elseif action == "save" then M.saveAction(row.kind == "document" and item or store.active(), row.kind == "action" and item or nil)
				elseif action == "rename" then forms.form("Rename script", { { key = "name", label = "Name", default = item.name, required = true } }, function(data) return store.rename(item.id, data.name) end)
				elseif action == "export" then common.work(function() return env.require("runtime/native_exports").write(item.source, "exports/" .. store.id("script") .. ".lua") end, function(result) common.copy(result.path); overlay.toast("Exported " .. result.path, "good") end)
				elseif action == "delete" then remove(row) end
			end)
		end })
		local off = store.changed:connect(function(event) if event.kind ~= "source" then render() end end)
		local handle = { root = root, list = list, render = render }
		function handle.destroy() store.workspace.libraryY = list.root.CanvasPosition.Y; off(); root:Destroy() end
		render(); list.root.CanvasPosition = Vector2.new(0, store.workspace.libraryY or 0); return handle
	end
	return M
end
