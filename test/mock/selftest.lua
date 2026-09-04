-- Self-test for the offline mocks. Run: luajit test/mock/selftest.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path

local json = require("json")
local scheduler = require("scheduler")

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		print(string.format("FAIL %s\n       got  %s\n       want %s", label, tostring(got), tostring(want)))
	else
		print("ok   " .. label .. "  -> " .. tostring(got))
	end
end

check("empty table encodes as array", json.encode({}), "[]")
check("array", json.encode({ 1, 2, 3 }), "[1,2,3]")
check("object keys sorted", json.encode({ name = "x", n = 2, ok = true }), '{"n":2,"name":"x","ok":true}')
check("nested with empty list", json.encode({ tools = {}, n = 1 }), '{"n":1,"tools":[]}')
check("float", json.encode({ 0.5 }), "[0.5]")
check("escapes", json.encode({ 'a"b\\c\nd' }), '["a\\"b\\\\c\\nd"]')

local decoded = json.decode('{"a":1,"b":null,"c":[1,2,{"d":"e"}],"f":true,"g":"x\\u00e9"}')
check("decode number", decoded.a, 1)
check("decode null drops key", decoded.b, nil)
check("decode nested", decoded.c[3].d, "e")
check("decode bool", decoded.f, true)
check("decode \\u escape", #decoded.g, 3)
check("decode empty object", type(json.decode("{}")), "table")
check("roundtrip", json.encode(json.decode('{"x":[1,2],"y":"z"}')), '{"x":[1,2],"y":"z"}')
check("decode rejects trailing", select(1, pcall(json.decode, "{} x")), false)
check("encode rejects NaN", select(1, pcall(json.encode, { 0 / 0 })), false)

local sched = scheduler.new()
local log = {}
sched.spawn(function()
	log[#log + 1] = "A0"
	sched.wait(0.3)
	log[#log + 1] = "A300"
end)
sched.delay(0.1, function() log[#log + 1] = "B100" end)
sched.spawn(function()
	for i = 1, 3 do
		sched.wait(0.05)
		log[#log + 1] = "C" .. i
	end
end)
sched.advance(1)
-- Both B100 and C's second wake land on t=0.10; the tie breaks on queue order,
-- so the earlier-queued delay wins. Real Roblox leaves this undefined -- what
-- matters offline is that it is the same on every run.
check("inline-until-first-yield plus ordering", table.concat(log, " "), "A0 C1 B100 C2 C3 A300")
check("virtual clock advanced", sched.now, 1)
check("queue drained", sched.pending(), 0)
check("no spurious errors", #sched.errors, 0)

sched.spawn(function() error("boom") end)
check("thread error captured", #sched.errors, 1)
check("error text kept", sched.errors[1].message:match("boom") ~= nil, true)

local order = {}
sched.spawn(function()
	sched.defer(function() order[#order + 1] = "deferred" end)
	order[#order + 1] = "inline"
end)
sched.advance(0)
check("defer runs after the current thread", table.concat(order, " "), "inline deferred")

print(("-"):rep(60))
print(failures == 0 and "mock selftest: all checks passed" or ("mock selftest: " .. failures .. " failure(s)"))
os.exit(failures > 0 and 1 or 0)
