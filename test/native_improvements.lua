-- Native client contracts, using synthetic objects, files, clocks and transports.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Native improvements")
local case, check = suite.case, suite.check
local function has(value, needle) return tostring(value):find(needle, 1, true) ~= nil end
local function object(f, class, name, parent)
	local item = f.h.Instance.new(class, parent or f.h.workspace); item.Name = name or class; return item
end
local function meta(f, remote, direction)
	return { remoteId = f.env.require("runtime/instance_refs").id(remote), name = remote.Name, className = remote.ClassName,
		method = direction == "incoming" and "OnClientEvent" or "InvokeServer", direction = direction or "outgoing", origin = "uai", sessionId = "fixture" }
end

case("source capabilities and provenance distinguish empty, authored and unsupported objects", function()
	local f = F.new(); local sources, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs")
	local script = object(f, "LocalScript", "Readable"); script.Source = "return '你好'"
	local calls = 0; f.env.require("runtime/caps").fn.decompile = function() calls = calls + 1; return "return false" end
	local key = refs.id(script); local capability = sources.capabilities(key)
	check("script advertises per-instance source and decompile", capability.supported and capability.source and capability.decompile)
	local item = assert(f.run(function() return sources.inspect(key) end))
	check("host source has immutable provenance", item.readOnly and item.method == "source" and item.origin == "host-readable" and item.instanceId == key and item.runtimeEpoch == refs.epoch and not item.writeBack and not item.liveBinding)
	check("reading source never invokes the decompiler", calls == 0 and item.sourceHash == sources.hash(script.Source))
	script.Source = ""; local empty = assert(f.run(function() return sources.inspect(key, nil, { refresh = true }) end))
	check("empty is a successful explicit source result", empty.status == "empty" and empty.bytes == 0 and calls == 0)
	local partId = refs.id(object(f, "Part", "NoSource"))
	local unsupported, _, detail = sources.inspect(partId)
	check("non-source objects have no source action", not sources.capabilities(partId).supported and not unsupported and detail.code == "unsupported_object")
	local store = f.env.require("runtime/code_store"); store.init()
	local authored = sources.document(store.active())
	check("authored documents use the same source model", authored.origin == "authored" and authored.status == "empty" and not authored.readOnly and authored.documentId == store.activeId())
	f.healthy(); f.close()
end)

case("decompile fallback returns safe structured failures without execution", function()
	local f = F.new(); local sources, refs, caps = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs"), f.env.require("runtime/caps")
	local script = object(f, "ModuleScript", "Unreadable"); local key = refs.id(script)
	caps.fn.decompile = nil
	local missing, _, absent = f.run(function() return sources.inspect(key) end)
	check("missing decompiler is distinct", not missing and absent.code == "decompiler_unavailable")
	caps.fn.decompile = function() error("fixture-private-host-detail") end
	local failed, message, detail = f.run(function() return sources.inspect(key) end)
	check("host errors are not exposed", not failed and detail.status == "error" and detail.code == "decompiler_failure" and not has(message, "fixture-private"))
	caps.fn.decompile = function() return "_G.sourceExecuted = true; return 1" end
	local item = assert(f.run(function() return sources.inspect(key) end))
	check("decompiled source is never executed by opening", item.method == "decompiled" and item.readOnly and f.h.sandbox.sourceExecuted == nil)
	f.healthy(); f.close()
end)

case("duplicate decompiles share one worker and cancelled owners cannot steal completion", function()
	local f = F.new(); local sources, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs")
	local key = refs.id(object(f, "LocalScript", "Slow")); local calls, results = 0, {}
	f.env.require("runtime/caps").fn.decompile = function() calls = calls + 1; f.h.sched.wait(0.1); return "return 2" end
	for i = 1, 2 do f.h.sched.spawn(function() results[i] = sources.inspect(key) end) end
	f.h.sched.advance(0.2)
	check("concurrent reads are deduplicated", calls == 1 and results[1] and results[2] and results[1].id == results[2].id and sources.state().workers == 0)
	sources.invalidate(key)
	local owner, old, newest = {}, nil, nil
	f.h.sched.spawn(function() local _, _, detail = sources.inspect(key, { requestOwner = owner }); old = detail end)
	f.h.sched.spawn(function() newest = sources.inspect(key, { requestOwner = owner }) end)
	f.h.sched.advance(0.2)
	check("superseded owner discards only its own result", old and old.code == "stale_request" and newest and calls == 2)
	f.healthy(); f.close()
end)

case("refresh generations and runtime cancellation discard late decompiles", function()
	local f = F.new(); local sources, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs")
	local key = refs.id(object(f, "LocalScript", "Refresh")); local calls, old, current = 0, nil, nil
	f.env.require("runtime/caps").fn.decompile = function() calls = calls + 1; local value = calls; f.h.sched.wait(0.1); return "return " .. value end
	f.h.sched.spawn(function() local _, _, detail = sources.inspect(key); old = detail end)
	f.h.sched.advance(0.02)
	f.h.sched.spawn(function() current = sources.inspect(key, nil, { refresh = true }) end)
	f.h.sched.advance(0.2)
	check("refresh rejects the old generation", old and old.code == "stale_request" and current and current.source == "return 2")
	check("only the current result is cached", sources.inspect(key).id == current.id and sources.state().snapshots == 1)
	local _, _, wrongEpoch = sources.inspect(key, { runtimeEpoch = "expired-runtime" })
	check("cross-runtime requests are rejected", wrongEpoch.code == "stale_request")
	f.close(); check("disposed service cannot reopen a cached source", sources.get(current.id) == nil)
	f.healthy()
end)

case("source timeouts bound host workers and reject their eventual results", function()
	local f = F.new(); local sources, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs")
	f.env.require("runtime/code_limits").sourceDeadline = 50
	local calls, results = 0, {}
	f.env.require("runtime/caps").fn.decompile = function() calls = calls + 1; f.h.sched.wait(0.2); return "return 1" end
	for i = 1, 5 do
		local key = refs.id(object(f, "ModuleScript", "Worker" .. i))
		f.h.sched.spawn(function() local item, why, detail = sources.inspect(key); results[i] = { item = item, why = why, detail = detail } end)
	end
	f.h.sched.advance(0.1)
	check("a fifth host worker is refused", calls == 4 and has(results[5].why, "busy") and sources.state().workers == 4)
	check("expired waiters receive a stale result", results[1].detail.code == "stale_request")
	f.h.sched.advance(0.2)
	check("abandoned completions cannot populate the cache", sources.state().workers == 0 and sources.state().snapshots == 0)
	f.healthy(); f.close()
end)

