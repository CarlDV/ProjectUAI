-- Behavior regressions against the bundled application.
-- The mock has no native UIListLayout measurement pass; the geometry scenario
-- publishes the AbsoluteSize measurements that the Roblox engine would supply.
-- Run: luajit test/chat_regressions.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local passed, failed = 0, 0

local function check(label, condition)
	if not condition then error(label, 2) end
	passed = passed + 1
end

local function scenario(name, run)
	local ok, reason = pcall(run)
	if ok then print("  ok   " .. name)
	else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(reason)) end
end

local function boot()
	local harness = envMock.new()
	local handle = assert(harness.boot())
	harness.settle(1)
	local panel = assert(handle.app.chatPanel, "main chat panel missing")
	return harness, handle, panel
end

scenario("main composer retains rejected input and sends accepted input once", function()
	local harness, handle, panel = boot()
	local composer = panel.composer
	local session = handle.sessions.current()
	local fsx = handle.env.require("runtime/fsx")
	assert(fsx.write("audit-context.txt", "ATTACHED_CONTEXT", { scope = "files" }))
	harness.click(harness.byName("AddContext", composer.shell))
	harness.click(harness.byName("Option_file:audit-context.txt"))
	check("attachment is attached through the actual menu", #composer.attachments == 1)
	check("attachment indicator is visible", harness.byName("Attachments", composer.shell).Visible)

	local attempts, stopped, payload = 0, 0, nil
	session.send = function(text) attempts = attempts + 1; payload = text; return false, "already working" end
	session.abort = function() stopped = stopped + 1 end
	harness.type(composer.field.instance, "Keep my question")
	check("rejected Enter attempts one send", attempts == 1)
	check("rejected Enter preserves prompt", composer.field.get() == "Keep my question")
	check("rejected Enter preserves attachment", #composer.attachments == 1)
	check("rejected attachment indicator remains", harness.byName("Attachments", composer.shell).Visible)
	check("payload contains attachment content", payload:find("ATTACHED_CONTEXT", 1, true))

	composer.setBusy(true)
	harness.type(composer.field.instance, "Draft while running")
	check("busy Enter does not dispatch", attempts == 1)
	check("busy Enter does not stop the current turn", stopped == 0)
	check("busy Enter preserves prompt", composer.field.get() == "Draft while running")
	check("busy Enter preserves attachments", #composer.attachments == 1)

	composer.setBusy(false)
	session.send = function(text) attempts = attempts + 1; payload = text; return true end
	harness.click(harness.byName("Send", composer.shell))
	check("accepted click sends once", attempts == 2)
	check("accepted payload contains the drafted question", payload:find("Draft while running", 1, true))
	check("accepted payload includes retained context", payload:find("ATTACHED_CONTEXT", 1, true))
	check("accepted send clears prompt", composer.field.get() == "")
	check("accepted send clears attachment state", #composer.attachments == 0)
	check("accepted send hides attachment indicator", not harness.byName("Attachments", composer.shell).Visible)
	composer.field.instance.FocusLost:Fire(true)
	harness.click(harness.byName("Send", composer.shell))
	check("empty repeat input cannot dispatch again", attempts == 2)
	check("composer flow has no thread errors", #harness.errors() == 0)
end)

scenario("compact composer keeps secondary controls in overflow", function()
	local harness, handle, panel = boot()
	local composer = panel.composer
	local context = harness.byName("ContextStrip", composer.shell)
	local toolbar = harness.byName("Meta", composer.shell)
	local surface = harness.byName("ComposerSurface", composer.shell)
	local fieldHolder = harness.byName("FieldHolder", composer.shell)
	local model = harness.byName("ModelChip", composer.shell)
	local theme = handle.env.require("ui/theme")
	local restingHeight = composer.shell.Size.Y.Offset
	check("desktop composer stays within 64 pixels", restingHeight > 0 and restingHeight <= 64)
	check("desktop composer has no proportional height", composer.shell.Size.Y.Scale == 0)
	check("prompt starts in single-line mode", not composer.expanded and not composer.field.instance.MultiLine)
	check("context details start hidden", context.Visible == false)
	check("status does not consume a footer", not harness.byName("ComposerState", composer.shell).Visible)
	check("toolbar shares the prompt row", toolbar.Parent == fieldHolder.Parent)
	check("toolbar stays on the input line", toolbar.Position.Y.Offset == 0)
	for _, name in ipairs({ "Composer", "ComposerSurface", "InputHolder", "InputRow", "FieldHolder", "Meta" }) do
		local node = name == "Composer" and composer.shell or harness.byName(name, composer.shell)
		check(name .. " has no automatic size growth", tostring(node.AutomaticSize):match("None$") ~= nil)
		check(name .. " has no competing list layout", node:FindFirstChildOfClass("UIListLayout") == nil)
		check(name .. " has no flex growth", node:FindFirstChildOfClass("UIFlexItem") == nil)
	end

	local function openOptions()
		harness.click(harness.byName("ComposerOptions", composer.shell))
	end
	composer.setStatus("")
	openOptions()
	for _, value in ipairs({ "prompts", "model", "permissions", "context", "expand", "clear" }) do
		check("overflow retains " .. value, harness.byName("Option_" .. value) ~= nil)
	end
	check("empty status does not add an overflow item", harness.byName("Option_status") == nil)
	harness.click(harness.byName("Option_context"))
	check("overflow opens context details", context.Visible)
	check("context reserves height only while open", composer.shell.Size.Y.Offset > restingHeight)
	check("context details scroll horizontally", tostring(context.ScrollingDirection) == "Enum.ScrollingDirection.X")
	openOptions()
	harness.click(harness.byName("Option_context"))
	check("overflow hides context details again", context.Visible == false)
	check("hiding context restores compact height", composer.shell.Size.Y.Offset == restingHeight)

	composer.setStatus("Working on the task")
	openOptions()
	check("current status is reachable from overflow", harness.byName("Option_status") ~= nil)
	harness.click(harness.byName("Option_status"))
	check("status feedback does not grow composer", composer.shell.Size.Y.Offset == restingHeight)
	openOptions()
	harness.click(harness.byName("Option_permissions"))
	for _, mode in ipairs({ "ask", "auto", "full" }) do
		check("permissions overflow retains " .. mode, harness.byName("Option_" .. mode) ~= nil)
	end
	harness.click(harness.byName("Option_ask"))
	check("permission selection updates existing permission state", handle.env.require("agent/permissions").mode() == "ask")

	local attempts = 0
	handle.sessions.current().send = function() attempts = attempts + 1; return true end
	composer.field.set("Preserve this draft")
	openOptions()
	harness.click(harness.byName("Option_expand"))
	check("overflow expands input explicitly", composer.expanded and composer.field.instance.MultiLine)
	check("expanded input reserves more space", composer.shell.Size.Y.Offset > restingHeight)
	check("expansion preserves draft", composer.field.get() == "Preserve this draft")
	harness.type(composer.field.instance, "First line\nSecond line")
	check("multiline Enter does not send", attempts == 0)
	openOptions()
	harness.click(harness.byName("Option_expand"))
	check("overflow returns to single-line input", not composer.expanded and not composer.field.instance.MultiLine)
	check("collapse preserves draft", composer.field.get() == "First line\nSecond line")
	check("collapse restores exact compact height", composer.shell.Size.Y.Offset == restingHeight)

	for _, width in ipairs({ 260, 420, 900 }) do
		surface.AbsoluteSize = harness.dt.Vector2.new(width, surface.Size.Y.Offset)
		local inputWidth = width - theme.space.sm * 2
		local fieldWidth = fieldHolder.Size.X.Scale * inputWidth + fieldHolder.Size.X.Offset
		check("prompt retains usable width at " .. width, fieldWidth >= 120)
		check("model only appears when there is room " .. width, model.Visible == (inputWidth >= theme.size.statCard))
		check("more remains on the toolbar at " .. width, harness.byName("ComposerOptions", composer.shell).Parent == toolbar)
		check("resizing does not grow composer at " .. width, composer.shell.Size.Y.Offset == restingHeight)
	end
	surface.AbsoluteSize = harness.dt.Vector2.new(160, surface.Size.Y.Offset)
	check("model hides before controls collide", not model.Visible)
	openOptions()
	check("model remains reachable when its chip is hidden", harness.byName("Option_model") ~= nil)
	harness.click(harness.byName("Option_context"))
	check("compact composer flow has no thread errors", #harness.errors() == 0)
end)

scenario("drafts and attachments follow conversations and survive rebuilds", function()
	local harness, handle, panel = boot()
	local first = handle.sessions.current()
	local fsx = handle.env.require("runtime/fsx")
	assert(fsx.write("draft-context.txt", "draft context", { scope = "files" }))
	harness.click(harness.byName("AddContext", panel.composer.shell))
	harness.click(harness.byName("Option_file:draft-context.txt"))
	panel.composer.field.set("First draft\nwith a second line")
	panel.composer.setExpanded(true)
	local second = handle.sessions.newThread()
	handle.app.openSession(second.id)
	check("new conversation has its own empty draft", panel.composer.field.get() == "")
	check("new conversation has no carried attachment", #panel.composer.attachments == 0)
	panel.composer.field.set("Second draft")
	handle.app.openSession(first.id)
	check("first conversation restores exact draft", panel.composer.field.get() == "First draft\nwith a second line")
	check("first conversation restores expanded input", panel.composer.expanded)
	check("first conversation restores attachment", #panel.composer.attachments == 1)
	handle.app.rebuild("chat draft regression")
	panel = handle.app.chatPanel
	check("rebuild restores draft", panel.composer.field.get() == "First draft\nwith a second line")
	check("rebuild restores attachment", panel.composer.attachments[1].text == "draft context")
	handle.app.openSession(second.id)
	check("other draft survives rebuild too", panel.composer.field.get() == "Second draft")
	panel.composer.field.clear()
	check("background draft is reported to the reload guard", handle.env.require("ui/chat/composer").hasDrafts())
	handle.sessions.remove(first.id)
	check("deleting a conversation releases its draft", not handle.env.require("ui/chat/composer").hasDrafts())
	check("draft switching has no thread errors", #harness.errors() == 0)
end)

scenario("welcome starters insert editable prompts and reflow on narrow screens", function()
	local harness, handle, panel = boot()
	local grid = harness.byName("PromptStarters")
	local cards = { harness.byName("Starter_explore", grid), harness.byName("Starter_build", grid) }
	grid.AbsoluteSize = harness.dt.Vector2.new(560, 240)
	check("wide starter layout uses two columns", cards[2].Position.X.Scale == 0.5)
	grid.AbsoluteSize = harness.dt.Vector2.new(260, 480)
	check("narrow starter layout stacks cards", cards[2].Position.X.Scale == 0 and cards[2].Position.Y.Offset > 0)
	check("activity starts folded", not harness.byName("ActivityCard").Visible)
	harness.click(harness.byName("ToggleActivity"))
	check("activity remains reachable", harness.byName("ActivityCard").Visible)
	local sent = 0
	handle.sessions.current().send = function() sent = sent + 1; return true end
	harness.click(cards[1])
	check("starter populates a real editable prompt", panel.composer.field.get():find("Explore this game", 1, true))
	check("starter never sends automatically", sent == 0)
	panel.composer.field.set("My existing idea")
	harness.click(harness.byName("ComposerOptions", panel.composer.shell))
	harness.click(harness.byName("Option_prompts"))
	harness.click(harness.byName("Option_diagnose"))
	check("prompt menu preserves existing draft", panel.composer.field.get():find("My existing idea\n\nCheck client performance", 1, true))
	check("appended prompt expands for editing", panel.composer.expanded)
	check("starter flow has no thread errors", #harness.errors() == 0)
end)

scenario("compact messages omit action bars and keep long content accessible", function()
	local harness, handle, panel = boot()
	local session = handle.sessions.current()
	local long = string.rep("A long question. ", 110)
	session.emit("user", { text = long })
	session.emit("assistant:text", { text = "First line.\nSecond line.", final = true })
	local user = harness.byName("User", panel.view.scroll.instance)
	local agent = harness.byName("Agent", panel.view.scroll.instance)
	for _, name in ipairs({ "CopyMessage", "ReuseMessage", "QuoteMessage", "MessageActions" }) do
		check(name .. " is absent from messages", harness.byName(name, panel.view.scroll.instance) == nil)
	end
	harness.click(harness.byName("ExpandMessage", user))
	check("full user message remains accessible", harness.textOf(user):find(long, 1, true))
	check("reply line breaks survive rendering", harness.textOf(agent):find("First line.", 1, true) and harness.textOf(agent):find("Second line.", 1, true))
	session.emit("assistant:reasoning", { text = "A long reasoning trace." })
	local reasoning = harness.byName("Reasoning", panel.view.scroll.instance)
	check("reasoning starts folded", not harness.byName("Aside", reasoning).Visible)
	harness.click(harness.byName("ReasoningHeader", reasoning))
	check("reasoning can be expanded", harness.byName("Aside", reasoning).Visible)
	check("message rendering has no thread errors", #harness.errors() == 0)
end)

scenario("touch composer keeps its input, toolbar, and targets separated", function()
	local harness, handle = boot()
	harness.services.UserInputService.TouchEnabled = true
	handle.env.require("ui/responsive").refresh("test")
	harness.setViewport(390, 844)
	harness.settle(2)
	local composer = handle.app.chatPanel.composer
	local surface = harness.byName("ComposerSurface", composer.shell)
	local input = harness.byName("InputHolder", composer.shell)
	local toolbar = harness.byName("Meta", composer.shell)
	surface.AbsoluteSize = harness.dt.Vector2.new(300, surface.Size.Y.Offset)
	for _, name in ipairs({ "Send", "AddContext", "ComposerOptions" }) do
		local button = harness.byName(name, composer.shell)
		check(name .. " meets the touch target", button.Size.X.Offset >= 44 and button.Size.Y.Offset >= 44)
	end
	check("touch composer stays compact", composer.shell.Size.Y.Offset <= 80)
	composer.setExpanded(true)
	check("expanded touch input remains above toolbar", composer.field.shell.Size.Y.Offset <= toolbar.Position.Y.Offset)
	harness.services.UserInputService.OnScreenKeyboardVisible = true
	harness.services.UserInputService.OnScreenKeyboardSize = harness.dt.Vector2.new(390, 300)
	handle.env.require("ui/responsive").refresh("keyboard")
	harness.settle(1)
	check("keyboard layout leaves a bounded composer", composer.shell.Size.Y.Offset < 330)
	check("touch interactions have no thread errors", #harness.errors() == 0)
end)

scenario("quick chat keeps dismissed drafts and transfers them to full chat", function()
	local harness, handle, panel = boot()
	local quick = handle.env.require("ui/quickchat")
	quick.show()
	quick.field.set("A quick thought")
	quick.hide()
	harness.settle(1)
	quick.show()
	check("dismissed draft is retained", quick.field.get() == "A quick thought")
	panel.composer.field.set("Main draft")
	harness.click(harness.byName("OpenFullChat"))
	check("transfer appends to the main draft", panel.composer.field.get() == "Main draft\n\nA quick thought")
	check("transferred quick draft is cleared", quick.field.get() == "")
	check("transfer closes quick chat", not quick.visible)
	check("transfer opens the full window", handle.app.window.visible)
	check("quick chat has no thread errors", #harness.errors() == 0)
end)

scenario("buffered replies render completely without simulated streaming", function()
	local harness, handle, panel = boot()
	handle.env.require("runtime/caps").executor = "AnimationTest"
	handle.env.require("ui/responsive").reduceMotion = false
	local message = handle.env.require("ui/chat/message")
	local original = message.agent
	local partials = 0
	message.agent = function(...)
		local result = original(...)
		local stream = result.stream
		result.stream = function(text)
			check("each revealed prefix is valid UTF-8", handle.env.require("runtime/util").validUtf8(text))
			partials = partials + 1
			stream(text)
		end
		return result
	end
	local reply = string.rep("你好🌟こんにちは ", 35)
	handle.sessions.current().emit("assistant:text", { text = reply, final = true })
	check("completed replies never enter a simulated stream", partials == 0 and panel.view.reveal == nil)
	check("final response is complete", harness.textOf(panel.view.agentHandle.column):find(handle.env.require("runtime/util").trim(reply), 1, true))
	check("reply remains free of action bars", harness.byName("MessageActions", panel.view.agentHandle.root) == nil)
	check("immediate replies have no thread errors", #harness.errors() == 0)
end)

scenario("real response previews update in place and reconcile with durable messages", function()
	local harness, handle, panel = boot()
	local session = handle.sessions.current()
	session.emit("user", { text = "Work in steps" })
	session.emit("request:start", { provider = "Fixture", model = "fixture-model", streamId = "live-fixture" })
	session.emit("assistant:preview", { streamId = "live-fixture", reasoning = "Checking the fixture.", text = "", model = "fixture-model" })
	local thought = harness.byName("Reasoning", panel.view.scroll.instance)
	check("received reasoning is visible before completion", thought and harness.textOf(thought):find("Checking the fixture.", 1, true))
	session.emit("assistant:preview", { streamId = "live-fixture", reasoning = "Checking the fixture.", text = "First step", model = "fixture-model" })
	local streamText = harness.byName("StreamText", panel.view.scroll.instance)
	session.emit("assistant:preview", { streamId = "live-fixture", reasoning = "Checking the fixture.", text = "First step\nSecond step", model = "fixture-model" })
	check("multiline chunks reuse the same live label", streamText and streamText == harness.byName("StreamText", panel.view.scroll.instance) and streamText.Text:find("Second step", 1, true))
	local agentRoot = panel.view.preview.textHandle.root
	session.emit("assistant:reasoning", { streamId = "live-fixture", text = "Checking the fixture. Complete." })
	session.emit("assistant:text", { streamId = "live-fixture", model = "served-model", text = "First step\nSecond step\nDone.", final = true })
	session.emit("assistant:complete", { streamId = "live-fixture" })
	check("final reply replaces its preview without another message", panel.view.agentHandle.root == agentRoot and panel.view.preview == nil)
	check("final attribution uses the model that answered", harness.byName("ModelAttribution", agentRoot).Text == "served-model")
	check("final reasoning replaces its preview without duplication", harness.byName("Reasoning", panel.view.scroll.instance) == thought and harness.textOf(thought):find("Checking the fixture. Complete.", 1, true))
	check("previews never enter the durable transcript", #session.log == 3 and session.livePreview == nil)
	check("streaming leaves no stale cursor", harness.byName("StreamText", panel.view.scroll.instance) == nil)
	panel.view.attach(nil); panel.view.attach(session)
	check("reopening retains final attribution and one reply", #harness.allByName("Agent", panel.view.scroll.instance) == 1
		and harness.byName("ModelAttribution", panel.view.agentHandle.root).Text == "served-model")
	check("preview rendering has no thread errors", #harness.errors() == 0)
end)

scenario("Markdown tables render in replies without reveal-time layout churn", function()
	local harness, handle, panel = boot()
	handle.env.require("runtime/caps").executor = "AnimationTest"
	handle.env.require("ui/responsive").reduceMotion = false
	local text = "Here are the results.\n\n| Name | Score |\n| :--- | ---: |\n| **Alice** | 42 |\n| Bob | 7 |"
	handle.sessions.current().emit("assistant:text", { text = text, final = true })
	local tableRoot = harness.byName("MarkdownTable", panel.view.scroll.instance)
	check("reply contains a real table grid", tableRoot ~= nil)
	check("structured reply skips progressive rebuilds", panel.view.reveal == nil)
	local header = harness.byName("TableHeader", tableRoot)
	check("table header is rendered", harness.textOf(header):find("Name", 1, true))
	local row = harness.byName("TableRow_1", tableRoot)
	check("table cells use inline formatting", harness.byName("Cell_1", row).Text:find("<b>Alice</b>", 1, true))
	check("numeric column uses declared alignment", tostring(harness.byName("Cell_2", row).TextXAlignment):find("Right", 1, true))
	local message = handle.env.require("ui/chat/message")
	local streaming = message.agent(panel.view.scroll.instance, "", 999, "test-model")
	local tableText = "| A | B |\n| --- | --- |\n| one | two |"
	streaming.stream(tableText)
	check("live tables keep their source in one label", harness.byName("StreamText", streaming.root).Text:find(tableText, 1, true)
		and harness.byName("MarkdownTable", streaming.root) == nil)
	streaming.finish(tableText)
	local streamed = harness.byName("MarkdownTable", streaming.root)
	check("completed tables render their cells", streamed ~= nil and harness.textOf(streamed):find("two", 1, true))
	check("stream cursor cannot leak into final cells", harness.byName("StreamText", streaming.root) == nil
		and not harness.textOf(streamed):find("●", 1, true))
	streaming.root:Destroy()
	harness.settle(1)
	check("table integration has no thread errors", #harness.errors() == 0)
end)

scenario("thinking merges consecutive traces and keeps expanded content bounded", function()
	local harness, handle, panel = boot()
	local session = handle.sessions.current()
	session.emit("assistant:reasoning", { text = "**Check** the workspace." })
	session.emit("assistant:reasoning", { text = string.rep("A longer observation. ", 180) })
	local traces = harness.allByName("Reasoning", panel.view.scroll.instance)
	check("consecutive reasoning events share one disclosure", #traces == 1)
	local body = harness.byName("ThoughtText", traces[1])
	check("reasoning retains inline emphasis", body.Text:find("<b>Check</b>", 1, true))
	harness.click(harness.byName("ReasoningHeader", traces[1]))
	local aside = harness.byName("Aside", traces[1])
	check("long thinking has a bounded viewport", aside.Size.Y.Offset <= handle.env.require("ui/theme").size.thinkingViewport)
	check("full trace is retained inside scroll", #body.Text > 3000)
	harness.click(harness.byName("ReasoningHeader", traces[1]))
	check("reasoning folds back to its header", not aside.Visible)
	session.emit("tool:call", { id = "think-tool", name = "instance_tree", arguments = "{}" })
	session.emit("assistant:reasoning", { text = "A later observation after the tool." })
	check("tool boundary preserves event order", #harness.allByName("Reasoning", panel.view.scroll.instance) == 2)
	session.emit("tool:error", { id = "think-tool", name = "instance_tree", text = "Could not inspect" })
	check("failed activity stays inspectable", harness.byName("Calls", panel.view.scroll.instance).Visible)
	harness.settle(1)
	check("thinking integration has no thread errors", #harness.errors() == 0)
end)

scenario("composer stays pinned while transcript responds to measured heights", function()
	local harness, handle, panel = boot()
	local chat = harness.byName("Chat")
	local middle = harness.byName("TranscriptHolder", chat)
	local composer = panel.composer.shell
	local todos = panel.todos.shell
	local bottomInset = 3 -- The existing desktop gap; mobile uses the panel edge.
	check("composer is anchored to its bottom edge", composer.AnchorPoint.Y == 1)
	check("composer preserves its desktop bottom inset", composer.Position.Y.Scale == 1 and composer.Position.Y.Offset == -bottomInset)
	check("chat does not use a competing flex stack", chat:FindFirstChildOfClass("UIListLayout") == nil)
	local cases = {
		{ height = 520, composer = 62, plan = 0 },
		{ height = 640, composer = 216, plan = 76 },
		{ height = 430, composer = 144, plan = 112 },
		{ height = 560, composer = 104, plan = 0 },
	}
	for index, spec in ipairs(cases) do
		chat.AbsoluteSize = harness.dt.Vector2.new(720, spec.height)
		composer.AbsoluteSize = harness.dt.Vector2.new(720, spec.composer)
		todos.AbsoluteSize = harness.dt.Vector2.new(720, spec.plan)
		todos.Visible = spec.plan > 0
		local height = middle.Size.Y.Scale * spec.height + middle.Size.Y.Offset
		local top = middle.Position.Y.Scale * spec.height + middle.Position.Y.Offset
		check("transcript begins below plan, case " .. index, top == spec.plan)
		check("transcript fills remaining height, case " .. index, height == spec.height - spec.plan - spec.composer - bottomInset)
		check("transcript ends at composer without a dead gap, case " .. index, top + height == spec.height - spec.composer - bottomInset)
		check("composer stays bottom-pinned, case " .. index, composer.Position.Y.Scale == 1 and composer.Position.Y.Offset == -bottomInset)
	end
	harness.settle(0.2)
	check("geometry updates have no thread errors", #harness.errors() == 0)
end)

scenario("attaching a busy conversation restores working feedback", function()
	local harness, handle, panel = boot()
	local session = handle.sessions.current()
	session.busy = true
	session.status = "Working on the task"
	panel.view.attach(session)
	harness.settle(0.3)
	local working = harness.byName("Working", panel.view.scroll.instance)
	check("busy attachment creates working row", working ~= nil)
	check("working row has an animated rotor", harness.byName("Rotor", working) ~= nil)
	check("working status has a transparent background", harness.byName("WorkingStatus", working).BackgroundTransparency == 1)
	check("working row displays current status", harness.textOf(working):find("Working on the task", 1, true))
	session.emit("status", { text = "Ready" })
	check("Ready clears working feedback", harness.byName("Working", panel.view.scroll.instance) == nil)
	session.status = "Working again"
	panel.view.attach(session)
	check("reattaching while busy restores working feedback", harness.byName("Working", panel.view.scroll.instance) ~= nil)
	session.emit("abort", {})
	check("abort clears working feedback", harness.byName("Working", panel.view.scroll.instance) == nil)
	session.busy = false
	harness.settle(1.2)
	check("spinner teardown has no thread errors", #harness.errors() == 0)
end)

scenario("conversation icons stay transparent across message types", function()
	local harness, handle, panel = boot()
	local message = handle.env.require("ui/chat/message")
	local primitives = handle.env.require("ui/primitives")
	local holder = primitives.frame(panel.view.scroll.instance, { name = "IconAudit" })
	local agent = message.agent(holder, "A short answer.", 1, "audit-model")
	message.reasoning(holder, "Reviewing the request.", 2)
	message.toolRun(holder, 3)
	message.toolCall(holder, { id = "audit-tool", name = "instance_find", group = "instance", risk = "read", arguments = "{}" }, 4)
	message.subagent(holder, { id = "audit-agent", label = "Audit", task = "Inspect", preset = "read" }, 5)
	for _, name in ipairs({ "BylineIcon", "SparkBadge", "RunIconBadge", "ToolIconBadge", "SubagentIconBadge" }) do
		local icon = harness.byName(name, holder)
		check(name .. " is present", icon ~= nil)
		check(name .. " has no filled background", icon.BackgroundTransparency == 1)
		check(name .. " has no badge corner", icon:FindFirstChildOfClass("UICorner") == nil)
	end
	check("assistant identity stays distinct from model attribution", harness.byName("Speaker", agent.root).Text == "Assistant")
	check("assistant keeps request model attribution", harness.byName("ModelAttribution", agent.root).Text == "audit-model")
	holder:Destroy()
	harness.settle(1.2)
	check("icon row teardown has no thread errors", #harness.errors() == 0)
end)

scenario("new assistant activity does not yank an older scroll position", function()
	local harness, handle, panel = boot()
	local session = handle.sessions.current()
	session.emit("user", { text = "Earlier question" })
	session.emit("assistant:text", { text = "Earlier answer.", final = true })
	harness.settle(1)
	local view = panel.view
	local scroll = view.scroll.instance
	scroll.AbsoluteCanvasSize = harness.dt.Vector2.new(720, 2400)
	scroll.AbsoluteWindowSize = harness.dt.Vector2.new(720, 400)
	scroll.CanvasPosition = harness.dt.Vector2.new(0, 320)
	check("reading older output unpins transcript", not view.pinned)
	check("jump-to-latest becomes reachable", harness.byName("Latest").Visible)
	session.emit("status", { text = "Still working" })
	session.emit("assistant:text", { text = "A newly completed answer.", final = true })
	view.scroll.layout.AbsoluteContentSize = harness.dt.Vector2.new(720, 2800)
	scroll.AbsoluteSize = harness.dt.Vector2.new(720, 380)
	harness.settle(1.5)
	check("new messages preserve older scroll position", scroll.CanvasPosition.Y == 320)
	check("content measurement preserves unpinned state", not view.pinned)
	harness.click(harness.byName("Latest"))
	check("explicit jump repins transcript", view.pinned)
	check("explicit jump reaches latest content", scroll.CanvasPosition.Y >= scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
	check("jump control hides at latest", not harness.byName("Latest").Visible)
	session.emit("status", { text = "Ready" })
	check("scroll flow has no thread errors", #harness.errors() == 0)
end)

scenario("context breakdown shows live colored categories across screen sizes", function()
	for _, size in ipairs({ { 1280, 720, false }, { 1194, 834, true }, { 390, 844, true }, { 844, 390, true } }) do
		local harness = envMock.new()
		local uis = harness.services.UserInputService
		uis.TouchEnabled, uis.MouseEnabled, uis.KeyboardEnabled = size[3], not size[3], not size[3]
		harness.setViewport(size[1], size[2])
		local handle = assert(harness.boot())
		harness.settle(1)
		local composer = handle.app.chatPanel.composer
		local session = handle.sessions.current()
		composer.field.set("Keep this draft")
		harness.click(harness.byName("ComposerOptions", composer.shell))
		harness.click(harness.byName("Option_context_inspect"))
		local inspector = assert(harness.byName("ContextInspector"), "context inspector did not open")
		check("empty context explains missing measurement", harness.textOf(inspector):find("After first request", 1, true))
		for _, id in ipairs({ "system", "messages", "summary", "unused" }) do
			local label = assert(harness.byName("ContextLabel_" .. id, inspector))
			check(id .. " reserves readable width without zero-width flex", label.Size.X.Scale == 1 and label.Size.X.Offset < 0 and label:FindFirstChildOfClass("UIFlexItem") == nil)
		end
		check("an unknown model is not given an invented window", harness.textOf(inspector):find("Model window: unknown", 1, true))
		local record = handle.providers.blank("custom")
		record.label, record.baseUrl, record.model, record.apiKey = "Context test", "https://context.test/v1", "context-test", "test-key"
		assert(handle.providers.save(record))
		handle.config.set("agent.forceContext", { ["context-test"] = 12000 })
		session.ctx.pushUser(("question "):rep(400))
		session.ctx.pushAssistant({ content = ("answer "):rep(300) })
		session.ctx.summary = ("earlier fact "):rep(100)
		session.ctx.calibrate(session.ctx.tokens() + 1200)
		session.emit("status", { text = "Ready" })
		harness.settle(1)
		local util = handle.env.require("runtime/util")
		check("the total uses the compaction pressure", harness.byName("ContextTotal", inspector).Text:find(util.formatNumber(session.ctx.pressure()), 1, true))
		local colors, spans = {}, 0
		for _, id in ipairs({ "system", "messages", "summary" }) do
			local segment = assert(harness.byName("ContextSegment_" .. id, inspector))
			check(id .. " has a visible segment", segment.Visible and segment.Size.X.Scale > 0)
			check(id .. " is placed after the preceding categories", math.abs(segment.Position.X.Scale - spans) < 0.00001)
			spans = spans + segment.Size.X.Scale
			colors[segment.BackgroundColor3:ToHex()] = true
		end
		local colorCount = 0
		for _ in pairs(colors) do colorCount = colorCount + 1 end
		check("each used category has a distinct color", colorCount == 3)
		check("bar shares use the model window", math.abs(spans - session.ctx.pressure() / 12000) < 0.00001)
		check("compaction marker matches the configured fraction", harness.byName("CompactionMarker", inspector).Position.X.Scale == 0.8)
		handle.config.set("agent.contextFraction", 0.5)
		harness.settle(0.2)
		check("open inspector tracks budget changes", harness.byName("CompactionMarker", inspector).Position.X.Scale == 0.5)
		local available = handle.env.require("ui/responsive").usableRect(handle.env.require("ui/overlay").layer, 0)
		check("inspector fits the viewport", inspector.Size.X.Offset <= available.width and inspector.Size.Y.Offset <= available.height)
		check("long details have a scrolling body", harness.byName("BodyScroll", inspector).ScrollingEnabled ~= false)
		local original, refreshed = session.ctx.breakdown, 0
		session.ctx.breakdown = function(...) refreshed = refreshed + 1; return original(...) end
		for _ = 1, 100 do session.emit("status", { text = "Working" }) end
		harness.settle(0.2)
		check("streaming event bursts coalesce context refreshes", refreshed == 1)
		harness.click(harness.byName("Close", inspector))
		check("closing preserves the prompt", composer.field.get() == "Keep this draft")
		session.emit("status", { text = "Ready" })
		harness.settle(0.3)
		check("closed inspectors stop recalculating categories", refreshed == 1)
		check("inspector bindings clean up", #harness.errors() == 0)
		check("inspector uses valid Roblox properties", #harness.instanceState.typeErrors == 0)
	end
end)

scenario("memory settings remove individual facts and stay synchronized", function()
	local harness, handle = boot()
	local state = handle.env.require("agent/state")
	assert(state.remember("first", "Keep the lighthouse"))
	assert(state.remember("second", "Build the dock"))
	local dialog = handle.env.require("ui/panels/settingsdialog").open("skills")
	harness.settle(1)
	local list = assert(harness.byName("MemoryEntries", dialog.card))
	check("each saved fact has its own delete control", #harness.allByName("ForgetOne", list) == 2)
	harness.click(harness.byName("ForgetOne", harness.byName("MemoryEntry_first", list)))
	check("only the chosen fact is deleted", state.recall("first") == nil and state.recall("second") == "Build the dock")
	check("the list immediately reflects deletion", #harness.allByName("ForgetOne", list) == 1)
	assert(state.remember("third", "Use warm lights"))
	harness.settle(0.2)
	check("external memory changes refresh the open pane", #harness.allByName("ForgetOne", list) == 2)
	harness.click(harness.byName("ForgetEverything", dialog.card))
	local overlays = handle.env.require("ui/overlay").open
	local confirmation = overlays[#overlays]
	local clearButton = harness.find(confirmation.footer, function(node)
		return node:IsA("TextButton") and harness.textOf(node) == "Clear"
	end)[1]
	assert(clearButton, "clear confirmation missing")
	harness.click(clearButton)
	check("forget everything still clears all facts", #state.memoryList() == 0)
	check("empty memory has readable feedback", harness.textOf(list):find("Nothing stored.", 1, true))
	dialog.close()
	harness.settle(0.3)
	state.remember("after-close", "No stale listener")
	harness.settle(0.3)
	check("memory bindings clean up", #harness.errors() == 0)
end)

print(string.format("chat regressions: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
