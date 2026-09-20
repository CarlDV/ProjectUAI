-- Tests for reasoning replay and auto-repairs in thinking mode.
-- Run: luajit test/reasoning_replay.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local json = require("json")
local passed, failed = 0, 0

local function check(label, condition, detail)
	if not condition then
		error(label .. (detail and (": " .. tostring(detail)) or ""), 2)
	end
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

local function chatBody(opts)
	opts = opts or {}
	local message = { role = "assistant", content = opts.content or "" }
	if opts.reasoning then message.reasoning_content = opts.reasoning end
	if opts.toolCalls then message.tool_calls = opts.toolCalls end
	return json.encode({
		id = "cmpl_test",
		model = opts.model or "harness-model",
		choices = { { index = 0, message = message, finish_reason = opts.finish or (opts.toolCalls and "tool_calls" or "stop") } },
		usage = { prompt_tokens = 10, completion_tokens = 10, total_tokens = 20 },
	})
end

local function bootWith(opts)
	opts = opts or {}
	local harness = envMock.new({ executor = opts.executor, stream = opts.stream })
	harness.http.handler = opts.handler
	local handle, err = harness.boot()
	if not handle then error("boot failed: " .. tostring(err), 0) end
	harness.settle(1)

	if opts.provider ~= false then
		local record = handle.providers.blank(opts.preset or "custom")
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
		if tostring(entry.url):find("/chat/completions") then
			out[#out + 1] = { raw = entry, body = json.decode(entry.body) }
		end
	end
	return out
end

scenario("wireMessages retains reasoning_content for assistant turns", function()
	local _, handle = bootWith({ provider = false })
	local openai = handle.env.require("provider/openai")

	-- 1. Assistant message with reasoning and prose
	local msgs1 = {
		{ role = "user", content = "hello" },
		{ role = "assistant", content = "hi there", reasoning = "thought process here" },
	}
	local wired1 = openai.wireMessages(msgs1)
	check("assistant has role", wired1[2].role == "assistant")
	check("assistant has content", wired1[2].content == "hi there")
	check("assistant has reasoning_content", wired1[2].reasoning_content == "thought process here")

	-- 2. Assistant message with tool calls and reasoning
	local msgs2 = {
		{ role = "user", content = "read file" },
		{
			role = "assistant",
			content = "",
			reasoning = "thinking about tool",
			toolCalls = {
				{ id = "call_1", ["function"] = { name = "read", arguments = '{"path":"a.txt"}' } }
			}
		},
		{ role = "tool", tool_call_id = "call_1", content = "file contents" },
	}
	local wired2 = openai.wireMessages(msgs2)
	check("tool calling assistant has reasoning_content", wired2[2].reasoning_content == "thinking about tool")
	check("tool calling assistant has tool_calls", #(wired2[2].tool_calls or {}) == 1)
	check("tool calling assistant preserved tool_call id", wired2[2].tool_calls[1].id == "call_1")

	-- 3. Assistant message without reasoning
	local msgs3 = {
		{ role = "user", content = "quick question" },
		{ role = "assistant", content = "quick answer" },
	}
	local wired3 = openai.wireMessages(msgs3)
	check("non-reasoning assistant omits reasoning_content", wired3[2].reasoning_content == nil)
end)

scenario("reasoning_content is replayed on subsequent chat completions turns", function()
	local step = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			step = step + 1
			if step == 1 then
				return { StatusCode = 200, Body = chatBody({ content = "Step 1 done", reasoning = "Thinking step 1" }) }
			else
				return { StatusCode = 200, Body = chatBody({ content = "Step 2 done", reasoning = "Thinking step 2" }) }
			end
		end,
	})

	local session = handle.sessions.current()
	session.send("first prompt")
	harness.settle(10)

	local requests1 = chatRequests(harness)
	check("first request went out", #requests1 == 1)

	session.send("second prompt")
	harness.settle(10)

	local requests2 = chatRequests(harness)
	check("second request went out", #requests2 == 2)
	local assistantMsg = requests2[2].body.messages[3]
	check("assistant message has role assistant", assistantMsg.role == "assistant")
	check("assistant message preserved content", assistantMsg.content == "Step 1 done")
	check("assistant message preserved reasoning_content", assistantMsg.reasoning_content == "Thinking step 1")
end)

scenario("reasoning_content missing in thinking mode is repaired and remembered", function()
	local attempts = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = json.decode(entry.body)
			attempts = attempts + 1
			if attempts == 1 then
				return { StatusCode = 200, Body = chatBody({ content = "I answered with no thought." }) }
			elseif attempts == 2 then
				for _, msg in ipairs(body.messages) do
					if msg.role == "assistant" and msg.reasoning_content == nil then
						return { StatusCode = 400, Body = json.encode({
							error = { message = "The `reasoning_content` in the thinking mode must be passed back to the API. [trace_id=test123]" },
						}) }
					end
				end
				return { StatusCode = 200, Body = chatBody({ content = "Second answer." }) }
			else
				return { StatusCode = 200, Body = chatBody({ content = "Second answer." }) }
			end
		end,
	})

	local session = handle.sessions.current()
	session.send("prompt 1")
	harness.settle(10)

	session.send("prompt 2")
	harness.settle(20)

	local requests = chatRequests(harness)
	check("three requests total (turn 1, turn 2 rejected with 400, turn 2 repaired retry)", #requests == 3)
	check("repaired retry had reasoning_content set", requests[3].body.messages[3].reasoning_content == "")
	check("answer landed", session.ctx.messages[#session.ctx.messages].content == "Second answer.")
	local repairs = handle.providers.active().repairs or {}
	local remembered = false
	for _, r in ipairs(repairs) do if r == "require_reasoning_content" then remembered = true end end
	check("require_reasoning_content was remembered on provider", remembered)
end)

scenario("content[].thinking refusal in thinking mode is repaired into blocks", function()
	local attempts = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = json.decode(entry.body)
			attempts = attempts + 1
			if attempts == 1 then
				return { StatusCode = 200, Body = chatBody({ content = "I thought a bit.", reasoning = "Some thoughts" }) }
			elseif attempts == 2 then
				local assistant = body.messages[3]
				if type(assistant.content) ~= "table" then
					return { StatusCode = 400, Body = json.encode({
						error = { message = "The `content[].thinking` in the thinking mode must be passed back to the API. [trace_id=test456]" },
					}) }
				end
				return { StatusCode = 200, Body = chatBody({ content = "Done." }) }
			else
				return { StatusCode = 200, Body = chatBody({ content = "Done." }) }
			end
		end,
	})

	local session = handle.sessions.current()
	session.send("prompt 1")
	harness.settle(10)

	session.send("prompt 2")
	harness.settle(20)

	local requests = chatRequests(harness)
	check("three requests total", #requests == 3)
	local retryAssistant = requests[3].body.messages[3]
	check("assistant content became a table", type(retryAssistant.content) == "table")
	check("first content block is thinking", retryAssistant.content[1].type == "thinking")
	check("thinking text preserved", retryAssistant.content[1].thinking == "Some thoughts")
	check("second content block is text", retryAssistant.content[2].type == "text")
	check("text content preserved", retryAssistant.content[2].text == "I thought a bit.")

	-- The conversion is ephemeral: a gateway that multiplexes backends would fail
	-- the next turn if it were remembered, so it must not be saved on the record.
	local repairs = handle.providers.active().repairs or {}
	for _, r in ipairs(repairs) do
		check("content[].thinking is not remembered", r ~= "content[].thinking", r)
	end
end)

scenario("unknown variant thinking (422) is repaired by flattening blocks back", function()
	local openai
	local _, handle = bootWith({ provider = false })
	openai = handle.env.require("provider/openai")

	-- Simulate the body a sibling backend rejects: an assistant turn whose content
	-- was already converted to thinking blocks by the sibling's Anthropic backend.
	local body = {
		messages = {
			{ role = "user", content = "hi" },
			{
				role = "assistant",
				content = {
					{ type = "thinking", thinking = "my private reasoning" },
					{ type = "text", text = "the answer" },
				},
			},
			{ role = "user", content = "again" },
		},
	}

	local message = "Failed to deserialize the JSON body into the target type: "
		.. "messages[2]: unknown variant `thinking`, expected one of `text`, `image_url`, `file`"
	local note, key = openai.repairForTest(body, message)
	check("reversal produced a note", type(note) == "string", note)
	check("reversal key is revert_thinking_blocks", key == "revert_thinking_blocks", key)

	local assistant = body.messages[2]
	check("content flattened to a string", type(assistant.content) == "string", type(assistant.content))
	check("text preserved after flatten", assistant.content == "the answer", assistant.content)
	check("reasoning restored", assistant.reasoning_content == "my private reasoning", assistant.reasoning_content)
end)

scenario("forbidden reasoning_content refusal is repaired by dropping the field", function()
	local attempts = 0
	local harness, handle = bootWith({
		handler = function(entry)
			if not tostring(entry.url):find("/chat/completions") then return { StatusCode = 404, Body = "{}" } end
			local body = json.decode(entry.body)
			attempts = attempts + 1
			if attempts == 1 then
				return { StatusCode = 200, Body = chatBody({ content = "Ans 1", reasoning = "Thought 1" }) }
			elseif attempts == 2 then
				for _, msg in ipairs(body.messages) do
					if msg.role == "assistant" and msg.reasoning_content ~= nil then
						return { StatusCode = 400, Body = json.encode({
							error = { message = "Extra inputs are not permitted: reasoning_content" },
						}) }
					end
				end
				return { StatusCode = 200, Body = chatBody({ content = "Ans 2" }) }
			else
				return { StatusCode = 200, Body = chatBody({ content = "Ans 2" }) }
			end
		end,
	})

	local session = handle.sessions.current()
	session.send("prompt 1")
	harness.settle(10)

	session.send("prompt 2")
	harness.settle(20)

	local requests = chatRequests(harness)
	check("three requests total", #requests == 3)
	check("retry dropped reasoning_content", requests[3].body.messages[3].reasoning_content == nil)
	local repairs = handle.providers.active().repairs or {}
	local remembered = false
	for _, r in ipairs(repairs) do if r == "drop_reasoning_content" then remembered = true end end
	check("drop_reasoning_content was remembered on provider", remembered)
end)

scenario("sse parser handles thinking field and content thinking blocks", function()
	local _, handle = bootWith({ provider = false })
	local sse = handle.env.require("net/sse")

	-- 1. Streamed chunks with delta.thinking then delta.content
	local chunk1 = "data: " .. json.encode({ choices = { { index = 0, delta = { role = "assistant", thinking = "thinking via delta.thinking" } } } })
	local chunk2 = "data: " .. json.encode({ choices = { { index = 0, delta = { content = "result prose" } } } })
	local chunk3 = "data: [DONE]"
	local parsed1 = sse.parse(chunk1 .. "\n\n" .. chunk2 .. "\n\n" .. chunk3 .. "\n\n")
	check("delta.thinking extracted", parsed1.reasoning == "thinking via delta.thinking")
	check("content extracted", parsed1.content == "result prose")

	-- 2. Non-streamed response with content blocks containing thinking
	local parsed2 = sse.fromResponse({
		choices = {
			{
				index = 0,
				message = {
					role = "assistant",
					content = {
						{ type = "thinking", thinking = "thought block text" },
						{ type = "text", text = "actual answer" },
					},
				},
			},
		},
	})
	check("content block thinking extracted", parsed2.reasoning == "thought block text")
	check("content block text extracted", parsed2.content == "actual answer")
end)

print(string.format("reasoning replay: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
