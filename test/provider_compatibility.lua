-- Offline protocol contracts. Every response is synthetic; no model or key is used.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Provider compatibility")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function recordFor(f, preset)
	local record = f.env.require("provider/registry").blank(preset or "custom")
	record.id, record.label, record.model = "fixture-" .. (preset or "custom"), "Fixture provider", "fixture/model:instruct"
	record.models = { record.model }
	if record.baseUrl == "" then record.baseUrl = "https://fixture.test/proxy/v1" end
	record.apiKey = record.authStyle == "none" and "" or "fixture-key"
	return record
end
local function jsonReply(f, text)
	return { StatusCode = 200, Body = f.h.json.encode({ choices = { { message = { role = "assistant", content = text or "ok" }, finish_reason = "stop" } } }) }
end
local function complete(f, record, request)
	return f.run(function() return f.env.require("provider/chat").complete(record, request or { messages = { { role = "user", content = "hello" } }, stream = false }) end)
end
local TOOLS = { { type = "function", ["function"] = { name = "fixture_tool", description = "Synthetic tool",
	parameters = { type = "object", properties = { value = { type = "string" } }, required = { "value" } } } } }

-- Expected routes are intentionally independent of registry.endpoint(). Catalog
-- additions must add a row here; the suite cannot quietly skip a new preset.
local MATRIX = {
	{ "hcnsec", "https://api.hcnsec.cn/v1", "openai", "bearer" },
	{ "agentrouter", "https://agentrouter.org/v1", "anthropic", "x-api-key" },
	{ "openai", "https://api.openai.com/v1", "openai", "bearer" },
	{ "openrouter", "https://openrouter.ai/api/v1", "openai", "bearer" },
	{ "zen", "https://opencode.ai/zen/v1", "openai", "bearer" },
	{ "azure-foundry", "https://YOUR-RESOURCE.openai.azure.com/openai/v1", "openai", "api-key" },
	{ "anthropic-messages", "https://api.anthropic.com/v1", "anthropic", "x-api-key" },
	{ "anthropic", "https://api.anthropic.com/v1", "openai", "x-api-key" },
	{ "google", "https://generativelanguage.googleapis.com/v1beta/openai", "openai", "bearer" },
	{ "groq", "https://api.groq.com/openai/v1", "openai", "bearer" },
	{ "deepseek", "https://api.deepseek.com/v1", "openai", "bearer" },
	{ "together", "https://api.together.xyz/v1", "openai", "bearer" },
	{ "mistral", "https://api.mistral.ai/v1", "openai", "bearer" },
	{ "xai", "https://api.x.ai/v1", "openai", "bearer" },
	{ "fireworks", "https://api.fireworks.ai/inference/v1", "openai", "bearer" },
	{ "cerebras", "https://api.cerebras.ai/v1", "openai", "bearer" },
	{ "azure", "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT", "openai", "api-key", "?api-version=2024-10-21" },
	{ "ollama", "http://127.0.0.1:11434/v1", "openai", "none" },
	{ "lmstudio", "http://127.0.0.1:1234/v1", "openai", "none" },
	{ "vllm", "http://127.0.0.1:8000/v1", "openai", "none" },
	{ "llamacpp", "http://127.0.0.1:8080/v1", "openai", "none" },
	{ "sglang", "http://127.0.0.1:30000/v1", "openai", "none" },
	{ "custom", "https://fixture.test/proxy/v1", "openai", "bearer" },
}