case("source cache eviction, display pins and explicit expiry stay bounded", function()
	local f = F.new(); local sources, limits = f.env.require("runtime/script_sources"), f.env.require("runtime/code_limits")
	limits.sourceSnapshots, limits.sourceCacheBytes, limits.ttl = 2, 64, 50
	local owner = {}; local first = assert(sources.keep("first", "fixture")); assert(sources.pin(first.id, owner))
	local second = assert(sources.keep("second", "fixture")); assert(sources.keep("third", "fixture"))
	check("eviction preserves displayed snapshots", sources.get(first.id) and not sources.get(second.id) and sources.state().snapshots == 2)
	f.h.sched.advance(0.1); check("display pin extends snapshot lifetime", sources.get(first.id) ~= nil)
	sources.release(owner); local _, _, expired = sources.get(first.id)
	check("release makes expired snapshots explicit", expired.code == "expired_snapshot" and expired.status == "expired")
	limits.file = 16; local tooLarge, _, detail = sources.keep(string.rep("a", 17), "fixture")
	check("oversize source is reported without retention", not tooLarge and detail.code == "oversized_source")
	local invalid, _, invalidDetail = sources.keep(string.char(255), "fixture")
	check("invalid source is structured", not invalid and invalidDetail.code == "invalid_source")
	f.healthy(); f.close()
end)

case("a decompile finishing at its deadline cannot populate the source cache", function()
	local f = F.new(); local sources, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/instance_refs")
	f.env.require("runtime/code_limits").sourceDeadline = 50
	local key = refs.id(object(f, "LocalScript", "Deadline"))
	f.env.require("runtime/caps").fn.decompile = function() f.h.sched.wait(0.05); return "return 'late'" end
	local item, why, detail = f.run(function() return sources.inspect(key) end)
	check("completion at the deadline is stale", not item and detail.code == "stale_request" and has(why, "timed out"))
	check("late results do not survive in the completed cache", sources.state().snapshots == 0 and sources.state().workers == 0)
	local ok, cancelled, _, failure = pcall(sources.inspect, key, { aborted = function() error("private callback error") end })
	check("throwing cancellation callbacks fail closed without leaking host errors", ok and not cancelled and failure.code == "stale_request" and not has(failure.diagnostics, "private"))
	f.healthy(); f.close()
end)

case("read-only source survives persistence and requires editable extraction", function()
	local f = F.new(); local sources, docs, store = f.env.require("runtime/script_sources"), f.env.require("tools/source_documents"), f.env.require("runtime/code_store")
	local item = assert(sources.keep("return '你好'", "decompiled fixture", "Readonly.lua", nil, { method = "decompiled" }))
	local opened = assert(docs.open({ sourceId = item.id, focus = true })); local doc = assert(store.resolve(opened.documentId))
	check("source edits, proposals, runs and actions are guarded", not store.update(doc.id, "return 2") and not store.propose(doc.id, 0, "return 2") and not store.saveAction(doc.id, "Unsafe", {}) and not f.env.require("tools/code_runner").snapshot(doc.id, doc.revision))
	local copy = assert(docs.extract({ documentId = doc.id, name = "Editable.lua" }))
	assert(store.update(copy.id, "return 3"))
	check("extraction cannot overwrite the immutable original", copy.id ~= doc.id and not copy.readOnly and doc.source == item.source)
	assert(store.saveNow())
	local fresh = F.new(); for path, content in pairs(f.h.files) do fresh.h.files[path] = content end
	local restored = fresh.env.require("runtime/code_store"); restored.init(); assert(restored.select(doc.id))
	check("persisted immutable source does not silently become runnable", restored.active().readOnly and restored.active().snapshotState == "expired" and not restored.update(doc.id, "return 4"))
	f.healthy(); fresh.healthy(); fresh.close(); f.close()
end)

case("source pins belong to the visible editor and are released on hide and destroy", function()
	local f = F.ui(480, 320); local sources, docs = f.env.require("runtime/script_sources"), f.env.require("tools/source_documents")
	f.env.require("runtime/code_limits").ttl = 50
	local item = assert(sources.keep("return 1", "fixture", "Pinned.lua", nil, { method = "decompiled" }))
	assert(docs.open({ sourceId = item.id, focus = true }))
	local editor = f.env.require("ui/code/editor").new(f.host)
	f.h.sched.advance(0.1); check("a displayed snapshot survives its original expiry", sources.get(item.id) ~= nil)
	editor.setVisible(false); check("hidden documents do not retain display pins", sources.get(item.id) == nil)
	local nextItem = assert(sources.keep("return 2", "fixture", "Next.lua", nil, { method = "decompiled" }))
	assert(docs.open({ sourceId = nextItem.id, focus = true })); editor.setVisible(true)
	f.h.sched.advance(0.1); editor.destroy()
	check("destroy releases the final display owner", sources.get(nextItem.id) == nil)
	f.healthy(); f.close()
end)

