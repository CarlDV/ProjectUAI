-- Immutable workspace executions through the existing shared engine.
return function(env)
	local store = env.require("runtime/code_store")
	local execution = env.require("tools/execution")
	local sources = env.require("runtime/script_sources")
	local actionInputs = env.require("runtime/code_actions")
	local limits = env.require("runtime/code_limits")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local M = { changed = env.require("runtime/signal").new("code-runs"), runs = {} }
	local alive = true
	function M.snapshot(ref, expected, origin)
		local doc, why = store.resolve(ref); if not doc then return nil, why end
		if doc.readOnly then return nil, "Read-only source snapshot; extract an editable copy before Run" end
		if expected ~= nil and expected ~= doc.revision then return nil, "stale_revision: source changed before Run" end
		if origin == "tool" and expected == nil then return nil, "expected_revision is required for code_run" end
		return { id = store.id("run"), documentId = doc.id, revision = doc.revision, source = doc.source, name = doc.name, bindingId = doc.bindingId, origin = origin or "user" }
	end
	function M.actionSnapshot(key, expected, inputs, origin)
		local item, why = store.action(key); if not item then return nil, why end
		if expected ~= item.revision then return nil, "stale_revision: refresh the saved action" end
		local params, err = actionInputs.parameters(item.inputs, inputs or {}); if not params then return nil, err end
		return { id = store.id("run"), actionId = item.id, revision = item.revision, source = item.source, name = item.name, bindingId = item.bindingId, origin = origin or "action", parameters = { n = 1, params } }
	end
	function M.run(snapshot, ctx, timeout)
		if not alive then return { ok = false, text = "Workspace unloaded" } end
		local running = 0
		for _, item in ipairs(M.runs) do
			if item.id == snapshot.id then return { ok = false, text = "This run was already dispatched; prepare a new Run before executing again" } end
			if item.status == "running" then running = running + 1 end
		end
		if running >= 4 then return { ok = false, text = "At most four workspace runs may be active" } end
		if snapshot.origin ~= "tool" and M.active and M.active ~= snapshot then return { ok = false, text = "A workspace run is already active; use Stop or inspect Output" } end
		if snapshot.cancelled or (ctx and ctx.aborted and ctx.aborted()) then if M.active == snapshot then M.active = nil end; return { ok = false, text = "Stopped before Run" } end
		if snapshot.documentId then
			local doc = store.resolve(snapshot.documentId)
			if not doc or doc.revision ~= snapshot.revision then if M.active == snapshot then M.active = nil end; return { ok = false, text = "stale_revision: source changed before dispatch" } end
			if doc.readOnly then if M.active == snapshot then M.active = nil end; return { ok = false, text = "Read-only source snapshot; extract an editable copy before Run" } end
		end
		if snapshot.actionId then
			local action = store.action(snapshot.actionId)
			if not action or action.revision ~= snapshot.revision then if M.active == snapshot then M.active = nil end; return { ok = false, text = "stale_revision: action changed before dispatch" } end
		end
		local run = util.copy(snapshot); run.startedAt, run.status, run.output = clock.ms(), "running", {}
		local runContext = { origin = snapshot.origin, runId = run.id, aborted = function() return not alive or run.cancelled or (ctx and ctx.aborted and ctx.aborted()) end }
		if snapshot.bindingId then
			local binding, why = sources.binding(snapshot.bindingId); if not binding then if M.active == snapshot then M.active = nil end; return { ok = false, text = why } end
			local scoped = util.copy(binding)
			if binding.call then scoped.call = function() return binding.call(runContext) end end
			run.parameters = { n = 1, scoped }
		end
		M.runs[#M.runs + 1] = run; if run.origin ~= "tool" then M.active = run end
		M.changed:fire({ kind = "started", runId = run.id })
		local ok, result = pcall(execution.run, { code = run.source, timeout = timeout, parameters = run.parameters, onOutput = function(line)
			if not alive or run.cancelled then return end
			run.outputBytes = (run.outputBytes or 0) + #line
			if #run.output < 500 and run.outputBytes <= 128000 then run.output[#run.output + 1] = line else run.outputOmitted = (run.outputOmitted or 0) + 1 end
			M.changed:fire({ kind = "output", runId = run.id })
		end }, runContext)
		if not ok then result = { ok = false, text = tostring(result), data = { status = "runtime_error" } } end
		run.finishedAt, run.result, run.status = clock.ms(), result, result.data and result.data.status or (result.ok and "completed" or "compile_error")
		if M.active == run then M.active = nil end
		while #M.runs > limits.runs do
			local removed = false; for i, item in ipairs(M.runs) do if item.status ~= "running" then table.remove(M.runs, i); removed = true; break end end
			if not removed then break end
		end
		M.changed:fire({ kind = "finished", runId = run.id, status = run.status })
		result.data = result.data or {}; result.data.runId, result.data.documentId, result.data.revision = run.id, run.documentId, run.revision
		return result
	end
	function M.start(ref, timeout)
		if M.active then return nil, "A workspace run is already active" end
		local snapshot, why = M.snapshot(ref); if not snapshot then return nil, why end
		-- Reserve immediately; task.defer must not admit two activations.
		M.active = snapshot
		clock.spawn(function() local result = M.run(snapshot, nil, timeout); if M.active == snapshot then M.active = nil end; if not result.ok and not result.data then M.changed:fire({ kind = "rejected", text = result.text }) end end)
		return snapshot.id
	end
	function M.startAction(key, expected, inputs, timeout)
		if M.active then return nil, "A workspace run is already active" end
		local snapshot, why = M.actionSnapshot(key, expected, inputs); if not snapshot then return nil, why end
		M.active = snapshot
		clock.spawn(function() local result = M.run(snapshot, nil, timeout); if M.active == snapshot then M.active = nil end; if not result.ok and not result.data then M.changed:fire({ kind = "rejected", text = result.text }) end end)
		return snapshot.id
	end
	function M.busy()
		if M.active then return true end
		for _, run in ipairs(M.runs) do if run.status == "running" then return true end end
		return false
	end
	function M.operation(name, fn)
		if M.active then return nil, "A workspace operation is already active" end
		local run = { id = store.id("run"), name = name, revision = 0, origin = "replay", startedAt = clock.ms(), status = "running", output = {} }
		M.active = run; M.runs[#M.runs + 1] = run; M.changed:fire({ kind = "started", runId = run.id })
		clock.spawn(function()
			local ok, result = pcall(fn, { runId = run.id, origin = "user", aborted = function() return not alive or run.cancelled end })
			if not ok or type(result) ~= "table" then result = { ok = false, text = tostring(result or "Operation returned no result"), data = { status = "errored" } } end
			run.finishedAt, run.result, run.status = clock.ms(), result, result.data and result.data.status or (result.ok and "completed" or "errored")
			if M.active == run then M.active = nil end
			while #M.runs > limits.runs do local index; for i, item in ipairs(M.runs) do if item.status ~= "running" then index = i; break end end; if not index then break end; table.remove(M.runs, index) end
			M.changed:fire({ kind = "finished", runId = run.id })
		end)
		return run.id
	end
	function M.stop(key)
		if M.active and (not key or M.active.id == key) then M.active.cancelled = true end
		for _, run in ipairs(M.runs) do if (not key or run.id == key) and run.status == "running" then run.cancelled = true end end
		M.changed:fire({ kind = "stopping", runId = key })
	end
	env.require("runtime/dispose").add(function() alive = false; M.stop(); M.changed:clear() end, "code runner")
	return M
end
