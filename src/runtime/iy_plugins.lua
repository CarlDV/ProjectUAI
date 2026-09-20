-- Author-owned IY plugins. The on-disk format is the ordinary IY plugin table;
-- top-level globals and shared locals are kept in the live IY environment.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local iy = env.require("runtime/iy")
	local M = {}
	local MAX_BYTES = 256000
	M.template = [=[-- Shared locals or globals may be declared above Plugin.
local count = 0

local Plugin = {
	["PluginName"] = "ExamplePlugin",
	["PluginDescription"] = "Two commands with shared state.",
	["Commands"] = {
		["example"] = {
			["ListName"] = "example / ex",
			["Description"] = "Prints a message to the console",
			["Aliases"] = {"ex"},
			["Function"] = function(args, speaker)
				count = count + 1
				print("Hello from ExamplePlugin!", count)
			end
		},
		["resetexample"] = {
			["ListName"] = "resetexample",
			["Description"] = "Resets the shared counter",
			["Aliases"] = {},
			["Function"] = function(args, speaker)
				count = 0
			end
		}
	}
}

return Plugin
]=]

	function M.filename(value)
		if type(value) ~= "string" then return nil, "plugin must be a plain .iy filename" end
		local name = util.trim(value)
		if name:lower():sub(-3) == ".iy" then name = name:sub(1, -4) end
		if #name < 1 or #name > 80 or not name:match("^[%w_%-]+$") then
			return nil, "use a plugin name containing only letters, numbers, underscores, or hyphens; no paths"
		end
		local lower = name:lower()
		if lower == "iy_fe" or lower == "con" or lower == "prn" or lower == "aux" or lower == "nul"
			or lower:match("^com%d$") or lower:match("^lpt%d$") then return nil, "that filename is reserved" end
		return name .. ".iy"
	end

	local function readExisting(name)
		local read = caps.fn.readfile
		if not read then return nil, "this host cannot read plugin files" end
		local present
		if caps.fn.isfile then
			local ok, result = pcall(caps.fn.isfile, name)
			if not ok then return nil, "could not check whether " .. name .. " exists" end
			present = result
			if not present then return nil end
		end
		local ok, source = pcall(read, name)
		if ok and type(source) == "string" then return source end
		if present then return nil, "could not read existing " .. name .. "; refusing to overwrite it" end
		if not caps.fn.isfile then return nil, "could not establish whether " .. name .. " exists (isfile is unavailable)" end
	end

	function M.read(name)
		local filename, err = M.filename(name)
		if not filename then return nil, err end
		local source, readErr = readExisting(filename)
		if not source then return nil, readErr or (filename .. " does not exist") end
		if #source > MAX_BYTES then return nil, "plugin is larger than 256 KB" end
		return source, nil, filename
	end

	local function validate(plugin)
		if type(plugin) ~= "table" then return nil, "plugin must return a Plugin table" end
		if type(plugin.PluginName) ~= "string" or util.trim(plugin.PluginName) == "" then return nil, "PluginName must be a nonempty string" end
		if type(plugin.PluginDescription) ~= "string" then return nil, "PluginDescription must be a string" end
		if type(plugin.Commands) ~= "table" or next(plugin.Commands) == nil then return nil, "Commands must contain at least one command" end
		local count, names = 0, {}
		for name, command in pairs(plugin.Commands) do
			count = count + 1
			if count > 100 then return nil, "a plugin may contain at most 100 commands" end
			if type(name) ~= "string" or not name:match("^[%w_%-]+$") then return nil, "command names must be single words" end
			if type(command) ~= "table" or type(command.Function) ~= "function" then return nil, name .. " needs a Function(args, speaker)" end
			if type(command.ListName) ~= "string" or type(command.Description) ~= "string" then return nil, name .. " needs ListName and Description strings" end
			if type(command.Aliases) ~= "table" or not util.isArray(command.Aliases) then return nil, name .. " needs an Aliases array (use {} for none)" end
			for _, alias in ipairs(command.Aliases) do
				if type(alias) ~= "string" or not alias:match("^[%w_%-]+$") then return nil, name .. " has an invalid alias" end
			end
			names[#names + 1] = name
		end
		table.sort(names)
		return names
	end
	local function registered(name)
		for _, plugin in ipairs(iy.value("PluginsTable") or {}) do if plugin == name then return true end end
		return false
	end
	local function commands(name)
		local out = {}
		for _, command in ipairs(iy.cmdsTable() or {}) do
			if command.PLUGIN == name then out[#out + 1] = command.NAME end
		end
		table.sort(out)
		return out
	end
	local function cancelled(ctx) return ctx and ctx.aborted and ctx.aborted() end

	local function write(args, ctx)
		local name, err = M.filename(args.plugin)
		if not name then return nil, err end
		if type(args.source) ~= "string" or #args.source == 0 or #args.source > MAX_BYTES then return nil, "source must contain 1–256000 bytes" end
		if not caps.fn.writefile or not caps.fn.loadstring then return nil, "plugin authoring needs writefile and loadstring" end
		local previous, readErr = readExisting(name)
		if readErr then return nil, readErr end
		if previous ~= nil and args.overwrite ~= true then return nil, name .. " exists; read it first and set overwrite=true to update it" end
		local compiled, chunk, compileErr = pcall(caps.fn.loadstring, args.source, "@" .. name)
		if not compiled or not chunk then return nil, "syntax error: " .. tostring(compiled and compileErr or chunk) end
		local load = args.load ~= false
		local add, remove, scope, fallback, wasRegistered
		if load then
			local ready, why = iy.ensure()
			if not ready then return nil, why end
			add, remove = iy.value("addPlugin"), iy.value("deletePlugin")
			if type(add) ~= "function" or type(iy.value("PluginsTable")) ~= "table" or type(iy.cmdsTable()) ~= "table" then
				return nil, "IY's plugin loader and registries must be exposed to verify a load"
			end
			wasRegistered = registered(name)
			if wasRegistered and type(remove) ~= "function" then return nil, "IY's plugin remover is unavailable; cannot reload this plugin" end
			scope = iy.environment()
			fallback = scope.loadfile
			if type(fallback) ~= "function" then return nil, "IY's loadfile is unavailable" end
			if not setfenv then return nil, "this host cannot bind plugin globals to IY (setfenv is unavailable); use load=false to save only" end
			local bound, why = pcall(setfenv, chunk, scope)
			if not bound then return nil, "could not bind plugin globals: " .. tostring(why) end
		end
		if cancelled(ctx) then return nil, "cancelled before writing the plugin" end
		local function restore()
			if previous ~= nil then
				local ok = pcall(caps.fn.writefile, name, previous)
				return ok and "Previous file restored." or "The previous file could not be restored."
			elseif caps.fn.delfile then
				local ok = pcall(caps.fn.delfile, name)
				return ok and "New file removed." or "The new file could not be removed."
			end
			return "The new file remains on disk."
		end
		local written, writeErr = pcall(caps.fn.writefile, name, args.source)
		if not written then return nil, "could not write " .. name .. ": " .. tostring(writeErr) .. ". " .. restore() end
		local verified, saved = pcall(caps.fn.readfile, name)
		if not verified or saved ~= args.source then return nil, "plugin write could not be verified. " .. restore() end
		if not load then return { plugin = name, bytes = #args.source, loaded = false, validation = "syntax checked; source was not executed" } end

		-- Evaluate once before removing existing commands. IY will consume this same
		-- returned table, preserving globals and closures without rerunning setup.
		local ran, plugin = pcall(chunk)
		if not ran then return nil, "plugin setup failed: " .. tostring(plugin) .. ". " .. restore() end
		local expected, invalid = validate(plugin)
		if not expected then return nil, "invalid plugin: " .. invalid .. ". " .. restore() end
		if cancelled(ctx) then return nil, "cancelled before registering the plugin. " .. restore() end
		local original = rawget(scope, "loadfile")
		rawset(scope, "loadfile", function(path, ...)
			if path == name then return function() return plugin end end
			return fallback(path, ...)
		end)
		local ok, loadErr = pcall(function()
			if wasRegistered then remove(name) end
			add(name)
		end)
		rawset(scope, "loadfile", original)
		local live = commands(name)
		if not ok or not registered(name) or #live ~= #expected then
			return nil, name .. " was saved, but IY did not register all commands: " .. tostring(loadErr or "check IY's plugin error")
		end
		return { plugin = name, name = plugin.PluginName, description = plugin.PluginDescription,
			bytes = #args.source, loaded = true, commands = live, validation = "syntax and plugin table checked" }
	end
	local writing = {}
	function M.write(args, ctx)
		local name, err = M.filename(args.plugin)
		if not name then return nil, err end
		local key = name:lower()
		if writing[key] then return nil, name .. " is already being updated; wait for that call to finish" end
		writing[key] = true
		local ok, result, reason = pcall(write, args, ctx)
		writing[key] = nil
		if not ok then return nil, "plugin authoring failed: " .. tostring(result) end
		return result, reason
	end
	return M
end
