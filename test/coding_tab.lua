-- Coding-tab regressions use synthetic files, objects, traffic and GUI events.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Coding tab interactions")
local case, check = suite.case, suite.check
local ui = F.ui
local function activate(list, id)
	for index, item in ipairs(list.items) do
		if item.id == id or item.instanceId == id then list.selected = index; list.activate(); return item end
	end
	error("Missing list item: " .. tostring(id))
end
local function rowFor(list, id)
	list.focusKey(id)
	for _, row in ipairs(list.rows) do if row.item and (row.item.id == id or row.item.instanceId == id) then return row end end
	error("Missing visible row: " .. tostring(id))
end
local function tab(h, root, label)
	for _, node in ipairs(root:GetDescendants()) do if node.Name == "TabButton" and h.textOf(node) == label then h.click(node); return end end
	error("Missing tab: " .. label)
end

case("live refresh preserves clicks; recycled rows cannot retarget a press", function()
	local f = ui(420, 240); local selected, doubles, toggles = {}, 0, 0
	local list = f.env.require("ui/code/common").virtualList(f.host, {
		onSelect = function(item) selected[#selected + 1] = item.id end,
		onDoubleClick = function() doubles = doubles + 1 end,
		chevron = function() return "closed" end, onToggle = function() toggles = toggles + 1 end,
	})
	list.set({ { id = "a", label = "Alpha" } })
	local row = list.rows[1]
	row.button.instance.InputBegan:Fire({ UserInputType = f.h.sandbox.Enum.UserInputType.MouseButton1 })
	list.set({ { id = "a", label = "Alpha updated" } }, true)
	row.button.instance.Activated:Fire()
	check("a refresh between down/up still selects the same row", #selected == 1 and selected[1] == "a")
	check("first click is never mistaken for a double click", doubles == 0)
	row.button.instance.Activated:Fire(); check("second click activates the double-click action", doubles == 1)
	row.button.instance.InputBegan:Fire({ UserInputType = f.h.sandbox.Enum.UserInputType.MouseButton1 })
	list.set({ { id = "b", label = "Beta", selected = true } }, true)
	row.button.instance.Activated:Fire(); check("recycling during a press never selects a different object", #selected == 1)
	row.button.instance.MouseEnter:Fire(); row.button.instance.MouseLeave:Fire()
	check("selection remains visible after hover leaves", row.button.instance.BackgroundTransparency == 0 and row.mark.Visible)
	row.chevronSlot.Activated:Fire()
	check("the expander is a separate hit target", toggles == 1 and #selected == 1 and row.chevronSlot.Parent == list.root)
	f.healthy(); list.root:Destroy(); f.close()
end)

case("native editing keeps its caret, raw selection and per-file position", function()
	local f = ui(680, 460); local store = f.env.require("runtime/code_store")
	local doc = store.active(); assert(store.update(doc.id, "local alpha = 1\nprint(alpha)"))
	local editor = f.env.require("ui/code/editor").new(f.host)
	local box = editor.box; box:CaptureFocus(); box.CursorPosition = 7
	check("focused source keeps syntax and a visible caret", f.h.byName("SourceCaret", editor.root).Visible and f.h.byName("SyntaxLine", editor.root).Visible and f.h.byName("SyntaxLine", editor.root).Text:find('<font color=', 1, true) and box.Active and box.MultiLine and not box.RichText)
	editor.indent(false)
	check("Tab at a caret inserts at the caret", box.Text == "local \talpha = 1\nprint(alpha)" and box.CursorPosition == 8)
	box.Text = "local alpha = 1\nprint(alpha)"; f.h.sched.advance(0.1)
	box.CursorPosition = 1; assert(editor.find("alpha"))
	check("Find selects exact source bytes", box.Text:sub(box.SelectionStart, box.CursorPosition - 1) == "alpha")
	check("native selection has a visible highlight", f.h.byName("SourceSelection", editor.root).Visible)
	local cursor, selection = box.CursorPosition, box.SelectionStart
	local other = assert(store.create("Other.lua", "return false", { select = true }))
	assert(store.select(doc.id))
	check("switching documents restores the selection", box.CursorPosition == cursor and box.SelectionStart == selection and box.Text == doc.source)
	box.CursorPosition, box.SelectionStart = 1, -1
	local long = string.rep("-- line\n", 1999) .. "return 'end'"
	box.Text = long; f.h.sched.advance(0.1); editor.gotoLine(1900)
	check("long-file navigation reveals the caret and syntax", box.CursorPosition == #("-- line\n") * 1899 + 1 and editor.scroll.CanvasPosition.Y > 0 and f.h.byName("SourceCaret", editor.root).Visible and f.h.byName("SyntaxLine", editor.root).Visible)
	editor.openFind(); check("Find has an inline text field", f.h.byName("FindSourceText", editor.root) ~= nil)
	editor.closeFind(); check("closing Find restores editor focus", f.h.services.UserInputService:GetFocusedTextBox() == box)
	editor.setVisible(false); assert(store.select(other.id)); editor.setVisible(true)
	check("hidden views keep the active source", box.Text == "return false")
	f.healthy(); editor.destroy(); f.close()
end)

case("workspace folders expand and file bindings preserve drafts and disk conflicts", function()
	local f = ui(360, 500); local fs, store = f.env.require("runtime/fsx"), f.env.require("runtime/code_store")
	assert(fs.write("files/scripts/a.lua", "return 1")); assert(fs.write("files/other/a.lua", "return 2")); assert(fs.write("skills/help.md", "fixture"))
	local files = f.env.require("runtime/code_files")
	local roots = assert(files.children("")); local seen = {}
	for _, item in ipairs(roots) do seen[item.path] = item; check("root listing contains only immediate children", not item.path:find("/", 1, true)) end
	check("UAI files and skills are real directories", seen.files and seen.files.isDir and seen.skills and seen.skills.isDir)
	local destination
	local browser = f.env.require("ui/code/files").new(f.host, function(id) destination = id end)
	activate(browser.list, "file:files"); activate(browser.list, "file:files/scripts"); activate(browser.list, "file:files/scripts/a.lua")
	local doc = store.active()
	check("clicking a file opens exact source in Editor", destination == "Editor" and doc.source == "return 1")
	assert(store.update(doc.id, "return 'draft'")); assert(files.open("UAI/files/scripts/a.lua"))
	check("reopening keeps the edited document", store.activeId() == doc.id and store.active().source == "return 'draft'" and files.dirty(doc.id))
	assert(fs.write("files/scripts/a.lua", "return 'external'"))
	local saved, why = files.save(doc.id)
	check("disk conflicts preserve both versions", not saved and why:find("changed on disk", 1, true) and fs.read("files/scripts/a.lua") == "return 'external'" and doc.source == "return 'draft'")
	assert(files.save(doc.id, "files/copy.lua"))
	check("Save as verifies the new file", fs.read("files/copy.lua") == doc.source and not files.dirty(doc.id))
	local second = assert(files.open("files/other/a.lua"))
	check("identical basenames in different folders stay distinct", second.documentId ~= doc.id and store.active().source == "return 2")
	check("path traversal cannot leave UAI", not files.open("../outside.lua"))
	assert(fs.write("files/large.lua", string.rep("-- line\n", 40000)))
	check("large files open in the bounded reader", assert(files.open("files/large.lua")).readOnly == true)
	f.healthy(); browser.destroy(); f.close()
end)

case("Explorer expands parents, clears search and targets the right-clicked object", function()
	local f = ui(390, 560); local h = f.h
	local parent = h.Instance.new("Folder", h.workspace); parent.Name = "ParentFixture"
	local child = h.Instance.new("Part", parent); child.Name = "NestedFixture"
	local refs, model = f.env.require("runtime/instance_refs"), f.env.require("runtime/explorer")
	local explorer = f.env.require("ui/code/explorer").new(f.host, function() end)
	activate(explorer.list, refs.id(h.workspace)); activate(explorer.list, refs.id(parent))
	local childRow = rowFor(explorer.list, refs.id(child))
	check("single-clicking a parent reveals children in the hierarchy", childRow ~= nil and h.byName("Hierarchy", explorer.root).Visible)
	explorer.search("NestedFixture"); h.sched.advance(0.4)
	check("name search finds descendants", model.view.query and #model.view.query.items == 1)
	explorer.search(""); h.sched.advance(0.2)
	check("clearing search restores the expandable hierarchy", model.view.query == nil and rowFor(explorer.list, refs.id(parent)) ~= nil)
	childRow = rowFor(explorer.list, refs.id(child)); childRow.button.instance.MouseButton2Click:Fire()
	check("context actions target the clicked object", model.primaryId == refs.id(child))
	activate(explorer.list, refs.id(child))
	check("a compact window exposes the selected object's inspector", h.byName("Inspector", explorer.root).Visible and not h.byName("Hierarchy", explorer.root).Visible)
	local modelParent = h.Instance.new("Folder", h.workspace); modelParent.Name = "OtherBranch"
	local distant = h.Instance.new("Part", modelParent); distant.Name = "ExternalSelection"
	assert(model.select({ refs.id(distant) })); h.sched.advance(0.2)
	check("external selections reveal their parent chain", model.expanded[refs.id(modelParent)] and rowFor(explorer.list, refs.id(distant)) ~= nil)
	f.healthy(); explorer.destroy(); f.close()
end)

case("one-click capture has a useful scope and observes more than 128 remotes", function()
	local f = ui(800, 650); local caps = f.env.require("runtime/caps")
	caps.fn.hookmetamethod, caps.fn.hookfunction = nil, nil
	local last
	for i = 1, 300 do last = f.h.Instance.new("RemoteEvent", f.h.workspace); last.Name = "Event" .. i end
	local capture, records = f.env.require("runtime/remote_capture"), f.env.require("runtime/remote_store")
	local view = f.env.require("ui/code/remotes").new(f.host, function() end)
	view.start(); f.h.sched.advance(0.5)
	local state = capture.state()
	check("Start uses the game scope and available incoming capture", state.status == "running" and state.mode == "incoming" and state.rootId == f.env.require("runtime/instance_refs").id(f.h.game))
	check("all 300 incoming events are subscribed", state.monitored == 300 and state.omitted == 0)
	last.OnClientEvent:Fire(false, nil, 7, nil); f.h.sched.advance(0.2)
	local record = assert(records.get(assert(records.latest()).items[1].id))
	check("incoming calls keep exact nil arity", record.arguments.count == 4 and record.arguments.slots[1].value == false)
	f.h.click(f.h.byName("StartRemoteCapture", view.root)); check("Pause is direct and keeps the session", capture.status == "paused")
	f.h.click(f.h.byName("StartRemoteCapture", view.root)); check("Resume is direct", capture.status == "running")
	f.h.click(f.h.byName("StopRemoteCapture", view.root)); check("Stop releases every subscription", capture.status == "stopped" and capture.state().monitored == 0)
	f.healthy(); view.destroy(); f.close()
end)

case("incoming startup does not miss a remote created while scanning", function()
	local f = F.new(); local scan = f.env.require("runtime/instance_scan")
	local late
	scan.descendants = function()
		late = f.h.Instance.new("RemoteEvent", f.h.workspace); late.Name = "AddedDuringScan"
		f.h.workspace.DescendantAdded:Fire(late)
		return { complete = true, scanned = 0 }
	end
	local capture = f.env.require("runtime/remote_capture")
	assert(capture.start({ mode = "incoming", rootId = f.env.require("runtime/instance_refs").id(f.h.workspace), persistent = true }))
	late.OnClientEvent:Fire("late")
	check("a remote omitted from the initial snapshot is still observed", capture.state().monitored == 1 and capture.state().retained == 1)
	f.healthy(); f.close()
end)

case("latest filters find quiet remotes and results preserve an edited replay draft", function()
	local f = ui(900, 680); local env = f.env
	local records, values, capture = env.require("runtime/remote_store"), env.require("runtime/values"), env.require("runtime/remote_capture")
	local remote = f.h.Instance.new("RemoteFunction", f.h.workspace); remote.Name = "QuietRemote"
	local refs = env.require("runtime/instance_refs")
	local token = records.begin({ name = remote.Name, remoteId = refs.id(remote), className = "RemoteFunction", method = "InvokeServer", direction = "outgoing", origin = "uai", sessionId = "fixture", outcome = "pending" }, values.pack("original"))
	for i = 1, 160 do records.begin({ name = "BusyRemote", method = "FireServer", direction = "outgoing", origin = "game", sessionId = "fixture", outcome = "forwarded" }, values.pack(i)) end
	local page = assert(records.latest({ name = "QuietRemote" }))
	check("a quiet match survives more than 100 unrelated calls", #page.items == 1 and page.items[1].id == token.id)
	local newest = assert(records.latest({ name = "BusyRemote" })); local older = assert(records.latest({ name = "BusyRemote", before_sequence = newest.first }))
	check("older pages are ordered and do not overlap", #newest.items == 100 and #older.items == 60 and older.last < newest.first)
	capture.view.filter = "QuietRemote"; env.require("runtime/code_store").workspace.remoteFilter = "QuietRemote"
	local view = env.require("ui/code/remotes").new(f.host, function() end)
	activate(view.list, token.id)
	tab(f.h, f.h.byName("RemoteDetailTabs", view.root), "Replay draft")
	local draft = capture.view.argumentDraft; draft.slots[1] = values.node("edited")
	records.finish(token, "returned", values.pack(false, nil, 9, nil)); f.h.sched.advance(0.3)
	check("a live outcome updates without replacing replay edits", capture.view.record.outcome == "returned" and capture.view.argumentDraft == draft and draft.slots[1].value == "edited")
	tab(f.h, f.h.byName("RemoteDetailTabs", view.root), "Code")
	local preview = f.h.byName("PreviewText", view.root):FindFirstChildWhichIsA("TextBox")
	check("generated code uses a selectable native preview", preview ~= nil and not preview.TextEditable and preview.TextTransparency == 0)
	f.healthy(); view.destroy(); f.close()
end)

case("the Code panel exposes files and document tabs at desktop and narrow sizes", function()
	local f = ui(960, 660)
	local panel = f.env.require("ui/panels/code").new(f.host)
	check("desktop editor has a workspace file pane", panel.views.Files ~= nil and panel.views.Files.root.Parent.Visible)
	check("destinations and open documents are visible UI tabs", f.h.byName("CodeDestinations", panel.root) ~= nil and f.h.byName("OpenDocumentTabs", panel.root) ~= nil)
	local run, save, stop = f.h.byName("RunCode", panel.root), f.h.byName("SaveCodeFile", panel.root), f.h.byName("StopCode", panel.root)
	check("Run and Save are adjacent without a dormant Stop slot", not stop.Visible and save.AbsolutePosition.X - run.AbsolutePosition.X - run.AbsoluteSize.X <= 5)
	local store = f.env.require("runtime/code_store"); local source = "-- preserved\nreturn 42"; assert(store.update(store.activeId(), source))
	for _, size in ipairs({ { 320, 500 }, { 640, 480 }, { 960, 660 } }) do
		f.host.Size = f.h.sandbox.UDim2.fromOffset(size[1], size[2]); panel.root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
		for _, destination in ipairs({ "Files", "Explorer", "Remotes", "History", "Game changes", "Editor" }) do panel.navigate(destination); f.h.sched.advance(0.15) end
		check("source survives resize at " .. size[1], store.active().source == source)
		local body = f.h.byName("WorkspaceContent", panel.root)
		check("body stays positive and inside the Code panel at " .. size[1], body.AbsoluteSize.Y > 0 and body.AbsoluteSize.X <= panel.root.AbsoluteSize.X)
	end
	f.healthy(); panel.destroy(); f.close()
end)

case("history reviews versions inline and keeps proposal conflict checks", function()
	local f = ui(960, 660); local h, store = f.h, f.env.require("runtime/code_store")
	local doc = store.active(); assert(store.update(doc.id, "local speed = 10\nreturn speed"))
	local saved = assert(store.saveVersion(doc.id, "Stable movement"))
	assert(store.update(doc.id, "local speed = 20\nreturn speed + 1"))
	local current = doc.source
	local history = f.env.require("ui/code/history").new(f.host, false)
	activate(history.list, saved.id)
	check("selecting a version opens an inline diff without changing source", h.byName("InlineSourceDiff", history.root) ~= nil and doc.source == current and #f.env.require("ui/overlay").open == 0)
	tab(h, h.byName("HistoryReviewTabs", history.root), "Saved source")
	check("saved source is copyable in a native preview", h.byName("PreviewText", history.root):FindFirstChildWhichIsA("TextBox").Text == saved.source)
	h.click(h.byName("RestoreSourceVersion", history.root))
	check("restore applies the reviewed version and keeps source Undo", doc.source == saved.source and assert(store.undoSource(doc.id)).source == current)
	local proposal = assert(store.propose(doc.id, doc.revision, "return 'proposal'", "Improve movement"))
	assert(store.update(doc.id, "return 'newer edit'"))
	activate(history.list, proposal.id); h.click(h.byName("RestoreSourceVersion", history.root))
	check("a stale proposal cannot overwrite a newer edit", doc.source == "return 'newer edit'" and #store.proposals(doc.id) == 1 and h.byName("HistoryReviewNotice", history.root).Visible)
	h.click(h.byName("DiscardSourceProposal", history.root))
	check("discard removes only the selected proposal", #store.proposals(doc.id) == 0 and doc.source == "return 'newer edit'")
	local fresh = assert(store.propose(doc.id, doc.revision, "return 'approved change'", "Current proposal"))
	activate(history.list, fresh.id); h.click(h.byName("RestoreSourceVersion", history.root))
	check("a current proposal applies directly from its reviewed details", doc.source == "return 'approved change'" and #store.proposals(doc.id) == 0)
	f.host.Size = h.sandbox.UDim2.fromOffset(320, 500); history.root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	activate(history.list, saved.id)
	check("narrow history makes room for the review", h.byName("HistoryReview", history.root).Visible and not h.byName("HistoryTimeline", history.root).Visible and h.byName("HistoryReviewContent", history.root).AbsoluteSize.Y > 100)
	h.click(h.byName("BackToHistory", history.root))
	check("Back returns to the timeline", h.byName("HistoryTimeline", history.root).Visible and not h.byName("HistoryReview", history.root).Visible)
	f.healthy(); history.destroy(); f.close()
end)

case("game changes show field values and undo refuses an external edit", function()
	local f = ui(900, 660); local h, env = f.h, f.env
	local part = h.Instance.new("Part", h.workspace); part.Name, part.Transparency = "SpawnMarker", 0
	local refs, values = env.require("runtime/instance_refs"), env.require("runtime/values")
	local edits, changes = env.require("runtime/instance_edits"), env.require("runtime/changes")
	local result = edits.apply({ { instanceId = refs.id(part), kind = "property", key = "Transparency", expected = values.node(0), value = values.node(0.5) } }, { origin = "Explorer" })
	assert(result.ok); local destination
	local history = env.require("ui/code/history").new(f.host, true, function(id) destination = id end)
	activate(history.list, result.batchId)
	local before = h.byName("BeforeValue", history.root):FindFirstChild("PreviewText"):FindFirstChildWhichIsA("TextBox")
	local after = h.byName("AfterValue", history.root):FindFirstChild("PreviewText"):FindFirstChildWhichIsA("TextBox")
	check("field review shows exact before and after values inline", before.Text == "0" and after.Text == "0.5" and #history.fields.items == 1)
	part.Transparency = 0.8; h.click(h.byName("UndoGameFields", history.root))
	check("Undo reports an external conflict without overwriting it", part.Transparency == 0.8 and changes.list()[1].status == "applied" and h.byName("HistoryReviewNotice", history.root).Text:find("Transparency", 1, true))
	part.Transparency = 0.5; h.click(h.byName("UndoGameFields", history.root))
	check("Undo restores the recorded value once", part.Transparency == 0 and changes.list()[1].status == "undone")
	h.click(h.byName("RevealChangedObject", history.root))
	check("Reveal selects the changed object in Explorer", destination == "Explorer" and env.require("runtime/explorer").primaryId == refs.id(part))
	local partial = changes.record({}, "fixture", { { instanceId = refs.id(part), kind = "property", key = "Transparency", before = 0, uncertain = true, reason = "Unreadable value" } })
	activate(history.list, partial); h.click(h.byName("UndoGameFields", history.root))
	check("unknown field outcomes stay reviewable without unsafe Undo", part.Transparency == 0 and h.byName("HistoryReviewNotice", history.root).Text:find("unknown", 1, true))
	f.host.Size = h.sandbox.UDim2.fromOffset(320, 500); history.root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	check("compact game review leaves room for field rows", h.byName("ChangedFields", history.root).AbsoluteSize.Y > 50)
	f.healthy(); history.destroy(); f.close()
end)

case("deep trees scroll horizontally without losing a keyboard selection", function()
	local f = ui(320, 260)
	local list = f.env.require("ui/code/common").virtualList(f.host, { indent = function(item) return item.depth end, chevron = function() return "closed" end })
	list.set({ { id = "parent", label = "Deeply nested workspace folder", depth = 24 }, { id = "child", label = "A readable child name", depth = 25 } })
	check("deep rows have a horizontal canvas and positive labels", list.root.CanvasSize.X.Offset > list.root.AbsoluteSize.X and list.rows[2].button.label.AbsoluteSize.X > 100)
	list.root.CanvasPosition = f.h.sandbox.Vector2.new(200, 0); list.move(1)
	check("keyboard movement keeps the horizontal reading position", list.root.CanvasPosition.X == 200 and list.selectedKey == "child")
	f.healthy(); list.root:Destroy(); f.close()
end)

case("the world picker previews on hover and selects on click without stealing UI input", function()
	local f = ui(900, 650); local h = f.h; local uis = h.services.UserInputService
	local part = h.Instance.new("Part", h.workspace); part.Name = "PickFixture"
	local v3 = h.sandbox.Vector3
	h.workspace.CurrentCamera.ScreenPointToRay = function() return { Origin = v3.new(0, 0, 0), Direction = v3.new(0, 0, -1) } end
	h.workspace.Raycast = function() return { Instance = part } end
	local overUI = false
	h.services.CoreGui.GetGuiObjectsAtPosition = function() return overUI and { f.host } or {} end
	local picked, picker = nil, f.env.require("ui/code/world_picker")
	local listeners = uis.InputChanged:Count()
	assert(picker.start(function(id) picked = id end))
	uis.InputChanged:Fire({ UserInputType = h.sandbox.Enum.UserInputType.MouseMovement, Position = v3.new(800, 600, 0) }, false)
	check("hover previews without selecting", h.byName("UAI_Picker", f.env.root).Adornee == part and picked == nil)
	overUI = true; uis.InputBegan:Fire({ UserInputType = h.sandbox.Enum.UserInputType.MouseButton1, Position = v3.new(800, 600, 0) }, false)
	check("a UI click never picks through the workspace window", picked == nil)
	overUI = false; uis.InputBegan:Fire({ UserInputType = h.sandbox.Enum.UserInputType.MouseButton1, Position = v3.new(800, 600, 0) }, false)
	check("one world click selects and releases the hover listener", picked == f.env.require("runtime/instance_refs").id(part) and uis.InputChanged:Count() == listeners)
	f.healthy(); f.close()
end)

case("automatic outgoing capture falls back when the namecall hook fails", function()
	local f = F.new(); local calls, installed, observed = 0, 0, 0
	local eventCell = function() calls = calls + 1 end
	local invokeCell = function() calls = calls + 1; return false, nil, 8, nil end
	local fire = function(...) return eventCell(...) end
	local invoke = function(...) return invokeCell(...) end
	local nativeNew = f.h.Instance.new
	f.h.sandbox.Instance = { new = function(class, parent) local item = nativeNew(class, parent); if class == "RemoteFunction" then item.InvokeServer = invoke else item.FireServer = fire end; return item end }
	local caps = f.env.require("runtime/caps")
	caps.fn.getnamecallmethod = function() return "FireServer" end
	caps.fn.hookmetamethod = function() error("fixture namecall unavailable") end
	caps.fn.hookfunction = function(original, replacement)
		installed = installed + 1
		if original == fire then local prior = eventCell; eventCell = replacement; return prior end
		assert(original == invoke); local prior = invokeCell; invokeCell = replacement; return prior
	end
	local hooks = f.env.require("runtime/remote_hooks")
	local state = assert(hooks.start(function(kind) if kind == "begin" then observed = observed + 1 end end, nil, "auto"))
	check("fallback reports its actual backend and probes send no traffic", state.backend == "direct" and installed == 2 and calls == 0)
	local remote = f.h.sandbox.Instance.new("RemoteEvent", f.h.workspace); remote:FireServer("fixture")
	check("fallback observes and forwards once", observed == 1 and calls == 1)
	hooks.stop(); f.healthy(); f.close()
end)

suite.finish()
