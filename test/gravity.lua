-- Gravity adapter contracts with synthetic state; no live physics or HTTP.
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
	h.sandbox.math = {}; for key, value in pairs(math) do h.sandbox.math[key] = value end
	h.sandbox.math.clamp = function(value, low, high) return math.max(low, math.min(high, value)) end
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer, players = h.services.Players,
		info = { folder = "UAI", version = "test" }, context = {} }
	local loaded = {}
	function env.require(id)
		if loaded[id] then return loaded[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb")); local source = file:read("*a"); file:close()
		local fn = assert(luau.load(source, id)); setfenv(fn, h.sandbox); loaded[id] = fn()(env); return loaded[id]
	end
	local calls = { saves = 0, refresh = 0, visuals = 0, buttons = 0, cleanup = 0 }
	local gravity = env.require("runtime/gravity")
	local context = { x1 = { k6 = "Preset", Targets = {}, k10 = 20 }, x2 = { Preset = { speed = 1, enabled = false }, Other = {} },
		x6 = { o = false, n = 0, pre = {} }, x4 = {}, x5 = {}, x9 = { c1 = 1, c2 = 1 }, local_shapes = {}, loaded_shapes = {} }
	context.x1.S = context.x2
	for key, spec in pairs(gravity.fields) do
		if spec.type == "boolean" then context.x1[key] = false
		elseif spec.type == "array" or spec.type == "object" then context.x1[key] = {}
		else context.x1[key] = spec.minimum or (spec.enum and spec.enum[1]) or "" end
	end
	context.x1.k3 = h.sandbox.Color3.fromRGB(255, 105, 180)
	context.x1.MaxSpeed, context.x1.Damping = 500, 0.5
	context.save_settings = function() calls.saves = calls.saves + 1 end
	context.x5.up = function() calls.refresh = calls.refresh + 1 end
	context.x4.f4 = function(pos) calls.position = pos; context.x6.o = true end
	context.x4.f5 = function() calls.stops = (calls.stops or 0) + 1; context.x6.o = false end
	context.x4.apply_disabled = function(value) calls.disabled = value; context.x1.Disabled = value end
	context.x4.refresh_core_visual = function() calls.visuals = calls.visuals + 1 end
	context.x4.enforce_part_cap = function() calls.cap = true end
	context.x4.recheck_rules = function() calls.rules = true end
	context.x4.preview_clear = function() calls.previewCleared = true end
	context.x4.switch_shape = function(name) calls.switched = name; context.x1.k6 = name; return true end
	local preset = { f2 = function() end, Controls = {
		{ Type = "Slider", Name = "Orbit Speed", Key = "speed", Min = 0, Max = 100, Div = 10, Default = 1, IntOnly = true },
		{ Type = "Toggle", Name = "Enabled", Key = "enabled", Default = false },
		{ Type = "Button", Name = "Pulse", Key = "pulse", Callback = function() calls.buttons = calls.buttons + 1 end },
	} }
	context.loaded_shapes.Preset, context.loaded_shapes.Other = preset, { f2 = function() end, Controls = {} }
	context.get_shape = function(name) return context.loaded_shapes[name] end
	context.plugin_controls = { activate = function(control, c, x6, x1) calls.buttonArguments = { c, x6, x1 }; return pcall(control.Callback, c, x6, x1) end }
	h.sandbox._GRAVITY_CONTEXT = context
	local registry = env.require("agent/registry"); registry.loaded = true
	for _, group in ipairs({ "gravity", "fs" }) do
		for _, tool in ipairs(env.require("tools/" .. group)) do tool.group = group; registry.register(tool) end
	end
	env.require("runtime/config").set("permissions.mode", "full")
	local ctx = { session = {}, aborted = function() return false end }
	local function run(name, args, seconds)
		local result
		h.sched.spawn(function() result = registry.dispatch({ id = "gravity-test", name = name, arguments = h.json.encode(args or {}) }, ctx) end)
		h.sched.advance(seconds or 0.2); assert(result, "tool did not finish: " .. name); return result
	end
	return h, env, context, calls, run, ctx, registry
end

scenario("connection follows startup, replacement and unload", function()
	local h, env, context, _, run, _, registry = fixture()
	h.sandbox._GRAVITY_CONTEXT = nil
	check("absence is reported", run("gravity_status").data.available == false)
	check("native actions require a live connection", not run("gravity_control", { action = "stop" }).ok)
	env.context.gravity = context
	check("explicit host context connects", env.require("runtime/gravity").current() == context)
	local replacement = { x1 = {}, x2 = {}, x4 = {}, x6 = {}, get_shape = function() end }
	h.sandbox._GRAVITY_CONTEXT = replacement
	check("ambient replacement wins over an old host context", env.require("runtime/gravity").current() == replacement)
	context.x6.torn_down, replacement.x6.torn_down = true, true
	check("unloaded contexts cannot be reused", env.require("runtime/gravity").current() == nil)
	check("status stays available without Gravity", registry.get("gravity_status") ~= nil)
end)

scenario("engine changes validate together and call native lifecycle handlers", function()
	local _, env, context, calls, run = fixture()
	check("invalid settings are rejected", not run("gravity_configure", { values = { MaxSpeed = 700, Damping = -1 } }).ok)
	check("valid siblings do not apply on failure", context.x1.MaxSpeed == 500 and calls.saves == 0)
	check("setting types are validated", not run("gravity_configure", { values = { MaxSpeed = true } }).ok)
	check("unknown settings cannot be injected", not run("gravity_configure", { values = { internal = true } }).ok)
	local result = run("gravity_configure", { values = { MaxSpeed = 750, Disabled = true, Paused = true, PreviewEnabled = false, TargetParts = 20, RuleMinSize = 2 } })
	check("native setting change succeeds", result.ok and context.x1.MaxSpeed == 750)
	check("physics handlers ran", calls.disabled == true and calls.visuals == 1 and calls.cap and calls.rules and calls.previewCleared)
	check("one save and refresh", calls.saves == 1 and calls.refresh == 1)
	check("start uses the real handler", run("gravity_control", { action = "start", position = { x = 5, y = 6, z = 7 } }).ok and context.x6.o and calls.position.Y == 6)
	check("stop releases through the real handler", run("gravity_control", { action = "stop" }).ok and calls.stops == 1 and not context.x6.o)
	check("session-only settings do not save", run("gravity_configure", { values = { TimeScale = -1 }, persist = false }).ok and calls.saves == 1)
	check("readonly mode omits writes", (function() env.require("runtime/config").set("permissions.mode", "readonly"); return not run("gravity_control", { action = "start" }).ok end)())
end)

scenario("shape values use real keys, slider units and native buttons", function()
	local _, _, context, calls, run = fixture()
	local info = run("gravity_shapes", { name = "preset", limit = 2 })
	check("actual slider units and extended speed range", info.ok and info.data.controls[1].maximum == 40 and info.data.controls[1].displayDivisor == 10)
	check("control descriptions paginate", #info.data.controls == 2 and info.data.nextOffset == 3)
	local tail = run("gravity_shapes", { name = "Preset", offset = 3 })
	check("buttons carry no saved value", tail.data.controls[1].kind == "Button" and tail.data.controls[1].value == nil)
	check("stored fractional values round in display units", run("gravity_shape", { action = "configure", values = { speed = 1.26, enabled = true } }).ok and context.x2.Preset.speed == 1.3)
	local before = context.x2.Preset.speed
	check("out-of-range batch is refused", not run("gravity_shape", { action = "configure", values = { speed = 1000, enabled = false } }).ok)
	check("shape controls remain unchanged on failure", context.x2.Preset.speed == before and context.x2.Preset.enabled)
	check("button is invoked once", run("gravity_shape", { action = "button", button = "pulse" }).ok and calls.buttons == 1)
	check("button uses the current native arguments", calls.buttonArguments[1] == context.x2.Preset and calls.buttonArguments[2] == context.x6 and context.x2.Preset.pulse == nil)
	check("shape selection goes through the switch handler", run("gravity_shape", { action = "select", shape = "Other" }).ok and calls.switched == "Other")
	check("inactive button cannot fire", not run("gravity_shape", { action = "button", shape = "Preset", button = "pulse" }).ok and calls.buttons == 1)
end)

scenario("player targeting rejects ambiguity and retains the native target table", function()
	local h, _, context, _, run = fixture()
	local a, b = h.makePlayer("Alice", 20), h.makePlayer("Alicia", 21)
	h.players[#h.players + 1], h.players[#h.players + 2] = a, b
	local targets = context.x1.Targets
	check("ambiguous prefix is rejected", not run("gravity_target", { mode = "add", player = "Ali" }).ok and #targets == 0)
	check("exact ID adds a target", run("gravity_target", { mode = "add", player = "20" }).ok and targets[1] == a and context.x1.TgtActive)
	check("repeated target is deduplicated", run("gravity_target", { mode = "add", player = "Alice" }).ok and #targets == 1)
	check("self targeting clears other modes", run("gravity_target", { mode = "self" }).ok and context.x1.AnchorSelf and not context.x1.PI_All and #targets == 0)
	check("target table identity is preserved", context.x1.Targets == targets)
end)

scenario("native settings apply typed values, report capabilities and restore failed changes", function()
	local _, _, context, calls, run = fixture()
	context.controls = { fps_cap = true, apply_settings = function(values) calls.effects = values end,
		refresh = function() calls.nativeRefresh = (calls.nativeRefresh or 0) + 1 end }
	local tags = context.x1.k5
	local info = run("gravity_status")
	check("color is JSON RGB and native capabilities are visible", info.ok and info.data.settings.k3.g == 105 and info.data.capabilities.fpsCap)
	local changed = run("gravity_configure", { values = { k3 = { r = 10, g = 20, b = 30 }, k5 = { "NoAttract", "Keep" },
		FPSCap = 144, PreserveCollisions = true, UIScale = 1.5, Perf_HideParticles = true, PartCtlPull = 100, PartCtlGridSnap = 4 } })
	check("typed native setting batch succeeds", changed.ok and context.x1.FPSCap == 144 and context.x1.k3.B == 30 / 255)
	check("tags retain native table identity", context.x1.k5 == tags and tags[2] == "Keep")
	check("native effects and full panel refresh are used", calls.effects.PreserveCollisions and calls.effects.Perf_HideParticles and calls.nativeRefresh == 1)
	check("invalid RGB channels block sibling changes", not run("gravity_configure", { values = { k3 = { r = 256, g = 0, b = 0 }, UIScale = 2 } }).ok and context.x1.UIScale == 1.5)
	check("invalid tags are refused before mutation", not run("gravity_configure", { values = { k5 = { "" }, UIScale = 2 } }).ok and #tags == 2)
	context.controls.fps_cap = false
	check("unsupported FPS control does not change siblings", not run("gravity_configure", { values = { FPSCap = 0, UIScale = 2 } }).ok and context.x1.UIScale == 1.5)
	local attempts = 0
	context.controls.apply_settings = function() attempts = attempts + 1; if attempts == 1 then error("effect failed") end end
	local failedChange = run("gravity_configure", { values = { k3 = { r = 0, g = 0, b = 0 }, k5 = { "New" }, UIScale = 2 } })
	check("effect failure restores settings", not failedChange.ok and context.x1.UIScale == 1.5 and context.x1.k3.B == 30 / 255)
	check("rollback restores tag contents without replacing the table", context.x1.k5 == tags and tags[2] == "Keep" and attempts == 2)
	context.controls.reset = function(persist) calls.reset = persist; context.x1.UIScale = 1 end
	check("reset delegates to the native complete reset", run("gravity_control", { action = "reset_settings", persist = false }).ok and calls.reset == false and context.x1.UIScale == 1)
	check("Slingshot launch requires the correct mode", not run("gravity_control", { action = "launch" }).ok)
	context.x1.k6, context.x1.SlingshotManual = "Slingshot", true
	check("manual launch is idempotent", run("gravity_control", { action = "launch" }).ok and run("gravity_control", { action = "launch" }).ok and context.x1.IsLaunching)
	check("manual charge resets the launch state", run("gravity_control", { action = "charge" }).ok and not context.x1.IsLaunching)
end)

scenario("native keybindings and favorites validate before mutating", function()
	local _, _, context, calls, run = fixture()
	context.x1.Keybinds = { Recenter = "E", Reset = "Q", Pause = "P", Disable = "L", Shapes = {} }
	local kb, shapeKeys = context.x1.Keybinds, context.x1.Keybinds.Shapes
	context.x8 = {
		core_actions = { { id = "Recenter" }, { id = "Reset" }, { id = "Pause" }, { id = "Disable" } },
		key_from_name = function(name) return ({ E = true, F5 = true, F6 = true })[name] end,
		find_conflict = function(key, exclude)
			for action, bound in pairs(kb) do if action ~= exclude and bound == key and key ~= "" then return action end end
			for shape, bound in pairs(shapeKeys) do if "shape:" .. shape ~= exclude and bound == key and key ~= "" then return shape end end
		end,
		rebind_all = function() calls.rebind = (calls.rebind or 0) + 1 end,
	}
	check("core hotkey rebinding works", run("gravity_keybind", { action = "Recenter", key = "F5" }).ok and kb.Recenter == "F5" and calls.rebind == 1)
	check("conflicts are refused without a rebind", not run("gravity_keybind", { shape = "Preset", key = "F5" }).ok and calls.rebind == 1 and next(shapeKeys) == nil)
	check("invalid key is rejected", not run("gravity_keybind", { action = "Pause", key = "InvalidKey" }).ok and kb.Pause == "P")
	check("ambiguous binding target is rejected", not run("gravity_keybind", { action = "Pause", shape = "Preset", key = "F6" }).ok)
	check("shape hotkey uses canonical shape name", run("gravity_keybind", { shape = "preset", key = "F6", persist = false }).ok and shapeKeys.Preset == "F6")
	check("an empty key unbinds without replacing tables", run("gravity_keybind", { shape = "Preset", key = "" }).ok and shapeKeys.Preset == "" and context.x1.Keybinds == kb and kb.Shapes == shapeKeys)
	context.favorites = {}
	local favorites = context.favorites
	context.save_favs = function() calls.favoritesSaved = (calls.favoritesSaved or 0) + 1 end
	context.x6.populate_modes = function() calls.modes = (calls.modes or 0) + 1 end
	check("unknown favorite blocks the whole batch", not run("gravity_favorite", { action = "add", shapes = { "Preset", "Missing" } }).ok and next(favorites) == nil)
	check("native favorites save and refresh", run("gravity_favorite", { action = "add", shapes = { "preset", "Other" } }).ok and favorites.Preset and calls.favoritesSaved == 1 and calls.modes == 1)
	check("shape catalog reports favorites", run("gravity_shapes", { name = "Preset" }).data.favorite == true)
	check("favorite removal is session only when requested", run("gravity_favorite", { action = "remove", shapes = { "Preset" }, persist = false }).ok and not favorites.Preset and calls.favoritesSaved == 1)
	check("clear preserves the native favorites table", run("gravity_favorite", { action = "clear" }).ok and next(favorites) == nil and context.favorites == favorites)
end)

local function partFixture(count)
	local h, env, context, calls, run, ctx = fixture()
	local x6 = context.x6
	x6.a, x6.pc_selected, x6.active_array = {}, {}, {}
	x6.pc_api_version = 1
	context.session_id = "fixture-session"
	local parts = {}
	for index = 1, count do
		local part = h.sandbox.Instance.new("Part", h.services.Workspace)
		part.Name, part.Position = "Duplicate.Name", h.sandbox.Vector3.new(index * 10, 5, 0)
		x6.a[part] = { id = index }
		parts[index] = part
	end
	x6.pc_clear = function() for part in pairs(x6.pc_selected) do x6.pc_selected[part] = nil end; calls.clears = (calls.clears or 0) + 1 end
	x6.pc_select = function(part) x6.pc_selected[part] = true end
	x6.pc_deselect = function(part) x6.pc_selected[part] = nil end
	x6.pc_assign = function(mode, opts)
		if mode == "shape" then if not context.get_shape(opts.shape) then return 0 end end
		if opts and opts.guard and not opts.guard() then return 0 end
		calls.assignments = (calls.assignments or 0) + 1
		local affected = 0
		for part in pairs(x6.pc_selected) do
			local d = x6.a[part]
			if d then
				d.pc_mode = mode
				if mode then d.pc_target = (opts and opts.target) or d.pc_target or part.Position
				else d.pc_target, d.pc_phys, d.pc_ride, d.pc_shape = nil, nil, nil, nil end
				if mode == "shape" then d.pc_shape = opts.shape end
				affected = affected + 1
			end
		end
		return affected
	end
	x6.pc_set_ride = function(on) local n = 0; for part in pairs(x6.pc_selected) do x6.a[part].pc_ride = on; n = n + 1 end; return n end
	x6.pc_set_phys = function(phys) local n = 0; for part in pairs(x6.pc_selected) do x6.a[part].pc_phys = phys; n = n + 1 end; return n end
	x6.pc_release_all = function()
		local n = 0
		for _, d in pairs(x6.a) do
			if d.pc_mode or d.pc_ride or d.pc_phys then n = n + 1; d.pc_mode, d.pc_phys, d.pc_ride, d.pc_target, d.pc_shape = nil, nil, nil, nil, nil end
		end
		return n
	end
	return context, calls, run, ctx, parts, h, env
end

scenario("parts use stable IDs, bounded pages and native selection/override actions", function()
	local context, calls, run, _, parts = partFixture(3)
	local x6 = context.x6
	local list = run("gravity_parts", { limit = 2 })
	check("authoritative held map is paged even before dense array catches up", list.ok and list.data.total == 3 and #list.data.parts == 2 and list.data.nextOffset == 3)
	local first, second = list.data.parts[1].id, list.data.parts[2].id
	check("duplicate names have distinct stable IDs", first ~= second and first == run("gravity_parts", { limit = 1 }).data.parts[1].id)
	check("invalid ID prevents any selection mutation", not run("gravity_part_control", { action = "select", ids = { first, "stale" } }).ok and next(x6.pc_selected) == nil)
	check("select operates through the native helpers", run("gravity_part_control", { action = "select", ids = { first, second } }).ok and x6.pc_selected[parts[1]] and x6.pc_selected[parts[2]])
	check("pin uses native assignment", run("gravity_part_control", { action = "assign", mode = "pin" }).ok and calls.assignments == 1 and x6.a[parts[1]].pc_mode == "pin")
	check("bad physics batch does not change overrides", not run("gravity_part_control", { action = "physics", physics = { k10 = 50, Damping = -1 } }).ok and x6.a[parts[1]].pc_phys == nil)
	check("physics is applied through the native setter", run("gravity_part_control", { action = "physics", physics = { k10 = 50 } }).ok and x6.a[parts[1]].pc_phys.k10 == 50)
	check("an empty physics object restores inheritance", run("gravity_part_control", { action = "physics", physics = {} }).ok and x6.a[parts[1]].pc_phys == nil)
	check("relative movement preserves spacing", run("gravity_part_control", { action = "move", offset = { x = 5, y = 10, z = 2 } }).ok and x6.a[parts[1]].pc_target.X == 15 and x6.a[parts[2]].pc_target.X == 25)
	check("absolute movement places the group center", run("gravity_part_control", { action = "move", position = { x = 100, y = 20, z = 0 } }).ok and x6.a[parts[1]].pc_target.X == 95 and x6.a[parts[2]].pc_target.X == 105)
	check("ride leaves manual targets intact", run("gravity_part_control", { action = "ride", ride = true }).ok and x6.a[parts[1]].pc_mode == "manual" and x6.a[parts[1]].pc_ride)
	check("clear only deselects", run("gravity_part_control", { action = "clear" }).ok and next(x6.pc_selected) == nil and x6.a[parts[1]].pc_mode == "manual")
	check("selected-only list is empty after clear", run("gravity_parts", { filter = "selected" }).data.total == 0)
	check("overridden list finds unselected parts", run("gravity_parts", { filter = "overridden" }).data.total == 2)
	check("release all reaches unselected overrides", run("gravity_part_control", { action = "release_all" }).data.affected == 2 and x6.a[parts[2]].pc_target == nil)
	context.session_id = "replacement-session"
	check("IDs cannot cross session boundaries", not run("gravity_part_control", { action = "select", ids = { first } }).ok and next(x6.pc_selected) == nil)
end)

scenario("selection caps and shape-load cancellation cannot mutate a different selection", function()
	local context, _, run, ctx, parts = partFixture(515)
	local all = run("gravity_part_control", { action = "select_all" })
	check("bulk selection reports the native cap", all.ok and all.data.selected == 512 and all.data.capped)
	local last = run("gravity_parts", { offset = 515, limit = 1 }).data.parts[1].id
	check("explicit addition above cap is atomic", not run("gravity_part_control", { action = "add", ids = { last } }).ok and not context.x6.pc_selected[parts[515]])
	local inverted = run("gravity_part_control", { action = "invert" })
	check("invert reaches parts beyond the first page", inverted.ok and inverted.data.selected == 3 and context.x6.pc_selected[parts[515]])
	local original = context.get_shape
	context.get_shape = function(name) context.x6.pc_clear(); context.x6.pc_select(parts[1]); return original(name) end
	local changed = run("gravity_part_control", { action = "assign", mode = "shape", shape = "Preset" })
	check("selection change during loading prevents assignment", not changed.ok and context.x6.a[parts[1]].pc_mode == nil and context.x6.a[parts[515]].pc_mode == nil)
	ctx.aborted = function() return true end
	check("cancelled changes never clear the selection", not run("gravity_part_control", { action = "clear" }).ok and context.x6.pc_selected[parts[1]])
end)

scenario("plugins save exact source by path and load setup once", function()
	local h, env, context, _, run = fixture()
	local template = env.require("runtime/gravity_docs").template
	local source = "-- LONG_PLUGIN_SOURCE " .. ("x"):rep(9000) .. "\n_G.gravitySetup = (_G.gravitySetup or 0) + 1\n" .. template
	local entry = assert(env.require("runtime/attachments").save(source, "bloom.lua"))
	local result = run("gravity_plugin_write", { plugin = "Orbit Bloom", path = entry.path })
	check("plugin saved and loaded", result.ok and result.data.loaded and h.files["GravityShapes/Orbit Bloom.lua"] == source)
	check("setup executes once", h.sandbox.gravitySetup == 1)
	check("source is not echoed in the tool result", not has(result.text, "LONG_PLUGIN_SOURCE") and #result.text < 1000)
	check("inactive shape is not automatically selected", context.x1.k6 == "Preset")
	check("control defaults exclude buttons", context.x2["Orbit Bloom"].radius == 40 and context.x2["Orbit Bloom"].restart == nil)
	check("actual cached module is registered", type(context.loaded_shapes["Orbit Bloom"].f2) == "function")
	check("module can be selected natively", run("gravity_shape", { action = "select", shape = "Orbit Bloom" }).ok)
	h.sched.advance(20)
	local mod = context.loaded_shapes["Orbit Bloom"]
	context.x2["Orbit Bloom"].bob = false
	local p = { Position = h.sandbox.Vector3.new(0, 0, 0) }
	local velocity, target = mod.f2(p, p.Position, { slot = 1 }, 0, context.x2["Orbit Bloom"], context.x1, context.x6, context.x9)
	check("live callbacks survive setup deadline", velocity.X == velocity.X and target.Y == 20)
	check("plugin buttons use returned closures", run("gravity_shape", { action = "button", button = "restart" }).ok)
	check("overwrite requires explicit intent", not run("gravity_plugin_write", { plugin = "Orbit Bloom", path = entry.path }).ok and h.sandbox.gravitySetup == 1)
	local read = run("gravity_plugin_read", { plugin = "Orbit Bloom", origin = "local", limit = 200 })
	check("real file is read in slices", read.ok and read.data.nextOffset and has(read.text, "LONG_PLUGIN_SOURCE"))
end)

scenario("plugin failures preserve the previous file and registered shape", function()
	local h, env, context, calls, run = fixture()
	local source = "return { f2 = function() end, Controls = {} }"
	h.files["GravityShapes/Custom.lua"] = source
	local previous = { f2 = function() end, Controls = {}, cleanup = function() calls.cleanup = calls.cleanup + 1 end }
	context.loaded_shapes.Custom, context.local_shapes.Custom, context.x2.Custom = previous, "GravityShapes/Custom.lua", {}
	for _, invalid in ipairs({ "not lua", "return {}", "return { f2 = function() end, Controls = {{Type='Button', Name='Bad'}} }" }) do
		check("invalid source fails", not run("gravity_plugin_write", { plugin = "Custom", source = invalid, overwrite = true }).ok)
		check("invalid source preserves previous state", h.files["GravityShapes/Custom.lua"] == source and context.loaded_shapes.Custom == previous and calls.cleanup == 0)
	end
	local written = run("gravity_plugin_write", { plugin = "Custom", source = source, overwrite = true })
	check("successful replacement calls cleanup once", written.ok and calls.cleanup == 1 and context.loaded_shapes.Custom ~= previous)
	check("path traversal is refused", not run("gravity_plugin_write", { plugin = "../bad", source = source, load = false }).ok)
	check("reserved file names are refused", not run("gravity_plugin_write", { plugin = "CON", source = source, load = false }).ok)
	local originalWrite, n = env.require("runtime/caps").fn.writefile, 0
	env.require("runtime/caps").fn.writefile = function(path, text) n = n + 1; return originalWrite(path, n == 1 and "corrupt" or text) end
	local active = context.loaded_shapes.Custom
	check("failed verification is reported", not run("gravity_plugin_write", { plugin = "Custom", source = source .. "\n", overwrite = true }).ok)
	check("failed write restores disk and does not register", h.files["GravityShapes/Custom.lua"] == source and context.loaded_shapes.Custom == active)
	env.require("runtime/caps").fn.writefile = function(path) return originalWrite(path, "corrupt") end
	local corrupt = run("gravity_plugin_write", { plugin = "Custom", source = source .. "\n", overwrite = true })
	check("failed restoration is never reported as restored", not corrupt.ok and has(corrupt.text, "inspect the file before retrying") and context.loaded_shapes.Custom == active)
end)

scenario("save-only authoring works offline and setup timeouts never register", function()
	local h, env, context, _, run = fixture()
	h.sandbox._GRAVITY_CONTEXT = nil
	local result = run("gravity_plugin_write", { plugin = "Offline", source = "_G.shouldNotRun=true; return {}", load = false })
	check("save-only writes a real file without setup", result.ok and not result.data.loaded and h.sandbox.shouldNotRun == nil)
	check("guide is available without a live runtime", run("gravity_plugin_read").ok)
	h.sandbox._GRAVITY_CONTEXT = context
	local timed = run("gravity_plugin_write", { plugin = "Runaway", source = "while true do end" }, 10.5)
	check("setup timeout is reported", not timed.ok and has(timed.text, "Timed out"))
	check("timed out setup never writes or registers", h.files["GravityShapes/Runaway.lua"] == nil and context.loaded_shapes.Runaway == nil)
end)

print(string.format("gravity: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
