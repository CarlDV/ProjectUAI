-- Independent chatbot integration, using the shipped bundle and yielding transports.
-- Run: luajit test/chat_bot.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, gamechat, json = require("env"), require("gamechat"), require("json")
local passed, failed = 0, 0
local function check(label, condition) assert(condition, label); passed = passed + 1 end
local function scenario(name, fn)
	local ok, err = pcall(fn)
	if ok then print("ok " .. name) else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function dispatch(app, name, args)
	return app.tools.dispatch({ name = name, arguments = json.encode(args or {}) }, app.sessions.current().toolContext())
end
local function boot(options)
	options = options or {}
	local h = envMock.new()
	local chat = gamechat(h)
	local requests = {}
	local reply = { text = "Hey! What's up?", delay = 0 }
	h.http.handler = function(req)
		if req.url:find("/chat/completions", 1, true) or req.url:find("/messages", 1, true) then
			local payload = json.decode(req.body)
			requests[#requests + 1] = payload
			local text, delay, status = reply.text, reply.delay, reply.status
			if delay > 0 then h.sandbox.task.wait(delay) end
			if status then return { StatusCode = status, Body = '{"error":{"message":"Unavailable"}}' } end
			local response
			if options.anthropic then
				response = { model = "harness-model", content = { { type = "text", text = text } }, stop_reason = "end_turn",
					usage = { input_tokens = 12, output_tokens = 8 } }
			else
				response = { model = "harness-model", choices = { { message = { role = "assistant", content = text,
					tool_calls = reply.toolCalls }, finish_reason = "stop" } }, usage = { prompt_tokens = 12, completion_tokens = 8 } }
			end
			return { StatusCode = 200, Body = json.encode(response) }
		end
		return { StatusCode = 200, Body = '{"data":[]}' }
	end
	local app = assert(h.boot()); h.settle(1)
	app.config.set("permissions.mode", "full")
	if not options.noProvider then
		local record = app.providers.blank("custom")
		record.label, record.baseUrl, record.apiKey = "Chatbot test", "https://chatbot.test/v1", "test-key"
		record.model, record.models, record.stream = "harness-model", { "harness-model" }, false
		if options.anthropic then record.api = "anthropic" end
		assert(app.providers.save(record))
	end
	h.settle(1)
	return h, app, chat, app.env.require("runtime/chatloops"), requests, reply
end
local function clean(h, app)
	app.destroy(); h.settle(1)
	check("no asynchronous errors", #h.errors() == 0)
end

scenario("dedicated tool starts immediately, batches input, and keeps its memory private", function()
	local h, app, chat, loops, requests, reply = boot()
	local session = app.sessions.current()
	session.ctx.pushUser("PRIVATE_MAIN_CONVERSATION")
	chat.receive("old history", 2, "Alice", nil, "old")
	local result = dispatch(app, "chat_bot", { instructions = "Talk about building games." })
	check("registered write tool starts", result.ok and result.data.id and app.tools.get("chat_bot").risk == "write")
	check("no request before new chat", #requests == 0 and #chat.sent == 0 and not session.busy)
	check("UI identifies chatbot", h.textOf(h.byName("ChatLoops")):find("Chatbot", 1, true))
	chat.receive("yo", 2, "Alice", nil, "a")
	chat.receive("let me ask something", 2, "Alice", nil, "b")
	h.settle(2)
	check("one burst makes one reply", #requests == 1 and #chat.sent == 1)
	check("tagged reply", chat.sent[1].text == "[AGENT] Hey! What's up?")
	local request = requests[1]
	local batch = json.decode(request.messages[#request.messages].content)
	check("both fresh messages are included once", #batch == 2 and batch[1].message == "yo" and batch[2].message == "let me ask something")
	check("main transcript and old chat are excluded", not json.encode(request):find("PRIVATE_MAIN_CONVERSATION", 1, true)
		and not json.encode(request):find("old history", 1, true))
	check("text only and bounded", request.tools == nil and request.max_tokens == 256)
	check("custom instructions reach the bot", request.messages[1].content:find("Talk about building games.", 1, true))
	local usage = app.env.require("agent/usage")
	check("background usage does not change main turn totals", usage.session.total == 20 and usage.turn.total == 0)
	check("manual sending cannot double-answer", not dispatch(app, "chat_send", { message = "Another reply" }).ok)
	check("another loop cannot duplicate this channel", not dispatch(app, "chat_bot", {}).ok
		and not dispatch(app, "auto_reply", { rules = { { trigger = "yo", response = "Hi" } } }).ok)
	reply.text = "Sure, ask me about your game."
	app.providers.setModel(app.providers.active().id, "another-model")
	app.sessions.newThread(); chat.receive("can you help?", 2, "Alice", nil, "c")
	h.settle(7)
	check("switching conversation does not stop chatbot", #chat.sent == 2 and loops.list()[1].state == "running")
	check("bot retains selected model and its own prior reply", requests[2].model == "harness-model"
		and json.encode(requests[2]):find("Hey! What's up?", 1, true))
	check("status exposes requests", dispatch(app, "chat_loop_status", { id = result.data.id }).data[1].bot.requests == 2)
	clean(h, app)
end)

scenario("replayed IDs, duplicate text, self echoes, and filtered chat never double-reply", function()
	local h, app, chat, loops, requests = boot()
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("yo", 2, "Alice", nil, "first")
	chat.receive("yo", 2, "Alice", nil, "first")
	chat.receive("YO!", 2, "Alice", nil, "duplicate-text")
	chat.receive("mine", 1, "TestPlayer")
	chat.receive("system", nil, "System")
	chat.receive("other channel", 2, "Alice", "RBXTeam")
	chat.receive("###########", 3, "Bob")
	chat.receive("[AGENT] Hello", 3, "OtherBot")
	h.settle(2)
	check("exactly one input accepted", #requests == 1 and #json.decode(requests[1].messages[2].content) == 1 and #chat.sent == 1)
	for index = 1, 110 do chat.receive("system " .. index, nil, "System", nil, "filler" .. index) end
	h.settle(20)
	chat.receive("yo", 2, "Alice", nil, "first")
	chat.receive("YO!", 2, "Alice", nil, "duplicate-text")
	chat.receive("filtered echo", 1, "TestPlayer", nil, "echo")
	h.settle(3)
	check("IDs survive history rollover and cooldown", #requests == 1 and #chat.sent == 1)
	chat.receive("another question", 2, "Alice", nil, "new")
	h.settle(3)
	check("duplicate AI output is suppressed", #requests == 2 and #chat.sent == 1 and loops.list()[1].bot.skipped > 0)
	clean(h, app)
end)

scenario("slow inference is single-flight and queues later messages for one subsequent reply", function()
	local h, app, chat, loops, requests, reply = boot()
	reply.delay = 8
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("first question", 2, "Alice", nil, "a"); h.settle(2)
	for index = 1, 25 do chat.receive("follow-up " .. index, 2, "Alice", nil, "q" .. index) end
	h.settle(6)
	check("only one inference is running", #requests == 1 and #chat.sent == 0 and loops.list()[1].bot.generating)
	check("queue is bounded under load", #loops.list()[1].bot.queue == 20 and loops.list()[1].bot.dropped == 5)
	reply.text = "Here's the follow-up answer."
	h.settle(3)
	check("first result sends once", #requests == 1 and #chat.sent == 1)
	h.settle(14)
	check("later burst sends once", #requests == 2 and #chat.sent == 2)
	check("new batch has each retained message once", #json.decode(requests[2].messages[#requests[2].messages].content) == 20)
	check("send pacing holds", chat.sent[2].at - chat.sent[1].at >= 5000)
	clean(h, app)
end)

scenario("stop, clear, removal, permission changes, deadline, and unload discard late inference", function()
	for _, action in ipairs({ "stop", "clear", "remove", "disable", "deny", "deadline", "unload" }) do
		local h, app, chat, loops, requests, reply = boot()
		reply.delay = 15
		assert(dispatch(app, "chat_bot", { duration = 10 }).ok)
		chat.receive("hello", 2, "Alice", nil, "a"); h.settle(2)
		check(action .. " has an in-flight request", #requests == 1)
		if action == "stop" then h.click(h.byName("StopChatLoops"))
		elseif action == "clear" then app.sessions.current().clear()
		elseif action == "remove" then app.sessions.remove(app.sessions.current().id)
		elseif action == "disable" then app.tools.setGroupEnabled("chat", false)
		elseif action == "deny" then app.env.require("agent/permissions").setRule("chat_bot", "deny")
		elseif action == "unload" then app.destroy() end
		h.settle(20)
		check(action .. " discards late answer", #chat.sent == 0 and #loops.running() == 0)
		if action ~= "unload" then clean(h, app) else check("unload stays clean", #h.errors() == 0) end
	end
end)

scenario("a yielding or ambiguous SendAsync is submitted at most once", function()
	for _, fail in ipairs({ false, true }) do
		local h, app, chat, loops = boot()
		local submissions = 0
		chat.addChannel("RBXGeneral", function(text)
			submissions = submissions + 1
			h.sandbox.task.wait(8)
			if fail then error("Unknown delivery status") end
			chat.sent[#chat.sent + 1] = { text = text }
		end)
		assert(dispatch(app, "chat_bot", {}).ok)
		chat.receive("hi", 2, "Alice", nil, "a"); h.settle(3)
		chat.receive("hi", 2, "Alice", nil, "a")
		if not fail then loops.stop() end
		h.settle(20)
		check("only one send was submitted", submissions == 1)
		check("no follow-up job remains", loops.list()[1].state == (fail and "failed" or "stopped"))
		check("failed delivery never claims success", loops.list()[1].sent == 0)
		clean(h, app)
	end
end)

scenario("reply normalization is duplicate-safe and UTF-8 stays within one message", function()
	local h, app, chat, loops, requests, reply = boot()
	reply.text = "[AGENT] [AGENT] Hello!"
	assert(dispatch(app, "chat_bot", { count = 2 }).ok)
	chat.receive("hi", 2, "Alice", nil, "a"); h.settle(3)
	check("prefix appears only once", chat.sent[1].text == "[AGENT] Hello!")
	reply.text = " hello. "
	chat.receive("question two", 2, "Alice", nil, "b"); h.settle(7)
	check("case whitespace punctuation variants are suppressed", #chat.sent == 1)
	reply.text = "<skip>"
	chat.receive("nothing to answer", 2, "Alice", nil, "c"); h.settle(7)
	check("skip is never posted", #chat.sent == 1)
	reply.text = string.rep("你好🌟\n", 100)
	chat.receive("question four", 2, "Alice", nil, "d"); h.settle(7)
	check("one bounded unicode message", #chat.sent == 2 and app.env.require("runtime/gamechat").validate(chat.sent[2].text))
	check("no line breaks or broken UTF-8", not chat.sent[2].text:find("\n", 1, true)
		and app.env.require("runtime/util").validUtf8(chat.sent[2].text))
	check("reply cap completes", loops.list()[1].state == "completed" and #requests == 4)
	clean(h, app)
end)

scenario("player scope, startup validation, and provider errors are reported", function()
	local h, app, chat, loops, requests, reply = boot({ noProvider = true })
	check("missing provider rejected", not dispatch(app, "chat_bot", {}).ok and #loops.list() == 0)
	clean(h, app)
	h, app, chat, loops, requests, reply = boot()
	check("bad prefix rejected", not dispatch(app, "chat_bot", { prefix = "bad\nprefix" }).ok)
	check("unknown channel rejected", not dispatch(app, "chat_bot", { channel = "Missing" }).ok)
	check("subagent cannot start a bot", not loops.start("bot", {}, { session = app.sessions.current(), depth = 1 }))
	assert(dispatch(app, "chat_bot", { user_ids = { 2 }, prefix = "" }).ok)
	chat.receive("hello", 3, "Bob"); h.settle(2)
	check("non-target player ignored", #requests == 0)
	reply.status = 401
	chat.receive("hello", 2, "Alice"); h.settle(3)
	check("inference failure is visible and not sent", #requests == 1 and #chat.sent == 0 and loops.list()[1].state == "failed")
	reply.status, reply.text = nil, "No tag"
	assert(dispatch(app, "chat_bot", { prefix = "", count = 1 }).ok)
	chat.receive("fresh", 2, "Alice"); h.settle(3)
	check("empty prefix supported", chat.sent[1].text == "No tag")
	clean(h, app)
end)

scenario("native Anthropic adapter supports the independent text-only conversation", function()
	local h, app, chat, loops, requests = boot({ anthropic = true })
	assert(dispatch(app, "chat_bot", { count = 1 }).ok)
	chat.receive("hello", 2, "Alice", nil, "a"); h.settle(3)
	check("native request uses its system field", #requests == 1 and type(requests[1].system) == "string")
	check("native reply delivered once", #chat.sent == 1 and loops.list()[1].state == "completed")
	clean(h, app)
end)

scenario("legacy message IDs and ID-less duplicate events are consumed once", function()
	local h, app, _, loops, requests = boot()
	-- Reboot in a fresh sandbox so the legacy listener is selected at mount time.
	app.destroy()
	local legacy = envMock.new()
	legacy.http.handler = h.http.handler
	local incoming = legacy.Instance.new("TextBox").FocusLost
	local sent = {}
	legacy.services.TextChatService = { ChatVersion = legacy.sandbox.Enum.ChatVersion.LegacyChatService }
	legacy.services.ReplicatedStorage = { FindFirstChild = function(_, name)
		if name == "DefaultChatSystemChatEvents" then return { FindFirstChild = function(_, child)
			if child == "SayMessageRequest" then return { FireServer = function(_, text) sent[#sent + 1] = text end } end
			if child == "OnMessageDoneFiltering" then return { OnClientEvent = incoming } end
		end } end
	end }
	app = assert(legacy.boot()); legacy.settle(1)
	app.config.set("permissions.mode", "full")
	local record = app.providers.blank("custom")
	record.baseUrl, record.apiKey, record.model = "https://chatbot.test/v1", "test-key", "harness-model"
	assert(app.providers.save(record)); legacy.settle(1)
	assert(dispatch(app, "chat_bot", { channel = "Team" }).ok)
	incoming:Fire({ Message = "hello", FromSpeaker = "Alice", SpeakerUserId = 2, OriginalChannel = "Team", ID = 42 })
	incoming:Fire({ Message = "hello", FromSpeaker = "Alice", SpeakerUserId = 2, OriginalChannel = "Team", ID = 42 })
	legacy.settle(3)
	check("legacy duplicate id produces one reply", #requests == 1 and #sent == 1)
	for index = 1, 110 do incoming:Fire({ Message = "system " .. index, FromSpeaker = "System", OriginalChannel = "Team" }) end
	legacy.settle(20)
	incoming:Fire({ Message = "hello", FromSpeaker = "Alice", SpeakerUserId = 2, OriginalChannel = "Team", ID = 42 })
	legacy.settle(3)
	check("legacy id survives history eviction", #requests == 1)
	incoming:Fire({ Message = "follow up", FromSpeaker = "Alice", SpeakerUserId = 2, OriginalChannel = "Team" })
	incoming:Fire({ Message = "follow up", FromSpeaker = "Alice", SpeakerUserId = 2, OriginalChannel = "Team" })
	legacy.settle(3)
	check("ID-less duplicate events form one input", #requests == 2
		and #json.decode(requests[2].messages[#requests[2].messages].content) == 1)
	check("legacy repeated reply is not sent", #sent == 1)
	clean(legacy, app)
end)

scenario("stopped generations cannot answer for a replacement bot", function()
	local h, app, chat, loops, requests, reply = boot()
	reply.delay = 15
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("old bot", 2, "Alice", nil, "old"); h.settle(2)
	loops.stop()
	reply.delay, reply.text = 0, "Replacement bot reply."
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("new bot", 2, "Alice", nil, "new"); h.settle(20)
	check("only replacement reply sent", #requests == 2 and #chat.sent == 1 and chat.sent[1].text == "[AGENT] Replacement bot reply.")
	check("old generation remains stopped", loops.list()[1].state == "stopped" and loops.list()[2].state == "running")
	clean(h, app)
end)

scenario("final send rechecks duplicates that arrived while waiting for the shared sender", function()
	local h, app, chat, loops, requests, reply = boot()
	assert(dispatch(app, "auto_chat", { messages = { "Team update" }, channel = "Team", count = 1 }).ok)
	h.settle(1)
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("question", 2, "Alice", nil, "a"); h.settle(2)
	check("bot is waiting behind global pacing", #requests == 1 and #chat.sent == 1 and loops.list()[2].pending ~= nil)
	chat.receive("[AGENT] " .. reply.text, 1, "TestPlayer", nil, "manual")
	h.settle(5)
	check("manual echo prevents a duplicate send", #chat.sent == 1 and loops.list()[2].pending == nil)
	clean(h, app)
end)

scenario("skipped responses have a request budget and unexpected tool calls never execute", function()
	local h, app, chat, loops, requests, reply = boot()
	reply.text = "<skip>"
	assert(dispatch(app, "chat_bot", { count = 1 }).ok)
	for index = 1, 4 do chat.receive("question " .. index, 2, "Alice", nil, "q" .. index); h.settle(7) end
	check("skip cannot create unbounded requests", #requests == 3 and #chat.sent == 0 and loops.list()[1].state == "completed")
	reply.text = "Do this"
	reply.toolCalls = { { id = "bad", type = "function", ["function"] = { name = "chat_send", arguments = '{"message":"BAD"}' } } }
	assert(dispatch(app, "chat_bot", {}).ok)
	chat.receive("try tools", 2, "Alice", nil, "tools"); h.settle(3)
	check("unexpected tools fail without sending prose or executing", #chat.sent == 0 and loops.list()[2].state == "failed")
	clean(h, app)
end)

print(string.format("chat bot: %d checks passed, %d scenarios failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
