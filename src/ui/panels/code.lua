-- Code owns its navigation and panes. Documents and live services outlive views.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local tabs = env.require("ui/code/tabs")
	local forms = env.require("ui/code/forms")
	local overlay = env.require("ui/overlay")
	local store = env.require("runtime/code_store")
	local files = env.require("runtime/code_files")
	local runner = env.require("tools/code_runner")
	local capture = env.require("runtime/remote_capture")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local M = {}
	local destinations = {
		{ id = "Editor", label = "Editor" }, { id = "Files", label = "Files" },
		{ id = "Explorer", label = "Explorer" }, { id = "Remotes", label = "Remote spy" },
		{ id = "Output", label = "Output" }, { id = "History", label = "History" },
		{ id = "Library", label = "Library" }, { id = "Game changes", label = "Game changes" },
	}
	function M.new(parent)
		store.init()
		local root = P.frame(parent, { name = "CodeWorkspace", size = UDim2.fromScale(1, 1), clip = true })
		local panel = { root = root, alive = true, visible = true }
		local views, containers, constructing, layingOut = {}, {}, {}, false
		local navigate, layout, sync
		local navigation = tabs.new(root, { name = "CodeDestinations", size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(id) navigate(id) end })
		local body = P.frame(root, { name = "WorkspaceContent", clip = true })
		local status = P.text(root, { name = "CodeStatus", text = "", role = "caption", truncate = true, color = theme.color.textSecondary })
		local statusRule = P.frame(root, { name = "CodeStatusRule", size = UDim2.new(1, 0, 0, 1), bg = theme.color.borderSubtle })
		local filePath = P.text(root, { name = "CodeFilePath", text = "", role = "caption", color = theme.color.textSecondary, truncate = true })
		local actionBar = common.toolbar(root, { name = "EditorActions", gap = 4, padding = 4 })
		local documentTabs, runButton, stopButton, moreButton
		local function editor() return views.Editor end
		local function newDocument()
			local doc, why = store.create("Untitled " .. (#store.list() + 1) .. ".lua", "", { select = true })
			if common.message(doc, why) then store.workspace.sourceId = nil; navigate("Editor"); if editor() then editor().gotoLine(1) end end
		end
		local function namedVersion()
			local doc = store.active(); if not doc then return end
			forms.form("Save source version", { { key = "name", label = "Version name", required = true, default = "Saved version" } }, function(data) return store.saveVersion(doc.id, data.name) end)
		end
		local function save(saveAs)
			if store.workspace.sourceId then common.message(nil, "Extract a selection before saving an editable copy."); return end
			env.require("ui/code/files").saveDocument(store.active(), saveAs)
		end
		local function find()
			navigate("Editor")
			if editor() and editor().openFind then editor().openFind(); return end
			forms.form("Find in script", { { key = "query", label = "Exact text", required = true } }, function(data)
				clock.delay(0, function() if editor() then common.message(editor().find(data.query)) end end); return true
			end, { key = "code-find", submit = "Find" })
		end
		local function run()
			if store.workspace.sourceId then common.message(nil, "Extract a selection into an editable script before running."); return end
			local id, why = runner.start(store.activeId())
			if common.message(id, why) then
				store.workspace.outputVisible = true
				if root.AbsoluteSize.X < 620 then navigate("Output") else layout(); sync() end
			end
		end
		local function more(button)
			local options = {
				{ label = "Open workspace files", value = "file" }, { label = "Save file · Ctrl+S", value = "save" },
				{ label = "Save file as…", value = "saveAs" }, { label = "Save named version", value = "version" },
				{ label = "Rename script", value = "rename" }, { label = "Close script", value = "close" },
				{ label = "Find · Ctrl+F", value = "find" }, { label = "Go to line…", value = "line" },
				{ label = "Indent", value = "indent" }, { label = "Outdent", value = "outdent" },
				{ label = "Undo source", value = "undo" }, { label = "Redo source", value = "redo" },
				{ label = "Copy source", value = "copy" }, { label = "Save as action…", value = "action" },
				{ label = store.workspace.filesVisible == false and "Show files pane" or "Hide files pane", value = "filesPane" },
				{ label = store.workspace.outputVisible and "Hide output pane" or "Show output pane", value = "outputPane" },
				{ label = "Retry workspace autosave", value = "workspaceSave" }, { label = "Delete script…", value = "delete" },
			}
			common.menu(button or moreButton, "Editor actions", options, function(action)
				local doc = store.active()
				if action == "file" then navigate("Files")
				elseif action == "filesPane" then store.workspace.filesVisible = store.workspace.filesVisible == false; layout()
				elseif action == "outputPane" then store.workspace.outputVisible = not store.workspace.outputVisible; layout()
				elseif action == "workspaceSave" then local ok, why = store.saveNow(); if common.message(ok, why) then overlay.toast("Workspace saved", "good") end
				elseif not doc then common.message(nil, "Open or create a script first.")
				elseif action == "save" or action == "saveAs" then save(action == "saveAs")
				elseif action == "version" then namedVersion()
				elseif action == "rename" then forms.form("Rename script", { { key = "name", label = "Name", required = true, default = doc.name } }, function(data) return store.rename(doc.id, data.name) end)
				elseif action == "close" then common.message(store.close(doc.id))
				elseif action == "delete" then overlay.confirm({ title = "Delete " .. doc.name .. "?", description = "This removes the library draft and its history. Workspace files stay on disk.", danger = true, confirmText = "Delete", onConfirm = function() common.message(store.delete(doc.id)) end })
				elseif action == "find" then find()
				elseif action == "line" then forms.form("Go to line", { { key = "line", label = "Line number", type = "number", min = 1, required = true } }, function(data) clock.delay(0, function() if panel.alive and editor() then editor().gotoLine(data.line) end end); return true end)
				elseif action == "indent" or action == "outdent" then if editor() then editor().indent(action == "outdent") end
				elseif action == "undo" then common.message(store.undoSource(doc.id))
				elseif action == "redo" then common.message(store.redoSource(doc.id))
				elseif action == "action" then env.require("ui/code/library").saveAction(doc)
				elseif action == "copy" then common.copy(doc.source) end
			end)
		end
		documentTabs = tabs.new(root, { name = "OpenDocumentTabs", position = UDim2.fromOffset(0, common.barHeight()),
			onSelect = function(id)
				if id == "new" then newDocument(); return end
				store.workspace.sourceId = nil; common.message(store.select(id)); navigate("Editor")
			end,
			onClose = function(id) if id ~= "new" then common.message(store.close(id)); sync() end end })
		runButton = actionBar.add("Run", run, { variant = "primary", name = "RunCode", tight = true, minWidth = 52 })
		actionBar.add("Save", function() save(false) end, { name = "SaveCodeFile", tight = true, minWidth = 56 })
		stopButton = actionBar.add("", function() runner.stop() end, { icon = "square", iconOnly = true, name = "StopCode" })
		stopButton.instance.Visible = false
		moreButton = actionBar.add("", more, { icon = "ellipsis", iconOnly = true, name = "CodeActions" })
		local function getView(id)
			if views[id] then return views[id] end
			if constructing[id] then return nil end
			constructing[id] = true
			local host = P.frame(body, { name = id, size = UDim2.fromScale(1, 1), clip = true }); containers[id] = host
			if id == "Editor" then views[id] = env.require("ui/code/editor").new(host, { onStatus = function() if sync then sync() end end })
			elseif id == "Large source" then views[id] = env.require("ui/code/large_source").new(host, navigate)
			elseif id == "Output" then views[id] = env.require("ui/code/output").new(host)
			elseif id == "History" or id == "Game changes" then views[id] = env.require("ui/code/history").new(host, id == "Game changes", navigate)
			else views[id] = env.require("ui/code/" .. id:lower()).new(host, navigate) end
			constructing[id] = nil; return views[id]
		end
		local fileDivider = env.require("ui/code/splitter").new(body, function(position)
			store.workspace.filePaneWidth = math.max(180, math.min(root.AbsoluteSize.X * 0.45, position.X - body.AbsolutePosition.X)); layout()
		end)
		local outputDivider = env.require("ui/code/splitter").new(body, function(position)
			store.workspace.outputHeight = math.max(100, math.min(body.AbsoluteSize.Y * 0.65, body.AbsolutePosition.Y + body.AbsoluteSize.Y - position.Y)); layout()
		end, true)
		layout = function()
			if not panel.alive or layingOut then return end; layingOut = true
			local id = store.workspace.destination
			local editing = id == "Editor"
			local barHeight = common.barHeight()
			local actionsWidth = actionBar.width()
			documentTabs.root.Visible, actionBar.root.Visible, filePath.Visible = editing, editing, editing
			documentTabs.root.Size = UDim2.new(1, -actionsWidth, 0, barHeight)
			actionBar.root.Position, actionBar.root.Size = UDim2.new(1, -actionsWidth, 0, barHeight), UDim2.fromOffset(actionsWidth, barHeight)
			filePath.Position, filePath.Size = UDim2.fromOffset(12, barHeight * 2), UDim2.new(1, -24, 0, 24)
			local top = editing and barHeight * 2 + 24 or barHeight
			body.Position, body.Size = UDim2.fromOffset(0, top), UDim2.new(1, 0, 1, -top - theme.size.codeStatus)
			status.Position, status.Size = UDim2.new(0, 10, 1, -theme.size.codeStatus), UDim2.new(1, -20, 0, theme.size.codeStatus)
			statusRule.Position = UDim2.new(0, 0, 1, -theme.size.codeStatus)
			local actual = editing and store.workspace.sourceId and "Large source" or id
			local dockFiles = editing and root.AbsoluteSize.X >= 640 and store.workspace.filesVisible ~= false
			local dockOutput = editing and root.AbsoluteSize.X >= 620 and body.AbsoluteSize.Y >= 250 and store.workspace.outputVisible == true
			getView(actual); if dockFiles then getView("Files") end; if dockOutput then getView("Output") end
			for key, view in pairs(views) do
				local visible = key == actual or (dockFiles and key == "Files") or (dockOutput and key == "Output")
				containers[key].Visible = visible
				containers[key].Position, containers[key].Size = UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1)
				if view.setVisible then view.setVisible(visible and panel.visible) else view.visible = visible and panel.visible end
			end
			local inset = 0
			fileDivider.root.Visible, outputDivider.root.Visible = dockFiles and panel.visible, dockOutput and panel.visible
			if dockFiles then
				local width = math.max(180, math.min(root.AbsoluteSize.X * 0.4, store.workspace.filePaneWidth or 230))
				containers.Files.Size = UDim2.new(0, width, 1, 0); inset = width + 6
				fileDivider.root.Position, fileDivider.root.Size = UDim2.fromOffset(width, 0), UDim2.new(0, 6, 1, 0)
			end
			if editing then
				containers[actual].Position, containers[actual].Size = UDim2.fromOffset(inset, 0), UDim2.new(1, -inset, 1, 0)
				if dockOutput then
					local height = math.max(100, math.min(body.AbsoluteSize.Y * 0.55, store.workspace.outputHeight or 160))
					containers[actual].Size = UDim2.new(1, -inset, 1, -height - 6)
					containers.Output.Position, containers.Output.Size = UDim2.new(0, inset, 1, -height), UDim2.new(1, -inset, 0, height)
					outputDivider.root.Position, outputDivider.root.Size = UDim2.new(0, inset, 1, -height - 6), UDim2.new(1, -inset, 0, 6)
				end
			end
			layingOut = false
		end
		sync = function()
			if not panel.alive then return end
			local doc = store.active()
			navigation.set(destinations, store.workspace.destination)
			local documents = {}
			for _, id in ipairs(store.openIds()) do
				local item = store.resolve(id)
				if item then documents[#documents + 1] = { id = id, label = item.name .. (files.dirty(id) and " •" or "") } end
			end
			documents[#documents + 1] = { id = "new", label = "+", closable = false }
			documentTabs.set(documents, store.activeId())
			runButton.setEnabled(caps.exec and doc ~= nil and not store.workspace.sourceId and not runner.busy())
			stopButton.setEnabled(runner.busy())
			local stopping = runner.busy()
			if stopButton.instance.Visible ~= stopping then stopButton.instance.Visible = stopping; layout() end
			local binding = doc and files.binding(doc.id)
			filePath.Text = store.workspace.sourceId and "Read-only source · extract a selection to edit" or binding and (files.root .. " / " .. binding.path:gsub("/", " / ")) or doc and (doc.provenance or ("Workspace draft / " .. doc.name)) or "Open a file or create a script with +"
			local states = { saved = "Workspace saved", dirty = "Autosave pending", saving = "Saving workspace…", session_only = "Session only", failed = "Autosave failed", protected = "Workspace protected" }
			local text = states[store.storage.state] or store.storage.state
			if store.workspace.destination == "Editor" and doc then
				local line, column = 1, 1; if editor() then line, column = editor().position() end
				text = "Ln " .. line .. ", Col " .. column .. "   ·   " .. (files.dirty(doc.id) and "File has unsaved changes" or text)
				if not caps.exec then text = text .. "   ·   Run unavailable" elseif editor() then text = text .. "   ·   " .. editor().syntax end
			elseif store.workspace.destination == "Remotes" then
				local state = capture.state(); text = state.retained .. " calls retained   ·   " .. state.status .. (#capture.rules > 0 and ("   ·   " .. #capture.rules .. " traffic rules") or "")
			end
			status.Text = text
		end
		navigate = function(id)
			local known = false; for _, item in ipairs(destinations) do if item.id == id then known = true; break end end
			if not known then return end
			store.preference("destination", id)
			if views["Large source"] and (not store.workspace.sourceId or views["Large source"].sourceId ~= store.workspace.sourceId) then
				views["Large source"].destroy(); containers["Large source"]:Destroy(); views["Large source"], containers["Large source"] = nil, nil
			end
			layout(); sync()
		end
		local offStore = store.changed:connect(function(event) sync(); if event.kind == "large_source" or event.kind == "preference" then layout() end end)
		local offStorage = store.storageChanged:connect(sync)
		local offRun = runner.changed:connect(function(event) sync(); if event.kind == "rejected" then common.message(nil, event.text) end end)
		local offCapture = capture.changed:connect(sync)
		local function held(name) local ok, result = pcall(function() return env.uis:IsKeyDown(Enum.KeyCode[name]) end); return ok and result end
		local input = env.uis.InputBegan:Connect(function(key, processed)
			if not panel.visible or not panel.alive or not root.Visible then return end
			local app = env.require("ui/app"); if app.panel ~= "code" or (app.window and not app.window.visible) or #overlay.open > 0 then return end
			local focused = env.uis:GetFocusedTextBox()
			if focused and (not editor() or focused ~= editor().box) then return end
			local modifier = held("LeftControl") or held("RightControl") or held("LeftMeta") or held("RightMeta")
			if modifier then
				if key.KeyCode == Enum.KeyCode.Return and store.workspace.destination == "Editor" then run()
				elseif key.KeyCode == Enum.KeyCode.S then save(held("LeftShift") or held("RightShift"))
				elseif key.KeyCode == Enum.KeyCode.F then find()
				elseif key.KeyCode == Enum.KeyCode.O or key.KeyCode == Enum.KeyCode.P then navigate("Files")
				elseif key.KeyCode == Enum.KeyCode.N then newDocument()
				elseif key.KeyCode == Enum.KeyCode.Z and not focused then if held("LeftShift") or held("RightShift") then common.message(store.redoSource()) else common.message(store.undoSource()) end end
			elseif focused and key.KeyCode == Enum.KeyCode.Tab then editor().indent(held("LeftShift") or held("RightShift"))
			elseif not focused and not processed then
				local view = views[store.workspace.destination]
				if view and view.list then
					if key.KeyCode == Enum.KeyCode.Up or key.KeyCode == Enum.KeyCode.DPadUp then view.list.move(-1)
					elseif key.KeyCode == Enum.KeyCode.Down or key.KeyCode == Enum.KeyCode.DPadDown then view.list.move(1)
					elseif key.KeyCode == Enum.KeyCode.Left and view.list.toggle then view.list.toggle(false)
					elseif key.KeyCode == Enum.KeyCode.Right and view.list.toggle then view.list.toggle(true)
					elseif key.KeyCode == Enum.KeyCode.Return then view.list.activate() end
				end
			end
		end)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		function panel.setVisible(visible) panel.visible = visible; layout(); sync() end
		function panel.destroy()
			if not panel.alive then return end; panel.alive = false
			input:Disconnect(); offStore(); offStorage(); offRun(); offCapture(); fileDivider.destroy(); outputDivider.destroy()
			for _, view in pairs(views) do if view.destroy then view.destroy() end end
			store.saveNow(); root:Destroy()
		end
		panel.navigate, panel.views = navigate, views
		layout(); sync(); return panel
	end
	return M
end
