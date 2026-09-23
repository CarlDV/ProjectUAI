-- Real GravityShapes files and validated registration in the current runtime.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local caps = env.require("runtime/caps")
	local gravity = env.require("runtime/gravity")
	local execution = env.require("tools/execution")
	local M = {}
	local MAX_BYTES = 2 * 1024 * 1024
	local function stopped(ctx) return ctx and ctx.aborted and ctx.aborted() end
	local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end

	function M.filename(value)
		local name = util.trim(value):gsub("%.[Ll][Uu][Aa]$", "")
		local safe = fsx.sanitise(name)
		if not safe or safe ~= name or name:find("[/\\]") or #name > 100 then return nil, "use a plain shape name, without a path" end
		local stem = name:lower():match("^[^.]+")
		if stem == "con" or stem == "prn" or stem == "aux" or stem == "nul" or stem:match("^com%d$") or stem:match("^lpt%d$") then return nil, "reserved shape filename" end
		return name, "GravityShapes/" .. name .. ".lua"
	end

	local function localPath(context, name, fallback)
		local path = context and context.local_shapes and context.local_shapes[name]
		if not path then return fallback end
		-- Executor listings may include their physical workspace prefix. Read only
		-- the canonical GravityShapes child, never an arbitrary host path.
		path = tostring(path):gsub("\\", "/")
		path = path:match("^GravityShapes/[^/]+$") or path:match("/+(GravityShapes/[^/]+)$")
		if not path or not fsx.sanitise(path) then return nil, "shape source is outside GravityShapes/" end
		return path
	end

	local function existing(path)
		if not caps.fn.isfile then return nil, "isfile is required to check existing shape files" end
		local ok, found = pcall(caps.fn.isfile, path)
		if not ok then return nil, "could not check " .. path end
		if not found then return nil end
		local source, err = fsx.read(path, { raw = true })
		if source == nil then return nil, err end
		return source
	end

	function M.read(args, ctx)
		local name, path = M.filename(args.plugin)
		if not name then return nil, path end
		local context = gravity.current()
		if context then name = gravity.shapeName(context, name) or name end
		local why
		path, why = localPath(context, name, "GravityShapes/" .. name .. ".lua")
		if not path then return nil, why end
		if (context and context.local_shapes and context.local_shapes[name]) or (caps.fn.isfile and fsx.exists(path, { raw = true })) then
			local source, err = fsx.read(path, { raw = true })
			return source, err, path
		end
		if args.origin == "local" then return nil, "local shape file does not exist" end
		local url = "https://raw.githubusercontent.com/CarlDV/Project-Gravity-02/main/shapes/" .. util.urlEncode(name) .. ".lua"
		local res, err = env.require("net/http").send({ url = url, method = "GET", identity = "browser", attempts = 1,
			aborted = ctx and ctx.aborted })
		if not res or res.status ~= 200 then return nil, "could not read the official shape: " .. tostring(err or (res and res.status)) end
		if #res.body > MAX_BYTES then return nil, "shape source exceeds 2 MiB" end
		return res.body, nil, "official shapes/" .. name .. ".lua"
	end

	local function validate(mod)
		if type(mod) ~= "table" or type(mod.f2) ~= "function" then return nil, "module must return a table with f2(p, cen, d, t, c, x1, x6, x9)" end
		for _, key in ipairs({ "px", "cleanup" }) do if mod[key] ~= nil and type(mod[key]) ~= "function" then return nil, key .. " must be a function" end end
		if type(mod.Controls) ~= "table" or not util.isArray(mod.Controls) or #mod.Controls > 100 then return nil, "Controls must be an array of at most 100 controls" end
		local defaults, keys = {}, {}
		for _, control in ipairs(mod.Controls) do
			if type(control) ~= "table" or type(control.Name) ~= "string" or util.trim(control.Name) == "" then return nil, "each control needs a Name" end
			local key = control.Key or (control.Type == "Button" and control.Name)
			if type(key) ~= "string" or key == "" or keys[key] then return nil, "control keys must be nonempty and unique" end
			keys[key] = true
			if control.Type == "Button" then
				if type(control.Callback) ~= "function" then return nil, key .. " needs Callback(c, x6, x1)" end
			elseif control.Type == "Slider" then
				local div = control.Div or 1
				if not finite(control.Min) or not finite(control.Max) or not finite(div) or div <= 0 or control.Min > control.Max then return nil, key .. " has an invalid slider range" end
				local spec = gravity.controlSpec(control)
				local value = control.Default == nil and control.Min / div or control.Default
				if not finite(value) or value < spec.minimum or value > spec.maximum then return nil, key .. " has an invalid default" end
				defaults[key] = value
			elseif control.Type == "Toggle" then
				if control.Default ~= nil and type(control.Default) ~= "boolean" then return nil, key .. " needs a boolean default" end
				defaults[key] = control.Default == true
			elseif control.Type == "TextBox" then
				if control.MaxChars ~= nil and (not finite(control.MaxChars) or control.MaxChars < 1 or control.MaxChars % 1 ~= 0) then return nil, key .. " has an invalid text limit" end
				if control.Default ~= nil and type(control.Default) ~= "string" then return nil, key .. " needs a text default" end
				if #(control.Default or "") > (control.MaxChars or 200) then return nil, key .. " has an oversized default" end
				defaults[key] = control.Default or ""
			else return nil, "unsupported control type: " .. tostring(control.Type) end
		end
		return defaults
	end

	local writing = {}
	local function write(args, ctx)
		local name, path = M.filename(args.plugin)
		if not name then return nil, path end
		local context, why = gravity.current()
		if context then name = gravity.shapeName(context, name) or name end
		local pathErr
		path, pathErr = localPath(context, name, "GravityShapes/" .. name .. ".lua")
		if not path then return nil, pathErr end
		local source = args.source
		if args.path then
			if source ~= nil then return nil, "provide source or path, not both" end
			local err
			source, err = fsx.readUser(args.path)
			if source == nil then return nil, err end
		end
		if type(source) ~= "string" or #source == 0 or #source > MAX_BYTES then return nil, "source must contain 1 byte to 2 MiB" end
		local oldSource, readErr = existing(path)
		if readErr then return nil, readErr end
		if (oldSource or (context and context.x2[name])) and args.overwrite ~= true then return nil, "shape already exists; read it first and set overwrite=true" end
		local checked = execution.check(source)
		if not checked.ok then return nil, checked.text end
		local mod, defaults, previous
		if args.load ~= false then
			if not context then return nil, why end
			if type(context.loaded_shapes) ~= "table" or type(context.local_shapes) ~= "table" then return nil, "Gravity's shape registries are unavailable" end
			previous = context.loaded_shapes[name]
			if previous and context.x6.pc_mods and context.x6.pc_mods[previous] then return nil, "release this shape's Part Control overrides before reloading it" end
			local result = execution.run({ code = source, timeout = 10 }, ctx, function(value) mod = value end)
			if not result.ok then return nil, "shape setup failed: " .. result.text end
			defaults, why = validate(mod)
			if not defaults then return nil, "invalid shape: " .. why end
			if not gravity.valid(context, ctx) then return nil, "Gravity was replaced or the upload was cancelled before registration" end
		end
		if stopped(ctx) then return nil, "shape write cancelled" end
		if args.load ~= false and context.loaded_shapes[name] ~= previous then return nil, "loaded shape changed during setup; inspect it before retrying" end
		-- Check again after potentially yielding setup; never overwrite a newer edit.
		local current, err = existing(path)
		if err or current ~= oldSource then return nil, err or "shape file changed during setup; read it again" end
		local ok, writeErr = fsx.write(path, source, { raw = true })
		local verified = ok and fsx.read(path, { raw = true }) == source
		local function restore()
			if oldSource ~= nil then
				return fsx.write(path, oldSource, { raw = true }) and fsx.read(path, { raw = true }) == oldSource
			end
			return fsx.delete(path, { raw = true })
		end
		if not verified then
			local restored = restore()
			return nil, "shape write failed verification: " .. tostring(writeErr) .. (restored and "; previous file restored" or "; inspect the file before retrying")
		end
		if args.load == false then return { plugin = name, path = path, bytes = #source, loaded = false, validation = "syntax checked; source not executed" } end
		if not gravity.valid(context, ctx) then restore(); return nil, "Gravity was replaced or the upload was cancelled" end
		if previous and type(previous.cleanup) == "function" then
			local cleaned, cleanupErr = pcall(previous.cleanup, context.x6, context.x1)
			if not cleaned then restore(); return nil, "previous shape cleanup failed: " .. tostring(cleanupErr) end
		end
		if not gravity.valid(context, ctx) then restore(); return nil, "Gravity was replaced or the upload was cancelled during cleanup" end
		local values = context.x2[name] or {}
		-- Retain values for compatible keys; remove old/button keys without replacing
		-- the table that the physics runtime and UI may already reference.
		for key in pairs(values) do if defaults[key] == nil or type(values[key]) ~= type(defaults[key]) then values[key] = nil end end
		for key, value in pairs(defaults) do if values[key] == nil then values[key] = value end end
		for _, control in ipairs(mod.Controls) do
			local key = control.Key
			if control.Type == "Slider" then
				local spec = gravity.controlSpec(control)
				values[key] = math.max(spec.minimum, math.min(spec.maximum, values[key]))
				if spec.integerDisplay then values[key] = math.floor(values[key] * spec.displayDivisor + 0.5) / spec.displayDivisor end
			elseif control.Type == "TextBox" and #values[key] > (control.MaxChars or 200) then
				local last = control.MaxChars or 200
				while last > 0 and values[key]:byte(last + 1) >= 128 and values[key]:byte(last + 1) < 192 do last = last - 1 end
				values[key] = values[key]:sub(1, last)
			end
		end
		context.x2[name], context.loaded_shapes[name], context.local_shapes[name] = values, mod, path
		if context.x1.k6 == name and context.x4.switch_shape then context.x4.switch_shape(name) end
		return { plugin = name, path = path, bytes = #source, loaded = true, selected = context.x1.k6 == name,
			note = gravity.refresh(context, true) }
	end

	function M.write(args, ctx)
		local name, err = M.filename(args.plugin)
		if not name then return nil, err end
		local key = name:lower()
		if writing[key] then return nil, "this shape is already being written" end
		writing[key] = true
		local ok, result, why = pcall(write, args, ctx)
		writing[key] = nil
		if not ok then return nil, tostring(result) end
		return result, why
	end
	return M
end
