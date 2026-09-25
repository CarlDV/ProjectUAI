-- Context compaction: model-window budget, usage calibration, forced compaction.
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
	local env = { services = h.services, hs = h.services.HttpService, info = { folder = "UAI", version = "test" }, context = {} }
	local loaded = {}
	function env.require(id)
		if loaded[id] then return loaded[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb")); local source = file:read("*a"); file:close()
		local fn = assert(luau.load(source, id)); setfenv(fn, h.sandbox); loaded[id] = fn()(env); return loaded[id]
	end
	local config = env.require("runtime/config")
	local context = env.require("agent/context")
	return env, config, context
end

scenario("limitFor scales to the model window and honours the hard cap", function()
	local _, config, context = fixture()
	config.set("agent.contextFraction", 0.8)
	config.set("agent.forceContext", { smallmodel = 10000 })
	local ctx = context.new()
	local cap = math.max(config.get("agent.contextTokens", 24000), 1000)
	check("an unknown model falls back to the configured cap", ctx.limitFor("mystery") == cap)
	check("a known window uses the fraction", ctx.limitFor("smallmodel") == 8000)
	config.set("agent.contextTokens", 5000)
	check("the configured cap still bounds the window", ctx.limitFor("smallmodel") == 5000)
	config.set("agent.contextFraction", 0.5)
	config.set("agent.contextTokens", 1000000)
	check("the fraction is applied to the window", ctx.limitFor("smallmodel") == 5000)
end)

scenario("calibration folds the provider's real prompt count into pressure", function()
	local _, _, context = fixture()
	local ctx = context.new()
	ctx.pushUser(("a"):rep(400))
	local base = ctx.tokens()
	ctx.calibrate(base + 1500)
	check("overhead is the reported count minus the message estimate", ctx.overhead == 1500)
	check("pressure adds the overhead to the estimate", ctx.pressure() == base + 1500)
	ctx.calibrate(0)
	check("a nonpositive report is ignored", ctx.overhead == 1500)
	ctx.pushUser("more")
	check("pressure tracks new turns on top of the overhead", ctx.pressure() == ctx.tokens() + 1500)
end)

scenario("auto compaction fires against the window-derived budget", function()
	local _, config, context = fixture()
	config.set("agent.contextFraction", 0.8)
	config.set("agent.forceContext", { tiny = 4000 })
	local ctx = context.new()
	for index = 1, 12 do
		ctx.pushUser(("word "):rep(200))
		ctx.pushAssistant({ content = ("reply "):rep(200) })
	end
	local before = ctx.tokens()
	check("the conversation exceeds the derived budget", before > ctx.limitFor("tiny"))
	local note = ctx.compact(function() return "rolling summary" end, { model = "tiny" })
	check("a summary was produced", note == "rolling summary")
	check("the context came down", ctx.tokens() < before)
	check("it fits the window-derived budget", ctx.tokens() <= ctx.limitFor("tiny"))
	check("a note records the compaction", ctx.stats().compactions == 1)
end)

scenario("prepared requests include prompt and tool overhead before a provider reply", function()
	local env, _, context = fixture()
	local ctx, usage = context.new(), env.require("agent/usage")
	local record = { id = "first", model = "fixture" }
	ctx.pushUser("hello")
	local tools = { { type = "function", ["function"] = { name = "inspect", parameters = { type = "object" } } } }
	local wire = ctx.wire("System instructions")
	local request = ctx.observeRequest(wire, tools, record)
	local expected = usage.estimateMessages(wire) + usage.estimateText(env.require("runtime/util").encode(tools))
	check("first-request pressure includes both system and schemas", ctx.pressure(record) == expected)
	local parts = ctx.breakdown(record)
	check("breakdown categories sum to pressure", parts.system + parts.messages + parts.summary == expected and parts.estimatedPrompt and not parts.calibrated)
	ctx.pushAssistant({ content = "reply added after dispatch" })
	ctx.calibrate(request.history + request.estimate + 300, request)
	check("late usage is calibrated against the sent history", ctx.overhead == request.estimate + 300)
	local nextRequest = ctx.observeRequest(ctx.wire("Longer system instructions"), tools, record)
	check("changed prompts preserve only the matching provider correction", ctx.overhead == nextRequest.estimate + 300 and ctx.calibrated)
	local changedEndpoint = { id = record.id, model = record.model, baseUrl = "https://changed.fixture.test" }
	check("changing a provider endpoint invalidates measured overhead", not ctx.breakdown(changedEndpoint).calibrated and ctx.breakdown(changedEndpoint).system == nextRequest.estimate)
	local other = { id = "other", model = record.model }
	check("switching providers does not reuse the old provider's measurement", ctx.breakdown(other).system == nextRequest.estimate and not ctx.breakdown(other).calibrated)
	ctx.observeRequest(ctx.wire("Longer system instructions"), {}, other)
	check("removed tools change the prepared overhead", ctx.overhead < nextRequest.estimate and not ctx.calibrated)
	ctx.clear()
	check("clear discards prepared and measured prompt metadata", ctx.pressure() == 0 and not ctx.breakdown().estimatedPrompt)
end)

scenario("invalid provider counts and model limits cannot poison the breakdown", function()
	local env, config, context = fixture()
	local ctx = context.new(); ctx.pushUser("hello"); ctx.calibrate(100)
	for _, invalid in ipairs({ math.huge, -math.huge, 0 / 0, -1, 0, "bad" }) do ctx.calibrate(invalid) end
	check("invalid usage cannot replace a finite measurement", ctx.pressure() == 100)
	for _, invalid in ipairs({ math.huge, -1, 0, 0 / 0, "bad" }) do
		config.set("agent.forceContext", { fixture = invalid })
		check("invalid context overrides stay unknown", env.require("provider/traits").contextWindow("fixture") == nil)
	end
end)

scenario("a conversation under budget is left alone unless forced", function()
	local _, config, context = fixture()
	config.set("agent.forceContext", { tiny = 4000 })
	local ctx = context.new()
	ctx.pushUser("hello")
	ctx.pushAssistant({ content = "hi" })
	check("nothing compacts under budget", ctx.compact(function() return "x" end, { model = "tiny" }) == nil)
	check("forcing a single turn still has nothing older to fold", ctx.compact(function() return "x" end, { model = "tiny", force = true }) == nil)
end)

scenario("forced compaction folds older turns and keeps the latest", function()
	local _, _, context = fixture()
	local ctx = context.new()
	for index = 1, 5 do
		ctx.pushUser("question " .. index)
		ctx.pushAssistant({ content = "answer " .. index })
	end
	local seen
	local note = ctx.compact(function(transcript) seen = transcript; return "did 1 through 3" end, { force = true, keepBlocks = 2 })
	check("a summary was produced", note == "did 1 through 3" and ctx.summary == "did 1 through 3")
	check("only the last two turns remain", ctx.stats().turns == 2)
	check("the summariser saw the dropped turns", has(seen, "question 1") and has(seen, "question 3"))
	check("the newest turn was kept", ctx.messages[#ctx.messages].content == "answer 5")
end)

scenario("context refusals name the window rather than the requested tokens", function()
	local env, config = fixture()
	local openai = env.require("provider/openai")
	local examples = {
		{ "This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens (5000 in the completion)", 128000 },
		{ "prompt is too long: 250000 tokens > 200000 maximum", 200000 },
		{ "Maximum context length of 128,000 tokens exceeded by 140,000 prompt tokens", 128000 },
		{ "Maximum context window is 1,048,576 tokens", 1048576 },
		{ "Too many tokens: at most 32000 tokens are allowed", 32000 },
		{ "max_tokens is too large: 200000" },
		{ "This model's maximum context length is 4000 tokens" },
		{ "context_length_exceeded: requested 130000 tokens with max_tokens 16000" },
		{ "context_length_exceeded: max_tokens 16000 is the maximum output budget" },
	}
	for _, example in ipairs(examples) do
		check(example[1], openai.contextWindowFromMessage(example[1]) == example[2])
	end
	check("missing text is safe", openai.contextWindowFromMessage(nil) == nil)
	config.set("agent.forceContext", { relayed = 1000000, other = 64000 })
	openai.rememberContextWindow({ model = "Relayed", label = "Relay" }, 128000)
	check("learning lowers a manual claim using the lowercase id", config.get("agent.forceContext").relayed == 128000)
	openai.rememberContextWindow({ model = "Relayed" }, 200000)
	check("a refusal cannot raise a known limit", config.get("agent.forceContext").relayed == 128000)
	for _, invalid in ipairs({ -1, 0, 7999, math.huge, 0 / 0, "not a window" }) do
		openai.rememberContextWindow({ model = "Relayed" }, invalid)
	end
	check("invalid windows are ignored", config.get("agent.forceContext").relayed == 128000)
	check("other models are unaffected", config.get("agent.forceContext").other == 64000)
end)

scenario("a learned window makes compaction fire for an unknown model", function()
	local env, config, context = fixture()
	config.set("agent.contextTokens", 1000000)
	local ctx = context.new()
	for index = 1, 24 do
		ctx.pushUser(("word "):rep(400))
		ctx.pushAssistant({ content = ("reply "):rep(400) })
	end
	check("the unknown model initially fits the manual cap", ctx.compact(function() return "unused" end, { model = "relayed" }) == nil)
	local before = #ctx.wire("system")
	local refusal = { status = 400, body = env.require("runtime/util").encode({ error = {
		message = "maximum context length is 12000 tokens; received 30000 tokens",
	} }) }
	check("the response teaches the real limit", env.require("provider/openai").learnContextWindow({ model = "relayed" }, refusal) == 12000)
	ctx.compact(function() return "summary" end, { model = "relayed" })
	check("the wire form shrank after compaction", #ctx.wire("system") < before)
	check("it now fits the learned window", ctx.pressure() <= ctx.limitFor("relayed"))
end)

scenario("summaries accumulate across repeated compactions", function()
	local _, _, context = fixture()
	local ctx, calls = context.new(), 0
	local function summarise(transcript)
		calls = calls + 1
		if calls == 2 then
			check("the next summary sees the prior facts", has(transcript, "Summary so far:\nKeep the lighthouse"))
			check("the next summary also sees newer turns", has(transcript, "Newer messages to fold") and has(transcript, "new question"))
		end
		return calls == 1 and "Keep the lighthouse" or "Keep the lighthouse and add a dock"
	end
	for index = 1, 8 do ctx.pushUser("old question"); ctx.pushAssistant({ content = "old answer" }) end
	ctx.compact(summarise, { force = true })
	for index = 1, 8 do ctx.pushUser("new question"); ctx.pushAssistant({ content = "new answer" }) end
	ctx.compact(summarise, { force = true })
	check("the summariser ran twice", calls == 2 and ctx.compactions == 2)
	check("the wire uses the updated summary", has(ctx.wire("system")[2].content, "Keep the lighthouse and add a dock"))
end)

scenario("failed or disabled summaries preserve previous facts", function()
	for _, summarise in ipairs({ function() error("offline") end, function() return "  " end, function() return nil end, false }) do
		local _, _, context = fixture()
		local ctx = context.new()
		ctx.summary = "Do not delete the lighthouse"
		for index = 1, 6 do ctx.pushUser("question"); ctx.pushAssistant({ content = "answer" }) end
		local result = ctx.compact(summarise, { force = true })
		check("old facts survive", has(result, "Do not delete the lighthouse"))
		check("the missing newer summary is disclosed", has(result, "8") and has(result, "dropped"))
		check("fallback compaction is counted", ctx.compactions == 1)
	end
end)

print(string.format("context compaction: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
