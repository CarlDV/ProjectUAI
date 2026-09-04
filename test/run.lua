-- Headless scenarios against the built bundle.
--
--   luajit tools/bundle.lua && luajit test/run.lua
--   luajit test/run.lua boot ua        (run only scenarios whose name matches)
--
-- Each scenario gets a fresh client: a new virtual clock, a new filesystem, a new
-- interface. Nothing carries over, so a failure is always reproducible on its own.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path

local envMock = require("env")
local json = require("json")

local suite = { passed = 0, failed = 0, scenarios = 0, failures = {} }
local filters = {}
for index = 1, #(arg or {}) do filters[#filters + 1] = tostring(arg[index]):lower() end

local current = "?"

local function report(ok, label, detail)
	if ok then
		suite.passed = suite.passed + 1
		print("    ok   " .. label)
	else
		suite.failed = suite.failed + 1
		suite.failures[#suite.failures + 1] = current .. " / " .. label
		print("    FAIL " .. label)
		if detail then
			for line in tostring(detail):gmatch("[^\n]+") do print("           " .. line) end
		end
	end
end

local function check(label, got, want)
	report(got == want, label, got == want and nil
		or ("got  " .. tostring(got) .. "\nwant " .. tostring(want)))
end

local function truthy(label, value, detail)
	report(value and true or false, label, (not value) and (detail or "value was falsy") or nil)
end

local function contains(label, haystack, needle)
	local found = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
	report(found, label, found and nil
		or ("looking for: " .. tostring(needle) .. "\nin: " .. tostring(haystack):sub(1, 400)))
end

local function scenario(name, fn)
	if #filters > 0 then
		local matched = false
		for _, filter in ipairs(filters) do
			if name:lower():find(filter, 1, true) then matched = true end
		end
		if not matched then return end
	end
	suite.scenarios = suite.scenarios + 1
	current = name
	print("  " .. name)
	local ok, err = pcall(fn)
	if not ok then
		suite.failed = suite.failed + 1
		suite.failures[#suite.failures + 1] = name .. " / crashed"
		print("    FAIL scenario crashed")
		for line in tostring(err):gmatch("[^\n]+") do print("           " .. line) end
	end
end

-- Shared fixtures ----------------------------------------------------------

local function chatBody(opts)
	opts = opts or {}
	local message = { role = "assistant", content = opts.content or "" }
	if opts.reasoning then message.reasoning_content = opts.reasoning end
	if opts.toolCalls then message.tool_calls = opts.toolCalls end
	return json.encode({
		id = "cmpl_1",
		model = opts.model or "harness-model",
		choices = { { index = 0, message = message, finish_reason = opts.finish or (opts.toolCalls and "tool_calls" or "stop") } },
		usage = { prompt_tokens = 120, completion_tokens = 40, total_tokens = 160 },
	})
end

-- An Anthropic Messages response, which is a different shape entirely: content is a
-- list of typed blocks and the stop reason names tool_use rather than tool_calls.
local function messagesBody(opts)
	opts = opts or {}
	local content = {}
	if opts.text then content[#content + 1] = { type = "text", text = opts.text } end
	if opts.toolUse then
		content[#content + 1] = {
			type = "tool_use",
			id = opts.toolUse.id,
			name = opts.toolUse.name,
			input = opts.toolUse.input or {},
		}
	end
	return json.encode({
		id = "msg_harness",
		type = "message",
		role = "assistant",
		model = opts.model or "claude-opus-5",
		content = content,
		stop_reason = opts.stop or (opts.toolUse and "tool_use" or "end_turn"),
		usage = { input_tokens = 100, output_tokens = 20 },
	})
end

local function toolCall(id, name, args)
	return {
		id = id,
		type = "function",
		["function"] = { name = name, arguments = json.encode(args or {}) },
	}
end

-- Boots a client with one provider configured and a scripted HTTP handler.
local function bootWith(opts)
	opts = opts or {}
	local harness = envMock.new({ executor = opts.executor })
	harness.http.handler = opts.handler
	local handle, err = harness.boot()
	if not handle then error("boot failed: " .. tostring(err), 0) end
	harness.settle(1)

	if opts.provider ~= false then
		local record = handle.providers.blank("custom")
		record.label = opts.label or "Harness"
		record.baseUrl = opts.baseUrl or "https://harness.test/v1"
		record.apiKey = "sk-harness-key-1234"
		record.model = opts.model or "harness-model"
		record.models = { opts.model or "harness-model" }
		record.stream = opts.stream == true
		local saved, problems = handle.providers.save(record)
		if not saved then error("provider rejected: " .. table.concat(problems or {}, ", "), 0) end
	end

	harness.settle(1)
	return harness, handle
end

local function chatRequests(harness)
	local out = {}
	for _, entry in ipairs(harness.http.log) do
		if tostring(entry.url):find("/chat/completions") then out[#out + 1] = entry end
	end
	return out
end

print("uai scenarios")
print(("="):rep(72))

-- 1. Boot ------------------------------------------------------------------

scenario("boot mounts the interface", function()
	local harness, handle = bootWith({ provider = false })

	truthy("bootstrap returned a handle", handle ~= nil)
	check("version reported", handle.version, "1.0.0")
	truthy("handle is alive", handle.alive)

	local screen = harness.screen()
	truthy("a ScreenGui was created", screen ~= nil, harness.dump(harness.coreGui))
	truthy("the launcher exists", screen:FindFirstChild("Launcher") ~= nil)
	truthy("the window exists", screen:FindFirstChild("UAI_Window") ~= nil)
	truthy("the overlay layer exists", screen:FindFirstChild("Overlay") ~= nil)

	check("no thread errors during boot", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("nothing was warned", #harness.console.warnings, 0,
		table.concat(harness.console.warnings, "\n"))

	local text = harness.textOf(screen)
	contains("the chat tab is present", text, "Chat")
	contains("the providers tab is present", text, "Providers")
	contains("the empty state explains what to do", text, "No provider configured")
end)

-- 2. Capabilities ----------------------------------------------------------

scenario("capabilities are detected from the host", function()
	local harness, handle = bootWith({ provider = false })
	check("executor transport chosen", handle.caps.http, "executor")
	check("user agent supported", handle.caps.uaSupported, true)
	check("filesystem detected", handle.caps.fs, true)
	check("code execution detected", handle.caps.exec, true)
	check("executor identified", handle.caps.executor, "OfflineHarness 1.0")

	local vanilla = envMock.new({ executor = false })
	local vanillaHandle = select(1, vanilla.boot())
	truthy("a client with no executor still boots", vanillaHandle ~= nil)
	check("falls back to HttpService", vanillaHandle.caps.http, "roblox")
	check("reports that it cannot set a user agent", vanillaHandle.caps.uaSupported, false)
	check("reports no filesystem", vanillaHandle.caps.fs, false)
end)

-- 3. Claude Code identity --------------------------------------------------

scenario("requests carry the Claude Code identity", function()
	local harness, handle = bootWith({
		handler = function() return { StatusCode = 200, Body = chatBody({ content = "Ready." }) } end,
	})

	handle.sessions.current().send("hello")
	harness.settle(6)

	local requests = chatRequests(harness)
	check("one chat request was sent", #requests, 1)
	local headers = requests[1] and requests[1].headers or {}

	contains("user agent is the claude-cli string", tostring(headers["User-Agent"]), "claude-cli/")
	contains("user agent marks itself external", tostring(headers["User-Agent"]), "(external, cli)")
	check("x-app identifies the cli", headers["x-app"], "cli")
	check("stainless language header", headers["X-Stainless-Lang"], "js")
	check("stainless runtime header", headers["X-Stainless-Runtime"], "node")
	truthy("stainless os header present", headers["X-Stainless-OS"] ~= nil)
	truthy("stainless arch header present", headers["X-Stainless-Arch"] ~= nil)
	check("retry count starts at zero", headers["X-Stainless-Retry-Count"], "0")
	check("authorization uses the key", headers["Authorization"], "Bearer sk-harness-key-1234")
	check("the executor transport was used", requests[1].via, "executor")

	-- And the identity is genuinely gone on a transport that cannot carry it.
	local vanilla = envMock.new({ executor = false })
	vanilla.http.handler = function() return { StatusCode = 200, Body = chatBody({ content = "ok" }) } end
	local vanillaHandle = select(1, vanilla.boot())
	local record = vanillaHandle.providers.blank("custom")
	record.label = "Vanilla"
	record.baseUrl = "https://harness.test/v1"
	record.apiKey = "sk-key"
	record.model = "m"
	record.models = { "m" }
	vanillaHandle.providers.save(record)
	vanillaHandle.sessions.current().send("hello")
	vanilla.settle(6)

	local vanillaRequests = chatRequests(vanilla)
	truthy("the vanilla client still sent the request", #vanillaRequests >= 1)
	local dropped = vanillaRequests[1] and vanillaRequests[1].droppedHeaders or {}
	local sawUserAgent = false
	for _, name in ipairs(dropped) do
		if tostring(name):lower() == "user-agent" then sawUserAgent = true end
	end
	truthy("RequestAsync dropped the user agent, as the real one does", sawUserAgent,
		"dropped: " .. table.concat(dropped, ", "))

	-- The client's own request log is what the Logs panel shows, so it has to say
	-- the identity did not make it rather than implying it did.
	local clientHistory = vanillaHandle.env.require("net/http").history
	local lastEntry = clientHistory[#clientHistory]
	truthy("the client logged the request", lastEntry ~= nil)
	check("and records that the identity did not reach the wire", lastEntry.uaSent, false)
	check("while the executor client records that it did",
		(function()
			local history = handle.env.require("net/http").history
			return history[#history].uaSent
		end)(), true)
end)

-- 4. Models ----------------------------------------------------------------

scenario("models come from the endpoint, never from a guess", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if tostring(entry.url):find("/models") then
				return {
					StatusCode = 200,
					Body = json.encode({ data = {
						{ id = "zeta-1" }, { id = "alpha-2" }, { id = "text-embedding-9" },
					} }),
				}
			end
			return { StatusCode = 200, Body = chatBody({ content = "hi" }) }
		end,
	})

	local catalog = handle.env.require("provider/catalog")
	local seeded = 0
	for _, preset in ipairs(catalog.presets) do
		seeded = seeded + #(preset.models or {})
	end
	check("no preset ships a model list", seeded, 0)

	local models = handle.env.require("provider/models")
	local record = handle.providers.active()
	local found, note = models.discover(record, { force = true })
	harness.settle(1)

	check("every id the endpoint returned is offered", #found, 3)
	check("sorted", found[1], "alpha-2")
	contains("the note names the endpoint", note, "/models")
	truthy("nothing was filtered out",
		table.concat(found, ","):find("text-embedding-9", 1, true) ~= nil,
		table.concat(found, ","))

	local listed = models.list(record)
	check("the manual entry still ranks first", listed[1], "harness-model")

	-- Manual addition is a first-class path, for endpoints with no /models route.
	local added, result = models.add(record, "typed-by-hand")
	check("a typed id is accepted", added, true)
	check("and becomes the selection", handle.providers.active().model, "typed-by-hand")
	check("the second add of the same id is rejected", select(1, models.add(record, "typed-by-hand")), false)

	models.remove(record, "typed-by-hand")
	truthy("removal falls back to another model", handle.providers.active().model ~= "typed-by-hand")

	local strict = handle.providers.blank("custom")
	strict.label = "No model"
	strict.baseUrl = "https://x.test/v1"
	strict.apiKey = "sk-y"
	local okSave, problems = handle.providers.save(strict)
	check("a provider with no model is refused", okSave, false)
	contains("and says why", table.concat(problems or {}, " "), "model")
end)

-- 5. Tool loop -------------------------------------------------------------

scenario("the loop runs tools and answers", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					content = "Let me look.",
					toolCalls = { toolCall("call_1", "game_info", {}) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "This place is Mock Place 123456789." }) }
		end,
	})

	local session = handle.sessions.current()
	session.send("what game is this")
	harness.settle(8)

	check("two requests were made", #chatRequests(harness), 2)
	check("the session is idle again", session.busy, false)

	local kinds = {}
	for _, event in ipairs(session.log) do kinds[event.kind] = (kinds[event.kind] or 0) + 1 end
	check("a tool call was announced", kinds["tool:call"], 1)
	check("a tool result came back", kinds["tool:result"], 1)
	check("the turn ended", kinds["turn:end"], 1)
	check("nothing errored", kinds["error"], nil)

	local roles = {}
	for _, message in ipairs(session.ctx.messages) do roles[#roles + 1] = message.role end
	check("context holds user, assistant, tool, assistant", table.concat(roles, ","),
		"user,assistant,tool,assistant")

	local toolMessage = session.ctx.messages[3]
	contains("the tool result reached the model", toolMessage.content, "PlaceId")
	check("the tool result is addressed to its call", toolMessage.tool_call_id, "call_1")

	local screen = harness.textOf()
	contains("the transcript shows the tool", screen, "game_info")
	contains("the transcript shows the answer", screen, "Mock Place")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 6. Parallel tool calls ---------------------------------------------------

scenario("tool calls in one turn run together", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = {
						toolCall("a", "game_info", {}),
						toolCall("b", "players_list", {}),
						toolCall("c", "agent_status", {}),
					},
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Done." }) }
		end,
	})

	local session = handle.sessions.current()
	session.send("three things at once")
	harness.settle(10)

	local results = 0
	for _, event in ipairs(session.log) do
		if event.kind == "tool:result" then results = results + 1 end
	end
	check("all three results came back", results, 3)

	local toolMessages = 0
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then toolMessages = toolMessages + 1 end
	end
	check("all three reached the model", toolMessages, 3)
	check("nothing errored", #harness.errors(), 0)
end)

-- 7. Streaming -------------------------------------------------------------

scenario("a streamed body is assembled", function()
	local frames = {
		{ choices = { { index = 0, delta = { role = "assistant", content = "The " } } } },
		{ choices = { { index = 0, delta = { content = "answer" } } } },
		{ choices = { { index = 0, delta = { reasoning_content = "thinking about it" } } } },
		{ choices = { { index = 0, delta = { content = " is 42." } } } },
		{ choices = { { index = 0, delta = {}, finish_reason = "stop" } },
			usage = { prompt_tokens = 7, completion_tokens = 3, total_tokens = 10 } },
	}
	local body = {}
	for _, frame in ipairs(frames) do body[#body + 1] = "data: " .. json.encode(frame) end
	body[#body + 1] = "data: [DONE]"

	local harness, handle = bootWith({
		stream = true,
		handler = function() return { StatusCode = 200, Body = table.concat(body, "\n\n") .. "\n\n" } end,
	})

	local session = handle.sessions.current()
	session.send("what is the answer")
	harness.settle(6)

	local last = session.ctx.messages[#session.ctx.messages]
	check("content was concatenated in order", last.content, "The answer is 42.")
	check("reasoning was kept separately", last.reasoning, "thinking about it")

	local requests = chatRequests(harness)
	contains("stream was requested", requests[1].body, '"stream":true')
	contains("usage was requested with it", requests[1].body, "include_usage")

	-- The tool_calls fragment assembly is the part that actually needs testing:
	-- name arrives once, arguments arrive in pieces.
	local sse = handle.env.require("net/sse")
	local pieces = {
		{ choices = { { delta = { tool_calls = { { index = 0, id = "call_x", ["function"] = { name = "instance_get" } } } } } } },
		{ choices = { { delta = { tool_calls = { { index = 0, ["function"] = { arguments = '{"pa' } } } } } } },
		{ choices = { { delta = { tool_calls = { { index = 0, ["function"] = { arguments = 'th":"Workspace"}' } } } } } } },
		{ choices = { { delta = {}, finish_reason = "tool_calls" } } },
	}
	local raw = {}
	for _, piece in ipairs(pieces) do raw[#raw + 1] = "data: " .. json.encode(piece) end
	local parsed = sse.parse(table.concat(raw, "\n\n") .. "\n\ndata: [DONE]\n\n")
	check("one call was assembled", #parsed.toolCalls, 1)
	check("its id survived", parsed.toolCalls[1].id, "call_x")
	check("its name survived", parsed.toolCalls[1]["function"].name, "instance_get")
	check("its arguments were joined", parsed.toolCalls[1]["function"].arguments, '{"path":"Workspace"}')
	check("finish reason read", parsed.finish, "tool_calls")
end)

-- 8. Retry and fallback ----------------------------------------------------

scenario("a rate limit is retried and a dead provider is skipped", function()
	local attempts = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			attempts = attempts + 1
			if attempts == 1 then
				return { StatusCode = 429, Body = '{"error":{"message":"slow down"}}', Headers = { ["Retry-After"] = "1" } }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Recovered." }) }
		end,
	})

	local session = handle.sessions.current()
	session.send("hello")
	harness.settle(20)

	check("it retried once and then succeeded", attempts, 2)
	local retried = false
	for _, event in ipairs(session.log) do
		if event.kind == "request:retry" then retried = true end
	end
	truthy("the retry was reported to the interface", retried)
	check("the answer landed", session.ctx.messages[#session.ctx.messages].content, "Recovered.")
end)

scenario("a failing provider hands over to the next", function()
	local harness, handle = bootWith({
		label = "Primary",
		baseUrl = "https://primary.test/v1",
		handler = function(entry)
			if tostring(entry.url):find("primary") then
				return { StatusCode = 500, Body = '{"error":{"message":"boom"}}' }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Secondary answered." }) }
		end,
	})

	local second = handle.providers.blank("custom")
	second.label = "Secondary"
	second.baseUrl = "https://secondary.test/v1"
	second.apiKey = "sk-second"
	second.model = "second-model"
	second.models = { "second-model" }
	handle.providers.save(second)

	local session = handle.sessions.current()
	session.send("hello")
	harness.settle(30)

	local switched = false
	for _, event in ipairs(session.log) do
		if event.kind == "provider:switch" then switched = true end
	end
	truthy("the switch was reported", switched)
	check("the second provider answered", session.ctx.messages[#session.ctx.messages].content,
		"Secondary answered.")

	local primary = handle.providers.get(handle.providers.list()[1].id)
	truthy("the failure was recorded against a provider",
		(handle.providers.get("primary") or primary).health.fail > 0)
end)

scenario("transient failures are retried and real refusals are not", function()
	local _, handle = bootWith({ provider = false })
	local http = handle.env.require("net/http")

	-- The policy is a predicate, so it is cheaper and far clearer to state it
	-- exhaustively here than to script fifteen handlers. The 403 rows are the point:
	-- these gateways return one for an exhausted shared quota or an edge filter and
	-- interleave them with 200s, so the body is what separates "busy" from "no".
	local cases = {
		{ "a transport error", nil, "timed out", true },
		{ "408", { status = 408, body = "" }, nil, true },
		{ "429", { status = 429, body = "" }, nil, true },
		{ "500", { status = 500, body = "" }, nil, true },
		{ "529", { status = 529, body = "" }, nil, true },
		{ "a 502 HTML error page", { status = 502, body = "<html>bad gateway</html>" }, nil, true },
		{ "a 403 with no body at all", { status = 403, body = "" }, nil, true },
		{ "a 403 naming an exhausted quota", { status = 403,
			body = '{"error":{"message":"用户额度不足"}}' }, nil, true },
		{ "a 403 refusing the model", { status = 403,
			body = '{"error":{"message":"You do not have access to this model"}}' }, nil, false },
		{ "401", { status = 401, body = '{"error":{"message":"bad key"}}' }, nil, false },
		{ "404", { status = 404, body = '{"error":{"message":"no such model"}}' }, nil, false },
		{ "a 400 schema complaint", { status = 400,
			body = '{"error":{"message":"TOOL_SCHEMA_INVALID"}}' }, nil, false },
		{ "a 200 hiding an overload", { status = 200, ok = true,
			body = '{"error":{"message":"server_is_overloaded"}}' }, nil, true },
		{ "a 200 hiding a rate limit in an SSE frame", { status = 200, ok = true,
			body = 'data: {"type":"error","error":{"message":"upstream_provider_rate_limit"}}' }, nil, true },
		{ "a 200 whose reply merely mentions rate limits", { status = 200, ok = true,
			body = '{"choices":[{"message":{"content":"You will hit a rate_limit if you loop."}}]}' }, nil, false },
	}
	for _, case in ipairs(cases) do
		local got = http.shouldRetry(case[2], case[3]) and true or false
		check(case[1] .. " -> " .. (case[4] and "retry" or "report"), got, case[4])
	end

	-- And end to end, because the unit table proves the predicate and not the wiring:
	-- a bodyless 403 followed by a 200 has to produce an answer rather than an error,
	-- which is exactly the sequence in the log that prompted this.
	local hits = 0
	local live, liveHandle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			hits = hits + 1
			if hits == 1 then return { StatusCode = 403, Body = "" } end
			return { StatusCode = 200, Body = chatBody({ content = "Recovered after a 403." }) }
		end,
	})
	local session = liveHandle.sessions.current()
	session.send("hello")
	live.settle(30)

	check("the bodyless 403 was retried once", hits, 2)
	check("and the answer landed", session.ctx.messages[#session.ctx.messages].content,
		"Recovered after a 403.")
	local reason
	for _, event in ipairs(session.log) do
		if event.kind == "request:retry" then reason = event.reason end
	end
	truthy("the transcript was told a retry happened", reason ~= nil, "no request:retry event")
	contains("and why", tostring(reason), "403")
	check("no thread errors", #live.errors(), 0,
		live.errors()[1] and live.errors()[1].traceback or nil)
end)

scenario("a request that dies on a deadline is not paid for twice", function()
	-- The gateway accepts the request and bills the whole prompt; the transport gives
	-- up a minute later with no status and no headers of its own. Read as a bodyless
	-- refusal worth another go, one turn became three identical billed requests.
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 403, Body = "", headerless = true, delay = 20 }
		end,
	})

	local session = handle.sessions.current()
	session.send("hello")
	harness.settle(180)

	check("the dead request was sent once", #chatRequests(harness), 1)

	local retried, errorEvent
	for _, event in ipairs(session.log) do
		if event.kind == "request:retry" then retried = event end
		if event.kind == "error" then errorEvent = event end
	end
	truthy("and never repeated", retried == nil)
	truthy("an error was reported", errorEvent ~= nil)
	contains("naming the wait, not a status the server never sent",
		errorEvent and errorEvent.message or "", "nothing returned after")
	check("the session recovered", session.busy, false)

	-- Headers present means a real server answered, and the rule that retries an
	-- unexplained 403 still applies to it.
	local http = handle.env.require("net/http")
	check("a prompt bodyless 403 is still retried",
		http.shouldRetry({ status = 403, body = "" }, nil, { elapsed = 400 }) and true or false, true)
	check("the same 403 after a minute is not",
		http.shouldRetry({ status = 403, body = "" }, nil, { elapsed = 60000 }) and true or false, false)
	check("nor a transport error that took a minute to produce nothing",
		http.shouldRetry(nil, "gave up", { elapsed = 60000 }) and true or false, false)
	check("while a quick one still is",
		http.shouldRetry(nil, "connection reset", { elapsed = 120 }) and true or false, true)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 9. Permissions -----------------------------------------------------------

scenario("a write tool waits for permission", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("w1", "instance_create", { class = "Folder", name = "Made", parent = "Workspace" }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Created it." }) }
		end,
	})

	handle.config.set("permissions.mode", "ask")

	local asked = nil
	local session = handle.sessions.current()
	session.events:connect(function(event)
		if event.kind == "permission:ask" then
			asked = event
			event.resolve(true, false)
		end
	end)

	session.send("make a folder called Made")
	harness.settle(10)

	truthy("permission was requested", asked ~= nil)
	check("for the right tool", asked and asked.name, "instance_create")
	check("marked as a write", asked and asked.risk, "write")
	truthy("the arguments were passed to the prompt", asked and asked.args and asked.args.class == "Folder")
	truthy("the folder now exists", harness.workspace:FindFirstChild("Made") ~= nil,
		harness.dump(harness.workspace))

	-- And a denial stops it.
	local denied = envMock.new({})
	denied.http.handler = function(entry)
		if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
		return { StatusCode = 200, Body = chatBody({
			toolCalls = { toolCall("w2", "instance_create", { class = "Folder", name = "Nope", parent = "Workspace" }) },
		}) }
	end
	local deniedHandle = select(1, denied.boot())
	local record = deniedHandle.providers.blank("custom")
	record.label = "D"
	record.baseUrl = "https://harness.test/v1"
	record.apiKey = "sk-d"
	record.model = "m"
	record.models = { "m" }
	deniedHandle.providers.save(record)
	deniedHandle.config.set("permissions.mode", "ask")
	local deniedSession = deniedHandle.sessions.current()
	deniedSession.events:connect(function(event)
		if event.kind == "permission:ask" then event.resolve(false, false) end
	end)
	deniedSession.send("make a folder")
	denied.settle(12)
	check("a denied tool creates nothing", denied.workspace:FindFirstChild("Nope"), nil)
	local sawDenial = false
	for _, message in ipairs(deniedSession.ctx.messages) do
		if message.role == "tool" and tostring(message.content):find("did not approve") then sawDenial = true end
	end
	truthy("the model was told it was refused", sawDenial)
end)

scenario("read-only mode hides everything that writes", function()
	local harness, handle = bootWith({ provider = false })
	handle.config.set("permissions.mode", "readonly")
	local definitions = handle.tools.definitions()
	local writes = 0
	for _, definition in ipairs(definitions) do
		local tool = handle.tools.get(definition["function"].name)
		if tool and tool.risk ~= "read" then writes = writes + 1 end
	end
	check("no write tool is offered", writes, 0)
	truthy("read tools are still offered", #definitions > 10)

	handle.config.set("permissions.mode", "auto")
	local all = handle.tools.definitions()
	truthy("auto mode offers more", #all > #definitions)
end)

-- 10. Loop safety ----------------------------------------------------------

scenario("an identical repeated call is broken", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			return { StatusCode = 200, Body = chatBody({
				toolCalls = { toolCall("same", "game_info", {}) },
			}) }
		end,
	})
	handle.config.set("agent.maxTurns", 8)

	local session = handle.sessions.current()
	session.send("loop please")
	harness.settle(30)

	local rejected = false
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" and tostring(message.content):find("will not be run again") then
			rejected = true
		end
	end
	truthy("the repeat was refused rather than run forever", rejected)
	check("the session finished", session.busy, false)
end)

scenario("a stop request ends the turn", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			return { StatusCode = 200, Body = chatBody({
				toolCalls = { toolCall("w" .. tostring(math.floor(1)), "wait", { seconds = 2 }) },
			}) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("wait around")
	harness.settle(0.5)
	session.abort()
	harness.settle(12)

	check("the session is idle", session.busy, false)
	local aborted = false
	for _, event in ipairs(session.log) do
		if event.kind == "abort" then aborted = true end
	end
	truthy("an abort was reported", aborted)
end)

-- 11. Context --------------------------------------------------------------

scenario("context trimming never orphans a tool result", function()
	local harness, handle = bootWith({ provider = false })
	local context = handle.env.require("agent/context").new()

	for turn = 1, 12 do
		context.pushUser(string.rep("question " .. turn .. " ", 60))
		context.pushAssistant({
			content = "",
			toolCalls = { { id = "c" .. turn, type = "function", ["function"] = { name = "game_info", arguments = "{}" } } },
		})
		context.pushToolResult("c" .. turn, "game_info", string.rep("result " .. turn .. " ", 80))
		context.pushAssistant({ content = "answer " .. turn })
	end

	local before = context.tokens()
	truthy("the conversation is over budget", before > 4000, tostring(before))
	context.trim(2000, 2)
	truthy("it came down", context.tokens() < before)

	-- The invariant: a tool message must be preceded by the assistant turn that
	-- asked for it, or every provider rejects the payload.
	local wire = context.wire("system")
	local orphans = 0
	for index, message in ipairs(wire) do
		if message.role == "tool" then
			local previous = wire[index - 1]
			local parentIsAssistant = previous and previous.role == "assistant" and previous.toolCalls ~= nil
			local previousWasTool = previous and previous.role == "tool"
			if not (parentIsAssistant or previousWasTool) then orphans = orphans + 1 end
		end
	end
	check("no orphaned tool results", orphans, 0)

	local ids = {}
	for _, message in ipairs(wire) do
		for _, call in ipairs(message.toolCalls or {}) do ids[call.id] = true end
	end
	local unmatched = 0
	for _, message in ipairs(wire) do
		if message.role == "tool" and not ids[message.tool_call_id] then unmatched = unmatched + 1 end
	end
	check("every tool result has its call", unmatched, 0)
end)

-- 12. Payload shape --------------------------------------------------------

scenario("the request payload is shaped the way gateways expect", function()
	local harness, handle = bootWith({
		handler = function() return { StatusCode = 200, Body = chatBody({ content = "ok" }) } end,
	})
	handle.config.set("permissions.mode", "auto")

	handle.sessions.current().send("hello")
	harness.settle(6)

	local body = chatRequests(harness)[1].body
	contains("a model is named", body, '"model":"harness-model"')
	contains("tools are sent", body, '"tools":[')
	contains("tool_choice is auto", body, '"tool_choice":"auto"')
	contains("parallel calls are enabled", body, '"parallel_tool_calls":true')
	truthy("no empty properties array survives", body:find('"properties":%[%]') == nil,
		"an empty JSON array was sent where an object is required")
	contains("zero-argument tools send an object", body, '"properties":{}')

	-- Anthropic-on-Bedrock validates every tool schema against JSON Schema draft
	-- 2020-12 and answers a bare TOOL_SCHEMA_INVALID, so the shape has to be right
	-- before it leaves. An empty Luau table encoding as [] is how this breaks, and
	-- it has to be caught on the wire text: once decoded, {} and [] are the same
	-- empty Lua table and the bug is invisible.
	local ARRAY_KEYS = {
		required = true, enum = true, examples = true, allOf = true, anyOf = true,
		oneOf = true, prefixItems = true,
		-- Payload arrays, not schema keywords.
		tools = true, messages = true, content = true, tool_calls = true, stop = true,
	}
	local emptyArrays = {}
	for key in body:gmatch('"([%w_%$]+)":%[%]') do
		if not ARRAY_KEYS[key] then emptyArrays[#emptyArrays + 1] = key end
	end
	truthy("no schema keyword encodes as an empty array", #emptyArrays == 0,
		"these came out as []: " .. table.concat(emptyArrays, ", "))

	local TYPES = {
		object = true, array = true, string = true, number = true,
		integer = true, boolean = true, ["null"] = true,
	}
	local schemaProblems = {}
	local function auditSchema(node, path)
		if type(node) ~= "table" then return end
		if node.type ~= nil and not TYPES[node.type] then
			schemaProblems[#schemaProblems + 1] = path .. ": type " .. tostring(node.type)
		end
		if node.type == "array" and node.items == nil then
			schemaProblems[#schemaProblems + 1] = path .. ": array without items"
		end
		for _, name in ipairs(node.required or {}) do
			if (node.properties or {})[name] == nil then
				schemaProblems[#schemaProblems + 1] = path .. ": requires undeclared " .. tostring(name)
			end
		end
		for key, value in pairs(node) do
			if type(value) == "table" and not ARRAY_KEYS[key] then
				auditSchema(value, path .. "." .. tostring(key))
			end
		end
	end
	local decoded = json.decode(body)
	for _, definition in ipairs(decoded.tools or {}) do
		auditSchema(definition["function"].parameters, definition["function"].name)
	end
	truthy("every tool schema is valid draft 2020-12", #schemaProblems == 0,
		table.concat(schemaProblems, "\n"))

	check("the system prompt leads", decoded.messages[1].role, "system")
	contains("it describes the host", decoded.messages[1].content, "Host:")
	contains("it names the place", decoded.messages[1].content, "PlaceId")
	check("the user turn follows", decoded.messages[2].role, "user")
	truthy("every tool has a description", (function()
		for _, definition in ipairs(decoded.tools) do
			if type(definition["function"].description) ~= "string" then return false end
		end
		return true
	end)())
end)

-- 13. Malformed model output ----------------------------------------------

scenario("broken tool arguments are repaired or reported", function()
	local harness, handle = bootWith({ provider = false })
	local schema = handle.env.require("agent/schema")

	local fenced, note = schema.repairJson('```json\n{"path":"Workspace"}\n```')
	check("a fenced object is read", fenced and fenced.path, "Workspace")

	local truncated = schema.repairJson('{"path":"Workspace","depth":')
	truthy("a truncated object is completed", truncated ~= nil and truncated.path == "Workspace")

	local trailing = schema.repairJson('{"path":"Workspace",}')
	check("a trailing comma is removed", trailing and trailing.path, "Workspace")

	local pythonic = schema.repairJson('{"path":"Workspace","recursive":True}')
	check("Python literals are converted", pythonic and pythonic.recursive, true)

	local prose = schema.repairJson('Sure! {"path":"Workspace"} hope that helps')
	check("surrounding prose is stripped", prose and prose.path, "Workspace")

	local hopeless = schema.repairJson("path = Workspace")
	check("genuinely broken input is refused", hopeless, nil)

	local coerced, errors = schema.validate({
		type = "object",
		properties = { depth = { type = "integer" }, path = { type = "string" } },
		required = { "path" },
	}, { depth = "3", path = "Workspace" })
	check("a numeric string is coerced", coerced.depth, 3)
	check("with no complaint", #errors, 0)

	local _, missing = schema.validate({
		type = "object",
		properties = { path = { type = "string" } },
		required = { "path" },
	}, {})
	check("a missing required field is reported", #missing, 1)
end)

-- 14. Filesystem tools -----------------------------------------------------

scenario("file tools stay inside the agent folder", function()
	local harness, handle = bootWith({ provider = false })
	handle.config.set("permissions.mode", "full")
	local tools = handle.tools
	local context = handle.sessions.current().toolContext()

	local write = tools.dispatch({ id = "1", ["function"] = {
		name = "file_write",
		arguments = json.encode({ path = "notes/plan.txt", content = "step one" }),
	} }, context)
	truthy("a write succeeds", write.ok, write.text)
	check("it landed in the agent folder", harness.files["UAI/notes/plan.txt"], "step one")

	local read = tools.dispatch({ id = "2", ["function"] = {
		name = "file_read", arguments = json.encode({ path = "notes/plan.txt" }),
	} }, context)
	contains("and reads back", read.text, "step one")

	local escape = tools.dispatch({ id = "3", ["function"] = {
		name = "file_write", arguments = json.encode({ path = "../../escape.txt", content = "no" }),
	} }, context)
	check("a path traversal is refused", escape.ok, false)
	contains("with a reason", escape.text, "..")
	check("and nothing was written outside", harness.files["../../escape.txt"], nil)
end)

-- 15. Responsiveness -------------------------------------------------------

scenario("the interface follows the viewport", function()
	local harness, handle = bootWith({ provider = false })
	local responsive = handle.env.require("ui/responsive")

	check("a desktop viewport is a window", responsive.mode, "window")

	harness.setViewport(390, 844)
	check("a phone viewport becomes a sheet", responsive.mode, "sheet")
	check("and reports the breakpoint", responsive.breakpoint, "xs")
	check("and the orientation", responsive.orientation, "portrait")
	truthy("the window survived the rebuild", harness.screen():FindFirstChild("UAI_Window") ~= nil,
		harness.dump())
	local sheet = harness.byName("UAI_Window")
	truthy("the sheet spans the width", sheet.AbsoluteSize.X > 340,
		tostring(sheet.AbsoluteSize.X))
	truthy("and does not exceed the viewport", sheet.AbsoluteSize.X <= 390)
	truthy("and leaves room above it", sheet.AbsoluteSize.Y < 844)

	harness.setViewport(834, 1112)
	check("a tablet viewport docks as a panel", responsive.mode, "panel")

	harness.setViewport(1920, 1080)
	check("back to a window on a large screen", responsive.mode, "window")

	-- Touch changes the minimum hit target, which is the thing a phone actually
	-- needs from a layout.
	harness.services.UserInputService.TouchEnabled = true
	responsive.refresh("test")
	check("touch raises the minimum target", responsive.minTarget(), 44)
	harness.services.UserInputService.TouchEnabled = false
	responsive.refresh("test")
	check("a pointer lowers it", responsive.minTarget(), 28)

	-- The on-screen keyboard must move the window, not cover the composer.
	harness.services.UserInputService.OnScreenKeyboardVisible = true
	harness.services.UserInputService.OnScreenKeyboardSize = harness.dt.Vector2.new(390, 300)
	harness.services.UserInputService:GetPropertyChangedSignal("OnScreenKeyboardVisible"):Fire()
	harness.settle(1)
	check("the keyboard height is reported", responsive.keyboardHeight, 300)
	truthy("and counted as an obstruction", responsive.bottomObstruction() >= 300)

	check("no thread errors through all of that", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("theme tokens react to settings", function()
	local harness, handle = bootWith({ provider = false })
	local theme = handle.env.require("ui/theme")

	local comfortable = theme.space.md
	handle.config.set("ui.density", "compact")
	harness.settle(1)
	truthy("compact density tightens spacing", theme.space.md < comfortable,
		tostring(theme.space.md) .. " vs " .. tostring(comfortable))

	local before = theme.text.body.size
	handle.config.set("ui.fontScale", 1.3)
	harness.settle(1)
	truthy("text scale grows the ramp", theme.text.body.size > before)

	handle.config.set("ui.accent", "rose")
	harness.settle(1)
	check("the accent changed", theme.accentName, "rose")
	truthy("the interface rebuilt without error", harness.screen():FindFirstChild("UAI_Window") ~= nil)

	-- And the converse, which is the expensive half. A theme rebuild fires
	-- theme.changed, and the app answers that by destroying and reconstructing every
	-- panel, the window and the launcher. Accepting the whole `ui.` namespace meant
	-- maximising the window, moving the launcher or switching panel each tore the
	-- interface down and built it again -- once a second, in the log that prompted
	-- this test.
	local rebuilds = 0
	local unsubscribe = theme.changed:connect(function() rebuilds = rebuilds + 1 end)
	for _, path in ipairs({ "ui.window.maximised", "ui.window.width", "ui.panel",
		"ui.showReasoning", "ui.launcher.x" }) do
		handle.config.set(path, path == "ui.window.width" and 900 or false)
	end
	harness.settle(1)
	check("an unrelated ui key does not rebuild the theme", rebuilds, 0)

	handle.config.set("ui.accent", "aurora")
	harness.settle(1)
	truthy("but a token key still does", rebuilds >= 1, tostring(rebuilds))
	pcall(unsubscribe)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 16. Markdown -------------------------------------------------------------

scenario("markdown blocks are split correctly", function()
	local harness, handle = bootWith({ provider = false })
	local markdown = handle.env.require("ui/markdown")

	local blocks = markdown.blocks(table.concat({
		"Here is the plan.",
		"",
		"- first",
		"- second",
		"",
		"```lua",
		"local x = 1 < 2",
		"```",
		"",
		"Done.",
	}, "\n"))

	check("four blocks", #blocks, 4)
	check("prose first", blocks[1].kind, "text")
	check("then bullets", blocks[2].kind, "bullets")
	check("two of them", #blocks[2].items, 2)
	check("then code", blocks[3].kind, "code")
	check("with its language", blocks[3].lang, "lua")
	check("kept verbatim", blocks[3].text, "local x = 1 < 2")
	check("then prose", blocks[4].kind, "text")

	local inline = markdown.inline("use **bold** and `code < here`")
	contains("bold becomes a tag", inline, "<b>bold</b>")
	contains("inline code gets the mono face", inline, 'face="Code"')
	truthy("a raw angle bracket was escaped", inline:find("&lt;", 1, true) ~= nil, inline)

	local unterminated = markdown.blocks("```lua\nlocal a = 1")
	check("an unterminated fence still renders", unterminated[1].kind, "code")
	check("and says so", unterminated[1].unterminated, true)
end)

-- 17. Subagent -------------------------------------------------------------

scenario("a subagent reports back without filling the parent context", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("s1", "dispatch_agent", { task = "count the players", preset = "read" }) },
				}) }
			end
			if step == 2 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("s2", "players_list", {}) },
				}) }
			end
			if step == 3 then
				return { StatusCode = 200, Body = chatBody({ content = "There is one player: TestPlayer." }) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "The subagent found one player." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("how many players are here")
	harness.settle(20)

	check("the parent context stayed small", #session.ctx.messages, 4)
	local report = session.ctx.messages[3]
	check("the report came back as a tool result", report.role, "tool")
	contains("carrying the subagent's answer", report.content, "one player")
	contains("labelled as a subagent report", report.content, "Subagent report")
	check("the parent answered", session.ctx.messages[4].content, "The subagent found one player.")

	-- The live view. The child's work is forwarded onto the parent's stream, because
	-- that stream is the only thing the transcript renders -- and it is addressed, so
	-- three concurrent subagents cannot paint over each other's rows.
	local kinds = {}
	local start
	for _, event in ipairs(session.log) do
		kinds[event.kind] = (kinds[event.kind] or 0) + 1
		if event.kind == "subagent:start" then start = event end
	end
	check("the dispatch was announced", kinds["subagent:start"], 1)
	check("the tool the child ran was forwarded", kinds["subagent:tool"], 1)
	check("with its outcome", kinds["subagent:tool:done"], 1)
	check("what it said between calls", kinds["subagent:text"], 1)
	check("and the finish", kinds["subagent:done"], 1)
	contains("the card is labelled with the task", start and start.label or "", "count the players")
	check("and addressed to the call that started it", start and start.call, "s1")

	truthy("a card was rendered for it", harness.byName("Subagent") ~= nil)
	truthy("nested inside the dispatch row rather than floating beside it",
		harness.byName("Subagent", harness.byName("Tool")) ~= nil)
	local shown = harness.textOf()
	contains("showing which tool the child ran", shown, "players_list")
	contains("and the task it was given", shown, "count the players")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("no property type errors", #harness.instanceState.typeErrors, 0,
		table.concat(harness.instanceState.typeErrors, "\n"))
end)

-- A subagent runs for minutes by design. The generic tool timeout is twenty-five
-- seconds, and until this was fixed it was what bounded the dispatching call: every
-- subagent was reported to the model as abandoned, kept running -- Luau cannot kill a
-- thread -- and finished into a caller that had stopped listening. The log said
-- "subagent finished in 26.1s over 9 messages" and the user was told nothing came back.
scenario("a slow subagent is not cut off by the generic tool timeout", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent", { task = "take your time", preset = "read" }) },
				}) }
			end
			if step == 2 then
				-- Longer than the generic timeout set below, shorter than the subagent's
				-- own budget.
				return { StatusCode = 200, delay = 8, Body = chatBody({ content = "Took a while: found nothing." }) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "The subagent reported back." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.config.set("agent.toolTimeout", 5)

	local subagent = handle.env.require("agent/subagent")
	local tool = handle.env.require("agent/registry").get("dispatch_agent")
	check("the tool states a timeout of its own", type(tool.timeout), "function")
	check("resolved from the subagent budget", tool.timeout(), subagent.toolTimeout())
	truthy("which is far past the generic one", tool.timeout() > handle.config.get("agent.toolTimeout"))
	handle.config.set("agent.subagentBudget", 60)
	check("and follows the setting", tool.timeout(), 120)
	handle.config.set("agent.subagentBudget", 240)

	local session = handle.sessions.current()
	session.send("delegate something slow")
	harness.settle(40)

	local report
	for _, entry in ipairs(session.ctx.messages) do
		if entry.role == "tool" then report = entry end
	end
	truthy("the call produced a report", report ~= nil)
	contains("carrying what the subagent found", report and report.content or "", "found nothing")
	truthy("and nothing was abandoned",
		not tostring(report and report.content or ""):find("did not finish"),
		tostring(report and report.content or ""))
	check("so the parent could answer with it",
		session.ctx.messages[#session.ctx.messages].content, "The subagent reported back.")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("stopping a turn stops the subagents it started", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent", { task = "keep digging", preset = "read" }) },
				}) }
			end
			return { StatusCode = 200, delay = 8, Body = chatBody({
				toolCalls = { toolCall("c1", "players_list", {}) },
			}) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("delegate then change your mind")
	harness.settle(3)
	truthy("the turn is running", session.busy)
	session.abort()
	harness.settle(40)

	local done
	for _, event in ipairs(session.log) do
		if event.kind == "subagent:done" then done = event end
	end
	truthy("the subagent reported back rather than running on", done ~= nil)
	truthy("and says it was stopped", done and done.aborted == true)
	truthy("the child made no further requests after the stop", step <= 2,
		"requests: " .. tostring(step))
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 18. Persistence ----------------------------------------------------------

scenario("settings and conversations persist", function()
	local harness, handle = bootWith({})
	handle.config.set("ui.accent", "amber")
	handle.config.saveNow()
	handle.sessions.current().ctx.pushUser("remember me")
	handle.sessions.persist(handle.sessions.current())
	harness.settle(2)

	truthy("a config file was written", harness.files["UAI/config.json"] ~= nil,
		table.concat((function()
			local keys = {}
			for key in pairs(harness.files) do keys[#keys + 1] = key end
			table.sort(keys)
			return keys
		end)(), "\n"))
	contains("with the setting in it", harness.files["UAI/config.json"], "amber")

	local sessionFiles = 0
	for key in pairs(harness.files) do
		if key:find("^UAI/sessions/") then sessionFiles = sessionFiles + 1 end
	end
	check("a conversation was written", sessionFiles, 1)

	-- A second client with the same filesystem should come back to the same state.
	local second = envMock.new({})
	for key, value in pairs(harness.files) do second.files[key] = value end
	for key in pairs(harness.folders) do second.folders[key] = true end
	local secondHandle = select(1, second.boot())
	second.settle(2)
	check("the accent came back", secondHandle.config.get("ui.accent"), "amber")
	truthy("the provider came back", secondHandle.providers.count() >= 1)
	local restored = false
	for _, session in ipairs(secondHandle.sessions.list()) do
		for _, message in ipairs(session.ctx.messages) do
			if tostring(message.content):find("remember me") then restored = true end
		end
	end
	truthy("the conversation came back", restored)
end)

-- 19. Error surfaces -------------------------------------------------------

scenario("a provider error is explained, not swallowed", function()
	local harness, handle = bootWith({
		handler = function()
			return { StatusCode = 401, Body = '{"error":{"message":"Incorrect API key provided"}}' }
		end,
	})

	local session = handle.sessions.current()
	session.send("hello")
	harness.settle(20)

	local errorEvent
	for _, event in ipairs(session.log) do
		if event.kind == "error" then errorEvent = event end
	end
	truthy("an error was reported", errorEvent ~= nil)
	contains("naming the cause", errorEvent and errorEvent.message or "", "API key")
	contains("and the transcript says so", harness.textOf(), "API key")
	check("the session recovered", session.busy, false)

	-- A 401 must not be retried: the key will not become correct.
	check("no pointless retries", #chatRequests(harness), 1)
end)

scenario("an unknown tool and a bad argument are reported to the model", function()
	local harness, handle = bootWith({ provider = false })
	local context = handle.sessions.current().toolContext()

	local unknown = handle.tools.dispatch({ id = "u", ["function"] = {
		name = "definitely_not_a_tool", arguments = "{}",
	} }, context)
	check("unknown tools do not raise", unknown.ok, false)
	contains("and suggest what exists", unknown.text, "Available tools include")

	local bad = handle.tools.dispatch({ id = "b", ["function"] = {
		name = "instance_get", arguments = json.encode({}),
	} }, context)
	check("a missing required argument is caught", bad.ok, false)
	contains("and named", bad.text, "path")

	local missingPath = handle.tools.dispatch({ id = "c", ["function"] = {
		name = "instance_get", arguments = json.encode({ path = "Workspace.NotThere" }),
	} }, context)
	truthy("a bad path explains itself", tostring(missingPath.text):find("has no child") ~= nil,
		missingPath.text)
end)

-- 20. Tool surface ---------------------------------------------------------

scenario("the tool catalog is broad and consistent", function()
	local harness, handle = bootWith({ provider = false })
	local tools = handle.tools.list()
	truthy("there are plenty of tools", #tools >= 45, tostring(#tools))

	local seen, problems = {}, {}
	for _, tool in ipairs(tools) do
		if seen[tool.name] then problems[#problems + 1] = "duplicate: " .. tool.name end
		seen[tool.name] = true
		if not tool.name:match("^[a-z][a-z0-9_]*$") then
			problems[#problems + 1] = "not snake_case: " .. tool.name
		end
		if type(tool.description) ~= "string" or #tool.description < 20 then
			problems[#problems + 1] = "thin description: " .. tool.name
		end
		if tool.risk ~= "read" and tool.risk ~= "write" and tool.risk ~= "danger" then
			problems[#problems + 1] = "bad risk: " .. tool.name
		end
		if type(tool.parameters) ~= "table" or tool.parameters.type ~= "object" then
			problems[#problems + 1] = "bad schema: " .. tool.name
		end
		for _, name in ipairs(tool.parameters.required or {}) do
			local properties = tool.parameters.properties or {}
			if properties[name] == nil then
				problems[#problems + 1] = tool.name .. " requires an undeclared field: " .. name
			end
		end
	end
	check("no catalog problems", #problems, 0, table.concat(problems, "\n"))

	local groups = handle.tools.stats().byGroup
	truthy("tools are spread across groups", (function()
		local count = 0
		for _ in pairs(groups) do count = count + 1 end
		return count >= 10
	end)())

	local dangerous = {}
	for _, tool in ipairs(tools) do
		if tool.risk == "danger" then dangerous[#dangerous + 1] = tool.name end
	end
	truthy("the destructive ones are marked", #dangerous >= 4, table.concat(dangerous, ", "))
	local expected = { run_luau = true, instance_destroy = true, file_delete = true, remote_fire = true }
	for name in pairs(expected) do
		truthy(name .. " is marked dangerous", (function()
			for _, item in ipairs(dangerous) do
				if item == name then return true end
			end
			return false
		end)())
	end
end)

scenario("luau execution is sandboxed and bounded", function()
	local harness, handle = bootWith({ provider = false })
	handle.config.set("permissions.mode", "full")
	local context = handle.sessions.current().toolContext()

	local result = handle.tools.dispatch({ id = "r", ["function"] = {
		name = "run_luau",
		arguments = json.encode({ code = "print('from the sandbox') return 6 * 7" }),
	} }, context)
	truthy("it ran", result.ok, result.text)
	contains("output was captured, not printed", result.text, "from the sandbox")
	contains("the return value came back", result.text, "42")
	check("nothing reached the real console", #harness.console.out, 0,
		table.concat(harness.console.out, "\n"))

	local broken = handle.tools.dispatch({ id = "r2", ["function"] = {
		name = "run_luau", arguments = json.encode({ code = "this is not lua" }),
	} }, context)
	contains("a compile error is reported", broken.text, "Compile error")

	local raising = handle.tools.dispatch({ id = "r3", ["function"] = {
		name = "run_luau", arguments = json.encode({ code = "error('deliberate')" }),
	} }, context)
	contains("a runtime error is reported", raising.text, "deliberate")
end)

scenario("every panel builds cleanly", function()
	local harness, handle = bootWith({})

	-- Visiting all five panels exercises most of the component set. The mock
	-- type-checks every property assignment, so this is where a wrong value type --
	-- a number handed to Size because a prop table overloaded the name -- surfaces.
	for _, panel in ipairs({ "providers", "tools", "settings", "logs", "chat" }) do
		handle.app.show(panel)
		harness.settle(1)
		truthy(panel .. " panel built", handle.app.panels[panel] ~= nil)
	end

	local typeErrors = harness.instanceState.typeErrors
	check("no property was assigned the wrong type", #typeErrors, 0,
		table.concat((function()
			local out = {}
			for index = 1, math.min(#typeErrors, 8) do out[index] = typeErrors[index] end
			return out
		end)(), "\n"))

	local unknownReads = {}
	for key in pairs(harness.instanceState.unknownReads) do unknownReads[#unknownReads + 1] = key end
	table.sort(unknownReads)
	check("no unknown property was read", #unknownReads, 0, table.concat(unknownReads, "\n"))

	local unknownEnums = {}
	for key in pairs(harness.unknownEnums) do unknownEnums[#unknownEnums + 1] = key end
	table.sort(unknownEnums)
	check("no unrecognised enum was used", #unknownEnums, 0, table.concat(unknownEnums, "\n"))

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("nothing was warned", #harness.console.warnings, 0,
		table.concat(harness.console.warnings, "\n"))
end)

scenario("the built interface holds its layout invariants", function()
	-- Two rules Roblox will not enforce and the mock cannot render, so they are
	-- asserted on the props instead.
	--
	-- One: a TextLabel starts at zero size, and `auto` only covers the axes it names, so
	-- `auto = "Y"` still leaves the width to the caller. A wrapped label that never
	-- gets one does not vanish -- which would at least be obvious -- it wraps at
	-- zero and renders one character per line, straight down the screen. The mock
	-- has no layout solver and cannot see that happen, but it does not need one:
	-- the mistake is in the props, so that is where this looks.
	--
	-- Two: a UIListLayout owns the Position of every GuiObject child it is given. A
	-- decoration that anchors itself to an edge does not merely fail to move, it
	-- becomes a layout item -- and a full-width one in a row takes the whole line
	-- and puts every sibling past the right edge, which is how a title bar goes
	-- missing without a single error.
	local function nameOf(value)
		if type(value) == "table" and value.Name then return tostring(value.Name) end
		return tostring(value)
	end

	local widths, anchors = {}, {}
	local seenWidth, seenAnchor = {}, {}

	local function sweep(harness)
		for _, node in ipairs(harness.screen():GetDescendants()) do
			local path = node:GetFullName()

			if node.ClassName == "TextLabel" or node.ClassName == "TextBox" then
				local truncates = nameOf(node.TextTruncate) == "AtEnd"
				local auto = nameOf(node.AutomaticSize)
				-- An auto width is the one case where the label sizes itself.
				local ownsWidth = auto == "X" or auto == "XY"
				if (node.TextWrapped == true or truncates) and not ownsWidth then
					local size = node.Size
					local width = type(size) == "table" and size.X or nil
					if (not width or (width.Scale == 0 and width.Offset <= 0)) and not seenWidth[path] then
						seenWidth[path] = true
						widths[#widths + 1] = string.format(
							"%s  wrap=%s truncate=%s auto=%s  text=%q",
							path, tostring(node.TextWrapped), tostring(truncates), auto,
							tostring(node.Text):sub(1, 48))
					end
				end
			end

			local parent = node.Parent
			if node:IsA("GuiObject") and parent and parent:FindFirstChildOfClass("UIListLayout") then
				local anchor = node.AnchorPoint
				local position = node.Position
				local placed = type(position) == "table"
					and (position.X.Scale ~= 0 or position.X.Offset ~= 0
						or position.Y.Scale ~= 0 or position.Y.Offset ~= 0)
				local anchored = type(anchor) == "table" and (anchor.X ~= 0 or anchor.Y ~= 0)
				if (placed or anchored) and not seenAnchor[path] then
					seenAnchor[path] = true
					anchors[#anchors + 1] = string.format(
						"%s  position=(%g,%g),(%g,%g) anchor=(%g,%g)",
						path, position.X.Scale, position.X.Offset, position.Y.Scale,
						position.Y.Offset, anchor.X, anchor.Y)
				end
			end
		end
	end

	-- Both states matter: a configured client renders the cards and headers, an
	-- unconfigured one renders the empty states, and they share almost no labels.
	for _, configured in ipairs({ true, false }) do
		local harness, handle = bootWith({ provider = configured })
		for _, panel in ipairs({ "providers", "tools", "settings", "logs", "chat" }) do
			handle.app.show(panel)
			harness.settle(1)
			sweep(harness)
		end

		-- Modals build their own header rather than going through a panel, and the
		-- provider editor is the densest form in the app, so both need walking too.
		handle.env.require("ui/panels/providers").editor(
			handle.providers.blank("openai"), function() end)
		harness.settle(1)
		sweep(harness)

		handle.env.require("ui/overlay").confirm({
			title = "Remove the thing?",
			description = "It will not come back.",
		})
		harness.settle(1)
		sweep(harness)
	end

	-- `truthy` rather than `check`, because `check` builds its own got/want detail and
	-- the offending paths are the only part of a failure here worth reading.
	truthy("every wrapped or truncated label has a width", #widths == 0,
		table.concat(widths, "\n"))
	truthy("nothing positions itself inside a list layout", #anchors == 0,
		table.concat(anchors, "\n"))
end)

scenario("the window and its controls respond to input", function()
	local harness, handle = bootWith({
		handler = function() return { StatusCode = 200, Body = chatBody({ content = "Got it." }) } end,
	})
	local window = handle.app.window

	-- The launcher is the only way back in once the window is closed, so the
	-- toggle has to work in both directions.
	truthy("the window starts open", window.visible)
	truthy("closing it works", harness.click(harness.byName("Close")) and not window.visible)
	harness.click(harness.byName("Launcher"))
	truthy("the launcher reopens it", window.visible)

	-- Nav.
	harness.click(harness.byName("Segment_tools"))
	check("a nav segment switches panel", handle.app.panel, "tools")
	harness.click(harness.byName("Segment_chat"))
	check("and back", handle.app.panel, "chat")

	-- Drag. The header is the handle; the body deliberately is not, so the
	-- transcript can still be dragged to scroll.
	local before = window.root.Position.X.Offset
	harness.drag(harness.byName("Header"), 400, 100, 520, 160)
	truthy("dragging the header moves the window",
		window.root.Position.X.Offset ~= before,
		tostring(before) .. " -> " .. tostring(window.root.Position.X.Offset))

	-- Resize.
	local sizeBefore = window.root.Size.X.Offset
	harness.drag(harness.byName("ResizeGrip"), 900, 700, 700, 500)
	truthy("dragging the grip resizes it",
		window.root.Size.X.Offset ~= sizeBefore,
		tostring(sizeBefore) .. " -> " .. tostring(window.root.Size.X.Offset))
	truthy("but not below the minimum", window.root.Size.X.Offset >= 340)

	-- Maximise rebuilds the shell, so the handle has to be re-read afterwards.
	harness.click(harness.byName("Maximise"))
	truthy("maximise takes effect", handle.app.window.maximised)
	truthy("and the window is still there", harness.byName("Header") ~= nil)

	-- Sending from the composer: type into the field, press the button.
	local field = harness.byName("Prompt")
	truthy("the composer field exists", field ~= nil)
	local box = field and field:FindFirstChildOfClass("TextBox")
	truthy("with a text box", box ~= nil)
	box.Text = "hello from the composer"
	harness.click(harness.byName("Send"))
	harness.settle(6)

	check("a request was sent", #chatRequests(harness), 1)
	contains("the transcript shows what was typed", harness.textOf(), "hello from the composer")
	contains("and the reply", harness.textOf(), "Got it.")
	check("the field was cleared", box.Text, "")

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("no property type errors", #harness.instanceState.typeErrors, 0,
		table.concat(harness.instanceState.typeErrors, "\n"))
end)

scenario("overlays can be dismissed and answered", function()
	local harness, handle = bootWith({ provider = false })
	local overlay = handle.env.require("ui/overlay")

	local confirmed, cancelled = false, false
	overlay.confirm({
		title = "Delete the thing?",
		description = "It will not come back.",
		confirmText = "Delete",
		danger = true,
		onConfirm = function() confirmed = true end,
		onCancel = function() cancelled = true end,
	})
	harness.settle(0.6)
	contains("the confirmation is on screen", harness.textOf(), "Delete the thing?")
	contains("with the consequence spelled out", harness.textOf(), "will not come back")

	local deleteButton
	for _, node in ipairs(harness.screen():GetDescendants()) do
		if node.__props.Text == "Delete" then deleteButton = node end
	end
	truthy("the confirm button is labelled by its action, not 'OK'", deleteButton ~= nil)
	-- The label is inside the button, so the click goes to its ancestor.
	harness.click(deleteButton and deleteButton.Parent and deleteButton.Parent.Parent)
	check("confirming fires the callback", confirmed, true)
	check("and not the cancel one", cancelled, false)
	truthy("the modal closed", harness.textOf():find("Delete the thing?", 1, true) == nil)

	-- A menu selects a value and closes itself.
	local picked = nil
	local target = harness.byName("Launcher")
	overlay.menu({
		target = target,
		options = {
			{ label = "First", value = "one" },
			{ label = "Second", value = "two", selected = true },
		},
		onSelect = function(value) picked = value end,
	})
	harness.settle(0.4)
	contains("the menu rendered its options", harness.textOf(), "Second")
	local firstOption
	for _, node in ipairs(harness.screen():GetDescendants()) do
		if node.__props.Text == "First" then firstOption = node end
	end
	harness.click(firstOption and firstOption.Parent and firstOption.Parent.Parent
		and firstOption.Parent.Parent.Parent)
	check("selecting reports the value", picked, "one")

	-- A toast appears and expires on its own.
	overlay.toast("saved", "good", 1)
	harness.settle(0.3)
	contains("the toast is visible", harness.textOf(), "saved")
	harness.settle(3)

	-- A dropdown opened from inside a modal has to sit above it. The preset menu in
	-- the Add provider dialog opened *behind* the dialog, because the dropdown layer
	-- ranked below the modal one -- and since ZIndexBehavior is Sibling, the
	-- comparison that decides it is between the two scrims, which are siblings under
	-- the overlay layer.
	local dialog = overlay.modal({ title = "Pick a preset", width = 380 })
	harness.settle(0.4)
	local inModal = overlay.menu({
		target = harness.byName("Launcher"),
		options = { { label = "One", value = "1" }, { label = "Two", value = "2" } },
	})
	harness.settle(0.4)
	local menuLayer = harness.byName("MenuLayer")
	local modalScrim = harness.byName("Scrim")
	truthy("a menu opened over a modal exists", menuLayer ~= nil, harness.dump())
	truthy("and ranks above the modal it was opened from",
		menuLayer and modalScrim and menuLayer.ZIndex > modalScrim.ZIndex,
		tostring(menuLayer and menuLayer.ZIndex) .. " vs " .. tostring(modalScrim and modalScrim.ZIndex))
	if inModal then inModal.close() end
	if dialog then dialog.close() end
	harness.settle(0.6)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 22. Anthropic wire ------------------------------------------------------

scenario("the Anthropic Messages API is spoken natively", function()
	local step = 0
	local harness = envMock.new({})
	harness.http.handler = function(entry)
		if not tostring(entry.url):find("/messages") then return { StatusCode = 404, Body = "{}" } end
		step = step + 1
		if step == 1 then
			return { StatusCode = 200, Body = messagesBody({
				text = "Let me look.",
				toolUse = { id = "toolu_1", name = "game_info" },
			}) }
		end
		return { StatusCode = 200, Body = messagesBody({ text = "This place is Mock Place 123456789." }) }
	end
	local handle = select(1, harness.boot())
	harness.settle(1)

	local record = handle.providers.blank("anthropic-messages")
	record.label = "Claude"
	record.apiKey = "sk-ant-harness"
	record.model = "claude-opus-5"
	record.models = { "claude-opus-5" }
	record.stream = false
	local saved, problems = handle.providers.save(record)
	truthy("the native preset saves", saved, table.concat(problems or {}, ", "))
	check("and is marked as the messages api", handle.providers.active().api, "anthropic")
	handle.config.set("permissions.mode", "full")
	harness.settle(1)

	local session = handle.sessions.current()
	session.send("what game is this")
	harness.settle(14)

	local requests = {}
	for _, entry in ipairs(harness.http.log) do
		if tostring(entry.url):find("/messages") then requests[#requests + 1] = entry end
	end
	check("two requests were made", #requests, 2)
	contains("to the messages endpoint", requests[1] and requests[1].url or "", "/v1/messages")
	check("authenticated with x-api-key", requests[1] and requests[1].headers["x-api-key"], "sk-ant-harness")
	check("and versioned", requests[1] and requests[1].headers["anthropic-version"], "2023-06-01")

	local first = json.decode(requests[1].body)
	truthy("the system prompt is hoisted to a top-level field",
		type(first.system) == "string" and #first.system > 0)
	check("so no message carries the system role", (function()
		for _, message in ipairs(first.messages or {}) do
			if message.role == "system" then return "found one" end
		end
		return "none"
	end)(), "none")
	truthy("max_tokens is sent, as this API requires", (first.max_tokens or 0) > 0)
	check("temperature is not, because current models reject it", first.temperature, nil)
	truthy("tools declare input_schema", first.tools and first.tools[1]
		and first.tools[1].input_schema ~= nil)
	check("and carry no function wrapper", first.tools[1]["function"], nil)

	-- The fiddly half: a tool result goes back as a tool_result block inside a USER
	-- turn, preceded by the assistant turn that asked for it. Getting either wrong is
	-- a 400 from the API rather than a wrong answer.
	local second = json.decode(requests[2].body)
	local last = second.messages[#second.messages]
	check("the tool result came back as a user turn", last.role, "user")
	check("carrying a tool_result block", last.content[1].type, "tool_result")
	check("addressed to the call", last.content[1].tool_use_id, "toolu_1")
	local asked = second.messages[#second.messages - 1]
	check("preceded by the assistant turn that asked", asked.role, "assistant")
	truthy("which replays the tool_use block verbatim", (function()
		for _, block in ipairs(asked.content or {}) do
			if block.type == "tool_use" and block.id == "toolu_1" then return true end
		end
		return false
	end)(), json.encode(asked.content or {}))

	check("the answer landed", session.ctx.messages[#session.ctx.messages].content,
		"This place is Mock Place 123456789.")

	-- The streamed form, checked directly: its events are Anthropic's own, and the
	-- tool input arrives as concatenated JSON fragments.
	local anthropic = handle.env.require("provider/anthropic")
	local streamed = anthropic.parseStream(table.concat({
		'data: {"type":"message_start","message":{"id":"msg_s","model":"claude-opus-5","usage":{"input_tokens":9}}}',
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi "}}',
		'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}',
		'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_s","name":"game_info"}}',
		'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\":"}}',
		'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"1}"}}',
		'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}',
		'data: {"type":"message_stop"}',
	}, "\n\n") .. "\n\n")
	check("streamed text was concatenated", streamed.content, "Hi there")
	check("one streamed call was assembled", #streamed.toolCalls, 1)
	check("its id survived", streamed.toolCalls[1].id, "toolu_s")
	check("its input json was joined", streamed.toolCalls[1]["function"].arguments, '{"a":1}')
	check("the stop reason was mapped", streamed.finish, "tool_calls")
	check("and usage normalised", streamed.usage.completion_tokens, 7)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 23. Token limits ---------------------------------------------------------

scenario("what a model accepts is known before a refusal teaches it", function()
	local _, handle = bootWith({ provider = false })
	local traits = handle.env.require("provider/traits")

	check("Opus 5 holds a million tokens", traits.contextWindow("claude-opus-5"), 1000000)
	check("badged for a picker", traits.badge("claude-opus-5"), "1M")
	check("through a gateway's prefix too", traits.badge("anthropic/claude-opus-5"), "1M")
	check("and a dated snapshot", traits.contextWindow("claude-opus-5-20260101"), 1000000)
	check("Haiku 4.5 is smaller", traits.badge("claude-haiku-4-5"), "200K")
	check("an unfamiliar model claims nothing", traits.contextWindow("harness-model"), nil)

	-- Silence has to mean "send it": withholding a parameter a gateway would have
	-- honoured breaks every model this table has never heard of.
	check("sampling is refused by Opus 5", traits.allowsSampling("claude-opus-5"), false)
	check("allowed on 4.6", traits.allowsSampling("claude-opus-4-6"), true)
	check("and on anything unknown", traits.allowsSampling("harness-model"), true)

	-- The effort scales differ by generation, and a level a model never had is a
	-- refusal rather than a rounding, so a setting is clamped down and never up.
	check("xhigh is honoured where it exists", traits.nearestEffort("claude-opus-5", "xhigh"), "xhigh")
	check("and lands on high where it does not", traits.nearestEffort("claude-opus-4-6", "xhigh"), "high")
	check("max survives on both", traits.nearestEffort("claude-opus-4-6", "max"), "max")
	check("a model with no scale takes no level", traits.nearestEffort("harness-model", "high"), nil)

	-- An Opus has cost a third of the 4.5 rate since 4.6, and reporting the old
	-- number made every turn in this client look three times dearer than it was.
	local usage = handle.env.require("agent/usage")
	local opus5 = usage.priceFor("claude-opus-5")
	check("Opus 5 input is five dollars", opus5 and opus5[1], 5.00)
	check("and output twenty-five", opus5 and opus5[2], 25.00)
	check("Sonnet 5 is cheaper still", (usage.priceFor("claude-sonnet-5") or {})[1], 2.00)
	check("an older Opus keeps its own price", (usage.priceFor("claude-opus-4-1") or {})[1], 15.00)
end)

scenario("a Claude request omits what Claude rejects and asks for a depth", function()
	local sent = {}
	local harness, handle = bootWith({
		model = "claude-opus-5",
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			sent[#sent + 1] = json.decode(entry.body)
			return { StatusCode = 200, Body = chatBody({ content = "ok" }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.config.set("agent.maxTokens", 999999)

	handle.sessions.current().send("hello")
	harness.settle(10)

	truthy("a request went out", sent[1] ~= nil)
	check("temperature is withheld from a model that refuses it",
		sent[1] and sent[1].temperature, nil)
	check("the reply ceiling is clamped to what the model allows",
		sent[1] and sent[1].max_tokens, 128000)
	check("and a reasoning depth is asked for", sent[1] and sent[1].reasoning_effort, "high")

	handle.config.set("agent.effort", "off")
	handle.sessions.current().send("again")
	harness.settle(10)
	check("which can be switched off entirely", sent[2] and sent[2].reasoning_effort, nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("an over-large reply ceiling is lowered to what the model allows", function()
	local _, handle = bootWith({ provider = false })
	local openai = handle.env.require("provider/openai")

	-- The refusal is the only place a model's output limit is published -- /models
	-- reports ids, not capabilities -- and every vendor words it differently. The last
	-- rows are the traps: the status code rides along in the text this is handed, and
	-- a dated model id is full of digits.
	local cases = {
		{ "anthropic names the maximum",
			"the provider rejected the request (400): max_tokens: 200000 > 64000, which is the maximum allowed number of output tokens for claude-sonnet-4-5-20250929",
			200000, 64000 },
		{ "openai names what the model supports",
			"max_tokens is too large: 200000. This model supports at most 16384 completion tokens",
			200000, 16384 },
		{ "a gateway states an inequality",
			"max_tokens must be less than or equal to 8192", 128000, 8192 },
		{ "a complaint naming no number halves instead of guessing",
			"the provider rejected the request (400): max_tokens too large", 64000, 32000 },
		{ "and a ceiling already at the floor gives up rather than crawl",
			"max_tokens too large", 1000, nil },
	}
	for _, case in ipairs(cases) do
		check(case[1], openai.ceilingFromMessage(case[2], case[3]), case[4])
	end

	-- End to end on chat completions: the 400 is repaired once, and the number is kept
	-- on the record so no later turn pays for the lesson again.
	local sent = {}
	local live, liveHandle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			local body = json.decode(entry.body)
			sent[#sent + 1] = body.max_tokens
			if (body.max_tokens or 0) > 8192 then
				return { StatusCode = 400, Body = json.encode({
					error = { message = "max_tokens must be less than or equal to 8192" },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Fits now." }) }
		end,
	})
	liveHandle.config.set("agent.maxTokens", 64000)
	local session = liveHandle.sessions.current()
	session.send("hello")
	live.settle(20)

	check("the ceiling the user chose was tried first", sent[1], 64000)
	check("then lowered to the one the provider named", sent[2], 8192)
	check("and the answer landed", session.ctx.messages[#session.ctx.messages].content, "Fits now.")
	local remembered = liveHandle.providers.active().maxTokensCap
	check("the limit was remembered", remembered and remembered.tokens, 8192)
	check("against the model it belongs to", remembered and remembered.model, "harness-model")

	session.send("again")
	live.settle(20)
	check("so the next turn opens with it", sent[3], 8192)

	-- The limit is the model's, not the endpoint's. A record pointed at a wider model
	-- has to ask for the full ceiling again rather than stay clamped to what the last
	-- one allowed, which nothing on screen would explain.
	liveHandle.providers.setModel(liveHandle.providers.active().id, "harness-model-wide")
	live.settle(1)
	session.send("once more")
	live.settle(20)
	check("switching model asks for the full ceiling again", sent[4], 64000)
	check("and learns this one's limit too", sent[5], 8192)
	check("no thread errors", #live.errors(), 0,
		live.errors()[1] and live.errors()[1].traceback or nil)

	-- And on the Messages API, where max_tokens is mandatory and there is no second
	-- shape to fall back to: without this the whole provider is unusable at that
	-- setting rather than merely capped.
	local nativeSent = {}
	local native = envMock.new({})
	native.http.handler = function(entry)
		if not tostring(entry.url):find("/messages") then return { StatusCode = 404, Body = "{}" } end
		local body = json.decode(entry.body)
		nativeSent[#nativeSent + 1] = body.max_tokens
		if (body.max_tokens or 0) > 64000 then
			return { StatusCode = 400, Body = json.encode({
				type = "error",
				error = {
					type = "invalid_request_error",
					message = "max_tokens: 96000 > 64000, which is the maximum allowed number of output tokens for claude-opus-5",
				},
			}) }
		end
		return { StatusCode = 200, Body = messagesBody({ text = "Within the limit." }) }
	end
	local nativeHandle = select(1, native.boot())
	native.settle(1)

	local record = nativeHandle.providers.blank("anthropic-messages")
	record.label = "Claude"
	record.apiKey = "sk-ant-harness"
	record.model = "claude-opus-5"
	record.models = { "claude-opus-5" }
	record.stream = false
	local saved, problems = nativeHandle.providers.save(record)
	truthy("the native preset saves", saved, table.concat(problems or {}, ", "))
	nativeHandle.config.set("agent.maxTokens", 96000)
	native.settle(1)

	local nativeSession = nativeHandle.sessions.current()
	nativeSession.send("hello")
	native.settle(20)

	check("the messages api tried the chosen ceiling", nativeSent[1], 96000)
	check("and retried at the model's own", nativeSent[2], 64000)
	check("with an answer rather than a dead provider",
		nativeSession.ctx.messages[#nativeSession.ctx.messages].content, "Within the limit.")
	check("which is remembered too", (nativeHandle.providers.active().maxTokensCap or {}).tokens, 64000)
	check("no thread errors on the native path", #native.errors(), 0,
		native.errors()[1] and native.errors()[1].traceback or nil)
end)

scenario("the token sliders span three orders of magnitude", function()
	local harness, handle = bootWith({ provider = false })
	harness.click(harness.byName("Segment_settings"))
	harness.settle(1)

	-- Dragging well past either end, which clamps: the assertion is about what the
	-- ends of the track carry, not about pixels, and the panel is the only place the
	-- stop lists are wired to a setting.
	local function dragTo(path, x)
		local slider = harness.byName("Slider_" .. path)
		local hit = slider and slider:FindFirstChildOfClass("TextButton")
		if not hit then return false end
		harness.drag(hit, 0, 0, x, 0)
		return true
	end

	truthy("the context budget has a slider", dragTo("agent.contextTokens", 100000))
	check("whose far end is a million tokens", handle.config.get("agent.contextTokens"), 1000000)
	contains("labelled as such", harness.textOf(), "1M")

	truthy("and it still goes back", dragTo("agent.contextTokens", -100000))
	check("to four thousand", handle.config.get("agent.contextTokens"), 4000)

	truthy("the reply ceiling has one", dragTo("agent.maxTokens", 100000))
	check("reaching 128k, which the widest models will spend", handle.config.get("agent.maxTokens"), 128000)

	truthy("and the tool result cap is adjustable at all", dragTo("agent.resultCap", 100000))
	check("up to 128k characters", handle.config.get("agent.resultCap"), 128000)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("no property type errors", #harness.instanceState.typeErrors, 0,
		table.concat(harness.instanceState.typeErrors, "\n"))
end)

scenario("effort reads as a scale rather than a number", function()
	local harness, handle = bootWith({ provider = false })
	harness.click(harness.byName("Segment_settings"))
	harness.settle(1)

	local slider = harness.byName("Slider_agent.effort")
	truthy("the effort setting has a track of its own", slider ~= nil)
	local hit = slider and slider:FindFirstChildOfClass("TextButton")
	truthy("with something to drag", hit ~= nil)

	-- Words, not numbers. What the scale costs and buys is the part a reader needs,
	-- and "xhigh" is not a quantity anyone can place on a bare track.
	contains("the near end says what it buys", harness.textOf(), "Faster")
	contains("and the far end too", harness.textOf(), "Smarter")

	if hit then
		harness.drag(hit, 0, 0, 100000, 0)
		check("the far end spends the most", handle.config.get("agent.effort"), "max")
		contains("and names itself", harness.textOf(), "Max")
		harness.drag(hit, 0, 0, -100000, 0)
		check("the near end the least", handle.config.get("agent.effort"), "low")
	end

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("no property type errors", #harness.instanceState.typeErrors, 0,
		table.concat(harness.instanceState.typeErrors, "\n"))
end)

scenario("reasoning arrives open, sized, and answers its switch", function()
	local harness, handle = bootWith({
		handler = function()
			return { StatusCode = 200, Body = chatBody({
				content = "Forty-two.",
				reasoning = string.rep("weighing the options ", 40),
			}) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.sessions.current().send("what is the answer")
	harness.settle(10)

	contains("the thinking is on screen", harness.textOf(), "weighing the options")
	contains("under a header naming it", harness.textOf(), "reasoning")
	-- Reasoning is billed as output and never appears in the reply, so its size is a
	-- number the reader cannot get from anywhere else on the row.
	contains("with its size in tokens", harness.textOf(), "tokens")
	contains("and the answer as well", harness.textOf(), "Forty-two.")

	local card = harness.byName("Reasoning")
	truthy("the row exists", card ~= nil)
	truthy("and is open on arrival, not folded away", card and card.Visible ~= false)

	-- The switch used to be read only while a row was being built, so turning it off
	-- left the conversation exactly as it was and read as a dead toggle.
	handle.config.set("ui.showReasoning", false)
	harness.settle(3)
	local after = harness.byName("Reasoning")
	truthy("switching it off takes the row off screen", after == nil or after.Visible == false)
	contains("and leaves the answer alone", harness.textOf(), "Forty-two.")

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 24. Quick chat ----------------------------------------------------------

scenario("quick chat opens on a keypress and sends to the same conversation", function()
	local harness, handle = bootWith({
		handler = function() return { StatusCode = 200, Body = chatBody({ content = "Quick answer." }) } end,
	})
	local quick = handle.env.require("ui/quickchat")

	check("the default key is bound", quick.keyName(), "Semicolon")
	truthy("and it starts hidden", not quick.visible)

	harness.press("Semicolon")
	truthy("the bound key opens it", quick.visible)
	truthy("its surface exists", harness.byName("QuickChat") ~= nil, harness.dump())

	harness.press("Escape")
	truthy("escape closes it", not quick.visible)
	check("without sending anything", #chatRequests(harness), 0)

	-- A keystroke the interface already consumed must not open it, or typing the
	-- bound character into the composer would open it on every keypress.
	harness.press("Semicolon", true)
	truthy("a processed keystroke is ignored", not quick.visible)

	harness.press("Semicolon")
	truthy("it opens again", quick.visible)
	quick.submit("hello from quick chat")
	truthy("sending closes it", not quick.visible)
	harness.settle(8)

	check("one request was sent", #chatRequests(harness), 1)
	contains("the transcript has it, so it is the same session",
		harness.textOf(), "hello from quick chat")
	contains("and the reply", harness.textOf(), "Quick answer.")

	-- Rebinding captures the next key rather than parsing a typed character.
	quick.captureNext(function() end)
	harness.press("Q")
	check("the captured key was stored", quick.keyName(), "Q")
	check("and persisted", handle.config.get("ui.quickKey"), "Q")
	harness.press("Semicolon")
	truthy("the old key no longer opens it", not quick.visible)
	harness.press("Q")
	truthy("the new one does", quick.visible)
	quick.hide()

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 25. Unload --------------------------------------------------------------

scenario("unloading stops everything it started", function()
	local harness, handle = bootWith({
		handler = function() return { StatusCode = 200, Body = chatBody({ content = "Hi." }) } end,
	})
	local dispose = handle.env.require("runtime/dispose")

	truthy("the interface is up", harness.screen() ~= nil)
	truthy("and cleanups are registered", dispose.count() > 0, tostring(dispose.count()))

	-- A turn leaves a working row behind with a timer driving it, so the drain has
	-- real work rather than an empty registry.
	handle.sessions.current().send("hello")
	harness.settle(1)

	local ran = handle.destroy()
	truthy("the drain ran cleanups", (ran or 0) > 0, tostring(ran))
	check("the registry is empty afterwards", dispose.count(), 0)
	check("the handle is no longer alive", handle.alive, false)
	truthy("the interface is gone", harness.screen() == nil, harness.dump(harness.coreGui))

	-- The whole point: nothing keeps running. Advancing the clock a long way must not
	-- raise from a timer writing to a label that no longer exists.
	harness.settle(25)
	check("no thread errors after unloading", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)

	-- And a config write must not rebuild an interface that has gone.
	handle.config.set("ui.accent", "amber")
	handle.config.set("ui.density", "compact")
	harness.settle(3)
	truthy("a config change does not resurrect it", harness.screen() == nil)
	check("still no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)

	check("a second unload is a no-op", handle.destroy(), 0)
end)

-- 44. The web bridge -------------------------------------------------------
--
-- A Roblox client cannot be connected to, so the browser half of this feature is a
-- local process that the client polls. Three things have to hold: a command coming
-- back off that poll reaches the session, the reply is pushed back out, and none of
-- the polling lands in the request history the Logs panel reads.

scenario("the web bridge relays a browser message into the session", function()
	local uploads, inboxCalls = {}, 0
	local harness, handle = bootWith({
		handler = function(entry)
			local url = tostring(entry.url)
			if url:find("/api/agent/inbox") then
				inboxCalls = inboxCalls + 1
				if inboxCalls == 1 then
					return { StatusCode = 200, Body = json.encode({
						commands = { { type = "send", text = "what game is this" } },
					}) }
				end
				return { StatusCode = 200, Body = json.encode({ commands = {} }) }
			end
			if url:find("/api/agent/events") then
				uploads[#uploads + 1] = json.decode(entry.body or "{}")
				return { StatusCode = 204, Body = "" }
			end
			if url:find("/chat/completions") then
				return { StatusCode = 200, Body = chatBody({
					content = "This place is Mock Place 123456789.",
				}) }
			end
			return { StatusCode = 404, Body = "{}" }
		end,
	})

	handle.config.set("bridge.token", ("a"):rep(64))
	handle.config.set("bridge.enabled", true)
	harness.settle(10)

	local bridge = handle.env.require("net/bridge")
	truthy("the bridge is running", bridge.running)
	truthy("and finds the local process reachable", bridge.online)

	local session = handle.sessions.current()
	local kinds = {}
	for _, event in ipairs(session.log) do kinds[event.kind] = (kinds[event.kind] or 0) + 1 end
	check("the browser's message became a user turn", kinds["user"], 1)
	truthy("and the agent answered it", (kinds["assistant:text"] or 0) >= 1)

	-- The answer has to travel back out, or the browser shows a question and then
	-- nothing at all.
	local relayed = {}
	for _, upload in ipairs(uploads) do
		for _, event in ipairs(upload.events or {}) do relayed[#relayed + 1] = event end
		for _, event in ipairs(upload.snapshot or {}) do relayed[#relayed + 1] = event end
	end
	local sawUser, sawReply = false, false
	for _, event in ipairs(relayed) do
		if event.kind == "user" and tostring(event.text):find("what game") then sawUser = true end
		if event.kind == "assistant:text" and tostring(event.text):find("Mock Place") then
			sawReply = true
		end
	end
	truthy("the user turn was pushed to the bridge", sawUser)
	truthy("so was the answer", sawReply)

	local http = handle.env.require("net/http")
	local leaked = 0
	for _, item in ipairs(http.history) do
		if tostring(item.url):find("/api/agent/") then leaked = leaked + 1 end
	end
	check("bridge traffic stays out of the request history", leaked, 0)
	truthy("while the inference call is still in it", #http.history > 0)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("unloading stops the bridge", function()
	local inboxCalls = 0
	local harness, handle = bootWith({
		handler = function(entry)
			local url = tostring(entry.url)
			if url:find("/api/agent/inbox") then
				inboxCalls = inboxCalls + 1
				return { StatusCode = 200, Body = json.encode({ commands = {} }) }
			end
			if url:find("/api/agent/events") then return { StatusCode = 204, Body = "" } end
			return { StatusCode = 404, Body = "{}" }
		end,
	})

	handle.config.set("bridge.token", ("b"):rep(64))
	handle.config.set("bridge.enabled", true)
	harness.settle(6)

	local bridge = handle.env.require("net/bridge")
	truthy("the bridge started", bridge.running)
	truthy("and polled at least once", inboxCalls > 0, tostring(inboxCalls))

	handle.destroy()
	local before = inboxCalls
	harness.settle(30)

	check("it stopped with everything else", bridge.running, false)
	check("and its poller made no further requests", inboxCalls, before)

	-- Re-enabling the setting afterwards must not bring the threads back: the
	-- subscription watching that setting is drained along with them.
	handle.config.set("bridge.enabled", false)
	handle.config.set("bridge.enabled", true)
	harness.settle(6)
	check("a config write does not restart it", bridge.running, false)
	check("still nothing polling", inboxCalls, before)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

print(("="):rep(72))
print(string.format("%d scenarios, %d checks passed, %d failed",
	suite.scenarios, suite.passed, suite.failed))
if suite.failed > 0 then
	print("")
	for _, failure in ipairs(suite.failures) do print("  - " .. failure) end
end
os.exit(suite.failed > 0 and 1 or 0)
