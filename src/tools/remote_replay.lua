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
	function M.prepare(args)
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
	function M.source(args)
		local plan, why = M.prepare(args); if not plan then return nil, why end
		local binding = sources.bind({ remoteId = plan.remoteId, arguments = plan.arguments }, function()
			local valid, err = transport.validate(plan.remoteId, plan.method, plan.arguments); return valid ~= nil, err
		end)
		local description = "-- Session-bound " .. plan.method .. ": " .. util.ellipsis(plan.target.displayPath, 500)
		local source = description .. "\n-- Packed arguments: " .. util.encode(plan.arguments):gsub("\n", "\n-- ")
			.. "\nlocal binding = ...\nassert(binding and binding.call, 'This script requires a current UAI binding')\nreturn binding.call()\n"
		-- The binding is runtime data, separate from serializable source.
		local data = sources.binding(binding)
		data.call = function(ctx)
			local result = transport.call(plan.remoteId, plan.method, plan.arguments, { replayOf = plan.recordId, rawReturns = true }, ctx)
			if not result.ok then error(result.text, 0) end
			local returned = result.returns or { n = 0 }
			return unpack(returned, 1, returned.n)
		end
		local item, err = sources.keep(source, "Capture " .. tostring(plan.recordId or plan.id) .. " · session-bound", "Remote call.lua")
		if item then item.bindingId = binding end
		return item, err
	end
	function M.portable(args)
		local plan, why = M.prepare(args); if not plan then return nil, why end
		return values.portable(plan.arguments, plan.remoteId, plan.method)
	end
	return M
end
