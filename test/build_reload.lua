-- Build identity and re-execution regressions against the shipping bundle.
-- Run after bundling: luajit test/build_reload.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local luau = require("luau")
local buildId = dofile("tools/build_id.lua")
local passed = 0
local function check(label, value)
	assert(value, label)
	passed = passed + 1
	print("ok " .. label)
end
local fixture = { { id = "ui/test", source = "return function()\nreturn 1\nend\n" } }
local base = buildId("1.0", fixture, "return true\n")
check("fingerprint is reproducible", base == buildId("1.0", fixture, "return true\n"))
check("fingerprint ignores CRLF and trailing whitespace", base == buildId("1.0", { { id = "ui/test", source = "return function()\r\nreturn 1\r\nend\r\n" } }, "return true\r\n"))
check("fingerprint changes with module content", base ~= buildId("1.0", { { id = "ui/test", source = "return 2" } }, "return true"))
check("fingerprint changes with bootstrap", base ~= buildId("1.0", fixture, "return false"))
check("fingerprint changes with version", base ~= buildId("1.1", fixture, "return true"))
check("fingerprint changes with module identity", base ~= buildId("1.0", { { id = "ui/other", source = fixture[1].source } }, "return true"))

local file = assert(io.open("dist/uai.lua", "rb"))
local source = file:read("*a")
file:close()
local identity = assert(source:match('local __UAI_BUILD = "([^"]+)"'))
local manifestFile = assert(io.open("dist/uai.manifest.json", "rb"))
local manifest = require("json").decode(manifestFile:read("*a")); manifestFile:close()
check("module manifest belongs to the generated bundle", manifest.buildId == identity and manifest.hashAlgorithm == "uai-dual32-v1" and #manifest.modules > 0)
local previousId = ""
for _, entry in ipairs(manifest.modules) do
	assert(entry.id > previousId and entry.bytes >= 0 and type(entry.hash) == "string", "manifest modules must be ordered and individually identified")
	previousId = entry.id
end
check("module manifest uses canonical order", previousId ~= "")
local function boot(harness, id, hostContext)
	local body = source
	if id then body = body:gsub('local __UAI_BUILD = "[^"]+"', 'local __UAI_BUILD = "' .. id .. '"', 1) end
	local chunk, errors = luau.load(body, "reload-test", { entry = true })
	assert(chunk, errors and errors[1] and errors[1].msg)
	setfenv(chunk, harness.sandbox)
	local handle = assert(chunk(hostContext))
	harness.settle(1)
	return handle
end
local function screenCount(harness)
	local count = 0
	for _, item in ipairs(harness.coreGui:GetChildren()) do
		if item:IsA("ScreenGui") and item.Name:match("^UAI_") then count = count + 1 end
	end
	return count
end
local harness = envMock.new()
local originalContext = { prompt = "Embedded instructions", hooks = { preTool = function() return true end } }
local first = boot(harness, nil, originalContext)
check("handle and runtime expose build identity", first.build == identity and first.env.info.build == identity)
local toggles = 0
local toggle = first.toggle
first.toggle = function() toggles = toggles + 1; toggle() end
local same = boot(harness)
check("same build returns the existing handle and toggles once", same == first and toggles == 1 and first.alive)
check("same build leaves exactly one screen", screenCount(harness) == 1)

first.config.set("agent.customInstructions", "Preserve settings on update", { transient = true })
local session = first.sessions.current()
session.title = "Saved across reload"
session.ctx.pushUser("Keep this conversation")
session.emit("user", { text = "Keep this conversation" })
local oldId, oldScreen = session.id, first.app.screen
local nextBuild = identity .. "-changed"
local updated = boot(harness, nextBuild)
check("changed build replaces the idle instance", updated ~= first and updated.build == nextBuild and updated.alive and not first.alive)
check("old screen detaches before replacement", oldScreen.Parent == nil and screenCount(harness) == 1)
check("config survives reload including previously unsaved settings", updated.config.get("agent.customInstructions") == "Preserve settings on update")
local restored = updated.sessions.threads[oldId]
check("conversation identity and title survive reload", restored and restored.title == "Saved across reload")
check("conversation context survives reload", restored.ctx.last("user").content == "Keep this conversation")
check("conversation transcript survives reload", restored.log[1] and restored.log[1].text == "Keep this conversation")
check("reloaded handle becomes global owner", harness.sandbox.UAI == updated)
check("reload preserves embedding context when no new context is provided", updated.env.context == originalContext)

local running = updated.sessions.newThread()
running.busy = true
running.abortFlag = false
local currentBuild = updated.build
local deferred = boot(harness, identity .. "-busy")
check("busy request remains on its existing build", deferred == updated and updated.build == currentBuild and updated.alive)
check("busy reload never aborts running work", running.busy and running.abortFlag == false)
check("busy reload records pending update", updated.pendingBuild == identity .. "-busy")
check("busy reload explains how to apply the update", harness.textOf():find("Let the current work finish", 1, true) ~= nil)
running.busy = false
local replacementContext = { prompt = "Updated embedding" }
local afterWork = boot(harness, identity .. "-busy", replacementContext)
check("rerunning after work finishes applies pending build", afterWork ~= updated and afterWork.build == identity .. "-busy")

check("explicit new embedding context takes precedence", afterWork.env.context == replacementContext)
local children = afterWork.env.require("agent/subagent")
children.records = { { id = "queued-test", status = "queued" } }
check("queued subagent also defers update", boot(harness, identity .. "-children") == afterWork and afterWork.alive)
children.records = {}

local composer = afterWork.app.chatPanel.composer
composer.field.set("Unsent work")
check("composer draft defers a changed build", boot(harness, identity .. "-draft") == afterWork and composer.field.get() == "Unsent work")
check("draft deferral gives a specific explanation", harness.textOf():find("draft and attachments", 1, true) ~= nil)
check("same build still toggles with a pending draft", boot(harness, afterWork.build) == afterWork and composer.field.get() == "Unsent work")
composer.field.clear()
composer.attachments = { { label = "unsent.lua", text = "return 1" } }
check("pending attachments defer a changed build", boot(harness, identity .. "-attachment") == afterWork and #composer.attachments == 1)
composer.attachments = {}
local draftedSession = afterWork.sessions.current()
composer.field.set("Background conversation draft")
local emptySession = afterWork.sessions.newThread()
afterWork.app.openSession(emptySession.id)
check("switching away leaves the active composer empty", composer.field.get() == "")
check("background conversation draft also defers update", boot(harness, identity .. "-background-draft") == afterWork and afterWork.alive)
afterWork.app.openSession(draftedSession.id)
check("deferred background draft stays intact", composer.field.get() == "Background conversation draft")
composer.field.clear()
local quick = afterWork.env.require("ui/quickchat")
quick.field.set("Quick draft")
check("Quick Chat draft defers a changed build", boot(harness, identity .. "-quick") == afterWork and quick.field.get() == "Quick draft")
quick.field.clear()
local chatFixture = require("gamechat")(harness)
afterWork.env.services.TextChatService = harness.services.TextChatService
afterWork.config.set("permissions.mode", "full")
local chatLoops = afterWork.env.require("runtime/chatloops")
assert(chatLoops.start("auto", { messages = { "Live loop" } }, afterWork.sessions.current().toolContext()))
check("live chat loop defers a changed build", boot(harness, identity .. "-chat-loop") == afterWork and afterWork.alive)
chatLoops.stop()
local isolated = afterWork.sessions.newThread()
isolated.setEphemeral(true)
isolated.ctx.pushUser("Private unsaved conversation")
check("populated isolated conversation defers update", boot(harness, identity .. "-isolated") == afterWork and isolated.ephemeral and isolated.ctx.last("user").content == "Private unsaved conversation")
check("isolated deferral gives a specific explanation", harness.textOf():find("isolated conversations", 1, true) ~= nil)
isolated.setEphemeral(false)

local save = afterWork.config.saveNow
afterWork.config.saveNow = function() return false end
check("save failure leaves old client alive", boot(harness, identity .. "-save-failed") == afterWork and afterWork.alive and screenCount(harness) == 1)
afterWork.config.saveNow = save

local dispose = afterWork.env.require("runtime/dispose")
dispose.add(function() error("simulated cleanup failure") end, "reload-test")
local blocked = boot(harness, identity .. "-cleanup-failed")
check("cleanup failure prevents replacement", blocked == afterWork and afterWork.cleanupFailed and afterWork.reloadBlocked)
check("cleanup failure retains a guard without a duplicate screen", harness.sandbox.UAI == afterWork and screenCount(harness) == 0)
check("rerun after failed cleanup cannot mount a duplicate", boot(harness, identity .. "-retry") == afterWork and screenCount(harness) == 0)

local throwingHarness = envMock.new()
local throwing = boot(throwingHarness)
throwing.destroy = function() error("simulated destroy failure") end
check("throwing destroy cannot mount a second instance", boot(throwingHarness, identity .. "-throw") == throwing and throwing.reloadBlocked and screenCount(throwingHarness) == 1)

local legacyHarness = envMock.new()
local legacy = boot(legacyHarness)
legacy.build = nil
local replacedLegacy = boot(legacyHarness)
check("legacy handle without build metadata is replaced", replacedLegacy ~= legacy and replacedLegacy.build == identity and not legacy.alive)

local volatileHarness = envMock.new()
local volatile = boot(volatileHarness)
volatile.env.require("runtime/fsx").enabled = false
check("host without persistence keeps in-memory state", boot(volatileHarness, identity .. "-volatile") == volatile and volatile.alive)
check("successful update paths have no asynchronous errors", #harness.errors() == 0 and #legacyHarness.errors() == 0)
print("build reload: " .. passed .. " checks passed")
