-- Source-level regressions for execution, tool dispatch and workspace editing.
-- Uses the real scheduler and executor mocks without mounting the UI.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local luau = require("luau")
local passed, failed = 0, 0
local function check(label, value)
	assert(value, label)
	passed = passed + 1
end
local function contains(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function scenario(name, fn)
	local ok, why = pcall(fn)
	if ok then print("  ok   " .. name)
	else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(why)) end
end
local function fixture()
	local h = envMock.new()
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer,
		info = { folder = "UAI", version = "test" }, context = {} }
	local loaded = {}
	function env.require(id)
		if loaded[id] then return loaded[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb"))
		local source = file:read("*a"); file:close()
		local factory = assert(luau.load(source, id))
		setfenv(factory, h.sandbox)
		loaded[id] = factory()(env)
		return loaded[id]
	end
	local registry = env.require("agent/registry")
	registry.loaded = true
	for _, group in ipairs({ "script", "fs" }) do
		for _, tool in ipairs(env.require("tools/" .. group)) do tool.group = group; registry.register(tool) end
	end
	env.require("runtime/config").set("permissions.mode", "full")
	local ctx = { env = env, session = {}, aborted = function() return false end }
	local function dispatch(name, args, seconds, custom)
		local result
		h.sched.spawn(function()
			result = registry.dispatch({ id = "test-call", name = name, arguments = h.json.encode(args or {}) }, custom or ctx)
		end)
		h.sched.advance(seconds or 0.1)
		assert(result, "tool did not finish: " .. name)
		return result
	end
	return h, env, registry, dispatch, ctx
end

scenario("compilation is read-only and execution failures are failures", function()
	local h, env, registry, run = fixture()
	check("valid code compiles", run("check_luau", { code = "_G.checked = true" }).ok)
	check("syntax checks never run the code", h.sandbox.checked == nil)
	check("syntax errors fail", not run("check_luau", { code = "local =" }).ok)
	check("compile failures are not successful runs", not run("run_luau", { code = "local =" }).ok)
	local runtime = run("run_luau", { code = "print('before failure'); error('deliberate')" })
	check("runtime failures are not successful runs", not runtime.ok)
	check("runtime error and preceding output retained", contains(runtime.text, "deliberate") and contains(runtime.text, "before failure"))
	check("empty execution fails", not run("run_luau", { code = "  " }).ok)
	check("no unexpected scheduler errors", #h.sched.errors == 0)
end)

scenario("run_luau executes a workspace file by path without inlining it", function()
	local h, env, registry, run = fixture()
	local fsx = env.require("runtime/fsx")
	assert(fsx.write("scripts/build.lua", "print('from file'); return 7", { scope = "files" }))
	local result = run("run_luau", { path = "scripts/build.lua" })
	check("file ran", result.ok)
	check("file output captured", contains(result.text, "from file"))
	check("file return value came back", contains(result.text, "Returned: 7"))

	-- Files the model wrote as pastes are runnable too.
	assert(fsx.write("snippet.lua", "_G.ranPaste = true", { scope = "pastes" }))
	check("paste-scoped file runs", run("run_luau", { path = "snippet.lua" }).ok)
	check("paste file executed", h.sandbox.ranPaste == true)

	check("missing file is a clean failure", not run("run_luau", { path = "nope.lua" }).ok)
	check("empty file is refused", (function()
		assert(fsx.write("blank.lua", "   ", { scope = "files" }))
		return not run("run_luau", { path = "blank.lua" }).ok
	end)())
	check("code and path together are refused", not run("run_luau", { code = "return 1", path = "scripts/build.lua" }).ok)
	check("neither code nor path is refused", not run("run_luau", {}).ok)
	check("path traversal is refused", not run("run_luau", { path = "../config.json" }).ok)
	check("no scheduler errors from file runs", #h.sched.errors == 0)
end)

scenario("output preserves whitespace, tables, cycles and nil return positions", function()
	local h, env, registry, run = fixture()
	local result = run("run_luau", { code = "local t = {answer=42}; t.self=t; print('first\\n  second'); warn('careful'); return t, false, nil, 7" })
	check("successful execution", result.ok)
	check("newlines and indentation preserved", contains(result.text, "first\n  second"))
	check("table values readable", contains(result.text, "answer = 42"))
	check("cycles bounded", contains(result.text, "<cycle>"))
	check("all returns retained", contains(result.text, "\tfalse\tnil\t7"))
	check("warnings captured", contains(result.text, "[warn]\tcareful"))
	check("console untouched", #h.console.out == 0 and #h.console.warnings == 0)
end)

scenario("saved scripts compile by path without executing or resending source", function()
	local h, env, registry, run = fixture()
	local fsx = env.require("runtime/fsx")
	local source = "_G.checkedFileRan = true; return 42"
	assert(fsx.write("scripts/check.lua", source, { scope = "files" }))
	local checked = run("check_luau", { path = "scripts/check.lua" })
	check("saved file compiles", checked.ok)
	check("checking a file has no side effects", h.sandbox.checkedFileRan == nil)
	check("source is not echoed into the result", not contains(checked.text, source))
	assert(fsx.write("broken.lua", "local =", { scope = "files" }))
	assert(fsx.write("empty.lua", "  ", { scope = "files" }))
	for _, path in ipairs({ "broken.lua", "empty.lua", "missing.lua", "../config.json" }) do
		check("invalid saved script refused: " .. path, not run("check_luau", { path = path }).ok)
	end
	check("checker refuses code and path together", not run("check_luau", { path = "scripts/check.lua", code = source }).ok)
	check("checker requires a source", not run("check_luau", {}).ok)
	assert(fsx.write("paste.lua", "_G.pasteRuns = (_G.pasteRuns or 0) + 1", { scope = "pastes" }))
	for index, path in ipairs({ "paste.lua", "pastes/paste.lua", "UAI/pastes/paste.lua" }) do
		check("saved paste compiles by its displayed path", run("check_luau", { path = path }).ok and h.sandbox.pasteRuns == (index > 1 and index - 1 or nil))
		check("saved paste runs by its displayed path", run("run_luau", { path = path }).ok and h.sandbox.pasteRuns == index)
	end
	assert(fsx.write("protected.lua", source, { scope = "files" }))
	assert(fsx.write("protected.lua", "_G.wrongPasteRan = true", { scope = "pastes" }))
	local caps = env.require("runtime/caps")
	local read = caps.fn.readfile
	caps.fn.readfile = function(path)
		if path == "UAI/files/protected.lua" then error("read denied") end
		return read(path)
	end
	for _, name in ipairs({ "check_luau", "run_luau" }) do
		local result = run(name, { path = "protected.lua" })
		check("unreadable workspace source never falls back to a different paste", not result.ok and contains(result.text, "read denied"))
	end
	check("fallback source was not executed", h.sandbox.wrongPasteRan == nil)
end)

scenario("loop checkpoints preserve strings, comments and source line numbers", function()
	local h, env, registry, run = fixture()
	local result = run("run_luau", { code = "-- while true do end\nlocal a = 'while true do end'\nlocal b = [=[repeat until false]=]\nfor i=1,3 do print(i) end\nreturn a, b" })
	check("finite loop executes", result.ok and contains(result.text, "Output:\n1\n2\n3"))
	check("quoted loop is unchanged", contains(result.text, "Returned: while true do end\trepeat until false"))
	local original = "--[==[ do repeat ]==]\nreturn `literal do {`inner repeat {\"do\"}`} end`"
	local transformed = env.require("tools/execution").instrument(original)
	check("nested Luau interpolation remains byte-identical", transformed == original)
	local collision = run("run_luau", { code = "local __uai_checkpoint = 5; for i=1,2 do print(__uai_checkpoint) end" })
	check("generated identifier cannot shadow the script", collision.ok and contains(collision.text, "5\n5"))
	local failure = run("run_luau", { code = "local n=1\nfor i=1,2 do\nerror('line three')\nend" })
	check("runtime line number maps to the original", contains(failure.text, ":3:") and contains(failure.text, "line three"))
end)

scenario("busy loops yield and stop at their deadline", function()
	local h, env, registry, run = fixture()
	local ticked = false
	h.sched.delay(0.1, function() ticked = true end)
	local result = run("run_luau", { code = "local n=0; while true do n=n+1 end", timeout = 1 }, 1.2)
	check("busy loop times out", not result.ok and result.data.status == "timeout")
	check("scheduler remained responsive", ticked)
	local again = run("run_luau", { code = "repeat until false", timeout = 1 }, 1.2)
	check("empty repeat is guarded", not again.ok and again.data.status == "timeout")
	check("no runaway task errors", #h.sched.errors == 0)
end)

scenario("spawned tasks finish before results and failures cancel siblings", function()
	local h, env, registry, run = fixture()
	local result = run("run_luau", { code = "task.spawn(function() task.wait(0.2); print('child') end); task.defer(function() print('deferred') end); return 'root'" }, 0.4)
	check("child output retained", result.ok and contains(result.text, "child") and contains(result.text, "deferred"))
	local failure = run("run_luau", { code = "task.delay(1, function() _G.late = true end); task.spawn(function() error('child error') end)" }, 0.1)
	check("child error fails execution", not failure.ok and contains(failure.text, "child error"))
	h.sched.advance(2)
	check("delayed sibling cancelled", h.sandbox.late == nil)
end)

scenario("Stop cancels managed code promptly without late side effects", function()
	local h, env, registry, run, ctx = fixture()
	local stopped = false
	ctx.aborted = function() return stopped end
	h.sched.delay(0.1, function() stopped = true end)
	local result = run("run_luau", { code = "task.delay(2, function() _G.childLate = true end); task.wait(5); _G.rootLate = true" }, 0.3)
	check("Stop returns promptly", not result.ok and result.data.status == "aborted" and result.ms < 300)
	h.sched.advance(6)
	check("root and child do not resume", h.sandbox.rootLate == nil and h.sandbox.childLate == nil)
	check("stopped queued tool never starts", not run("run_luau", { code = "_G.queued = true" }).ok and h.sandbox.queued == nil)
end)

scenario("deadline can be extended, capture is bounded and globals stay intact", function()
	local h, env, registry, run = fixture()
	local original = h.sandbox.print
	local result = run("run_luau", { code = "task.wait(11); return 'finished'", timeout = 12 }, 11.2)
	check("custom deadline exceeds the old fixed timeout", result.ok and contains(result.text, "finished"))
	local output = run("run_luau", { code = "for i=1,200 do print(string.rep('界',1000)) end" })
	check("captured output bounded", output.data.outputTruncated and #(output.full or output.text) < 17000)
	check("capture stays valid UTF-8", env.require("runtime/util").validUtf8(output.full or output.text))
	check("executor globals were not replaced", h.sandbox.print == original)
	local single = run("run_luau", { code = "print(string.rep('x',10000))" })
	check("one oversized value reports truncation", single.data.outputTruncated and contains(single.text, "capture limit"))
end)

scenario("execution works without setfenv and reports cancellation limits honestly", function()
	local h, env, registry, run, ctx = fixture()
	h.sandbox.setfenv = false
	check("capture needs no environment mutation", contains(run("run_luau", { code = "print('captured')" }).text, "captured"))
	h.sandbox.task.cancel = nil
	local stopped = false
	ctx.aborted = function() return stopped end
	h.sched.delay(0.1, function() stopped = true end)
	local result = run("run_luau", { code = "task.wait(10); _G.shouldNotRun = true" }, 0.3)
	check("cooperative cancellation still returns", not result.ok and result.data.status == "aborted")
	h.sched.advance(11)
	check("managed waits still prevent late effects", h.sandbox.shouldNotRun == nil)
	check("no uncaught cancellation error", #h.sched.errors == 0)
end)

scenario("successful scripts can register callbacks outside the tool lifetime", function()
	local h, env, registry, run = fixture()
	local result = run("run_luau", { code = "_G.later = function() task.wait(0.1); local n=0; for i=1,200 do n=n+1 end; _G.callbackValue=n end; return 'registered'" })
	check("registration succeeds", result.ok)
	h.sched.advance(12)
	h.sched.spawn(h.sandbox.later)
	h.sched.advance(0.2)
	check("completed call does not poison later engine callbacks", h.sandbox.callbackValue == 200)
	check("callback has no expired-guard error", #h.sched.errors == 0)
end)

scenario("explicit cancellation never closes a native task", function()
	for _, mode in ipairs({ "normal", "missing", "throws", "refuses" }) do
		local h, env, registry, run = fixture()
		local nativeCancel, cancelledNatively = h.sandbox.task.cancel, 0
		h.sandbox.task.cancel = function(thread) cancelledNatively = cancelledNatively + 1; return nativeCancel(thread) end
		if mode == "missing" then h.sandbox.task.cancel = nil
		elseif mode == "throws" then h.sandbox.task.cancel = function() error("not supported") end
		elseif mode == "refuses" then h.sandbox.task.cancel = function() return false end end
		local result = run("run_luau", { code = "local child=task.spawn(function() task.wait(0.1); _G.cancelledChildRan=true end); task.wait(0.01); task.cancel(child); return 'done'" }, 0.05)
		check(mode .. ": parent can complete", result.ok and contains(result.text, "done"))
		check(mode .. ": no native coroutine is closed", cancelledNatively == 0)
		h.sched.advance(0.2)
		check(mode .. ": cancelled child stays stopped", h.sandbox.cancelledChildRan == nil)
		check(mode .. ": cancellation is caught", #h.sched.errors == 0)
	end
end)

scenario("cancelling the current managed task stops its remaining code", function()
	local h, env, registry, run = fixture()
	local nativeCalls = 0
	h.sandbox.task.cancel = function() nativeCalls = nativeCalls + 1; error("cannot resume dead coroutine") end
	local result = run("run_luau", { code = "task.spawn(function() task.cancel(coroutine.running()); _G.cancelledSelfRan=true end); return 'done'" })
	check("parent completes after child cancels itself", result.ok)
	check("self-cancelled child cannot continue", h.sandbox.cancelledSelfRan == nil)
	check("self cancellation is caught", #h.sched.errors == 0)
	check("self cancellation never reaches the native scheduler", nativeCalls == 0)
	local root = run("run_luau", { code = "task.cancel(coroutine.running()); _G.cancelledRootRan=true" })
	check("a self-cancelled root settles without later effects", root.ok and h.sandbox.cancelledRootRan == nil and nativeCalls == 0)
end)

scenario("stopping during an engine wait preserves its native continuation", function()
	local h, env, registry, run, ctx = fixture()
	local stopped, nativeCalls, completedWait = false, 0, false
	ctx.aborted = function() return stopped end
	local nativeCancel = h.sandbox.task.cancel
	h.sandbox.task.cancel = function(thread) nativeCalls = nativeCalls + 1; return nativeCancel(thread) end
	h.sandbox.engineWait = function() h.sched.wait(0.5); completedWait = true end
	h.sched.delay(0.1, function() stopped = true end)
	local result = run("run_luau", { code = "engineWait(); task.wait(); _G.afterEngineWait=true" }, 0.3)
	check("engine wait does not hold up Stop", not result.ok and result.data.status == "aborted")
	check("a pending external continuation is disclosed", contains(result.text, "before its next checkpoint"))
	check("Stop does not close an engine-owned waiter", nativeCalls == 0)
	h.sched.advance(0.4)
	check("native completion resumes a live coroutine", completedWait and #h.sched.errors == 0)
	check("the next managed checkpoint stops further work", h.sandbox.afterEngineWait == nil)
	stopped = false
	check("subsequent scripts still execute", run("run_luau", { code = "return 42" }).ok)
end)

scenario("dead handles are harmless and other scripts cannot be cancelled", function()
	local h, env, registry, run = fixture()
	local nativeCalls = 0
	h.sandbox.task.cancel = function() nativeCalls = nativeCalls + 1; error("cannot resume dead coroutine") end
	local dead = run("run_luau", { code = "local t=task.spawn(function() end); task.cancel(t); task.cancel(t); return 'done'" })
	check("repeated cancellation of a finished task is harmless", dead.ok and nativeCalls == 0)
	local externalFinished = false
	h.sandbox.externalThread = h.sched.spawn(function() h.sched.wait(0.2); externalFinished = true end)
	local external = run("run_luau", { code = "task.cancel(externalThread)" })
	check("foreign task cancellation is refused", not external.ok and contains(external.text, "this script's tasks") and nativeCalls == 0)
	h.sched.advance(0.2)
	check("other scripts keep running", externalFinished)
	for _, code in ipairs({ "task.cancel(nil)", "task.cancel({})" }) do
		check("invalid cancellation handles fail cleanly", not run("run_luau", { code = code }).ok)
	end
	check("invalid and dead handles do not poison the scheduler", #h.sched.errors == 0)
end)

scenario("late callbacks keep managed cancellation after a successful run", function()
	local h, env, registry, run = fixture()
	local nativeCalls = 0
	h.sandbox.task.cancel = function() nativeCalls = nativeCalls + 1 end
	local result = run("run_luau", { code = "_G.laterCancel=function() local t=task.spawn(function() task.wait(0.1); _G.lateCancelRan=true end); task.cancel(t) end" })
	check("callback registration completes", result.ok)
	h.sched.advance(12)
	h.sched.spawn(h.sandbox.laterCancel)
	h.sched.advance(0.3)
	check("late callbacks never revert to unsafe native cancellation", nativeCalls == 0 and h.sandbox.lateCancelRan == nil and #h.sched.errors == 0)
end)

scenario("stopped long delays drain promptly without native cancellation", function()
	local h, env, registry, run, ctx = fixture()
	local stopped, nativeCalls = false, 0
	ctx.aborted = function() return stopped end
	h.sandbox.task.cancel = function() nativeCalls = nativeCalls + 1 end
	h.sched.delay(0.1, function() stopped = true end)
	local result = run("run_luau", { code = "task.delay(86400, function() _G.tomorrow=true end); task.wait(86400)" }, 0.3)
	check("long timers settle after Stop", not result.ok and result.data.status == "aborted")
	h.sched.advance(1) -- let the fixture's debounced settings save settle too
	check("no orphaned one-day timer remains", h.sched.pending() == 0 and nativeCalls == 0 and h.sandbox.tomorrow == nil)
end)

scenario("unload cancels execution roots and their delayed tasks", function()
	local h, env, registry, run = fixture()
	h.sched.delay(0.1, function() env.require("runtime/dispose").drain() end)
	local result = run("run_luau", { code = "task.delay(1, function() _G.afterUnload=true end); task.wait(5)" }, 0.3)
	check("unload stops the active execution", not result.ok and result.data.status == "aborted")
	h.sched.advance(6)
	check("unload cancels scheduled work", h.sandbox.afterUnload == nil)
end)

scenario("JSON repairs do not rewrite code and reject unfinished strings", function()
	local h, env = fixture()
	local schema = env.require("agent/schema")
	local source = 'print("True False None ,} ,]")'
	local repaired = schema.repairJson('{"code":' .. h.json.encode(source) .. ',"flag":True,}')
	check("only JSON literals are repaired", repaired and repaired.code == source and repaired.flag == true)
	check("truncated code is never completed and executed", schema.repairJson('{"code":"print(42)') == nil)
	local complete = schema.repairJson('{"code":"return 42"')
	check("missing object closer can still be repaired", complete and complete.code == "return 42")
	local _, errors = schema.validate({ type = "integer" }, "1.5")
	check("fractional integers are not silently rounded", #errors > 0)
	local _, invalid = schema.validate({ type = "number" }, math.huge)
	check("non-finite numbers rejected", #invalid > 0)
end)

scenario("interrupted write arguments never apply a partial edit or script", function()
	local h, env, registry, run, ctx = fixture()
	local fsx = env.require("runtime/fsx")
	local original = "local first=1\nlocal second=1\n"
	assert(fsx.write("edit.lua", original, { scope = "files" }))
	local function raw(name, arguments)
		local result
		h.sched.spawn(function() result = registry.dispatch({ id = "cut", name = name, arguments = arguments }, ctx) end)
		h.sched.advance(0.1)
		return assert(result)
	end
	local interrupted = {
		{ "file_edit_many", '{"path":"edit.lua","edits":[{"old_text":"first=1","new_text":"first=2"},{"old_text":"second=1","new_text":"sec' },
		{ "file_edit_many", '{"path":"edit.lua","edits":[{"old_text":"first=1","new_text":"first=2"},' },
		{ "file_edit", '{"path":"edit.lua","old_text":"first=1","new_text":"first=2"' },
		{ "file_write", '{"path":"edit.lua","content":"return {}' },
		{ "file_append", '{"path":"edit.lua","content":"-- appended"' },
		{ "run_luau", '{"code":"_G.partialRan = true"' },
	}
	for _, call in ipairs(interrupted) do
		local result = raw(call[1], call[2])
		check("incomplete mutation refused: " .. call[1], not result.ok and result.error == "bad arguments")
		check("every original byte survives", fsx.read("edit.lua", { scope = "files" }) == original)
	end
	check("unfinished execution has no side effects", h.sandbox.partialRan == nil)
	local read = raw("file_read", '{"path":"edit.lua","limit":')
	check("read-only missing options can still be repaired", read.ok and contains(read.text, "first=1"))
	local source = 'print("True False None ,} ,]")'
	local repaired = raw("file_write", '```json\n{"path":"valid.lua","content":' .. h.json.encode(source) .. ',}\n```')
	check("complete writes retain harmless formatting repair", repaired.ok and fsx.read("valid.lua", { scope = "files" }) == source)
	local schema = env.require("agent/schema")
	check("braces inside truncated source cannot become JSON closers", schema.repairJson('{"code":"return {value=42}') == nil)
end)

scenario("dispatch enforces current tool scope and routes progress by call id", function()
	local h, env, registry, run, ctx = fixture()
	registry.setGroupEnabled("script", false)
	check("disabled groups cannot execute stale calls", not run("run_luau", { code = "_G.disabled = true" }).ok and h.sandbox.disabled == nil)
	registry.setGroupEnabled("script", true)
	ctx.session.toolFilter = { check_luau = true }
	check("child allowlists enforced", not run("run_luau", { code = "_G.scoped = true" }).ok and h.sandbox.scoped == nil)
	ctx.session.toolFilter = nil
	ctx.session.toolExclude = { run_luau = true }
	check("excluded tools cannot execute", not run("run_luau", { code = "_G.excluded = true" }).ok and h.sandbox.excluded == nil)
	ctx.session.toolExclude = nil
	local progress = {}
	ctx.emit = function(kind, event) progress[#progress + 1] = { kind = kind, event = event } end
	registry.register({ name = "progress_test", risk = "read", run = function(args, scoped)
		scoped.progress("first")
		scoped.emit("tool:progress", "second")
		return "done"
	end })
	check("progress tool succeeds", run("progress_test").ok)
	check("progress carries its own call id", #progress == 2 and progress[1].event.id == "test-call" and progress[2].event.name == "progress_test")
end)

scenario("scope changes during approval are enforced before execution", function()
	local h, env, registry, run, ctx = fixture()
	env.require("runtime/config").set("permissions.mode", "ask")
	ctx.emit = function(kind, event)
		if kind == "permission:ask" then registry.setGroupEnabled("script", false); event.resolve(true) end
	end
	local result = run("run_luau", { code = "_G.afterApproval = true" })
	check("disabled while pending never runs", not result.ok and h.sandbox.afterApproval == nil)
end)

scenario("parallel tools publish results as they finish and keep return order", function()
	local h, env, registry, run, ctx = fixture()
	registry.register({ name = "slow_test", risk = "read", run = function() h.sched.wait(0.3); return "slow" end })
	registry.register({ name = "fast_test", risk = "read", run = function() h.sched.wait(0.05); return "fast" end })
	local observed, results = {}, nil
	h.sched.spawn(function()
		results = registry.runAll({ { id = "slow", name = "slow_test" }, { id = "fast", name = "fast_test" } }, ctx,
			function(result) observed[#observed + 1] = result end)
	end)
	h.sched.advance(0.1)
	check("fast result is visible while slow work continues", #observed == 1 and observed[1].id == "fast" and results == nil)
	h.sched.advance(0.4)
	check("each result published exactly once", #observed == 2 and observed[2].id == "slow")
	check("model result order follows original calls", results[1].id == "slow" and results[2].id == "fast")
end)

scenario("failed and stopped turns return the interface to Ready", function()
	local h, env, registry, run, ctx = fixture()
	local session = { ctx = env.require("agent/context").new(), systemPrompt = "Test", maxTurns = 1 }
	local events = {}
	session.aborted = function() return false end
	session.emit = function(kind, payload) events[#events + 1] = { kind = kind, text = payload.text } end
	session.toolContext = function() return ctx end
	local result = env.require("agent/loop").run(session, "hello")
	check("provider failure is reported", contains(result, "could not reach a provider"))
	check("provider failure resets status", events[#events].kind == "status" and events[#events].text == "Ready")
	local record = { label = "Fixture", model = "fixture-model" }
	local providers = env.require("provider/registry")
	providers.active, providers.chain = function() return record end, function() return { record } end
	env.require("provider/chat").complete = function()
		return { content = "", reasoning = "", model = "fixture-model", toolCalls = {
			{ id = "last-step", ["function"] = { name = "run_luau", arguments = h.json.encode({ code = "task.wait(10)" }) } } }, usage = {} }
	end
	local stopped = false
	session.aborted = function() return stopped end
	ctx.aborted = session.aborted
	h.sched.delay(0.1, function() stopped = true end)
	h.sched.spawn(function() result = env.require("agent/loop").run(session, "work") end)
	h.sched.advance(0.3)
	check("Stop on final allowed step does not report a step limit", result == "Stopped.")
	check("Stop resets status", events[#events].kind == "status" and events[#events].text == "Ready")
end)

scenario("a crashed session cancels only its old turn and can be used again", function()
	local h, env = fixture()
	local sessions = env.require("agent/session")
	local session, other = sessions.create(), sessions.create()
	local loop = env.require("agent/loop")
	local oldContext, callback
	loop.run = function(owner)
		oldContext = owner.toolContext()
		error("228866: cannot resume dead coroutine")
	end
	check("crashing turn was accepted", session.send("first", function(reply) callback = reply end))
	h.sched.advance(0.1)
	check("a crash releases the UI and completion callback", not session.busy and session.status == "Ready" and contains(callback, "cannot resume dead coroutine"))
	check("old tool workers are cancelled", oldContext.aborted())
	check("another conversation is unaffected", not other.aborted())
	local newContext
	loop.run = function(owner) newContext = owner.toolContext(); return "recovered" end
	check("a new send remains available", session.send("second"))
	h.sched.advance(0.1)
	check("new send cannot revive an old worker", oldContext.aborted() and not newContext.aborted() and not session.busy)
	local fresh = sessions.create()
	fresh.send("before clear")
	local beforeClear = newContext
	fresh.clear()
	fresh.send("after clear")
	check("clearing and reusing a turn number cannot revive a worker", beforeClear.aborted() and not newContext.aborted())
	check("session crash cleanup raises no scheduler error", #h.sched.errors == 0)
end)

scenario("file and script slices cover every byte without hidden truncation", function()
	local h, env, registry, run = fixture()
	local fsx = env.require("runtime/fsx")
	env.require("runtime/config").set("agent.resultCap", 600)
	local source = ("local text = '界🙂'\n"):rep(100)
	assert(fsx.write("code.lua", source, { scope = "files" }))
	local pieces, offset, pages = {}, 1, 0
	repeat
		local result = run("file_read", { path = "code.lua", offset = offset, limit = 64000 })
		check("page remains inside result budget", result.ok and not result.truncated and #result.text <= 600)
		check("page contains complete UTF-8", env.require("runtime/util").validUtf8(result.text))
		pieces[#pieces + 1] = result.text:match("^[^\n]*\n(.*)$")
		offset = result.data.nextOffset
		pages = pages + 1
		assert(pages < 100, "pagination did not advance")
	until not offset
	check("all bytes recovered in order", table.concat(pieces) == source)
	check("offset past end is explicit failure", not run("file_read", { path = "code.lua", offset = #source + 2 }).ok)
	assert(fsx.write("empty.txt", "", { scope = "files" }))
	local empty = run("file_read", { path = "empty.txt" })
	check("empty files are readable", empty.ok and empty.data.eof and contains(empty.text, "empty"))
	local node = h.Instance.new("LocalScript", h.workspace)
	node.Name, node.Source = "SourceTest", source
	local script = run("script_source", { path = "Workspace.SourceTest", offset = 21, limit = 200 })
	check("script source is also resumable", script.ok and script.data.offset <= 21 and script.data.nextOffset > 21)
end)

scenario("token-limited tool batches recover without running their complete prefix", function()
	local h, env, registry, run, ctx = fixture()
	local record = { label = "Fixture", model = "fixture-model" }
	local providers = env.require("provider/registry")
	providers.active, providers.chain = function() return record end, function() return { record } end
	local requests, errors = 0, 0
	env.require("provider/chat").complete = function(_, request)
		requests = requests + 1
		if requests == 1 then
			return { content = "", reasoning = "", finish = "length", model = record.model, usage = {}, toolCalls = {
				{ id = "whole", ["function"] = { name = "file_write", arguments = h.json.encode({ path = "partial.lua", content = "return 1" }) } },
				{ id = "cut", ["function"] = { name = "run_luau", arguments = '{"code":"_G.cutRan = true' } },
			} }
		elseif requests == 2 then
			local toolResults = 0
			for _, message in ipairs(request.messages) do
				if message.role == "tool" then
					toolResults = toolResults + 1
					check("recovery says no calls ran and requests smaller calls", contains(message.content, "No calls") and contains(message.content, "smaller"))
				end
			end
			check("each interrupted call retains a matching tool result", toolResults == 2)
			return { content = "", reasoning = "", finish = "tool_calls", model = record.model, usage = {}, toolCalls = {
				{ id = "recovered", ["function"] = { name = "file_write", arguments = h.json.encode({ path = "finished.lua", content = "return 42" }) } },
			} }
		end
		return { content = "Saved.", reasoning = "", finish = "stop", model = record.model, usage = {}, toolCalls = {} }
	end
	local session = { ctx = env.require("agent/context").new(), systemPrompt = "Test", maxTurns = 3,
		aborted = function() return false end, toolContext = function() return ctx end,
		emit = function(kind) if kind == "tool:error" then errors = errors + 1 end end }
	local result
	h.sched.spawn(function() result = env.require("agent/loop").run(session, "write a script") end)
	h.sched.advance(1)
	check("loop resumes and finishes", result == "Saved." and requests == 3)
	check("token-limited prefix never writes or runs", h.files["UAI/files/partial.lua"] == nil and h.sandbox.cutRan == nil)
	check("complete retry writes normally", h.files["UAI/files/finished.lua"] == "return 42")
	check("transcript receives both truncation errors", errors == 2)
	check("recovery has no asynchronous errors", #h.sched.errors == 0)
end)

scenario("saved-paste references resolve exactly as shown in chat", function()
	local h, env, registry, run = fixture()
	assert(env.require("runtime/fsx").write("long.txt", "PASTE_BODY", { scope = "pastes" }))
	for _, path in ipairs({ "long.txt", "pastes/long.txt", "UAI/pastes/long.txt" }) do
		check("paste reference readable: " .. path, contains(run("file_read", { path = path }).text, "PASTE_BODY"))
	end
	check("paste fallback cannot traverse scopes", not run("file_read", { path = "pastes/../config.json" }).ok)
end)

scenario("exact edits preserve surrounding text and refuse ambiguous matches", function()
	local h, env, registry, run = fixture()
	local fsx = env.require("runtime/fsx")
	local scope = { scope = "files" }
	assert(fsx.write("edit.lua", "head\nlocal rate = 10 -- 10%\ntail\n", scope))
	check("exact edit succeeds", run("file_edit", { path = "edit.lua", old_text = "rate = 10", new_text = "rate = 20" }).ok)
	check("surrounding content preserved", fsx.read("edit.lua", scope) == "head\nlocal rate = 20 -- 10%\ntail\n")
	check("empty search refused", not run("file_edit", { path = "edit.lua", old_text = "", new_text = "oops" }).ok)
	check("missing search refused", not run("file_edit", { path = "edit.lua", old_text = "missing", new_text = "oops" }).ok)
	assert(fsx.write("repeat.txt", "a.b a.b", scope))
	check("ambiguous edit refused", not run("file_edit", { path = "repeat.txt", old_text = "a.b", new_text = "x" }).ok)
	check("refused edit left file intact", fsx.read("repeat.txt", scope) == "a.b a.b")
	assert(fsx.write("overlap.txt", "aaa", scope))
	check("overlapping matches are also ambiguous", not run("file_edit", { path = "overlap.txt", old_text = "aa", new_text = "b" }).ok)
	check("overlapping refusal preserves the file", fsx.read("overlap.txt", scope) == "aaa")
	check("replace-all succeeds", run("file_edit", { path = "repeat.txt", old_text = "a.b", new_text = "%1", replace_all = true }).ok)
	check("search and replacement are literal", fsx.read("repeat.txt", scope) == "%1 %1")
	check("empty replacement deletes text", run("file_edit", { path = "edit.lua", old_text = "head\n", new_text = "" }).ok)
	local read, reads = fsx.read, 0
	fsx.read = function(path, options)
		reads = reads + 1
		if reads == 2 then fsx.write(path, "newer content", options) end
		return read(path, options)
	end
	check("concurrent content change refused", not run("file_edit", { path = "repeat.txt", old_text = "%1 %1", new_text = "old edit" }).ok)
	check("newer contents survived", read("repeat.txt", scope) == "newer content")
end)

scenario("filesystem failures do not masquerade as success or erase contents", function()
	local h, env, registry, run = fixture()
	local fsx, caps = env.require("runtime/fsx"), env.require("runtime/caps")
	local scope = { scope = "files" }
	assert(fsx.write("protected.txt", "original", scope))
	caps.fn.appendfile = nil
	caps.fn.readfile = function() error("read denied") end
	check("failed fallback read does not overwrite a file", not fsx.append("protected.txt", "new", scope))
	check("original bytes remain", h.files["UAI/files/protected.txt"] == "original")
	caps.fn.writefile = function() return false end
	check("explicit write refusal reported", not fsx.write("other.txt", "new", scope))
	caps.fn.delfile = function() return false end
	check("explicit deletion refusal reported", not fsx.delete("protected.txt", scope))
	caps.fn.listfiles = function() error("listing denied") end
	check("listing failure is not an empty directory", not run("file_list").ok)
	for _, path in ipairs({ ".. /config.json", ".../config.json", "x/../y", "x\0y", "folder /file" }) do
		check("ambiguous path refused", fsx.sanitise(path) == nil)
	end
end)

print(string.format("Execution tools: %d checks passed, %d scenarios failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
