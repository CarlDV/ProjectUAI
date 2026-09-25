-- Work and retention budgets are deterministic; elapsed times are diagnostic only.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Native performance")
local case, check = suite.case, suite.check
local function rows(root, name)
	local count = 0
	for _, node in ipairs(root:GetDescendants()) do if node.Name == name then count = count + 1 end end
	return count
end

case("line insertion reuses shifted syntax while multiline state changes invalidate it", function()
	local f = F.new(); local lexer = f.env.require("runtime/code_lexer")
	local lines = {}; for i = 1, 6000 do lines[i] = "local value" .. i .. " = " .. i end
	local source = table.concat(lines, "\n"); local original = lexer.scan(source)
	local inserted = lexer.scan("-- inserted\n" .. source, original)
	check("inserting one line lexes only that line", inserted.lexed == 1 and inserted.reused == 6000 and inserted.spans[6001] == original.spans[6000])
	check("unchanged source reuses the entire cache", lexer.scan(inserted.source, inserted) == inserted)
	local block = lexer.scan("--[[\ninside\n]]\nreturn 1")
	local changed = lexer.scan("-- plain\ninside\n]]\nreturn 1", block)
	check("changed multiline state invalidates affected lines only", changed.lexed == 3 and changed.reused == 1 and changed.spans[2][1].kind ~= "comment" and changed.spans[4] == block.spans[4])
	print(string.format("metric lexer: %d bytes, %d reused lines, %d newly lexed", #source, inserted.reused, inserted.lexed))
	f.close()
end)

case("typing reuses measurements and scroll rendering retains a bounded row pool", function()
	local f = F.ui(640, 420); local store, P = f.env.require("runtime/code_store"), f.env.require("ui/primitives")
	local lines = {}; for i = 1, 5000 do lines[i] = "local value" .. i .. " = " .. i end
	assert(store.update(store.activeId(), table.concat(lines, "\n")))
	local measure, measured = P.measureText, 0
	P.measureText = function(value, options) measured = measured + 1; return measure(value, options) end
	local editor = f.env.require("ui/code/editor").new(f.host); f.h.sched.advance(0.1)
	local initialMeasures, initialRows = measured, rows(editor.root, "SyntaxLine")
	measured = 0; editor.box.Text = "-- new line\n" .. editor.box.Text; f.h.sched.advance(0.1)
	check("a one-line edit does not remeasure the document", initialMeasures >= 5000 and measured < 30)
	for i = 1, 20 do editor.scroll.CanvasPosition = f.h.sandbox.Vector2.new(0, i * 2300) end
	check("scrolling recycles the visible rows", initialRows > 0 and initialRows <= 160 and rows(editor.root, "SyntaxLine") == initialRows)
	print(string.format("metric editor: %d initial measurements, %d edit/scroll measurements, %d retained rows", initialMeasures, measured, initialRows))
	P.measureText = measure; f.healthy(); editor.destroy(); f.close()
end)

case("typing publishes metadata without deep-copying documents or history", function()
	local f = F.new(); local store, util = f.env.require("runtime/code_store"), f.env.require("runtime/util"); store.init()
	assert(store.update(store.activeId(), "--" .. string.rep("a", 240000)))
	local copy, copies, sourceEvents = util.deepCopy, 0, 0
	util.deepCopy = function(...) copies = copies + 1; return copy(...) end
	local off = store.changed:connect(function(event)
		if event.kind == "source" then sourceEvents = sourceEvents + 1; assert(event.source == nil and event.document == nil and event.revision) end
	end)
	for i = 1, 40 do assert(store.update(store.activeId(), store.active().source .. "a", { origin = "typing" })) end
	check("typing has no full-document deep copy", copies == 0 and sourceEvents == 40)
	check("typing bursts coalesce history checkpoints", #store.active().versions <= 3)
	util.deepCopy = copy; off(); f.healthy(); f.close()
end)

case("long lines and large-source pages bound text measurement and drawing", function()
	local f = F.ui(480, 300); local P, store = f.env.require("ui/primitives"), f.env.require("runtime/code_store")
	local measure, largest = P.measureText, 0
	P.measureText = function(value, options) largest = math.max(largest, #value); return measure(value, options) end
	assert(store.update(store.activeId(), "--" .. string.rep("你", 60000)))
	local editor = f.env.require("ui/code/editor").new(f.host)
	editor.scroll.CanvasPosition = f.h.sandbox.Vector2.new(150000, 0)
	local visibleBytes = 0
	for _, node in ipairs(editor.root:GetDescendants()) do if node.Name == "SyntaxLine" and node.Visible then visibleBytes = math.max(visibleBytes, #node.Text) end end
	check("measurement calls use bounded UTF-8 chunks", largest <= 2051)
	check("horizontal rendering emits a bounded rich-text window", visibleBytes > 0 and visibleBytes < 9000)
	local sources, limits, text = f.env.require("runtime/script_sources"), f.env.require("runtime/code_limits"), f.env.require("runtime/code_text")
	local source = string.rep("你", 650000); local item = assert(sources.keep(source, "performance fixture"))
	local page = assert(sources.read(item.id, 1, 1000000))
	check("near-limit source pages remain bounded and UTF-8 aligned", #page.text <= limits.sourcePage and text.boundary(source, page.nextOffset))
	print(string.format("metric long source: %d source bytes, %d measured bytes per call, %d rendered bytes", #source, largest, visibleBytes))
	P.measureText = measure; f.healthy(); editor.destroy(); f.close()
end)

case("source and capture retention stay within count and byte budgets", function()
	local f = F.new(); local sources, limits = f.env.require("runtime/script_sources"), f.env.require("runtime/code_limits")
	limits.sourceSnapshots, limits.sourceCacheBytes = 3, 10000
	local first = assert(sources.keep(string.rep("a", 4000), "fixture")); local owner = {}; assert(sources.pin(first.id, owner))
	for i = 1, 40 do assert(sources.keep(string.rep(tostring(i % 10), 4000), "fixture")) end
	check("source bytes and count cannot grow with completed requests", sources.state().bytes <= 10000 and sources.state().snapshots <= 3 and sources.get(first.id))
	local records, values = f.env.require("runtime/remote_store"), f.env.require("runtime/values")
	records.limits.records, records.limits.bytes = 30, 16000
	for i = 1, 200 do records.begin({ name = "Synthetic", direction = "incoming", method = "OnClientEvent", outcome = "received" }, values.pack(string.rep("x", 300))) end
	local state = records.state()
	check("capture ring cannot grow with traffic", state.retained <= 30 and state.bytes <= 16000 and state.counters.evicted > 0)
	local page = assert(records.exportPage(assert(records.freeze()), 1, 3))
	check("frozen export pages honor the requested bound", #page.items == 3 and page.nextOffset == 4)
	sources.release(owner); f.healthy(); f.close()
end)

suite.finish()
