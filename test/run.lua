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
	contains("the sidebar offers a new conversation", text, "+ New")
	contains("and names the place the client is in", text, "Mock Place")
	contains("the empty state explains what to do", text, "No provider configured")

	-- Navigation is the sidebar's, and in a client whose panels are its surfaces the
	-- panel list has to be reachable rather than hidden behind an invisible control.
	truthy("the app menu is reachable", harness.byName("Nav_menu") ~= nil)
	harness.click(harness.byName("More"))
	truthy("the panel list opens", harness.byName("NavRow_providers") ~= nil,
		harness.dump(harness.byName("Sidebar")))
	harness.click(harness.byName("NavRow_providers"))
	check("and switches panel", handle.app.panel, "providers")
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

-- The step limit is there to stop a runaway, but on a long job it stops the work
-- instead: the turn ends part-way through with "I reached this session's step limit"
-- and the user has to ask it to continue. `agent.unlimitedTurns` removes it, and the
-- turn deadline with it -- a fifteen-minute ceiling left standing behind a switch
-- labelled unlimited stops the same job at roughly twice the step count and reports
-- it as running out of time.
scenario("unlimited tool calls runs past the step limit", function()
	-- Alternating tool names, because the repeat breaker is the bound that stays in
	-- force and three identical batches would trip it before the ninth step.
	local function scripted()
		local step = 0
		return function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step <= 9 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("c" .. tostring(step),
						(step % 2 == 0) and "todo_read" or "game_info", {}) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Finished after nine steps." }) }
		end
	end

	local limited, limitedHandle = bootWith({ handler = scripted() })
	limitedHandle.config.set("agent.maxTurns", 4)
	local capped = limitedHandle.sessions.current()
	capped.send("do a long job")
	limited.settle(40)

	local stopped
	for _, event in ipairs(capped.log) do
		if event.kind == "error" then stopped = event.message end
	end
	contains("the step limit stops the turn by default", stopped or "", "Reached the step limit of 4")
	check("after exactly that many requests", #chatRequests(limited), 4)

	local free, freeHandle = bootWith({ handler = scripted() })
	freeHandle.config.set("agent.maxTurns", 4)
	freeHandle.config.set("agent.unlimitedTurns", true)
	local session = freeHandle.sessions.current()
	session.send("do the same long job")
	free.settle(60)

	check("with the switch on it works through to the answer",
		session.ctx.messages[#session.ctx.messages].content, "Finished after nine steps.")
	check("which took more steps than the limit allowed", #chatRequests(free), 10)

	local reported, announced
	for _, event in ipairs(session.log) do
		if event.kind == "error" then reported = event.message end
		if event.kind == "turn:start" then announced = event.unlimited end
	end
	check("nothing was reported as a limit", reported, nil)
	check("and the turn said so when it started", announced, true)
	check("the session is idle again", session.busy, false)
	check("no thread errors", #free.errors(), 0,
		free.errors()[1] and free.errors()[1].traceback or nil)
end)

-- A subagent runs this same loop, so the switch has to stop at the conversation the
-- user is watching. A child is dispatched with a step budget of its own; if the
-- toggle overrode that too, the one session nobody is looking at would be the one
-- with no bound on it.
scenario("unlimited tool calls does not reach a subagent", function()
	local parentStep, childStep = 0, 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			-- The child's requests are the ones carrying the subagent brief.
			if tostring(entry.body):find("You are a subagent", 1, true) then
				childStep = childStep + 1
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("k" .. tostring(childStep),
						(childStep % 2 == 0) and "players_list" or "game_info", {}) },
				}) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent", { task = "dig forever", preset = "read" }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "The subagent ran out of steps." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.config.set("agent.unlimitedTurns", true)
	handle.config.set("agent.subagentTurns", 3)

	local session = handle.sessions.current()
	session.send("delegate something endless")
	harness.settle(60)

	check("the child stopped at its own step budget", childStep, 3)

	local report
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then report = message end
	end
	contains("and said so in its report", report and report.content or "", "step limit")
	check("the parent, which is unlimited, carried on and answered",
		session.ctx.messages[#session.ctx.messages].content, "The subagent ran out of steps.")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- The other half of that decision.
--
-- Holding the line at the watched conversation leaves the delegated half of a long job
-- stopping mid-way and saying so -- the whole dispatch spent producing "I reached this
-- session's step limit before finishing", which is the one outcome that answers nothing.
-- `subagentUnlimited` is the switch that says otherwise, and it has to reach the child
-- without the parent's switch being involved at all.
scenario("the subagent switch lifts a child's own limits", function()
	local parentStep, childStep = 0, 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			if tostring(entry.body):find("You are a subagent", 1, true) then
				childStep = childStep + 1
				if childStep <= 8 then
					return { StatusCode = 200, Body = chatBody({
						toolCalls = { toolCall("k" .. tostring(childStep),
							(childStep % 2 == 0) and "players_list" or "game_info", {}) },
					}) }
				end
				return { StatusCode = 200, Body = chatBody({ content = "Nine steps in, here is the answer." }) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent",
						{ task = "dig for as long as it takes", preset = "read" }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "The subagent got there." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.config.set("agent.subagentTurns", 3)
	handle.config.set("agent.subagentUnlimited", true)

	local session = handle.sessions.current()
	session.send("delegate something long")
	harness.settle(90)

	check("the child ran past the step limit it was given", childStep, 9)

	local report
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then report = tostring(message.content) end
	end
	contains("and answered rather than reporting a limit", report or "", "Nine steps in")
	truthy("no step limit was reported at all",
		(report or ""):find("step limit", 1, true) == nil, report)

	local record = handle.env.require("agent/subagent").list()[1]
	truthy("the register kept the dispatch", record ~= nil)
	check("marked as having run unlimited", record and record.unlimited, true)
	check("and it finished rather than being cut off", record and record.status, "done")
	-- The brief has to agree with the budget, or the model rations turns it does not
	-- have to ration and stops reading early to save them.
	local childBody
	for _, entry in ipairs(chatRequests(harness)) do
		if tostring(entry.body):find("You are a subagent", 1, true) then childBody = tostring(entry.body) end
	end
	contains("the child was told it has no step limit", childBody or "", "no step limit and no clock")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- A dispatch used to be one shot: the child answered, its context went on the floor,
-- and a parent that wanted one more fact had to describe the whole job again to a fresh
-- subagent that would go and rediscover it. This is the same subagent, asked a second
-- question in the conversation it already had.
scenario("a subagent takes a follow-up instead of being replaced", function()
	local parentStep, childStep = 0, 0
	local sawFirstTurn = false
	-- Declared before the boot, because the handler reaches back for the register to
	-- read the id the report gave it -- and a `local harness, handle = bootWith(...)`
	-- leaves both nil inside the closure being passed in.
	local harness, handle
	harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = tostring(entry.body)
			if body:find("You are a subagent", 1, true) then
				childStep = childStep + 1
				if childStep == 1 then
					return { StatusCode = 200, Body = chatBody({ content = "There is one player: TestPlayer." }) }
				end
				-- The point of the whole thing: the second turn can see the first. Without
				-- that a follow-up is a fresh dispatch wearing a different name.
				sawFirstTurn = body:find("TestPlayer", 1, true) ~= nil
					and body:find("and their team", 1, true) ~= nil
				return { StatusCode = 200, Body = chatBody({ content = "TestPlayer is on Neutral." }) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent",
						{ task = "count the players", preset = "read" }) },
				}) }
			end
			if parentStep == 2 then
				-- Addressed by the id the report handed back, which is the only handle the
				-- model has on a child.
				local id = handle.env.require("agent/subagent").list()[1].id
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("f1", "agent_followup",
						{ agent = id, message = "and their team" }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "One player, on Neutral." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("how many players are here")
	harness.settle(60)

	local subagents = handle.env.require("agent/subagent")
	local record = subagents.list()[1]
	check("the parent took three steps and no more", parentStep, 3)
	check("one dispatch, not two", #subagents.list(), 1)
	check("which ran twice", record and record.runs, 2)
	check("the child kept one context across both", childStep, 2)
	truthy("and could see its own first turn", sawFirstTurn)

	local reports = {}
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then reports[#reports + 1] = tostring(message.content) end
	end
	check("both turns came back as tool results", #reports, 2)
	contains("the first names the id a follow-up needs", reports[1] or "", record.id)
	contains("and the tool that takes it", reports[1] or "", "agent_followup")
	contains("the second carries the answer to the follow-up", reports[2] or "", "Neutral")

	-- Two cards, one subagent. A follow-up has to read as a second turn on the same
	-- child rather than as a second dispatch doing the job again.
	local starts = {}
	for _, event in ipairs(session.log) do
		if event.kind == "subagent:start" then starts[#starts + 1] = event end
	end
	check("two starts were announced", #starts, 2)
	check("both for the same subagent", starts[2] and starts[2].id, starts[1] and starts[1].id)
	check("the first is not a follow-up", starts[1] and starts[1].followUp, false)
	check("the second is", starts[2] and starts[2].followUp, true)
	check("and is addressed to the call that asked for it", starts[2] and starts[2].call, "f1")
	contains("the card says which it is", harness.textOf(), "follow-up")
	check("the parent answered with both halves",
		session.ctx.messages[#session.ctx.messages].content, "One player, on Neutral.")

	-- A follow-up to something that was never dispatched has to fail with the ids that
	-- do exist, or the model spends a step guessing.
	local failed, why = subagents.followUp({ id = "agent_nope", task = "hello" })
	check("an unknown id is refused", failed, nil)
	contains("and the open ones are named", why or "", record.id)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
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

	-- The size ramp is floored at one, not at eight. It used to be eight, which was
	-- harmless while every token was larger than that and silently wrong the moment
	-- the small ones arrived: a 3px slider track, a 4px scrollbar and a 6px status dot
	-- all came out of the ramp as 8.
	handle.config.set("ui.fontScale", 1)
	harness.settle(1)
	truthy("a small token survives the ramp", theme.size.dotSmall < theme.size.dot,
		tostring(theme.size.dotSmall) .. " vs " .. tostring(theme.size.dot))
	truthy("and is not clamped up to eight", theme.size.track < 8, tostring(theme.size.track))
	truthy("the scrollbar is the width it says it is", theme.size.scrollbar < 8,
		tostring(theme.size.scrollbar))

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

-- A design system whose text cannot be read on its own surface is a design system
-- with a bug in it, and it is the one class of visual mistake that no amount of
-- looking at the code will catch: every token here is a plausible dark grey. So the
-- contrast is computed, in the same terms the accessibility guidelines use, over the
-- pairs the interface actually puts together.
scenario("the palette keeps text legible on the surface it sits on", function()
	local harness, handle = bootWith({ provider = false })
	local theme = handle.env.require("ui/theme")

	-- WCAG relative luminance. The mock's Color3 keeps its channels as 0-1 floats,
	-- same as the real one.
	local function channel(value)
		if value <= 0.03928 then return value / 12.92 end
		return ((value + 0.055) / 1.055) ^ 2.4
	end
	local function luminance(colour)
		return 0.2126 * channel(colour.R) + 0.7152 * channel(colour.G) + 0.0722 * channel(colour.B)
	end
	local function ratio(a, b)
		local first, second = luminance(a), luminance(b)
		if first < second then first, second = second, first end
		return (first + 0.05) / (second + 0.05)
	end

	local colour = theme.color
	-- 4.5 is the guideline for body text, 3.0 for large text and for a control's own
	-- outline. Captions are held to 4.5 too: "it is only a caption" is how a caption
	-- ends up unreadable.
	local pairsToCheck = {
		{ "body text on the canvas", colour.text, colour.canvas, 4.5 },
		{ "body text on a card", colour.text, colour.surfaceRaised, 4.5 },
		{ "secondary text on the canvas", colour.textSecondary, colour.canvas, 4.5 },
		{ "tertiary text on the canvas", colour.textTertiary, colour.canvas, 4.5 },
		{ "tertiary text on a card", colour.textTertiary, colour.surfaceRaised, 4.5 },
		-- The overlay tone is the lightest surface in the set, so it is where a muted
		-- caption comes closest to disappearing: a menu's detail line and a toast both
		-- sit on it. This pair is what set the tertiary tone, not the other way round.
		{ "tertiary text on an overlay", colour.textTertiary, colour.surfaceOverlay, 4.5 },
		{ "text on the user's own turn", colour.text, colour.bubbleUser, 4.5 },
		{ "code on the code surface", colour.codeText, colour.codeSurface, 4.5 },
		{ "a code block's language on its bar", colour.codeGutter, colour.codeBar, 3 },
		{ "an added line on its own fill", colour.codeAddText, colour.codeAddSurface, 4.5 },
		{ "a removed line on its own fill", colour.codeRemoveText, colour.codeRemoveSurface, 4.5 },
		{ "inline code on the canvas", colour.accentHot, colour.canvas, 4.5 },
		{ "the accent on the canvas", colour.accent, colour.canvas, 3 },
		{ "dark text on the solid action", colour.onSolid, colour.solid, 4.5 },
		{ "dark text on the accent", colour.textOnAccent, colour.accent, 4.5 },
		{ "danger text on its own surface", colour.danger, colour.dangerSurface, 3 },
		{ "warn text on its own surface", colour.warn, colour.warnSurface, 3 },
		{ "success text on its own surface", colour.success, colour.successSurface, 3 },
		{ "info text on its own surface", colour.info, colour.infoSurface, 3 },
		{ "a toast's text on a toast", colour.text, colour.surfaceOverlay, 4.5 },
	}
	for _, entry in ipairs(pairsToCheck) do
		local label, fg, bg, want = entry[1], entry[2], entry[3], entry[4]
		local got = ratio(fg, bg)
		truthy(label .. " clears " .. tostring(want) .. ":1", got >= want,
			string.format("%.2f:1", got))
	end

	-- Hairlines are not text and do not need 3:1, but they do have to be visible at
	-- all: borderSubtle used to sit one step above the surface it was drawn on, which
	-- is 1.05:1 and reads as no border.
	for _, entry in ipairs({
		{ "the hairline on the canvas", colour.borderSubtle, colour.canvas },
		{ "the hairline on a card", colour.borderSubtle, colour.surfaceRaised },
		{ "the window outline on the canvas", colour.border, colour.canvas },
	}) do
		local got = ratio(entry[2], entry[3])
		truthy(entry[1] .. " is actually visible", got >= 1.25, string.format("%.2f:1", got))
	end

	-- And the surfaces have to be distinguishable from each other, or the hierarchy
	-- the whole palette is built on is decoration.
	local steps = {
		{ "canvas", colour.canvas }, { "surface", colour.surface },
		{ "raised", colour.surfaceRaised }, { "overlay", colour.surfaceOverlay },
	}
	for index = 2, #steps do
		local previous, current = steps[index - 1], steps[index]
		truthy(current[1] .. " is a step above " .. previous[1],
			luminance(current[2]) > luminance(previous[2]))
	end
	check("the code surface is below the canvas",
		luminance(colour.codeSurface) < luminance(colour.canvas), true)

	-- Every accent has to clear the same bar, or switching one turns the interface
	-- into a different quality of interface.
	for name in pairs(theme.ACCENTS) do
		handle.config.set("ui.accent", name)
		harness.settle(1)
		truthy(name .. " reads as inline code on the canvas",
			ratio(theme.color.accentHot, theme.color.canvas) >= 4.5,
			string.format("%.2f:1", ratio(theme.color.accentHot, theme.color.canvas)))
		truthy(name .. " takes dark text when it is a fill",
			ratio(theme.color.textOnAccent, theme.color.accent) >= 4.5,
			string.format("%.2f:1", ratio(theme.color.textOnAccent, theme.color.accent)))
	end

	-- And so does every code palette. The light one inverts the whole set, so a pair
	-- that was only ever checked against the dark tones is exactly where a code block
	-- would come out as pale grey on cream.
	for _, name in ipairs(theme.CODE_THEME_ORDER) do
		handle.config.set("ui.codeTheme", name)
		harness.settle(1)
		local set = theme.color
		for _, entry in ipairs({
			{ "code", set.codeText, set.codeSurface, 4.5 },
			{ "the language label", set.codeGutter, set.codeBar, 3 },
			{ "an added line", set.codeAddText, set.codeAddSurface, 4.5 },
			{ "a removed line", set.codeRemoveText, set.codeRemoveSurface, 4.5 },
		}) do
			local got = ratio(entry[2], entry[3])
			truthy(name .. ": " .. entry[1] .. " clears " .. tostring(entry[4]) .. ":1",
				got >= entry[4], string.format("%.2f:1", got))
		end
	end
	handle.config.set("ui.codeTheme", "dark")
	harness.settle(1)

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

	-- Ordered lists kept losing their numbers: `1.` and `-` both landed in the same
	-- array of bare strings and both painted as a dot, so a list of steps read as a
	-- list of unordered points.
	local ordered = markdown.blocks("1. first\n2. second\n  - nested")
	check("one list", #ordered, 1)
	check("of three items", #ordered[1].items, 3)
	check("the first keeps its number", ordered[1].items[1].marker, "1.")
	check("and its text", ordered[1].items[1].text, "first")
	check("the second too", ordered[1].items[2].marker, "2.")
	check("a bullet has no marker", ordered[1].items[3].marker, nil)
	check("but does have a depth", ordered[1].items[3].depth, 1)

	local quoted = markdown.blocks("> an aside\n> over two lines\n\nback to prose")
	check("a blockquote is its own block", quoted[1].kind, "quote")
	check("joined", quoted[1].text, "an aside\nover two lines")
	check("and prose follows it", quoted[2].kind, "text")
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

-- Parallel dispatch is the reason a subagent is worth having for a wide job: three
-- searches in one step cost one wait instead of three. It comes out of the ordinary
-- parallel-tool path, so what this pins down is that nothing in the dispatch itself
-- serialises the batch -- a shared lock, a shared prompt, a shared counter -- and
-- that two children finishing out of order both still land.
scenario("two subagents dispatched in one step run at the same time", function()
	local parentStep = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = tostring(entry.body)
			-- Checked before the task text, which also appears in the parent's own
			-- messages once the calls are on the transcript.
			if body:find("You are a subagent", 1, true) then
				if body:find("alpha sweep", 1, true) then
					return { StatusCode = 200, delay = 6, Body = chatBody({ content = "Alpha found three doors." }) }
				end
				return { StatusCode = 200, delay = 1, Body = chatBody({ content = "Bravo found one key." }) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = {
						toolCall("d1", "dispatch_agent", { task = "alpha sweep", preset = "read" }),
						toolCall("d2", "dispatch_agent", { task = "bravo sweep", preset = "read" }),
					},
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Three doors and one key." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("sweep the place two ways")
	harness.settle(40)

	local reports = {}
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then reports[#reports + 1] = message end
	end
	check("both dispatches produced a report", #reports, 2)
	contains("the first carries its own child's answer", reports[1].content, "three doors")
	contains("and the second its own", reports[2].content, "one key")
	check("the parent answered with both",
		session.ctx.messages[#session.ctx.messages].content, "Three doors and one key.")

	local starts, dones = {}, {}
	for _, event in ipairs(session.log) do
		if event.kind == "subagent:start" then starts[#starts + 1] = event end
		if event.kind == "subagent:done" then dones[#dones + 1] = event end
	end
	check("two cards were opened", #starts, 2)
	truthy("addressed to different calls", starts[1].call ~= starts[2].call)
	truthy("and keyed to different children", starts[1].id ~= starts[2].id)
	contains("the first card is labelled with its task", starts[1].label, "alpha sweep")
	contains("the second with its own", starts[2].label, "bravo sweep")

	check("two cards were closed", #dones, 2)
	-- The whole point: the one-second child reports before the six-second child, which
	-- is only possible if the second dispatch was not waiting on the first.
	contains("the quicker child finished first", dones[1].label, "bravo sweep")
	truthy("so the slower one was still running when it did",
		(dones[2].at - dones[2].ms) < dones[1].at,
		string.format("alpha ran %d-%d, bravo ended %d",
			dones[2].at - dones[2].ms, dones[2].at, dones[1].at))
	truthy("and the turn took about one wait, not two",
		dones[2].at - (dones[2].at - dones[2].ms) < (dones[1].ms + dones[2].ms))

	local shown = harness.textOf()
	contains("both tasks are on screen", shown, "alpha sweep")
	contains("both of them", shown, "bravo sweep")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- Depth caps how deep the tree goes; nothing capped how wide. `toolConcurrency`
-- bounds one batch, so it bounds a dispatch from the main conversation -- but a
-- subagent's own batch is bounded separately, and two levels of that multiply. A
-- dispatch over the ceiling waits for a slot rather than failing, because the step
-- that asked has already been paid for.
scenario("the subagent ceiling serialises what it cannot fit", function()
	local parentStep = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = tostring(entry.body)
			if body:find("You are a subagent", 1, true) then
				if body:find("alpha sweep", 1, true) then
					return { StatusCode = 200, delay = 6, Body = chatBody({ content = "Alpha done." }) }
				end
				return { StatusCode = 200, delay = 1, Body = chatBody({ content = "Bravo done." }) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = {
						toolCall("d1", "dispatch_agent", { task = "alpha sweep", preset = "read" }),
						toolCall("d2", "dispatch_agent", { task = "bravo sweep", preset = "read" }),
					},
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Both back." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.config.set("agent.subagentConcurrency", 1)

	local subagent = handle.env.require("agent/subagent")
	check("the ceiling follows the setting", subagent.concurrencyLimit(), 1)

	local session = handle.sessions.current()
	session.send("sweep the place two ways")
	harness.settle(60)

	local dones = {}
	for _, event in ipairs(session.log) do
		if event.kind == "subagent:done" then dones[#dones + 1] = event end
	end
	check("both children still ran", #dones, 2)
	contains("the first dispatched went first", dones[1].label, "alpha sweep")
	truthy("and the second waited for it rather than running beside it",
		(dones[2].at - dones[2].ms) >= dones[1].at - 500,
		string.format("alpha ended %d, bravo started %d", dones[1].at, dones[2].at - dones[2].ms))
	check("nothing was abandoned", dones[2].ok, true)
	check("the parent got both reports",
		session.ctx.messages[#session.ctx.messages].content, "Both back.")
	check("and the ceiling was given back afterwards", subagent.live, 0)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- A subagent used to refuse streaming, on the reading that a child with no interface
-- has nothing to stream into. No Roblox transport delivers a body incrementally
-- anyway, so that bought nothing and cost the two things only the streamed shape
-- carries: reasoning text, and the per-request usage block that is the only place
-- some gateways report token counts at all.
scenario("a subagent's own requests stream like the main conversation", function()
	local parentStep = 0
	local harness, handle = bootWith({
		stream = true,
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			if tostring(entry.body):find("You are a subagent", 1, true) then
				return { StatusCode = 200, Body = chatBody({ content = "Nothing unusual here." }) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent", { task = "look around", preset = "read" }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "It looked around." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local session = handle.sessions.current()
	session.send("send someone to look")
	harness.settle(30)

	local parent, child
	for _, entry in ipairs(chatRequests(harness)) do
		if tostring(entry.body):find("You are a subagent", 1, true) then
			child = child or entry
		else
			parent = parent or entry
		end
	end
	truthy("the parent made a request", parent ~= nil)
	truthy("and so did the child", child ~= nil)
	contains("the parent asked for a stream", parent.body, '"stream":true')
	contains("and the child asked for one too", child.body, '"stream":true')
	contains("including the usage block it is asked for", child.body, "include_usage")
	check("the child's report still came back",
		session.ctx.messages[#session.ctx.messages].content, "It looked around.")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- The two switches this section is about are settings, and a setting nobody can reach
-- is not one. Nothing else in this suite mounts the Settings panel, so a mistyped
-- control here would have surfaced first on a real client.
scenario("the new agent switches are reachable from Settings", function()
	local harness, handle = bootWith({ provider = false })
	handle.show("settings")
	harness.settle(3)

	local shown = harness.textOf()
	contains("the step limit still has its row", shown, "Step limit")
	contains("the unlimited switch is there", shown, "Unlimited tool calls")
	contains("saying what still bounds it", shown, "Stop still apply")
	contains("and the subagent ceiling has a row", shown, "Parallel subagents")
	truthy("the ceiling is on a named track",
		harness.byName("Slider_agent.subagentConcurrency") ~= nil)
	-- The two that had no control at all: a config key nothing can write is a setting
	-- only the file has.
	contains("the per-subagent step limit has one now", shown, "Subagent steps")
	truthy("on its own track", harness.byName("Slider_agent.subagentTurns") ~= nil)
	contains("and so does the depth cap", shown, "Delegation depth")
	truthy("which is the switch that can turn delegation off",
		harness.byName("Slider_agent.subagentDepth") ~= nil)
	-- The switch that answers the step-limit message a dispatch comes back with. It only
	-- existed in config.json, which for a setting whose whole point is a stuck job is the
	-- same as not existing.
	contains("lifting a subagent's own limits is a switch too", shown, "Unlimited subagents")
	contains("and it says what still stops one", shown, "Stop still apply")

	local config = handle.config
	check("the switch starts off", config.get("agent.unlimitedTurns"), false)
	config.set("agent.unlimitedTurns", true)
	check("and persists when turned on", config.get("agent.unlimitedTurns"), true)
	check("the subagent switch starts off too", config.get("agent.subagentUnlimited"), false)
	config.set("agent.subagentUnlimited", true)
	check("and the dispatcher reads it",
		handle.env.require("agent/subagent").unlimited(), true)
	check("the ceiling has a default", config.get("agent.subagentConcurrency"), 8)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("nothing was warned", #harness.console.warnings, 0,
		table.concat(harness.console.warnings, "\n"))
end)

-- 18. Persistence ----------------------------------------------------------

scenario("settings and conversations persist", function()
	-- Sent through session.send rather than pushed straight into the context, because
	-- the two halves of a stored conversation come from different places: the context
	-- from ctx.serialise, and the transcript from the event log that only a real turn
	-- produces. Writing to ctx alone is what let the transcript go unpersisted unnoticed.
	local harness, handle = bootWith({
		handler = function()
			return { StatusCode = 200, Body = chatBody({ content = "I will." }) }
		end,
	})
	handle.config.set("ui.accent", "amber")
	handle.config.saveNow()
	handle.sessions.current().send("remember me")
	harness.settle(12)
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

	-- The context is what the model needs to continue; the log is what the transcript
	-- is drawn from, and only the first of the two used to be written. So a restored
	-- conversation was listed in the sidebar, switched to correctly, and then showed the
	-- greeting card -- which is what "previous conversations will not load" looks like.
	local target = nil
	for _, session in ipairs(secondHandle.sessions.list()) do
		for _, message in ipairs(session.ctx.messages) do
			if tostring(message.content):find("remember me") then target = session end
		end
	end
	truthy("the restored conversation has a transcript", target and #target.log > 0,
		target and tostring(#target.log) or "no session")
	local sawUser = false
	for _, event in ipairs(target and target.log or {}) do
		if event.kind == "user" and tostring(event.text):find("remember me") then sawUser = true end
	end
	truthy("with the question in it", sawUser)

	-- And it renders, rather than only existing in the table.
	secondHandle.app.openSession(target.id)
	second.settle(2)
	contains("which the transcript draws", second.textOf(), "remember me")

	-- A status line, a token count and a permission prompt are not transcript: the
	-- first two are meaningless after the fact and the third carries the closure that
	-- answers it, which would fail the whole write.
	for _, event in ipairs(target.log) do
		truthy("no ephemeral event was stored: " .. tostring(event.kind),
			event.kind ~= "status" and event.kind ~= "usage"
				and event.kind ~= "permission:ask" and event.kind ~= "tool:progress")
	end
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
	for _, panel in ipairs({ "providers", "tools", "settings", "logs", "cowork", "agents", "chat" }) do
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
				-- A flex child inside a list layout is the other: the layout hands it
				-- whatever is left on the line, which is exactly what a (0,0) width
				-- plus FlexMode.Fill asks for. Several rows in here fill deliberately
				-- rather than reserving a guessed number of pixels for their
				-- neighbours -- that guess is what used to push the timing column of a
				-- tool row past the card's own clip.
				local flex = node:FindFirstChildOfClass("UIFlexItem")
				local flexMode = flex and nameOf(flex.FlexMode) or nil
				local parentList = node.Parent and node.Parent:FindFirstChildOfClass("UIListLayout")
				if parentList and (flexMode == "Fill" or flexMode == "Grow") then
					ownsWidth = true
				end
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
		for _, panel in ipairs({ "providers", "tools", "settings", "logs", "cowork", "agents", "chat" }) do
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

		-- The settings dialog is a surface of its own -- two panes and thirteen
		-- categories, none of which go through a panel -- and it is where three
		-- zero-width controls were hiding.
		local dialog = handle.app.showSettingsDialog("general")
		for _, entry in ipairs(handle.env.require("ui/settingspanes").PANES) do
			local row = harness.byName("Category_" .. entry.id)
			if row then harness.click(row) end
			harness.settle(1)
			sweep(harness)
		end
		if dialog then dialog.close() end
		harness.settle(1)

		-- The one remaining surface that builds its own chrome: the search results.
		handle.app.showSearch()
		harness.settle(1)
		sweep(harness)
		handle.env.require("ui/overlay").closeAll()
		harness.settle(1)

		handle.app.showSearch()
		harness.settle(1)
		sweep(harness)
		handle.env.require("ui/overlay").closeAll()
		harness.settle(1)

		handle.app.showAbout()
		harness.settle(1)
		sweep(harness)
		handle.env.require("ui/overlay").closeAll()
		harness.settle(1)
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

	-- Nav. The app menu is the path that exists in every layout mode, including the
	-- ones with no sidebar, so it is the one worth testing.
	harness.click(harness.byName("Nav_menu"))
	harness.click(harness.byName("Option_tools"))
	check("a menu option switches panel", handle.app.panel, "tools")
	harness.click(harness.byName("Nav_menu"))
	harness.click(harness.byName("Option_chat"))
	check("and back", handle.app.panel, "chat")

	-- Which is also what the two history arrows walk.
	truthy("going back is offered", handle.app.canBack())
	handle.app.back()
	check("back returns to the previous panel", handle.app.panel, "tools")
	handle.app.forward()
	check("and forward returns", handle.app.panel, "chat")

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

	-- The send button is also the stop button, so it has to disarm when the turn
	-- ends. It did not: the loop emits "Ready" one line after turn:end and from
	-- inside the turn, so session.busy was still true when the status handler read
	-- it, and the composer went straight back to Stop a frame after being cleared --
	-- leaving no way to send a second message.
	local composer = handle.app.chatPanel and handle.app.chatPanel.composer
	truthy("the composer is reachable", composer ~= nil)
	check("the session is idle", handle.sessions.current().busy, false)
	check("and so is the composer", composer and composer.busy, false)
	truthy("so the button offers send rather than stop",
		harness.byName("IconSend", harness.byName("Send")) ~= nil,
		harness.dump(harness.byName("Send")))

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
	harness.click(harness.byName("Nav_menu"))
	harness.click(harness.byName("Option_settings"))
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
	harness.click(harness.byName("Nav_menu"))
	harness.click(harness.byName("Option_settings"))
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
	contains("under a header naming it", harness.textOf(), "Thinking")
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

-- 45. Activity history ------------------------------------------------------

-- Every figure the home card shows has to come from something the client saw. These
-- scenarios are the contract: a number appears only after the event that produces it,
-- it survives a restart, and nothing is counted twice.
scenario("activity is counted from what actually happened", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Counted." }) }
		end,
	})
	local stats = handle.env.require("agent/stats")

	local before = stats.window("all")
	check("nothing is counted before anything happens", before.messages, 0)
	check("and no tokens", before.tokens, 0)
	truthy("so there is no comparison to make", stats.comparison(before.tokens) == nil)

	handle.sessions.current().send("count this")
	harness.settle(8)

	local after = stats.window("all")
	check("the question was counted", after.userMessages, 1)
	check("and the answer", after.replies, 1)
	check("as two messages", after.messages, 2)
	check("the conversation was counted once", after.sessions, 1)
	check("one request", after.requests, 1)
	-- 120 in and 40 out is what the fixture's usage block reports.
	check("the tokens the provider reported went in", after.tokensIn, 120)
	check("and the ones it sent back", after.tokensOut, 40)
	check("totalled", after.tokens, 160)
	check("today is the only active day", after.activeDays, 1)
	check("which is a one day streak", after.currentStreak, 1)

	-- The virtual clock starts at midnight on the first of January 2026, so the day
	-- key is a fixed, readable date rather than whatever the test machine thinks.
	local todayKey = handle.env.require("runtime/clock").dayKey()
	check("bucketed under the local day", todayKey, "2026-01-01")
	truthy("which has a record", stats.data.days[todayKey] ~= nil)

	local model = after.topModel
	truthy("the model that did the work is named", model ~= nil)
	check("and it is the one that answered", model and model.id, "harness-model")
	check("with all of the tokens", model and model.tokens, 160)

	-- A second turn in the same conversation is more messages, not a second
	-- conversation: the id has already been counted.
	handle.sessions.current().send("and this")
	harness.settle(8)
	local second = stats.window("all")
	check("a second turn adds messages", second.messages, 4)
	check("but not a second conversation", second.sessions, 1)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("the activity history survives a restart", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Stored." }) }
		end,
	})
	handle.sessions.current().send("remember this")
	harness.settle(8)
	handle.destroy()
	harness.settle(2)

	truthy("the history was written", harness.files["UAI/stats.json"] ~= nil)
	contains("with the model in it", harness.files["UAI/stats.json"], "harness-model")

	-- A fresh client on the same filesystem, which is what a second run is.
	local revived = envMock.new({})
	for path, body in pairs(harness.files) do revived.files[path] = body end
	for path in pairs(harness.folders) do revived.folders[path] = true end
	revived.http.handler = function() return { StatusCode = 404, Body = "{}" } end
	local second = revived.boot()
	truthy("the client came back", second ~= nil)
	revived.settle(2)

	local stats = second.env.require("agent/stats")
	local window = stats.window("all")
	check("the messages are still counted", window.messages, 2)
	check("so is the conversation", window.sessions, 1)
	check("and the tokens", window.tokens, 160)
	check("no thread errors", #revived.errors(), 0,
		revived.errors()[1] and revived.errors()[1].traceback or nil)
end)

scenario("a history that predates the counters is recovered from the transcripts", function()
	-- The client kept conversations on disk long before it counted anything, so the
	-- first run with a counter file reads the real timestamps out of those
	-- transcripts. Tokens are deliberately not recovered: nothing on disk records
	-- them, and an estimate would be a figure with no measurement behind it.
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Answered." }) }
		end,
	})
	handle.sessions.current().send("an older conversation")
	harness.settle(8)
	handle.destroy()
	harness.settle(2)

	local revived = envMock.new({})
	for path, body in pairs(harness.files) do
		-- Everything except the counters, which is exactly the state an install from
		-- before this feature is in.
		if path ~= "UAI/stats.json" then revived.files[path] = body end
	end
	for path in pairs(harness.folders) do revived.folders[path] = true end
	revived.http.handler = function() return { StatusCode = 404, Body = "{}" } end
	local second = revived.boot()
	revived.settle(2)

	local stats = second.env.require("agent/stats")
	local window = stats.window("all")
	check("the messages came back", window.messages, 2)
	check("and the conversation", window.sessions, 1)
	check("without inventing tokens", window.tokens, 0)
	truthy("and nothing claims to know when they were spent", window.tokensFrom == nil)

	-- Seeding runs once. A third boot must not count the same transcripts again.
	local third = envMock.new({})
	for path, body in pairs(revived.files) do third.files[path] = body end
	for path in pairs(revived.folders) do third.folders[path] = true end
	third.http.handler = function() return { StatusCode = 404, Body = "{}" } end
	local handle3 = third.boot()
	third.settle(2)
	check("a later boot does not count them again",
		handle3.env.require("agent/stats").window("all").messages, 2)
	check("no thread errors", #third.errors(), 0,
		third.errors()[1] and third.errors()[1].traceback or nil)
end)

scenario("the activity windows and the heatmap agree with the record", function()
	local harness, handle = bootWith({ provider = false })
	local stats = handle.env.require("agent/stats")
	local clock = handle.env.require("runtime/clock")

	-- Written straight into the store rather than through a conversation, because
	-- what is under test is the arithmetic over several days and the virtual clock
	-- only ever advances by seconds.
	local today = clock.dayNumber()
	local function put(offset, tokens, messages)
		local key = clock.keyFromDayNumber(today - offset)
		stats.data.days[key] = {
			sessions = 1, messages = messages, userMessages = messages, replies = 0,
			tokensIn = tokens, tokensOut = 0, cost = 0, requests = 1,
			toolCalls = 0, toolErrors = 0, errors = 0,
			hours = { ["11"] = messages }, models = {},
		}
		return key
	end
	put(0, 1000, 2)
	put(1, 500, 1)
	put(2, 250, 1)
	-- A gap at three days, then an older cluster, which is what makes the streaks
	-- and the windows different from each other.
	put(9, 100, 1)
	put(40, 50, 1)

	local all = stats.window("all")
	check("every day counts in all", all.activeDays, 5)
	check("with every token", all.tokens, 1900)
	check("the streak ends at the gap", all.currentStreak, 3)
	check("and the longest run is the same one", all.longestStreak, 3)
	check("the busiest hour is the one with the messages", all.peakHour, 11)
	check("read back as a time", clock.describeHour(all.peakHour), "11 AM")

	local week = stats.window("7d")
	check("a week excludes the older days", week.activeDays, 3)
	check("and their tokens", week.tokens, 1750)

	local month = stats.window("30d")
	check("a month reaches the cluster", month.activeDays, 4)
	check("but not the one before it", month.tokens, 1850)

	local map = stats.heatmap(26)
	check("the heatmap is the weeks it was asked for", #map.columns, 26)
	check("each column is a week", #map.columns[1], 7)
	check("and its peak is the busiest day", map.peak, 1000)

	local todayKey = clock.keyFromDayNumber(today)
	local found = nil
	for _, column in ipairs(map.columns) do
		for _, cell in ipairs(column) do
			if cell.key == todayKey then found = cell end
		end
	end
	truthy("today has a cell", found ~= nil)
	check("at the top level", found and found.level, 4)
	check("holding the day's real total", found and found.tokens, 1000)

	-- One book is the floor, because "0.4 books" is not a sentence.
	truthy("no comparison under a whole book", stats.comparison(90000) == nil)
	contains("and the book is named above it", tostring(stats.comparison(1000000)),
		"Harry Potter")
	contains("with a multiple", tostring(stats.comparison(1000000)), "10")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 46. The reworked interface ------------------------------------------------

-- The sidebar, the composer's chips and the settings dialog were the three surfaces
-- that looked finished and were not: a hardcoded list of project names, a permission
-- chip that announced the opposite of the mode in force, and a dialog whose panes
-- were mostly placeholder text. These scenarios pin the replacements to real state.
scenario("the conversation list is the real one", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Noted." }) }
		end,
	})

	handle.sessions.current().send("the raft spawns in the wrong place")
	harness.settle(8)
	local first = handle.sessions.activeId
	handle.app.openSession(handle.sessions.newThread().id)
	handle.sessions.current().send("the camera clips through the wall")
	harness.settle(8)
	local second = handle.sessions.activeId

	local sidebar = harness.byName("Sidebar")
	truthy("the sidebar exists", sidebar ~= nil)
	local text = harness.textOf(sidebar)
	contains("the first conversation is listed", text, "the raft spawns")
	contains("so is the second", text, "the camera clips")
	contains("grouped under the place they happened in", text, "Mock Place")
	-- The list used to be three invented project names with eleven invented titles
	-- under them, copied out of a screenshot.
	truthy("and nothing invented is listed",
		not text:find("Project%-Gravity") and not text:find("rbxmptest"), text)

	local rows = harness.allByName("SessionRow", sidebar)
	check("one row per conversation", #rows, 2)

	-- The most recent conversation sorts first, so the second row is the older one.
	harness.click(rows[2])
	check("clicking a row switches to it", handle.sessions.activeId, first)
	contains("and the transcript follows", harness.textOf(harness.byName("Transcript")),
		"the raft spawns")

	local session = handle.sessions.threads[first]
	session.rename("Raft spawn point")
	harness.settle(1)
	contains("a rename shows up in the list", harness.textOf(harness.byName("Sidebar")),
		"Raft spawn point")

	handle.sessions.remove(second)
	harness.settle(1)
	truthy("a deleted conversation leaves the list",
		not harness.textOf(harness.byName("Sidebar")):find("the camera clips"))
	truthy("and its file goes with it",
		harness.files["UAI/sessions/" .. tostring(second) .. ".json"] == nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("the composer states what is actually in force", function()
	local harness, handle = bootWith({
		model = "claude-opus-5",
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Fine." }) }
		end,
	})

	local runtime = harness.byName("Chip_runtime")
	truthy("the runtime chip exists", runtime ~= nil)
	contains("and names the host it is on", harness.textOf(runtime), "OfflineHarness")

	-- The permission chip said "Bypass permissions" on a client whose mode was "ask",
	-- which is the one place a fake label was also a safety problem.
	local permissionLabel = harness.byName("PermissionLabel")
	truthy("the permission chip exists", permissionLabel ~= nil)
	check("and reads the mode in force", permissionLabel.Text, "Ask first")
	handle.env.require("agent/permissions").setMode("full")
	harness.settle(1)
	check("changing the mode changes the label", permissionLabel.Text, "Allow everything")

	local modelLabel = harness.byName("ModelLabel")
	contains("the model is the one the provider is pointed at", modelLabel.Text, "claude-opus-5")
	contains("with the window this client knows it has", modelLabel.Text, "1M")

	-- Isolation is the worktree chip: a conversation marked that way is never written.
	local session = handle.sessions.current()
	session.send("write this down")
	harness.settle(8)
	local path = "UAI/sessions/" .. tostring(session.id) .. ".json"
	truthy("an ordinary conversation is on disk", harness.files[path] ~= nil)
	harness.click(harness.byName("Chip_isolate"))
	truthy("isolating it takes it off disk", harness.files[path] == nil)
	session.send("and this")
	harness.settle(8)
	truthy("and it stays off", harness.files[path] == nil)
	harness.click(harness.byName("Chip_isolate"))
	truthy("turning it back on saves it again", harness.files[path] ~= nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("an attached file travels with the message", function()
	local sent = nil
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			sent = entry.body
			return { StatusCode = 200, Body = chatBody({ content = "Read it." }) }
		end,
	})

	local fsx = handle.env.require("runtime/fsx")
	fsx.write("notes/plan.txt", "step one: fix the raft")

	local composer = handle.app.chatPanel.composer
	composer.attachments = { { label = "notes/plan.txt", text = "step one: fix the raft" } }
	local box = harness.byName("Prompt"):FindFirstChildOfClass("TextBox")
	box.Text = "what does the plan say"
	harness.click(harness.byName("Send"))
	harness.settle(8)

	truthy("a request went out", sent ~= nil)
	contains("with the file's contents in it", tostring(sent), "step one: fix the raft")
	contains("named", tostring(sent), "notes/plan.txt")
	contains("alongside the question", tostring(sent), "what does the plan say")
	check("and the attachment is not resent", #composer.attachments, 0)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("every settings pane builds and is reachable", function()
	local harness, handle = bootWith({})
	local panes = handle.env.require("ui/settingspanes")

	local dialog = handle.app.showSettingsDialog("usage")
	harness.settle(1)
	truthy("the dialog opened", dialog ~= nil)
	truthy("with a category list", harness.byName("Category_usage") ~= nil)

	-- Every pane, one at a time. The mock type-checks every property assignment, so
	-- this is where a pane that only looked finished stops looking finished.
	for _, entry in ipairs(panes.PANES) do
		local row = harness.byName("Category_" .. entry.id)
		truthy(entry.id .. " has a category row", row ~= nil)
		if row then
			harness.click(row)
			harness.settle(1)
			truthy(entry.id .. " renders", harness.byName("Pane_" .. entry.id) ~= nil)
		end
	end

	-- The old dialog built its own scrim and registered with nothing, so Escape did
	-- not close it and neither did clicking beside it.
	harness.press("Escape")
	harness.settle(1)
	truthy("Escape closes it", harness.byName("SettingsDialog") == nil)

	local typeErrors = handle.env and harness.instanceState.typeErrors or {}
	check("no property was assigned the wrong type", #typeErrors, 0,
		typeErrors[1] and tostring(typeErrors[1]) or nil)
	local unknownReads = {}
	for key in pairs(harness.instanceState.unknownReads) do unknownReads[#unknownReads + 1] = key end
	table.sort(unknownReads)
	check("no unknown property was read", #unknownReads, 0, table.concat(unknownReads, "\n"))
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
	check("nothing was warned", #harness.console.warnings, 0,
		table.concat(harness.console.warnings, "\n"))
end)

scenario("a tool group can be withheld from the model", function()
	local sent = nil
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			sent = entry.body
			return { StatusCode = 200, Body = chatBody({ content = "Nothing to do." }) }
		end,
	})
	local registry = handle.env.require("agent/registry")

	local before = #registry.definitions({})
	local groups = registry.groups()
	truthy("the registry reports its groups", #groups > 0)

	local target = nil
	for _, group in ipairs(groups) do
		if group.id == "remotes" then target = group end
	end
	truthy("including the remotes family", target ~= nil)

	registry.setGroupEnabled("remotes", false)
	local after = #registry.definitions({})
	truthy("switching it off shortens the tool list", after < before,
		tostring(before) .. " -> " .. tostring(after))
	check("by exactly that family", before - after, target.total)

	handle.sessions.current().send("look around")
	harness.settle(8)
	truthy("and the wire carries the shorter list", sent ~= nil)
	truthy("with none of the withheld tools in it",
		not tostring(sent):find("remote_fire", 1, true), tostring(sent):sub(1, 400))

	registry.setGroupEnabled("remotes", true)
	check("turning it back on restores them", #registry.definitions({}), before)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("search finds a conversation by what was said in it", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Understood." }) }
		end,
	})

	handle.sessions.current().send("the lighting is too dark near the docks")
	harness.settle(8)
	local older = handle.sessions.activeId
	handle.app.openSession(handle.sessions.newThread().id)
	handle.sessions.current().send("something else entirely")
	harness.settle(8)

	handle.app.showSearch()
	harness.settle(1)
	local field = harness.byName("SearchField")
	truthy("the search field is there", field ~= nil)
	local box = field:FindFirstChildOfClass("TextBox")
	box.Text = "docks"
	harness.settle(1)

	local result = harness.byName("Result_1")
	truthy("a result appeared", result ~= nil, harness.dump(harness.byName("SearchResults")))
	contains("naming the conversation it was found in", harness.textOf(result), "lighting is too dark")
	harness.click(result)
	harness.settle(1)
	check("and opening it switches to that conversation", handle.sessions.activeId, older)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("cowork is the web bridge rather than a slogan", function()
	local harness, handle = bootWith({
		handler = function(entry)
			local url = tostring(entry.url)
			if url:find("/api/agent/inbox") then
				return { StatusCode = 200, Body = json.encode({ commands = {} }) }
			end
			if url:find("/api/agent/events") then return { StatusCode = 204, Body = "" } end
			return { StatusCode = 404, Body = "{}" }
		end,
	})

	handle.app.show("cowork")
	harness.settle(1)
	local panel = harness.byName("Cowork")
	truthy("the cowork panel builds", panel ~= nil)
	contains("and says the bridge is off", harness.textOf(panel), "Off.")

	handle.config.set("bridge.token", ("c"):rep(64))
	handle.config.set("bridge.enabled", true)
	harness.settle(6)
	local text = harness.textOf(harness.byName("Cowork"))
	contains("turning it on reports the connection", text, "Connected")
	contains("and which conversation is shared", text, "sharing:")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("the home card reports the record and nothing else", function()
	local harness, handle = bootWith({ provider = false })
	local stats = handle.env.require("agent/stats")
	local clock = handle.env.require("runtime/clock")

	local card = harness.byName("Home")
	truthy("the card is on an empty conversation", card ~= nil)
	local blank = harness.textOf(card)
	contains("greeting the player by name", blank, "TestPlayer")
	-- The card used to open with 11 sessions, 5,387 messages and 1.5B tokens on a
	-- client that had never sent a request.
	truthy("with no invented figures on it",
		not blank:find("5,387") and not blank:find("1.5B"), blank)
	contains("and says why it is empty", blank, "Nothing recorded in this window yet")

	local today = clock.dayNumber()
	stats.data.days[clock.keyFromDayNumber(today)] = {
		sessions = 2, messages = 40, userMessages = 20, replies = 20,
		tokensIn = 900000, tokensOut = 100000, cost = 1.5, requests = 20,
		toolCalls = 6, toolErrors = 0, errors = 0,
		hours = { ["9"] = 40 },
		models = { ["claude-opus-5"] = { requests = 20, tokensIn = 900000, tokensOut = 100000, cost = 1.5 } },
	}
	stats.changed:fire(stats.data)
	harness.settle(2)

	local filled = harness.textOf(harness.byName("Home"))
	contains("the message count is the recorded one", filled, "40")
	contains("the tokens are the recorded ones", filled, "1M")
	contains("the peak hour is the recorded one", filled, "9 AM")
	contains("and the model is the one that answered", filled, "claude-opus-5")
	contains("with the comparison the record supports", filled, "Harry Potter")

	-- The range pills are a real window over the same record.
	harness.click(harness.byName("Pill_7d"))
	harness.settle(1)
	contains("a week still contains today", harness.textOf(harness.byName("Home")), "40")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("the appearance settings change what is drawn", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({
				content = "Try this:\n\n```lua\nlocal x = 1\n```\n",
			}) }
		end,
	})
	local theme = handle.env.require("ui/theme")

	-- Ctrl-comma, which the profile menu advertises. A menu that names a key it has
	-- not bound is decoration.
	harness.hold("LeftControl", true)
	harness.press("Comma")
	harness.settle(1)
	harness.hold("LeftControl", false)
	truthy("the shortcut opens the settings", harness.byName("SettingsDialog") ~= nil)

	harness.click(harness.byName("Category_claude_code"))
	harness.settle(1)

	local darkSurface = theme.color.codeSurface
	truthy("both code palettes are previewed",
		harness.byName("CodePreview_dark") ~= nil and harness.byName("CodePreview_light") ~= nil)
	harness.click(harness.byName("CodePreview_light"))
	harness.settle(2)
	check("pressing one selects it", handle.config.get("ui.codeTheme"), "light")
	truthy("and the code surface actually changes",
		theme.color.codeSurface ~= darkSurface)

	-- And it reaches the transcript, which is the only reason the setting exists.
	handle.sessions.current().send("show me")
	harness.settle(8)
	local block = harness.byName("Code")
	truthy("a code block was rendered", block ~= nil)
	check("in the palette that was chosen", block.BackgroundColor3, theme.color.codeSurface)

	local bodyFont = theme.text.body.font
	handle.config.set("ui.interfaceFont", "gotham")
	harness.settle(2)
	truthy("the interface font is a real change", theme.text.body.font ~= bodyFont)

	local wide = theme.size.reading
	handle.config.set("ui.transcriptWidth", "narrow")
	harness.settle(2)
	truthy("so is the transcript width", theme.size.reading < wide,
		tostring(wide) .. " -> " .. tostring(theme.size.reading))

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("a phone can still reach every panel and conversation", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then
				return { StatusCode = 404, Body = "{}" }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Fine." }) }
		end,
	})
	handle.sessions.current().send("the first one")
	harness.settle(8)
	local first = handle.sessions.activeId
	handle.app.openSession(handle.sessions.newThread().id)
	handle.sessions.current().send("the second one")
	harness.settle(8)

	-- A phone has no sidebar, so the app menu carries the whole of navigation. It used
	-- to carry only the panels, and on a tablet in portrait or a console it carried
	-- nothing at all -- the hamburger was gated on "sheet or narrower than 500".
	harness.setViewport(390, 844)
	harness.settle(2)
	check("the layout is a sheet", handle.env.require("ui/responsive").mode, "sheet")
	check("with no sidebar", handle.app.sidebarVisible(), false)

	harness.click(harness.byName("Nav_menu"))
	harness.settle(1)
	local menu = harness.byName("MenuLayer")
	truthy("the app menu opens", menu ~= nil)
	local text = harness.textOf(menu)
	contains("listing the panels", text, "Providers")
	contains("a new conversation", text, "New conversation")
	contains("and the conversations themselves", text, "the first one")

	harness.click(harness.byName("Option_session:" .. tostring(first)))
	harness.settle(1)
	check("one of which can be opened", handle.sessions.activeId, first)

	-- A tablet in portrait is the other mode with no sidebar.
	harness.setViewport(834, 1112)
	harness.settle(2)
	check("a portrait tablet is a panel", handle.env.require("ui/responsive").mode, "panel")
	truthy("and still has the app menu", harness.byName("Nav_menu") ~= nil)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 34. The sidebar toggle ---------------------------------------------------

-- Untested until now, which is how a toggle that was a mathematical no-op shipped:
-- `collapsed = not sidebarVisible()` is a fixed point in both directions, so pressing
-- it rebuilt the whole tree and produced a byte-identical sidebar.
scenario("the sidebar collapses and comes back", function()
	local harness, handle = bootWith({})
	local app = handle.app

	truthy("the sidebar starts open", app.sidebarVisible())
	truthy("and is on screen", harness.byName("Sidebar") ~= nil)

	harness.click(harness.byName("Nav_sidebar"))
	harness.settle(2)
	check("pressing the toggle collapses it", app.sidebarVisible(), false)
	truthy("and takes it off screen", harness.byName("Sidebar") == nil)
	check("which is remembered", handle.config.get("ui.sidebarCollapsed"), true)

	-- The only control that could bring it back used to live inside the sidebar, so
	-- collapsing it was a one-way trip.
	local expand = harness.byName("Nav_collapse")
	truthy("the header offers a way back", expand ~= nil)
	harness.click(expand)
	harness.settle(2)
	truthy("which restores it", app.sidebarVisible())
	truthy("and the sidebar with it", harness.byName("Sidebar") ~= nil)

	-- The switch in the appearance pane writes the same path without the quiet flag,
	-- and nothing was listening for it.
	handle.config.set("ui.sidebarCollapsed", true)
	harness.settle(2)
	check("the setting collapses it too", app.sidebarVisible(), false)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 35. Outbound encoding ----------------------------------------------------

-- The crash this covers: HttpService:JSONEncode raises "Can't convert to JSON" on a
-- string that is not valid UTF-8, and a web search's scraped snippet is full of
-- candidates. Because the tool result is appended to the message history, the error
-- then repeated on every following turn with no position and no clue.
scenario("invalid UTF-8 never reaches the encoder", function()
	local harness, handle = bootWith({ provider = false })
	local util = handle.env.require("runtime/util")

	local bare = "caf\233 latte"
	check("a lone Latin-1 byte is not valid UTF-8", util.validUtf8(bare), false)
	local fixed, changed = util.sanitise(bare)
	check("sanitising reports the repair", changed, true)
	truthy("and the result validates", util.validUtf8(fixed))
	contains("keeping the text either side", fixed, "latte")

	local clean = "caf\195\169 latte"
	truthy("valid text validates", util.validUtf8(clean))
	local same, untouched = util.sanitise(clean)
	check("and is returned unchanged", same, clean)
	check("with nothing reported", untouched, false)

	-- The three producers that were making such bytes.
	check("an entity above 127 becomes real UTF-8", util.htmlEntities("a&#233;b"), "a\195\169b")
	check("and one above 255 is no longer dropped", util.htmlEntities("it&#8217;s"), "it\226\128\153s")
	truthy("a percent-escaped Latin-1 byte is repaired",
		util.validUtf8(util.urlDecode("caf%E9")))

	-- Byte-indexed cuts through a multi-byte character. The em dash is three bytes.
	local dashes = string.rep("a\226\128\148", 40)
	truthy("ellipsis cuts on a character boundary", util.validUtf8(util.ellipsis(dashes, 30)))
	truthy("so does truncate", util.validUtf8((util.truncate(dashes, 60, "note"))))

	-- The chokepoint itself: every outbound value goes through this.
	local encoded = util.encode({ snippet = bare, count = 0 / 0, note = "ok" })
	truthy("encode does not raise on poisoned input", type(encoded) == "string")
	contains("and still carries the good fields", encoded, "ok")
	truthy("with no NaN token in the body", encoded:lower():find("nan") == nil, encoded)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 36. Code in the transcript ------------------------------------------------

-- What the model wrote is the most useful thing in a transcript of an agent that
-- writes and runs code, and it was reachable only by opening a pane that defaulted
-- shut. What showed instead was ninety characters of the JSON envelope.
scenario("a tool call shows the code it was given", function()
	local step = 0
	local source = "local part = Instance.new(\"Part\")\npart.Anchored = true\nreturn part.Name"
	local harness, handle = bootWith({
		handler = function()
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("call_1", "run_luau", { code = source }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Made a part." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.sessions.current().send("make me a part")
	harness.settle(12)

	local row = harness.byName("Tool")
	truthy("the tool row is there", row ~= nil)
	local shown = harness.textOf(row)
	contains("the code is on screen without opening anything", shown, "part.Anchored = true")
	contains("and the last line too", shown, "return part.Name")
	contains("under its language", shown, "lua")
	contains("with a line count", shown, "3 lines")

	-- The header says what the call is doing rather than showing the envelope.
	truthy("no JSON envelope in the row", shown:find('{"code"', 1, true) == nil, shown)

	-- Turning it off leaves the code behind the row's own caret rather than removing it.
	handle.config.set("ui.showToolCode", false)
	harness.settle(3)
	local without = harness.byName("Tool")
	truthy("the row survives the setting", without ~= nil)
	truthy("and the listing is gone from view",
		harness.textOf(without):find("part.Anchored", 1, true) == nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 37. The providers panel ---------------------------------------------------

-- What this locks in: the key is never rendered, the facts the registry keeps are on
-- screen, and a health event does not tear the panel down. The old panel printed the
-- whole API key into a field, showed none of the endpoint/protocol/latency facts, and
-- rebuilt itself from scratch on every completion.
-- Adding a provider has to be finishable in the editor it is done in.
--
-- `registry.validate` refuses a record with no model, and the picker lived only on the
-- detail pane -- which is reached by selecting a provider that has already been saved.
-- So the add path ended on an instruction, "fetch the model list or add a model id",
-- that nothing on screen could carry out, and Test asked for a completion with no model
-- named and reported back whatever the endpoint says to that.
scenario("a provider can be added without leaving the editor", function()
	local harness, handle = bootWith({
		provider = false,
		handler = function(entry)
			if tostring(entry.url):find("/models") then
				return { StatusCode = 200, Body = json.encode({
					data = { { id = "beta-mini" }, { id = "alpha-large" } },
				}) }
			end
			return { StatusCode = 404, Body = "{}" }
		end,
	})

	local record = handle.providers.blank("openai")
	record.label = "Editor test"
	record.apiKey = "sk-editor-key-1234"
	check("a new record starts with no model at all", record.model, "")

	local savedId
	handle.env.require("ui/panels/providers").editor(record, function(id) savedId = id end)
	harness.settle(2)

	local form = harness.byName("Form")
	local picker = harness.byName("ActiveModel", form)
	truthy("the editor has a model control", picker ~= nil, harness.dump())
	contains("saying one is still needed", harness.textOf(picker), "Choose a model")

	harness.click(picker)
	truthy("which offers a fetch", harness.byName("Option_fetch") ~= nil, harness.dump())
	harness.click(harness.byName("Option_fetch"))
	harness.settle(4)

	local asked
	for _, entry in ipairs(harness.http.log) do
		if tostring(entry.url):find("/models") then asked = entry end
	end
	truthy("the endpoint was asked for its list", asked ~= nil)
	check("with a GET", asked and asked.method, "GET")
	local note = harness.byName("ModelNote", form)
	contains("and the row reports what came back", note and note.Text or "", "2 models")
	-- Picking one is the reason to fetch, so the list comes back by itself rather than
	-- leaving the same control to be pressed twice for one decision.
	truthy("the list is on screen without pressing anything else",
		harness.byName("Option_model:alpha-large") ~= nil, harness.dump())

	harness.click(harness.byName("Option_model:alpha-large"))
	harness.settle(1)
	contains("the control names the chosen model", harness.textOf(picker), "alpha-large")

	harness.click(harness.byName("SaveProvider"))
	harness.settle(2)
	truthy("the provider saved", savedId ~= nil,
		harness.textOf(harness.byName("Problem")))
	local stored = savedId and handle.providers.get(savedId)
	check("with the model that was chosen", stored and stored.model, "alpha-large")
	-- Only the chosen one is written to the record. The rest came off the wire and are
	-- the endpoint's to answer for again next time; a record is not a cache.
	check("and only that one on the record", #(stored and stored.models or {}), 1)
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("the providers panel shows the record without showing the key", function()
	local harness, handle = bootWith({})
	local record = handle.providers.active()
	record.apiKey = "sk-secret-tail-9999"
	record.wsUrl = ""
	handle.providers.save(record, { force = true })
	handle.app.show("providers")
	harness.settle(2)

	local text = harness.textOf()
	truthy("the key is not on screen", text:find("sk-secret-tail", 1, true) == nil, text)
	contains("only its last four characters are", text, "9999")
	contains("the completions endpoint is named", text, "/chat/completions")
	contains("so is the model list route", text, "/models")
	contains("and the wire protocol", text, "Chat completions")
	-- The single fact that decides whether a long reply can arrive, never stated before.
	contains("and whether replies can stream", text, "HTTP only")
	contains("with the fallback rule as configured", text, "active provider first")

	truthy("the provider is listed in the rail",
		harness.byName("Provider_" .. tostring(record.id)) ~= nil)

	-- A health tick used to rebuild the panel, its header and its scroll position.
	local rail = harness.byName("Provider_" .. tostring(record.id))
	handle.providers.markFail(record, "a transient 500")
	harness.settle(1)
	check("a health event leaves the rail row in place",
		harness.byName("Provider_" .. tostring(record.id)), rail)
	contains("while the failure count updates", harness.textOf(), "1 failed")

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 38. Tool pairing ----------------------------------------------------------

-- The 400 this prevents is not survivable on its own: it is not retried, three of them
-- bench the provider, the chain walks the same broken history to the next one, and
-- ctx.serialise keeps both halves -- so one orphan kills every following turn and
-- survives a restart.
scenario("orphaned tool calls and results are repaired before they go out", function()
	local harness, handle = bootWith({ provider = false })
	local ctx = handle.sessions.current().ctx

	-- A result whose call is not in the assistant turn before it. A gateway that drops
	-- an assistant message with empty content manufactures exactly this.
	ctx.pushUser("do the thing")
	ctx.pushAssistant({ content = "", toolCalls = {
		{ id = "call_real", type = "function", ["function"] = { name = "run_luau", arguments = "{}" } },
	} })
	ctx.pushToolResult("call_real", "run_luau", "fine")
	ctx.pushToolResult("call_ghost", "run_luau", "orphan")

	local dropped, filled = ctx.repair()
	check("the orphan was dropped", dropped, 1)
	check("and nothing was invented", filled, 0)
	local ids = {}
	for _, message in ipairs(ctx.messages) do
		if message.role == "tool" then ids[#ids + 1] = message.tool_call_id end
	end
	check("one result survives", #ids, 1)
	check("the matched one", ids[1], "call_real")

	-- The mirror: a call the turn never answered, which is what a crash between
	-- dispatch and result recording leaves behind.
	ctx.pushUser("and again")
	ctx.pushAssistant({ content = "", toolCalls = {
		{ id = "call_hanging", type = "function", ["function"] = { name = "file_write", arguments = "{}" } },
	} })
	local dropped2, filled2 = ctx.repair()
	check("nothing was dropped this time", dropped2, 0)
	check("the hanging call was answered", filled2, 1)
	local last = ctx.messages[#ctx.messages]
	check("with a tool message", last.role, "tool")
	check("naming the call", last.tool_call_id, "call_hanging")
	contains("and saying what happened", last.content, "did not complete")

	-- Idempotent: a repaired history repairs to itself, so the warning does not repeat
	-- on every request for the rest of the conversation.
	local dropped3, filled3 = ctx.repair()
	check("a second pass drops nothing", dropped3, 0)
	check("and fills nothing", filled3, 0)

	-- And it happens on the way out, not only when asked.
	ctx.pushToolResult("call_ghost_again", "run_luau", "orphan")
	local wire = ctx.wire("system")
	local seen = {}
	for _, message in ipairs(wire) do
		for _, call in ipairs(message.toolCalls or {}) do seen[tostring(call.id)] = true end
	end
	local unmatched = 0
	for _, message in ipairs(wire) do
		if message.role == "tool" and not seen[tostring(message.tool_call_id)] then
			unmatched = unmatched + 1
		end
	end
	check("the wire payload has no orphans", unmatched, 0)
end)

-- 41. Two conversations at once --------------------------------------------

-- What this locks in: opening a second conversation does not break the first one.
-- Three things were client-wide that are not: the task list the model keeps, the
-- pending permission prompts, and which conversation the prompt dialog listens to.
-- The consequences were, in order: a running turn resumed against somebody else's
-- plan; a turn finishing anywhere refused whatever another was waiting on; and a
-- prompt raised by a conversation that was not on screen was never shown at all, so
-- after three minutes every call it had planned came back as a refusal.
scenario("two conversations work at the same time", function()
	-- Counted per conversation rather than matched on tool names: every tool the
	-- client has is listed in the definitions on every request, so a body always
	-- contains "todo_write".
	local steps = { alpha = 0, bravo = 0 }
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = tostring(entry.body)
			local who = body:find("the alpha job", 1, true) and "alpha" or "bravo"
			steps[who] = steps[who] + 1
			local step = steps[who]
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall(who .. "1", "todo_write", {
						items = { { text = who .. " step one", status = "active" } },
					}) },
				}) }
			end
			if who == "alpha" and step == 2 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("a2", "instance_create", {
						class = "Folder", name = "AlphaMade", parent = "Workspace",
					}) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({
				content = who == "alpha" and "Alpha is done." or "Bravo is done.",
			}) }
		end,
	})
	handle.config.set("permissions.mode", "ask")

	local state = handle.env.require("agent/state")
	local permissions = handle.env.require("agent/permissions")

	local alpha = handle.sessions.current()
	alpha.rename("Alpha")
	alpha.send("the alpha job")
	harness.settle(8)

	truthy("the first conversation is parked on a prompt", permissions.pendingCount(alpha) == 1)
	truthy("and is still busy while it waits", alpha.busy == true)

	-- The second conversation, opened and run while the first waits.
	local bravo = handle.sessions.newThread()
	bravo.rename("Bravo")
	handle.app.openSession(bravo.id)
	harness.settle(1)
	bravo.send("the bravo job")
	harness.settle(10)

	check("the second conversation answered", bravo.busy, false)
	contains("with its own reply", bravo.ctx.messages[#bravo.ctx.messages].content, "Bravo is done")

	-- One: the plans did not overwrite each other.
	local alphaTodos = state.todoList(alpha)
	local bravoTodos = state.todoList(bravo)
	check("each conversation kept one task", #alphaTodos, 1)
	check("its own", #bravoTodos, 1)
	contains("the first one's plan survived the second", alphaTodos[1].text, "alpha step one")
	contains("and the second has its own", bravoTodos[1].text, "bravo step one")

	-- Two: finishing a turn did not sweep the other conversation's prompt.
	check("the first conversation is still waiting to be asked", permissions.pendingCount(alpha), 1)
	truthy("and still running", alpha.busy == true)

	-- Three: the prompt is on screen even though the other conversation is open.
	local shown = harness.textOf()
	contains("the prompt names the tool", shown, "Allow instance_create?")
	contains("and says which conversation is asking", shown, "in Alpha")

	local allow = harness.byName("PermissionAllow")
	truthy("with an allow control", allow ~= nil)
	harness.click(allow)
	harness.settle(10)

	truthy("answering it lets the first conversation finish",
		harness.workspace:FindFirstChild("AlphaMade") ~= nil, harness.dump(harness.workspace))
	check("and it is no longer busy", alpha.busy, false)
	contains("with its own reply", alpha.ctx.messages[#alpha.ctx.messages].content, "Alpha is done")
	check("nothing is left pending", permissions.pendingCount(), 0)

	-- The strip shows the conversation on screen, not the last plan written anywhere.
	handle.app.openSession(alpha.id)
	harness.settle(2)
	contains("the task strip follows the conversation", harness.textOf(harness.byName("Todos")),
		"alpha step one")
	handle.app.openSession(bravo.id)
	harness.settle(2)
	contains("both ways", harness.textOf(harness.byName("Todos")), "bravo step one")

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 42. Managing subagents ---------------------------------------------------

-- A dispatch is the longest-lived and least visible thing this client does: minutes of
-- work on its own context, its own tool calls, and -- until this -- one card in one
-- conversation's transcript. There was no register, so nothing could answer "what is
-- running", and no way to stop one child short of stopping the whole turn.
scenario("a dispatch is registered, watched and stopped", function()
	local parentStep = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = tostring(entry.body)
			if body:find("You are a subagent", 1, true) then
				-- Keeps working until something stops it, which is what makes it
				-- observable in the register and worth having a stop for.
				return { StatusCode = 200, delay = 1, Body = chatBody({
					toolCalls = { toolCall("c" .. tostring(math.random(1, 1000000)), "players_list", {}) },
				}) }
			end
			parentStep = parentStep + 1
			if parentStep == 1 then
				return { StatusCode = 200, Body = chatBody({
					toolCalls = { toolCall("d1", "dispatch_agent", {
						task = "sweep the place for doors", preset = "read",
					}) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "It was stopped before it answered." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")

	local subagent = handle.env.require("agent/subagent")
	local session = handle.sessions.current()
	session.send("find every door")
	harness.settle(6)

	local running = subagent.running()
	check("the dispatch is in the register", #running, 1)
	local record = running[1]
	contains("labelled with its task", record.label, "sweep the place")
	check("marked as running", record.status, "running")
	check("attributed to the conversation that asked", record.parentTitle, session.title)
	truthy("with the tools it has called", #record.tools > 0, tostring(#record.tools))

	-- The panel is the register, drawn.
	handle.app.show("agents")
	harness.settle(2)
	local panel = harness.byName("Agents")
	truthy("the panel is built", panel ~= nil)
	local shown = harness.textOf(panel)
	contains("the task is on screen", shown, "sweep the place")
	contains("with the capacity in use", shown, "1 of ")
	contains("and what it is allowed to touch", shown, "read tools")
	-- The ceilings are stated where the dispatches are, and changed in one place: two
	-- sets of sliders for one key can disagree, and one of them is always stale.
	contains("the limits in force are stated", shown, "of delegation")
	truthy("with a way to change them", harness.byName("OpenAgentSettings", panel) ~= nil)

	local stop = harness.byName("Stop", panel)
	truthy("a stop control is offered", stop ~= nil)
	harness.click(stop)
	harness.settle(1)
	-- The flag is the mechanism: Luau cannot kill a thread, so the child notices
	-- between steps and this is what it notices.
	truthy("the stop reached the child", record.session ~= nil and record.session.abortFlag == true)
	harness.settle(20)

	check("nothing is left running", #subagent.running(), 0)
	check("the record says it was stopped", record.status, "stopped")
	truthy("and how long it ran for", (record.ms or 0) > 0)

	-- The turn that dispatched it was not stopped with it: that is the whole point of
	-- a per-dispatch control.
	check("the conversation finished on its own", session.busy, false)
	local reports = {}
	for _, message in ipairs(session.ctx.messages) do
		if message.role == "tool" then reports[#reports + 1] = message end
	end
	check("the parent was handed a report", #reports, 1)
	contains("saying it stopped early", reports[1].content, "stopped early")
	contains("and the conversation answered", session.ctx.messages[#session.ctx.messages].content,
		"stopped before it answered")

	handle.app.show("agents")
	harness.settle(2)
	contains("the panel keeps it afterwards", harness.textOf(harness.byName("Agents")), "stopped")
	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 43. Transcript density ---------------------------------------------------

-- Every tool call used to be a top-level row, and the transcript puts a paragraph of
-- air between top-level rows because that gap is what separates a question from its
-- answer. A turn that called eight tools therefore arrived as eight paragraph-spaced
-- lines with eight listings hanging off them: the machinery was louder than anything
-- the agent said, which is what "too bloated with a lot of tool calls" looks like.
scenario("a turn's tool calls arrive as one foldable block", function()
	local step = 0
	-- Five different lookups rather than the same one five times: identical calls are
	-- what the repeat breaker exists to stop, and it would end the run at three.
	local paths = { "Workspace", "Players", "Lighting", "ReplicatedStorage", "SoundService" }
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step <= #paths then
				return { StatusCode = 200, Body = chatBody({
					reasoning = "Checking " .. paths[step] .. ".",
					toolCalls = { toolCall("t" .. tostring(step), "instance_get",
						{ path = paths[step] }) },
				}) }
			end
			return { StatusCode = 200, Body = chatBody({ content = "Five looks at the tree." }) }
		end,
	})
	handle.config.set("permissions.mode", "full")
	handle.sessions.current().send("look at the tree five times")
	harness.settle(20)

	local runs = harness.allByName("ToolRun")
	check("the whole run is one block", #runs, 1)
	local rows = harness.allByName("Tool", runs[1])
	check("holding every call", #rows, 5)
	check("and nothing is left at the top level", #harness.allByName("Tool", harness.byName("Transcript"))
		- #rows, 0)

	-- The thinking between calls goes in with them, in order: a row that sorted after
	-- the block would read as though it happened after the work it came before.
	truthy("the thinking between calls is inside it too",
		#harness.allByName("Reasoning", runs[1]) > 0)

	local header = harness.byName("RunHeader", runs[1])
	truthy("the block has a header", header ~= nil)
	contains("counting the run", harness.textOf(header), "5 tools")

	local calls = harness.byName("Calls", runs[1])
	check("a finished run of this size folds itself away", calls.Visible, false)
	harness.click(header)
	check("and the header opens it again", calls.Visible, true)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 44. The mascot -----------------------------------------------------------

-- The one piece of decoration in this interface, and the only place something is
-- alive. It was a static sprite; a static sprite perched on the composer is a
-- sticker. What it does is tied to the turn rather than invented, which is the only
-- honest thing a mascot can do here -- and reduced motion gets the sprite and
-- nothing else, like every other animation in the client.
scenario("the mascot is alive and answers reduced motion", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			return { StatusCode = 200, delay = 4, Body = chatBody({ content = "Done." }) }
		end,
	})
	harness.settle(2)

	local sprite = harness.byName("IconMascot")
	truthy("the mascot is on the composer", sprite ~= nil)
	-- The mock applies a tween's goal immediately, so a sprite that is marching sits at
	-- the top of its hop, rocked over, with its feet apart and its arms pulled in.
	truthy("it is off the ground", sprite.Position.Y.Offset < 0, tostring(sprite.Position.Y.Offset))
	truthy("and rocking", sprite.Rotation ~= 0, tostring(sprite.Rotation))

	local mascot = handle.app.chatPanel.composer.mascot
	truthy("the composer holds its handle", mascot ~= nil)
	check("resting while nothing is happening", mascot.busy, false)

	handle.sessions.current().send("take your time")
	harness.settle(1)
	check("working while the turn is", mascot.busy, true)
	harness.settle(12)
	check("and resting again afterwards", mascot.busy, false)

	-- Reduced motion: the sprite stays, the motion goes -- and it goes back to the
	-- frame it was drawn in rather than wherever a cancelled tween left it.
	handle.config.set("ui.reduceMotion", "on")
	harness.setViewport(1280, 820)
	harness.settle(2)
	handle.app.rebuild("test")
	harness.settle(2)
	check("reduced motion is in force", handle.env.require("ui/responsive").reduceMotion, true)
	local still = harness.byName("IconMascot")
	truthy("the mascot is still drawn", still ~= nil)
	check("and does not move", still.Position.Y.Offset, 0)
	check("or rock", still.Rotation, 0)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 45. The window is a CanvasGroup, and that has rules ----------------------

-- Why this exists: the window is a CanvasGroup, which renders every child into one
-- offscreen texture and then draws that texture. Draw it at anything other than 1:1 and
-- the texture is resampled -- so the whole interface, every glyph in it, goes soft at
-- once with nothing on screen to explain why. There were two ways in. A UIScale tweened
-- from 0.98 to 1 on the way in, which blurred the window for the length of the
-- animation and left it blurry for good if the tween was interrupted; and a 0.5 anchor
-- with an odd amount of space around it, which puts the group on a half pixel -- one
-- pixel of viewport or one drag of the resize grip was enough.
scenario("the window never draws itself between pixels", function()
	local harness, handle = bootWith({})
	handle.app.show("chat")
	harness.settle(2)

	local window = harness.byName("UAI_Window")
	truthy("the window is there", window ~= nil)
	check("and it is a CanvasGroup", window.ClassName, "CanvasGroup")
	check("with nothing scaling it", window:FindFirstChildOfClass("UIScale"), nil)

	-- An odd viewport is the case that used to soften it.
	local responsive = handle.env.require("ui/responsive")
	for _, size in ipairs({ { 1281, 805 }, { 1280, 800 }, { 1440, 901 } }) do
		harness.setViewport(size[1], size[2])
		harness.settle(2)
		local root = harness.byName("UAI_Window")
		local spareX = size[1] - root.Size.X.Offset
		local spareY = (size[2] - responsive.inset.Y) - root.Size.Y.Offset
		-- Only the offset-sized modes centre on their own measurements; a scale-sized
		-- one is inset by a fixed amount on both sides and is even by construction.
		if root.Size.X.Scale == 0 then
			check(string.format("%dx%d leaves whole pixels across", size[1], size[2]),
				spareX % 2, 0)
		end
		if root.Size.Y.Scale == 0 then
			check(string.format("%dx%d leaves whole pixels down", size[1], size[2]),
				spareY % 2, 0)
		end
	end

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

-- 46. Transcript typography ------------------------------------------------

-- Two things the mock cannot see, because it has no layout solver: whether a bullet
-- lines up with its text, and whether a block of output has room between its lines.
-- Both are decided by props, so that is where this looks -- the same reasoning as the
-- layout-invariant sweep.
--
-- The bullet was a 4px frame centred inside a 23px slot, next to a label centred inside
-- its own measured bounds. Two heights computed separately agree only by luck, and they
-- did not: every bullet in every reply sat low, down by the descender of its line. Now
-- the marker is text in the same role, on the same line height, top-aligned in a box of
-- that height -- one baseline by construction.
scenario("a bullet sits on the line it belongs to, and output has room", function()
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			return { StatusCode = 200, Body = chatBody({
				content = "Here is what I can do:\n- read the tree\n- write a file\n\n"
					.. "```\nPath: Workspace\nHealth: 100 / 100\nParts: 21\n```",
			}) }
		end,
	})
	handle.sessions.current().send("what can you do")
	harness.settle(12)

	local function nameOf(value)
		if type(value) == "table" and value.Name then return tostring(value.Name) end
		return tostring(value)
	end

	local theme = handle.env.require("ui/theme")
	local list = harness.byName("List")
	truthy("the bullets rendered as a list", list ~= nil)
	local markers = harness.allByName("Marker", list)
	check("one marker per item", #markers, 2)

	local marker = markers[1]
	check("the marker is text, not a dot in a box", marker.ClassName, "TextLabel")
	check("in the same line height as the item", marker.LineHeight, theme.text.body.line)
	check("top-aligned", nameOf(marker.TextYAlignment), "Top")
	check("inside a box one line tall", marker.Size.Y.Offset, theme.text.body.height)
	check("and it is the middle dot, which every family has", marker.Text, "\194\183")

	-- The item's own label has to match on all three or the construction means nothing.
	local item = nil
	for _, node in ipairs(list:GetDescendants()) do
		if node.ClassName == "TextLabel" and node.__props.Name ~= "Marker"
			and tostring(node.Text):find("read the tree", 1, true) then
			item = node
		end
	end
	truthy("the item text is there", item ~= nil)
	check("on the marker's line height", item and item.LineHeight, theme.text.body.line)
	check("and top-aligned with it", nameOf(item and item.TextYAlignment), "Top")

	-- Output. The gutter and the code are separate labels, so a line height they do not
	-- share puts number 11 beside line 9.
	local source = harness.byName("Source")
	truthy("the block rendered", source ~= nil)
	check("the code is on the code line height", source.LineHeight, theme.line.code)
	truthy("which is looser than the rest of the mono text",
		theme.line.code > theme.text.mono.line)
	local numbers = harness.byName("Numbers")
	truthy("with a gutter", numbers ~= nil)
	check("on exactly the same one", numbers.LineHeight, source.LineHeight)

	-- Air on the sides, and one number for both of them. The horizontal inset used to be
	-- two other measurements in disguise -- part of the gutter's own width on the left,
	-- padding on the scroll viewport on the right -- so the two edges of a block never
	-- agreed with each other and the language bar above them agreed with neither.
	local card = harness.byName("Code")
	truthy("the block is a card of its own", card ~= nil)
	local body = harness.byName("Body", card)
	local bodyPad = body and body:FindFirstChildOfClass("UIPadding")
	truthy("whose body is padded", bodyPad ~= nil)
	check("on the left", bodyPad and bodyPad.PaddingLeft.Offset, theme.space.lg)
	check("by the same amount on the right", bodyPad and bodyPad.PaddingRight.Offset, theme.space.lg)
	local bar = harness.byName("Bar", card)
	local barPad = bar and bar:FindFirstChildOfClass("UIPadding")
	truthy("and the language bar shares its left edge",
		barPad and barPad.PaddingLeft.Offset == theme.space.lg,
		barPad and tostring(barPad.PaddingLeft.Offset) or "no padding")
	local viewport = harness.byName("Viewport", card)
	truthy("with nothing left on the scroll to disagree with it",
		viewport and viewport:FindFirstChildOfClass("UIPadding") == nil)

	-- And air around it. A fenced block sat exactly as far from the sentence introducing
	-- it as from the next paragraph, which is what makes a reply read as one column with
	-- a slab dropped into it.
	truthy("the block is held off the prose either side of it",
		harness.byName("CodeSlot") ~= nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

scenario("icons use getcustomasset when the capability is present", function()
	local harness, handle = bootWith({ provider = false })
	local icons = handle.env.require("ui/icons")
	local caps = handle.env.require("runtime/caps")
	local fsx = handle.env.require("runtime/fsx")

	-- Mock executor customasset and filesystem
	local writtenFiles = {}
	caps.fn.customasset = function(path)
		return "rbxasset://" .. tostring(path)
	end
	caps.fn.writefile = function(path, content)
		writtenFiles[path] = content
		return true
	end
	caps.fn.readfile = function(path)
		return writtenFiles[path]
	end
	caps.fn.isfile = function(path)
		return writtenFiles[path] ~= nil
	end
	caps.fn.makefolder = function() end
	caps.fn.isfolder = function() return true end
	caps.fs = true

	local Instance = harness.sandbox.Instance
	local Color3 = harness.sandbox.Color3

	local testParent = Instance.new("Frame")
	local frame = icons.draw("gear", testParent, 24, Color3.fromRGB(255, 255, 255))
	truthy("an icon was created", frame ~= nil)
	check("named IconGear", frame.Name, "IconGear")
	local img = frame and frame:FindFirstChild("Image")
	truthy("an Image child was created", img ~= nil)
	check("its image is from getcustomasset", img and img.Image, "rbxasset://UAI/icons/settings.png")
	truthy("the asset was written to disk automatically", writtenFiles["UAI/icons/settings.png"] ~= nil)

	check("no thread errors", #harness.errors(), 0,
		harness.errors()[1] and harness.errors()[1].traceback or nil)
end)

print(("="):rep(72))
print(string.format("%d scenarios, %d checks passed, %d failed",
	suite.scenarios, suite.passed, suite.failed))if suite.failed > 0 then
	print("")
	for _, failure in ipairs(suite.failures) do print("  - " .. failure) end
end
os.exit(suite.failed > 0 and 1 or 0)
