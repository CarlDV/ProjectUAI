return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local overlay = env.require("ui/overlay")
	local explorer = env.require("runtime/explorer")
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local fields = env.require("runtime/instance_fields")
	local edits = env.require("runtime/instance_edits")
	local store = env.require("runtime/code_store")
	local clock = env.require("runtime/clock")
	local util = env.require("runtime/util")
	local instanceIcons = env.require("ui/instance_icons")
	local M = {}
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "NativeExplorer", size = UDim2.fromScale(1, 1), clip = true })
		local view = explorer.view
		view.pages, view.section = view.pages or {}, view.section or "properties"
		view.root = view.root or refs.id(game)
		local handle = { root = root, alive = true, visible = true }
		local treeHost = P.frame(root, { name = "Hierarchy", clip = true })
		local detailHost = P.frame(root, { name = "Inspector", clip = true })
		local treeBar, detailBar = common.toolbar(treeHost), common.toolbar(detailHost)
		local treeList, propertyList, refresh, layout, refreshProperties, observerOff, primary, menuButton
		local detailSnapshot, selectedCopy, busy = nil, {}, false
		local searchGeneration, debounceGeneration = 0, 0
		local dirtyBranches, selectingRow = {}, false
		local search, changingSearch
		local function setSearchText(text)
			changingSearch = true
			if search and search.get() ~= text then search.set(text) end
			store.workspace.explorerQuery = text
			changingSearch = false
		end
		local function clearSearch()
			searchGeneration, debounceGeneration = searchGeneration + 1, debounceGeneration + 1
			view.query, view.class, view.tag, view.searchRoot, busy = nil, nil, nil, nil, false
			setSearchText("")
		end
		local function held(name)
			local ok, down = pcall(function() return env.uis:IsKeyDown(Enum.KeyCode[name]) end)
			return ok and down
		end
		local status = P.text(treeHost, { text = "", color = theme.color.textSecondary, role = "caption", truncate = true })
		local function page(key, more)
			local old = view.pages[key]
			local result, why = explorer.children((key ~= "nil" and key ~= "bookmarks") and key or nil, more and old and old.nextCursor or nil, 50, (key == "nil" or key == "bookmarks") and key or nil)
			if not result then status.Text = tostring(why); return end
			if more and old then for _, item in ipairs(result.items) do old.items[#old.items + 1] = item end; old.nextCursor = result.nextCursor
			else view.pages[key] = result end
			view.pages[key].at = clock.ms()
			local count = util.count(view.pages)
			if count > 64 then
				local oldest
				for id, item in pairs(view.pages) do if id ~= key and id ~= view.root and (not oldest or item.at < view.pages[oldest].at) then oldest = id end end
				if oldest then view.pages[oldest] = nil end
			end
			return view.pages[key]
		end
		local function chooseSource(id)
			common.work(function() return env.require("tools/source_documents").open({ instanceId = id, focus = true }, { aborted = function() return not handle.alive end }) end, function() if handle.alive then navigate("Editor") end end)
		end
		local function reveal(key)
			local object = refs.resolve(key); if not object then return end
			local chain, current = {}, object.Parent
			while current and #chain < 64 do chain[#chain + 1] = refs.id(current); current = current.Parent end
			clearSearch(); view.root = chain[#chain] or "nil"
			for i = #chain, 1, -1 do explorer.expanded[chain[i]] = true; page(chain[i]) end
			if #chain == 0 then page("nil") end
		end
		local function pick()
			common.message(env.require("ui/code/world_picker").start(function(key)
				if not handle.alive then return end
				reveal(key); view.detail = true; refresh(); refreshProperties(); layout(); treeList.focusKey(key)
			end))
		end
		local function selectedInfo()
			local ids, parents = util.copy(explorer.selectedIds), {}
			for _, id in ipairs(ids) do local object = refs.resolve(id); if not object then return nil, "A selected object expired" end; parents[id] = values.node(object.Parent) end
			return ids, parents
		end
		local function performHierarchy(action)
			local ids, parents = selectedInfo(); if not common.message(ids, parents) or #ids == 0 then return end
			local function apply(args)
				args.expectedParents = parents
				local result = edits.hierarchyMany(action, ids, args)
				common.message(result); view.pages = {}; page(view.root); refresh(); refreshProperties(); return result.ok, result.text
			end
			if action == "delete" or action == "detach" then
				overlay.confirm({ title = (action == "delete" and "Delete " or "Detach ") .. #ids .. " selected objects?", description = "These exact objects are bound to this action. Hierarchy operations are outside supported Undo.", danger = true, confirmText = action == "delete" and "Delete" or "Detach", onConfirm = function() apply({}) end })
			elseif action == "reparent" then forms.form("Move selected objects", { { key = "parentId", label = "Destination object reference", required = true, default = view.moveTarget } }, function(data) view.moveTarget = data.parentId; return apply(data) end, { key = "explorer-move", description = "Copy the destination object's reference from its More menu before moving." })
			else apply({ parentIds = parents }) end
		end
		local function addField(kind)
			local ids = util.copy(explorer.selectedIds); if #ids == 0 then return end
			forms.form(kind == "attribute" and "Add attribute" or "Add tag", { { key = "key", label = "Exact name", required = true }, { key = "type", label = "Value type", type = "choice", choices = kind == "tag" and { "boolean" } or forms.types } }, function(data)
				local operations = {}
				for _, id in ipairs(ids) do
					local object, why = refs.resolve(id); if not object then return nil, why end
					local ok, before = fields.read(object, kind, data.key); if not ok then return nil, "Field unavailable" end
					operations[#operations + 1] = { instanceId = id, kind = kind, key = data.key, expected = values.node(before) }
				end
				local function write(value)
					for _, op in ipairs(operations) do op.value = value end
					local result = edits.apply(operations); refreshProperties(); return result.ok, result.text
				end
				if kind == "tag" then return write(values.node(true)) end
				clock.delay(0, function() forms.typed({ kind = data.type }, "Attribute value", write, { key = "attribute:" .. data.key }) end)
				return true
			end, { key = "explorer-new-" .. kind })
		end
		local function actionsMenu(button)
			local id = explorer.primaryId; local object = id and refs.resolve(id)
			local options = {
				{ label = view.selectMode and "Finish multiple selection" or "Select multiple objects", value = "multi" },
				{ label = "Game roots", value = "game" }, { label = "Session bookmarks", value = "bookmarks" }, { label = "Nil / unparented objects", value = "nil" },
				{ label = "Search options…", value = "search" }, { label = "World picker…", value = "pick" },
			}
			if object then
				for _, pair in ipairs({ { "Copy object reference", "reference" }, { "Copy diagnostic path", "path" }, { "Parent / breadcrumb", "parent" }, { "Bookmark object", "bookmark" }, { "Remove bookmark", "unbookmark" }, { "Rename", "rename" }, { "Move…", "reparent" }, { "Detach…", "detach" }, { "Create child…", "create" }, { "Duplicate", "duplicate" }, { "Delete…", "delete" }, { "Add attribute…", "attribute" }, { "Add tag…", "tag" }, { "Open script source", "source" }, { "View in Remotes", "remotes" }, { "Export metadata…", "export" }, { "Ask AI about selection", "ask" } }) do options[#options + 1] = { label = pair[1], value = pair[2] } end
			end
			common.menu(button or menuButton, "Explorer actions", options, function(action)
				if action == "multi" then view.selectMode = not view.selectMode; refresh()
				elseif action == "game" or action == "bookmarks" or action == "nil" then view.root = action == "game" and refs.id(game) or action; clearSearch(); page(view.root); view.detail = false; refresh(); layout()
				elseif action == "search" then forms.form("Search objects", { { key = "name", label = "Name", default = store.workspace.explorerQuery }, { key = "class", label = "Class (optional)", default = view.class }, { key = "tag", label = "Tag (optional)", default = view.tag }, { key = "scope", label = "Scope", type = "choice", choices = { "Current root", "Selected subtree", "Game" } }, { key = "pattern", label = "Use Lua pattern", type = "boolean", default = view.pattern } }, function(data)
					view.class, view.tag, view.pattern = data.class, data.tag, data.pattern; view.searchRoot = data.scope == "Selected subtree" and id or data.scope == "Game" and refs.id(game) or view.root
					store.preference("explorerQuery", data.name); handle.search(data.name); return true
				end, { key = "explorer-search" })
				elseif action == "pick" then pick()
				elseif action == "reference" then common.copy(id)
				elseif action == "path" then common.copy(refs.describe(object).displayPath)
				elseif action == "bookmark" or action == "unbookmark" then common.message(explorer.bookmark(id, action == "unbookmark"))
				elseif action == "parent" then if object.Parent then view.root = refs.id(object.Parent); clearSearch(); view.detail = false; page(view.root); refresh(); layout() end
				elseif action == "source" then chooseSource(id)
				elseif action == "remotes" then if object:IsA("RemoteEvent") or object:IsA("RemoteFunction") or object.ClassName == "UnreliableRemoteEvent" then
					local capture = env.require("runtime/remote_capture"); capture.select(nil)
					capture.view.remoteId, capture.view.record, capture.view.argumentDraft, capture.view.detail = id, nil, nil, true
					navigate("Remotes")
				else common.message(nil, "Choose a RemoteEvent or RemoteFunction") end
				elseif action == "ask" then common.ask("Inspect Explorer selection " .. id .. " (selection revision " .. explorer.selectionRevision .. ").")
				elseif action == "attribute" or action == "tag" then addField(action)
				elseif action == "rename" then
					local expected = values.node(object.Name)
					forms.form("Rename object", { { key = "name", label = "Name", default = object.Name, required = true } }, function(data) local result = edits.apply({ { instanceId = id, kind = "property", key = "Name", expected = expected, value = values.node(data.name) } }); return result.ok, result.text end, { key = "rename:" .. id })
				elseif action == "create" then forms.form("Create child", { { key = "class", label = "Class", default = "Folder", required = true }, { key = "name", label = "Name", default = "New object", required = true } }, function(data) data.parentId = id; local result = edits.hierarchy("create", data); page(id); refresh(); return result.ok, result.text end, { key = "create:" .. id })
				elseif action == "export" then
					local ids = util.copy(explorer.selectedIds)
					forms.form("Export selected metadata", { { key = "depth", label = "Descendant depth (0 for selected only)", type = "number", min = 0, max = 8, default = 0 }, { key = "destination", label = "File under workspace files (optional)" } }, function(data)
						common.work(function() return env.require("runtime/native_exports").explorer(ids, { depth = data.depth, destination = data.destination ~= "" and data.destination or nil }) end, function(result) overlay.toast("Exported " .. result.path, "good") end); return true
					end)
				else performHierarchy(action) end
			end)
		end
		primary = treeBar.add("Game roots", function(button)
			common.menu(button, "Hierarchy root", { { label = "Game", value = refs.id(game) }, { label = "Bookmarks", value = "bookmarks" }, { label = "Nil objects", value = "nil" } }, function(key) view.root, view.detail = key, false; clearSearch(); page(key); refresh(); layout() end)
		end, { flex = true })
		treeBar.add("Pick", pick, { name = "PickWorldObject", tight = true })
		treeBar.add("Refresh", function() view.pages = {}; if view.query then handle.search(store.workspace.explorerQuery) else page(view.root); refresh() end end, { tight = true })
		menuButton = treeBar.add("", actionsMenu, { icon = "ellipsis", iconOnly = true, name = "ExplorerActions" })
		search = P.field(treeHost, { name = "ExplorerSearch", placeholder = "Search name", text = store.workspace.explorerQuery or "", onChange = function(text)
			if changingSearch then return end
			store.workspace.explorerQuery = text; debounceGeneration = debounceGeneration + 1; local generation = debounceGeneration
			clock.delay(0.3, function() if handle.alive and handle.visible and generation == debounceGeneration and handle.search then handle.search(text) end end)
		end, onSubmit = function(text) debounceGeneration = debounceGeneration + 1; handle.search(text) end })
		search.shell.Position, search.shell.Size = UDim2.fromOffset(8, common.barHeight() + theme.space.xs), UDim2.new(1, -16, 0, common.barHeight())
		local top = common.barHeight() * 2 + theme.space.sm
		local inspectWidth = common.buttonWidth("Inspect", { tight = true })
		status.Position, status.Size = UDim2.fromOffset(common.inset(), top), UDim2.new(1, -common.inset() * 2 - inspectWidth - common.gap(), 0, common.barHeight())
		local inspectButton = common.button(treeHost, { name = "InspectSelection", text = "Inspect", fill = true, tight = true, onClick = function() view.detail = true; refreshProperties(); layout() end })
		inspectButton.instance.Position, inspectButton.instance.Size = UDim2.new(1, -common.inset() - inspectWidth, 0, top + 4), UDim2.fromOffset(inspectWidth, common.controlHeight())
		top = top + common.barHeight()
		treeList = common.virtualList(treeHost, { name = "InstanceTree", dense = true, position = UDim2.fromOffset(0, top), size = UDim2.new(1, 0, 1, -top),
			label = function(row) return row.label end,
			icon = function(row) return row.instanceId and row.className or nil end,
			indent = function(row) return row.depth or 0 end,
			chevron = function(row)
				if not row.instanceId or row.hasChildren == false then return nil end
				return explorer.expanded[row.instanceId] and "open" or "closed"
			end,
			onToggle = function(row)
				if not row.instanceId then return end
				local key = row.instanceId
				if explorer.expanded[key] then
					explorer.collapse(key)
					view.pages[key] = nil
				else
					explorer.expanded[key] = true
					page(key)
				end
				refresh()
			end,
			onDoubleClick = function(row)
				if not row.instanceId then return end
				local key = row.instanceId
				local object = refs.resolve(key)
				if object and (object:IsA("LuaSourceContainer") or object:IsA("Script") or object:IsA("LocalScript") or object:IsA("ModuleScript")) then
					chooseSource(key)
				else view.detail = true; layout(); refreshProperties() end
			end,
			onContextMenu = function(row, rowIndex, button)
				if not row.instanceId then return end
				if not row.selected then
					selectingRow = true; local result, why = explorer.select({ row.instanceId }); selectingRow = false
					if not common.message(result, why) then return end
					refresh(); refreshProperties()
				end
				actionsMenu(button or menuButton)
			end,
			onSelect = function(row, rowIndex, button)
				if row.more then if view.query then handle.search(nil, true) else page(row.more, true); refresh() end; return end
				if not row.instanceId then return end
				local key = row.instanceId
				local modifier = held("LeftControl") or held("RightControl") or held("LeftMeta") or held("RightMeta")
				local range = held("LeftShift") or held("RightShift")
				local mode, ids = "replace", { key }
				if range and view.anchorId then
					local anchor
					for i, item in ipairs(treeList.items) do if item.instanceId == view.anchorId then anchor = i; break end end
					if anchor then
						ids = {}; for i = math.min(anchor, rowIndex), math.max(anchor, rowIndex) do local id = treeList.items[i].instanceId; if id then ids[#ids + 1] = id end end
						if modifier then mode = "add" end
					end
				elseif view.selectMode or modifier then mode = "add"; for _, id in ipairs(explorer.selectedIds) do if id == key then mode = "remove" end end end
				selectingRow = true; local result, why = explorer.select(ids, mode, explorer.selectionRevision); selectingRow = false
				if not common.message(result, why) then return end
				if not range then view.anchorId = key end
				if not modifier and not range and not view.selectMode then
					if row.hasChildren and not explorer.expanded[key] then explorer.expanded[key] = true; page(key)
					elseif row.hasChildren == false then view.detail = true end
				end
				refresh(); refreshProperties(); layout()
		end })
		local backButton = detailBar.add("Back", function() view.detail = false; layout() end, { icon = "arrowLeft" })
		local sectionButton = detailBar.add("Inspector", function() end, { flex = true, trailing = false })
		local sourceButton = detailBar.add("Source", function() if explorer.primaryId then chooseSource(explorer.primaryId) end end, { name = "OpenInstanceSource", tight = true })
		detailBar.add("", actionsMenu, { icon = "ellipsis", iconOnly = true, name = "DetailActions" })
		local sectionTabs = env.require("ui/code/tabs").new(detailHost, { name = "InspectorSections", position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(section) view.section = section; refreshProperties() end })
		local identityIcon = Instance.new("ImageLabel", detailHost)
		identityIcon.Name, identityIcon.BackgroundTransparency, identityIcon.BorderSizePixel = "DetailIcon", 1, 0
		identityIcon.Size = UDim2.fromOffset(theme.size.iconLarge, theme.size.iconLarge)
		identityIcon.Position = UDim2.fromOffset(theme.space.sm, common.barHeight() * 2 + theme.space.xs)
		identityIcon.ScaleType, identityIcon.Visible = Enum.ScaleType.Fit, false
		local identityInset = theme.size.iconLarge + theme.space.sm * 2
		local identity = P.text(detailHost, { text = "Select an object", role = "caption", truncate = true, position = UDim2.fromOffset(identityInset, common.barHeight() * 2), size = UDim2.new(1, -identityInset - theme.space.sm, 0, theme.text.caption.height * 2 + theme.space.sm) })
		local detailTop = common.barHeight() * 2 + theme.text.caption.height * 2 + theme.space.sm
		local propertySearch = P.field(detailHost, { name = "PropertySearch", placeholder = "Filter properties", role = "small", text = view.propertyQuery or "", onChange = function(text) view.propertyQuery = text; refreshProperties() end })
		propertySearch.shell.Position, propertySearch.shell.Size = UDim2.fromOffset(8, detailTop), UDim2.new(1, -16, 0, common.barHeight())
		detailTop = detailTop + common.barHeight() + 8
		propertyList = common.virtualList(detailHost, { name = "InstanceProperties", dense = true, position = UDim2.fromOffset(0, detailTop), size = UDim2.new(1, 0, 1, -detailTop), label = function(row) return row.key or row.label end, value = function(row) return row.valueText end, onSelect = function(row, _, button)
			if not row.key then return end
			local snapshot, ids = detailSnapshot, util.copy(selectedCopy)
			local first = row.observations[1].value
			local options = { { label = "Inspect value", value = "inspect" } }
			if row.writable then options[#options + 1] = { label = "Edit field", value = "edit" } end
			if row.kind == "attribute" or row.kind == "tag" then options[#options + 1] = { label = "Remove " .. row.kind, value = "remove" } end
			if first.kind == "Instance" then options[#options + 1] = { label = "Reveal reference", value = "reveal" } end
			if row.key == "Source" then options[#options + 1] = { label = "Open source", value = "source" } end
			common.menu(button or sectionButton, row.key, options, function(action)
				if action == "source" then chooseSource(ids[1]); return end
				if action == "reveal" then common.message(explorer.select({ first.instanceId })); return end
				if action == "inspect" then local lines = {}; for _, observation in ipairs(row.observations) do lines[#lines + 1] = observation.instanceId .. "\n" .. values.format(observation.value) end; overlay.code({ title = row.key, code = table.concat(lines, "\n\n") }); return end
				local function apply(value)
					local operations = {}
					for _, id in ipairs(ids) do
						local expected, why = explorer.expected(snapshot, id, row.kind, row.key); if not expected then return nil, why end
						operations[#operations + 1] = { instanceId = id, kind = row.kind, key = row.key, expected = expected, value = value }
					end
					local result = edits.apply(operations); refreshProperties(); return result.ok, result.text
				end
				if action == "remove" then local value = { kind = "nil" }; if row.kind == "tag" then value = values.node(false) end; local ok, why = apply(value); common.message(ok, why)
				else forms.typed(first, "Edit " .. row.key .. (#ids > 1 and (" on " .. #ids .. " objects") or ""), apply, { key = "property:" .. ids[1] .. ":" .. row.key, description = "Current: " .. (row.mixed and "Mixed values" or values.format(first)) }) end
			end)
		end })
		refreshProperties = function()
			if not handle.alive or not handle.visible or not propertyList then return end
			selectedCopy = util.copy(explorer.selectedIds)
			sectionButton.setText("Inspector" .. (#selectedCopy > 1 and (" · " .. #selectedCopy) or ""))
			sectionTabs.set({ { id = "properties", label = "Properties" }, { id = "attributes", label = "Attributes" }, { id = "tags", label = "Tags" } }, view.section)
			inspectButton.setEnabled(#selectedCopy > 0)
			sourceButton.instance.Visible = false
			if #selectedCopy == 0 then propertyList.set({}); identity.Text = "Select an object"; identityIcon.Visible = false; return end
			local object = refs.resolve(explorer.primaryId); local info = object and refs.describe(object)
			sourceButton.instance.Visible = object ~= nil and object:IsA("LuaSourceContainer")
			identityIcon.Visible = info ~= nil
			if info then instanceIcons.paint(identityIcon, info.className) end
			identity.Text = info and (info.name .. " · " .. info.className .. "\n" .. util.ellipsis(info.displayPath, 180)) or "Selected object is no longer available"
			local result, why = explorer.properties(selectedCopy, view.section)
			if not result then propertyList.set({ { label = tostring(why) } }); return end
			detailSnapshot = result.snapshotId
			local items, needle = {}, (view.propertyQuery or ""):lower()
			for _, row in ipairs(result.items) do
				if needle == "" or row.key:lower():find(needle, 1, true) then
					row.id = row.kind .. ":" .. row.key
					row.valueText = (row.mixed and "Mixed values" or values.format(row.observations[1].value)) .. (row.writable and "" or "  · read only")
					items[#items + 1] = row
				end
			end
			if #items == 0 then items[1] = { label = needle ~= "" and "No matching fields" or "No " .. view.section .. ". Use More to add fields." } end
			propertyList.set(items, true)
		end
		refresh = function()
			if not handle.alive or not handle.visible then return end
			local rows, selected, seen = {}, {}, {}
			for _, id in ipairs(explorer.selectedIds) do selected[id] = true end
			local function append(items, depth)
				for _, item in ipairs(items or {}) do
					if #rows >= 4000 then return end
					local row = util.copy(item); row.selected = selected[item.instanceId]; row.depth = math.min(depth, 12)
					row.label = (view.query and item.className and item.className ~= "" and item.name ~= item.className) and (item.name .. "  ·  " .. item.className) or item.name
					rows[#rows + 1] = row
					if explorer.expanded[item.instanceId] and not seen[item.instanceId] then
						seen[item.instanceId] = true; local branch = view.pages[item.instanceId] or page(item.instanceId)
						if branch then append(branch.items, depth + 1); if branch.nextCursor then rows[#rows + 1] = { more = item.instanceId, label = "Load more children…", depth = math.min(depth + 1, 12) } end end
					end
				end
			end
			local result = view.query or view.pages[view.root]
			if result then append(result.items, 0); if result.nextCursor then rows[#rows + 1] = { more = view.root, label = "Load more…" } end end
			if #rows == 0 then rows[1] = { label = busy and "Searching…" or "No objects found" } end
			status.Text = (busy and "Searching… · " or view.selectMode and "Select mode · " or "") .. #explorer.selectedIds .. " selected" .. (view.query and (" · " .. (result.scanned or 0) .. " scanned · " .. (result.reason or "complete")) or result and result.complete == false and " · Partial results" or "")
			primary.setText(view.query and "Search" or (view.root == "nil" and "Nil objects" or view.root == "bookmarks" and "Bookmarks" or "Game"))
			treeList.set(rows, true)
		end
		function handle.search(text, more)
			if more and busy then return end
			searchGeneration = searchGeneration + 1; local generation = searchGeneration; busy = true
			if not more then setSearchText(text or ""); store.preference("explorerQuery", text or ""); view.query = nil end
			if not more and util.trim(text or "") == "" and (not view.class or view.class == "") and (not view.tag or view.tag == "") then busy = false; page(view.root); refresh(); return end
			local query = { name = text or store.workspace.explorerQuery, class = view.class, tag = view.tag ~= "" and view.tag or nil, pattern = view.pattern, rootId = view.searchRoot or ((view.root ~= "nil" and view.root ~= "bookmarks") and view.root or refs.id(game)), limit = 100, cursor = more and view.query and view.query.nextCursor or nil }
			clock.spawn(function()
				local result, why = explorer.query(query, { aborted = function() return not handle.alive or not handle.visible or generation ~= searchGeneration end })
				if not handle.alive or generation ~= searchGeneration then return end; busy = false
				if not result then status.Text = tostring(why); return end
				if more and view.query then for _, item in ipairs(result.items) do view.query.items[#view.query.items + 1] = item end; view.query.nextCursor = result.nextCursor else view.query = result end
				refresh()
			end)
		end
		local divider = env.require("ui/code/splitter").new(root, function(position)
			view.treeWidth = math.max(240, math.min(root.AbsoluteSize.X - 280, position.X - root.AbsolutePosition.X)); layout()
		end)
		layout = function()
			local wide = root.AbsoluteSize.X >= 620
			local width = math.max(240, math.min(root.AbsoluteSize.X - 280, view.treeWidth or root.AbsoluteSize.X * 0.42))
			treeHost.Visible, detailHost.Visible = wide or not view.detail, wide or view.detail == true
			treeHost.Size = wide and UDim2.new(0, width, 1, 0) or UDim2.fromScale(1, 1)
			detailHost.Position, detailHost.Size = UDim2.fromOffset(wide and width + 6 or 0, 0), UDim2.new(1, wide and -width - 6 or 0, 1, 0)
			backButton.instance.Visible, divider.root.Visible = not wide, wide and handle.visible
			divider.root.Position, divider.root.Size = UDim2.fromOffset(width, 0), UDim2.new(0, 6, 1, 0)
		end
		local queued = false
		local function queue()
			if queued or not handle.visible then return end; queued = true
			clock.delay(0.1, function()
				queued = false
				if handle.alive and handle.visible then
					local dirty = dirtyBranches; dirtyBranches = {}
					for key in pairs(dirty) do if key == view.root or explorer.expanded[key] then page(key) end end
					refreshProperties(); refresh()
				end
			end)
		end
		local function observe()
			if observerOff then observerOff(); observerOff = nil end
			if handle.visible then observerOff = explorer.observe(explorer.selectedIds, function()
				for _, id in ipairs(explorer.selectedIds) do local object = refs.resolve(id); if object and object.Parent then dirtyBranches[refs.id(object.Parent)] = true end end
				queue()
			end) end
		end
		local off = explorer.changed:connect(function(event)
			if event.kind == "selection" then
				if not selectingRow and explorer.primaryId then reveal(explorer.primaryId); view.detail = true; refresh(); layout(); treeList.focusKey(explorer.primaryId) end
				observe(); queue()
			elseif event.kind == "branch" then dirtyBranches[event.parentId] = true; queue() end
		end)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		function handle.setVisible(visible)
			if visible == handle.visible then return end
			handle.visible = visible; treeList.visible, propertyList.visible = visible, visible; observe()
			if visible then page(view.root); if explorer.primaryId then reveal(explorer.primaryId) end; queue(); refresh(); refreshProperties(); layout()
			else searchGeneration = searchGeneration + 1; busy = false; env.require("ui/code/world_picker").stop() end
			divider.root.Visible = visible and root.AbsoluteSize.X >= 620
		end
		function handle.destroy() handle.alive = false; view.y = treeList.root.CanvasPosition.Y; off(); if observerOff then observerOff() end; divider.destroy(); env.require("ui/code/world_picker").stop(); root:Destroy() end
		handle.list, handle.more, handle.refresh = treeList, actionsMenu, function() refresh(); refreshProperties() end
		if explorer.primaryId then reveal(explorer.primaryId) end
		if not view.pages[view.root] then page(view.root) end
		refresh(); refreshProperties(); observe(); layout(); treeList.root.CanvasPosition = Vector2.new(0, view.y or 0)
		return handle
	end
	return M
end
