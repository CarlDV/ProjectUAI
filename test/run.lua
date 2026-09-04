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
	if opts.toolCalls then message.tool_calls = opts.toolCalls end
	return json.encode({
		id = "cmpl_1",
		model = opts.model or "harness-model",
		choices = { { index = 0, message = message, finish_reason = opts.finish or (opts.toolCalls and "tool_calls" or "stop") } },
		usage = { prompt_tokens = 120, completion_tokens = 40, total_tokens = 160 },
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

print(("="):rep(72))
print(string.format("%d scenarios, %d checks passed, %d failed",
	suite.scenarios, suite.passed, suite.failed))
if suite.failed > 0 then
	print("")
	for _, failure in ipairs(suite.failures) do print("  - " .. failure) end
end
os.exit(suite.failed > 0 and 1 or 0)
