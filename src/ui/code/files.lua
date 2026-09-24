return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local files = env.require("runtime/code_files")
	local store = env.require("runtime/code_store")
	local util = env.require("runtime/util")
	local M = {}
	function M.saveDocument(doc, saveAs, done)
		if not doc then return end
		local binding = files.binding(doc.id)
		local function save(path)
			local result, why = files.save(doc.id, path)
			if not result then return nil, why end
			files.reveal((files.binding(doc.id) or {}).path)
			env.require("ui/overlay").toast("Saved " .. result.path, "good")
			if done then done(result) end
			return true
		end
		if binding and not saveAs then common.message(save()); return end
		forms.form("Save source file", { { key = "path", label = "File under " .. files.root, required = true, default = binding and binding.path or "files/" .. doc.name } }, function(data) return save(data.path) end, { key = "code-save-file:" .. doc.id, submit = "Save" })
	end
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "WorkspaceFiles", size = UDim2.fromScale(1, 1), clip = true })
		local view = files.view
		local handle = { root = root, alive = true, visible = true }
		local bar = common.toolbar(root)
		local list, refresh
		local title = bar.add("Workspace", function(button)
			common.menu(button, "Workspace files", { { label = "Collapse folders", value = "collapse" }, { label = "Reveal active file", value = "reveal" }, { label = "New folder", value = "folder" }, { label = "Open by path…", value = "path" } }, function(action)
				if action == "collapse" then view.expanded = { [""] = true }; refresh()
				elseif action == "reveal" then local binding = files.binding(store.activeId()); if binding then files.reveal(binding.path); refresh(); list.focusKey("file:" .. binding.path) end
				elseif action == "folder" then handle.create(true)
				else forms.form("Open workspace file", { { key = "path", label = "File under " .. files.root, required = true, default = "files/" } }, function(data) return handle.open(data.path) end, { submit = "Open" }) end
			end)
		end, { flex = true })
		bar.add("", function() handle.create(false) end, { icon = "plus", iconOnly = true, name = "NewWorkspaceFile" })
		bar.add("Refresh", function() view.pages = {}; refresh() end, { tight = true, name = "RefreshWorkspaceFiles" })
		local filter = P.field(root, { name = "WorkspaceFileSearch", placeholder = "Filter loaded files", text = view.query or "", role = "small", onChange = function(text) view.query = text; if refresh then refresh() end end })
		filter.shell.Position, filter.shell.Size = UDim2.fromOffset(8, common.barHeight() + 6), UDim2.new(1, -16, 0, common.barHeight())
		local top = common.barHeight() * 2 + 12
		local hint = P.text(root, { name = "WorkspaceFileStatus", text = "Click a folder to expand · click a file to open", role = "caption", color = theme.color.textSecondary, truncate = true, position = UDim2.new(0, 8, 1, -24), size = UDim2.new(1, -16, 0, 24) })
		local function load(path)
			local result, why = files.children(path)
			view.pages[path] = { items = result or {}, error = why, limit = 200 }
			return view.pages[path]
		end
		local function toggle(row)
			if not row.isDir then return end
			view.expanded[row.path] = not view.expanded[row.path]
			if view.expanded[row.path] then load(row.path) end
			refresh()
		end
		function handle.open(path)
			local result, why = files.open(path); if not result then return nil, why end
			files.reveal(path); navigate("Editor"); return result
		end
		function handle.create(folder)
			local base = view.selected and (view.pages[view.selected] and view.selected or view.selected:match("^(.*)/[^/]+$")) or "files"
			forms.form(folder and "New workspace folder" or "New workspace file", { { key = "path", label = "Path under " .. files.root, required = true, default = (base ~= "" and base .. "/" or "") .. (folder and "New folder" or "Untitled.lua") } }, function(data)
				local result, why = files.create(data.path, folder); if not result then return nil, why end
				files.reveal(result.path); refresh()
				if not folder then return handle.open(result.path) end
				return true
			end, { key = "workspace-new", submit = "Create" })
		end
		list = common.virtualList(root, { name = "WorkspaceFileTree", position = UDim2.fromOffset(0, top), size = UDim2.new(1, 0, 1, -top - 24), dense = true,
			icon = function(row) return row.path ~= nil and (row.isDir and "Folder" or row.name:lower():match("%.lua[u]?$") and "ModuleScript" or "Document") or nil end,
			indent = function(row) return row.depth or 0 end,
			chevron = function(row) if row.isDir then return view.expanded[row.path] and "open" or "closed" end end,
			onToggle = toggle,
			onSelect = function(row)
				if row.more then view.pages[row.more].limit = view.pages[row.more].limit + 200; refresh(); return end
				if row.path == nil then return end
				view.selected = row.path
				if row.isDir then toggle(row) else common.message(handle.open(row.path)) end
			end,
			onDoubleClick = function(row) if row.path and not row.isDir then common.message(handle.open(row.path)) end end,
			onContextMenu = function(row, _, button)
				if not row.path then return end
				view.selected = row.path; refresh()
				local choices = { { label = "Copy path", value = "path" } }
				if row.isDir then choices[#choices + 1] = { label = "New file here", value = "new" }; choices[#choices + 1] = { label = "Refresh folder", value = "refresh" }
				else choices[#choices + 1] = { label = "Open file", value = "open" } end
				common.menu(button, row.name, choices, function(action)
					if action == "path" then common.copy(files.root .. "/" .. row.path)
					elseif action == "new" then handle.create(false)
					elseif action == "refresh" then load(row.path); refresh()
					else common.message(handle.open(row.path)) end
				end)
			end })
		refresh = function()
			if not handle.alive or not handle.visible then return end
			local rows, needle = {}, (view.query or ""):lower()
			local function append(row, depth)
				if #rows >= 4000 or depth > 24 then return end
				local matches = needle == "" or row.isDir or row.name:lower():find(needle, 1, true)
				if matches then
					local item = util.copy(row); item.label, item.depth, item.selected = item.name, depth, item.path == view.selected; rows[#rows + 1] = item
				end
				if row.isDir and view.expanded[row.path] then
					local branch = view.pages[row.path] or load(row.path)
					if branch.error then rows[#rows + 1] = { id = "error:" .. row.path, label = branch.error, depth = depth + 1, color = theme.color.textSecondary }
					else
						for index = 1, math.min(#branch.items, branch.limit) do append(branch.items[index], depth + 1) end
						if #branch.items == 0 then rows[#rows + 1] = { id = "empty:" .. row.path, label = "Empty folder", depth = depth + 1, color = theme.color.textTertiary } end
						if #branch.items > branch.limit then rows[#rows + 1] = { id = "more:" .. row.path, more = row.path, label = "Load more files…", depth = depth + 1 } end
					end
				end
			end
			append({ id = "file:", path = "", name = files.root, isDir = true }, 0)
			list.set(rows, true)
			local binding = files.binding(store.activeId())
			hint.Text = binding and (files.root .. "/" .. binding.path .. (files.dirty(store.activeId()) and " · unsaved changes" or "")) or "Click folders to expand · click files to open"
		end
		local off = store.changed:connect(function(event) if event.kind ~= "source" then refresh() end end)
		function handle.setVisible(visible)
			if handle.visible == visible then return end
			handle.visible, list.visible = visible, visible
			if visible then view.pages = {}; refresh() else view.y = list.root.CanvasPosition.Y end
		end
		function handle.destroy() handle.alive = false; view.y = list.root.CanvasPosition.Y; off(); root:Destroy() end
		handle.list, handle.refresh = list, refresh
		refresh(); list.root.CanvasPosition = Vector2.new(0, view.y or 0)
		return handle
	end
	return M
end
