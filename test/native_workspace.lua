package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("workspace_fixture")
local suite = F.suite("Native workspace")
local case, check = suite.case, suite.check
local function object(f, class, name, parent)
	local item = f.h.Instance.new(class); item.Name, item.Parent = name or class, parent or f.h.workspace; return item
end
local function event(f, class, name)
	local item = object(f, class or "RemoteEvent", name or "FixtureRemote")
	item.OnClientEvent = require("instance").newSignal("OnClientEvent")
	return item
end

case("native module/schema discovery is inert", function()
	local f = F.new(); local hooks, calls = 0, 0
	f.h.sandbox.hookfunction = function() hooks = hooks + 1 end
	f.h.sandbox.hookmetamethod = function() hooks = hooks + 1 end
	f.h.sandbox.getnamecallmethod = function() return "FireServer" end
	f.h.sandbox.getnilinstances = function() calls = calls + 1; return {} end
	for _, group in ipairs({ "coding", "instance", "remotes", "script" }) do f.env.require("tools/" .. group) end
	local capture = f.env.require("runtime/remote_capture")
	check("discovery leaves capture idle", capture.status == "idle" and capture.state().monitored == 0)
	check("no hooks or discovery scan", hooks == 0 and calls == 0)
	check("no module-load filesystem writes", next(f.h.files) == nil)
	f.close()
end)

case("exact handles survive rename/move and refuse replacement targets", function()
	local f = F.new(); local refs, paths = f.env.require("runtime/instance_refs"), f.env.require("runtime/instance_paths")
	local a, b = object(f, "Part", "Duplicate"), object(f, "Part", "Duplicate")
	local ia, ib = refs.id(a), refs.id(b)
	check("duplicates have distinct IDs", ia ~= ib and refs.resolve(ib) == b)
	check("ambiguous path refuses silent first child", not paths.resolve("Workspace.Duplicate"))
	b.Name = "Renamed"; local folder = object(f, "Folder", "Folder"); b.Parent = folder
	check("renaming/moving preserves ID", refs.id(b) == ib and refs.resolve(ib) == b)
	b.Parent = nil; check("observed detached object remains usable", refs.resolve(ib) == b)
	b:Destroy(); local replacement = object(f, "Part", "Renamed", folder)
	check("destroyed handle does not select replacement", not refs.resolve(ib) and refs.id(replacement) ~= ib)
	check("mixed selectors rejected", not refs.select({ instance_id = ia, path = "Workspace.Duplicate" }))
	check("other epoch rejected", not refs.resolve("inst:old:1"))
	-- Observation limits must not recycle a still-live object's identity.
	for i = 1, 2060 do refs.id(object(f, "Folder", "Node" .. i)) end
	check("identity survives observer eviction", refs.id(a) == ia)
	f.healthy(); f.close()
end)

