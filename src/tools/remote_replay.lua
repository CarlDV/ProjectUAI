-- Reviewed, expiring, single-dispatch plans. Opening/reading a plan sends nothing.
return function(env)
	local transport = env.require("tools/remote_transport")
	local capture = env.require("runtime/remote_capture")
	local records = env.require("runtime/remote_store")
	local refs = env.require("runtime/instance_refs")
	local sources = env.require("runtime/script_sources")
	local values = env.require("runtime/values")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local M = {}
	local plans, serial = {}, 0
	local function digest(text) local hash = 5381; for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967296 end; return string.format("%08x", hash) end
	local function resolve(args)
		local graph, remoteId, method, recordId = args.arguments, args.remoteId, args.method, args.recordId
		local record
		if recordId then
			if remoteId or method then return nil, "Choose a capture or an explicit remote, not both" end
			if args.recordRevision == nil then return nil, "record_revision is required" end
			local why; record, why = records.get(recordId, args.recordRevision); if not record then return nil, why end
			if record.offline then return nil, "Imported captures require explicit current-target rebinding" end
			if record.direction == "incoming" then return nil, "Incoming observations cannot be replayed to the server" end
			remoteId, method, graph = record.remoteId, record.method, graph or record.arguments
		end
		local valid, why = transport.validate(remoteId, method, graph); if not valid then return nil, why end
		return { graph = graph, remoteId = remoteId, method = method, recordId = recordId, record = record, valid = valid }
	end
	function M.prepare(args)
		local resolved, why = resolve(args); if not resolved then return nil, why end
		local graph, remoteId, method, recordId, record, valid = resolved.graph, resolved.remoteId, resolved.method, resolved.recordId, resolved.record, resolved.valid
		serial = serial + 1
		local plan = { id = "replay:" .. refs.epoch .. ":" .. serial, remoteId = remoteId, method = method, arguments = util.deepCopy(graph),
			recordId = recordId, recordRevision = record and record.revision, ruleRevision = capture.ruleRevision, at = clock.ms(), status = "prepared", target = refs.describe(valid.object) }
		plan.digest = digest(plan.id .. util.encode(plan.arguments) .. method .. remoteId)
		plans[#plans + 1] = plan; while #plans > 20 do table.remove(plans, 1) end
		return util.deepCopy(plan)
	end
	function M.validate(key, expected)
		for _, plan in ipairs(plans) do
			if plan.id == key then
				if expected ~= plan.digest then return nil, "Plan digest does not match the reviewed arguments" end
				if plan.status ~= "prepared" then return plan end
				if clock.ms() - plan.at > 300000 then return nil, "expired: prepare a fresh replay plan" end
				if plan.ruleRevision ~= capture.ruleRevision then return nil, "Traffic rules changed; prepare a fresh plan" end
				if plan.recordId then local record, why = records.get(plan.recordId, plan.recordRevision); if not record then return nil, why end end
				local valid, why = transport.validate(plan.remoteId, plan.method, plan.arguments); if not valid then return nil, why end
				return plan
			end
		end
		return nil, "expired: replay plan is no longer retained"
	end
	function M.run(key, expected, ctx, timeout)
		local plan, why = M.validate(key, expected); if not plan then return { ok = false, text = why, data = { status = "stale", dispatched = false } } end
		if plan.status ~= "prepared" then return plan.result or { ok = false, text = "This plan was already dispatched", data = { status = plan.status, dispatched = true } } end
		if ctx and ctx.aborted and ctx.aborted() then return { ok = false, text = "Stopped before dispatch", data = { status = "aborted", dispatched = false } } end
		plan.status = "outstanding"
		local result = transport.call(plan.remoteId, plan.method, plan.arguments, { timeout = timeout, replayOf = plan.recordId }, ctx)
		plan.result, plan.status = result, result.data and result.data.status or "errored"
		return result
	end
	function M.portable(args)
		local resolved, why = resolve(args); if not resolved then return nil, why end
		return values.portable(resolved.graph, resolved.remoteId, resolved.method)
	end
	function M.source(args)
		local source, why = M.portable(args); if not source then return nil, why end
		local item, err = sources.keep(source, "Portable remote call · " .. tostring(args.recordId or args.remoteId), "Remote call.lua", nil, { method = "captured", origin = "portable remote script" })
		if item then item.recordId, item.recordRevision = args.recordId, args.recordRevision end
		return item, err
	end
	local reviews = {}
	function M.reviewSource(args)
		local item, why = M.source(args); if not item then return nil, why end
		serial = serial + 1
		local review = { id = "script-review:" .. refs.epoch .. ":" .. serial, digest = digest(item.source), source = item.source, sourceId = item.id, at = clock.ms(), args = util.deepCopy(args) }
		reviews[#reviews + 1] = review; while #reviews > 20 do table.remove(reviews, 1) end
		return util.copy(review)
	end
	function M.reviewedSource(key, expected)
		for _, review in ipairs(reviews) do if review.id == key then
			if clock.ms() - review.at > 300000 then return nil, "Script review expired; review the script again" end
			if review.digest ~= expected then return nil, "Script review digest changed" end
			local current, why = M.portable(review.args); if not current then return nil, why end
			if current ~= review.source then return nil, "Remote target or arguments changed; review a fresh script" end
			return review.source
		end end
		return nil, "Script review expired"
	end
	env.require("runtime/dispose").add(function() plans, reviews = {}, {} end, "replay plans and script reviews")
	return M
end
