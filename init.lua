--!globals __UAI_MODULES
-- Bootstrap.
--
-- Everything above this file is a factory of the form `return function(env)`. This
-- is the one chunk that is not: it builds the env, wires the module loader, and
-- mounts the interface. The bundler emits it last, after the module table, so
-- `__UAI_MODULES` is a local in the finished artifact.
--
-- Run it as:
--     loadstring(game:HttpGet("<url>/dist/uai.lua"))()
-- or, when embedding it in a host script, pass a context table:
--     loadstring(...)({ prompt = "You also control X", hooks = { preTool = fn } })

local MODULES = __UAI_MODULES
if type(MODULES) ~= "table" then
	warn("[uai] no module table -- run the bundled dist/uai.lua, not src/init.lua")
	return nil
end

local hostContext = ...

local VERSION = "1.0.0"
local FOLDER = "UAI"

-- An existing instance is toggled rather than duplicated: running the loader twice
-- is the normal way people re-open a script, and two copies would fight over the
-- same config file and stack two interfaces.
local globalTable = (type(getgenv) == "function") and getgenv() or nil
if globalTable and type(globalTable.UAI) == "table" and globalTable.UAI.alive then
	local existing = globalTable.UAI
	if existing.toggle then
		local ok = pcall(existing.toggle)
		if ok then return existing end
	end
end

-- Services are resolved lazily and memoised. GetService is the correct accessor
-- even for Workspace and Players: a game may have renamed the instance, and
-- indexing `game.Workspace` would then miss.
local services = setmetatable({}, {
	__index = function(cache, name)
		local ok, service = pcall(function() return game:GetService(name) end)
		if not ok or not service then return nil end
		cache[name] = service
		return service
	end,
})

local env = {
	info = { name = "UAI", version = VERSION, folder = FOLDER },
	services = services,
	context = (type(hostContext) == "table" and hostContext)
		or (globalTable and type(globalTable.UAI_CONTEXT) == "table" and globalTable.UAI_CONTEXT)
		or {},
}

env.hs = services.HttpService
env.uis = services.UserInputService
env.tween = services.TweenService
env.run = services.RunService
env.guisvc = services.GuiService
env.players = services.Players
env.plr = env.players and env.players.LocalPlayer or nil

-- The loader. Cycles are an error rather than a hang: a module that is already
-- loading has been reached again, and returning a half-built table would fail
-- somewhere far away from the cause.
local loaded, loading = {}, {}

function env.require(id)
	local cached = loaded[id]
	if cached ~= nil then return cached end
	if loading[id] then
		error("[uai] circular require: " .. tostring(id), 2)
	end
	local factory = MODULES[id]
	if type(factory) ~= "function" then
		error("[uai] no module '" .. tostring(id) .. "'", 2)
	end
	loading[id] = true
	local ok, result = pcall(factory, env)
	loading[id] = nil
	if not ok then
		error("[uai] module '" .. tostring(id) .. "' failed to load: " .. tostring(result), 2)
	end
	if result == nil then
		error("[uai] module '" .. tostring(id) .. "' returned nothing", 2)
	end
	loaded[id] = result
	return result
end

env.loadedModules = loaded

-- Startup order matters in exactly one place: config has to be read before
-- anything derives from it, because the theme and the provider list are both
-- built from stored values.
local function start()
	local caps = env.require("runtime/caps")
	local log = env.require("runtime/log")
	local config = env.require("runtime/config")

	config.load()
	log.mirror = config.get("logs.mirror", false) == true
	log.info("boot", string.format("UAI %s starting -- %s", VERSION, caps.summary()))

	-- Asked for early and answered in the background: the place name is what the
	-- conversation list groups by, and it is a web call.
	env.require("runtime/place").resolve()

	env.require("agent/hooks").adoptContext()
	env.require("agent/registry").load()

	local sessions = env.require("agent/session")
	sessions.restore()

	-- After the restore, because the first run recovers the real message history out
	-- of whatever transcripts are already on disk, and before the interface, because
	-- the home card reads it as soon as it builds.
	env.require("agent/stats").init()

	local app = env.require("ui/app")
	app.mount()
	app.show(config.get("ui.panel", "chat"))

	-- After the interface, because the bridge attaches to whichever thread is
	-- active and the interface is what establishes that on a fresh install. A
	-- no-op unless the setting has been turned on.
	local bridge = env.require("net/bridge")
	local bridgeOk, bridgeWhy = bridge.sync()
	if not bridgeOk and bridgeWhy then log.warn("bridge", "not started", bridgeWhy) end

	-- The handle a host script (or the user, from a console) can drive.
	-- Declared before it is populated: `local handle = { ... }` does not put `handle`
	-- in scope inside its own initialiser, so every closure below that reaches for
	-- `handle` would have captured a nil global instead. `destroy` did exactly that,
	-- which is why unloading raised rather than unloading.
	local handle
	handle = {
		alive = true,
		version = VERSION,
		env = env,
		app = app,
		sessions = sessions,
		config = config,
		log = log,
		caps = caps,
		bridge = bridge,
		providers = env.require("provider/registry"),
		tools = env.require("agent/registry"),
		toggle = function() app.toggle() end,
		show = function(panel) app.show(panel) end,
		hide = function() app.hide() end,
		ask = function(text)
			local session = sessions.current()
			return session.send(text)
		end,
		-- The kill switch. Destroying the ScreenGui is not unloading: timers keep
		-- ticking, input handlers keep firing on the service, and a config write
		-- would rebuild an interface that is no longer on screen. Everything that
		-- outlives the instance tree registers a cleanup in runtime/dispose, and
		-- this is what drains it.
		--
		--     getgenv().UAI.destroy()
		destroy = function()
			if not handle.alive then return 0 end
			handle.alive = false
			-- A turn in flight is stopped first, so no reply arrives to a transcript
			-- that has already gone.
			pcall(function() sessions.current().abort() end)
			local ran, failed = env.require("runtime/dispose").drain()
			pcall(function() app.screen:Destroy() end)
			pcall(function() config.saveNow() end)
			if globalTable then globalTable.UAI = nil end
			log.info("boot", string.format("unloaded -- %d cleanups run", ran or 0))
			for _, problem in ipairs(failed or {}) do
				log.warn("boot", "cleanup failed", problem)
			end
			return ran
		end,
		unload = function() return handle.destroy() end,
	}

	if globalTable then globalTable.UAI = handle end
	log.info("boot", "ready")
	return handle
end

local ok, result = pcall(start)
if not ok then
	warn("[uai] failed to start: " .. tostring(result))
	-- A visible failure beats a silent one: the log module may not even have
	-- loaded, so this goes to the console directly.
	return nil
end
return result
