package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, json = require("env"), require("json")
local passed = 0
local function check(label, value) assert(value, label); passed = passed + 1; print("ok " .. label) end
local function setup()
	local h = envMock.new()
	local app = assert(h.boot()); h.settle(1)
	app.config.set("bridge.token", "test-bridge-token")
	app.config.set("bridge.runtime", "web")
	app.config.set("bridge.enabled", true, { quiet = true })
	return h, app
end
local function completion(text)
	return json.encode({ model = "test-model", choices = { { message = { role = "assistant", content = text }, finish_reason = "stop" } }, usage = { prompt_tokens = 5, completion_tokens = 2 } })
end

do
	local h, app = setup()
	local jobs, starts, submissions, polls = {}, 0, 0, 0
	h.http.handler = function(req)
		if req.url:find("/api/hello", 1, true) then return { StatusCode = 200, Body = '{"protocol":2,"instance":"server-one"}' } end
		if req.url:match("/api/inference$") then
			local input = json.decode(req.body); submissions = submissions + 1
			if not jobs[input.id] then jobs[input.id] = input; starts = starts + 1 end
			check("provider headers are forwarded only inside authenticated body", input.headers.Authorization == "Bearer provider-test" and req.headers.Authorization == "Bearer test-bridge-token")
			if submissions == 1 then error("submission response lost") end
			return { StatusCode = 202, Body = json.encode({ id = input.id, state = "running" }) }
		end
		local id = req.url:match("/api/inference/(.+)$")
		if id then
			polls = polls + 1
			if polls == 1 then error("poll failed") end
			if polls < 65 then return { StatusCode = 200, Body = json.encode({ id = id, state = "running" }) } end
			return { StatusCode = 200, Body = json.encode({ id = id, state = "completed", status = 200, body = completion("One answer"), headers = { ["content-type"] = "application/json" } }) }
		end
		error("unexpected direct request " .. req.url)
	end
	local record = app.providers.blank("custom")
	record.baseUrl, record.apiKey, record.model = "https://provider.invalid/v1", "provider-test", "test-model"
	assert(app.providers.save(record))
	local result, err
	h.sandbox.task.spawn(function() result, err = app.env.require("provider/chat").complete(record, { messages = { { role = "user", content = "test" } }, sessionId = app.sessions.current().id }) end)
	h.settle(75)
	check("inference outlives a sixty-second executor cap", result and result.content == "One answer")
	check("lost submission is retried with the same ID", starts == 1 and submissions == 2)
	check("result carries streaming correlation ID", result.requestId ~= nil and result.via == "web")
	check("polls stay out of request history", #app.env.require("net/http").history == 1)
	app.destroy(); h.settle(1); check("no callback errors", #h.errors() == 0)
end

do
	local h, app = setup()
	local aborted, deletes, started = false, 0, 0
	h.http.handler = function(req)
		if req.url:find("/hello", 1, true) then return { StatusCode = 200, Body = '{"protocol":2,"instance":"server-one"}' } end
		if req.method == "DELETE" then deletes = deletes + 1; return { StatusCode = 200, Body = '{}' } end
		local input = req.body and json.decode(req.body)
		if input then started = started + 1 end
		return { StatusCode = 200, Body = json.encode({ id = input and input.id or req.url:match("/inference/(.+)$"), state = "running" }) }
	end
	local response, err
	h.sandbox.task.spawn(function() response, err = app.env.require("net/http").send({ url = "https://provider.invalid/v1/chat/completions", method = "POST", body = "{}", relay = true, attempts = 5, aborted = function() return aborted end }) end)
	h.settle(2); aborted = true; h.settle(1)
	check("abort cancels upstream and never resubmits", response == nil and err == "aborted" and deletes == 1 and started == 1)
	app.destroy(); h.settle(1)
end

do
	local h, app = setup()
	local requests, id = 0
	h.http.handler = function(req)
		if req.url:find("/hello", 1, true) then return { StatusCode = 200, Body = '{"protocol":2,"instance":"server-one"}' } end
		if req.method == "DELETE" then return { StatusCode = 200, Body = '{}' } end
		if req.method == "POST" then requests = requests + 1; id = json.decode(req.body).id; return { StatusCode = 202, Body = json.encode({ id = id, state = "running" }) } end
		return { StatusCode = 404, Body = '{"error":"job lost"}' }
	end
	local result
	h.sandbox.task.spawn(function() result = app.env.require("net/http").send({ url = "https://provider.invalid", method = "POST", body = "{}", relay = true, attempts = 5 }) end)
	h.settle(4)
	check("lost relay job is terminal instead of paying twice", result and result.terminal and requests == 1)
	app.destroy(); h.settle(1)
end

do
	local h = envMock.new(); local app = assert(h.boot()); h.settle(1)
	local seen, acks, state, receivedText = 0, 0, nil, nil
	local original = app.sessions.current().send
	app.sessions.current().send = function() seen = seen + 1; return true end
	h.http.handler = function(req)
		if req.url:find("/inbox", 1, true) then return { StatusCode = 200, Body = json.encode({ commands = { { type = "send", text = "once", commandId = "duplicate-command", sessionId = app.sessions.current().id } } }), delay = 0.1 } end
		if req.url:find("/ack", 1, true) then acks = acks + 1; return { StatusCode = 200, Body = '{}' } end
		if req.url:find("/events", 1, true) then
			local body = json.decode(req.body); state = body.state or state
			for _, event in ipairs(body.events or {}) do if event.kind == "assistant:text" then receivedText = event.text end end
			return { StatusCode = 204, Body = '' }
		end
		return { StatusCode = 200, Body = '{}' }
	end
	app.config.set("bridge.token", "token"); app.config.set("bridge.enabled", true); h.settle(3)
	check("duplicate browser commands execute once", seen == 1 and acks > 0)
	check("web state includes real controls and theme", state and state.protocol == 2 and state.theme.canvas and state.settings.agent and state.tools[1].parameters)
	check("provider credentials are not exposed in state", not json.encode(state):find('apiKey', 1, true))
	local multiline = "First paragraph\n\n```lua\nprint('line one')\nprint('line two')\n```"
	app.sessions.current().emit("assistant:text", { text = multiline, final = true }); h.settle(1)
	check("bridge preserves Markdown and code line breaks", receivedText == multiline)
	app.sessions.current().send = original
	app.destroy(); h.settle(1); check("bridge callbacks stay clean", #h.errors() == 0)
end
do
	local h = envMock.new(); local app = assert(h.boot()); h.settle(1)
	local commands = app.env.require("net/bridge_commands")
	local session = app.sessions.current()
	check("runtime can switch while idle", commands.run({ type = "runtime", value = "web" }))
	session.busy = true
	check("runtime switch is rejected during work", not pcall(commands.run, { type = "runtime", value = "game" }))
	session.busy = false
	check("invalid settings are rejected", not pcall(commands.run, { type = "setting", path = "agent.toolConcurrency", value = 0 }))
	app.config.set("permissions.mode", "ask")
	local executed, result = 0, nil
	app.tools.register({ name = "bridge_test_write", risk = "write", group = "test", parameters = { type = "object", properties = {}, required = {} },
		run = function() executed = executed + 1; return "Done once" end })
	h.sandbox.task.spawn(function() result = commands.run({ type = "tool:run", name = "bridge_test_write", commandId = "manual-tool", arguments = {} }) end)
	h.settle(0.2)
	check("web tool execution uses real permission engine", app.env.require("agent/permissions").pendingCount() == 1 and executed == 0 and session.busy)
	for _, entry in pairs(app.env.require("agent/permissions").pending) do entry.resolve(true, false) end
	h.settle(1)
	check("approval releases exactly one tool execution", result and result.ok and executed == 1 and not session.busy)
	local answered
	session.emit("ask:user", { id = "web-question", question = "Choose a direction", options = { "Left", "Right" }, resolve = function(text) answered = text end })
	check("web can answer a real ask_user prompt", commands.run({ type = "ask:answer", id = "web-question", text = "Left" }) and answered == "Left")
	check("answered prompt cannot be answered twice", not pcall(commands.run, { type = "ask:answer", id = "web-question", text = "Right" }))
	app.destroy(); h.settle(1); check("management callbacks stay clean", #h.errors() == 0)
end
print("web runtime: " .. passed .. " checks passed")
