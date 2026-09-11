-- Infinite Yield as an internal command engine.
--
-- UAI is standalone, so nothing guarantees Infinite Yield is running when the
-- agent wants it. Two paths cover both cases, and both end in the same place:
-- a held reference to IY's `execCmd` and `cmds`.
--
--   1. Ambient. The user already ran IY; it left `execCmd` in the executor's
--      global table. Latching on costs nothing, so it is tried first.
--   2. Internal. UAI loads IY itself. The fetched source is run through
--      loadstring against a captured copy of the global table, so the
--      chunk-level globals IY writes (execCmd, cmds, PARENT -- it never
--      getgenv's them, they are just chunk globals in the executor env) land
--      in a table we hold a reference to, whatever the host calls its shared
--      environment.
--
-- Re-running IY's source while IY_LOADED is truthy is a no-op by IY's own
-- guard, so an internal load after an ambient detection cannot double it.
--
-- The GUI toggle is a mode, not a hide-after-load: "hidden" loads IY and then
-- parks its ScreenGui, "visible" leaves it exactly as IY drew it. Either way
-- the agent gets every command through the same execCmd.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")

	local SOURCE_URL = "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"

	-- How long the fetch-and-load may take before a caller gives up on it. IY's
	-- source is around a megabyte, and parsing it on a slow client is seconds
	-- rather than the tens the HTTP transport alone might suggest.
	local LOAD_TIMEOUT = 45

	local M = {
		-- "off" | "hidden" | "visible" -- what the user asked for in Settings.
		-- "off" is not stored state, it is the absence of a request.
		mode = nil,
		-- Set once an internal load has been attempted, successful or not, so a
		-- failed load is reported rather than retried by every tool call.
		loadTried = false,
		loadError = nil,
		-- How IY was obtained, once known: "ambient" or "internal".
		source = nil,
		-- IY's globals, captured. execCmd, cmds, prefix, IY_LOADED, PARENT.
		iy = nil,
		-- The environment an internal load ran against. Kept because a plugin
		-- loaded later through iy_plugin needs the same table.
		sandbox = nil,
	}

	local function genv()
		if caps.fn.getgenv then
			local ok, shared = pcall(caps.fn.getgenv)
			if ok and type(shared) == "table" then return shared end
		end
		return _G
	end

	-- Read one of IY's globals through whichever route can see it. The ambient
	-- route only: after an internal load we read through `sandbox` directly.
	-- Exposed on the module because the plugin store needs the same reach for
	-- IY's addPlugin/deletePlugin, and a second copy of the route would be a
	-- second thing to keep in step with the sandbox.
	local function ambient(name)
		local shared = genv()
		local value = rawget(shared, name)
		if value ~= nil then return value end
		-- Some hosts isolate chunks from the shared table; IY's globals then live
		-- nowhere UAI can name. That is the case the internal load exists for.
		return nil
	end

	M.ambient = ambient

	function M.execFn()
		if M.iy then return M.iy.execCmd end
		local fn = ambient("execCmd")
		if type(fn) == "function" then return fn end
		return nil
	end

	function M.cmdsTable()
		if M.iy then return M.iy.cmds end
		local list = ambient("cmds")
		if type(list) == "table" then return list end
		return nil
	end

	function M.isLoaded()
		return type(M.execFn()) == "function"
	end

	-- One command through IY's dispatcher. The third argument of execCmd is
	-- `store` (history), not quiet -- passing true would push every agent call
	-- into the user's visible command history, so false.
	function M.exec(command)
		local fn = M.execFn()
		if not fn then return false, "Infinite Yield is not loaded" end
		local speaker = env.plr
		local ok, err = pcall(fn, command, speaker, false)
		if not ok then return false, tostring(err) end
		return true, nil
	end

	-- Hide or show IY's own interface after a load.
	--
	-- IY parents everything under a randomly-named ScreenGui (its `PARENT`
	-- global) and remembers nothing about being hidden, so the reference has to
	-- be captured at load time -- after the load returns there is no way back to
	-- it. Setting Enabled keeps IY's loops, bindings and the command bar alive;
	-- only the pixels go away, which is the whole point: the agent keeps every
	-- command, the user keeps their screen.
	--
	-- The guard exists because IY flips this bit itself: its CaptureService
	-- handlers set PARENT.Enabled = false when a screenshot starts and back to
	-- true the moment it ends, so a hidden IY would resurface on the first
	-- screenshot the user takes. Enforcing the bit on change, rather than hiding
	-- children (which would also un-hide panels IY manages the visibility of
	-- itself), is the one intervention that cannot corrupt IY's own UI state.
	local guard = nil

	local function stopGuard()
		if guard then
			pcall(function() guard:Disconnect() end)
			guard = nil
		end
	end

	env.require("runtime/dispose").add(stopGuard, "iy.guard")

	function M.applyGui()
		local iy = M.iy
		if not iy or not iy.PARENT then return false, "IY's GUI reference was not captured" end
		local gui = iy.PARENT
		if typeof and typeof(gui) ~= "Instance" then return false, "IY's GUI reference is not an Instance" end
		local hidden = (M.mode == "hidden")
		stopGuard()
		local ok = pcall(function() gui.Enabled = not hidden end)
		if not ok then return false, "could not set the GUI's Enabled flag" end
		if hidden then
			local okConn, conn = pcall(function()
				return gui:GetPropertyChangedSignal("Enabled"):Connect(function()
					if M.mode == "hidden" and gui.Enabled then gui.Enabled = false end
				end)
			end)
			if okConn then guard = conn end
		end
		return true, nil
	end

	-- Fetch, compile and run IY's source against a captured global table.
	--
	-- The sandbox is the live shared table with a metatable, not a copy: IY
	-- reaches for Roblox globals and its own earlier declarations constantly,
	-- and a frozen copy would make its `function execCmd` declarations local to
	-- a table nobody reads. __index falls through to the real environment; the
	-- chunk's own writes land in `holder`, which is what we keep.
	local function runInternal()
		local compile = caps.fn.loadstring
		if not compile then return nil, "this host cannot compile code (loadstring is unavailable)" end

		local holder = {}
		local sandbox = setmetatable(holder, { __index = genv() })

		-- The fetch goes through net/http rather than raw game:HttpGet so it is
		-- subject to the same transport fallback, identity and history the rest
		-- of the client's traffic is. Browser identity: raw.githubusercontent
		-- answers 403 to some CLI agent strings.
		local http = env.require("net/http")
		local res, err = http.send({
			url = SOURCE_URL,
			method = "GET",
			identity = "browser",
			tag = "iy",
			timeout = LOAD_TIMEOUT * 1000,
			attempts = 2,
		})
		if not res then return nil, "could not fetch the source: " .. tostring(err) end
		if res.status ~= 200 then
			return nil, string.format("the download answered HTTP %d", res.status)
		end
		local src = tostring(res.body or "")
		if #src < 10000 then return nil, "the download was too small to be Infinite Yield" end

		local fn, compileErr = compile(src, "infiniteyield")
		if not fn then return nil, "compile error: " .. tostring(compileErr) end

		-- setfenv where the host offers it, so the chunk's globals are the holder
		-- rather than the executor's shared table. Without setfenv (some hosts
		-- restrict it under identity sandboxing) the writes go to the real shared
		-- table instead, which is also fine: the ambient probe finds them there
		-- on the next look.
		if setfenv then
			pcall(setfenv, fn, sandbox)
		end

		local ok, runErr = pcall(fn)
		if not ok then return nil, "the source raised: " .. tostring(runErr) end

		-- Give task.spawn'ed init threads one scheduler round to declare
		-- themselves, then look for the dispatcher wherever it landed.
		clock.wait(0.5)
		local exec = rawget(holder, "execCmd") or ambient("execCmd")
		if type(exec) ~= "function" then
			return nil, "the source ran but exposed no execCmd -- IY may have refused to load here"
		end

		M.sandbox = sandbox
		-- prefix and PARENT carry the ambient fallback too: on a host without
		-- setfenv the chunk's globals land in the shared table instead of the
		-- holder, and cmds already looks there. addPlugin, deletePlugin and
		-- PluginsTable ride along for the plugin store -- they are chunk globals
		-- like the rest, written the same way.
		M.iy = {
			execCmd = exec,
			cmds = rawget(holder, "cmds") or ambient("cmds"),
			prefix = rawget(holder, "prefix") or ambient("prefix"),
			PARENT = rawget(holder, "PARENT") or ambient("PARENT"),
			addPlugin = rawget(holder, "addPlugin") or ambient("addPlugin"),
			deletePlugin = rawget(holder, "deletePlugin") or ambient("deletePlugin"),
			PluginsTable = rawget(holder, "PluginsTable") or ambient("PluginsTable"),
		}
		return true, nil
	end

	-- Bring IY up to the mode the user asked for. Cheap when it is already
	-- there: ambient first, then one internal load, then never again this
	-- session unless the caller forces a retry.
	function M.ensure()
		if M.mode == nil then
			local stored = config.get("iy.mode", "off")
			M.mode = (stored == "hidden" or stored == "visible") and stored or "off"
		end
		if M.mode == "off" then
			return false, "Infinite Yield integration is off in Settings"
		end
		if M.isLoaded() then
			if M.source == nil then M.source = "ambient" end
			-- The GUI follow only applies to a load UAI made; an ambient IY the
			-- user started themselves is theirs to see.
			if M.source == "internal" then
				local ok, err = M.applyGui()
				if not ok then log.warn("iy", "could not apply the GUI mode", err) end
			end
			return true, nil
		end
		if M.loadTried then
			return false, M.loadError or "an earlier load attempt failed"
		end
		M.loadTried = true

		local ok, err = runInternal()
		if not ok then
			M.loadError = err
			log.warn("iy", "internal load failed", err)
			return false, err
		end

		M.source = "internal"
		log.info("iy", "Infinite Yield loaded internally (" .. M.mode .. ")")
		local guiOk, guiErr = M.applyGui()
		if not guiOk then log.warn("iy", "GUI mode could not be applied", guiErr) end
		return true, nil
	end

	-- The settings toggle. Setting a mode does not load anything by itself --
	-- loading is one fetch of a megabyte and a GUI, and a settings row is not
	-- the place to spend that. The next tool call picks the mode up. What does
	-- happen immediately is the GUI following a load that already exists:
	-- switching Hidden to With GUI in Settings should show the interface now,
	-- not after the next command.
	function M.setMode(mode)
		if mode ~= "off" and mode ~= "hidden" and mode ~= "visible" then return false end
		M.mode = mode
		config.set("iy.mode", mode)
		if M.source == "internal" and M.isLoaded() then
			local ok, err = M.applyGui()
			if not ok then log.warn("iy", "could not apply the GUI mode", err) end
		end
		return true
	end

	function M.status()
		local rows = {}
		rows[#rows + 1] = { "Setting", M.mode or config.get("iy.mode", "hidden") }
		if M.isLoaded() then
			rows[#rows + 1] = { "Loaded", "yes, via " .. (M.source or "ambient") }
			local cmds = M.cmdsTable()
			if type(cmds) == "table" then
				rows[#rows + 1] = { "Commands", tostring(#cmds) }
			end
			local prefix = M.iy and M.iy.prefix or ambient("prefix")
			if prefix then rows[#rows + 1] = { "Prefix", tostring(prefix) } end
			if M.source == "internal" then
				rows[#rows + 1] = { "GUI", (M.mode == "hidden") and "hidden" or "visible" }
			else
				rows[#rows + 1] = { "GUI", "the user's own -- not managed here" }
			end
		else
			rows[#rows + 1] = { "Loaded", "no" }
			if M.loadTried and M.loadError then
				rows[#rows + 1] = { "Last load", M.loadError }
			end
		end
		rows[#rows + 1] = { "Host can load it", caps.exec and "yes" or "no (no loadstring)" }
		return rows
	end

	return M
end
