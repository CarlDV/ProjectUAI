-- Session identity is independent of mutable names/paths. Ordinary references are weak.
return function(env)
	local clock = env.require("runtime/clock")
	local paths = env.require("runtime/instance_paths")
	local M = {}
	local ok, guid = pcall(function() return env.hs:GenerateGUID(false) end)
	M.epoch = ok and guid or (tostring(clock.ms()) .. ":" .. math.random(100000, 999999))
	local byObject = setmetatable({}, { __mode = "k" })
	local byId = setmetatable({}, { __mode = "v" })
	local pins, serial, alive, watched = {}, 0, true, {}
	local function watch(instance, entry)
		if entry.connection then return true end
		while #watched >= 2048 do
			local index
			for i, candidate in ipairs(watched) do if (candidate.pinCount or 0) == 0 then index = i; break end end
			if not index then return false end
			local old = table.remove(watched, index)
			if old.connection then pcall(function() old.connection:Disconnect() end) end
			-- Losing an observer does not change the identity of a live object.
			-- Detached objects without an observer require explicit rediscovery.
			old.hookOnly, old.connection = true, nil
		end
		pcall(function() entry.connection = instance.Destroying:Connect(function() entry.destroyed = true; byId[entry.id] = nil end) end)
		if entry.connection then watched[#watched + 1] = entry; entry.hookOnly = nil end
		return true
	end
	function M.id(instance, hookOnly)
		if not alive or typeof(instance) ~= "Instance" then return nil end
		local entry = byObject[instance]
		if entry and not entry.expired then if not hookOnly then watch(instance, entry) end; return entry.id end
		serial = serial + 1
		entry = { id = "inst:" .. M.epoch .. ":" .. serial, hookOnly = hookOnly }
		byObject[instance], byId[entry.id] = entry, instance
		if not hookOnly then watch(instance, entry) end
		return entry.id
	end
	function M.resolve(key)
		if not alive or type(key) ~= "string" or key:sub(1, #M.epoch + 6) ~= "inst:" .. M.epoch .. ":" then return nil, "stale_handle: this reference belongs to another runtime" end
		local instance = byId[key]
		if not instance or (byObject[instance] and byObject[instance].destroyed) then return nil, "stale_handle: object is no longer available" end
		local readable, parent = pcall(function() local _ = instance.ClassName; return instance.Parent end)
		if not readable then return nil, "unavailable: object cannot be read" end
		if byObject[instance].hookOnly and instance ~= game and parent == nil then return nil, "stale_handle: an untracked detached object must be explicitly rediscovered" end
		return instance
	end
	function M.select(args)
		if args.instance_id and args.path then return nil, "Provide exactly one of instance_id or path" end
		if args.instance_id then return M.resolve(args.instance_id) end
		if not args.path then return nil, "An instance_id or explicit path is required" end
		return paths.resolve(args.path)
	end
	function M.describe(instance, minimal)
		local key = M.id(instance, minimal); if not key then return { availability = "unavailable" } end
		local entry = byObject[instance]
		local result = { instanceId = key, availability = entry.destroyed and "destroyed" or "available" }
		pcall(function() result.name, result.className = instance.Name, instance.ClassName end)
		if not minimal then result.displayPath, result.observedAt = paths.pathOf(instance), clock.ms() end
		return result
	end
	function M.pin(key, owner)
		local instance, why = M.resolve(key); if not instance then return nil, why end
		owner = owner or {}; pins[owner] = pins[owner] or {}
		local entry = byObject[instance]
		if not pins[owner][key] then entry.pinCount = (entry.pinCount or 0) + 1 end
		pins[owner][key] = instance; watch(instance, entry)
		return instance
	end
	function M.release(owner)
		for _, instance in pairs(pins[owner] or {}) do local entry = byObject[instance]; if entry then entry.pinCount = math.max(0, (entry.pinCount or 0) - 1) end end
		pins[owner] = nil
	end
	function M.invalidate(instance)
		local entry = byObject[instance]; if entry then entry.destroyed = true; byId[entry.id] = nil end
	end
	env.require("runtime/dispose").add(function()
		alive = false; pins = {}
		for _, entry in pairs(byObject) do if entry.connection then pcall(function() entry.connection:Disconnect() end) end end
		byObject, byId, watched = {}, {}, {}
	end, "instance identities")
	return M
end
