-- Real files, compact inference inputs, exact UTF-8 and both composer paths.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, luau = require("env"), require("luau")
local passed, failed = 0, 0
local function check(label, value) assert(value, label); passed = passed + 1 end
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function scenario(name, fn)
	local ok, err = pcall(fn)
	if ok then print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function fixture()
	local h = envMock.new()
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer, players = h.services.Players,
		info = { folder = "UAI", version = "test" }, context = {} }
	local loaded, sent = {}, {}
	loaded["agent/loop"] = { run = function(session, text) sent[#sent + 1] = text; session.ctx.pushUser(text); return "ok" end }
	function env.require(id)
		if loaded[id] then return loaded[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb")); local source = file:read("*a"); file:close()
		local chunk = assert(luau.load(source, id)); setfenv(chunk, h.sandbox)
		loaded[id] = chunk()(env); return loaded[id]
	end
	env.loadedModules = loaded
	local registry = env.require("agent/registry"); registry.loaded = true
	for _, tool in ipairs(env.require("tools/fs")) do tool.group = "fs"; registry.register(tool) end
	env.require("runtime/config").set("permissions.mode", "full")
	local sessions = env.require("agent/session")
	local session = sessions.create({ id = "attachment-test" }); sessions.threads[session.id] = session; sessions.activeId = session.id
	return h, env, session, sent, registry
end
local body = "  -- START_OF_SOURCE\r\n" .. ("local value = '界🙂'; -- inspect me\r\n"):rep(900) .. "-- END_OF_SOURCE\r\n  "

scenario("long input is a verified file and never an inline inference payload", function()
	local h, env, session, sent = fixture()
	check("send accepted", session.send(body))
	h.sched.advance(0.2)
	local text = assert(sent[1]); local path = assert(text:match("Path: ([^\n]+)"))
	check("source never appears in input", #text < 650 and not has(text, "START_OF_SOURCE") and not has(text, "END_OF_SOURCE"))
	check("file preserves every original byte", env.require("runtime/fsx").readUser(path) == body)
	check("model history is compact", not has(h.json.encode(session.ctx.wire("system")), "START_OF_SOURCE"))
	check("persisted transcript contains the reference", has(h.files["UAI/sessions/attachment-test.json"], path))
	local saved = h.json.decode(h.files["UAI/sessions/attachment-test.json"])
	check("persisted transcript has no duplicated source", not has(h.json.encode(saved.transcript), "START_OF_SOURCE") and not has(h.json.encode(saved.context), "START_OF_SOURCE"))
	check("second long input accepted", session.send(body .. "different")); h.sched.advance(0.2)
	check("same-second sends have distinct files", sent[1]:match("Path: ([^\n]+)") ~= sent[2]:match("Path: ([^\n]+)"))
	check("original file survives follow-ups", env.require("runtime/fsx").readUser(path) == body)
end)

scenario("the threshold is bytes and ordinary inputs remain inline", function()
	local h, env, session, sent = fixture()
	check("threshold-sized text accepted", session.send(("x"):rep(8000))); h.sched.advance(0.2)
	check("exact threshold stays inline", sent[1] == ("x"):rep(8000))
	check("ordinary whitespace behavior unchanged", session.send("  hello  ")); h.sched.advance(0.2)
	check("ordinary message is inline", sent[2] == "hello")
	check("multibyte input accepted", session.send(("界"):rep(2700))); h.sched.advance(0.2)
	check("multibyte threshold uses actual bytes", has(sent[3], "8100 bytes"))
end)

scenario("failed or unavailable storage never falls back to a huge request", function()
	for _, mode in ipairs({ "unavailable", "refused", "corrupt", "oversize", "disabled" }) do
		local h, env, session, sent, registry = fixture()
		local caps = env.require("runtime/caps")
		if mode == "unavailable" then env.require("runtime/fsx").enabled = false
		elseif mode == "refused" then caps.fn.writefile = function() return false end
		elseif mode == "corrupt" then caps.fn.writefile = function(path, text) h.files[path] = text:sub(1, 10) end
		elseif mode == "disabled" then registry.setGroupEnabled("fs", false) end
		local input = mode == "oversize" and ("x"):rep(2 * 1024 * 1024 + 1) or body
		local ok, err = session.send(input); h.sched.advance(0.2)
		check(mode .. " reports a recoverable failure", ok == false and type(err) == "string")
		check(mode .. " never reaches the model or adds a turn", #sent == 0 and session.turns == 0 and not session.busy and not session.preparing)
	end
end)

scenario("explicit file references are validated even in a short message", function()
	local h, env, session, sent, registry = fixture()
	local store = env.require("runtime/attachments")
	local entry = assert(store.save(body))
	registry.setGroupEnabled("fs", false)
	check("disabled file tools refuse references", not session.send(store.reference(entry), nil, { entry }))
	registry.setGroupEnabled("fs", true)
	h.files["UAI/" .. entry.path] = nil
	check("missing file refuses send", not session.send(store.reference(entry), nil, { entry }))
	check("a refusal does not consume a turn", session.turns == 0 and #sent == 0)
end)

scenario("pasted source is readable and searchable in bounded exact slices", function()
	local h, env = fixture()
	local store, fs = env.require("runtime/attachments"), env.require("runtime/fsx")
	local entry = assert(store.save(body))
	assert(fs.write(entry.path, "workspace shadow", { scope = "files" }))
	check("explicit pastes bypass shadow files", fs.readUser("UAI/" .. entry.path) == body)
	env.require("runtime/config").set("agent.resultCap", 20000)
	local defs = {}; for _, tool in ipairs(env.require("tools/fs")) do defs[tool.name] = tool end
	local offset, pieces = 1, {}
	repeat
		local result = defs.file_read.run({ path = entry.path, offset = offset, limit = 64000 })
		check("page stays bounded and valid UTF-8", #result.text <= 6220 and env.require("runtime/util").validUtf8(result.text))
		pieces[#pieces + 1] = result.text:match("^[^\n]*\n(.*)$")
		check("continuation advances", result.data.nextOffset == nil or result.data.nextOffset > offset)
		offset = result.data.nextOffset
	until not offset
	check("pages reconstruct exactly", #pieces > 1 and table.concat(pieces) == body)
	local search = defs.file_search.run({ path = entry.path, query = "END_OF_SOURCE" })
	check("search finds a tail instruction without echoing the body", search.data and #search.data.matches == 1 and #search.text < 1000)
	local many = defs.file_read_many.run({ reads = { { path = entry.path, limit = 16000 } } })
	check("batch reads also bound paste slices", #many.text < 6500)
end)

scenario("browser chunks commit one verified file and retries do not append twice", function()
	local h, env = fixture()
	local store = env.require("runtime/attachments")
	local first = { uploadId = "upload-test-1", name = "code.lua", offset = 0, content = body:sub(1, 12000) }
	local part = assert(store.upload("one", first))
	check("partial upload has no usable file reference", part.received == 12000 and part.path == nil)
	check("repeated chunk is idempotent", assert(store.upload("one", first)).received == 12000)
	check("another conversation cannot append", store.upload("two", { uploadId = first.uploadId, content = "x", offset = 12000 }) == nil)
	check("out-of-order chunk is refused", store.upload("one", { uploadId = first.uploadId, content = "x", offset = 1 }) == nil)
	local final = { uploadId = first.uploadId, content = body:sub(12001), offset = 12000, final = true }
	local entry = assert(store.upload("one", final))
	check("filename survives the transfer", entry.name == "code.lua")
	check("uploaded bytes are exact", env.require("runtime/fsx").readUser(entry.path) == body)
	check("final retry returns the same file", assert(store.upload("one", final)).path == entry.path)
	check("completed ID cannot be reused for other content", store.upload("one", { uploadId = first.uploadId, content = "changed", offset = 0, final = true }) == nil)
end)

scenario("paste detection preserves surrounding instructions", function()
	local _, env = fixture()
	local store = env.require("runtime/attachments")
	local source, remainder = store.inserted("Fix this:\n\nKeep the interface.", "Fix this:\n" .. body .. "\nKeep the interface.")
	check("only the inserted code is saved", source == body)
	check("both sides stay editable", remainder == "Fix this:\n\nKeep the interface.")
	check("ordinary inserts stay inline", store.inserted("Hello", "Hello world") == nil)
end)

scenario("the native composer sends attachment-only input and retains rejected drafts", function()
	local h = envMock.new(); local app = assert(h.boot()); h.settle(1)
	local composer, session = app.app.chatPanel.composer, app.sessions.current()
	composer.field.set(body)
	check("long paste becomes a real attachment", #composer.attachments == 1 and composer.field.get() == "")
	local entry = composer.attachments[1]
	check("attachment contains metadata instead of source", entry.file and entry.text == nil and entry.bytes == #body)
	local payload, refs
	session.send = function(text, callback, files) payload, refs = text, files; return false, "fixture refusal" end
	h.click(h.byName("Send", composer.shell))
	check("attachment-only send is enabled", payload and #refs == 1)
	check("payload contains only a file pointer", has(payload, entry.path) and not has(payload, "START_OF_SOURCE"))
	check("rejected send keeps the attachment", #composer.attachments == 1)
	session.send = function() return true end
	h.click(h.byName("Send", composer.shell))
	check("accepted send clears the attachment", #composer.attachments == 0)
	check("no native UI thread errors", #h.errors() == 0)
end)

print(string.format("attachments: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