case("the protocol matrix covers every advertised preset", function()
	local f = F.new(); local wanted = {}
	for _, row in ipairs(MATRIX) do wanted[row[1]] = true end
	local presets = f.env.require("provider/catalog").presets
	check("matrix/catalog count agrees", #presets == #MATRIX)
	for _, preset in ipairs(presets) do check("coverage for " .. preset.id, wanted[preset.id] == true) end
	f.healthy(); f.close()
end)

for _, row in ipairs(MATRIX) do
	case(row[1] .. " discovers, calls tools and replays results over JSON/SSE", function()
		local f = F.new(); local record = recordFor(f, row[1]); local native = row[3] == "anthropic"
		local posts, seenBodies = 0, {}
		check("preset wire/auth", record.api == row[3] and record.authStyle == row[4])
		f.h.http.handler = function(entry)
			local header = f.env.require("net/headers").get
			if row[4] == "none" then
				check("no unsolicited local credentials/identity", not header(entry.headers, "Authorization") and not header(entry.headers, "x-api-key") and not header(entry.headers, "x-app"))
			elseif row[4] == "bearer" then check("Bearer auth", header(entry.headers, "Authorization") == "Bearer fixture-key")
			else check("named auth header", header(entry.headers, row[4]) == "fixture-key") end
			if native then check("Messages version header", header(entry.headers, "anthropic-version") == "2023-06-01") end
			if entry.method == "GET" then
				check("model discovery route", entry.url == row[2] .. "/models" .. (row[5] or ""))
				return { StatusCode = 200, Body = f.h.json.encode({ data = { { id = record.model }, { id = "embedding-fixture" } } }) }
			end
			check("completion route", entry.url == row[2] .. (native and "/messages" or "/chat/completions") .. (row[5] or ""))
			posts = posts + 1
			local body = f.h.json.decode(entry.body); seenBodies[posts] = body
			check("model/deployment selection", row[1] == "azure" and body.model == nil or row[1] ~= "azure" and body.model == record.model)
			check("effective Accept header", header(entry.headers, "Accept") == (body.stream and "text/event-stream" or "application/json"))
			check("tools reach the server", type(body.tools) == "table" and #body.tools > 0)
			if row[1] == "ollama" then check("Ollama avoids unsupported defaults", body.tool_choice == nil and body.parallel_tool_calls == nil) end
			if posts == 1 then
				if native then
					return { StatusCode = 200, Body = f.h.json.encode({ type = "message", role = "assistant", id = "fixture-message", model = record.model,
						content = { { type = "text", text = "using a tool" }, { type = "tool_use", id = "call-fixture", name = "fixture_tool", input = { value = row[1] } } },
						stop_reason = "tool_use", usage = { input_tokens = 17, output_tokens = 8 } }) }
				end
				local args = row[4] == "none" and { value = row[1] } or f.h.json.encode({ value = row[1] })
				return { StatusCode = 200, Body = f.h.json.encode({ id = "fixture-message", model = record.model,
					choices = { { message = { role = "assistant", content = "using a tool", tool_calls = {
						{ id = "call-fixture", type = "function", ["function"] = { name = "fixture_tool", arguments = args } } } }, finish_reason = "tool_calls" } },
					usage = { prompt_tokens = 17, completion_tokens = 8 } }) }
			end
			check("tool result retained on the next request", has(entry.body, "fixture result") and has(entry.body, "call-fixture"))
			local chunks = {}
			local function event(value) chunks[#chunks + 1] = "data: " .. f.h.json.encode(value) .. "\r\n\r\n" end
			if native then
				event({ type = "message_start", message = { id = "final", model = record.model, usage = { input_tokens = 20, output_tokens = 0 } } })
				event({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
				event({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "finished " .. row[1] } })
				event({ type = "content_block_stop", index = 0 })
				event({ type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 9 } })
				event({ type = "message_stop" })
			else
				event({ choices = { { delta = { content = "finished " .. row[1], reasoning_content = "fixture reasoning" }, finish_reason = "stop" } } })
				event({ choices = {}, usage = { prompt_tokens = 20, completion_tokens = 9 } })
				chunks[#chunks + 1] = "data: [DONE]\r\n\r\n"
			end
			return { StatusCode = 200, Body = ": fixture heartbeat\r\n\r\n" .. table.concat(chunks), Headers = { ["Content-Type"] = "text/event-stream" } }
		end
		local found = f.run(function() return f.env.require("provider/models").discover(record) end)
		check("discovery keeps all model ids", #found == 2 and found[1] == "embedding-fixture")
		local first, why = complete(f, record, { messages = { { role = "system", content = "fixture instructions" }, { role = "user", content = "use tool" } }, tools = TOOLS, stream = false, maxTokens = 256 })
		check("JSON completion succeeded: " .. tostring(why), first ~= nil and #first.toolCalls == 1)
		local call = first.toolCalls[1]
		check("tool name/id/arguments survive", call.id == "call-fixture" and call["function"].name == "fixture_tool" and f.h.json.decode(call["function"].arguments).value == row[1])
		local final, finalError = complete(f, record, { messages = { { role = "user", content = "use tool" },
			{ role = "assistant", content = first.content, toolCalls = first.toolCalls }, { role = "tool", tool_call_id = call.id, content = "fixture result" } },
			tools = TOOLS, stream = true, maxTokens = 256 })
		check("SSE completion succeeded: " .. tostring(finalError), final ~= nil and final.content == "finished " .. row[1] and final.finish == "stop")
		check("usage and streaming retained", final.streamed and final.usage.completion_tokens == 9)
		if not native then check("reasoning retained", final.reasoning == "fixture reasoning") end
		check("only discovery and two intended requests", f.h.http.requestCount == 3 and posts == 2)
		f.healthy(); f.close()
	end)
end

case("URL normalization handles public, local, LAN, IPv6 and prefixes", function()
	local f = F.new(); local registry = f.env.require("provider/registry")
	local examples = {
		{ "api.example.com", "https://api.example.com/v1" },
		{ "localhost:11434", "http://localhost:11434/v1" },
		{ "host.local:8000/", "http://host.local:8000/v1" },
		{ "inference-box:8000/proxy/v1/", "http://inference-box:8000/proxy/v1" },
		{ "192.168.1.20:1234", "http://192.168.1.20:1234/v1" },
		{ "10.42.1.2:8000", "http://10.42.1.2:8000/v1" },
		{ "172.20.1.2:8000", "http://172.20.1.2:8000/v1" },
		{ "[::1]:8080", "http://[::1]:8080/v1" },
		{ "[fd12::1]:8000/v1", "http://[fd12::1]:8000/v1" },
		{ "[2001:db8::1]:8000/v1", "https://[2001:db8::1]:8000/v1" },
		{ "HTTPS://localhost:1234/v1/", "https://localhost:1234/v1" },
		{ "https://example.com?token=fixture#ignored", "https://example.com/v1?token=fixture" },
		{ "https://example.com/proxy/v1/?token=fixture", "https://example.com/proxy/v1?token=fixture" },
	}
	for _, example in ipairs(examples) do check(example[1], registry.normaliseBaseUrl(example[1]) == example[2]) end
	local record = recordFor(f); record.baseUrl = "https://example.com/prefix/v1/chat/completions?token=fixture&api-version=old"
	record.query = { ["api-version"] = "new", tag = "a b" }
	check("suffix precedes query and overrides are not duplicated", registry.endpoint(record, "/models") == "https://example.com/prefix/v1/models?token=fixture&api-version=new&tag=a%20b")
	record.baseUrl = "https://example.com/prefix/v1/messages/?token=fixture"; record.query = {}
	check("full Messages discovery", registry.endpoint(record, "/models") == "https://example.com/prefix/v1/models?token=fixture")
	check("full Messages inference", f.env.require("provider/anthropic").endpoint(record) == "https://example.com/prefix/v1/messages?token=fixture")
	check("full endpoint recognition with query", registry.isFullEndpoint(record.baseUrl))
	for _, bad in ipairs({ "ftp://example.com/v1", "ws://example.com/v1", "https://", "https://user:pass@example.com/v1", "https://example.com:99999", "https://bad host/v1" }) do
		record.baseUrl = bad; local valid = registry.validate(record); check("invalid base " .. bad, not valid)
	end
	f.healthy(); f.close()
end)

case("local reachability follows actual addresses and native paths fail before inference", function()
	local f = F.new(); local registry = f.env.require("provider/registry"); local record = recordFor(f)
	f.env.require("runtime/caps").http = "roblox"
	for _, base in ipairs({ "localhost:11434", "http://127.0.0.2:8000", "http://192.168.1.10:1234", "http://[::ffff:127.0.0.1]:8000" }) do
		record.baseUrl = base; local ok, problems = registry.validate(record)
		check("custom local address needs executor", not ok and has(table.concat(problems, " "), "executor HTTP"))
	end
	record.preset, record.requires, record.baseUrl = "vllm", "executor", "https://public.example.com/v1"
	check("public address in old local preset is accepted", registry.validate(record))
	record.baseUrl = "http://localhost:11434/api/chat"
	local result, why = complete(f, record)
	check("native Ollama route has an actionable diagnostic", not result and has(why, "/v1"))
	record.baseUrl, record.api = "https://fixture.test/v1", "unimplemented"
	result, why = complete(f, record)
	check("unknown protocol is not silently routed", not result and has(why, "not implemented"))
	check("protocol failures made no requests", f.h.http.requestCount == 0)
	f.healthy(); f.close()
end)

case("key pools and explicit Messages auth select one credential", function()
	local f = F.new(); local registry = f.env.require("provider/registry"); local record = recordFor(f)
	record.apiKey = " key-one\nkey-two, key-three\nkey-one "
	registry.cooldownKey(record, "key-one", 30); registry.cooldownKey(record, "key-two", 10); registry.cooldownKey(record, "key-three", 20)
	check("all cooling selects the earliest key string", registry.nextKey(record) == "key-two")
	check("discovery headers contain one credential", f.env.require("provider/chat").headers(record).Authorization == "Bearer key-two")
	record.api = "anthropic"
	local headers = f.env.require("provider/chat").headers(record)
	check("Messages honors explicit Bearer", headers.Authorization == "Bearer key-two" and headers["x-api-key"] == nil)
	record.authStyle = "both"; headers = f.env.require("provider/chat").headers(record)
	check("both uses the same selected credential", headers.Authorization == "Bearer key-two" and headers["x-api-key"] == "key-two")
	record.authStyle = "none"; headers = f.env.require("provider/chat").headers(record)
	check("none sends no auth but retains Messages version", not headers.Authorization and not headers["x-api-key"] and headers["anthropic-version"])
	f.healthy(); f.close()
end)

case("header overrides are case insensitive and identity is host scoped", function()
	local f = F.new(); local http = f.env.require("net/http"); local record = recordFor(f)
	record.headers = { authorization = "Bearer override", ["content-TYPE"] = "application/custom", ["user-agent"] = "custom-client" }
	local headers = http.headersFor({ url = "https://fixture.test/openrouter.ai?host=openrouter.ai", identity = "none", body = "{}", headers = f.env.require("provider/chat").headers(record) })
	check("custom auth replaces default", headers.authorization == "Bearer override" and headers.Authorization == nil)
	check("no duplicate content type or user-agent", headers["content-TYPE"] == "application/custom" and headers["Content-Type"] == nil and headers["user-agent"] == "custom-client" and headers["User-Agent"] == nil)
	check("substring does not select OpenRouter identity", headers["HTTP-Referer"] == nil)
	headers = http.headersFor({ url = "HTTPS://OPENROUTER.AI.:443/api/v1/chat/completions", headers = { ["x-stainless-lang"] = "bad", ["X-App"] = "bad" } })
	check("official host receives attribution", headers["X-OpenRouter-Title"] == "Project UAI")
	check("case variants of competing identity are removed", headers["x-stainless-lang"] == nil and headers["X-App"] == nil)
	f.healthy(); f.close()
end)

case("discovery separates drafts and changes in connection/auth", function()
	local f = F.new(); local models = f.env.require("provider/models"); local a, b = recordFor(f), recordFor(f)
	a.id, b.id = "", ""; a.baseUrl, b.baseUrl = "http://localhost:1234/v1", "http://localhost:8000/v1"
	local serial = 0
	f.h.http.handler = function() serial = serial + 1; return { StatusCode = 200, Body = f.h.json.encode({ models = { { name = "model-" .. serial }, { name = " model-" .. serial .. " " } } }) } end
	local function fetch(record) return f.run(function() return models.discover(record) end) end
	check("first draft list is deduplicated after trim", #fetch(a) == 1 and models.discovered(a)[1] == "model-1")
	check("second draft uses its own endpoint", fetch(b)[1] == "model-2")
	check("unchanged connection is cached", fetch(a)[1] == "model-1" and serial == 2)
	a.apiKey = "different-key"; check("auth changes invalidate cached models", fetch(a)[1] == "model-3")
	a.baseUrl = "http://localhost:9000/v1"; check("endpoint changes invalidate cached models", fetch(a)[1] == "model-4")
	a.headers = { ["X-Tenant"] = "second" }; check("header changes invalidate cached models", fetch(a)[1] == "model-5")
	a.query = { tenant = "third" }; check("query changes invalidate cached models", fetch(a)[1] == "model-6")
	check("other draft remains cached", fetch(b)[1] == "model-2" and serial == 6)
	f.healthy(); f.close()
end)

case("failed discovery is never cached as an empty success", function()
	local f = F.new(); local models = f.env.require("provider/models"); local record = recordFor(f)
	local status = 401
	f.h.http.handler = function() return { StatusCode = status, Body = f.h.json.encode({ error = { message = "fixture refusal" } }) } end
	for _, code in ipairs({ 401, 403, 404, 422, 200 }) do
		status = code
		local found, note = f.run(function() return models.discover(record, { force = true }) end)
		check("error status is not an empty success: " .. code, #found == 0 and not has(note, "empty list"))
		if code == 401 then check("auth diagnostic", has(note, "key was rejected")) end
		if code == 403 then check("permission diagnostic", has(note, "not allowed")) end
		if code == 404 then check("manual entry diagnostic", has(note, "by hand")) end
		check("no failed cache entry", models.cached(record) == nil)
		check("manual model remains available", models.list(record)[1] == record.model)
	end
	f.healthy(); f.close()
end)

case("discovery rejects out-of-order, changed and invalidated requests", function()
	local f = F.new(); local models = f.env.require("provider/models"); local record = recordFor(f)
	f.h.http.handler = function(entry) return { StatusCode = 200, delay = entry.index == 1 and 0.3 or 0.05,
		Body = f.h.json.encode({ data = { { id = "response-" .. entry.index } } }) } end
	local first, second
	f.h.sched.spawn(function() first = { models.discover(record, { force = true }) } end)
	f.h.sched.spawn(function() second = { models.discover(record, { force = true }) } end)
	f.h.sched.advance(0.5)
	check("newest response owns cache", second[1][1] == "response-2" and models.discovered(record)[1] == "response-2")
	check("older response is suppressed", #first[1] == 0 and has(first[2], "superseded"))
	f.h.sched.spawn(function() first = { models.discover(record, { force = true }) } end)
	record.apiKey = "changed-during-request"; f.h.sched.advance(0.2)
	check("in-flight setting change is suppressed", #first[1] == 0 and #models.discovered(record) == 0)
	f.h.sched.spawn(function() first = { models.discover(record, { force = true }) } end)
	models.invalidate(record); f.h.sched.advance(0.2)
	check("invalidation cannot be undone by old response", #first[1] == 0 and models.cached(record) == nil)
	f.healthy(); f.close()
end)

case("FastAPI parameter errors are repairable without echoing input", function()
	local f = F.new(); local adapter = f.env.require("provider/openai"); local record = recordFor(f)
	local errorBody = f.h.json.encode({ detail = { { loc = { "body", "tool_choice" }, msg = "Extra inputs are not permitted", type = "extra_forbidden", input = "never-echo-this-prompt" } } })
	local message = adapter.errorText({ status = 422, body = errorBody })
	check("field path retained", has(message, "body.tool_choice"))
	check("input omitted", not has(message, "never-echo"))
	local bodies = {}
	f.h.http.handler = function(entry)
		bodies[#bodies + 1] = f.h.json.decode(entry.body)
		if #bodies == 1 then return { StatusCode = 422, Body = errorBody } end
		return jsonReply(f)
	end
	local result = complete(f, record, { messages = { { role = "user", content = "hi" } }, tools = TOOLS, stream = false })
	check("one field refusal is repaired", result and #bodies == 2 and bodies[1].tool_choice == "auto" and bodies[2].tool_choice == nil and #bodies[2].tools > 0)
	f.healthy(); f.close()
end)

case("learned repairs and output caps stay with their model and endpoint", function()
	local f = F.new(); local adapter = f.env.require("provider/openai"); local record = recordFor(f)
	local bodies = {}
	f.h.http.handler = function(entry)
		bodies[#bodies + 1] = f.h.json.decode(entry.body)
		if #bodies == 1 then return { StatusCode = 400, Body = f.h.json.encode({ error = { message = "Unsupported parameter: temperature" } }) } end
		return jsonReply(f)
	end
	check("initial request repairs", complete(f, record) ~= nil)
	check("repair is reused", complete(f, record) ~= nil and bodies[3].temperature == nil)
	record.model = "other-model"; check("different model is not stripped", complete(f, record) ~= nil and bodies[4].temperature ~= nil)
	adapter.rememberMaxTokens(record, 2048)
	check("learned cap applies on same endpoint/model", adapter.cappedMaxTokens(record, 10000) == 2048)
	record.baseUrl = "https://another.test/v1"
	check("same model on another endpoint gets its own cap", adapter.cappedMaxTokens(record, 10000) == 10000)
	record.maxTokensCap = { model = record.model, tokens = 1024 }
	check("legacy cap adopts current scope", adapter.cappedMaxTokens(record, 10000) == 1024)
	record.baseUrl = "https://third.test/v1"
	check("adopted legacy cap is then scoped", adapter.cappedMaxTokens(record, 10000) == 10000)
	f.healthy(); f.close()
end)

case("small local contexts and explicit output bounds are recognized", function()
	local f = F.new(); local adapter = f.env.require("provider/openai"); local record = recordFor(f)
	for _, limit in ipairs({ 512, 2048, 4096 }) do
		local text = "This model's maximum context length is " .. limit .. " tokens; requested 9000 including max_tokens 8192"
		check("small named window " .. limit, adapter.contextWindowFromMessage(text) == limit)
		local body = { max_tokens = 8192 }; check("context refusal never teaches output limit", adapter.repairForTest(body, text) == nil and body.max_tokens == 8192)
	end
	adapter.rememberContextWindow(record, 2048)
	check("small learned window reaches context traits", f.env.require("provider/traits").contextWindow(record.model) == 2048)
	check("explicit 512 output bound", adapter.ceilingFromMessage("max_tokens must be less than or equal to 512 (400)", 4096) == 512)
	local body = { max_completion_tokens = 4096 }
	check("renamed token field can learn a small bound", adapter.repairForTest(body, "max_completion_tokens must be less than or equal to 512") ~= nil and body.max_completion_tokens == 512)
	body = { max_tokens = 8192 }
	check("unnumbered context errors cannot teach output caps", adapter.repairForTest(body, "context_length_exceeded: reduce max_tokens or the prompt") == nil and body.max_tokens == 8192)
	f.healthy(); f.close()
end)

case("a refusal cannot teach or resend through a connection changed in flight", function()
	for _, protocol in ipairs({ "openai", "anthropic" }) do
		local f = F.new(); local record = recordFor(f); record.api = protocol
		f.h.http.handler = function() return { StatusCode = 400, delay = 0.1, Body = f.h.json.encode({ error = { message = "max_tokens must be less than or equal to 512" } }) } end
		f.h.sched.delay(0.05, function() record.baseUrl, record.model = "https://new-connection.test/v1", "new-model" end)
		local result, why = complete(f, record)
		check(protocol .. " old request stops before another dispatch", not result and why == "aborted" and f.h.http.requestCount == 1)
		check(protocol .. " new selection inherits no old cap", record.maxTokensCap == nil)
		f.healthy(); f.close()
	end
end)

case("optional body controls respect explicit stream and tool choices", function()
	local f = F.new(); local adapter = f.env.require("provider/openai"); local record = recordFor(f, "ollama")
	local body = adapter.buildBody(record, { tools = TOOLS, stream = true, parallelToolCalls = false, toolChoice = "required" })
	check("explicit options are literal", body.parallel_tool_calls == false and body.tool_choice == "required")
	record.params = { stream = false }
	body = adapter.buildBody(record, { stream = true })
	check("nonstreaming override removes stream-only options", body.stream == false and body.stream_options == nil)
	f.healthy(); f.close()
end)

suite.finish()
