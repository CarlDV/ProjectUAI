-- Targeted audit regressions. Fixtures boot the bundle, then load changed modules
-- from src so this can run while another task is preparing the final bundle.
-- Run: luajit test/audit_regressions.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local passed, failed = 0, 0

local function check(label, condition)
	if not condition then error(label, 2) end
	passed = passed + 1
end

local function scenario(name, run)
	local ok, reason = pcall(run)
	if ok then
		print("  ok   " .. name)
	else
		failed = failed + 1
		print("  FAIL " .. name .. ": " .. tostring(reason))
	end
end

local function boot()
	local harness = envMock.new()
	local handle = assert(harness.boot())
	harness.settle(1)
	return harness, handle
end

local function source(harness, handle, id)
	local chunk = assert(loadfile("src/" .. id .. ".lua"))
	setfenv(chunk, harness.sandbox)
	return chunk()(handle.env)
end

local function holder(harness)
	local frame = harness.Instance.new("Frame", harness.screen())
	frame.Size = harness.dt.UDim2.fromOffset(560, 640)
	return frame
end

scenario("diagnostics copy the selected view and preserve final updates", function()
	local harness, handle = boot()
	local http = handle.env.require("net/http")
	local log = handle.env.require("runtime/log")
	log.clear()
	log.info("audit", "APPLICATION_MARKER")
	http.history = {
		{ stamp = "12:34:56", method = "POST", url = "https://audit.test/v1/chat",
			tag = "inference", status = 429, ms = 25, bytes = 14, via = "executor",
			identity = "claude", uaSent = true, attempt = 2, trace = "trace-last",
			response = "PRIVATE_RESPONSE", error = "sk-sensitive-private-secret-tail" },
	}
	local frame = holder(harness)
	source(harness, handle, "ui/panels/logs").new(frame)
	local copy = harness.byName("CopyDiagnostics", frame)
	harness.click(copy)
	local text = tostring(harness.sandbox.__clipboard)
	check("request URL copied", text:find("https://audit.test/v1/chat", 1, true))
	check("request status copied", text:find("429", 1, true))
	check("request trace copied", text:find("trace-last", 1, true))
	check("request export excludes application log", not text:find("APPLICATION_MARKER", 1, true))
	check("request export excludes response body", not text:find("PRIVATE_RESPONSE", 1, true))
	check("request export redacts secrets", not text:find("sensitive-private-secret", 1, true))
	harness.click(harness.byName("Segment_log", frame))
	harness.click(copy)
	check("log tab copies application log", tostring(harness.sandbox.__clipboard):find("APPLICATION_MARKER", 1, true))
	log.info("audit", "BURST_FIRST")
	log.info("audit", "BURST_LAST")
	harness.settle(0.5)
	check("final burst entry renders", harness.textOf(frame):find("BURST_LAST", 1, true))
	handle.env.require("runtime/caps").fn.clipboard = function() error("clipboard unavailable") end
	harness.click(copy)
	check("copy failure reports retry", harness.textOf(copy):find("Retry", 1, true))
	frame:Destroy()
	harness.settle(0.5)
	check("diagnostic teardown is clean", #harness.errors() == 0)
end)

scenario("quick chat preserves rejected drafts and closes on acceptance", function()
	local harness, handle = boot()
	local quick = source(harness, handle, "ui/quickchat")
	quick.mount(harness.screen())
	quick.show()
	harness.settle(0.4)
	quick.field.set("Keep this prompt intact")
	local session = handle.sessions.current()
	local send = session.send
	session.send = function() return false, "already working" end
	quick.submit(quick.field.get())
	check("rejection keeps quick chat open", quick.visible)
	check("rejection retains prompt", quick.field.get() == "Keep this prompt intact")
	check("rejection explains reason", quick.hint.Text == "already working")
	quick.submit("  ")
	check("empty submission keeps quick chat open", quick.visible)
	local sent
	session.send = function(text) sent = text; return true end
	quick.submit(quick.field.get())
	check("retry sends retained prompt", sent == "Keep this prompt intact")
	check("acceptance closes quick chat", not quick.visible)
	session.send = send
	harness.settle(0.5)
	check("quick-chat interactions are clean", #harness.errors() == 0)
end)

scenario("directory cache recovers after deletion and failed creation", function()
	local harness, handle = boot()
	local caps = handle.env.require("runtime/caps")
	local fsx = source(harness, handle, "runtime/fsx")
	local original = caps.fn.makefolder
	local calls = {}
	-- The general mock removes descendant files but leaves folder records behind.
	-- Match recursive executor deletion for this cache regression.
	local deleteFolder = caps.fn.delfolder
	caps.fn.delfolder = function(path)
		deleteFolder(path)
		local prefix = path .. "/"
		for folder in pairs(harness.folders) do
			if folder:sub(1, #prefix) == prefix then harness.folders[folder] = nil end
		end
	end
	caps.fn.makefolder = function(path)
		calls[path] = (calls[path] or 0) + 1
		return original(path)
	end
	check("initial nested write succeeds", fsx.write("cachecase/inner/a.txt", "first", { scope = "files" }))
	check("sibling write succeeds", fsx.write("cachecase-sibling/a.txt", "sibling", { scope = "files" }))
	check("directory deletion succeeds", fsx.delete("cachecase", { scope = "files" }))
	check("write recreates deleted hierarchy", fsx.write("cachecase/inner/b.txt", "second", { scope = "files" }))
	check("deleted parent recreated", calls[fsx.root .. "/files/cachecase"] == 2)
	check("deleted child recreated", calls[fsx.root .. "/files/cachecase/inner"] == 2)
	check("sibling remains writable", fsx.write("cachecase-sibling/b.txt", "sibling", { scope = "files" }))
	check("sibling cache retained", calls[fsx.root .. "/files/cachecase-sibling"] == 1)
	local retryCalls = 0
	caps.fn.makefolder = function(path)
		if path == fsx.root .. "/retry-folder" then
			retryCalls = retryCalls + 1
			if retryCalls == 1 then error("transient folder failure") end
		end
		return original(path)
	end
	check("creation failure is reported", fsx.ensure(fsx.root .. "/retry-folder") == false)
	check("creation retry succeeds", fsx.ensure(fsx.root .. "/retry-folder") == true)
	check("failure was not cached", retryCalls == 2)
end)

scenario("ask_user keeps typed answers visible and usable", function()
	local harness, handle = boot()
	local previous = handle.env.require("ui/panels/ask")
	if previous.watching then previous.watching() end
	local ask = source(harness, handle, "ui/panels/ask")
	ask.watch()
	local answer
	handle.sessions.current().emit("ask:user", {
		question = "Which result should I keep?",
		options = { "First", "Second" },
		resolve = function(value) answer = value end,
	})
	harness.settle(0.4)
	local field = harness.byName("AskField")
	check("typed answer field exists", field ~= nil)
	check("typed answer has visible height", field.Size.Y.Offset >= handle.env.require("ui/responsive").minTarget())
	local input = field:FindFirstChildOfClass("TextBox")
	check("typed answer has an input", input ~= nil)
	harness.type(input, "Keep both")
	harness.click(harness.byName("AskSend"))
	check("custom answer is submitted", answer == "Keep both")
	check("question resolves after submit", not ask.showing)
	check("question flow is clean", #harness.errors() == 0)
end)

scenario("long subagent reports scroll with a reachable footer", function()
	local harness, handle = boot()
	local subagent = handle.env.require("agent/subagent")
	subagent.records = {
		{ id = "audit-child", label = "Audit report", status = "done", preset = "read",
			task = ("Read the module. "):rep(80), report = ("A detailed result.\n"):rep(80) .. "REPORT_END",
			tools = {}, calls = 0, ms = 1200, runs = 1, depth = 1 },
	}
	local frame = holder(harness)
	source(harness, handle, "ui/panels/agents").new(frame)
	harness.click(harness.byName("Open", frame))
	local modal = harness.byName("Modal")
	local scroll = harness.byName("BodyScroll", modal)
	local footer = harness.byName("Footer", modal)
	check("report opens in a bounded modal", modal ~= nil and modal.Size.Y.Offset > 0)
	check("report has a scroll viewport", scroll ~= nil)
	check("report footer exists", footer ~= nil)
	local cursor = footer
	while cursor and cursor ~= scroll do cursor = cursor.Parent end
	check("footer stays outside scrolling content", cursor == nil)
	check("full report remains available", harness.textOf(scroll):find("REPORT_END", 1, true))
	check("report flow is clean", #harness.errors() == 0)
end)

print(string.format("audit regressions: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
