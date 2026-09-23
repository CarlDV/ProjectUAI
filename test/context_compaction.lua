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
	local env = { services = h.services, info = { folder = "UAI", version = "test" }, context = {} }
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

print(string.format("context compaction: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