case("typed graphs preserve nil arity, aliases and binary bytes", function()
	local f = F.new(); local values = f.env.require("runtime/values")
	local packed = values.pack(false, nil, "hello", nil); local graph = values.snapshot(packed)
	local restored = assert(values.decode(graph))
	check("exact four slots", graph.count == 4 and #graph.slots == 4 and restored.n == 4 and restored[1] == false and restored[2] == nil and restored[4] == nil)
	check("zero differs from nil", values.snapshot(values.pack()).count == 0 and values.snapshot(values.pack(nil)).count == 1)
	local shared = { x = 1 }; local aliases = assert(values.decode(values.snapshot(values.pack(shared, shared))))
	check("shared table alias retained", aliases[1] == aliases[2])
	local binary = "a\0\255\1289"; local bytes = values.snapshot(values.pack(binary))
	check("binary encoding is lossless", bytes.slots[1].encoding == "hex" and assert(values.decode(bytes))[1] == binary)
	local part = object(f, "Part", "Reference"); local typed = assert(values.decode(values.snapshot(values.pack(part, f.h.dt.Vector3.new(1, 2, 3), f.h.dt.UDim2.new(0.5, 7, 1, 9)))))
	check("typed instance and compounds", typed[1] == part and typed[2].Y == 2 and typed[3].X.Offset == 7)
	local special = values.snapshot(values.pack(0 / 0, math.huge)); check("nonfinite inspectable but not sent", special.slots[1].special == "nan" and not values.decode(special))
	f.close()
end)

case("unsafe or malformed graphs remain inspectable but never replay", function()
	local f = F.new(); local values = f.env.require("runtime/values")
	local count = 0; local hostile = setmetatable({ safe = 1 }, { __index = function() count = count + 1; error("index") end, __pairs = function() count = count + 1; error("pairs") end, __tostring = function() count = count + 1; error("tostring") end })
	check("snapshot never invokes table metamethods", values.snapshot(values.pack(hostile)).complete and count == 0)
	local cyclic = {}; cyclic.self = cyclic; local cycle = values.snapshot(values.pack(cyclic))
	check("cycles are inspectable", cycle.complete and #cycle.nodes == 1 and not values.decode(cycle))
	check("sparse tables are not replayed", not values.decode(values.snapshot(values.pack({ [1] = 1, [3] = 3 }))))
	check("mixed tables are not replayed", not values.decode(values.snapshot(values.pack({ [1] = 1, field = 2 }))))
	check("opaque functions are not replayed", not values.decode(values.snapshot(values.pack(function() end))))
	local huge = values.snapshot(values.pack(string.rep("x", 20000)))
	check("oversize strings have explicit truncation", not huge.complete and huge.slots[1].length == 20000 and huge.slots[1].truncated and not values.decode(huge))
	local malformed = { count = 1, slots = { { kind = "table", node = 99 } }, nodes = {}, complete = true }
	check("dangling references refused", not values.validateGraph(malformed) and not values.decode(malformed))
	check("bad encoding refused", not values.decode({ count = 1, slots = { { kind = "string", encoding = "hex", value = "zz", length = 1 } }, nodes = {} }))
	f.close()
end)

case("typed edits preflight every field and Undo uses actual readback", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local edits, history = f.env.require("runtime/instance_edits"), f.env.require("runtime/changes")
	local part = object(f, "Part", "Before"); local id = refs.id(part); part.Transparency = 0
	local batch = { { instanceId = id, kind = "property", key = "Name", expected = values.node("Before"), value = values.node("After") }, { instanceId = id, kind = "attribute", key = "Flag", expected = values.node(nil), value = values.node(false) } }
	local result = edits.apply(batch); check("batch readback recorded", result.ok and result.batchId and part.Name == "After" and part:GetAttribute("Flag") == false)
	part:SetAttribute("Flag", true); local conflict = history.undo(result.batchId)
	check("Undo preflights all before writing", not conflict.ok and conflict.status == "conflict" and part.Name == "After")
	part:SetAttribute("Flag", false); assert(history.undo(result.batchId).ok)
	check("Undo restores exact absent attribute", part.Name == "Before" and part:GetAttribute("Flag") == nil)
	local stale = edits.apply({ batch[1], { instanceId = id, key = "Transparency", expected = values.node(0.8), value = values.node(0.2) } })
	check("later stale field prevents earlier write", not stale.ok and part.Name == "Before")
	local tagged = edits.apply({ { instanceId = id, kind = "tag", key = "Exact tag", expected = values.node(false), value = values.node(true) } })
	check("tag changes outside Undo", tagged.ok and not tagged.batchId and part:HasTag("Exact tag"))
	assert(edits.apply({ { instanceId = id, kind = "tag", key = "Exact tag", expected = values.node(true), value = values.node(false) } }).ok)
	check("explicit false removes tag", not part:HasTag("Exact tag"))
	f.healthy(); f.close()
end)

case("partial writes recover conditionally and retain uncertain effects", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local fields, edits = f.env.require("runtime/instance_fields"), f.env.require("runtime/instance_edits")
	local part = object(f, "Part", "Before"); part.Transparency = 0; local id = refs.id(part)
	local originalRead, originalWrite = fields.read, fields.write
	fields.write = function(target, kind, key, value) if key == "Transparency" then return false, "fixture refusal" end; return originalWrite(target, kind, key, value) end
	local result = edits.apply({ { instanceId = id, key = "Name", expected = values.node("Before"), value = values.node("After") }, { instanceId = id, key = "Transparency", expected = values.node(0), value = values.node(0.5) } })
	check("earlier field conditionally recovered", not result.ok and part.Name == "Before" and #result.recovered == 1 and result.changedCount == 0)
	fields.write = function(target, kind, key, value) local ok, why = originalWrite(target, kind, key, value); fields.read = function() return false, "readback unavailable" end; return ok, why end
	result = edits.apply({ { instanceId = id, key = "Name", expected = values.node("Before"), value = values.node("Uncertain") } })
	check("successful write with unreadable outcome is reported uncertain", not result.ok and result.status == "partial" and result.uncertain and #result.uncertain == 1 and part.Name == "Uncertain")
	check("unknown outcome is not counted as zero or offered Undo", result.changedCount == nil and result.batchId and f.env.require("runtime/changes").undo(result.batchId).status == "partial")
	local recorded = f.env.require("runtime/changes").list()[1]
	check("uncertainty remains inspectable in history", recorded.status == "partial" and recorded.records[1].uncertain and recorded.records[1].after == nil)
	fields.read, fields.write = originalRead, originalWrite; f.close()
end)

case("hierarchy cycle/parent checks and overlapping deletes", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local edits = f.env.require("runtime/instance_edits")
	local folder = object(f, "Folder", "Outer"); local child = object(f, "Folder", "Inner", folder)
	local id, childId = refs.id(folder), refs.id(child)
	check("cycle rejected", not edits.hierarchy("reparent", { instanceId = id, parentId = childId, expectedParent = values.node(f.h.workspace) }).ok)
	check("stale parent rejected", not edits.hierarchy("detach", { instanceId = childId, expectedParent = values.node(f.h.workspace) }).ok)
	local copy = edits.hierarchy("duplicate", { instanceId = childId, parentId = refs.id(f.h.workspace) })
	check("clone gets a distinct live identity", copy.ok and copy.item.instanceId ~= childId)
	local result = edits.hierarchyMany("delete", { id, childId }, {})
	check("overlapping selection deletes once", result.ok and #result.outcomes == 1 and not refs.resolve(childId))
	f.healthy(); f.close()
end)

case("Explorer snapshots, selection, branch/filter cursor invalidation", function()
	local f = F.new(); local refs, explorer = f.env.require("runtime/instance_refs"), f.env.require("runtime/explorer")
	local root = object(f, "Folder", "Root"); for i = 1, 20 do object(f, "Part", "Part" .. i, root) end
	local first = assert(explorer.children(refs.id(root), nil, 3)); local second = assert(explorer.children(refs.id(root), first.nextCursor, 3))
	check("child pagination preserves items", #first.items == 3 and #second.items == 3 and first.items[1].instanceId ~= second.items[1].instanceId)
	object(f, "Part", "New", root); check("changed branch invalidates cursor", not explorer.children(refs.id(root), first.nextCursor, 3))
	local query = assert(explorer.query({ rootId = refs.id(root), name = "Part", limit = 3 }))
	check("changed query cannot reuse cursor", not explorer.query({ rootId = refs.id(root), name = "New", cursor = query.nextCursor, limit = 3 }))
	assert(explorer.query({ rootId = refs.id(root), name = "Part", cursor = query.nextCursor, limit = 3 }))
	assert(explorer.select({ first.items[1].instanceId, first.items[2].instanceId }))
	local props = assert(explorer.properties(nil, "properties", { "Name" }))
	check("multi-selection reports mixed and guarded snapshot", props.items[1].mixed and props.snapshotId and explorer.expected(props.snapshotId, first.items[1].instanceId, "property", "Name"))
	explorer.collapse(refs.id(root)); check("collapse releases direct-child listener", root.ChildAdded:Count() == 0)
	f.healthy(); f.close()
end)

case("explicit incoming capture, pause/clear/stop and lifetime", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local capture, records = f.env.require("runtime/remote_capture"), f.env.require("runtime/remote_store")
	local remote = event(f); local state = assert(capture.start({ mode = "incoming", ids = { refs.id(remote) }, duration = 1 }))
	check("one owned subscription", state.monitored == 1 and remote.OnClientEvent:Count() == 1)
	remote.OnClientEvent:Fire(false, nil, "payload", nil)
	local page = assert(records.page({ limit = 5 })); local record = assert(records.get(page.items[1].id))
	check("incoming argument arity preserved", record.arguments.count == 4 and record.outcome == "received")
	assert(capture.control("pause", capture.sessionId, capture.revision)); remote.OnClientEvent:Fire("ignored")
	check("pause preserves buffer", records.state().retained == 1)
	assert(capture.control("clear", capture.sessionId, capture.revision)); check("clear keeps pause/subscription", capture.status == "paused" and records.state().retained == 0 and remote.OnClientEvent:Count() == 1)
	assert(capture.control("resume", capture.sessionId, capture.revision)); f.h.sched.advance(1.1)
	check("duration releases subscription", capture.status == "stopped" and remote.OnClientEvent:Count() == 0)
	assert(capture.start({ mode = "incoming", ids = { refs.id(remote) }, persistent = true })); remote:Destroy()
	check("destroyed remote disconnects", capture.state().monitored == 0)
	f.close()
end)

case("capture eviction gaps, frozen drafts, filters and UTF-8 byte reads", function()
	local f = F.new(); local records, values = f.env.require("runtime/remote_store"), f.env.require("runtime/values")
	records.limits.records = 3
	local meta = { sessionId = "fixture", remoteId = "diagnostic", name = "Remote", direction = "outgoing", method = "InvokeServer", origin = "uai" }
	local first = records.begin(meta, values.pack("frozen")); assert(records.pin(first.id)); local draft = assert(records.get(first.id))
	records.finish(first, "returned", values.pack(false, nil))
	check("draft snapshot is unchanged by completion", draft.outcome == "pending" and records.get(first.id).revision == 2)
	for i = 1, 7 do records.begin(meta, values.pack(i)) end
	local page = assert(records.page({ after_sequence = 1, origin = "uai", limit = 1 }))
	check("ring eviction gap is explicit", page.gap and page.gap.first == 2 and page.gap.last >= 4 and records.state().counters.evicted > 0)
	check("cursor binds view filters", not records.page({ cursor = page.nextCursor, origin = "game", limit = 1 }))
	check("pinned record survives ring eviction", records.get(first.id) ~= nil)
	local text = "héllo"; local token = records.begin(meta, values.pack(text))
	local bytes = assert(records.readBytes({ record_id = token.id, section = "arguments", index = 1, byte_offset = 2, byte_limit = 2 }))
	check("UTF-8 reads respect boundaries", bytes.value == "é" and bytes.nextByteOffset == 4)
	check("inside UTF-8 sequence rejected", not records.readBytes({ record_id = token.id, section = "arguments", index = 1, byte_offset = 3 }))
	records.clear(); check("clear invalidates all pins", not records.get(first.id))
	f.close()
end)

case("managed replay is compiler independent, exact, one-shot and outstanding", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local capture, transport, replay = f.env.require("runtime/remote_capture"), f.env.require("tools/remote_transport"), f.env.require("tools/remote_replay")
	local remote = event(f, "RemoteFunction"); local calls, received = 0
	remote.InvokeServer = function(self, ...) calls = calls + 1; received = values.pack(...); return false, nil, 7, nil end
	f.env.require("runtime/caps").exec = false
	assert(capture.start({ mode = "uai", persistent = true }))
	local plan = assert(replay.prepare({ remoteId = refs.id(remote), method = "InvokeServer", arguments = values.snapshot(values.pack(false, nil, "text", nil)) }))
	check("preparation sends nothing", calls == 0)
	local result = f.run(function() return replay.run(plan.id, plan.digest) end)
	check("exact args and return arity without compiler", result.ok and calls == 1 and received.n == 4 and result.results.count == 4)
	assert(replay.run(plan.id, plan.digest).ok); check("repeat plan never redispatches", calls == 1)
	local fresh = assert(replay.prepare({ remoteId = refs.id(remote), method = "InvokeServer", arguments = values.snapshot(values.pack()) }))
	check("cancel before dispatch sends nothing", not replay.run(fresh.id, fresh.digest, { aborted = function() return true end }).ok and calls == 1)
	remote.InvokeServer = function() calls = calls + 1; f.h.sched.wait(3); return "late" end
	local slow = assert(replay.prepare({ remoteId = refs.id(remote), method = "InvokeServer", arguments = values.snapshot(values.pack()) }))
	result = f.run(function() return replay.run(slow.id, slow.digest, nil, 1) end, 1.2)
	check("timeout remains outstanding", not result.ok and result.data.status == "outstanding" and result.data.dispatched and calls == 2)
	replay.run(slow.id, slow.digest); f.h.sched.advance(3)
	check("late completion does not retry", calls == 2)
	check("legacy omitted arguments means zero", transport.arguments({}).n == 0 and not transport.arguments({ args = {}, arguments = values.snapshot(values.pack()) }))
	f.healthy(); f.close()
end)

case("capture export/import is verified, offline and explicitly rebound", function()
	local f = F.new(); local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local records, exports, replay = f.env.require("runtime/remote_store"), f.env.require("runtime/native_exports"), f.env.require("tools/remote_replay")
	local remote = event(f); local token = records.begin({ sessionId = "fixture", remoteId = refs.id(remote), name = remote.Name, className = "RemoteEvent", direction = "outgoing", method = "FireServer", origin = "uai", outcome = "forwarded" }, values.pack(7))
	local exported = assert(exports.captures({ token.id }, "exports/fixture.json"))
	check("verified scoped export", exported.verified and exported.path == "files/exports/fixture.json")
	check("existing export not overwritten", not exports.captures({ token.id }, "exports/fixture.json"))
	local count = assert(exports.import(exported.path)); check("one offline import", count == 1)
	local page = assert(records.page({ session_id = records.state().offlineSessionId })); local imported = assert(records.get(page.items[1].id))
	check("import stays offline", imported.offline and not replay.prepare({ recordId = imported.id, recordRevision = imported.revision }))
	check("explicit rebinding can prepare", replay.prepare({ remoteId = refs.id(remote), method = "FireServer", arguments = imported.arguments }) ~= nil)
	local fs = f.env.require("runtime/fsx"); local metadata = assert(exports.explorer({ refs.id(remote) }, { depth = 0 }))
	check("metadata export labels scope", fs.readUser(metadata.path):find('uai%-instance%-metadata') ~= nil)
	f.close()
end)

case("direct hook cells preserve forwarding, arity, errors and reuse", function()
	local f = F.new(); local values = f.env.require("runtime/values"); local calls, installs, seen = 0, 0, 0
	local marker = {}; local received
	local nativeEvent = function(receiver, ...) calls = calls + 1; received = values.pack(...); if receiver.Throw then error(marker, 0) end; return false, nil end
	local nativeInvoke = function(receiver, ...) calls = calls + 1; f.h.sched.wait(0.1); return false, nil, 8, nil end
	local eventCell, invokeCell = nativeEvent, nativeInvoke
	local fire = function(...) return eventCell(...) end; local invoke = function(...) return invokeCell(...) end
	f.h.sandbox.Instance = { new = function(class, parent)
		local item = f.h.Instance.new(class, parent)
		if class == "RemoteFunction" then item.InvokeServer = invoke else item.FireServer = fire end
		return item
	end }
	local caps = f.env.require("runtime/caps")
	caps.fn.hookfunction = function(original, replacement)
		installs = installs + 1
		if original == fire then local prior = eventCell; eventCell = replacement; return prior end
		assert(original == invoke); local prior = invokeCell; invokeCell = replacement; return prior
	end
	local hooks = f.env.require("runtime/remote_hooks")
	local function observe(kind) if kind == "begin" then seen = seen + 1; return {} end end
	assert(hooks.start(observe, nil, "direct"))
	check("shared event methods hooked once and probes send no traffic", installs == 2 and calls == 0)
	local remote = f.h.sandbox.Instance.new("RemoteEvent"); remote.Parent = f.h.workspace
	local result = values.pack(remote:FireServer(false, nil, "a", nil))
	check("predecessor once with exact args and returns", calls == 1 and seen == 1 and received.n == 4 and result.n == 2 and result[1] == false)
	remote.Throw = true; local ok, err = pcall(remote.FireServer, remote, "error")
	check("original error object preserved", not ok and err == marker and calls == 2)
	remote.Throw = false; hooks.stop(); remote:FireServer(1)
	check("stopped cell forwards without observing", calls == 3 and seen == 2)
	assert(hooks.start(observe, nil, "direct")); check("restart adds no wrapper layers", installs == 2)
	local fn = f.h.sandbox.Instance.new("RemoteFunction"); fn.Parent = f.h.workspace
	local returned = f.run(function() return values.pack(fn:InvokeServer(1, nil)) end, 0.2)
	check("unverified invoke stays tail-forwarded and yields", returned.n == 4 and returned[3] == 8)
	hooks.stop(); f.healthy(); f.close()
end)

suite.finish()
