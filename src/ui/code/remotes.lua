return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local tree = env.require("ui/code/value_tree")
	local overlay = env.require("ui/overlay")
	local capture = env.require("runtime/remote_capture")
	local records = env.require("runtime/remote_store")
	local replay = env.require("tools/remote_replay")
	local explorer = env.require("runtime/explorer")
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local store = env.require("runtime/code_store")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local caps = env.require("runtime/caps")
	local tabs = env.require("ui/code/tabs")
	local M = {}
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "NativeRemotes", size = UDim2.fromScale(1, 1), clip = true })
		local view = capture.view
		view.filter = store.workspace.remoteFilter or view.filter or ""
		view.section, view.expanded = view.section or "arguments", view.expanded or {}
		view.drafts = view.drafts or {}
		view.filters = view.filters or {}
		view.mode = view.mode or ((caps.fn.hookmetamethod and caps.fn.getnamecallmethod or caps.fn.hookfunction) and "Incoming and outgoing" or "Incoming events")
		view.scope, view.backend, view.listMode = view.scope or "Game subtree", view.backend or "auto", view.listMode or "calls"
		if view.remoteId and not view.record then view.scope = "Selected remote" end
		if view.persistent == nil then view.persistent = true end
		if view.follow == nil then view.follow = true end
		local handle = { root = root, alive = true, visible = true }
		local header = common.toolbar(root)
		local statusButton, startButton, stopButton, menuButton, refresh, refreshDetail, layout, perform
		local info = P.text(root, { name = "CaptureCoverage", text = "Capture is stopped", role = "caption", wrap = true })
		local body = P.frame(root, { name = "CaptureBody" })
		local listHost, detailHost = P.frame(body, { name = "Calls", clip = true }), P.frame(body, { name = "CallDetail", clip = true })
		local listBar, detailBar = common.toolbar(listHost), common.toolbar(detailHost)
		local list, valueView, newCalls, recordHeader, sectionTabs, listTabs, scopeButton, modeButton
		local catalogue, catalogueGeneration, catalogueBusy, movingList = nil, 0, false, false
		local selected = view.record
		local function saveDraft()
			if selected and view.argumentDraft then view.drafts[selected.id] = { graph = view.argumentDraft, at = clock.ms(), reboundId = view.reboundId } end
			local ordered = {}; for key, draft in pairs(view.drafts) do if clock.ms() - draft.at > 300000 and (not selected or key ~= selected.id) then view.drafts[key] = nil else ordered[#ordered + 1] = { key = key, at = draft.at } end end
			table.sort(ordered, function(a, b) return a.at < b.at end); for i = 1, math.max(0, #ordered - 20) do view.drafts[ordered[i].key] = nil end
		end
		local function state() return capture.state() end
		local function optionsForRecord()
			if not selected then return nil end
			if selected.offline and view.reboundId then return { remoteId = view.reboundId, method = selected.method, arguments = view.argumentDraft or selected.arguments } end
			return { recordId = selected.id, recordRevision = selected.revision, arguments = view.argumentDraft }
		end
		local modeIds = { ["UAI calls"] = "uai", ["Incoming events"] = "incoming", ["Outgoing calls"] = "outgoing", ["Incoming and outgoing"] = "combined" }
		local function start()
			local ids, rootId = {}, nil
			if view.scope == "Selected remote" then if view.remoteId then ids = { view.remoteId } end
			elseif view.scope == "Explorer selection" then ids = util.copy(explorer.selectedIds)
			elseif view.scope == "Selected subtree" then rootId = explorer.primaryId
			else rootId = refs.id(game) end
			local args = { mode = modeIds[view.mode], ids = ids, rootId = rootId, backend = view.backend, persistent = view.persistent, duration = not view.persistent and (view.duration or 60) or nil, expected_revision = capture.revision }
			common.work(function() return capture.start(args, { origin = "user", aborted = function() return not handle.alive end }) end, function()
				view.follow, view.before, view.listMode = true, nil, "calls"; if handle.alive then refresh() end
			end)
		end
		local function configure()
			local selectedIds = util.copy(explorer.selectedIds)
			local startRevision = capture.revision
			forms.form("Start capture", {
				{ key = "mode", label = "Observe", type = "choice", choices = { "Incoming and outgoing", "Outgoing calls", "Incoming events", "UAI calls" }, default = view.mode },
				{ key = "scope", label = "Scope", type = "choice", choices = { "Game subtree", "Selected remote", "Explorer selection", "Selected subtree" }, default = view.scope },
				{ key = "backend", label = "Outgoing backend", type = "choice", choices = { "auto", "namecall", "direct" }, default = view.backend },
				{ key = "lifetime", label = "Stop condition", type = "choice", choices = { "Until stopped", "30 seconds", "60 seconds", "300 seconds" }, default = view.persistent and "Until stopped" or tostring(view.duration or 60) .. " seconds" },
			}, function(data)
				local modes = { ["UAI calls"] = "uai", ["Incoming events"] = "incoming", ["Outgoing calls"] = "outgoing", ["Incoming and outgoing"] = "combined" }
				local ids, rootId = {}, nil
				if data.scope == "Selected remote" then if view.remoteId then ids = { view.remoteId } end
				elseif data.scope == "Explorer selection" then ids = selectedIds
				elseif data.scope == "Selected subtree" then rootId = selectedIds[#selectedIds]
				else rootId = refs.id(game) end
				view.mode, view.backend, view.scope, view.persistent, view.duration = data.mode, data.backend, data.scope, data.lifetime == "Until stopped", tonumber(data.lifetime:match("^%d+"))
				local result, why = capture.start({ mode = modes[data.mode], ids = ids, rootId = rootId, backend = data.backend, persistent = data.lifetime == "Until stopped", duration = tonumber(data.lifetime:match("^%d+")), expected_revision = startRevision })
				if not result then return nil, why end
				view.follow, view.before, view.listMode = true, nil, "calls"; refresh(); return true
			end, { key = "capture-start", submit = "Start", description = "Capture observes the chosen scope. Replay and traffic blocking are separate actions." })
		end
		local function review()
			local args = optionsForRecord(); if not args then return end
			local plan, why = replay.prepare(args); if not common.message(plan, why) then return end
			local modal = overlay.modal({ title = "Review replay", description = plan.method .. " · " .. plan.target.name .. " · " .. plan.arguments.count .. " arguments" })
			if not modal then return end
			forms.stopControl(modal)
			P.text(modal.content, { text = plan.target.displayPath .. "\n" .. plan.remoteId .. "\nPrepared arguments are fixed. Replay sends one call.", role = "caption", auto = "Y", wrap = true, layoutOrder = 1 })
			local host = P.frame(modal.content, { size = UDim2.new(1, 0, 0, theme.size.codeOutput * 2), layoutOrder = 2 })
			tree.new(host, { graph = plan.arguments })
			common.button(modal.footer, { text = "Cancel", size = "sm", onClick = function() modal.close() end })
			common.button(modal.footer, { text = "Replay once", size = "sm", variant = "danger", layoutOrder = 2, onClick = function()
				local runner = env.require("tools/code_runner")
				local started, err = runner.operation(plan.method .. " · " .. plan.target.name, function(ctx) return replay.run(plan.id, plan.digest, ctx) end)
				if not common.message(started, err) then return end
				modal.close(true); navigate("Output")
			end })
		end
		local function rules(button)
			local choices = {}
			for _, rule in ipairs(capture.rules) do choices[#choices + 1] = { label = "Unblock " .. rule.method .. " · " .. rule.remoteId, value = rule.id } end
			choices[#choices + 1] = { label = "Clear all traffic rules", value = "clear" }
			choices[#choices + 1] = { label = "Block selected remote…", value = "add" }
			common.menu(button or menuButton, "Traffic rules · " .. #capture.rules .. " active", choices, function(action)
				local current = state()
				local args = { revision = current.revision, sessionId = current.sessionId, ruleId = action }
				if action == "add" then
					args.remoteId = selected and selected.remoteId or view.remoteId
					local object, why = refs.resolve(args.remoteId); if not common.message(object, why) then return end
					args.method = object.ClassName == "RemoteFunction" and "InvokeServer" or "FireServer"; args.policy = args.method == "InvokeServer" and "local_error" or nil
					overlay.confirm({ title = "Block " .. object.Name .. "?", danger = true, confirmText = "Block", description = args.method == "InvokeServer" and "Calls to this exact remote will raise a local error. Stop disarms the rule." or "Outgoing events to this exact remote will be suppressed until unblocked or stopped.", onConfirm = function() common.message(capture.setRule("add", args)) end })
				else common.message(capture.setRule(action == "clear" and "clear" or "remove", args)) end
			end)
		end
		local function more(button)
			local choices = { { label = "Capture settings / Start…", value = "start" }, { label = "Capture coverage", value = "coverage" }, { label = "Traffic rules…", value = "rules" }, { label = "Export retained calls", value = "export" }, { label = "Import offline capture…", value = "import" }, { label = "Clear retained calls", value = "clear" }, { label = "Show excluded remotes", value = "excluded" }, { label = "Reset admission filters", value = "filterReset" } }
			if selected or view.remoteId then
				for _, pair in ipairs({ { "Reveal remote in Explorer", "reveal" }, { "Exclude exact remote from recording", "exclude" }, { "Restore exact remote recording", "include" }, { "Copy reference", "reference" }, { "Ask AI about this", "ask" } }) do choices[#choices + 1] = { label = pair[1], value = pair[2] } end
			end
			if selected then
				for _, pair in ipairs({ { "Edit replay arguments", "draft" }, { "Review replay…", "replay" }, { "Open generated script", "source" }, { "Copy portable script", "portable" }, { "Export portable script", "portableExport" }, { "Export this call", "exportOne" }, { "Open caller source", "caller" }, { "Refresh selected result", "refresh" }, { "Start empty argument draft", "empty" } }) do choices[#choices + 1] = { label = pair[1], value = pair[2] } end
				if selected.offline then choices[#choices + 1] = { label = "Rebind offline call to current remote…", value = "rebind" } end
			end
			common.menu(button or menuButton, "Remotes actions", choices, function(action) perform(action, button) end)
		end
		perform = function(action, button)
				local id = selected and selected.remoteId or view.remoteId
				if action == "start" then configure()
				elseif action == "coverage" then
					overlay.code({ title = "Actual capture coverage", code = capture.coverageText() })
				elseif action == "rules" then rules(button)
				elseif action == "clear" then overlay.confirm({ title = "Clear retained calls?", description = "Capture configuration and traffic rules stay active. Stop ends recording and disarms rules.", confirmText = "Clear", onConfirm = function() common.message(capture.control("clear", capture.sessionId, capture.revision)); selected, view.record, view.argumentDraft = nil, nil, nil; refreshDetail() end })
				elseif action == "export" or action == "exportOne" then common.work(function() return env.require("runtime/native_exports").captures(action == "exportOne" and { selected.id } or nil) end, function(result) common.copy(result.path); overlay.toast("Capture export verified", "good") end)
				elseif action == "import" then forms.form("Open offline capture", { { key = "path", label = "Workspace file reference", required = true } }, function(data) local count, why = env.require("runtime/native_exports").import(data.path); if not count then return nil, why end; view.follow = true; refresh(); return true end, { key = "capture-import", submit = "Open" })
				elseif action == "filterReset" then common.message(capture.setFilter({}, capture.revision))
				elseif action == "excluded" then local names = util.keys(capture.filter.exclude, true); overlay.code({ title = "Admission exclusions (traffic still passes)", code = #names > 0 and table.concat(names, "\n") or "No exclusions" })
				elseif action == "exclude" or action == "include" then
					local exclude = util.copy(capture.filter.exclude); exclude[id] = action == "exclude" or nil
					common.message(capture.setFilter({ include = util.keys(capture.filter.include), exclude = util.keys(exclude), method = capture.filter.method }, capture.revision))
				elseif action == "reveal" then if common.message(explorer.select({ id })) then navigate("Explorer") end
				elseif action == "reference" then common.copy(selected and (selected.id .. " revision " .. selected.revision .. " · " .. id) or id)
				elseif action == "ask" then common.ask(selected and ("Inspect capture " .. selected.id .. " revision " .. selected.revision .. ".") or ("Inspect remote " .. id .. "."))
				elseif action == "draft" then view.argumentDraft = view.argumentDraft or util.deepCopy(selected.arguments); view.section, view.detail = "draft", true; refreshDetail(); layout()
				elseif action == "empty" then overlay.confirm({ title = "Start an empty replay draft?", description = "The captured call is preserved. The new draft begins with zero arguments.", onConfirm = function() view.argumentDraft = { count = 0, slots = {}, nodes = {}, complete = true }; view.section = "draft"; refreshDetail() end })
				elseif action == "replay" then review()
				elseif action == "rebind" then
					if selected.direction == "incoming" then common.message(nil, "Incoming observations cannot be replayed to the server"); return end
					forms.form("Bind offline call", { { key = "remoteId", label = "Current remote reference", type = "reference", required = true, default = explorer.primaryId } }, function(data)
						local object, why = refs.resolve(data.remoteId); if not object then return nil, why end
						local method = object.ClassName == "RemoteFunction" and "InvokeServer" or (object.ClassName == "RemoteEvent" or object.ClassName == "UnreliableRemoteEvent") and "FireServer"
						if method ~= selected.method then return nil, "Remote class does not match the captured method" end
						view.reboundId = data.remoteId; view.argumentDraft = view.argumentDraft or util.deepCopy(selected.arguments); saveDraft(); refreshDetail(); return true
					end, { key = "rebind:" .. selected.id, submit = "Bind", description = "This only binds the draft target. Replace any expired Instance arguments, then review replay separately." })
				elseif action == "refresh" then local record, why = records.get(selected.id); if common.message(record, why) then selected, view.record = record, record; refreshDetail() end
				elseif action == "caller" then local caller = selected.caller; if caller and caller.scriptId then common.work(function() return env.require("tools/source_documents").open({ instanceId = caller.scriptId, focus = true }) end, function() navigate("Editor") end) else common.message(nil, "Calling script information is unavailable") end
				elseif action == "source" then common.work(function()
					local source, why = replay.source(optionsForRecord()); if not source then return nil, why end
					return env.require("tools/source_documents").open({ sourceId = source.id, focus = true })
				end, function() navigate("Editor") end)
				elseif action == "portable" or action == "portableExport" then
					local source, why = replay.portable(optionsForRecord()); if not common.message(source, why) then return end
					if action == "portable" then common.copy(source) else common.work(function() return env.require("runtime/native_exports").write(source, "exports/" .. store.id("remote") .. ".lua") end, function(result) common.copy(result.path) end) end
				end
		end
		local function generatedCode()
			local args = optionsForRecord(); if not args then return nil, "Select a captured call first." end
			local source, why = replay.portable(args)
			if source then return source end
			local bound, err = replay.source(args)
			if bound then return bound.source end
			return nil, err or why
		end
		local function copyCode()
			local source, why = generatedCode(); if common.message(source, why) then common.copy(source) end
		end
		statusButton = header.add("Stopped", function() more(statusButton) end, { flex = true, trailing = false })
		startButton = header.add("Start", function()
			if capture.status == "running" then common.message(capture.control("pause", capture.sessionId, capture.revision))
			elseif capture.status == "paused" then common.message(capture.control("resume", capture.sessionId, capture.revision)) else start() end
		end, { variant = "primary", name = "StartRemoteCapture", tight = true })
		stopButton = header.add("Stop", function() capture.stop("Stopped by user") end, { name = "StopRemoteCapture", tight = true })
		header.add("Clear", function() perform("clear") end, { name = "ClearRemoteCalls", tight = true })
		menuButton = header.add("", more, { icon = "ellipsis", iconOnly = true, name = "RemoteActions" })
		local configBar = common.toolbar(root, { name = "CaptureControls" })
		configBar.root.Position = UDim2.fromOffset(0, common.barHeight())
		local scopeNames = { ["Game subtree"] = "All remotes", ["Selected remote"] = "Selected remote", ["Explorer selection"] = "Explorer selection", ["Selected subtree"] = "Selected subtree" }
		scopeButton = configBar.add("All remotes", function(button)
			local choices = { { label = "All game remotes", value = "Game subtree" }, { label = "Selected remote", value = "Selected remote" }, { label = "Explorer selection", value = "Explorer selection" }, { label = "Selected subtree", value = "Selected subtree" } }
			common.menu(button, "Capture scope", choices, function(value) view.scope = value; refresh() end)
		end, { flex = true, name = "RemoteCaptureScope" })
		modeButton = configBar.add("Both directions", function(button)
			common.menu(button, "Capture direction", { { label = "Incoming and outgoing", value = "Incoming and outgoing" }, { label = "Outgoing calls", value = "Outgoing calls" }, { label = "Incoming events", value = "Incoming events" }, { label = "UAI calls only", value = "UAI calls" } }, function(value) view.mode = value; refresh() end)
		end, { dropdown = true, name = "RemoteCaptureMode", tight = true })
		configBar.add("", configure, { icon = "sliders", iconOnly = true, name = "RemoteCaptureSettings" })
		local function showFilter()
			local definitions = { { key = "name", label = "Remote name", default = view.filter } }
			for _, item in ipairs({ { "direction", "Direction", { "All", "outgoing", "incoming" } }, { "method", "Method", { "All", "FireServer", "InvokeServer", "OnClientEvent" } }, { "origin", "Origin", { "All", "unknown", "uai", "replay", "game", "executor", "server" } }, { "outcome", "Outcome", { "All", "pending", "forwarded", "returned", "received", "errored", "blocked", "completion_unobserved" } } }) do
				definitions[#definitions + 1] = { key = item[1], label = item[2], type = "choice", choices = item[3], default = view.filters[item[1]] or "All" }
			end
			forms.form("Filter retained calls", definitions, function(data)
				view.filter = data.name; store.preference("remoteFilter", data.name)
				for _, key in ipairs({ "direction", "method", "origin", "outcome" }) do view.filters[key] = data[key] ~= "All" and data[key] or nil end
				view.follow, view.before, view.listMode = true, nil, "calls"; refresh(); return true
			end, { key = "calls-filter" })
		end
		local function cataloguePage(morePage)
			catalogueGeneration = catalogueGeneration + 1; local generation = catalogueGeneration
			catalogueBusy = true
			local query = { kind = "remote", rootId = refs.id(game), name = view.filter, limit = 100, cursor = morePage and catalogue and catalogue.nextCursor or nil }
			clock.spawn(function()
				local result, why = explorer.query(query, { aborted = function() return not handle.alive or not handle.visible or generation ~= catalogueGeneration end })
				if not handle.alive or generation ~= catalogueGeneration then return end
				catalogueBusy = false
				if not result then catalogue = { items = {}, error = why }
				elseif morePage and catalogue then
					for _, item in ipairs(result.items) do catalogue.items[#catalogue.items + 1] = item end
					catalogue.nextCursor, catalogue.complete, catalogue.reason = result.nextCursor, result.complete, result.reason
				else catalogue = result end
				refresh()
			end)
		end
		listTabs = tabs.new(listHost, { name = "RemoteListTabs", size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(mode)
			view.listMode, view.detail = mode, false
			if mode == "remotes" and not catalogue then cataloguePage() end
			refresh(); layout()
		end })
		newCalls = listBar.add("Latest", function()
			view.follow, view.before, view.listMode = true, nil, "calls"; refresh()
		end, { flex = true, trailing = false, name = "FollowLatestCalls", tight = true })
		local function layoutListHeader()
			local tabsWidth = math.max(100, common.controlHeight() * 2 + common.inset() * 2)
			local width = math.min(listBar.width(), math.max(common.controlHeight() + common.inset() * 2, listHost.AbsoluteSize.X - tabsWidth))
			listTabs.root.Size = UDim2.new(1, -width, 0, common.barHeight())
			listBar.root.Position, listBar.root.Size = UDim2.new(1, -width, 0, 0), UDim2.fromOffset(width, common.barHeight())
		end
		listHost:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutListHeader)
		local searchGeneration = 0
		local search = P.field(listHost, { name = "RemoteSearch", placeholder = "Search remotes", role = "small", text = view.filter, onChange = function(text)
			view.filter = text; store.workspace.remoteFilter = text; searchGeneration = searchGeneration + 1; local generation = searchGeneration
			clock.delay(0.15, function()
				if not handle.alive or not handle.visible or generation ~= searchGeneration then return end
				view.follow, view.before = true, nil
				if view.listMode == "remotes" then cataloguePage() else refresh() end
			end)
		end })
		local filterSize, searchInset = common.controlHeight(), common.inset()
		search.shell.Position, search.shell.Size = UDim2.fromOffset(searchInset, common.barHeight() + 4), UDim2.new(1, -searchInset * 2 - filterSize - common.gap(), 0, filterSize)
		local filterButton = common.button(listHost, { name = "FilterRemoteCalls", text = "", icon = "sliders", tight = true, fill = true, variant = "ghost", onClick = showFilter })
		filterButton.instance.Position, filterButton.instance.Size = UDim2.new(1, -searchInset - filterSize, 0, common.barHeight() + 4), UDim2.fromOffset(filterSize, filterSize)
		local listTop = common.barHeight() * 2 + 8
		local function selectRow(row)
			if row.older then view.follow, view.before = false, row.older; refresh(); return end
			if row.more then cataloguePage(true); return end
			if row.instanceId then
				saveDraft(); capture.select(nil); selected, view.record, view.argumentDraft = nil, nil, nil
				view.remoteId, view.scope, view.detail = row.instanceId, "Selected remote", true
				refreshDetail(); refresh(); layout(); return
			end
			if not row.id or not row.sequence then return end
			local record, why = records.get(row.id); if not common.message(record, why) then return end
			if not common.message(capture.select(row.id)) then return end
			saveDraft(); selected = record
			local draft = view.drafts[row.id]
			view.record, view.remoteId, view.argumentDraft, view.reboundId = selected, selected.remoteId, draft and draft.graph, draft and draft.reboundId
			view.section, view.detail, view.follow, view.before = "arguments", true, false, view.before or records.sequence + 1
			refreshDetail(); refresh(); layout()
		end
		list = common.virtualList(listHost, { name = "RemoteCallList", position = UDim2.fromOffset(0, listTop), size = UDim2.new(1, 0, 1, -listTop),
			label = function(row) return row.label end, detail = function(row) return row.description end,
			meta = function(row) return row.sequence and ("#" .. row.sequence) or "" end,
			icon = function(row) return row.className end, onSelect = selectRow,
			onContextMenu = function(row, _, button) selectRow(row); if row.remoteId or row.instanceId then more(button) end end })
		list.root:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			view.y = list.root.CanvasPosition.Y
			if not movingList and view.listMode == "calls" and list.root.CanvasPosition.Y + list.root.AbsoluteSize.Y + 12 < list.root.CanvasSize.Y.Offset then
				view.follow, view.before = false, view.before or records.sequence + 1
			end
		end)
		local backButton = detailBar.add("Back", function() view.detail = false; layout() end, { icon = "arrowLeft", tight = true })
		local copyButton = detailBar.add("Copy code", copyCode, { tight = true, name = "CopyRemoteCode" })
		local openButton = detailBar.add("Open", function() perform("source") end, { tight = true, name = "OpenRemoteCode" })
		local replayButton = detailBar.add("Replay", review, { tight = true, name = "ReviewRemoteReplay" })
		detailBar.add("", more, { icon = "ellipsis", iconOnly = true, name = "RemoteDetailActions" })
		sectionTabs = tabs.new(detailHost, { name = "RemoteDetailTabs", position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(section)
			view.section = section
			if section == "draft" and selected then view.argumentDraft = view.argumentDraft or util.deepCopy(selected.arguments) end
			refreshDetail()
		end })
		recordHeader = P.text(detailHost, { name = "RemoteCallIdentity", text = "Select a captured call", role = "caption", truncate = true, position = UDim2.fromOffset(8, common.barHeight() * 2), size = UDim2.new(1, -16, 0, theme.text.caption.height * 2 + 12) })
		local detailTop = common.barHeight() * 2 + theme.text.caption.height * 2 + 12
		local valueHost = P.frame(detailHost, { name = "RemoteValues", position = UDim2.fromOffset(0, detailTop), size = UDim2.new(1, 0, 1, -detailTop), clip = true })
		local function describeSelected()
			if not selected then return end
			local object = selected.remoteId and refs.resolve(selected.remoteId)
			local path = object and refs.describe(object).displayPath or selected.pathAtCapture or selected.name or "Remote"
			recordHeader.Text = "#" .. selected.sequence .. " · " .. selected.method .. " · " .. selected.outcome .. (selected.offline and " · offline" or "") .. "\n" .. path
		end
		refreshDetail = function()
			if valueView then valueView.destroy(); valueView = nil end; common.clear(valueHost)
			sectionTabs.set({ { id = "arguments", label = "Arguments" }, { id = "code", label = "Code" }, { id = "results", label = "Results" }, { id = "caller", label = "Caller" }, { id = "draft", label = "Replay draft" } }, view.section)
			local outgoing = selected ~= nil and selected.direction == "outgoing"
			copyButton.setEnabled(outgoing); openButton.setEnabled(outgoing); replayButton.setEnabled(outgoing)
			if not selected then
				local object = view.remoteId and refs.resolve(view.remoteId)
				recordHeader.Text = object and (object.Name .. " · " .. object.ClassName .. "\n" .. refs.describe(object).displayPath) or "Select a call to inspect its arguments, code and results."
				local title = object and "Ready to observe this remote" or "Remote spy"
				P.text(valueHost, { text = title, role = "heading", position = UDim2.fromOffset(16, 20), size = UDim2.new(1, -32, 0, 30) })
				P.text(valueHost, { text = object and "Selected remote is the capture scope. Press Start to begin recording." or "Press Start to record calls across the game. Browse remotes to choose a specific target.", role = "small", wrap = true, position = UDim2.fromOffset(16, 58), size = UDim2.new(1, -32, 0, 90), color = theme.color.textSecondary })
				return
			end
			describeSelected()
			if view.section == "code" then
				local source, why = generatedCode()
				valueView = env.require("ui/code/preview").new(valueHost, source or ("-- " .. tostring(why)), "RemoteGeneratedCode"); return
			end
			if view.section == "caller" then
				local caller = selected.caller or {}
				valueView = env.require("ui/code/preview").new(valueHost, "Origin: " .. (selected.origin or "unknown") .. "\nCalling script: " .. (caller.scriptId or "Unavailable") .. "\nProvenance: " .. (caller.provenance or "Not observed"), "RemoteCaller"); return
			end
			if view.section == "draft" then view.argumentDraft = view.argumentDraft or util.deepCopy(selected.arguments) end
			local graph = view.section == "draft" and view.argumentDraft or view.section == "results" and selected.results or selected.arguments
			if view.section == "results" and not selected.results then
				P.text(valueHost, { text = selected.error or (selected.outcome == "pending" and "Waiting for the call to return…" or "Return values were not observed for this call."), role = "small", wrap = true, position = UDim2.fromOffset(12, 12), size = UDim2.new(1, -24, 1, -24) }); return
			end
			valueView = tree.new(valueHost, { graph = graph, expanded = view.expanded, editable = view.section == "draft", key = selected.id, reveal = navigate, onChange = function(value) view.argumentDraft = value; saveDraft() end })
		end
		refresh = function()
			if not handle.alive or not handle.visible then return end
			local current = state()
			local active = current.status == "running" or current.status == "paused" or current.status == "starting"
			local names = { idle = "Stopped", stopped = "Stopped", starting = "Starting…", running = "Recording", paused = "Paused", faulted = "Failed", disposed = "Stopped" }
			statusButton.setText((names[current.status] or current.status) .. (#capture.rules > 0 and (" · " .. #capture.rules .. " rules") or ""))
			startButton.setText(current.status == "running" and "Pause" or current.status == "paused" and "Resume" or "Start")
			startButton.setEnabled(current.status ~= "starting")
			stopButton.setEnabled(active or #capture.rules > 0)
			scopeButton.setText(scopeNames[view.scope] or "All remotes"); scopeButton.setEnabled(not active)
			local modeNames = { ["Incoming and outgoing"] = "Both directions", ["Outgoing calls"] = "Outgoing", ["Incoming events"] = "Incoming", ["UAI calls"] = "UAI only" }
			modeButton.setText(modeNames[view.mode] or view.mode); modeButton.setEnabled(not active)
			local modes = { uai = "UAI calls only", incoming = "Incoming events", outgoing = "Outgoing calls", combined = "Incoming + outgoing" }
			local summary = active and (modes[current.mode] .. " · " .. current.monitored .. " incoming remotes · " .. current.retained .. " calls") or ("Ready · " .. (scopeNames[view.scope] or view.scope) .. " · " .. (modeNames[view.mode] or view.mode))
			if current.omitted > 0 then summary = summary .. " · " .. current.omitted .. " omitted" end
			if current.counters.evicted > 0 then summary = summary .. " · " .. current.counters.evicted .. " old calls evicted" end
			if current.status == "faulted" then summary = tostring(capture.reason or "Capture failed. Open settings to choose another backend.") end
			info.Text = summary
			listTabs.set({ { id = "calls", label = "Calls" }, { id = "remotes", label = "Remotes" } }, view.listMode)
			local items, why = {}, nil
			if view.listMode == "remotes" then
				for _, item in ipairs(catalogue and catalogue.items or {}) do
					local row = util.copy(item); row.label, row.description, row.selected = item.name, item.displayPath, item.instanceId == view.remoteId; items[#items + 1] = row
				end
				if catalogue and catalogue.nextCursor then items[#items + 1] = { id = "more-remotes", more = true, label = "Load more remotes…" } end
				why = catalogue and catalogue.error
				if #items == 0 then items[1] = { id = "empty-remotes", label = catalogueBusy and "Finding remotes…" or why or "No matching remotes found", description = "Available RemoteEvents and RemoteFunctions" } end
			else
				local query = util.copy(view.filters); query.name, query.limit = view.filter, 100
				if not view.follow then view.before = view.before or current.newest + 1; query.before_sequence = view.before end
				local page; page, why = records.latest(query)
				if page then
					view.first, view.last = page.first, page.last
					if page.hasOlder then items[#items + 1] = { id = "older:" .. page.first, older = page.first, label = "Load older calls…", description = "Earlier matching calls" } end
					for _, row in ipairs(page.items) do
						row.label = row.name or "Remote"
						row.description = (row.direction == "incoming" and "← " or "→ ") .. row.method .. " · " .. row.argumentCount .. " args · " .. row.outcome .. " · " .. (row.origin or "unknown")
						row.selected = selected and row.id == selected.id; items[#items + 1] = row
					end
				end
				if #items == 0 then
					items[1] = { id = "empty-calls", label = why or (current.retained > 0 and "No calls match this filter" or active and "Waiting for remote calls…" or "No captured calls yet"), description = active and "Use the game while recording to see calls here." or "Choose a scope above, then press Start." }
				end
			end
			movingList = true; list.set(items, true)
			if view.follow and view.listMode == "calls" then
				list.root.CanvasPosition = Vector2.new(0, math.max(0, list.root.CanvasSize.Y.Offset - list.root.AbsoluteSize.Y))
				view.lastSeen = current.newest
			end
			movingList = false
			local unseen = math.max(0, current.newest - (view.lastSeen or current.newest))
			newCalls.setText(view.follow and "Following" or unseen > 0 and ("Latest +" .. unseen) or "Latest")
			layoutListHeader()
			if selected then
				local live = records.get(selected.id)
				if not live then recordHeader.Text = "This call expired or was cleared.\nIts replay draft is still available."
				elseif live.revision ~= selected.revision then
					selected, view.record = live, live
					if view.section == "results" then refreshDetail() else describeSelected() end
				end
			end
		end
		local divider = env.require("ui/code/splitter").new(body, function(position)
			view.listWidth = math.max(240, math.min(body.AbsoluteSize.X - 280, position.X - body.AbsolutePosition.X)); layout()
		end)
		layout = function()
			local top = common.barHeight() * 2 + theme.text.caption.height * 2 + 8
			info.Position, info.Size = UDim2.fromOffset(10, common.barHeight() * 2 + 4), UDim2.new(1, -20, 0, top - common.barHeight() * 2 - 4)
			body.Position, body.Size = UDim2.fromOffset(0, top), UDim2.new(1, 0, 1, -top)
			local wide = root.AbsoluteSize.X >= 620
			local width = math.max(240, math.min(root.AbsoluteSize.X - 280, view.listWidth or root.AbsoluteSize.X * 0.4))
			listHost.Visible, detailHost.Visible = wide or not view.detail, wide or view.detail == true
			listHost.Size = wide and UDim2.new(0, width, 1, 0) or UDim2.fromScale(1, 1)
			layoutListHeader()
			detailHost.Position, detailHost.Size = UDim2.fromOffset(wide and width + 6 or 0, 0), UDim2.new(1, wide and -width - 6 or 0, 1, 0)
			backButton.instance.Visible, divider.root.Visible = not wide, wide and handle.visible
			divider.root.Position, divider.root.Size = UDim2.fromOffset(width, 0), UDim2.new(0, 6, 1, 0)
		end
		local queued = false
		local function queue()
			if queued or not handle.visible then return end; queued = true
			clock.delay(0.1, function() queued = false; if handle.alive and handle.visible then refresh() end end)
		end
		local offRecords, offCapture = records.changed:connect(queue), capture.changed:connect(queue)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		function handle.setVisible(visible)
			if handle.visible == visible then return end
			handle.visible, list.visible = visible, visible
			if visible then
				selected = view.record
				if not selected and view.remoteId then view.scope = "Selected remote" end
				refresh(); refreshDetail(); layout()
				if view.listMode == "remotes" then cataloguePage() end
			else
				saveDraft(); catalogueGeneration = catalogueGeneration + 1; catalogueBusy = false; divider.root.Visible = false
			end
		end
		function handle.destroy()
			handle.alive = false; catalogueGeneration = catalogueGeneration + 1
			saveDraft(); view.record = selected; offRecords(); offCapture(); divider.destroy()
			if valueView then valueView.destroy() end; root:Destroy()
		end
		handle.list, handle.more, handle.refresh, handle.start, handle.scan = list, more, refresh, start, cataloguePage
		layout(); refresh(); refreshDetail()
		if view.listMode == "remotes" then cataloguePage() end
		if not view.follow then movingList = true; list.root.CanvasPosition = Vector2.new(0, view.y or 0); movingList = false end
		return handle
	end
	return M
end
