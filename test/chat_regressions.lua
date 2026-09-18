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

scenario("compact composer keeps optional controls in overflow without flex growth", function()
	local harness, handle, panel = boot()
	local composer = panel.composer
	local context = harness.byName("ContextStrip", composer.shell)
	local toolbar = harness.byName("Meta", composer.shell)
	local surface = harness.byName("ComposerSurface", composer.shell)
	local fieldHolder = harness.byName("FieldHolder", composer.shell)
	local model = harness.byName("ModelChip", composer.shell)
	local theme = handle.env.require("ui/theme")
	local restingHeight = composer.shell.Size.Y.Offset
	check("desktop composer starts no taller than 64 pixels", restingHeight > 0 and restingHeight <= 64)
	check("desktop composer has no proportional height", composer.shell.Size.Y.Scale == 0)
	check("prompt starts in single-line mode", not composer.expanded and not composer.field.instance.MultiLine)
	check("context details start hidden", context.Visible == false)
	check("secondary status has no visible row", harness.byName("ComposerState", composer.shell).Visible == false)
	check("input controls share the prompt row", toolbar.Parent == harness.byName("InputRow", composer.shell))
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
	for _, value in ipairs({ "model", "permissions", "context", "expand", "clear" }) do
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
		check("prompt retains usable width at " .. width, fieldWidth > 0)
		check("model visibility follows available width " .. width, model.Visible == (inputWidth >= 560))
		check("more remains on the input line at " .. width, toolbar.Parent == fieldHolder.Parent)
		check("resizing does not grow composer at " .. width, composer.shell.Size.Y.Offset == restingHeight)
	end
	surface.AbsoluteSize = harness.dt.Vector2.new(260, surface.Size.Y.Offset)
	openOptions()
	check("model remains reachable when its chip is hidden", harness.byName("Option_model") ~= nil)
	harness.click(harness.byName("Option_context"))
	check("compact composer flow has no thread errors", #harness.errors() == 0)
end)

scenario("composer stays pinned while transcript responds to measured heights", function()
	local harness, handle, panel = boot()
	local chat = harness.byName("Chat")
	local middle = harness.byName("TranscriptHolder", chat)
	local composer = panel.composer.shell
	local todos = panel.todos.shell
	check("composer is anchored to its bottom edge", composer.AnchorPoint.Y == 1)
	check("composer is positioned at panel bottom", composer.Position.Y.Scale == 1 and composer.Position.Y.Offset == 0)
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
		check("transcript fills remaining height, case " .. index, height == spec.height - spec.plan - spec.composer)
		check("transcript ends at composer without a dead gap, case " .. index, top + height == spec.height - spec.composer)
		check("composer stays bottom-pinned, case " .. index, composer.Position.Y.Scale == 1 and composer.Position.Y.Offset == 0)
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

print(string.format("chat regressions: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
