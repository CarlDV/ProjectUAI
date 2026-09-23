-- Adapter for Project-Gravity-02's live desktop/mobile context.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local M = {}

	-- Native names and display ranges from Gravity's Advanced panel. Values are
	-- validated as a complete change before touching the live settings table.
	M.fields = {
		MaxSpeed = { type = "number", minimum = 50, maximum = 2000 },
		Damping = { type = "number", minimum = 0, maximum = 5 },
		Ki = { type = "number", minimum = 0, maximum = 10 },
		AngularDamping = { type = "number", minimum = 0, maximum = 1 },
		VerticalStiffness = { type = "number", minimum = 0.1, maximum = 5 },
		PredictionFactor = { type = "number", minimum = 0, maximum = 500 },
		PredictiveTracking = { type = "boolean" }, Paused = { type = "boolean" },
		Disabled = { type = "boolean" }, HideCoreOnPause = { type = "boolean" },
		AntiFling = { type = "boolean" }, VoidProtection = { type = "boolean" },
		AggressiveClaim = { type = "boolean" }, MaxFidelity = { type = "boolean" },
		["Force Smooth (Lags)"] = { type = "boolean" }, ["Realistic Liftoff"] = { type = "boolean" },
		TimeScale = { type = "number", minimum = -3, maximum = 3 },
		BlendEnabled = { type = "boolean" }, BlendShape = { type = "string", maxLength = 100 },
		BlendWeight = { type = "integer", minimum = 0, maximum = 100 },
		BlendStagger = { type = "integer", minimum = 0, maximum = 100 },
		PreviewEnabled = { type = "boolean" }, PreviewDeviation = { type = "boolean" },
		PreviewCount = { type = "integer", minimum = 4, maximum = 200 },
		SlotMode = { type = "string", enum = { "Claim", "Size Desc", "Size Asc", "Distance", "Shuffle" } },
		TargetParts = { type = "integer", minimum = 0, maximum = 5000 },
		SurplusRule = { type = "string", enum = { "Farthest", "Nearest", "Newest", "Oldest", "Smallest", "Largest" } },
		RuleMinSize = { type = "number", minimum = 0, maximum = 200 },
		RuleMaxSize = { type = "number", minimum = 0, maximum = 500 },
		RuleClaimRadius = { type = "number", minimum = 0, maximum = 2000 },
		RuleName = { type = "string", maxLength = 120 },
		PreserveCollisions = { type = "boolean" }, SimpleMode = { type = "boolean" }, ShowHUD = { type = "boolean" },
		UIScale = { type = "number", minimum = 0.5, maximum = 2 },
		FPSCap = { type = "integer", minimum = 0, maximum = 240 },
		Perf_DisableShadows = { type = "boolean" }, Perf_DisablePostFX = { type = "boolean" },
		Perf_PotatoMaterials = { type = "boolean" }, Perf_HideParticles = { type = "boolean" },
		k3 = { type = "object", description = "Core color, RGB channels from 0 to 255.", properties = {
			r = { type = "integer", minimum = 0, maximum = 255 }, g = { type = "integer", minimum = 0, maximum = 255 },
			b = { type = "integer", minimum = 0, maximum = 255 },
		}, required = { "r", "g", "b" }, additionalProperties = false },
		k5 = { type = "array", description = "Ignore tags (child names checked by Gravity's claim filter). Empty clears the list.",
			items = { type = "string", minLength = 1, maxLength = 100 }, maxItems = 32 },
		PartCtlMultiSelect = { type = "boolean" }, PartCtlEnabled = { type = "boolean" },
		PartCtlMode = { type = "string", enum = { "normal", "pin", "manual", "shape" } },
		PartCtlShape = { type = "string", maxLength = 100 }, PartCtlRide = { type = "boolean" },
		PartCtlPull = { type = "number", minimum = -1, maximum = 200 },
		PartCtlDamping = { type = "number", minimum = -1, maximum = 5 },
		PartCtlSmoothing = { type = "number", minimum = -1, maximum = 1 },
		PartCtlMaxSpeed = { type = "number", minimum = -1, maximum = 2000 },
		PartCtlSurfaceSnap = { type = "boolean" }, PartCtlGridSnap = { type = "number", minimum = 0, maximum = 16 },
		SculptorMultiSelect = { type = "boolean" }, SlingshotManual = { type = "boolean" },
	}
	local nativeFields = { PreserveCollisions = true, UIScale = true, FPSCap = true, ShowHUD = true, k3 = true, k5 = true,
		Perf_DisableShadows = true, Perf_DisablePostFX = true, Perf_PotatoMaterials = true, Perf_HideParticles = true }

	local function live(context)
		return type(context) == "table" and type(context.x1) == "table" and type(context.x2) == "table"
			and type(context.x6) == "table" and not context.x6.torn_down and not context.x6.destroying
			and type(context.x4) == "table" and type(context.get_shape) == "function"
	end

	function M.current()
		-- Resolve every time: UAI may launch first, and Gravity may reload later.
		if caps.fn.getgenv then
			local ok, globals = pcall(caps.fn.getgenv)
			if ok and type(globals) == "table" and live(globals._GRAVITY_CONTEXT) then return globals._GRAVITY_CONTEXT end
		end
		local host = env.context or {}
		if live(host.gravity) then return host.gravity end
		if live(host) then return host end
		return nil, "Project Gravity is not connected. Run the updated Gravity loader, then open its PROJECT UAI button."
	end

	function M.valid(context, ctx)
		return live(context) and M.current() == context and not (ctx and ctx.aborted and ctx.aborted())
	end

	function M.refresh(context, persist)
		local notes = {}
		if persist ~= false and type(context.save_settings) == "function" then
			local ok, err = pcall(context.save_settings)
			if not ok or err == false then notes[#notes + 1] = "Settings changed, but saving failed." end
		end
		if context.controls and type(context.controls.refresh) == "function" then
			local ok, note = pcall(context.controls.refresh)
			if not ok then notes[#notes + 1] = "Settings changed; Gravity's interface could not refresh."
			elseif note then notes[#notes + 1] = note end
		elseif context.x5 and type(context.x5.up) == "function" then
			local ok = pcall(context.x5.up)
			if not ok then notes[#notes + 1] = "Settings changed; reopen Gravity's panel to refresh its controls." end
		end
		return #notes > 0 and table.concat(notes, " ") or nil
	end

	function M.shapeName(context, value)
		local query = util.trim(value)
		if context.x2[query] then return query end
		for name in pairs(context.x2) do if name:lower() == query:lower() then return name end end
		return nil, "Unknown Gravity shape: " .. query .. ". Use gravity_shapes for exact names."
	end

	function M.status()
		local context, err = M.current()
		if not context then return { available = false, message = err } end
		local settings, targets = {}, {}
		for key in pairs(M.fields) do
			local value = context.x1[key]
			if key == "k3" and value then
				value = { r = math.floor(value.R * 255 + 0.5), g = math.floor(value.G * 255 + 0.5), b = math.floor(value.B * 255 + 0.5) }
			end
			settings[key] = value
		end
		for _, player in ipairs(context.x1.Targets or {}) do
			targets[#targets + 1] = { name = player.Name, userId = player.UserId }
		end
		local x1, x6 = context.x1, context.x6
		local bindings = context.x8 or {}
		return { available = true, platform = context.is_mobile and "mobile" or "desktop", shape = x1.k6,
			running = x6.o == true, heldParts = x6.n or 0, settings = settings, targets = targets,
			isLaunching = x1.IsLaunching == true, keybinds = x1.Keybinds,
			capabilities = { partControl = type(x6.pc_assign) == "function" and (tonumber(x6.pc_api_version) or 0) >= 1, keybindings = type(bindings.rebind_all) == "function",
				runtimeSettings = context.controls ~= nil, fpsCap = context.controls and context.controls.fps_cap == true or false,
				resetSettings = context.controls ~= nil, favorites = type(context.favorites) == "table" },
			targetMode = x1.PI_All and "all" or (x1.AnchorSelf and "self" or (x1.TgtActive and "players" or "none")) }
	end

	function M.controlSpec(control)
		local spec = { key = control.Key, name = control.Name, kind = control.Type, description = control.Desc }
		if control.Type == "Slider" then
			local div = tonumber(control.Div) or 1
			if div <= 0 then return nil, "invalid slider divisor" end
			local max = tonumber(control.Max)
			if not max or not tonumber(control.Min) then return nil, "slider has no numeric range" end
			if tostring(control.Name):lower():find("speed", 1, true) and not control.ExactMax then max = max + 300 end
			spec.minimum, spec.maximum, spec.displayDivisor = control.Min / div, max / div, div
			spec.integerDisplay = control.IntOnly == true
		elseif control.Type == "TextBox" then spec.maxLength = control.MaxChars or 200 end
		return spec
	end

	function M.shapes(args)
		local context, err = M.current()
		if not context then return nil, err end
		if args.name then
			local name, why = M.shapeName(context, args.name)
			if not name then return nil, why end
			local mod = context.get_shape(name)
			if not M.valid(context) then return nil, "Gravity was unloaded or replaced while loading the shape" end
			if type(mod) ~= "table" then return nil, "Gravity could not load " .. name end
			local controls = {}
			local offset, limit = args.offset or 1, args.limit or 12
			local all = mod.Controls or {}
			for index = offset, math.min(#all, offset + limit - 1) do
				local control = all[index]
				local spec = M.controlSpec(control)
				if spec then
					if control.Type ~= "Button" then spec.value = context.x2[name][control.Key] end
					controls[#controls + 1] = spec
				end
			end
			return { name = name, active = context.x1.k6 == name, favorite = context.favorites and context.favorites[name] == true or false, controls = controls, totalControls = #all,
				nextOffset = offset + limit <= #all and offset + limit or nil,
				continuousMotion = mod.ContinuousMotion == true, noBlend = mod.NoBlend == true,
				testing = mod.Testing == true, mobileControls = type(mod.MobileControls) == "table" }
		end
		local names, results = {}, {}
		for name in pairs(context.x2) do
			if name:lower():find(util.trim(args.query):lower(), 1, true) then names[#names + 1] = name end
		end
		table.sort(names)
		local offset, limit = args.offset or 1, args.limit or 25
		for index = offset, math.min(#names, offset + limit - 1) do
			local name = names[index]
			results[#results + 1] = { name = name, active = name == context.x1.k6,
				favorite = context.favorites and context.favorites[name] == true or false,
				localPlugin = context.local_shapes and context.local_shapes[name] ~= nil }
		end
		return { shapes = results, total = #names, nextOffset = offset + #results <= #names and offset + #results or nil }
	end

	local function scalar(value, spec)
		if spec.type == "object" then
			if type(value) ~= "table" then return false end
			for _, key in ipairs(spec.required or {}) do if value[key] == nil then return false end end
			for key, item in pairs(value) do if not spec.properties[key] or not scalar(item, spec.properties[key]) then return false end end
			return true
		elseif spec.type == "array" then
			if type(value) ~= "table" or #value > spec.maxItems then return false end
			for key, item in pairs(value) do
				if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value or not scalar(item, spec.items) then return false end
			end
			return true
		end
		if spec.type == "number" or spec.type == "integer" then
			if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return false end
			if spec.type == "integer" and value % 1 ~= 0 then return false end
			return value >= spec.minimum and value <= spec.maximum
		end
		if type(value) ~= spec.type then return false end
		if spec.maxLength and #value > spec.maxLength then return false end
		if spec.minLength and #value < spec.minLength then return false end
		if spec.enum then for _, option in ipairs(spec.enum) do if value == option then return true end end; return false end
		return true
	end

	function M.configure(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		local changes = args.values
		if type(changes) ~= "table" or next(changes) == nil then return nil, "provide settings in values" end
		local prepared, previous = {}, {}
		for key, value in pairs(changes) do
			local spec = M.fields[key]
			if not spec or not scalar(value, spec) then return nil, "invalid Gravity setting or value: " .. tostring(key) end
			if context.x1[key] == nil then return nil, "this Gravity version does not support " .. key end
			if nativeFields[key] and (not context.controls or type(context.controls.apply_settings) ~= "function") then
				return nil, "Update and reload Gravity to change " .. key .. " through its native settings handler"
			end
			if key == "FPSCap" and not context.controls.fps_cap then return nil, "This executor does not support setfpscap" end
			if key == "BlendShape" or key == "PartCtlShape" then
				local name, why = M.shapeName(context, value)
				if not name then return nil, why end
				if key == "PartCtlShape" and name == "Sculptor" then return nil, "Sculptor cannot drive a Part Control shape override" end
				value = name
			end
			prepared[key] = value
			previous[key] = context.x1[key]
		end
		if prepared.Disabled ~= nil and type(context.x4.apply_disabled) ~= "function" then return nil, "Gravity's disable handler is unavailable" end
		if not M.valid(context, ctx) then return nil, "Gravity change cancelled" end
		local tags = context.x1.k5
		local function assign(values, converted)
			for key, value in pairs(values) do
				if key == "k5" then
					for index in pairs(tags) do tags[index] = nil end
					for index, tag in ipairs(value) do tags[index] = tag end
				elseif key ~= "Disabled" then
					context.x1[key] = key == "k3" and not converted and Color3.fromRGB(value.r, value.g, value.b) or value
				end
			end
			if values.Disabled ~= nil then context.x4.apply_disabled(values.Disabled) end
		end
		if prepared.k5 then previous.k5 = {}; for index, tag in ipairs(tags) do previous.k5[index] = tag end end
		local ok, problem = pcall(function()
			assign(prepared, false)
			if context.controls then context.controls.apply_settings(prepared)
			else
				if prepared.BlendShape then context.x6.bl_failed = nil end
				if (prepared.Paused ~= nil or prepared.HideCoreOnPause ~= nil) and context.x4.refresh_core_visual then context.x4.refresh_core_visual() end
				if prepared.PreviewEnabled == false and context.x4.preview_clear then context.x4.preview_clear() end
				if (prepared.RuleMinSize or prepared.RuleMaxSize or prepared.RuleName) and context.x4.recheck_rules then context.x4.recheck_rules() end
				if prepared.TargetParts and context.x4.enforce_part_cap then context.x4.enforce_part_cap() end
			end
		end)
		if not ok then
			local restored = pcall(function() assign(previous, true); if context.controls then context.controls.apply_settings(previous) end end)
			return nil, "Gravity settings failed: " .. tostring(problem) .. (restored and "; previous settings restored" or "; restoration was incomplete, inspect gravity_status")
		end
		return { changed = prepared, persistence = args.persist == false and "session only" or "save requested",
			note = M.refresh(context, args.persist) }
	end

	function M.control(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		if not M.valid(context, ctx) then return nil, "Gravity action cancelled" end
		local action = args.action
		if action == "reset_settings" then
			if not context.controls or type(context.controls.reset) ~= "function" then return nil, "Update and reload Gravity to reset native settings" end
			local note = context.controls.reset(args.persist)
			if not M.valid(context, ctx) then return nil, "Gravity was unloaded or the reset was cancelled" end
			return { action = action, note = note, shape = context.x1.k6 }
		end
		if action == "launch" or action == "charge" then
			if context.x1.k6 ~= "Slingshot" or not context.x1.SlingshotManual then return nil, "Select Slingshot and enable SlingshotManual first" end
			context.x1.IsLaunching = action == "launch"
			return { action = action, isLaunching = context.x1.IsLaunching, note = M.refresh(context, false) }
		end
		if action == "pause" or action == "resume" then return M.configure({ values = { Paused = action == "pause" } }, ctx) end
		if action == "disable" or action == "enable" then return M.configure({ values = { Disabled = action == "disable" } }, ctx) end
		local method = ({ start = "f4", recenter = "f4", stop = "f5", reroll = "reroll_seeds" })[action]
		if not method or type(context.x4[method]) ~= "function" then return nil, "unsupported Gravity action" end
		local position
		if method == "f4" then
			if args.position then
				for _, key in ipairs({ "x", "y", "z" }) do
					local value = args.position[key]
					if type(value) ~= "number" or value ~= value or math.abs(value) > 10000000 then return nil, "invalid core position" end
				end
				position = Vector3.new(args.position.x, args.position.y, args.position.z)
			else
				local character = env.plr and env.plr.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not root then return nil, "provide a position; your character has no HumanoidRootPart" end
				position = root.Position
			end
		end
		context.x4[method](position)
		return { action = action, running = context.x6.o == true, note = M.refresh(context, action == "reroll") }
	end

	function M.changeShape(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		local name, why = M.shapeName(context, args.shape or context.x1.k6)
		if not name then return nil, why end
		local mod = context.get_shape(name)
		if type(mod) ~= "table" then return nil, "Gravity could not load " .. name end
		if not M.valid(context, ctx) then return nil, "Gravity was unloaded or the action was cancelled" end
		if args.action == "select" then
			if type(context.x4.switch_shape) ~= "function" or context.x4.switch_shape(name, args.persist) ~= true then return nil, "Gravity could not switch to " .. name end
			return { selected = name }
		end
		local controls = {}
		for _, control in ipairs(mod.Controls or {}) do controls[control.Key or control.Name] = control end
		if args.action == "button" then
			local control = controls[args.button]
			if not control or control.Type ~= "Button" then return nil, "unknown shape button; inspect gravity_shapes first" end
			if context.x1.k6 ~= name then return nil, "select the shape before invoking its button" end
			if not context.plugin_controls or type(context.plugin_controls.activate) ~= "function" then return nil, "Gravity's button handler is unavailable" end
			local ok, message = context.plugin_controls.activate(control, context.x2[name], context.x6, context.x1)
			if not ok then return nil, tostring(message) end
			return { shape = name, button = args.button, activated = true }
		end
		if args.action ~= "configure" or type(args.values) ~= "table" or next(args.values) == nil then return nil, "provide shape control values" end
		local prepared = {}
		for key, value in pairs(args.values) do
			local control = controls[key]
			if not control or control.Type == "Button" then return nil, "unknown setting or action-only key: " .. tostring(key) end
			local spec = M.controlSpec(control)
			if not spec then return nil, "invalid control definition: " .. tostring(key) end
			if control.Type == "Slider" then
				spec.type = "number"
				if not scalar(value, spec) then return nil, "out-of-range slider: " .. key end
				if spec.integerDisplay then value = math.floor(value * spec.displayDivisor + 0.5) / spec.displayDivisor end
			elseif control.Type == "Toggle" then
				if type(value) ~= "boolean" then return nil, key .. " needs a boolean" end
			elseif control.Type == "TextBox" then
				if type(value) ~= "string" or #value > spec.maxLength then return nil, key .. " needs text within its length limit" end
			else return nil, "unsupported control type: " .. tostring(control.Type) end
			prepared[key] = value
		end
		if not M.valid(context, ctx) then return nil, "Gravity change cancelled" end
		for key, value in pairs(prepared) do context.x2[name][key] = value end
		return { shape = name, changed = prepared, note = M.refresh(context, args.persist) }
	end

	function M.keybind(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		local bindings, kb = context.x8, context.x1.Keybinds
		if not bindings or type(bindings.rebind_all) ~= "function" or type(bindings.key_from_name) ~= "function"
			or type(bindings.find_conflict) ~= "function" or type(kb) ~= "table" then
			return nil, "Update and reload Gravity to edit native keybindings"
		end
		if (args.action ~= nil) == (args.shape ~= nil) then return nil, "provide one core action or one shape" end
		local target, id, shape = args.action, args.action, nil
		if args.shape then
			shape, err = M.shapeName(context, args.shape)
			if not shape then return nil, err end
			target, id = shape, "shape:" .. shape
		else
			local found = false
			for _, entry in ipairs(bindings.core_actions or {}) do if entry.id == target then found = true; break end end
			if not found then return nil, "unknown core keybinding" end
		end
		local key = args.key
		if type(key) ~= "string" or (key ~= "" and not bindings.key_from_name(key)) then return nil, "invalid Roblox KeyCode name; use an empty string to unbind" end
		local conflict = bindings.find_conflict(key, id)
		if conflict then return nil, "Key " .. key .. " is already bound to " .. tostring(conflict) .. "; clear that binding first" end
		if not M.valid(context, ctx) then return nil, "Gravity keybinding cancelled" end
		if shape then kb.Shapes = kb.Shapes or {} end
		local destination = shape and kb.Shapes or kb
		local before = destination[target]
		destination[target] = key
		local ok, why = pcall(bindings.rebind_all)
		if not ok then
			destination[target] = before
			pcall(bindings.rebind_all)
			return nil, "Gravity could not rebind keys: " .. tostring(why)
		end
		return { target = id, key = key, unbound = key == "", note = M.refresh(context, args.persist) }
	end

	function M.favorite(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		if type(context.favorites) ~= "table" then return nil, "Gravity favorites are unavailable" end
		local names = {}
		if args.action == "add" or args.action == "remove" then
			if type(args.shapes) ~= "table" or #args.shapes == 0 or #args.shapes > 50 then return nil, "provide 1 to 50 shape names" end
			for _, value in ipairs(args.shapes) do
				local name, why = M.shapeName(context, value)
				if not name then return nil, why end
				names[#names + 1] = name
			end
		elseif args.action ~= "clear" then return nil, "unknown favorite action" end
		if not M.valid(context, ctx) then return nil, "Gravity favorite change cancelled" end
		if args.action == "clear" then
			for name in pairs(context.favorites) do context.favorites[name] = nil end
		else
			for _, name in ipairs(names) do context.favorites[name] = args.action == "add" or nil end
		end
		local note
		if args.persist ~= false and context.save_favs then
			local ok, saved = pcall(context.save_favs)
			if not ok or saved == false then note = "Favorites changed, but saving failed." end
		end
		if context.x6.populate_modes then pcall(context.x6.populate_modes, context.x6.mode_filter or "") end
		return { action = args.action, shapes = names, note = note }
	end

	function M.target(args, ctx)
		local context, err = M.current()
		if not context then return nil, err end
		local mode, found = args.mode, nil
		if mode == "add" or mode == "remove" then
			local query, matches = util.trim(args.player):lower():gsub("^@", ""), {}
			if query == "" then return nil, "provide a player username or user ID" end
			for _, player in ipairs(env.players:GetPlayers()) do
				if player.Name:lower() == query or tostring(player.UserId) == query then found = player; break end
				if player.Name:lower():find(query, 1, true) == 1 or player.DisplayName:lower() == query then matches[#matches + 1] = player end
			end
			if not found and #matches == 1 then found = matches[1] end
			if not found then return nil, #matches > 1 and "ambiguous player; use the exact username or user ID" or "player not found" end
		elseif mode ~= "clear" and mode ~= "self" and mode ~= "all" then return nil, "unknown targeting mode" end
		if not M.valid(context, ctx) then return nil, "Gravity targeting cancelled" end
		local x1 = context.x1
		x1.Targets = x1.Targets or {}
		if mode == "clear" or mode == "self" or mode == "all" then
			for index = #x1.Targets, 1, -1 do table.remove(x1.Targets, index) end
			x1.AnchorSelf, x1.PI_All, x1.TgtActive = mode == "self", mode == "all", false
		else
			local index
			for position, player in ipairs(x1.Targets) do if player == found then index = position; break end end
			if mode == "add" and not index then x1.Targets[#x1.Targets + 1] = found end
			if mode == "remove" and index then table.remove(x1.Targets, index) end
			if mode == "add" then x1.AnchorSelf, x1.PI_All = false, false end
			x1.TgtActive = #x1.Targets > 0
		end
		return { mode = mode, player = found and found.Name, note = M.refresh(context, false) }
	end

	return M
end
