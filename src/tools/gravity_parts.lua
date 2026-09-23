-- Part identity comes from Gravity's held-record IDs, never ambiguous paths.
return function(env)
	local gravity = env.require("runtime/gravity")
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local M = {}
	local scopes, serial = setmetatable({}, { __mode = "k" }), 0
	local MAX_SELECT = 512 -- Gravity's native selection/highlight ceiling.
	M.physics = {
		k10 = { type = "number", minimum = 0, maximum = 200, description = "Pull" },
		Damping = { type = "number", minimum = 0, maximum = 5 },
		k8 = { type = "number", minimum = 0, maximum = 1, description = "Smoothing" },
		MaxSpeed = { type = "number", minimum = 0, maximum = 2000 },
	}

	local function scope(context)
		if context.session_id then return tostring(context.session_id) end
		if not scopes[context] then serial = serial + 1; scopes[context] = "session" .. serial end
		return scopes[context]
	end
	local function overridden(d) return d.pc_mode ~= nil or d.pc_ride == true or d.pc_phys ~= nil end
	local function vector(v) return v and { x = v.X, y = v.Y, z = v.Z } or nil end
	local function position(v)
		if type(v) ~= "table" then return nil end
		for _, key in ipairs({ "x", "y", "z" }) do
			if type(v[key]) ~= "number" or v[key] ~= v[key] or math.abs(v[key]) > 10000000 then return nil end
		end
		return Vector3.new(v.x, v.y, v.z)
	end
	local function held(context)
		local entries, ids = {}, {}
		local prefix = scope(context) .. ":"
		for part, d in pairs(context.x6.a or {}) do
			if d.id ~= nil then
				local entry = { part = part, record = d, id = prefix .. tostring(d.id) }
				entries[#entries + 1], ids[entry.id] = entry, entry
			end
		end
		table.sort(entries, function(a, b) return a.record.id < b.record.id end)
		return entries, ids
	end
	local function selected(context, entries)
		local list, set = {}, {}
		for _, entry in ipairs(entries) do
			if (context.x6.pc_selected or {})[entry.part] then list[#list + 1] = entry; set[entry.part] = entry.record end
		end
		return list, set
	end
	local function physical(value)
		if type(value) ~= "table" then return nil, "physics must be an object; an empty object restores inheritance" end
		local prepared = {}
		for key, number in pairs(value) do
			local spec = M.physics[key]
			if not spec or type(number) ~= "number" or number ~= number or number < spec.minimum or number > spec.maximum then
				return nil, "invalid per-part physics setting: " .. tostring(key)
			end
			prepared[key] = number
		end
		return prepared
	end

	function M.list(args)
		local context, err = gravity.current()
		if not context then return nil, err end
		local matches, selectionCount, overrideCount = {}, 0, 0
		local entries = held(context)
		for _, entry in ipairs(entries) do
			local picked, override = (context.x6.pc_selected or {})[entry.part] == true, overridden(entry.record)
			if picked then selectionCount = selectionCount + 1 end
			if override then overrideCount = overrideCount + 1 end
			if (args.filter ~= "selected" or picked) and (args.filter ~= "overridden" or override)
				and tostring(entry.part.Name):lower():find(util.trim(args.query):lower(), 1, true) then matches[#matches + 1] = entry end
		end
		local offset, limit, results = args.offset or 1, args.limit or 10, {}
		for index = offset, math.min(#matches, offset + limit - 1) do
			local e, d = matches[index], matches[index].record
			results[#results + 1] = { id = e.id, name = e.part.Name, path = util.truncate(H.pathOf(e.part), 300),
				position = vector(e.part.Position), target = vector(d.pc_target), slot = d.slot,
				selected = (context.x6.pc_selected or {})[e.part] == true, mode = d.pc_mode or "normal",
				shape = d.pc_shape, ride = d.pc_ride == true, physics = d.pc_phys }
		end
		return { parts = results, total = #matches, held = #entries, selected = selectionCount, overridden = overrideCount,
			nextOffset = offset + #results <= #matches and offset + #results or nil }
	end

	function M.control(args, ctx)
		local context, err = gravity.current()
		if not context then return nil, err end
		local x6, action = context.x6, args.action
		if (tonumber(x6.pc_api_version) or 0) < 1 then return nil, "Update and reload Gravity to use guarded native Part Control" end
		for _, method in ipairs({ "pc_assign", "pc_select", "pc_deselect", "pc_clear", "pc_release_all", "pc_set_ride", "pc_set_phys" }) do
			if type(x6[method]) ~= "function" then return nil, "Gravity Part Control is unavailable; update and reload Gravity" end
		end
		if not gravity.valid(context, ctx) then return nil, "Gravity part action cancelled" end
		local entries, ids = held(context)
		local selection, snapshot = selected(context, entries)
		local function guard()
			if not gravity.valid(context, ctx) then return false end
			for part, d in pairs(snapshot) do if not x6.pc_selected[part] or x6.a[part] ~= d then return false end end
			for part in pairs(x6.pc_selected) do if x6.a[part] and not snapshot[part] then return false end end
			return true
		end
		local idAction = action == "select" or action == "add" or action == "deselect"
		if args.ids ~= nil and not idAction then return nil, "ids apply only to select/add/deselect; other actions use the current selection" end
		if idAction or action == "select_all" or action == "select_overridden" or action == "invert" then
			local desired, targets, capped = {}, {}, false
			if action == "add" or action == "deselect" then for part in pairs(snapshot) do desired[part] = true end end
			if idAction then
				if type(args.ids) ~= "table" or #args.ids == 0 or #args.ids > MAX_SELECT then return nil, "provide 1 to 512 IDs from gravity_parts" end
				for _, id in ipairs(args.ids) do
					local e = ids[id]
					if not e then return nil, "part is no longer held or belongs to another session: " .. tostring(id) .. "; read gravity_parts again" end
					desired[e.part] = action ~= "deselect" or nil
				end
			else
				for _, e in ipairs(entries) do
					if action == "select_all" or (action == "select_overridden" and overridden(e.record)) or (action == "invert" and not snapshot[e.part]) then
						desired[e.part] = true
					end
				end
			end
			for _, e in ipairs(entries) do if desired[e.part] then targets[#targets + 1] = e end end
			if #targets > MAX_SELECT and idAction then return nil, "selection would exceed Gravity's 512-part limit" end
			if #targets > MAX_SELECT then capped = true end
			if not guard() then return nil, "Gravity selection changed; inspect it before retrying" end
			-- Build a replacement using the native selection methods, preserving
			-- their highlight and UI notifications without releasing overrides.
			x6.pc_clear()
			for index = 1, math.min(#targets, MAX_SELECT) do x6.pc_select(targets[index].part, true) end
			return { action = action, selected = math.min(#targets, MAX_SELECT), capped = capped }
		end
		if action == "clear" then x6.pc_clear(); return { action = action, selected = 0 } end
		if action == "release_all" then return { action = action, affected = x6.pc_release_all() } end
		if #selection == 0 then return nil, "no held parts are selected; use gravity_parts and gravity_part_control(select) first" end
		if #selection > MAX_SELECT then return nil, "selection exceeds Gravity's 512-part limit" end
		local affected, opts = 0, { guard = guard }
		if args.physics ~= nil then opts.phys, err = physical(args.physics); if not opts.phys then return nil, err end end
		if opts.phys and next(opts.phys) == nil then opts.phys = false end
		if args.ride ~= nil then
			if type(args.ride) ~= "boolean" then return nil, "ride must be a boolean" end
			opts.ride = args.ride
		end
		if action == "assign" then
			if args.mode ~= "pin" and args.mode ~= "manual" and args.mode ~= "shape" and args.mode ~= "normal" then return nil, "provide a valid assignment mode" end
			if args.mode == "shape" then
				opts.shape, err = gravity.shapeName(context, args.shape)
				if not opts.shape then return nil, err end
				if opts.shape == "Sculptor" then return nil, "Sculptor cannot drive a Part Control override" end
			end
			if args.position then
				if args.mode ~= "pin" and args.mode ~= "manual" then return nil, "a target position requires pin or manual mode" end
				opts.target = position(args.position)
				if not opts.target then return nil, "invalid part target position" end
			end
			affected = x6.pc_assign(args.mode == "normal" and nil or args.mode, opts)
		elseif action == "move" then
			if (args.position ~= nil) == (args.offset ~= nil) then return nil, "provide a destination for the group's center or a relative offset" end
			local move = position(args.position or args.offset)
			if not move then return nil, "invalid movement vector" end
			local targets, center = {}, Vector3.new(0, 0, 0)
			for _, e in ipairs(selection) do
				local d = e.record
				local base = ((d.pc_mode == "pin" or d.pc_mode == "manual") and d.pc_target) or e.part.Position
				targets[e.part], center = base, center + base
			end
			local delta = args.offset and move or move - center / #selection
			for part, base in pairs(targets) do
				targets[part] = base + delta
				if not position(vector(targets[part])) then return nil, "movement would exceed the world coordinate range" end
			end
			affected = x6.pc_assign("manual", opts)
			if not guard() then return nil, "Gravity selection changed during movement; inspect gravity_parts" end
			for part, target in pairs(targets) do x6.a[part].pc_target = target end
		elseif action == "ride" then
			if args.ride == nil then return nil, "provide ride=true or ride=false" end
			affected = x6.pc_set_ride(args.ride)
		elseif action == "physics" then
			if args.physics == nil then return nil, "provide physics; an empty object restores inheritance" end
			affected = x6.pc_set_phys(opts.phys or nil)
		elseif action == "release" then affected = x6.pc_assign(nil, opts)
		else return nil, "unknown Part Control action" end
		if not guard() then return nil, "Gravity session or selection changed during the action; inspect gravity_parts before retrying" end
		if affected == 0 then return nil, "Gravity did not apply the override; check that the shape loaded successfully" end
		return { action = action, affected = affected, selected = #selection }
	end
	return M
end
