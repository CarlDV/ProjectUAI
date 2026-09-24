-- Synthetic source-module fixture. Never reads or writes an executor workspace.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, luau = require("env"), require("luau")
local M = {}
function M.new(options)
	local h = envMock.new(options)
	local loaded, loading = {}, {}
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer,
		uis = h.services.UserInputService, tween = h.services.TweenService, run = h.services.RunService,
		guisvc = h.services.GuiService, players = h.services.Players,
		info = { folder = "UAI", version = "1.7.0", name = "UAI", build = "workspace-fixture" }, context = {}, loadedModules = loaded }
	function env.require(id)
		if loaded[id] ~= nil then return loaded[id] end
		assert(not loading[id], "circular module: " .. id); loading[id] = true
		local file = assert(io.open("src/" .. id .. ".lua", "rb")); local text = file:read("*a"); file:close()
		local chunk = assert(luau.load(text, id)); setfenv(chunk, h.sandbox)
		loaded[id] = chunk()(env); loading[id] = nil; return loaded[id]
	end
	local f = { h = h, env = env, loaded = loaded }
	function f.run(fn, seconds)
		local done, result
		h.sched.spawn(function() result = { fn() }; done = true end)
		h.sched.advance(seconds or 0.2)
		if not done then
			local last = h.sched.errors[#h.sched.errors]
			error(last and last.traceback or "fixture operation did not finish", 2)
		end
		return unpack(result)
	end
	function f.tools(groups)
		local registry = env.require("agent/registry"); registry.loaded = true
		for _, group in ipairs(groups) do for _, tool in ipairs(env.require("tools/" .. group)) do tool.group = group; registry.register(tool) end end
		env.require("runtime/config").set("permissions.mode", "full")
		f.registry = registry; return registry
	end
	function f.dispatch(name, args, ctx, seconds)
		ctx = ctx or { env = env, session = {}, aborted = function() return false end }
		return f.run(function() return f.registry.dispatch({ id = "fixture-call", name = name, arguments = h.json.encode(args or {}) }, ctx) end, seconds)
	end
	function f.healthy()
		local last = h.sched.errors[#h.sched.errors]
		assert(not last, last and last.traceback)
		assert(#h.instanceState.typeErrors == 0, table.concat(h.instanceState.typeErrors, "\n"))
		for _, line in ipairs(h.console.warnings) do assert(not line:find("handler failed", 1, true), line) end
	end
	function f.close() if loaded["runtime/dispose"] then loaded["runtime/dispose"].drain() end end
	return f
end
function M.suite(label)
	local passed, failed, assertions = 0, 0, 0
	local suite = {}
	function suite.check(name, condition) assert(condition, name); assertions = assertions + 1 end
	function suite.case(name, fn)
		local ok, why = xpcall(fn, debug.traceback)
		if ok then passed = passed + 1; print("ok " .. name)
		else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(why)) end
	end
	function suite.finish()
		print(string.format("%s: %d cases, %d assertions, %d failures", label, passed + failed, assertions, failed))
		os.exit(failed == 0 and 0 or 1)
	end
	return suite
end
return M
