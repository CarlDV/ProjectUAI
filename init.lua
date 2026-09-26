--!globals __UAI_MODULES __UAI_BUILD
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

local VERSION = "2.0.0"
local FOLDER = "UAI"
local BUILD = type(__UAI_BUILD) == "string" and __UAI_BUILD or VERSION

-- Re-running the same build reopens it; a changed build replaces an idle client.
-- Never tear down active work or mount over a cleanup that did not finish.
local globalTable = (type(getgenv) == "function") and getgenv() or nil
if globalTable and type(globalTable.UAI) == "table" then
	local existing = globalTable.UAI
	if existing.alive or existing.reloadBlocked then
		local function notice(message)
			local shown = pcall(function()
				existing.env.require("ui/overlay").toast(message, "warn", 7)
			end)
			if not shown or not existing.alive then warn("[uai] " .. message) end
		end
		if existing.reloadBlocked then
			notice("The previous client did not finish unloading. Rejoin before loading the update.")
			return existing
		end
		if existing.build == BUILD then
			if type(existing.toggle) == "function" then pcall(existing.toggle) end
			return existing
		end
		existing.pendingBuild = BUILD
		local inspected, busy = pcall(function()
			local runner = existing.env.loadedModules and existing.env.loadedModules["tools/code_runner"]
			if runner and runner.busy and runner.busy() then return true end
			for _, session in ipairs(existing.sessions.list()) do
				if session.busy then return true end
			end
			local child = existing.env.loadedModules and existing.env.loadedModules["agent/subagent"]
			return child ~= nil and #child.running() > 0
		end)
		if not inspected then
			notice("Update ready. Could not check active work; reopen the client after your work finishes.")
			return existing
		end
		if busy then
			notice("Update ready. Let the current work finish or stop it, then run the loader again.")
			return existing
		end
		local checkedDrafts, pending = pcall(function()
			local workspace = existing.env.loadedModules and existing.env.loadedModules["runtime/code_store"]
			if workspace and workspace.preflightReplacement then
				local preserved, why = workspace.preflightReplacement()
				if not preserved then return "Update ready. " .. tostring(why) end
			end
			for _, session in ipairs(existing.sessions.list()) do
				local ctx = session.ctx or {}
				if session.ephemeral and (#(session.log or {}) > 0 or #(ctx.messages or {}) > 0
					or (type(ctx.summary) == "string" and ctx.summary ~= "") or session.named or (session.turns or 0) > 0) then
					return "Update ready. Save or remove your isolated conversations before running the loader again."
				end
			end
			local composer = existing.app.chatPanel and existing.app.chatPanel.composer
			local chatLoops = existing.env.loadedModules and existing.env.loadedModules["runtime/chatloops"]
			if chatLoops and #chatLoops.running() > 0 then
				return "Update ready. Stop your chat loops before running the loader again."
			end
			local composerModule = existing.env.loadedModules and existing.env.loadedModules["ui/chat/composer"]
			local quick = existing.env.loadedModules and existing.env.loadedModules["ui/quickchat"]
			local function hasText(field)
				return field and type(field.get) == "function" and tostring(field.get()):find("%S") ~= nil
			end
			if (composer and (hasText(composer.field) or #(composer.attachments or {}) > 0))
				or (composerModule and composerModule.hasDrafts and composerModule.hasDrafts()) then
				return "Update ready. Send or clear your draft and attachments before running the loader again."
			end
			if quick and hasText(quick.field) then
				return "Update ready. Send or clear your Quick Chat draft before running the loader again."
			end
		end)
		if not checkedDrafts or pending then
			notice(pending or "Update ready. Could not check unsaved drafts, so this client is staying open.")
			return existing
		end
		local saved, complete = pcall(function()
			local fsx = existing.env.require("runtime/fsx")
			if not fsx.enabled then return false end
			if not existing.config.saveNow() then return false end
			for _, session in ipairs(existing.sessions.list()) do
				if not session.headless and not session.ephemeral and (session.depth or 0) == 0 then
					if not existing.sessions.persist(session) then return false end
				end
			end
			return true
		end)
		if not saved or not complete then
			notice("Update ready. Settings and conversations could not be saved, so this client is staying open.")
			return existing
		end
		if hostContext == nil and existing.env and type(existing.env.context) == "table" then
			hostContext = existing.env.context
		end
		local unloaded, result = pcall(function() return existing.destroy() end)
		local checked, detached = pcall(function()
			return not existing.app.screen or existing.app.screen.Parent == nil
		end)
		if not unloaded or result == false or existing.alive or existing.cleanupFailed or not checked or not detached then
			existing.reloadBlocked = true
			globalTable.UAI = existing
			notice("The previous client did not finish unloading. Rejoin before loading the update.")
			return existing
		end
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
	info = { name = "UAI", version = VERSION, build = BUILD, folder = FOLDER },
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

-- How many modules this artifact carries, counted rather than written down: the
-- bundler decides it, and a literal here would go stale on the next build. It is the
-- only denominator available to the boot indicator, and it is deliberately *not*
-- treated as a target -- a normal boot loads about four fifths of it and never
-- reaches the rest, because a panel's module is loaded the first time that panel is
-- opened.
env.moduleTotal = 0
for _ in pairs(MODULES) do env.moduleTotal = env.moduleTotal + 1 end
env.moduleCount = 0

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
	env.moduleCount = env.moduleCount + 1
	-- The one hook in the loader, and it exists for the boot indicator: the count is
	-- real work finishing, which is the only progress this client can honestly report
	-- before the interface is up. pcall because a watcher must never be able to stop a
	-- module from loading.
	if env.onModuleLoaded then pcall(env.onModuleLoaded, id, env.moduleCount, env.moduleTotal) end
	return result
end

env.loadedModules = loaded

local function start()
	-- The boot indicator first, before a single other module loads.
	--
	-- It is dependency free on purpose, so it can paint within a frame of execution
	-- rather than after the theme and the control set are built -- the seconds those
	-- take are exactly what it exists to cover, and it used to appear only once three
	-- quarters of them were already spent. It is only a pcall deep because a client
	-- that cannot draw it must still boot: a progress bar is not worth failing a
	-- start over.
	local boot
	pcall(function() boot = env.require("ui/boot").show() end)

	-- The loader reports real work finishing -- the only honest progress there is
	-- before the interface is up -- and yields on a budget while it does, so the
	-- indicator animates instead of freezing until the mount is done. A Roblox GUI
	-- does not paint until the thread building it yields, and the whole boot used to
	-- run start-to-finish without one; the throttle keeps a fast client from paying
	-- for yields it does not need while still repainting a slow one a few times a
	-- second. pcall on step because a watcher must never stop a module loading.
	local lastYield = os.clock()
	env.onModuleLoaded = function(id, count, total)
		if boot then pcall(boot.step, id, count, total) end
		if os.clock() - lastYield >= 0.03 then
			task.wait()
			lastYield = os.clock()
		end
	end

	-- The interface build is the tail of the boot that module counting cannot see:
	-- once every module is loaded the counter sits still while the window, the
	-- transcript and the composer are constructed -- the single largest synchronous
	-- chunk of the whole start, and where the bar used to jump to four fifths and then
	-- freeze. app.mount calls this at those construction boundaries, so the indicator
	-- yields across them and keeps animating. Set only for the first mount and cleared
	-- with the loader below, so a later rebuild never pays for it.
	env.onMountPhase = function(text)
		if boot then pcall(boot.phase, text) end
		task.wait()
	end

	-- Force the first paint before the heavy loading begins, so the indicator is on
	-- screen for the whole of it rather than appearing at the end.
	if boot then task.wait() end

	-- Startup order matters in exactly one place: config has to be read before
	-- anything derives from it, because the theme and the provider list are both
	-- built from stored values.
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

	-- The workspace migration, before anything that reads files/: the file tools,
	-- the paste fallbacks, the attach menu. For a returning user with older files
	-- this is the step between "it used to see my notes" and the tidy layout, so it
	-- is reported through the boot indicator while it happens rather than logged
	-- where nobody looks. A fresh install sweeps an empty root and reports nothing.
	pcall(function()
		local fsx = env.require("runtime/fsx")
		local alreadyMigrated = config.get("fs.migrated", false) == true
		local hasDisplacedSkills = fsx.isDir("skills", { scope = "files" })
		if alreadyMigrated and not hasDisplacedSkills then return end

		local swept = fsx.list("")
		local pending = 0
		for _, entry in ipairs(swept) do
			if not tostring(entry.path or ""):find("/", 1, true) then
				local name = tostring(entry.name or "")
				local clientOwns = name == "files" or name == "pastes" or name == "skills"
					or name == "sessions" or name == "export" or name == "icons"
					or name == "config.json" or name == "stats.json"
				if not clientOwns then pending = pending + 1 end
			end
		end
		if (pending > 0 or hasDisplacedSkills) and boot then
			boot.phase("updating: your files are moving to the new layout", 0)
		end
		local moved = fsx.migrate(function(count, name)
			if boot then boot.phase(string.format("moved %d: %s", count, name), math.min(count / 30, 0.9)) end
		end)
		if moved and moved > 0 and boot then
			boot.phase(string.format("moved %d file(s) into files/", moved), 1)
		end
		config.set("fs.migrated", true)
		config.save()
		fsx.ensure("skills")
		fsx.ensure("files")
	end)

	local sessions = env.require("agent/session")
	sessions.restore()

	-- After the restore, because the first run recovers the real message history out
	-- of whatever transcripts are already on disk, and before the interface, because
	-- the home card reads it as soon as it builds.
	env.require("agent/stats").init()

	local app = env.require("ui/app")
	app.mount()
	app.show(config.get("ui.panel", "chat"))

	-- The interface is up, so the indicator has nothing left to report. The count is
	-- what it closes on: the rest of the artifact is the panels nobody has opened yet.
	env.onModuleLoaded = nil
	env.onMountPhase = nil
	if boot then
		pcall(boot.done, string.format("%d of %d modules loaded -- the rest load with the panel that needs them",
			env.moduleCount, env.moduleTotal))
	end

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
		build = BUILD,
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
			-- Every turn in flight is stopped, not just the one on screen: conversations
			-- run on their own threads and more than one can be working, so aborting the
			-- active session alone left the others to finish into a transcript that had
			-- already been destroyed.
			for _, session in ipairs(sessions.list()) do
				pcall(session.abort)
			end
			-- Anything delegated is stopped with them. A subagent outlives the step that
			-- dispatched it by design, and its budget is measured in minutes.
			pcall(function() env.require("agent/subagent").stopAll() end)
			local ran, failed = env.require("runtime/dispose").drain()
			local screenOk = pcall(function() app.screen:Destroy() end)
			handle.cleanupFailed = not screenOk or #(failed or {}) > 0
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
	--
	-- And on screen too, where the indicator already is: a boot that dies at module
	-- forty leaves a bar stopped at forty and no explanation, which is worse than
	-- never having drawn one. Both the flag and the notice are cleared here, so a
	-- half-loaded client leaves nothing of itself behind.
	env.onModuleLoaded = nil
	pcall(function() env.require("ui/boot").fail(result) end)
	return nil
end
return result