case("UTF-8 slicing, columns and search share one coordinate contract", function()
	local f = F.new(); local text = f.env.require("runtime/code_text")
	local source = "A你🙂"
	check("columns count Unicode code points", text.column(source, 1, #source + 1) == 4 and text.byteAt(source, 3) == 5)
	check("byte boundaries reject continuation bytes", text.boundary(source, 2) and not text.boundary(source, 3) and not text.page(source, 3, 8))
	local part, nextAt = text.page(source, 2, 1)
	check("tiny pages retain complete UTF-8 characters", part == "你" and nextAt == 5)
	local found = assert(text.search("Needle needle needlework 你🙂", "needle", { caseSensitive = false, wholeWord = true }))
	check("case and whole-word options agree", found.total == 2 and #found.items == 2)
	local emoji = assert(text.search(source, "🙂"))
	check("search returns exact byte selections", emoji.items[1].first == 5 and emoji.items[1].after == #source + 1)
	check("invalid patterns fail explicitly", not text.search(source, "[", { pattern = true }))
	f.close()
end)

case("workspace search continues beyond the first result page", function()
	local f = F.new(); local store = f.env.require("runtime/code_store"); store.init()
	assert(store.update(store.activeId(), string.rep("needle ", 40)))
	local rows, _, cursor, counts = store.search("needle", { document = store.activeId(), limit = 2, offset = 20 })
	check("a result limit does not truncate the underlying query", #rows == 2 and rows[1].first == 141 and cursor == 22 and counts.retainedMatches == 40 and counts.complete)
	f.healthy(); f.close()
end)

case("editor exposes multiline selection, match counts and horizontal caret reveal", function()
	local f = F.ui(380, 300); local store = f.env.require("runtime/code_store")
	assert(store.update(store.activeId(), "你好 alpha\nsecond\nalpha ALPHA alphaWord"))
	local editor = f.env.require("ui/code/editor").new(f.host); local box = editor.box
	box:CaptureFocus(); box.SelectionStart, box.CursorPosition = 1, #box.Text + 1
	local selections = 0; for _, node in ipairs(editor.root:GetDescendants()) do if node.Name == "SourceSelection" and node.Visible then selections = selections + 1 end end
	check("selection paints every selected line", selections == 3)
	box.CursorPosition = 1; assert(editor.find("alpha", false, { caseSensitive = false, wholeWord = true }))
	check("match count and exact range are visible", editor.matches().total == 3 and editor.matches().current == 1 and box.Text:sub(box.SelectionStart, box.CursorPosition - 1) == "alpha")
	assert(editor.find("alpha", false)); check("Next advances the current match", editor.matches().current == 2)
	editor.gotoLine(2); check("Go to line uses the correct UTF-8 byte offset", box.CursorPosition == #("你好 alpha\n") + 1)
	box.Text = string.rep("a", 4000); f.h.sched.advance(0.1); box.CursorPosition, box.SelectionStart = #box.Text + 1, -1
	check("a long line reveals the caret horizontally", editor.scroll.CanvasPosition.X > 0)
	f.healthy(); editor.destroy(); f.close()
end)

case("large-source search crosses pages and hidden snapshots expire with recovery", function()
	local f = F.ui(500, 350); local sources, store = f.env.require("runtime/script_sources"), f.env.require("runtime/code_store")
	f.env.require("runtime/code_limits").ttl = 50
	local item = assert(sources.keep(string.rep("a", 5998) .. "needle\nend", "fixture", "Large.lua"))
	store.workspace.sourceId, store.workspace.sourceInfo = item.id, sources.describe(item)
	local reader = f.env.require("ui/code/large_source").new(f.host, function() end)
	check("ordinary pages are byte bounded", #assert(sources.read(item.id, 1)).text == 6000)
	assert(reader.find("needle")); check("a match spanning the first page is found in full", store.workspace.sourceOffset == 5999)
	reader.setVisible(false); f.h.sched.advance(0.1); reader.setVisible(true)
	check("expired reader shows recovery instead of old content", reader.expired == true and has(f.h.textOf(reader.root), "Expired"))
	f.healthy(); reader.destroy(); f.close()
end)

case("source refreshes cannot navigate after their reader is hidden or replaced", function()
	local f = F.ui(500, 350); local sources, store, refs = f.env.require("runtime/script_sources"), f.env.require("runtime/code_store"), f.env.require("runtime/instance_refs")
	local script = object(f, "LocalScript", "SlowRefresh")
	local item = assert(sources.keep("return 'old'", "fixture", "SlowRefresh.lua", nil, { method = "decompiled", instanceId = refs.id(script) }))
	store.workspace.sourceId, store.workspace.sourceInfo = item.id, sources.describe(item)
	local navigations, initial = 0, store.activeId()
	local reader = f.env.require("ui/code/large_source").new(f.host, function() navigations = navigations + 1 end)
	f.env.require("runtime/caps").fn.decompile = function() f.h.sched.wait(0.1); return "return 'refreshed'" end
	reader.refresh(); f.h.sched.advance(0.02); reader.setVisible(false); f.h.sched.advance(0.2)
	check("leaving the reader discards its pending navigation", navigations == 0 and store.activeId() == initial and store.workspace.sourceId == item.id)
	reader.setVisible(true); reader.refresh(); f.h.sched.advance(0.02)
	reader.setVisible(false); reader.setVisible(true); f.h.sched.advance(0.2)
	check("returning to the view cannot revive its cancelled refresh", navigations == 0 and store.activeId() == initial and store.workspace.sourceId == item.id)
	reader.refresh(); f.h.sched.advance(0.02)
	local replacement = assert(sources.keep("return 'replacement'", "fixture", "Replacement.lua"))
	store.workspace.sourceId = replacement.id; f.h.sched.advance(0.2)
	check("a replaced source cannot reclaim the editor", navigations == 0 and store.activeId() == initial and store.workspace.sourceId == replacement.id)
	f.healthy(); reader.destroy(); f.close()
end)

case("maximum editable sources autosave and interrupted writes remain retryable", function()
	local f = F.new(); local store, fs = f.env.require("runtime/code_store"), f.env.require("runtime/fsx"); store.init()
	local source = "--" .. string.rep("a", 255998); assert(store.update(store.activeId(), source)); assert(store.saveNow())
	check("maximum-size editable source survives autosave", has(fs.read("code/workspace.json"), source))
	local write = fs.write; local interrupted = false
	fs.write = function(path, raw, options)
		if not interrupted and path == "code/workspace.json" then interrupted = true; write(path, raw:sub(1, 10), options); error("interrupted fixture write") end
		return write(path, raw, options)
	end
	assert(store.update(store.activeId(), "return 'unsaved'")); check("interrupted save keeps the draft and releases the save lock", not store.saveNow() and store.storage.state == "failed" and store.active().source == "return 'unsaved'")
	fs.write = write; assert(store.saveNow())
	check("Retry repairs owned partial writes", store.storage.state == "saved" and fs.read("code/workspace.json") == fs.read("code/workspace.backup.json"))
	f.healthy(); f.close()
end)

case("a successful save with interrupted readback can be verified on Retry", function()
	local f = F.new(); local store, fs = f.env.require("runtime/code_store"), f.env.require("runtime/fsx"); store.init()
	assert(store.saveNow()); assert(store.update(store.activeId(), "return 'new draft'"))
	local read, write, written = fs.read, fs.write, false
	fs.write = function(path, raw, options)
		local result, why = write(path, raw, options)
		if path == "code/workspace.json" then written = true end
		return result, why
	end
	fs.read = function(path) if written and path == "code/workspace.json" then error("readback interrupted") end; return read(path) end
	check("failed readback releases the save lock and retains the draft", not store.saveNow() and store.storage.state == "failed" and store.active().source == "return 'new draft'")
	fs.read, fs.write = read, write
	assert(store.saveNow())
	check("Retry recognizes the exact previously written snapshot", store.storage.state == "saved" and fs.read("code/workspace.json") == fs.read("code/workspace.backup.json"))
	f.healthy(); f.close()
end)

case("external workspace conflicts never overwrite drafts or break undo revisions", function()
	local f = F.new(); local store, fs = f.env.require("runtime/code_store"), f.env.require("runtime/fsx"); store.init()
	local doc = store.active(); assert(store.update(doc.id, "return 1")); assert(store.saveNow())
	assert(store.update(doc.id, "return 2", { origin = "tool", expected_revision = doc.revision }))
	local revision = doc.revision; assert(store.undoSource(doc.id)); assert(store.redoSource(doc.id))
	check("undo and redo advance rather than reuse revisions", doc.source == "return 2" and doc.revision == revision + 2)
	local proposal = assert(store.propose(doc.id, doc.revision, "return 3")); assert(store.applyProposal(proposal.id))
	assert(fs.write("code/workspace.json", "external fixture content"))
	check("external writes remain untouched", not store.saveNow() and store.storage.state == "conflict" and fs.read("code/workspace.json") == "external fixture content" and doc.source == "return 3")
	f.healthy(); f.close()
end)

case("Explorer separates primary, focus and selection and rejects stale hierarchy actions", function()
	local f = F.new(); local explorer, refs, edits = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs"), f.env.require("runtime/instance_edits")
	local a, b = object(f, "Part", "A"), object(f, "Part", "B"); local ia, ib = refs.id(a), refs.id(b)
	assert(explorer.select({ ia, ib }, "replace", nil, { primaryId = ia, clickedId = ib, focusId = ib }))
	local snapshot = explorer.state(); check("primary is explicit and can differ from focus and click", snapshot.primaryId == ia and snapshot.focusId == ib and snapshot.clickedId == ib and #snapshot.selectedIds == 2)
	check("single-target actions cannot ignore a multi-selection", not edits.hierarchy("delete", { instanceId = ib, selection = snapshot }).ok and b.Parent ~= nil)
	assert(explorer.select({ ia }, "remove")); check("primary removal selects a remaining object", explorer.primaryId == ib and explorer.anchorId == ib)
	check("stale Inspector actions do not write", not edits.hierarchyMany("delete", { ia, ib }, { selection = snapshot }).ok and a.Parent ~= nil)
	b:Destroy(); explorer.reconcileSelection()
	check("destroyed selections clear all identity fields", #explorer.selectedIds == 0 and explorer.primaryId == nil and explorer.focusId == nil and explorer.anchorId == nil)
	f.healthy(); f.close()
end)

case("Explorer query cancellation, deduplication and result ownership are canonical", function()
	local f = F.new(); local explorer, refs, scan = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs"), f.env.require("runtime/instance_scan")
	local a, b = object(f, "Part", "MatchA"), object(f, "Part", "MatchB")
	scan.descendants = function(_, _, visit) visit(a); f.h.sched.wait(0.05); visit(a); visit(b); return { complete = true, scanned = 3, unreadable = 0, duplicates = 1 } end
	local cancelled, problem = false, nil
	f.h.sched.spawn(function() local _, why = explorer.query({ name = "Match" }, { aborted = function() return cancelled end }); problem = why end)
	f.h.sched.advance(0.02); cancelled = true; f.h.sched.advance(0.1)
	check("a superseded query cannot become the shared result", has(problem, "cancelled") and explorer.state().query == nil)
	local page = assert(f.run(function() return explorer.query({ name = "Match", limit = 1, generation = 7 }) end))
	check("query results deduplicate identities", page.total == 2 and page.generation == 7 and page.totalKnown)
	local second = assert(explorer.query({ name = "Match", cursor = page.nextCursor, limit = 1 }))
	second.items[1].name = "UI mutation"
	check("UI pages cannot mutate the retained query", explorer.query({ name = "Match", cursor = page.nextCursor }).items[1].name == "MatchB")
	local merged = assert(explorer.mergePage(page, second)); check("runtime merges pages by identity", #merged.items == 2 and merged.items[1].instanceId == refs.id(a))
	explorer.cancelQuery(page.queryId)
	check("cancelled cursors cannot be reused", not explorer.query({ name = "Match", cursor = page.nextCursor }))
	f.healthy(); f.close()
end)

case("Explorer reports runtime child limits and UI truncation honestly", function()
	local f = F.new(); local explorer, refs = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs")
	local root, child = object(f, "Folder", "Root"), object(f, "Part", "Child")
	local children = {}; for i = 1, 20001 do children[i] = child end
	root.__children = children
	local page = assert(explorer.children(refs.id(root), nil, 2))
	check("runtime limits distinguish omitted from unreadable", page.total == 20001 and page.limited == 1 and page.omitted == 1 and page.unreadable == 0 and not page.complete)
	local capped = assert(explorer.mergePage(nil, { items = { { instanceId = "a" }, { instanceId = "b" } }, nextCursor = "more" }, 1))
	check("UI truncation is explicit and cannot silently keep paging", capped.uiTruncated and capped.displayed == 1 and capped.nextCursor == nil)
	f.healthy(); f.close()
end)

case("Explorer partial searches and displayed row limits remain explicit", function()
	local f = F.ui(420, 320); local explorer, scan = f.env.require("runtime/explorer"), f.env.require("runtime/instance_scan")
	scan.descendants = function(_, _, visit) visit({ ClassName = "Part" }); return { complete = true, scanned = 1, unreadable = 0 } end
	local result = assert(explorer.query({ name = "unreadable" }))
	check("unreadable names make the match total unknown", not result.complete and not result.totalKnown and result.unreadable == 1 and result.reason ~= nil)
	local merged = assert(explorer.mergePage({ items = { { instanceId = "a" } }, omittedBefore = 20 },
		{ items = { { instanceId = "b" } }, omittedBefore = 70 }))
	check("appending a reveal page preserves its original starting boundary", merged.omittedBefore == 20 and #merged.items == 2)
	explorer.children = function()
		local items = {}; for i = 1, 4005 do items[i] = { instanceId = "fixture:" .. i, name = "Row " .. i, className = "Part" } end
		return { items = items, total = #items, complete = true }
	end
	local view = f.env.require("ui/code/explorer").new(f.host, function() end)
	check("the capped tree includes a visible explanation row", #view.list.items == 4000 and view.list.items[4000].limited and has(view.list.items[4000].label, "4,000"))
	explorer.children = function()
		local items = {}; for i = 1, 3999 do items[i] = { instanceId = "fixture:" .. i, name = "Row " .. i, className = "Part" } end
		return { items = items, total = 4500, complete = false, nextCursor = "more-fixture" }
	end
	view.setVisible(false); view.setVisible(true)
	check("a hidden load-more row still reports the display limit", #view.list.items == 4000 and view.list.items[4000].limited)
	f.healthy(); view.destroy(); f.close()
end)

case("Remote Spy resolves the explicit primary and rejects stale selection scopes", function()
	local f = F.new(); local refs, explorer, targets = f.env.require("runtime/instance_refs"), f.env.require("runtime/explorer"), f.env.require("runtime/remote_targets")
	local a, b = object(f, "RemoteEvent", "A"), object(f, "RemoteEvent", "B"); local ia, ib = refs.id(a), refs.id(b)
	assert(explorer.select({ ia, ib }, "replace", nil, { primaryId = ia }))
	local snapshot = explorer.state()
	check("selected remote uses primary rather than the last selected ID", targets.resolve("Selected remote", nil, snapshot).ids[1] == ia)
	check("selected subtree is rooted at the primary only", targets.resolve("Selected subtree", nil, snapshot).rootId == ia)
	assert(explorer.select({ ib })); check("stale scope cannot retarget silently", not targets.resolve("Selected remote", nil, snapshot) and not targets.resolve("Explorer selection", nil, snapshot))
	check("a separately displayed remote is an explicit target", targets.resolve("Selected remote", ia, snapshot).ids[1] == ia)
	f.healthy(); f.close()
end)

case("late pinned completions enforce bytes and Stop prevents further updates", function()
	local f = F.new(); local records, values = f.env.require("runtime/remote_store"), f.env.require("runtime/values")
	local remote = object(f, "RemoteFunction", "Late")
	records.limits.records, records.limits.pinBytes = 1, 1800
	local token = records.begin(meta(f, remote), values.pack()); assert(records.pin(token.id))
	local nextMeta = meta(f, remote); nextMeta.outcome = "forwarded"; records.begin(nextMeta, values.pack("new"))
	check("pinned pending records survive ring eviction", records.get(token.id) ~= nil)
	records.finish(token, "returned", values.pack(string.rep("r", 3000)))
	check("late completion cannot overflow the pin budget", records.state().pinBytes <= records.limits.pinBytes and records.get(token.id) == nil)
	local pending = records.begin(meta(f, remote), values.pack()); records.stopPending(); local stopped = records.get(pending.id)
	records.finish(pending, "returned", values.pack("late after Stop"))
	check("Stop invalidates pending completion acceptance", records.get(pending.id).revision == stopped.revision and records.get(pending.id).outcome == "completion_unobserved")
	local retained = records.get(pending.id)
	check("ring accounting includes outcome metadata", records.state().bytes == #f.h.json.encode(retained))
	f.healthy(); f.close()
end)

case("capture export freezes sequences and outcomes before concurrent writes", function()
	local f = F.new(); local records, values, exports = f.env.require("runtime/remote_store"), f.env.require("runtime/values"), f.env.require("runtime/native_exports")
	local remote = object(f, "RemoteFunction", "Export")
	local token = records.begin(meta(f, remote), values.pack(1)); local frozen = assert(records.freeze({ token.id }))
	records.finish(token, "returned", values.pack(2)); records.begin(meta(f, remote), values.pack(3))
	check("frozen export never observes later outcomes or admissions", #frozen.items == 1 and frozen.items[1].outcome == "pending" and frozen.throughSequence == 1)
	check("export pages retain the same sequence boundary", records.exportPage(frozen, 1, 1000).throughSequence == 1)
	local fs = f.env.require("runtime/fsx"); local write = fs.write; local admitted = false
	fs.write = function(path, raw, options) if not admitted then admitted = true; records.begin(meta(f, remote), values.pack(4)) end; return write(path, raw, options) end
	local result = assert(exports.captures(nil, "exports/frozen.json")); local data = f.h.json.decode(assert(fs.readUser(result.path)))
	check("live recording during file writes cannot enter the export", #data.records == 2 and data.throughSequence == 2 and records.state().newest == 3)
	fs.write = write; f.healthy(); f.close()
end)

case("capture reconfiguration failure is explicit and leaves no active behavior", function()
	local f = F.new(); local capture = f.env.require("runtime/remote_capture")
	local remote = object(f, "RemoteEvent", "Reconfigure"); local key = f.env.require("runtime/instance_refs").id(remote)
	assert(capture.start({ mode = "incoming", ids = { key }, persistent = true }))
	local result, why = capture.start({ mode = "outgoing", ids = { key }, backend = "direct", expected_revision = capture.revision })
	check("failed replacement reports loss of the previous capture", not result and has(why, "previous capture was stopped") and capture.status == "faulted")
	check("failure cleans up subscriptions and rules", capture.state().monitored == 0 and #capture.rules == 0)
	f.healthy(); f.close()
end)

case("permission revocation stops agent capture immediately and preserves user observation", function()
	local f = F.new(); f.tools({ "remotes" })
	local sessions, config, capture = f.env.require("agent/session"), f.env.require("runtime/config"), f.env.require("runtime/remote_capture")
	local session = sessions.newThread()
	local started = f.dispatch("remotes_capture", { action = "start", mode = "uai", persistent = true }, { env = f.env, session = session, aborted = function() return false end })
	check("tool-owned capture starts explicitly", started.ok and capture.status == "running")
	config.set("permissions.mode", "readonly")
	check("permission changes revoke capture without waiting for a poll", capture.status == "stopped")
	assert(capture.start({ mode = "uai", persistent = true }, { origin = "user" }))
	config.set("permissions.mode", "full"); config.set("permissions.mode", "readonly")
	check("unrelated revocation preserves user observation", capture.status == "running" and capture.state().owner == "user")
	f.healthy(); f.close()
end)

case("caller-source integration preserves identity and exports likely call sites", function()
	local f = F.ui(500, 350); local records, refs, values = f.env.require("runtime/remote_store"), f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local caller = object(f, "LocalScript", "Caller"); caller.Source = string.rep("-- context\n", 40) .. "local remote = game.Workspace.Ping\nremote:FireServer()"
	local remote = object(f, "RemoteEvent", "Ping"); local captured = meta(f, remote, "incoming")
	captured.pathAtCapture = "game.Workspace.Ping"
	local editor = f.env.require("ui/code/editor").new(f.host)
	captured.caller = { scriptId = refs.id(caller), runtimeEpoch = refs.epoch }; captured.outcome = "received"
	local token = records.begin(captured, values.pack())
	local opened = assert(f.run(function() return f.env.require("tools/source_documents").caller(token.id, { focus = true }) end))
	local record = assert(records.get(token.id)); local store = f.env.require("runtime/code_store")
	check("caller source opens read-only with immutable identity", opened.readOnly and opened.instanceId == refs.id(caller) and store.active().readOnly)
	check("likely call sites and capture provenance stay together", #record.sourceProvenance.callSites == 1 and record.sourceProvenance.callSites[1].line == 41 and records.freeze({ token.id }).items[1].sourceProvenance.sourceHash)
	check("caller path matches are selected in the displayed editor", has(record.sourceProvenance.callSites[1].evidence, "path") and editor.box.Text:sub(editor.box.SelectionStart, editor.box.CursorPosition - 1) == captured.pathAtCapture)
	check("caller-source navigation reveals a match below the viewport", editor.scroll.CanvasPosition.Y > 0)
	local capabilities = records.capabilities(record)
	check("incoming records offer diagnostics and caller actions without replay", capabilities.diagnostic and capabilities.caller and not capabilities.replay and not capabilities.editArguments)
	f.healthy(); editor.destroy(); f.close()
end)

case("portable scripts require current review and preserve exact argument arity", function()
	local f = F.new(); local refs, values, replay = f.env.require("runtime/instance_refs"), f.env.require("runtime/values"), f.env.require("tools/remote_replay")
	local remote = object(f, "RemoteEvent", "Portable"); local calls, received = 0, nil
	remote.FireServer = function(_, ...) calls = calls + 1; received = values.pack(...) end
	local review = assert(replay.reviewSource({ remoteId = refs.id(remote), method = "FireServer", arguments = values.snapshot(values.pack(false, nil, "text", nil)) }))
	check("preparing and reviewing a portable script send no traffic", calls == 0 and replay.reviewedSource(review.id, review.digest) == review.source and not has(review.source, "UAI"))
	check("a different review digest cannot export source", not replay.reviewedSource(review.id, "wrong"))
	local run = assert(require("luau").load(review.source, "portable-fixture", { entry = true })); setfenv(run, f.h.sandbox); run()
	check("explicit execution preserves trailing nil arguments", calls == 1 and received.n == 4 and received[1] == false and received[3] == "text")
	remote.Name = "Renamed"
	check("path changes invalidate reviewed script exports", not replay.reviewedSource(review.id, review.digest))
	f.healthy(); f.close()
end)

case("session logs and stale tool callbacks remain bounded and cancelled", function()
	local f = F.new(); local sessions = f.env.require("agent/session"); local session = sessions.newThread()
	session.emit("user", { text = "Keep this question" })
	for i = 1, 600 do session.emit("tool:progress", { text = string.rep("x", 4000), index = i }) end
	check("retained logs respect both count and byte limits", #session.log <= sessions.limits.events and session.logBytes <= sessions.limits.transcriptBytes)
	check("transient progress cannot evict the durable conversation", #session.log == 1 and session.log[1].text == "Keep this question")
	for i = 1, 600 do session.emit("tool:result", { text = string.rep("x", 4000), index = i }) end
	check("durable events also respect retention limits", #session.log <= sessions.limits.events and session.logBytes <= sessions.limits.transcriptBytes)
	local ctx = session.toolContext(); session.abort()
	check("idle Stop invalidates old contexts without blocking new work", ctx.aborted() and not session.toolContext().aborted())
	local count = #session.log; ctx.progress("stale output"); ctx.emit("assistant:text", "stale callback")
	check("old contexts cannot publish into the next turn", ctx.aborted() and #session.log == count)
	sessions.remove(session.id); session.emit("assistant:text", { text = "removed" })
	check("removed sessions cannot publish events", #session.log == count)
	f.healthy(); f.close()
end)

case("thread restoration chooses recent history and preserves unsaved overflow", function()
	local f = F.new(); local sessions, fs = f.env.require("agent/session"), f.env.require("runtime/fsx")
	for i = 1, 70 do
		local id = string.format("fixture-%03d", i)
		assert(fs.writeJson("sessions/" .. id .. ".json", { id = id, title = "History " .. i, updatedAt = i, createdAt = i,
			context = { messages = { { role = "user", content = "Question " .. i } } } }))
	end
	check("restore loads only the 64 most recent conversations", sessions.restore() == 64 and #sessions.list() == 64 and sessions.current().id == "fixture-070")
	check("older disk history survives memory limits", sessions.threads["fixture-001"] == nil and sessions.threads["fixture-007"] ~= nil and fs.read("sessions/fixture-001.json") ~= nil)
	check("repeated restore cannot add duplicate threads", sessions.restore() == 0 and #sessions.list() == 64)
	fs.enabled = false
	local first = sessions.threads["fixture-007"]
	for i = 1, 3 do sessions.newThread() end
	check("the retention target never discards unwritten conversations", sessions.threads[first.id] == first and #sessions.list() == 67 and not first.removed)
	f.healthy(); f.close()
end)

case("clearing a conversation stops only its own child agents", function()
	local f = F.new(); local sessions, children = f.env.require("agent/session"), f.env.require("agent/subagent")
	local first, other = sessions.newThread(), sessions.newThread()
	local child, unrelated = sessions.create({ headless = true }), sessions.create({ headless = true })
	children.records = {
		{ id = "owned", label = "Owned child", parent = first, session = child, status = "running" },
		{ id = "other", label = "Other child", parent = other, session = unrelated, status = "running" },
	}
	first.clear()
	check("the cleared conversation's child is cancelled", children.records[1].stopRequested and child.aborted())
	check("the other conversation and child remain available", not children.records[2].stopRequested and not unrelated.aborted() and not other.aborted())
	f.healthy(); f.close()
end)

case("stopped subagents can resume and queued follow-ups stay cancellable", function()
	local f = F.new(); local sessions, children = f.env.require("agent/session"), f.env.require("agent/subagent")
	f.env.require("runtime/config").set("agent.subagentConcurrency", 1)
	local parent, calls, first, queued = sessions.newThread(), 0, nil, nil
	f.env.require("agent/loop").run = function(child, task)
		calls = calls + 1; child.ctx.pushUser(task)
		if task == "first" then f.h.sched.wait(0.1) elseif task == "blocker" then f.h.sched.wait(0.5) end
		return "Completed " .. task
	end
	f.h.sched.spawn(function() first = children.dispatch({ parent = parent, task = "first" }) end)
	local record = children.records[1]; assert(children.stop(record.id)); f.h.sched.advance(0.2)
	check("a stop stays recorded even when the worker returns normally", first.aborted and record.status == "stopped")
	f.h.sched.spawn(function() children.dispatch({ parent = parent, task = "blocker" }) end)
	f.h.sched.spawn(function()
		local result, why = children.followUp({ id = record.id, parent = parent, task = "queued follow-up" })
		queued = { result = result, why = why }
	end)
	check("a fresh follow-up clears the previous stop and registers its queue wait", record.status == "queued" and not record.stopRequested)
	local duplicate, why = children.followUp({ id = record.id, task = "duplicate" })
	check("a queued follow-up cannot be started twice", not duplicate and has(why, "still working"))
	assert(children.stop(record.id)); f.h.sched.advance(0.21)
	check("queued follow-ups stop before dispatching another model turn", queued and not queued.result and has(queued.why, "stopped") and calls == 2 and record.status == "stopped" and not record.stopping)
	f.h.sched.advance(0.4)
	local resumed = assert(f.run(function() return children.followUp({ id = record.id, parent = parent, task = "resume" }) end))
	check("a later successful follow-up is reported as done", not resumed.aborted and record.status == "done" and calls == 3 and children.live == 0)
	f.env.require("agent/loop").run = function() f.h.sched.wait(0.1); error("fixture worker failure") end
	local failure
	f.h.sched.spawn(function() local result, why = children.followUp({ id = record.id, parent = parent, task = "failure" }); failure = { result = result, why = why } end)
	assert(children.stop(record.id)); f.h.sched.advance(0.2)
	check("a failed worker also clears its pending Stop label and releases capacity", failure and not failure.result and has(failure.why, "failed") and record.status == "failed" and not record.stopping and children.live == 0)
	f.healthy(); f.close()
end)

case("subagent settings control concurrency and unlimited queue budgets", function()
	local f = F.new(); local config, children = f.env.require("runtime/config"), f.env.require("agent/subagent")
	check("the default concurrency matches the configured maximum", children.concurrencyLimit() == config.get("agent.subagentConcurrency") and children.concurrencyLimit() == 12)
	config.set("agent.subagentConcurrency", 99)
	check("excessive concurrency remains bounded", children.concurrencyLimit() == 12)
	config.set("agent.subagentConcurrency", 1.9)
	check("fractional concurrency cannot admit an extra worker", children.concurrencyLimit() == 1)
	config.set("agent.subagentBudget", 15); config.set("agent.subagentUnlimited", true)
	local parent, result = f.env.require("agent/session").newThread(), nil
	f.env.require("agent/loop").run = function(child, task)
		child.ctx.pushUser(task)
		if task == "blocker" then f.h.sched.wait(5) end
		return "Completed " .. task
	end
	f.h.sched.spawn(function() children.dispatch({ parent = parent, task = "blocker" }) end)
	f.h.sched.spawn(function() result = children.dispatch({ parent = parent, task = "queued" }) end)
	local record = assert(children.find("queued"))
	f.h.sched.advance(4.1)
	check("unlimited queueing outlasts the disabled finite budget", not result and record.status == "queued" and children.live == 1)
	f.h.sched.advance(1.2)
	check("the unlimited worker runs after capacity is released without a finite budget", result and not result.aborted and record.status == "done" and record.budget == nil and record.session.budgetSeconds == nil and children.live == 0)
	config.set("agent.subagentUnlimited", false)
	local limited = assert(f.run(function() return children.followUp({ id = record.id, parent = parent, task = "limited" }) end))
	check("the next run picks up the enabled finite budget", not limited.aborted and record.budget == 15 and not record.unlimited and record.session.budgetSeconds == 15)
	f.healthy(); f.close()
end)

case("workspace runs reject repeated dispatch and newly immutable sources", function()
	local f = F.new(); local store, execution = f.env.require("runtime/code_store"), f.env.require("tools/execution"); store.init()
	local runs = 0; execution.run = function() runs = runs + 1; return { ok = true, text = "done", data = { status = "completed" } } end
	local runner = f.env.require("tools/code_runner")
	local snapshot = assert(runner.snapshot(store.activeId()))
	check("one snapshot can dispatch only once", runner.run(snapshot).ok and not runner.run(snapshot).ok and runs == 1)
	local pending = assert(runner.snapshot(store.activeId()))
	local source = assert(f.env.require("runtime/script_sources").keep(store.active().source, "fixture", "Readonly.lua", nil, { method = "decompiled" }))
	assert(store.attachSource(store.activeId(), source))
	check("read-only protection is rechecked at dispatch", not runner.run(pending).ok and runs == 1)
	f.healthy(); f.close()
end)

case("library removal requires a current confirmation", function()
	local f = F.ui(500, 350); local store, overlay = f.env.require("runtime/code_store"), f.env.require("ui/overlay")
	local doc, review = store.active(), nil
	overlay.confirm = function(options) review = options end
	local library = f.env.require("ui/code/library").new(f.host, function() end)
	library.list.rows[1].closeSlot.Activated:Fire()
	check("the remove control first presents the exact entry", review and store.resolve(doc.id) ~= nil and has(review.title, doc.name))
	assert(store.update(doc.id, "return 'changed since review'"))
	review.onConfirm()
	check("a stale confirmation preserves newly edited source", store.resolve(doc.id) ~= nil)
	library.list.rows[1].closeSlot.Activated:Fire(); review.onConfirm()
	check("a current explicit confirmation removes the entry", store.resolve(doc.id) == nil)
	f.healthy(); library.destroy(); f.close()
end)

case("live response previews are bounded, coalesced and cancelled", function()
	local f = F.new(); local session = f.env.require("agent/session").newThread()
	local stream, util = f.env.require("agent/stream"), f.env.require("runtime/util")
	local events, cancelled = {}, false
	session.events:connect(function(event) if event.kind == "assistant:preview" then events[#events + 1] = event end end)
	local preview = stream.new(session, "fixture", function() return cancelled end)
	preview.feed({ model = "served-fixture", choices = { { delta = { reasoning_content = "Checking." } } } })
	check("the first received frame appears immediately", #events == 1 and events[1].reasoning == "Checking.")
	check("live attribution follows the model reported by the stream", events[1].model == "served-fixture")
	for i = 1, 30 do preview.feed({ choices = { { delta = { content = "你🙂" } } } }) end
	check("bursts do not redraw for every token", #events == 1)
	f.h.sched.advance(0.11)
	check("the queued preview preserves received text order", #events == 2 and events[2].text == string.rep("你🙂", 30))
	preview.feed({ choices = { { delta = { content = string.rep("你🙂", 12000) } } } }); f.h.sched.advance(0.11)
	check("live preview size is bounded without cutting UTF-8", #session.livePreview.text <= stream.previewBytes and session.livePreview.limited and util.validUtf8(session.livePreview.text))
	local retained = session.livePreview.text
	preview.feed({ choices = { { delta = { content = "x" } } } }); f.h.sched.advance(0.11)
	check("later frames cannot splice new text into a truncated prefix", session.livePreview.text == retained)
	preview.feed({ choices = { { delta = { reasoning_content = "More" } } } })
	local count = #events; preview.feed({ choices = { { delta = { reasoning_content = "pending" } } } }); cancelled = true; preview.close(); f.h.sched.advance(0.2)
	check("closed/cancelled previews cannot publish queued frames", #events == count)
	check("transient frames never evict durable transcript entries", #session.log == 0)
	f.healthy(); f.close()
end)

case("the agent forwards real frames before committing one final reply", function()
	local f = F.new(); local sessions, providers = f.env.require("agent/session"), f.env.require("provider/registry")
	local record = { id = "fixture", label = "Fixture", model = "fixture-model" }
	providers.active = function() return record end; providers.chain = function() return { record } end
	local callback
	f.env.require("provider/chat").complete = function(_, request)
		callback = request.onFrame
		callback({ choices = { { delta = { reasoning_content = "Checked." } } } })
		f.h.sched.wait(0.15)
		callback({ choices = { { delta = { content = "Done." } } } })
		return { content = "Done.", reasoning = "Checked.", toolCalls = {}, finish = "stop" }
	end
	local session = sessions.newThread(); session.systemPrompt, session.toolFilter = "Fixture instructions", {}
	assert(session.send("Check the fixture")); f.h.sched.advance(0.02)
	check("in-flight reasoning reaches the session while the request is pending", session.busy and session.livePreview and session.livePreview.reasoning == "Checked.")
	f.h.sched.advance(0.3)
	local textCount, thoughtCount = 0, 0
	for _, event in ipairs(session.log) do
		if event.kind == "assistant:text" then
			textCount = textCount + 1
			check("responses without a model retain the dispatched model", event.model == record.model)
		end
		if event.kind == "assistant:reasoning" then thoughtCount = thoughtCount + 1 end
	end
	check("only the completed reply and reasoning are retained", not session.busy and not session.livePreview and textCount == 1 and thoughtCount == 1)
	callback({ choices = { { delta = { content = "late" } } } }); f.h.sched.advance(0.2)
	check("late frames cannot revive a completed preview", session.livePreview == nil)
	f.healthy(); f.close()
end)

case("native HTTP timeouts never dispatch a retry or accept a late result", function()
	local f = F.new(); local calls = 0; local caps = f.env.require("runtime/caps")
	caps.fn.request = function() calls = calls + 1; f.h.sched.wait(2); return { StatusCode = 200, Body = "{}", Headers = { ok = "true" } } end
	local http = f.env.require("net/http")
	local response, why = f.run(function() return http.send({ url = "https://fixture.test/timeout", timeout = 1, attempts = 3 }) end, 1.2)
	check("timeout is terminal and dispatches once", not response and http.terminal(why) and calls == 1 and http.workers() == 1)
	f.h.sched.advance(1.2)
	check("late host completion cannot replace the reported outcome", http.workers() == 0 and #http.history == 1 and has(http.history[1].error, "deadline"))
	caps.fn.request = function() return { StatusCode = 200, Body = {}, Headers = { ok = "true" } } end
	local malformed, message = f.run(function() return http.request({ url = "https://fixture.test/malformed" }) end)
	check("non-text bodies fail consistently", not malformed and http.terminal(message))
	f.healthy(); f.close()
end)

case("retry callbacks cannot break native HTTP cleanup or valid retry responses", function()
	local f = F.new(); local calls, retries = 0, 0
	f.env.require("runtime/caps").fn.request = function()
		calls = calls + 1
		return { StatusCode = calls == 1 and 429 or 200, Body = "{}", Headers = { ["Retry-After"] = "0.01" } }
	end
	local http = f.env.require("net/http")
	local response = f.run(function() return http.send({ url = "https://fixture.test/retry", attempts = 2, onRetry = function() retries = retries + 1; error("fixture callback failure") end }) end)
	check("callback failure cannot discard a valid response", response and response.ok and calls == 2 and retries == 1 and http.workers() == 0)
	f.healthy(); f.close()
end)

case("SSE parsers reject malformed and over-budget streams consistently", function()
	local f = F.new(); local sse = f.env.require("net/sse")
	local malformed = sse.parse("data: not JSON\n\ndata: [DONE]\n\n")
	check("invalid JSON is not a successful empty stream", has(malformed.streamError, "malformed_stream:"))
	local part = f.h.json.encode({ choices = { { delta = { content = "partial" } } } })
	check("unterminated streams do not silently succeed", has(sse.parse("data: " .. part .. "\n\n").streamError, "before completion"))
	local assembled = sse.assembler(); check("malformed chunks cannot escape as exceptions", not assembled.feedChunk({ choices = "wrong" }) and has(assembled.result().streamError, "malformed_stream:"))
	sse.limits.frame = 30
	local frames, why = sse.frames("data: " .. string.rep("x", 31) .. "\n\n")
	check("frame size is bounded", #frames == 0 and has(why, "malformed_stream:"))
	local anthropic = f.env.require("provider/anthropic")
	check("both provider parsers propagate framing errors", has(anthropic.parseStream("data: " .. string.rep("x", 31) .. "\n\n").streamError, "malformed_stream:"))
	f.healthy(); f.close()
end)

case("native sockets bound established connections and disconnect every callback", function()
	local f = F.new(); local signal = require("instance").newSignal
	local sockets, closed, frames, results = {}, 0, 0, {}
	f.env.require("runtime/caps").fn.websocket = function()
		local socket = { OnMessage = signal("message"), OnClose = signal("close") }
		socket.Send = function() end; socket.Close = function() closed = closed + 1 end
		sockets[#sockets + 1] = socket; return socket
	end
	local ws = f.env.require("net/ws")
	for i = 1, 5 do f.h.sched.spawn(function() local body, why = ws.stream({ url = "wss://fixture.test", timeout = 1, onFrame = function() frames = frames + 1 end }); results[i] = { body = body, why = why } end) end
	check("established sockets consume the connection budget", #sockets == 4 and ws.state().connections == 4 and has(results[5].why, "limit"))
	local payload = f.h.json.encode({ choices = { { delta = { content = "ok" }, finish_reason = "stop" } } })
	for _, socket in ipairs(sockets) do socket.OnMessage:Fire(payload); socket.OnMessage:Fire("[DONE]") end
	f.h.sched.advance(0.1)
	check("completion closes every socket", closed == 4 and ws.state().connections == 0 and results[1].body and frames == 4)
	sockets[1].OnMessage:Fire(payload); check("late socket callbacks are disconnected", frames == 4)
	f.healthy(); f.close()
end)

case("signals and disposer continue cleanup after errors and suppress recursion", function()
	local f = F.new(); local signals, dispose = f.env.require("runtime/signal"), f.env.require("runtime/dispose")
	local signal = signals.new("fixture"); local events = 0
	signal:connect(function() events = events + 1; signal:fire() end); signal:fire()
	check("recursive event dispatch has a finite bound", events == 32 and signal.dropped == 1)
	signal:clear(); check("clear releases every subscriber", signal:count() == 0 and #signal.handlers == 0)
	local cleaned = 0; dispose.add(function() cleaned = cleaned + 1 end, "successful cleanup")
	dispose.add(function() error("fixture failure") end, "failing cleanup")
	local _, failures = dispose.drain()
	check("cleanup continues after one disposer fails", cleaned == 1 and #failures == 1 and dispose.count() == 0 and dispose.drain() == 0)
	f.healthy()
end)

suite.finish()
