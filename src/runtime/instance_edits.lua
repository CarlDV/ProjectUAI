-- Shared guarded writes for native UI and existing/new tools. No global batch.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local fields = env.require("runtime/instance_fields")
	local history = env.require("runtime/changes")
	local util = env.require("runtime/util")
	local M = {}
	local function fail(status, text, extra) local r = extra or {}; r.ok, r.status, r.text = false, status, text; return r end
	function M.apply(operations, ctx)
		if type(operations) ~= "table" or not util.isArray(operations) or #operations < 1 or #operations > 100 then return fail("invalid_arguments", "Use 1–100 ordered field edits") end
		local prepared, targets, seen = {}, {}, {}
		for i, op in ipairs(operations) do
			if type(op) ~= "table" then return fail("invalid_arguments", "Invalid field operation") end
			local target, why = refs.resolve(op.instanceId or op.instance_id); if not target then return fail("stale_handle", why) end
			local key, kind = op.key or op.field, op.kind or "property"
			local identity = tostring(op.instanceId or op.instance_id) .. ":" .. tostring(kind) .. ":" .. tostring(key)
			if seen[identity] then return fail("invalid_arguments", "Each field may occur only once per batch") end
			seen[identity], targets[target] = true, true
			if util.count(targets) > 20 then return fail("invalid_arguments", "Use at most 20 target objects") end
			local read, before = fields.read(target, kind, key); if not read then return fail("unavailable", "Cannot read " .. tostring(key)) end
			local expectedOK, expected = values.decodeNode(op.expected)
			if not expectedOK or not values.equal(expected, before) then return fail("conflict", "Observed value changed for " .. tostring(key) .. "; no fields were written") end
			local decoded, value = values.decodeNode(op.remove and { kind = "nil" } or op.value)
			if not decoded then return fail("invalid_arguments", value) end
			local valid, reason = fields.validate(kind, key, value, before); if not valid then return fail("invalid_arguments", reason) end
			prepared[i] = { target = target, instanceId = refs.id(target), kind = kind, key = key, before = before, value = value }
		end
		local applied, outcomes, uncertain, failure = {}, {}, {}, nil
		for _, op in ipairs(prepared) do
			if ctx and ctx.aborted and ctx.aborted() then failure = "aborted"; break end
			local target = refs.resolve(op.instanceId)
			local read, current = false, nil; if target then read, current = fields.read(target, op.kind, op.key) end
			if not read or not values.equal(current, op.before) then failure = "conflict"; break end
			local wrote, why = fields.write(target, op.kind, op.key, op.value)
			local observed, after = fields.read(target, op.kind, op.key)
			if observed and not values.equal(after, op.before) then
				op.after = after; applied[#applied + 1] = op
			elseif not observed then
				op.uncertain, op.reason = true, "Readback unavailable after write"
				uncertain[#uncertain + 1] = op
			end
			outcomes[#outcomes + 1] = { instanceId = op.instanceId, kind = op.kind, key = op.key, ok = wrote and observed, value = observed and values.node(after) or nil,
				uncertain = not observed or nil, error = not wrote and tostring(why) or (not observed and op.reason or nil) }
			if not wrote or not observed then failure = "write_failed"; break end
		end
		local recovered, remaining = {}, {}
		if failure then
			for i = #applied, 1, -1 do
				local op = applied[i]; local read, current = fields.read(op.target, op.kind, op.key)
				if read and values.equal(current, op.after) then fields.write(op.target, op.kind, op.key, op.before) end
				local verified, actual = fields.read(op.target, op.kind, op.key)
				if verified and values.equal(actual, op.before) then recovered[#recovered + 1] = op.key
				elseif not verified then
					op.uncertain, op.reason = true, "Readback unavailable during recovery"
					uncertain[#uncertain + 1] = op
				else
					-- Preserve our observed after value. Never adopt a newer external
					-- value as ours: a later Undo must conflict with that value.
					remaining[#remaining + 1] = op
				end
			end
		else remaining = applied end
		local batch = history.record(remaining, ctx and ctx.origin or "user", uncertain)
		local unknown = {}
		for _, op in ipairs(uncertain) do
			unknown[#unknown + 1] = { instanceId = op.instanceId, kind = op.kind, key = op.key, before = values.node(op.before), reason = op.reason }
			op.target, op.value = nil, nil
		end
		for _, op in ipairs(remaining) do op.target, op.value = nil, nil end
		return { ok = failure == nil, status = failure and ((#remaining > 0 or #unknown > 0) and "partial" or failure) or "completed",
			text = #unknown > 0 and ("Edit did not finish; " .. #unknown .. " field outcomes are unreadable. Inspect these fields again; this batch cannot be undone.")
				or (failure and "Edit did not finish; inspect applied/recovered fields" or ("Updated " .. #applied .. " local fields")),
			outcomes = outcomes, recovered = recovered, uncertain = unknown, confirmedChangedCount = #remaining,
			changedCount = #unknown == 0 and #remaining or nil, batchId = batch }
	end
	function M.hierarchy(action, args, ctx)
		args = args or {}; local parent, target, why
		if args.instanceId then target, why = refs.resolve(args.instanceId); if not target then return fail("stale_handle", why) end end
		if args.parentId then parent, why = refs.resolve(args.parentId); if not parent then return fail("stale_handle", why) end end
		if ctx and ctx.aborted and ctx.aborted() then return fail("aborted", "Operation stopped before any change") end
		if action == "reparent" or action == "detach" then
			if not target then return fail("invalid_arguments", "A target is required") end
			local good, expected = values.decodeNode(args.expectedParent)
			if not good or target.Parent ~= expected then return fail("conflict", "Parent changed; inspect the object again") end
			if action == "reparent" and not parent then return fail("invalid_arguments", "Choose a parent") end
			if parent and (parent == target or parent:IsDescendantOf(target)) then return fail("invalid_arguments", "Cannot move an object inside itself") end
			local ok, err = pcall(function() target.Parent = parent end); if not ok then return fail("partial", tostring(err)) end
			return { ok = true, status = "completed", text = action == "detach" and "Detached locally; outside Undo coverage" or "Moved locally; outside Undo coverage", item = refs.describe(target) }
		elseif action == "delete" then
			if not target or target == game then return fail("invalid_arguments", "Choose an object to delete") end
			local info = refs.describe(target); local ok, err = pcall(function() target:Destroy() end)
			if not ok then return fail("partial", tostring(err)) end
			refs.invalidate(target); return { ok = true, status = "completed", text = "Deleted " .. tostring(info.name) .. "; this cannot be undone", item = info }
		elseif action == "create" or action == "duplicate" then
			if action == "duplicate" and not target then return fail("invalid_arguments", "Choose an object to duplicate") end
			local ok, object = pcall(function() return action == "duplicate" and target:Clone() or Instance.new(args.class) end)
			if not ok or not object then return fail("unavailable", "Object could not be created or cloned") end
			local configured, err = pcall(function()
				if args.name then if type(args.name) ~= "string" or #args.name > 1000 then error("Invalid name") end; object.Name = args.name end
				for _, op in ipairs(args.properties or {}) do
					local decoded, value = values.decodeNode(op.value); if not decoded then error(value) end
					local readable, before = fields.read(object, "property", op.key); if not readable then error("Unreadable property: " .. op.key) end
					local valid, reason = fields.validate("property", op.key, value, before); if not valid then error(reason) end
					object[op.key] = value
				end
				for _, key in ipairs(util.keys(args.legacyProperties or {}, true)) do
					local value, why = env.require("runtime/legacy_values").coerce(args.legacyProperties[key], object[key])
					if value == nil then error(why or "Invalid property value") end
					local valid, reason = fields.validate("property", key, value, object[key]); if not valid then error(reason) end
					object[key] = value
				end
				if ctx and ctx.aborted and ctx.aborted() then error("aborted") end
				object.Parent = parent
			end)
			if not configured then pcall(function() object:Destroy() end); return fail("unavailable", tostring(err)) end
			return { ok = true, status = "completed", text = "Created locally; outside Undo coverage", item = refs.describe(object) }
		end
		return fail("invalid_arguments", "Unknown hierarchy operation")
	end
	function M.hierarchyMany(action, ids, args, ctx)
		if type(ids) ~= "table" or #ids < 1 or #ids > 20 then return fail("invalid_arguments", "Choose 1–20 objects") end
		local objects, normalized = {}, {}
		for _, key in ipairs(ids) do local target, why = refs.resolve(key); if not target then return fail("stale_handle", why) end; objects[#objects + 1] = target end
		for _, target in ipairs(objects) do
			local nested = false
			if action == "delete" or action == "duplicate" then for _, other in ipairs(objects) do if other ~= target and target:IsDescendantOf(other) then nested = true end end end
			if not nested then normalized[#normalized + 1] = target end
		end
		-- Validate every move before touching any member of the batch.
		if action == "reparent" or action == "detach" then
			local parent, why
			if action == "reparent" then parent, why = refs.resolve(args and args.parentId); if not parent then return fail("stale_handle", why) end end
			for _, target in ipairs(normalized) do
				local expected = args and args.expectedParents and args.expectedParents[refs.id(target)]
				local valid, before = values.decodeNode(expected)
				if not valid or target.Parent ~= before then return fail("conflict", "A selected parent changed; no objects were moved") end
				if parent and (parent == target or parent:IsDescendantOf(target)) then return fail("invalid_arguments", "Cannot move an object inside itself") end
			end
		end
		local result = { ok = true, status = "completed", outcomes = {}, text = "Hierarchy operation completed; outside Undo coverage" }
		for _, target in ipairs(normalized) do
			local options = util.copy(args); options.instanceId = refs.id(target)
			if options.expectedParents then options.expectedParent = options.expectedParents[options.instanceId] end
			if action == "duplicate" and options.parentIds then
				local valid, parent = values.decodeNode(options.parentIds[options.instanceId]); if not valid then return fail("stale_handle", "Duplicate destination expired") end
				options.parentId = parent and refs.id(parent) or nil
			end
			local outcome = M.hierarchy(action, options, ctx); result.outcomes[#result.outcomes + 1] = outcome
			if not outcome.ok then result.ok, result.status, result.text = false, "partial", "Some hierarchy operations did not finish"; break end
		end
		return result
	end
	return M
end
