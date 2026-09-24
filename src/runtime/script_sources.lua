-- Immutable bounded source snapshots and ephemeral execution bindings.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local caps = env.require("runtime/caps")
	local fs = env.require("runtime/fsx")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local limits = env.require("runtime/code_limits")
	local M = {}
	local sources, bindings, serial, bytes = {}, {}, 0, 0
	local function id(prefix) serial = serial + 1; return prefix .. ":" .. refs.epoch .. ":" .. serial end
	function M.keep(source, provenance, name, existingPath)
		if type(source) ~= "string" or not util.validUtf8(source) then return nil, "Source is not valid UTF-8" end
		if #source > limits.file then return nil, "Source exceeds 2 MiB; existing documents were preserved" end
		local item = { id = id("source"), name = util.ellipsis(name or "Source.lua", 120), provenance = provenance, bytes = #source, at = clock.ms(), source = source }
		if existingPath then item.path = existingPath
		elseif #source > limits.source and fs.enabled then
			local path = "source-" .. tostring(clock.ms()) .. "-" .. serial .. ".lua"
			local ok = fs.write(path, source, { scope = "pastes" })
			if ok and fs.read(path, { scope = "pastes" }) == source then item.path = "pastes/" .. path
			else item.persistenceError = "Source file verification failed; temporary memory snapshot retained" end
		end
		sources[#sources + 1], bytes = item, bytes + #source
		while #sources > 8 or bytes > 8 * 1024 * 1024 do local old = table.remove(sources, 1); bytes = bytes - #old.source end
		return item
	end
	function M.get(key) for _, item in ipairs(sources) do if item.id == key then return item end end; return nil, "Source snapshot expired" end
	function M.inspect(instanceId, ctx)
		local object, why = refs.resolve(instanceId); if not object then return nil, why end
		if not object:IsA("LuaSourceContainer") then return nil, "Choose a script" end
		if ctx and ctx.aborted and ctx.aborted() then return nil, "aborted" end
		local ok, source = pcall(function() return object.Source end); local method = "Source"
		if (not ok or type(source) ~= "string") and caps.fn.decompile then ok, source = pcall(caps.fn.decompile, object); method = "decompiled" end
		if ctx and ctx.aborted and ctx.aborted() then return nil, "aborted" end
		if not ok or type(source) ~= "string" then return nil, "Script source is unavailable on this host" end
		local info = refs.describe(object)
		return M.keep(source, method .. " · " .. info.instanceId .. " · " .. info.displayPath, info.name .. ".lua")
	end
	function M.fromFile(path)
		local source, why, resolved = fs.readUser(path); if not source then return nil, why end
		local item, err = M.keep(source, "File snapshot · " .. resolved, resolved:match("[^/]+$"), resolved)
		if item then item.path = resolved end; return item, err
	end
	function M.read(key, offset, count)
		local item, why = M.get(key); if not item then return nil, why end
		offset, count = math.max(1, math.floor(tonumber(offset) or 1)), math.max(1, math.min(math.floor(tonumber(count) or limits.sourcePage), limits.sourcePage))
		if offset > #item.source + 1 then return nil, "Offset is outside source" end
		local byte = item.source:byte(offset); if byte and byte >= 128 and byte < 192 then return nil, "Offset splits a UTF-8 character" end
		local last = math.min(#item.source, offset + count - 1)
		while last > offset and item.source:byte(last + 1) and item.source:byte(last + 1) >= 128 and item.source:byte(last + 1) < 192 do last = last - 1 end
		if item.source:byte(last + 1) and item.source:byte(last + 1) >= 128 and item.source:byte(last + 1) < 192 then return nil, "Slice is too small for a complete UTF-8 character" end
		return { sourceId = item.id, text = item.source:sub(offset, last), offset = offset, nextOffset = last < #item.source and last + 1 or nil, bytes = item.bytes, provenance = item.provenance, path = item.path }
	end
	function M.bind(data, validate)
		local key = id("binding"); bindings[#bindings + 1] = { id = key, at = clock.ms(), data = data, validate = validate }
		while #bindings > 20 do table.remove(bindings, 1) end
		return key
	end
	function M.binding(key)
		for _, item in ipairs(bindings) do
			if item.id == key then
				if clock.ms() - item.at > limits.ttl then return nil, "Source binding expired; prepare a fresh script" end
				local valid, why = item.validate(); if not valid then return nil, why end
				return item.data
			end
		end
		return nil, "Source binding belongs to an expired runtime; prepare a fresh script"
	end
	env.require("runtime/dispose").add(function() sources, bindings = {}, {}; bytes = 0 end, "source snapshots and bindings")
	return M
end
