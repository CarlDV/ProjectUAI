-- Session-local property/attribute Undo. Preflight conflicts make zero writes.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local fields = env.require("runtime/instance_fields")
	local clock = env.require("runtime/clock")
	local M = { changed = env.require("runtime/signal").new("game-changes") }
	local batches, serial, records = {}, 0, 0
	function M.record(changes, origin, uncertain)
		local kept, unknown = {}, false
		for _, item in ipairs(changes) do
			if item.kind ~= "tag" and not values.equal(item.before, item.after) then kept[#kept + 1] = item end
		end
		for _, item in ipairs(uncertain or {}) do
			if item.kind ~= "tag" then kept[#kept + 1] = item; unknown = true end
		end
		if #kept == 0 then return nil end
		serial = serial + 1
		local batch = { id = "change:" .. refs.epoch .. ":" .. serial, at = clock.ms(), origin = origin or "user", status = unknown and "partial" or "applied", records = kept }
		batches[#batches + 1] = batch; records = records + #kept
		for _, item in ipairs(kept) do refs.pin(item.instanceId, batch) end
		while #batches > 30 or records > 300 do local old = table.remove(batches, 1); records = records - #old.records; refs.release(old) end
		M.changed:fire({ batchId = batch.id, status = batch.status, changedCount = #kept }); return batch.id
	end
	function M.list()
		local out = {}
		for i = #batches, 1, -1 do
			local batch, items = batches[i], {}
			for _, item in ipairs(batch.records) do items[#items + 1] = { instanceId = item.instanceId, kind = item.kind, key = item.key, before = values.node(item.before),
				after = not item.uncertain and values.node(item.after) or nil, uncertain = item.uncertain, reason = item.reason } end
			out[#out + 1] = { id = batch.id, at = batch.at, origin = batch.origin, status = batch.status, records = items }
		end
		return out
	end
	function M.undo(key, ctx)
		local batch
		for _, item in ipairs(batches) do if item.id == key then batch = item end end
		if not batch then return { ok = false, status = "expired", text = "This game-change batch has expired" } end
		if batch.status ~= "applied" then return { ok = false, status = batch.status, text = "This batch is " .. batch.status } end
		local targets, conflicts = {}, {}
		for i, item in ipairs(batch.records) do
			local target = refs.resolve(item.instanceId)
			local ok, current = false, nil; if target then ok, current = fields.read(target, item.kind, item.key) end
			if not ok or not values.equal(current, item.after) then conflicts[#conflicts + 1] = { instanceId = item.instanceId, key = item.key } end
			targets[i] = target
		end
		if #conflicts > 0 then return { ok = false, status = "conflict", text = "Values changed or targets are unavailable; no fields were written", conflicts = conflicts } end
		local reverted, failures, uncertain = {}, {}, {}
		for i = #batch.records, 1, -1 do
			local item, target = batch.records[i], targets[i]
			local ok, current = fields.read(target, item.kind, item.key)
			if (ctx and ctx.aborted and ctx.aborted()) or not ok or not values.equal(current, item.after) then failures[#failures + 1] = item.key; break end
			local wrote = fields.write(target, item.kind, item.key, item.before)
			local read, after = fields.read(target, item.kind, item.key)
			if read and values.equal(after, item.before) then reverted[#reverted + 1] = i end
			if not wrote or not read or not values.equal(after, item.before) then
				if not read or (not values.equal(after, item.before) and not values.equal(after, item.after)) then uncertain[#uncertain + 1] = item.key end
				failures[#failures + 1] = item.key; break
			end
		end
		if #failures > 0 then
			local unrecovered = uncertain
			for j = #reverted, 1, -1 do
				local i = reverted[j]; local item = batch.records[i]
				local ok, current = fields.read(targets[i], item.kind, item.key)
				local wrote = ok and values.equal(current, item.before) and fields.write(targets[i], item.kind, item.key, item.after)
				local read, after = fields.read(targets[i], item.kind, item.key)
				if not wrote or not read or not values.equal(after, item.after) then unrecovered[#unrecovered + 1] = item.key end
			end
			if #unrecovered > 0 then batch.status = "partial" end
			M.changed:fire({ batchId = key, status = batch.status })
			return { ok = false, status = #unrecovered > 0 and "partial" or "conflict", text = "Undo could not finish; inspect field outcomes", failed = failures, unrecovered = unrecovered }
		end
		batch.status = "undone"; M.changed:fire({ batchId = key, status = "undone" })
		return { ok = true, status = "undone", text = "Restored " .. #batch.records .. " recorded fields", changedCount = #batch.records }
	end
	env.require("runtime/dispose").add(function() for _, batch in ipairs(batches) do refs.release(batch) end; batches = {}; M.changed:clear() end, "game change history")
	return M
end
