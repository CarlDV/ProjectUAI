-- Explicit, verified exports under the user files scope. Never a live stream.
return function(env)
	local fs = env.require("runtime/fsx")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local records = env.require("runtime/remote_store")
	local scan = env.require("runtime/instance_scan")
	local M = {}; local serial = 0
	function M.write(content, destination)
		if type(content) ~= "string" or #content > 2 * 1024 * 1024 then return nil, "Export part exceeds 2 MiB" end
		serial = serial + 1
		local path, why = fs.sanitise(destination or ("exports/uai-" .. clock.ms() .. "-" .. serial .. ".json"))
		if not path then return nil, why end
		if fs.exists(path, { scope = "files" }) then return nil, "Destination already exists; choose another name" end
		local ok, err = fs.write(path, content, { scope = "files" }); if not ok then return nil, err end
		if fs.read(path, { scope = "files" }) ~= content then return nil, "Export verification failed" end
		return { path = "files/" .. path, bytes = #content, verified = true }
	end
	function M.captures(keys, destination)
		local list, why
		if keys then list, why = records.exportRecords(keys)
		else
			list = {}; local cursor
			repeat
				local page, err = records.page({ cursor = cursor, limit = 100 }); if not page then return nil, err end
				for _, summary in ipairs(page.items) do local record = records.get(summary.id); if record then list[#list + 1] = record end end
				cursor = page.nextCursor
			until not cursor or #list >= 1000
		end
		if not list then return nil, why end
		serial = serial + 1
		local envelope = { format = "uai-captures", version = 1, snapshotId = "capture-export:" .. refs.epoch .. ":" .. serial,
			exportedAt = clock.ms(), epoch = refs.epoch, placeId = game.PlaceId,
			state = env.require("runtime/remote_capture").state(), records = list }
		local encoded = util.encode(envelope)
		if #encoded <= 2 * 1024 * 1024 then return M.write(encoded, destination) end
		local parts, batch, used = {}, {}, 0
		local prefix = destination and destination:gsub("%.json$", "") or ("exports/captures-" .. clock.ms())
		local function flush()
			local part = util.copy(envelope); part.records = batch
			local result, err = M.write(util.encode(part), prefix .. ".part-" .. (#parts + 1) .. ".json")
			if not result then return nil, err end
			parts[#parts + 1] = result; batch, used = {}, 0; return true
		end
		for _, record in ipairs(list) do
			local size = #util.encode(record)
			if used + size > 1800000 then local ok, err = flush(); if not ok then return nil, "Incomplete export: " .. tostring(err) end end
			batch[#batch + 1], used = record, used + size
		end
		if #batch > 0 then local ok, err = flush(); if not ok then return nil, "Incomplete export: " .. tostring(err) end end
		return M.write(util.encode({ format = "uai-capture-manifest", version = 1, complete = true, snapshotId = envelope.snapshotId, parts = parts, recordCount = #list, epoch = refs.epoch }), prefix .. ".manifest.json")
	end
	function M.import(path)
		local raw, why = fs.readUser(path); if not raw then return nil, why end
		if #raw > 2 * 1024 * 1024 then return nil, "Import is limited to 2 MiB per capture part" end
		local item = util.decode(raw)
		if type(item) ~= "table" or item.format ~= "uai-captures" or item.version ~= 1 then return nil, "Unsupported capture file; import a capture part" end
		return records.import(item.records)
	end
	function M.explorer(ids, options, ctx)
		options = options or {}; if type(ids) ~= "table" or #ids < 1 or #ids > 20 then return nil, "Choose 1–20 objects" end
		if options.format and options.format ~= "metadata" then return nil, "Only selected-object metadata export is supported; no model-export adapter is verified" end
		local depth = options.depth ~= nil and tonumber(options.depth) or (options.descendants and 8 or 0)
		if not values.finite(depth) or depth < 0 or depth > 8 or depth ~= math.floor(depth) then return nil, "Export depth must be an integer from 0 to 8" end
		local list, seen, omitted = {}, {}, 0
		local function include(object)
			local key = refs.id(object); if seen[key] then return end; seen[key] = true
			if #list >= 500 then omitted = omitted + 1; return false end
			local item = refs.describe(object); item.fields = {}
			for i, name in ipairs(options.fields or { "Name", "ClassName", "Parent" }) do
				if i > 20 then break end
				if name ~= "Source" then local ok, value = pcall(function() return object[name] end); item.fields[name] = ok and values.node(value) or { kind = "unavailable" } end
			end
			list[#list + 1] = item
		end
		for _, key in ipairs(ids) do
			local object, why = refs.resolve(key); if not object then return nil, why end
			include(object)
			if depth > 0 then
				local stats = scan.descendants(object, ctx, function(child)
					local level, ancestor = 0, child
					while ancestor and ancestor ~= object and level <= depth do level, ancestor = level + 1, ancestor.Parent end
					if ancestor == object and level <= depth then return include(child) end
				end, 20000)
				if not stats.complete then omitted = omitted + 1 end
			end
		end
		if ctx and ctx.aborted and ctx.aborted() then return nil, "aborted" end
		return M.write(util.encode({ format = "uai-instance-metadata", version = 1, epoch = refs.epoch, items = list, omitted = omitted, partial = omitted > 0, depth = depth, scope = "selected objects", sourceIncluded = false }), options.destination)
	end
	return M
end
