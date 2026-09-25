-- Synthetic long-chat, retention and resize regressions. Written before validation.
-- Run after building the native bundle: luajit test/chat_stability.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
io.stdout:setvbuf("no")
local F = require("coding_fixture")
local suite = F.suite("Chat stability")
local case, check = suite.case, suite.check
local function has(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
local function named(root, name)
	local out = {}
	for _, item in ipairs(root:GetDescendants()) do if item.Name == name then out[#out + 1] = item end end
	return out
end
local function size(map) local n = 0; for _ in pairs(map) do n = n + 1 end; return n end
local function dialogue(session)
	local out = {}
	for _, event in ipairs(session.log) do
		if event.kind == "user" or event.kind == "assistant:text" then out[#out + 1] = event.text end
	end
	return table.concat(out, "\n")
end
local function chat()
	local f = F.ui(900, 650)
	local session = f.env.require("agent/session").newThread()
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session); f.h.settle(0.1)
	return f, session, view
end
local function tool(session, id, name)
	session.emit("tool:call", { id = id, name = name or "file_read", risk = "read", arguments = "{}" })
	session.emit("tool:result", { id = id, name = name or "file_read", ok = true, text = "Read fixture", ms = 30 })
end
local function history(session, count)
	for i = 1, count do
		session.emit("user", { text = "Question " .. i })
		session.emit("assistant:text", { text = "Answer " .. i, model = "fixture-model" })
	end
end

case("busy parallel agents cannot evict dialogue or split retained calls", function()
	local f = F.new(); local sessions = f.env.require("agent/session"); local session = sessions.newThread()
	session.emit("user", { text = "Keep the original request" })
	session.emit("assistant:text", { text = "Keep the earlier answer", model = "fixture-model" })
	for i = 1, 12 do
		session.emit("tool:call", { id = "dispatch-" .. i, name = "agent_dispatch", arguments = "{}" })
		session.emit("subagent:start", { id = "agent-" .. i, call = "dispatch-" .. i, label = "Worker " .. i, task = "Inspect fixture" })
	end
	for i = 1, 600 do
		local agent = "agent-" .. ((i - 1) % 12 + 1)
		session.emit("subagent:tool", { id = agent, callId = "child-" .. i, name = "file_read", arguments = string.rep("x", 2500), index = math.ceil(i / 12) })
		session.emit("subagent:status", { id = agent, text = "Still working " .. i })
		session.emit("subagent:tool:done", { id = agent, callId = "child-" .. i, name = "file_read", ok = true, text = string.rep("y", 2500) })
	end
	for i = 1, 12 do
		session.emit("subagent:done", { id = "agent-" .. i, label = "Worker " .. i, ok = true, text = "Worker report " .. i, calls = 50, finishedCalls = 50, ms = 9000 })
		session.emit("tool:result", { id = "dispatch-" .. i, name = "agent_dispatch", text = "Returned", ok = true })
	end
	check("original dialogue survives over 1,200 durable worker events", dialogue(session) == "Keep the original request\nKeep the earlier answer")
	local calls, starts, finishes, bytes, previous = {}, {}, {}, 0, 0
	for _, event in ipairs(session.log) do
		check("retained events keep a strict chronological identity", event.transcriptId > previous)
		previous, bytes = event.transcriptId, bytes + event.retainedBytes
		if event.kind == "tool:call" then calls[event.id] = true
		elseif event.kind == "tool:result" then check("parent result retains its call", calls[event.id])
		elseif event.kind == "subagent:tool" then calls[event.id .. ":" .. event.callId] = true
		elseif event.kind == "subagent:tool:done" then check("child result retains its call", calls[event.id .. ":" .. event.callId])
		elseif event.kind == "subagent:start" then starts[event.id] = true
		elseif event.kind == "subagent:done" then finishes[event.id] = true; check("report retains dispatch metadata", starts[event.id]) end
	end
	check("all worker summaries survive activity pressure", size(starts) == 12 and size(finishes) == 12)
	check("count and byte accounting stay bounded", #session.log <= sessions.limits.events and bytes == session.logBytes and bytes <= sessions.limits.transcriptBytes)
	check("only detailed activity was evicted", session.transcript.omitted.activity > 0 and session.transcript.omitted.conversation == 0 and session.transcript.omitted.lifecycle == 0)
	check("finished progress checkpoints are released", #session.transcript.live() == 0)
	local expected, expectedCount = dialogue(session), #session.log
	assert(sessions.persist(session))
	local fs = f.env.require("runtime/fsx")
	local raw = assert(fs.read("sessions/" .. session.id .. ".json"))
	local other = F.new(); assert(other.env.require("runtime/fsx").write("sessions/" .. session.id .. ".json", raw))
	local restored = other.env.require("agent/session"); assert(restored.restore() == 1)
	check("save and restore use the same retention policy", dialogue(restored.current()) == expected and #restored.current().log == expectedCount)
	check("history omissions survive reload", restored.current().transcript.omitted.activity == session.transcript.omitted.activity)
	f.healthy(); other.healthy(); f.close(); other.close()
end)

case("conversation and malformed payloads respect independent hard bounds", function()
	local f = F.new(); local sessions = f.env.require("agent/session"); local session = sessions.newThread()
	history(session, 400)
	check("dialogue overflow is explicit and retains recent answers", session.transcript.omitted.conversation > 0 and has(dialogue(session), "Answer 400"))
	local payload = { text = string.rep("你", 17000), callback = function() end, nested = { private = true }, invalid = math.huge }
	for i = 1, 80 do payload["extra" .. i] = string.rep("z", 4000) end
	session.emit("assistant:text", payload)
	local last = session.log[#session.log]
	check("retention drops nonserializable and nonfinite fields", last.callback == nil and last.nested == nil and last.invalid == nil)
	check("bounded fields remain valid UTF-8", f.env.require("runtime/util").validUtf8(last.text) and #last.text < 25000 and last.retainedBytes < 66000)
	check("large payloads cannot exceed aggregate budgets", #session.log <= sessions.limits.events and session.logBytes <= sessions.limits.transcriptBytes)
	check("snapshots do not expose mutable retained events", (function() local copy = session.transcript.snapshot(); copy[#copy].text = "changed"; return last.text ~= "changed" end)())
	f.healthy(); f.close()
end)

case("legacy history recovers missing dialogue without duplicating repeated prompts", function()
	local f = F.new(); local module = f.env.require("agent/transcript"); local owner = {}; local store = module.new(owner)
	local ctx = { messages = {
		{ role = "user", content = "Again", at = 10 }, { role = "assistant", content = "First answer", at = 20 },
		{ role = "user", content = "Again", at = 30 }, { role = "assistant", content = "Second answer", at = 40 },
	} }
	store.restore({ { kind = "user", text = "Again", at = 30 },
		{ kind = "subagent:start", id = "old-worker", label = "Worker", at = 31 },
		{ kind = "subagent:done", id = "old-worker", text = "Report", at = 39 },
		{ kind = "assistant:text", text = "Second answer", at = 40 } }, ctx)
	check("missing earlier turns are recovered in order", dialogue(owner) == "Again\nFirst answer\nAgain\nSecond answer" and owner.log[1].at == 10)
	check("recovery is counted and labeled", store.recovered == 2 and owner.log[1].recovered)
	local restoredOwner = {}; local restored = module.new(restoredOwner)
	restored.restore(store.snapshot(), ctx, store.metadata())
	check("repeated restores do not duplicate recovered dialogue", #restoredOwner.log == #owner.log and restored.recovered == 2)
	store.restore({ { kind = "subagent:done", id = "only-activity", text = "Old report" } }, ctx)
	check("activity-only legacy files regain surviving conversation text", dialogue(owner) == "Again\nFirst answer\nAgain\nSecond answer")
	local modern = {}; local modernStore = module.new(modern)
	modernStore.restore({ { kind = "assistant:text", text = "Second answer", at = 40 } }, ctx,
		{ version = 2, omitted = { conversation = 3 } })
	check("modern intentional limits are not undone by context recovery", #modern.log == 1 and modernStore.recovered == 0 and modernStore.omitted.conversation == 3)
	f.healthy(); f.close()
end)

case("pending calls survive pressure and live status is coalesced", function()
	local f = F.new(); local session = f.env.require("agent/session").newThread()
	session.emit("tool:call", { id = "waiting", name = "file_read", arguments = "original arguments" })
	session.emit("subagent:start", { id = "worker", label = "Worker" })
	for i = 1, 600 do
		tool(session, "done-" .. i)
		session.emit("tool:progress", { id = "waiting", text = "Progress " .. i })
		session.emit("subagent:status", { id = "worker", text = "Status " .. i })
	end
	local live, call = session.transcript.live(), false
	for _, event in ipairs(session.log) do if event.id == "waiting" then call = event.arguments == "original arguments" end end
	check("unfinished call arguments cannot be crowded out by completed calls", call)
	check("transient updates keep only the current checkpoints", #live == 2 and has(live[1].text, "600") and has(live[2].text, "600"))
	session.emit("tool:result", { id = "waiting", text = "Done", ok = true })
	session.emit("subagent:done", { id = "worker", text = "Done", ok = true })
	check("completion releases coalesced status", #session.transcript.live() == 0)
	f.healthy(); f.close()
end)

case("live history releases old GUI rows and keeps nested agent reports", function()
	local f, session, view = chat(); session.busy = true
	session.emit("user", { text = "The conversation must remain" })
	session.emit("assistant:text", { text = "Earlier answer remains too", model = "fixture" })
	session.emit("tool:call", { id = "dispatch", name = "agent_dispatch", arguments = "{}" })
	session.emit("subagent:start", { id = "worker", call = "dispatch", label = "Keep worker" })
	local agent = view.agents.worker
	session.emit("subagent:done", { id = "worker", text = "Protected worker report", ok = true, ms = 1000 })
	session.emit("tool:result", { id = "dispatch", text = "Reported", ok = true })
	for i = 1, 300 do tool(session, "first-" .. i, "fixture_tool_" .. i) end
	f.h.settle(0.1)
	local initial = #view.scroll.instance:GetDescendants()
	for i = 1, 300 do tool(session, "second-" .. i, "fixture_tool_" .. i) end
	f.h.settle(0.1)
	check("conversation text stays visible during sustained activity", has(f.h.textOf(view.scroll.instance), "The conversation must remain") and has(f.h.textOf(view.scroll.instance), "Earlier answer remains too"))
	check("expired dispatch parents cannot destroy protected reports", agent.root.Parent and agent.root:IsDescendantOf(view.scroll.instance) and has(f.h.textOf(agent.root), "Protected worker report"))
	check("GUI retention plateaus instead of growing with every event", #view.scroll.instance:GetDescendants() <= initial + 30 and size(view.rows) <= #session.log)
	check("run metadata does not accumulate every tool name", view.run and #view.run.names <= 16)
	check("limited activity is disclosed", view.historyNotice and has(view.historyNotice.Text, "Older activity details"))
	local shown = f.h.textOf(view.scroll.instance)
	view.refresh(); f.h.settle(2)
	check("refresh retains dialogue and worker reports", has(f.h.textOf(view.scroll.instance), "The conversation must remain") and has(f.h.textOf(view.scroll.instance), "Protected worker report"))
	check("refresh leaves no renderer error banner", not view.issue and has(shown, "Earlier answer remains too"))
	f.healthy(); view.destroy(); f.close()
end)

case("child-tool retention releases its code rows and preserves live agent identity", function()
	local f, session, view = chat(); session.busy = true
	session.emit("user", { text = "Keep this question" })
	session.emit("subagent:start", { id = "worker", label = "Worker", startedAt = f.env.require("runtime/clock").ms() - 5000 })
	local root = view.agents.worker.root
	for i = 1, 240 do
		session.emit("subagent:tool", { id = "worker", callId = "step-" .. i, index = i, name = "luau_execute", arguments = '{"source":"print(1)"}' })
		session.emit("subagent:tool:done", { id = "worker", callId = "step-" .. i, finishedCalls = i, text = "1", summary = "1", ok = true })
	end
	check("live worker is not replaced while its feed rolls over", view.agents.worker.root == root and root.Parent)
	check("child rows follow the activity budget", #named(root, "SubagentTool") <= 128 and #named(root, "Code") <= 128)
	check("worker counts retain omitted work", has(f.h.textOf(root), "240/240"))
	session.emit("subagent:done", { id = "worker", ok = true, text = "Finished the task", calls = 240, finishedCalls = 240, ms = 5000 })
	view.refresh(); f.h.settle(2)
	check("replayed report keeps total calls and final result", has(f.h.textOf(view.scroll.instance), "240/240") and has(f.h.textOf(view.scroll.instance), "Finished the task"))
	f.healthy(); view.destroy(); f.close()
end)

case("merged reasoning releases expired fragments while preserving its disclosure", function()
	local f, session, view = chat(); session.busy = true
	session.emit("request:start", { provider = "Fixture", model = "fixture" })
	session.emit("assistant:preview", { streamId = "thought", reasoning = "Temporary reasoning preview" })
	local root = view.preview.thoughtHandle.root
	session.emit("assistant:reasoning", { streamId = "thought", text = "An early completed trace" })
	session.emit("assistant:complete", { streamId = "thought" })
	f.h.click(root:FindFirstChild("ReasoningHeader", true))
	local listeners = root.Destroying:Count()
	for i = 1, 600 do session.emit("assistant:reasoning", { text = "Retained thought [" .. i .. "]" }) end
	local thought = view.run.thought
	check("consecutive traces keep the promoted preview and one disclosure", thought.root == root and #named(view.scroll.instance, "Reasoning") == 1)
	check("retention preserves the disclosure's expanded state", root:FindFirstChild("Aside", true).Visible)
	check("expired trace text is released from the shared body", not has(thought.body.Text, "An early completed trace") and not has(thought.body.Text, "[1]") and has(thought.body.Text, "[600]"))
	check("shared row bookkeeping follows retained history", #thought.thoughtChunks == #session.log and size(thought.transcriptIds) == #session.log and size(view.rows) == #session.log)
	check("expired fragments cannot accumulate destruction listeners", root.Destroying:Count() == listeners)
	local expected = thought.body.Text
	view.refresh(); f.h.settle(2)
	local rebuilt = named(view.scroll.instance, "Reasoning")
	check("refresh reconstructs exactly the retained combined trace", #rebuilt == 1 and rebuilt[1]:FindFirstChild("ThoughtText", true).Text == expected)
	for i = 1, 140 do tool(session, "expire-thought-" .. i) end
	check("a fully expired disclosure is released", #named(view.scroll.instance, "Reasoning") == 0)
	f.healthy(); view.destroy(); f.close()
end)

case("discarded reasoning previews release their activity handles immediately", function()
	local f, session, view = chat(); session.busy = true
	session.emit("user", { text = "Keep this conversation during retries" })
	for i = 1, 80 do
		session.emit("request:start", { provider = "Fixture", model = "fixture" })
		session.emit("assistant:preview", { streamId = "retry-" .. i, reasoning = "Unfinished preview" })
		session.emit("request:done", { error = "Synthetic interrupted stream" })
	end
	check("transient retries do not leave destroyed activity handles", size(view.runs) == 0 and view.run == nil and #named(view.scroll.instance, "ToolRun") == 0)
	check("cleanup does not depend on evicting durable history", #session.log == 1 and has(f.h.textOf(view.scroll.instance), "Keep this conversation during retries"))
	session.emit("assistant:reasoning", { text = "A retained completed trace" })
	local run = view.run
	session.emit("assistant:preview", { streamId = "temporary", reasoning = "A discarded continuation" })
	session.emit("assistant:complete", { streamId = "temporary" })
	check("discarding a preview preserves an existing populated activity block", view.run == run and size(view.runs) == 1 and has(f.h.textOf(run.root), "A retained completed trace") and not has(f.h.textOf(run.root), "A discarded continuation"))
	f.healthy(); view.destroy(); f.close()
end)

case("long replay yields and accepts live events exactly once", function()
	local f = F.ui(900, 650); local session = f.env.require("agent/session").newThread(); history(session, 90)
	session.busy = true
	local view = f.env.require("ui/chat/view").new(f.host); view.attach(session)
	check("long attach returns with bounded initial work", view.replaying and #named(view.scroll.instance, "User") <= 6 and session.events:count() == 1)
	session.emit("assistant:text", { text = "Arrived during reconstruction", model = "live-model" })
	session.emit("tool:call", { id = "live-call", name = "file_read", arguments = "{}" })
	session.emit("tool:progress", { id = "live-call", text = "Latest tool progress" })
	session.emit("request:start", { provider = "Fixture", model = "live-model" })
	session.emit("assistant:preview", { streamId = "preview", model = "live-model", text = "Reply still streaming" })
	f.h.settle(2)
	check("queued durable text renders once", not view.replaying and #named(view.scroll.instance, "User") == 90 and #named(view.scroll.instance, "Agent") == 92)
	check("the queued tool receives current progress", view.tools["live-call"] and has(f.h.textOf(view.tools["live-call"].root), "Latest tool progress"))
	check("live preview is reconstructed after history", view.preview and has(f.h.textOf(view.preview.textHandle.root), "Reply still streaming"))
	local liveRoot = view.preview.textHandle.root
	session.emit("assistant:text", { streamId = "preview", text = "The final streamed reply", model = "live-model" })
	session.emit("assistant:complete", { streamId = "preview" })
	check("completed live preview is promoted without a duplicate reply", view.agentHandle.root == liveRoot and #named(view.scroll.instance, "Agent") == 92)
	f.healthy(); view.destroy(); f.close()
end)

case("switch, clear and destruction invalidate pending replay work", function()
	local f = F.ui(900, 650); local sessions = f.env.require("agent/session")
	local first = sessions.newThread(); history(first, 70)
	local second = sessions.newThread(); second.emit("user", { text = "Second conversation only" })
	local view = f.env.require("ui/chat/view").new(f.host); view.attach(first); view.attach(second)
	f.h.settle(2)
	check("switching cancels the old replay and subscription", first.events:count() == 0 and second.events:count() == 1 and not has(f.h.textOf(view.scroll.instance), "Question 70"))
	check("the chosen conversation remains intact", has(f.h.textOf(view.scroll.instance), "Second conversation only"))
	history(second, 80); view.refresh(); check("refresh is pending before clear", view.replaying)
	second.clear(); second.emit("user", { text = "After clear" }); f.h.settle(2)
	check("clear cannot be undone by a stale replay callback", #named(view.scroll.instance, "User") == 1 and has(f.h.textOf(view.scroll.instance), "After clear"))
	history(second, 70); view.refresh(); view.destroy()
	local created = f.h.instanceState.count
	second.emit("assistant:text", { text = "After destruction" }); f.h.settle(2)
	check("destroyed views stop allocating and listening", f.h.instanceState.count == created and second.events:count() == 0)
	f.healthy(); f.close()
end)

case("several active chats keep independent history while navigating and resizing", function()
	local f = F.ui(900, 650); local sessions = f.env.require("agent/session"); local threads = {}
	for i = 1, 4 do
		local session = sessions.newThread(); threads[i] = session
		session.emit("user", { text = "Private request for chat " .. i })
		session.emit("assistant:text", { text = "Answer for chat " .. i })
		session.busy = true
		for call = 1, 150 do tool(session, "call-" .. call) end
	end
	local view = f.env.require("ui/chat/view").new(f.host)
	for i, session in ipairs(threads) do
		view.attach(session); f.h.settle(2)
		local user = named(view.scroll.instance, "User")[1]
		for _, width in ipairs({ 360, 950, 500 }) do view.scroll.instance.AbsoluteSize = f.h.dt.Vector2.new(width, 400) end
		f.h.settle(0.1)
		local shown = f.h.textOf(view.scroll.instance)
		check("chat " .. i .. " retains its original dialogue and row identity", named(view.scroll.instance, "User")[1] == user and has(shown, "Private request for chat " .. i) and has(shown, "Answer for chat " .. i))
		for j, other in ipairs(threads) do
			check("chat subscriptions remain scoped " .. i .. "/" .. j, other.events:count() == (i == j and 1 or 0))
			if i ~= j then check("other chat content cannot leak into the panel " .. i .. "/" .. j, not has(shown, "Private request for chat " .. j)) end
		end
	end
	f.healthy(); view.destroy(); f.close()
end)

case("reading position and follow preference survive refresh and conversation switches", function()
	local f, session, view = chat(); history(session, 3); f.h.settle(0.1)
	local V = f.h.dt.Vector2
	local scroll = view.scroll.instance
	scroll.AbsoluteCanvasSize, scroll.AbsoluteWindowSize = V.new(700, 2600), V.new(700, 400)
	scroll.CanvasPosition = V.new(0, 320)
	check("manual reading unpins the transcript", not view.pinned)
	view.attach(session); view.repin(); f.h.settle(0.1)
	check("reopening the same conversation retains the pixel offset", not view.pinned and scroll.CanvasPosition.Y == 320)
	view.refresh(); f.h.settle(0.2)
	check("refresh preserves reading state", not view.pinned and scroll.CanvasPosition.Y == 320)
	local other = f.env.require("agent/session").newThread(); other.emit("user", { text = "Other" })
	view.attach(other); view.attach(session); f.h.settle(0.2)
	check("each conversation remembers its reading position", not view.pinned and scroll.CanvasPosition.Y == 320)
	f.h.click(f.host:FindFirstChild("Latest", true)); f.h.settle(0.1)
	check("Latest explicitly resumes following", view.pinned and scroll.CanvasPosition.Y == 2200)
	f.healthy(); view.destroy(); f.close()
end)

case("width reflow preserves the visible message anchor and positive canvas", function()
	local f, session, view = chat(); history(session, 2); f.h.settle(0.1)
	local V, scroll = f.h.dt.Vector2, view.scroll.instance
	scroll.AbsolutePosition, scroll.AbsoluteSize = V.new(0, 100), V.new(700, 400)
	scroll.AbsoluteWindowSize, scroll.AbsoluteCanvasSize = V.new(700, 400), V.new(700, 2600)
	local events = session.log
	local offsets, roots = { 0, 250, 900, 1200 }, {}
	for i, event in ipairs(events) do
		local root = view.rows[event.transcriptId].root; roots[i] = root
		root.AbsolutePosition, root.AbsoluteSize = V.new(0, 100 + offsets[i] - 320), V.new(700, i == 2 and 600 or 150)
	end
	scroll.CanvasPosition = V.new(0, 320)
	check("a measured visible message becomes the reading anchor", session.viewState.anchor == events[2].transcriptId and session.viewState.offset == -70)
	local previous = 320
	local off = scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local delta = scroll.CanvasPosition.Y - previous; previous = scroll.CanvasPosition.Y
		for _, root in ipairs(roots) do if root.Parent then root.AbsolutePosition = V.new(root.AbsolutePosition.X, root.AbsolutePosition.Y - delta) end end
	end)
	for i = 2, #roots do roots[i].AbsolutePosition = V.new(0, roots[i].AbsolutePosition.Y + 60) end
	view.scroll.layout.AbsoluteContentSize = V.new(500, 2700)
	scroll.AbsoluteSize = V.new(500, 400); f.h.settle(0.1)
	check("reflow keeps the same line at the same viewport offset", not view.pinned and scroll.CanvasPosition.Y == 380 and roots[2].AbsolutePosition.Y == 30)
	check("canvas follows measured content instead of automatic sizing", tostring(scroll.AutomaticCanvasSize) == "Enum.AutomaticSize.None" and scroll.CanvasSize.Y.Offset >= 2700)
	local height = scroll.CanvasSize.Y.Offset; view.scroll.layout.AbsoluteContentSize = V.new(0, 0); f.h.settle(0.1)
	check("a transient zero-size measurement cannot erase the canvas", scroll.CanvasSize.Y.Offset == height)
	off:Disconnect(); f.healthy(); view.destroy(); f.close()
end)

case("Markdown failures keep readable text and the same reply shell", function()
	local f = F.ui(800, 600); local message, markdown = f.env.require("ui/chat/message"), f.env.require("ui/markdown")
	local reply = message.agent(f.host, "Old reply", 1, "fixture"); reply.stream("Partial preview")
	local stream = reply.root:FindFirstChild("StreamText", true)
	local parser = markdown.blocks; local oldStillPresent = false
	markdown.blocks = function() oldStillPresent = stream.Parent ~= nil; error("synthetic Markdown failure") end
	reply.finish("Keep **all** this source\nincluding the last line")
	check("replacement is built before releasing the preview", oldStillPresent)
	check("plain text recovers failed Markdown in the existing message", reply.root.Parent == f.host and has(f.h.textOf(reply.root), "including the last line") and reply.root:FindFirstChild("PlainTextFallback", true))
	markdown.blocks = parser; reply.finish("Recovered **formatting**")
	check("later updates restore formatted rendering", not reply.root:FindFirstChild("PlainTextFallback", true) and has(f.h.textOf(reply.root), "<b>formatting</b>"))
	f.healthy(); reply.root:Destroy(); f.close()
end)

case("replayed timers use original event times and history search outlives context", function()
	local f = F.ui(800, 600); local message, clock = f.env.require("ui/chat/message"), f.env.require("runtime/clock")
	local now = clock.ms(); local run = message.toolRun(f.host, 1, now - 9000)
	run.pendingName = "file_read"; run.opened(); run.closed(true, now - 1000)
	check("completed activity preserves elapsed time", run.ms == 8000)
	local child = message.subagent(f.host, { id = "worker", label = "Worker", startedAt = now - 10000 }, 2)
	check("active worker age does not restart after replay", has(f.h.textOf(child.root), "10.0s"))
	local sessions = f.env.require("agent/session"); local session = sessions.newThread()
	session.emit("user", { text = "Remember the amber lighthouse" }); session.ctx.messages = {}
	local found = sessions.search("amber lighthouse")
	check("search finds dialogue after model context compaction", #found == 1 and found[1].session == session and found[1].where == "message")
	f.healthy(); child.root:Destroy(); run.root:Destroy(); f.close()
end)

case("maximize, resize and recovery controls preserve a busy full application", function()
	local h = require("env").new(); local handle = assert(h.boot()); h.settle(1)
	handle.app.show("chat"); local session = handle.sessions.current()
	history(session, 14); session.busy = true
	session.emit("request:start", { provider = "Fixture", model = "fixture" })
	session.emit("assistant:preview", { streamId = "active", model = "fixture", text = "Live content" })
	local panel, window = handle.app.chatPanel, handle.app.window
	panel.composer.field.set("Keep this unsent draft")
	check("desktop shell draws directly without an offscreen group", window.root.ClassName == "Frame" and window.root:FindFirstChildOfClass("UIScale") == nil)
	for _ = 1, 4 do h.click(h.byName("Maximise", window.root)); h.settle(0.1) end
	check("maximize retains the window, transcript and live preview", handle.app.window == window and handle.app.chatPanel == panel and panel.view.preview and panel.composer.field.get() == "Keep this unsent draft")
	for _, width in ipairs({ 420, 680, 1050, 500, 900 }) do
		window.root.Size = h.dt.UDim2.fromOffset(width, 540); window.root.AbsoluteSize = h.dt.Vector2.new(width, 540)
		panel.view.scroll.instance.AbsoluteSize = h.dt.Vector2.new(width - 50, 360)
	end
	h.settle(0.2)
	check("repeated resize keeps earlier chat and streaming content", has(h.textOf(panel.view.scroll.instance), "Question 1") and has(h.textOf(panel.view.scroll.instance), "Live content"))
	h.click(h.byName("ComposerOptions", panel.composer.shell)); h.click(assert(h.byName("Option_refresh"))); h.settle(2)
	check("Refresh conversation works during an active request", handle.app.chatPanel == panel and panel.view.preview and panel.composer.field.get() == "Keep this unsent draft")
	handle.app.rebuild("chat stability fixture"); h.settle(2)
	check("a full layout rebuild retains history, live preview and draft", has(h.textOf(handle.app.chatPanel.view.scroll.instance), "Question 1") and handle.app.chatPanel.view.preview and handle.app.chatPanel.composer.field.get() == "Keep this unsent draft")
	check("full application operations produce no scheduler errors", #h.errors() == 0)
	handle.env.require("runtime/dispose").drain()
end)

suite.finish()
