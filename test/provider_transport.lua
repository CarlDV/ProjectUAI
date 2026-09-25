-- Synthetic socket/SSE failure tests. Never opens a network connection.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local signal = require("instance").newSignal
local suite = F.suite("Provider transport")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function chunk(f, text, finish)
	return f.h.json.encode({ choices = { { delta = { content = text }, finish_reason = finish } } })
end
local function fixture(onSend)
	local f = F.new(); f.sockets = {}
	local caps = f.env.require("runtime/caps"); caps.ws = true
	function f.socket()
		local socket = { OnMessage = signal("message"), OnClose = signal("close"), sends = 0, closes = 0 }
		function socket:Send(envelope) self.sends = self.sends + 1; self.envelope = f.h.json.decode(envelope); if onSend then onSend(f, self) end end
		function socket:Close() self.closes = self.closes + 1; self.OnClose:Fire() end
		f.sockets[#f.sockets + 1] = socket
		return socket
	end
	caps.fn.websocket = function() return f.socket() end
	function f.request(spec, seconds)
		spec = spec or {}; spec.url = spec.url or "wss://fixture.test/stream"; spec.timeout = spec.timeout or 1
		return f.run(function() return f.env.require("net/ws").stream(spec) end, seconds or 0.2)
	end
	function f.record()
		local record = f.env.require("provider/registry").blank("custom")
		record.id, record.label = "socket-fixture", "Socket fixture"
		record.baseUrl, record.model, record.apiKey = "https://fixture.test/proxy/v1?tenant=one", "fixture-model", "fixture-key"
		record.wsUrl, record.claudeUa = "wss://gateway.test/stream", false
		return record
	end
	function f.complete(record, request, seconds)
		return f.run(function() return f.env.require("provider/chat").complete(record or f.record(), request or { messages = { { role = "user", content = "hello" } }, stream = true }) end, seconds or 0.2)
	end
	f.h.http.handler = function() return { StatusCode = 200, Body = f.h.json.encode({ choices = { { message = { role = "assistant", content = "HTTP fallback" }, finish_reason = "stop" } } }) } end
	function f.cleaned()
		for _, socket in ipairs(f.sockets) do
			check("socket closes once", socket.closes == 1)
			check("message and close subscriptions released", socket.OnMessage:Count() == 0 and socket.OnClose:Count() == 0)
		end
		check("connection slots released", f.env.require("net/ws").state().connections == 0)
		f.healthy()
	end
	return f
end

case("SSE decoder accepts arbitrary splits, CRLF, metadata and multiline data", function()
	local f = F.new(); local sse = f.env.require("net/sse")
	local body = "\239\187\191: heartbeat\r\n\r\nevent: chunk\r\nid: one\r\nretry: 10\r\ndata: {\r\ndata: \"choices\": [{\"delta\": {\"content\": \"hello\"}, \"finish_reason\": \"stop\"}]\r\ndata: }\r\n\r\ndata: [DONE]\r\n\r\n"
	for _, width in ipairs({ 1, 2, 3, 7, 19, #body }) do
		local frames = {}; local decoder = sse.decoder(function(frame) frames[#frames + 1] = frame end)
		for from = 1, #body, width do check("split accepted", decoder.push(body:sub(from, from + width - 1))) end
		check("EOF accepted", decoder.finish())
		check("metadata/comments do not become payloads", #frames == 2 and frames[1].event == "chunk" and frames[2].data == "[DONE]")
		check("multiline JSON stays valid", f.h.json.decode(frames[1].data).choices[1].delta.content == "hello")
	end
	local parsed = sse.parse(body)
	check("buffered decoder returns the same content", parsed.content == "hello" and not parsed.streamError)
	local bareCR = "event: chunk\rdata: " .. chunk(f, "CR stream", "stop") .. "\r\rdata: [DONE]\r\r"
	check("bare CR stream is recognized", sse.looksStreamed(bareCR) and sse.parse(bareCR).content == "CR stream")
	f.healthy(); f.close()
end)

case("tool argument objects survive and incompatible fragments fail", function()
	local f = F.new(); local sse = f.env.require("net/sse")
	local function tool(arguments, name)
		return { choices = { { delta = { tool_calls = { { index = 0, id = "call-a", ["function"] = { name = name, arguments = arguments } } } } } } }
	end
	local assembler = sse.assembler()
	check("object accepted", assembler.feedChunk(tool({ value = "hello", nested = { n = 3 } }, "fixture_tool")))
	local call = assembler.result().toolCalls[1]
	check("object serialized as JSON", type(call["function"].arguments) == "string" and f.h.json.decode(call["function"].arguments).nested.n == 3)
	check("later string fragment cannot corrupt object", not assembler.feedChunk(tool("}", nil)) and has(assembler.result().streamError, "malformed_stream:"))
	assembler = sse.assembler(); assembler.feedChunk(tool({}, "empty_tool"))
	check("empty object remains an object on wire", assembler.result().toolCalls[1]["function"].arguments == "{}")
	assembler = sse.assembler(); assembler.feedChunk(tool("{\"value\":", "fixture_tool")); assembler.feedChunk(tool("\"hello\"}", nil))
	check("normal string fragments still concatenate", assembler.result().toolCalls[1]["function"].arguments == "{\"value\":\"hello\"}")
	assembler = sse.assembler(); check("nonempty arrays are not argument objects", not assembler.feedChunk(tool({ "bad" }, "fixture_tool")))
	assembler = sse.assembler(); sse.limits.arguments = 32
	check("object arguments respect the byte limit", not assembler.feedChunk(tool({ value = string.rep("x", 33) }, "fixture_tool")))
	f.healthy(); f.close()
end)

case("Messages streams preserve complete argument objects and reject mixed input", function()
	local f = F.new(); local adapter = f.env.require("provider/anthropic")
	local function event(value) return "data: " .. f.h.json.encode(value) .. "\n\n" end
	local head = event({ type = "content_block_start", index = 0, content_block = { type = "tool_use", id = "native-call", name = "fixture_tool", input = { value = "kept" } } })
	local tail = event({ type = "message_delta", delta = { stop_reason = "tool_use" } }) .. event({ type = "message_stop" })
	local parsed = adapter.parseStream(head .. tail)
	check("whole input object survives", not parsed.streamError and f.h.json.decode(parsed.toolCalls[1]["function"].arguments).value == "kept")
	parsed = adapter.parseStream(head .. event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = "}" } }) .. tail)
	check("mixed input cannot silently corrupt a tool call", has(parsed.streamError, "malformed_stream:"))
	f.healthy(); f.close()
end)

case("an already cancelled request never opens a socket", function()
	local f = fixture(); local body, why = f.request({ aborted = function() return true end })
	check("pre-cancel is terminal without connecting", not body and why == "aborted" and #f.sockets == 0)
	f.cleaned(); f.close()
end)

case("raw chunks stream immediately and retain the complete endpoint envelope", function()
	local previews = 0
	local f = fixture(function(fx, socket)
		socket.OnMessage:Fire(chunk(fx, "socket reply", "stop")); socket.OnMessage:Fire("[DONE]")
	end)
	local record = f.record(); record.query = { mode = "a b" }; record.headers = { ["X-Tenant"] = "one" }
	local result, why = f.complete(record, { messages = { { role = "user", content = "hello" } }, stream = true, onFrame = function() previews = previews + 1 end })
	check("socket result: " .. tostring(why), result and result.content == "socket reply" and result.via == "websocket")
	local envelope = f.sockets[1].envelope
	check("prefix and query reach gateway", envelope.path == "/proxy/v1/chat/completions?tenant=one&mode=a%20b")
	check("provider credentials and content headers reach gateway", envelope.headers.Authorization == "Bearer fixture-key" and envelope.headers["Content-Type"] == "application/json" and envelope.headers.Accept == "text/event-stream")
	check("custom header and body retained", envelope.headers["X-Tenant"] == "one" and envelope.body.model == "fixture-model" and envelope.body.stream == true)
	check("preview once and no HTTP", previews == 1 and f.h.http.requestCount == 0)
	f.sockets[1].OnMessage:Fire(chunk(f, "late", "stop")); check("late preview ignored", previews == 1)
	f.cleaned(); f.close()
end)

case("OpenRouter and required Claude identities match HTTP inside sockets", function()
	for _, target in ipairs({ "https://openrouter.ai/api/v1", "https://agentrouter.org/v1" }) do
		local f = fixture(function(fx, socket) socket.OnMessage:Fire(chunk(fx, "ok", "stop")); socket.OnMessage:Fire("[DONE]") end)
		local record = f.record(); record.baseUrl = target; record.headers = { ["user-agent"] = "custom", ["X-App"] = "custom" }
		f.env.require("runtime/config").set("identity.claudeUa", false)
		check("socket completes", f.complete(record) ~= nil)
		local headers = f.sockets[1].envelope.headers
		if has(target, "openrouter") then
			check("OpenRouter attribution included", headers["X-OpenRouter-Title"] == "Project UAI" and not headers["X-App"])
		else
			check("required Claude identity included", has(headers["User-Agent"], "claude-cli/") and headers["x-app"] == "cli" and headers["user-agent"] == nil)
		end
		f.cleaned(); f.close()
	end
end)

case("socket accepts split and combined SSE events with metadata", function()
	local frames = 0
	local f = fixture(function(fx, socket)
		local stream = ": heartbeat\r\n\r\nevent: chunk\r\nid: first\r\ndata: " .. chunk(fx, "Hello ") .. "\r\n\r\ndata: " .. chunk(fx, "world", "stop") .. "\r\n\r\ndata: [DONE]\r\n\r\n"
		for from = 1, 49 do socket.OnMessage:Fire(stream:sub(from, from)) end
		socket.OnMessage:Fire(stream:sub(50))
	end)
	local body, why = f.request({ onFrame = function() frames = frames + 1 end })
	check("combined/split stream succeeds: " .. tostring(why), body ~= nil)
	check("text is assembled once", f.env.require("net/sse").parse(body).content == "Hello world" and frames == 2)
	f.cleaned(); f.close()
end)

case("socket accepts legacy data lines, raw DONE and pretty JSON", function()
	for _, style in ipairs({ "legacy", "pretty", "close" }) do
		local f = fixture(function(fx, socket)
			if style == "pretty" then socket.OnMessage:Fire('{\n "choices": [{"delta": {"content": "ok"}, "finish_reason": "stop"}]\n}')
			else socket.OnMessage:Fire("data: " .. chunk(fx, "ok", "stop")) end
			if style == "close" then socket.OnClose:Fire() else socket.OnMessage:Fire("[DONE]") end
		end)
		local body = f.request()
		check(style .. " response remains valid SSE", body and f.env.require("net/sse").parse(body).content == "ok")
		f.cleaned(); f.close()
	end
end)

case("unavailable and failed setup sockets fall back before dispatch", function()
	for _, failure in ipairs({ "connect", "events", "invalid-url", "unavailable" }) do
		local f = fixture(); local record = f.record(); local caps = f.env.require("runtime/caps")
		if failure == "connect" then caps.fn.websocket = function() error("fixture connection refused") end
		elseif failure == "events" then caps.fn.websocket = function() local socket = f.socket(); socket.OnMessage = nil; return socket end
		elseif failure == "invalid-url" then record.wsUrl = "https://gateway.test/stream"
		else caps.ws = false; caps.fn.websocket = nil end
		local result = f.complete(record)
		check(failure .. " has one HTTP fallback", result and result.content == "HTTP fallback" and f.h.http.requestCount == 1)
		for _, socket in ipairs(f.sockets) do check("nothing sent during setup failure", socket.sends == 0 and socket.closes == 1) end
		check("no connection slot leak", f.env.require("net/ws").state().connections == 0)
		f.healthy(); f.close()
	end
end)

case("connection deadline falls back and a late connection is closed without sending", function()
	local f = fixture(); local caps = f.env.require("runtime/caps")
	caps.fn.websocket = function() f.h.sched.wait(2); return f.socket() end
	local result = f.complete(nil, { messages = { { role = "user", content = "hi" } }, stream = true, timeout = 1 }, 1.3)
	check("deadline before send permits one fallback", result and result.content == "HTTP fallback" and f.h.http.requestCount == 1)
	check("pending connector is still counted", f.env.require("net/ws").state().workers == 1)
	f.h.sched.advance(1)
	check("late socket never dispatches", #f.sockets == 1 and f.sockets[1].sends == 0)
	check("late worker releases slot", f.env.require("net/ws").state().workers == 0)
	f.cleaned(); f.close()
end)

case("post-send exceptions and malformed streams never fall back", function()
	for _, failure in ipairs({ "send", "json", "truncated", "provider-error", "responses", "callback", "close-empty", "partial-sse" }) do
		local f = fixture(function(fx, socket)
			if failure == "send" then error("fixture send threw after possible delivery")
			elseif failure == "json" then socket.OnMessage:Fire("{broken")
			elseif failure == "truncated" then socket.OnMessage:Fire(chunk(fx, "unfinished")); socket.OnClose:Fire()
			elseif failure == "provider-error" then socket.OnMessage:Fire('{"error":{"message":"fixture refusal"}}')
			elseif failure == "responses" then socket.OnMessage:Fire('{"type":"response.output_text.delta","delta":"wrong protocol"}')
			elseif failure == "callback" then socket.OnMessage:Fire(chunk(fx, "ok", "stop")); socket.OnMessage:Fire("[DONE]")
			elseif failure == "partial-sse" then socket.OnMessage:Fire('data: {"choices":['); socket.OnClose:Fire()
			else socket.OnClose:Fire() end
		end)
		local result, why = f.complete(nil, { messages = { { role = "user", content = "hi" } }, stream = true,
			onFrame = failure == "callback" and function() error("fixture callback error") end or nil })
		check(failure .. " is terminal: " .. tostring(why), not result and f.env.require("net/http").terminal(why))
		check("no HTTP duplicate after " .. failure, f.h.http.requestCount == 0 and f.sockets[1].sends == 1)
		f.cleaned(); f.close()
	end
end)

case("post-send timeout is terminal and shuts down callbacks", function()
	local f = fixture(); local result, why = f.complete(nil, { messages = { { role = "user", content = "hi" } }, stream = true, timeout = 1 }, 1.3)
	check("sent request remains an unknown outcome", not result and has(why, "outcome is unknown") and f.h.http.requestCount == 0)
	check("exactly one send", f.sockets[1].sends == 1)
	f.cleaned(); f.close()
end)

case("cancel and disposal release sockets without late previews or fallback", function()
	for _, kind in ipairs({ "cancel", "dispose" }) do
		local stopped, previews = false, 0
		local f = fixture(function(fx, socket)
			socket.OnMessage:Fire(chunk(fx, "preview"))
			fx.h.sched.delay(0.08, function()
				if kind == "dispose" then fx.close() else stopped = true end
			end)
		end)
		local result, why = f.complete(nil, { messages = { { role = "user", content = "hi" } }, stream = true,
			aborted = function() return stopped end, onFrame = function() previews = previews + 1 end })
		check(kind .. " cancels inference", not result and why == "aborted" and f.h.http.requestCount == 0)
		f.sockets[1].OnMessage:Fire(chunk(f, "late", "stop")); check("late callbacks cannot publish", previews == 1)
		f.cleaned(); f.close()
	end
end)

case("effective stream=false and Messages protocol never use a socket", function()
	local f = fixture(function() error("socket must not be used") end); local record = f.record()
	record.params = { stream = false }
	local result = f.complete(record)
	check("body override selects HTTP", result and #f.sockets == 0 and f.h.http.requestCount == 1)
	local body = f.h.json.decode(f.h.http.log[1].body)
	check("HTTP request is consistently nonstreaming", body.stream == false and body.stream_options == nil and f.h.http.log[1].headers.Accept == "application/json")
	record.api, record.authStyle, record.params = "anthropic", "none", {}
	f.h.http.handler = function(entry)
		check("Messages route via HTTP", has(entry.url, "/messages?"))
		return { StatusCode = 200, Body = f.h.json.encode({ type = "message", role = "assistant", content = { { type = "text", text = "Messages HTTP" } }, stop_reason = "end_turn" }) }
	end
	result = f.complete(record)
	check("Messages ignores socket URL", result and result.content == "Messages HTTP" and #f.sockets == 0 and f.h.http.requestCount == 2)
	f.cleaned(); f.close()
end)

case("stream budgets remain bounded for socket and buffered responses", function()
	local f = fixture(function(fx, socket) socket.OnMessage:Fire("data: " .. chunk(fx, string.rep("x", 80), "stop") .. "\n\n") end)
	f.env.require("net/sse").limits.frame = 64
	local result, why = f.complete()
	check("oversized SSE event is terminal", not result and has(why, "malformed_stream:") and f.h.http.requestCount == 0)
	f.cleaned(); f.close()
	f = fixture(function(fx, socket)
		for _ = 1, 4 do socket.OnMessage:Fire(chunk(fx, "a")) end
	end)
	f.env.require("net/sse").limits.chunks = 3
	result, why = f.complete()
	check("socket message count is bounded", not result and has(why, "budget exceeded") and f.h.http.requestCount == 0)
	f.cleaned(); f.close()
	local plain = F.new(); local sse = plain.env.require("net/sse")
	sse.limits.body = 64
	local parsed = sse.parse("data: " .. string.rep("x", 65))
	check("buffered body limit retained", has(parsed.streamError, "8 MiB"))
	plain.healthy(); plain.close()
end)

case("socket worker limit permits HTTP while blocked connectors finish safely", function()
	local f = fixture(); local caps = f.env.require("runtime/caps"); local results = {}
	caps.fn.websocket = function() f.h.sched.wait(2); return f.socket() end
	for i = 1, 4 do f.h.sched.spawn(function() results[i] = { f.env.require("net/ws").stream({ url = "wss://fixture.test/stream", timeout = 1 }) } end) end
	check("four connectors are reserved", f.env.require("net/ws").state().workers == 4 and f.env.require("net/ws").state().connections == 4)
	local result = f.complete()
	check("fifth request uses HTTP before any socket dispatch", result and result.content == "HTTP fallback" and f.h.http.requestCount == 1)
	f.h.sched.advance(2.2)
	for _, reply in ipairs(results) do check("connection attempts ended before sending", not reply[1] and has(reply[2], "before dispatch")) end
	for _, socket in ipairs(f.sockets) do check("late connectors never send", socket.sends == 0) end
	check("workers all released", f.env.require("net/ws").state().workers == 0)
	f.cleaned(); f.close()
end)

case("executor WebSocket connector aliases are detected", function()
	for _, alias in ipairs({ "WebSocket", "websocket", "syn.websocket" }) do
		local f = F.new(); local connect = function() end
		f.h.sandbox.WebSocket, f.h.sandbox.websocket, f.h.sandbox.syn = nil, nil, nil
		if alias == "syn.websocket" then f.h.sandbox.syn = { websocket = { connect = connect } }
		else f.h.sandbox[alias] = { connect = connect } end
		local caps = f.env.require("runtime/caps")
		check(alias .. " is recognized", caps.ws and caps.fn.websocket == connect)
		f.healthy(); f.close()
	end
end)

suite.finish()
