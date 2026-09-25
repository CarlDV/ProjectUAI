-- Immutable snapshots. Decompilation runs only in bounded explicit request workers.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local caps = env.require("runtime/caps")
	local fs = env.require("runtime/fsx")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local limits = env.require("runtime/code_limits")
	local text = env.require("runtime/code_text")
	local M = {}
	local sources, bindings, cache, flights, generations, owners = {}, {}, {}, {}, {}, {}
	local serial, bytes, workers, alive = 0, 0, 0, true
	local function id(prefix) serial = serial + 1; return prefix .. ":" .. refs.epoch .. ":" .. serial end
	local function hash(source) local value = 5381; for i = 1, #source do value = (value * 33 + source:byte(i)) % 4294967296 end; return string.format("%08x", value) end
	M.hash = hash
	local function failure(code, message, instanceId, method)
		return { id = id("source"), instanceId = instanceId, runtimeEpoch = refs.epoch, method = method or "source",
			status = (code == "expired_snapshot" and "expired") or ((code == "decompiler_failure" or code == "invalid_source" or code == "source_failure") and "error") or "unavailable",
			code = code, bytes = 0, readOnly = true, liveBinding = false, writeBack = false, capturedAt = clock.ms(), diagnostics = message }
	end
	M.failure = failure
	function M.describe(item)
		local result = {}; for key, value in pairs(item or {}) do if key ~= "source" and key ~= "pins" then result[key] = value end end
		return result
	end
	function M.document(doc)
		local result = M.describe(doc.sourceInfo)
		result.id, result.documentId, result.revision = "document:" .. doc.id .. ":" .. doc.revision, doc.id, doc.revision
		result.runtimeEpoch, result.method, result.origin = result.runtimeEpoch or refs.epoch, result.method or "source", result.origin or "authored"
		result.status, result.bytes = #doc.source == 0 and "empty" or "available", #doc.source
		result.readOnly, result.liveBinding, result.writeBack = doc.readOnly == true, false, false
		result.capturedAt, result.sourceHash = result.capturedAt or doc.updatedAt, hash(doc.source)
		result.snapshotState = doc.snapshotState
		return result
	end
	local function remove(index)
		local item = table.remove(sources, index); bytes = bytes - item.bytes
		for key, value in pairs(cache) do if value == item.id then cache[key] = nil end end
	end
	local function prune(required)
		for i = #sources, 1, -1 do local item = sources[i]; if not next(item.pins) and clock.ms() > item.expiresAt then remove(i) end end
		while #sources >= limits.sourceSnapshots or bytes + required > limits.sourceCacheBytes do
			local oldest
			for i, item in ipairs(sources) do if not next(item.pins) then oldest = i; break end end
			if not oldest then return false end
			remove(oldest)
		end
		return true
	end
	function M.keep(source, provenance, name, existingPath, metadata)
		metadata = metadata or {}
		if not alive then return nil, "Source service belongs to an expired runtime", failure("stale_request", "Source service belongs to an expired runtime", metadata.instanceId) end
		if type(source) ~= "string" or not util.validUtf8(source) then return nil, "Source is not valid UTF-8", failure("invalid_source", "Source is not valid UTF-8", metadata.instanceId, metadata.method) end
		if #source > limits.file then return nil, "Source exceeds 2 MiB; existing documents were preserved", failure("oversized_source", "Source exceeds 2 MiB", metadata.instanceId) end
		if not prune(#source) then return nil, "Source cache is full of displayed snapshots; close a source view first", failure("cache_full", "Source cache is full of displayed snapshots", metadata.instanceId, metadata.method) end
		local method = metadata.method or (existingPath and "file") or "captured"
		local item = { id = id("source"), name = util.ellipsis(name or "Source.lua", 120), provenance = provenance or method,
			bytes = #source, at = clock.ms(), capturedAt = clock.ms(), expiresAt = clock.ms() + limits.ttl, source = source, pins = {},
			runtimeEpoch = refs.epoch, method = method, status = #source == 0 and "empty" or "available", code = #source == 0 and "empty_source" or "available",
			readOnly = method == "source" or method == "decompiled", liveBinding = false, writeBack = false, sourceHash = hash(source),
			instanceId = metadata.instanceId, instancePath = metadata.instancePath, origin = metadata.origin or method, generation = metadata.generation,
			diagnostics = #source == 0 and "The host returned an empty source string" or nil }
		if existingPath then item.path = existingPath end
		sources[#sources + 1], bytes = item, bytes + #source
		return item
	end
	function M.get(key)
		for i, item in ipairs(sources) do
			if item.id == key then
				if alive and item.runtimeEpoch == refs.epoch and (next(item.pins) or clock.ms() <= item.expiresAt) then return item end
				remove(i); break
			end
		end
		return nil, "Expired source snapshot; refresh the script or reopen its file", failure("expired_snapshot", "Expired source snapshot")
	end
	function M.pin(key, owner)
		local item, why = M.get(key); if not item then return nil, why end
		if owner == nil then return nil, "A snapshot owner is required" end
		item.pins[owner] = true; return item
	end
	function M.release(owner) if owner == nil then return end; for _, item in ipairs(sources) do item.pins[owner] = nil end end
	function M.capabilities(instanceId)
		local object, why = refs.resolve(instanceId)
		local result = { instanceId = instanceId, runtimeEpoch = refs.epoch, supported = false, decompile = false, source = false }
		if not object then result.diagnostics = why; return result end
		local ok, supported = pcall(function() return object:IsA("LuaSourceContainer") end)
		result.supported = ok and supported == true
		if not result.supported then result.diagnostics = "This object does not contain source"; return result end
		local readable, source = pcall(function() return object.Source end)
		result.source, result.empty = readable and type(source) == "string", readable and source == ""
		result.decompile = caps.fn.decompile ~= nil
		result.status = result.source and (result.empty and "empty" or "source") or result.decompile and "decompile" or "unavailable"
		return result
	end
	function M.cancel(owner) if owner ~= nil then owners[owner] = nil end; M.release(owner) end
	function M.invalidate(instanceId)
		generations[instanceId] = (generations[instanceId] or 0) + 1
		cache[instanceId .. ":auto"], cache[instanceId .. ":decompiled"] = nil, nil
	end
	function M.inspect(instanceId, ctx, options)
		ctx, options = ctx or {}, options or {}
		local method = options.decompile and "decompiled" or "auto"
		local function stopped()
			if not alive or (ctx.runtimeEpoch and ctx.runtimeEpoch ~= refs.epoch) then return true end
			if not ctx.aborted then return false end
			local ok, value = pcall(ctx.aborted)
			return not ok or value == true
		end
		local function reject(code, message) return nil, message, failure(code, message, instanceId, options.decompile and "decompiled" or "source") end
		if stopped() then return reject("stale_request", "Source request was cancelled or belongs to an expired runtime") end
		local object, why = refs.resolve(instanceId); if not object then return reject("unavailable_source", why) end
		local capability = M.capabilities(instanceId)
		if not capability.supported then return reject("unsupported_object", "Choose a script that contains source") end
		if options.refresh then M.invalidate(instanceId) end
		local key, generation = instanceId .. ":" .. method, generations[instanceId] or 0
		local request, deadline = id("request"), clock.ms() + limits.sourceDeadline
		if ctx.requestOwner then owners[ctx.requestOwner] = request end
		local function stale() return stopped() or clock.ms() >= deadline or generation ~= (generations[instanceId] or 0) or (ctx.requestOwner and owners[ctx.requestOwner] ~= request) end
		local cached = cache[key] and M.get(cache[key]); if cached and not stale() then if ctx.requestOwner then owners[ctx.requestOwner] = nil end; return cached end
		local flight = flights[key]
		if not flight or flight.generation ~= generation then
			if workers >= limits.sourceWorkers then if ctx.requestOwner then owners[ctx.requestOwner] = nil end; return reject("unavailable_source", "Source workers are busy; retry after an active request completes") end
			flight = { generation = generation, epoch = refs.epoch, status = "pending", waiters = {} }; flights[key] = flight
			flight.waiters[request] = stale; workers = workers + 1
			clock.spawn(function()
				local ok, result, problem, detail = pcall(function()
					local source, read, origin
					if not options.decompile then read, source = pcall(function() return object.Source end); origin = "host-readable" end
					local used = "source"
					if options.decompile or not read or type(source) ~= "string" then
						if not caps.fn.decompile then return nil, "Decompiler unavailable on this host", failure("decompiler_unavailable", "Source is unreadable and no decompiler is available", instanceId) end
						read, source = pcall(caps.fn.decompile, object); used, origin = "decompiled", "decompiled"
						if not read or type(source) ~= "string" then return nil, "Decompiler failed to return source", failure("decompiler_failure", "Decompiler failed to return source; host error text was omitted", instanceId, used) end
					end
					local wanted = false; for _, cancelled in pairs(flight.waiters) do if not cancelled() then wanted = true end end
					if not wanted or not alive or flight.epoch ~= refs.epoch or generation ~= (generations[instanceId] or 0) or not refs.resolve(instanceId) then return reject("stale_request", "Discarded stale source completion") end
					local info = refs.describe(object)
					return M.keep(source, origin .. " · " .. instanceId .. " · " .. info.displayPath, info.name .. ".lua", nil,
						{ method = used, origin = origin, instanceId = instanceId, instancePath = info.displayPath, generation = generation })
				end)
				workers = math.max(0, workers - 1)
				flight.result, flight.problem = ok and result or nil, ok and problem or "Source request failed safely"
				flight.detail = detail or (not flight.result and failure("source_failure", flight.problem or "Source request failed safely", instanceId))
				flight.status = "completed"
				if alive and flight.result then cache[key] = flight.result.id end
				if flights[key] == flight then flights[key] = nil end
			end)
		else flight.waiters[request] = stale end
		while flight.status == "pending" and not stale() and clock.ms() < deadline do clock.wait(0.01) end
		flight.waiters[request] = nil
		local cancelled = stale()
		if ctx.requestOwner and owners[ctx.requestOwner] == request then owners[ctx.requestOwner] = nil end
		if clock.ms() >= deadline then return reject("stale_request", "Source request timed out; late results will be discarded") end
		if cancelled then return reject("stale_request", "Source request was superseded or cancelled") end
		return flight.result, flight.problem, flight.detail
	end
	function M.fromFile(path)
		local source, why, resolved = fs.readUser(path); if not source then return nil, why, failure("unavailable_source", "File snapshot is unavailable", nil, "file") end
		return M.keep(source, "File snapshot · " .. resolved, resolved:match("[^/]+$"), resolved, { method = "file" })
	end
	function M.read(key, offset, count)
		local item, why = M.get(key); if not item then return nil, why end
		offset, count = math.floor(tonumber(offset) or 1), math.max(1, math.min(math.floor(tonumber(count) or limits.sourcePage), limits.sourcePage))
		local body, nextOffset = text.page(item.source, offset, count); if not body then return nil, nextOffset end
		local result = M.describe(item); result.sourceId, result.text, result.offset, result.nextOffset = item.id, body, offset, nextOffset
		return result
	end
	function M.bind(data, validate)
		local key = id("binding"); bindings[#bindings + 1] = { id = key, at = clock.ms(), data = data, validate = validate }
		while #bindings > 20 do table.remove(bindings, 1) end
		return key
	end
	function M.binding(key)
		for _, item in ipairs(bindings) do if item.id == key then
			if not alive or clock.ms() - item.at > limits.ttl then return nil, "Source binding expired; prepare a fresh script" end
			local ok, valid, why = pcall(item.validate); if not ok or not valid then return nil, why or "Source binding is no longer available" end
			return item.data
		end end
		return nil, "Source binding belongs to an expired runtime; prepare a fresh script"
	end
	function M.state() return { snapshots = #sources, bytes = bytes, workers = workers, runtimeEpoch = refs.epoch } end
	env.require("runtime/dispose").add(function() alive = false; sources, bindings, flights, cache, owners = {}, {}, {}, {}, {}; bytes = 0 end, "source snapshots and requests")
	return M
end
