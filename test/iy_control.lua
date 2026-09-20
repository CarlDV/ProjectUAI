-- Adapter regressions against IY's public editor/loader contracts. No network or
-- Roblox executor required: luajit test/iy_control.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, luau = require("env"), require("luau")
local passed, failed = 0, 0
local function check(label, condition) assert(condition, label); passed = passed + 1 end
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function scenario(name, fn)
	local ok, err = pcall(fn)
	if ok then print("  ok   " .. name) else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end

local function fixture()
	local h = envMock.new()
	local env = { hs = h.services.HttpService, services = h.services, plr = h.localPlayer,
		info = { folder = "UAI", version = "test" }, context = {} }
	local cache = {}
	function env.require(id)
		if cache[id] then return cache[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb"))
		local source = file:read("*a"); file:close()
		local chunk = assert(luau.load(source, id)); setfenv(chunk, h.sandbox)
		cache[id] = chunk()(env)
		return cache[id]
	end
	-- Native IY contracts from master/source (reviewed 2026-09-20): ordered
	-- {command, filters, delay} tuples, LoadData merging only known events, and
	-- LoadPlugin executing loadfile exactly once and suffixing colliding names.
	local native = assert(loadstring([=[
HttpService = game:GetService("HttpService")
Players = game:GetService("Players")
prefix, StayOpen, KeepInfYield, logsEnabled, jLogsEnabled, espTransparency = ";", false, true, false, false, 0.3
nosaves, binds, PluginsTable, toggleOn, dispatches, saveCalls, refreshCalls = false, {}, {}, {}, {}, 0, 0
cmds = { { NAME = "example", ALIAS = {}, FUNC = function() end }, { NAME = "speed", ALIAS = {}, FUNC = function() end } }
cmds[2].ALIAS = { "ws" }
cmds[3] = { NAME = "guiscale", ALIAS = {}, FUNC = function() end }
cmds[4] = { NAME = "chatlogswebhook", ALIAS = { "logswebhook" }, FUNC = function() end }
CMDs = { { NAME = "speed / ws [num]", DESC = "Set walk speed" }, { NAME = "example / ex", DESC = "Example command" } }
aliases, customAlias, WayPoints, AllWaypoints, PlaceId, guiScale = {}, {}, {}, {}, 123, 1
function getPlayer(selector, speaker)
	lastSelector, lastSpeaker = selector, speaker
	if selector == "all" then return { speaker.Name, "Guest", "Visitor" } end
	if selector == "me" then return { speaker.Name } end
	return {}
end
function getRoot(character) return character and character:FindFirstChild("HumanoidRootPart") end
function refreshaliases() refreshCalls = refreshCalls + 1 end
function refreshwaypoints() refreshCalls = refreshCalls + 1 end
local eventCommands = { OnExecute = {}, OnSpawn = {}, OnDied = {}, OnDamage = {}, OnKilled = {}, OnJoin = {}, OnLeave = {}, OnChatted = {}, CustomPluginEvent = {} }
eventEditor = {
	SaveData = function() return HttpService:JSONEncode(eventCommands) end,
	LoadData = function(source)
		for event, commands in pairs(HttpService:JSONDecode(source)) do
			if eventCommands[event] then eventCommands[event] = commands end
		end
	end,
	Refresh = function() refreshCalls = refreshCalls + 1 end,
	FireEvent = function(name, ...)
		local args = {...}
		for _, binding in ipairs(eventCommands[name]) do
			local filters, matches = binding[2], true
			if name ~= "OnExecute" then
				matches = filters[1] == 1 or (filters[1] == 0 and args[1] == Players.LocalPlayer.Name) or filters[1] == args[1]
			end
			if name == "OnChatted" and filters[2] ~= 0 then matches = matches and string.find(args[2]:lower(), filters[2]:lower()) end
			if name == "OnDamage" and filters[2] ~= 0 then matches = matches and args[2] <= filters[2] end
			if matches then task.spawn(function()
				wait(binding[3] or 0)
				local command = binding[1]
				for index, value in ipairs(args) do command = command:gsub("%$" .. index, tostring(value)) end
				execCmd(command)
			end) end
		end
	end,
}
function execCmd(command, speaker, history)
	dispatches[#dispatches + 1] = { command = command, speaker = speaker, history = history }
end
function updatesaves()
	saveCalls = saveCalls + 1
	writefile("IY_FE.iy", HttpService:JSONEncode({ prefix = prefix, binds = binds, aliases = aliases, WayPoints = AllWaypoints, eventBinds = eventEditor.SaveData(), untouched = "keep" }))
end
function refreshbinds() refreshCalls = refreshCalls + 1 end
function loadfile(name) return assert(loadstring(readfile(name))) end
function findCmd(name)
	for _, cmd in ipairs(cmds) do
		if cmd.NAME == name then return cmd end
		for _, alias in ipairs(cmd.ALIAS) do if alias == name then return cmd end end
	end
end
function deletePlugin(name)
	for index = #cmds, 1, -1 do if cmds[index].PLUGIN == name then table.remove(cmds, index) end end
	for index = #PluginsTable, 1, -1 do if PluginsTable[index] == name then table.remove(PluginsTable, index) end end
end
function addPlugin(name)
	for _, item in ipairs(PluginsTable) do if item == name then return end end
	table.insert(PluginsTable, name)
	local ok, plugin = pcall(function() return loadfile(name)() end)
	if not ok then deletePlugin(name); return end -- IY catches plugin setup errors.
	for base, command in pairs(plugin.Commands) do
		local name, suffix = base, 0
		while findCmd(name) do suffix = suffix + 1; name = base .. suffix end
		cmds[#cmds + 1] = { NAME = name, ALIAS = command.Aliases, FUNC = command.Function, PLUGIN = PluginsTable[#PluginsTable] }
	end
	updatesaves()
end
]=]))
	setfenv(native, h.sandbox); native()
	local caps = env.require("runtime/caps")
	-- The executor compiler accepts plugin globals; the repository's static
	-- authoring lint is intentionally only for UAI modules.
	caps.fn.loadstring = function(source, name)
		local fn, err = loadstring(source, name)
		if fn then setfenv(fn, h.sandbox) end
		return fn, err
	end
	local registry = env.require("agent/registry")
	registry.loaded = true
	for _, tool in ipairs(env.require("tools/iy")) do tool.group = "iy"; registry.register(tool) end
	env.require("runtime/config").set("permissions.mode", "full")
	local ctx = { session = {}, aborted = function() return false end }
	local function run(name, args)
		local result
		h.sched.spawn(function() result = registry.dispatch({ id = "iy-test", name = name, arguments = h.json.encode(args or {}) }, ctx) end)
		h.sched.advance(0.25)
		assert(result, "tool did not return: " .. name)
		return result
	end
	return h, env, registry, run, ctx
end

scenario("command discovery exposes live signatures and descriptions with an older-IY fallback", function()
	local h, env, registry, run = fixture()
	local result = run("iy_cmds", { filter = "WS" })
	check("alias search includes the signature and description", result.ok and has(result.text, "speed / ws [num]") and has(result.text, "Set walk speed"))
	h.sandbox.CMDs = { false, { NAME = "WS [amount]", DESC = "Alias-only description" }, { NAME = "ws [other]", DESC = "Duplicate loses" } }
	result = run("iy_cmds", { filter = "speed" })
	check("replacement tables and aliases resolve with first mapping winning", result.ok and has(result.text, "Alias-only description") and not has(result.text, "Duplicate loses"))
	h.sandbox.CMDs = { { NAME = "speed [on/off] / ws [num]", DESC = string.rep("d", 200) } }
	result = run("iy_cmds", { filter = "speed" })
	check("descriptions are bounded", result.ok and has(result.text, "speed [on/off] / ws [num]") and not has(result.text, string.rep("d", 121)))
	h.sandbox.CMDs = nil
	result = run("iy_cmds", { filter = "speed" })
	check("missing descriptions preserve the original output", result.ok and result.text == "1 of 4 commands matched\n1. speed (alias: ws)")
end)

scenario("player selectors use IY's live resolver and expose bounded readable results", function()
	local h, env, registry, run = fixture()
	local tool = registry.get("iy_players")
	check("selector resolution is read-only without host requirements", tool.risk == "read" and tool.needs == nil)
	for _, keyword in ipairs({ "all", "others", "me", "random", "#<n>", "%<team>", "allies", "enemies", "team", "nonteam", "friends", "nonfriends", "guests", "bacons", "age<n>", "nearest", "farthest", "group<id>", "alive", "dead", "rad<n>", "cursor", "npcs", "@name" }) do
		check("selector documented: " .. keyword, has(tool.description, keyword))
	end
	local all = run("iy_players", { selector = " all ", limit = 1 })
	check("all names remain in structured data", all.ok and all.data.count == 3 and all.data.names[2] == "Guest" and all.data.names[3] == "Visitor")
	check("text honours the limit", has(all.text, "2 more") and not has(all.text, "Guest"))
	check("resolver receives the local speaker and trimmed selector", h.sandbox.lastSpeaker == h.localPlayer and h.sandbox.lastSelector == "all")
	local me = run("iy_players", { selector = "me" })
	check("me resolves through IY", me.ok and me.data.names[1] == h.localPlayer.Name)
	local none = run("iy_players", { selector = "unknown" })
	check("empty matches are explicit and structured", none.ok and none.data.count == 0 and has(none.text, "matched no players right now"))
	check("blank selectors are rejected", not run("iy_players", { selector = " " }).ok)
	h.sandbox.getPlayer = function() error("selector failed") end
	check("resolver errors are reported", has(run("iy_players", { selector = "all" }).text, "selector failed"))
	h.sandbox.getPlayer = function() return { {} } end
	check("malformed lists fail cleanly", not run("iy_players", { selector = "all" }).ok)
	h.sandbox.getPlayer = nil
	check("older IY without a resolver fails clearly", has(run("iy_players", { selector = "all" }).text, "does not expose getPlayer"))
end)

scenario("alias management updates native tables, persists and clears in place", function()
	local h, env, registry, run = fixture()
	local aliases, custom = h.sandbox.aliases, h.sandbox.customAlias
	local first = run("iy_control", { action = "alias_add", alias = " Quick ", command = "WS 80" })
	check("command aliases resolve to the native entry", first.ok and custom.quick == h.sandbox.cmds[2] and aliases[1].CMD == "ws" and aliases[1].ALIAS == "quick")
	check("edit refreshes and requests a native save", h.sandbox.refreshCalls == 1 and h.sandbox.saveCalls == 1 and h.json.decode(h.files["IY_FE.iy"]).aliases[1].ALIAS == "quick")
	for _, args in ipairs({
		{ action = "alias_add", alias = "unknown", command = "missing" },
		{ action = "alias_add", alias = "QUICK", command = "example" },
		{ action = "alias_add", alias = "speed", command = "example" },
		{ action = "alias_add", alias = "two words", command = "speed" },
		{ action = "alias_add", alias = "a\\speed", command = "speed" },
		{ action = "alias_add", alias = "2^speed", command = "speed" },
		{ action = "alias_add", alias = "!quick", command = "speed" },
		{ action = "alias_remove", alias = "missing" },
	}) do
		check("invalid alias operation is rejected", not run("iy_control", args).ok)
		check("invalid alias operation has no side effects", #aliases == 1 and custom.quick == h.sandbox.cmds[2] and h.sandbox.refreshCalls == 1 and h.sandbox.saveCalls == 1)
	end
	check("session-only alias works", run("iy_control", { action = "alias_add", alias = "slow", command = "speed", persist = false }).ok and h.sandbox.saveCalls == 1)
	local page = run("iy_control", { action = "inspect", section = "aliases", limit = 1 })
	check("alias inspection is paginated", page.ok and page.data.aliases.total == 2 and page.data.aliases.nextOffset == 2 and page.data.aliases.items[1].alias == "quick")
	page = run("iy_control", { action = "inspect", section = "aliases", limit = 1, offset = page.data.aliases.nextOffset })
	check("alias continuation preserves indexes", page.ok and page.data.aliases.items[1].index == 2 and page.data.aliases.items[1].command == "speed" and page.data.aliases.nextOffset == nil)
	check("remove is case insensitive", run("iy_control", { action = "alias_remove", alias = "QUICK" }).ok and custom.quick == nil and #aliases == 1)
	check("clear empties both tables in place", run("iy_control", { action = "alias_clear" }).ok and h.sandbox.aliases == aliases and h.sandbox.customAlias == custom and next(aliases) == nil and next(custom) == nil)
	h.sandbox.aliases, h.sandbox.customAlias = { false }, {}
	check("malformed aliases do not crash inspection", run("iy_control", { action = "inspect", section = "aliases" }).data.aliases.items[1].malformed ~= nil)
	h.sandbox.aliases = nil
	check("missing alias tables are reported", run("iy_control", { action = "inspect", section = "aliases" }).data.aliases.unavailable ~= nil and not run("iy_control", { action = "alias_clear" }).ok)
end)

scenario("waypoints use validated coordinates and preserve other places unless explicitly cleared", function()
	local h, env, registry, run = fixture()
	local waypoints, all = h.sandbox.WayPoints, h.sandbox.AllWaypoints
	local first = run("iy_control", { action = "waypoint_add", name = " Home ", position = { x = 1.9, y = -2.1, z = 3.8 } })
	check("explicit coordinates are floored and scoped", first.ok and waypoints[1].NAME == "Home" and waypoints[1].COORD[1] == 1 and waypoints[1].COORD[2] == -3 and waypoints[1].COORD[3] == 3 and waypoints[1].GAME == 123)
	check("saved coordinates are equivalent independent entries", #all == 1 and all[1] ~= waypoints[1] and all[1].COORD ~= waypoints[1].COORD and all[1].COORD[2] == -3 and h.json.decode(h.files["IY_FE.iy"]).WayPoints[1].GAME == 123)
	h.sandbox.getRoot = function(character)
		check("current-position lookup receives the character", character == h.localPlayer.Character)
		return { Position = { X = 10.9, Y = 20.3, Z = -30.1 } }
	end
	check("implicit coordinates use the root", run("iy_control", { action = "waypoint_add", name = "Spawn" }).ok and waypoints[2].COORD[1] == 10 and waypoints[2].COORD[3] == -31)
	local page = run("iy_control", { action = "inspect", section = "waypoints", limit = 1 })
	check("waypoint inspection includes coordinates and continuation", page.ok and page.data.waypoints.items[1].x == 1 and page.data.waypoints.total == 2 and page.data.waypoints.allPlacesTotal == 2 and page.data.waypoints.nextOffset == 2)
	page = run("iy_control", { action = "inspect", section = "waypoints", limit = 1, offset = 2 })
	check("waypoint continuation is stable", page.data.waypoints.items[1].index == 2 and page.data.waypoints.items[1].name == "Spawn" and page.data.waypoints.nextOffset == nil)
	local other = { NAME = "Home", COORD = { 9, 9, 9 }, GAME = 456 }
	all[#all + 1] = other
	check("removing by name preserves another place's namesake", run("iy_control", { action = "waypoint_remove", name = "HOME" }).ok and #waypoints == 1 and #all == 2 and all[2] == other)
	local saveCalls, refreshCalls = h.sandbox.saveCalls, h.sandbox.refreshCalls
	for _, args in ipairs({
		{ action = "waypoint_add", name = " " },
		{ action = "waypoint_add", name = "Home\\speed 100", position = { x = 1, y = 2, z = 3 } },
		{ action = "waypoint_add", name = "Bad", position = { x = 1, y = 2 } },
		{ action = "waypoint_add", name = "Bad", position = { x = "x", y = 2, z = 3 } },
		{ action = "waypoint_remove", name = "unknown" },
	}) do check("malformed waypoints fail without mutation", not run("iy_control", args).ok and #waypoints == 1 and #all == 2) end
	local control = env.require("runtime/iy_control")
	for _, value in ipairs({ math.huge, -math.huge, 0 / 0 }) do
		check("nonfinite coordinates are rejected before mutation", control.run({ action = "waypoint_add", name = "Bad", position = { x = value, y = 0, z = 0 } }) == nil and #waypoints == 1)
	end
	h.sandbox.getRoot = function() error("no character") end
	check("missing root is reported", has(run("iy_control", { action = "waypoint_add", name = "Bad" }).text, "no root part"))
	check("failed operations did not save or refresh", h.sandbox.saveCalls == saveCalls and h.sandbox.refreshCalls == refreshCalls)
	check("default clear is scoped and in place", run("iy_control", { action = "waypoint_clear" }).ok and h.sandbox.WayPoints == waypoints and #waypoints == 0 and h.sandbox.AllWaypoints == all and #all == 1 and all[1] == other)
	check("explicit all-place clear empties in place", run("iy_control", { action = "waypoint_clear", all_places = true }).ok and h.sandbox.AllWaypoints == all and next(all) == nil)
	h.sandbox.WayPoints, h.sandbox.AllWaypoints = { false, { NAME = "Broken", COORD = {} } }, nil
	page = run("iy_control", { action = "inspect", limit = 1 })
	check("all includes aliases and malformed waypoints without stalling pagination", page.ok and page.data.aliases and page.data.waypoints.items[1].malformed and page.data.waypoints.nextOffset == 2)
	h.sandbox.WayPoints = nil
	check("missing waypoints are reported", run("iy_control", { action = "inspect", section = "waypoints" }).data.waypoints.unavailable ~= nil)
end)

scenario("command-backed settings validate before mutation and report asynchronous dispatch", function()
	local h, env, registry, run = fixture()
	local set = run("iy_control", { action = "configure", settings = { gui_scale = 1.5, logs_webhook = "https://example.com/logs" } })
	check("settings dispatch the native commands", set.ok and h.sandbox.dispatches[1].command == "guiscale 1.5" and h.sandbox.dispatches[2].command == "chatlogswebhook https://example.com/logs")
	check("async dispatch is explicit", has(set.data.warning, "asynchronously") and #set.data.dispatched == 2)
	check("an empty webhook disables it without another argument", run("iy_control", { action = "configure", settings = { logs_webhook = "" } }).ok and h.sandbox.dispatches[3].command == "chatlogswebhook")
	for _, settings in ipairs({ { gui_scale = 3 }, { logs_webhook = "file:///tmp/logs" }, { logs_webhook = "https://" }, { logs_webhook = "https://example.com\\speed 100" }, { logs_webhook = "https://example.com\n" } }) do
		settings.prefix = "!"
		check("invalid mixed settings never partially apply", not run("iy_control", { action = "configure", settings = settings }).ok and h.sandbox.prefix == ";" and #h.sandbox.dispatches == 3)
	end
	check("native saving is not mislabeled as session-only", not run("iy_control", { action = "configure", settings = { gui_scale = 1 }, persist = false }).ok)
	h.sandbox.guiScale, h.sandbox.logsWebhook = 1.5, "https://example.com/logs"
	local inspect = run("iy_control", { action = "inspect", section = "settings" })
	check("inspection reads the eventual live settings", inspect.ok and inspect.data.settings.gui_scale == 1.5 and inspect.data.settings.logs_webhook == "https://example.com/logs")
	h.sandbox.execCmd = function() error("dispatcher failed") end
	local failedSet = run("iy_control", { action = "configure", settings = { prefix = "!", gui_scale = 1 } })
	check("immediate dispatch failures are not reported as success", not failedSet.ok and has(failedSet.text, "dispatcher failed") and h.sandbox.prefix == ";")
end)

scenario("native event bindings preserve other events, serialize, update, fire and remove", function()
	local h, env, registry, run = fixture()
	local first = run("iy_control", { action = "event_add", event = "OnSpawn", command = ";speed 80", delay = 0.5 })
	check("binding was added", first.ok and first.data.result.index == 1)
	local saved = h.json.decode(h.files["IY_FE.iy"])
	local events = h.json.decode(saved.eventBinds)
	check("uses native tuple and self filter", events.OnSpawn[1][1] == "speed 80" and events.OnSpawn[1][2][1] == 0 and events.OnSpawn[1][3] == 0.5)
	check("unrelated native data is preserved", saved.untouched == "keep" and events.CustomPluginEvent ~= nil)
	check("save request is reported honestly", has(first.data.persistence, "requested"))
	local chat = run("iy_control", { action = "event_add", event = "OnChatted", command = "record $1 $2", conditions = { player = "all", message = "^hello" } })
	check("chat event configured", chat.ok)
	local update = run("iy_control", { action = "event_update", event = "OnSpawn", index = 1, command = "speed 90" })
	events = h.json.decode(h.sandbox.eventEditor.SaveData())
	check("update preserves omitted delay and filters", update.ok and events.OnSpawn[1][1] == "speed 90" and events.OnSpawn[1][3] == 0.5 and events.OnSpawn[1][2][1] == 0)
	check("updating spawn preserves chat events", events.OnChatted[1][1] == "record $1 $2")
	local fired = run("iy_control", { action = "event_fire", event = "OnChatted", arguments = { "Guest", "Hello world" } })
	check("native event executes with substituted arguments", fired.ok and h.sandbox.dispatches[1].command == "record Guest Hello world")
	run("iy_control", { action = "event_fire", event = "OnChatted", arguments = { "Guest", "Bye" } })
	check("message filter remains effective", #h.sandbox.dispatches == 1)
	local inspect = run("iy_control", { action = "inspect", section = "events", event = "OnSpawn", limit = 1 })
	check("inspect returns usable indexes and fields", inspect.ok and inspect.data.events.bindings[1].index == 1 and inspect.data.events.bindings[1].delay == 0.5)
	check("remove works", run("iy_control", { action = "event_remove", event = "OnSpawn", index = 1 }).ok)
	check("clear is scoped to one event", run("iy_control", { action = "event_clear", event = "OnChatted" }).ok and #h.json.decode(h.sandbox.eventEditor.SaveData()).OnChatted == 0)
	check("no asynchronous errors", #h.errors() == 0)
end)

scenario("invalid events never mutate the live editor", function()
	local h, env, registry, run = fixture()
	local before = h.sandbox.eventEditor.SaveData()
	for _, args in ipairs({
		{ action = "event_add", event = "OnSpawn", command = "speed 100", conditions = { message = "hello" } },
		{ action = "event_add", event = "OnChatted", command = "record", conditions = { message = "[" } },
		{ action = "event_add", event = "OnSpawn", command = "plugin mine" },
		{ action = "event_update", event = "OnSpawn", index = 7, command = "speed 100" },
		{ action = "event_remove", event = "OnSpawn", index = 0 },
		{ action = "event_add", event = "Typo", command = "speed 100" },
		{ action = "event_fire", event = "OnDamage", arguments = { "Guest", "not a number" } },
	}) do
		local result = run("iy_control", args)
		check("invalid operation fails", not result.ok)
		check("live events unchanged", h.sandbox.eventEditor.SaveData() == before and h.sandbox.saveCalls == 0)
	end
	check("health and killer filters map to native slots", run("iy_control", { action = "event_add", event = "OnDamage", command = "record", conditions = { player = "all", health_below = 25 } }).ok)
	local data = h.json.decode(h.sandbox.eventEditor.SaveData())
	check("numeric filter preserved", data.OnDamage[1][2][1] == 1 and data.OnDamage[1][2][2] == 25)
	h.sandbox.nosaves = true
	local volatile = run("iy_control", { action = "event_add", event = "OnKilled", command = "record", conditions = { player = "me", killer = "others" } })
	check("unavailable persistence is explicit", volatile.ok and has(volatile.data.persistence, "session only"))
end)

scenario("settings and keybinds use live tables and respect the integration mode", function()
	local h, env, registry, run = fixture()
	local bind = run("iy_control", { action = "keybind_add", key = "F", command = "fly", toggle = "unfly" })
	check("keybind added in native format", bind.ok and h.sandbox.binds[1].KEY == "Enum.KeyCode.F" and h.sandbox.binds[1].TOGGLE == "unfly")
	check("duplicate binding is idempotent", run("iy_control", { action = "keybind_add", key = "F", command = "fly", toggle = "unfly" }).ok and #h.sandbox.binds == 1)
	h.sandbox.toggleOn[h.sandbox.binds[1]] = true
	check("remove clears toggle state", run("iy_control", { action = "keybind_remove", index = 1 }).ok and next(h.sandbox.toggleOn) == nil)
	h.sandbox.binds = { { COMMAND = "speed 10", KEY = "LeftClick" } }
	local inspect = run("iy_control", { action = "inspect", section = "keybinds" })
	check("replacement tables are read live", inspect.ok and inspect.data.keybinds.items[1].key == "LeftClick")
	local set = run("iy_control", { action = "configure", settings = { prefix = "!", chat_logs = true, esp_transparency = 0.7 } })
	check("settings applied", set.ok and h.sandbox.prefix == "!" and h.sandbox.logsEnabled == true and h.sandbox.espTransparency == 0.7)
	check("custom command prefix stripped once", run("iy_cmd", { command = "!speed 20" }).ok and h.sandbox.dispatches[1].command == "speed 20" and h.sandbox.dispatches[1].history == false)
	check("bad mixed settings do not partially commit", not run("iy_control", { action = "configure", settings = { prefix = "?", typo = true } }).ok and h.sandbox.prefix == "!")
	check("integration can be switched off", run("iy_control", { action = "configure", settings = { mode = "off" } }).ok)
	check("loaded engine still honours off", not run("iy_cmd", { command = "speed 100" }).ok and not run("iy_control", { action = "event_clear", event = "OnSpawn" }).ok)
	check("status remains available while off", run("iy_status", {}).ok)
	check("integration can be enabled again", run("iy_control", { action = "configure", settings = { mode = "hidden" } }).ok)
	check("stop loops reaches IY", run("iy_control", { action = "stop_loops" }).ok and h.sandbox.dispatches[#h.sandbox.dispatches].command == "breakloops")
	check("dangerous plugin execution uses code permission", registry.get("iy_plugin_write").risk == "danger")
end)

local PLUGIN = [=[
SharedPluginRuns = (SharedPluginRuns or 0) + 1
local sharedCount = 0
local Plugin = {
	PluginName = "ExamplePlugin", PluginDescription = "Shared state and two commands",
	Commands = {
		example = { ListName = "example / ex", Description = "Increment", Aliases = {"ex"},
			Function = function(args, speaker) sharedCount = sharedCount + 1; PluginOutput = sharedCount end },
		cmd = { ListName = "cmd", Description = "Read shared state", Aliases = {},
			Function = function(args, speaker) PluginOutput = sharedCount end },
	}
}
return Plugin
]=]

scenario("plugin creation supports globals, multiple commands, aliases and live reload", function()
	local h, env, registry, run = fixture()
	local loader = h.sandbox.loadfile
	local result = run("iy_plugin_write", { plugin = "demo", source = PLUGIN })
	check("plugin saved and loaded", result.ok and result.data.loaded and h.files["demo.iy"] == PLUGIN)
	check("top-level code runs exactly once", h.sandbox.SharedPluginRuns == 1)
	check("native loader is restored", h.sandbox.loadfile == loader)
	check("actual collision suffix returned", has(table.concat(result.data.commands, ","), "example1") and #result.data.commands == 2)
	h.sandbox.findCmd("ex").FUNC({}, h.localPlayer)
	h.sandbox.findCmd("cmd").FUNC({}, h.localPlayer)
	check("commands and aliases share closure state", h.sandbox.PluginOutput == 1)
	local duplicate = run("iy_plugin_write", { plugin = "demo", source = PLUGIN })
	check("overwriting requires explicit intent", not duplicate.ok and h.sandbox.SharedPluginRuns == 1)
	local read = run("iy_plugin_read", { plugin = "demo", limit = 100 })
	check("source reading paginates", read.ok and read.data.nextOffset == 101 and has(read.text, "SharedPluginRuns"))
	check("template uses the requested multi-command format", has(run("iy_plugin_read", {}).text, "return Plugin"))
	local update = run("iy_plugin_write", { plugin = "demo.iy", source = PLUGIN:gsub("Increment", "Increment again"), overwrite = true })
	check("reload replaces rather than duplicates commands", update.ok and #h.sandbox.cmds == 6 and #h.sandbox.PluginsTable == 1 and h.sandbox.SharedPluginRuns == 2)
	check("loadfile override never leaks", h.sandbox.loadfile == loader)
	check("saved source still loads as a normal IY plugin", h.sandbox.loadfile("demo.iy")().PluginName == "ExamplePlugin")
	check("no asynchronous plugin errors", #h.errors() == 0)
end)

scenario("plugin validation preserves existing files and rejects invalid destinations", function()
	local h, env, registry, run, ctx = fixture()
	check("save-only never executes setup", run("iy_plugin_write", { plugin = "draft", source = PLUGIN, load = false }).ok and h.sandbox.SharedPluginRuns == nil)
	local invalid = run("iy_plugin_write", { plugin = "draft", source = "local Plugin = {", overwrite = true, load = false })
	check("syntax errors do not overwrite source", not invalid.ok and h.files["draft.iy"] == PLUGIN)
	check("load initial valid plugin", run("iy_plugin_write", { plugin = "draft", source = PLUGIN, overwrite = true }).ok)
	local command = h.sandbox.findCmd("cmd")
	local malformed = run("iy_plugin_write", { plugin = "draft", source = "return {}", overwrite = true })
	check("invalid returned tables restore file and retain live commands", not malformed.ok and h.files["draft.iy"] == PLUGIN and h.sandbox.findCmd("cmd") == command)
	check("runtime errors restore file", not run("iy_plugin_write", { plugin = "draft", source = "error('broken setup')", overwrite = true }).ok and h.files["draft.iy"] == PLUGIN)
	for _, name in ipairs({ "../escape", "nested/plugin.iy", "C:\\escape", "IY_FE.iy", "iy_fe", "CON", "NUL.iy", "demo.iy:stream" }) do
		check("unsafe filename rejected: " .. name, not run("iy_plugin_write", { plugin = name, source = PLUGIN, load = false }).ok)
	end
	ctx.aborted = function() return true end
	check("cancelled request does not write", not run("iy_plugin_write", { plugin = "cancelled", source = PLUGIN }).ok and h.files["cancelled.iy"] == nil)
	ctx.aborted = function() return false end
	h.sandbox.addPlugin = function() end
	local silent = run("iy_plugin_write", { plugin = "silent", source = PLUGIN })
	check("silent native failures are not reported as loaded", not silent.ok and has(silent.text, "did not register"))
end)

scenario("parallel writes cannot replace a plugin while its setup is yielding", function()
	local h, env, registry, run, ctx = fixture()
	local first
	local source = "wait(1)\n" .. PLUGIN
	h.sched.spawn(function()
		first = registry.dispatch({ id = "first", name = "iy_plugin_write", arguments = h.json.encode({ plugin = "parallel", source = source }) }, ctx)
	end)
	h.sched.advance(0.1)
	local second = run("iy_plugin_write", { plugin = "parallel", source = PLUGIN, overwrite = true })
	check("conflicting write is rejected", not second.ok and has(second.text, "already being updated"))
	h.sched.advance(1.2)
	check("original write completes with its own source", first and first.ok and h.files["parallel.iy"] == source and h.sandbox.SharedPluginRuns == 1)
	check("lock is released after completion", run("iy_plugin_write", { plugin = "parallel", source = PLUGIN, overwrite = true }).ok)
end)

scenario("internal loading is shared and plugins inherit the captured IY environment", function()
	local h, env = fixture()
	h.sandbox.execCmd = nil
	local requests = 0
	local source = [[
execCmd = function() end
cmds = {}
CMDs = { { NAME = "speed [num]", DESC = "Internal description" } }
getPlayer = function(selector, speaker) return { speaker.Name } end
prefix = ";"
PARENT = Instance.new("ScreenGui")
privateHelper = 42
wait(0.4)
]] .. string.rep("-- upstream-sized fixture\n", 500)
	env.require("net/http").send = function() requests = requests + 1; return { status = 200, body = source } end
	local iy = env.require("runtime/iy")
	local first, second
	h.sched.spawn(function() first = iy.ensure() end)
	h.sched.advance(0.1)
	h.sched.spawn(function() second = iy.ensure() end)
	h.sched.advance(1.2)
	check("parallel callers share a completed load", requests == 1 and first == true and second == true and iy.source == "internal")
	check("captured globals remain private", iy.value("privateHelper") == 42 and h.sandbox.privateHelper == nil)
	check("descriptions and selectors work inside the captured environment", iy.descriptions()[1].DESC == "Internal description" and iy.resolvePlayers("me")[1] == h.localPlayer.Name)
	iy.environment().CMDs = nil
	h.sandbox.CMDs = nil
	check("removed internal descriptions do not use a stale capture", iy.descriptions() == nil)
	h.files["scoped.iy"] = "pluginGlobal = privateHelper + 1; return { value = pluginGlobal }"
	local plugin = iy.environment().loadfile("scoped.iy")()
	check("plugin top-level globals share IY helpers", plugin.value == 43 and iy.value("pluginGlobal") == 43 and h.sandbox.pluginGlobal == nil)
	local gui = iy.value("PARENT")
	gui.Enabled = true
	check("hidden mode survives IY showing its GUI", gui.Enabled == false)
end)

scenario("switching integration off during startup prevents the pending command", function()
	local h, env = fixture()
	h.sandbox.execCmd = nil
	env.require("net/http").send = function()
		return { status = 200, body = "wait(0.4)\nexecCmd = function() end\ncmds = {}\nPARENT = Instance.new('ScreenGui')\n" .. string.rep("-- startup fixture\n", 700) }
	end
	local iy, ready = env.require("runtime/iy")
	h.sched.spawn(function() ready = iy.ensure() end)
	h.sched.advance(0.1)
	iy.setMode("off")
	h.sched.advance(1.2)
	check("waiting caller observes the latest mode", ready == false and iy.value("PARENT").Enabled == false)
	check("dispatcher refuses commands while off", iy.exec("speed 100") == false)
end)

print(string.format("IY control: %d checks passed, %d scenarios failed", passed, failed))
if failed > 0 then os.exit(1) end
