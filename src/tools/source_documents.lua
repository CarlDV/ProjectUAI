return function(env)
	local sources = env.require("runtime/script_sources")
	local store = env.require("runtime/code_store")
	local limits = env.require("runtime/code_limits")
	local M = {}
	function M.open(args, ctx)
		local count = (args.instanceId and 1 or 0) + (args.sourceId and 1 or 0) + (args.path and 1 or 0) + (args.recordId and 1 or 0)
		if count ~= 1 then return nil, "Choose exactly one script, source, file, or captured call" end
		local source, why
		if args.instanceId then source, why = sources.inspect(args.instanceId, ctx)
		elseif args.sourceId then source, why = sources.get(args.sourceId)
		elseif args.path then source, why = sources.fromFile(args.path)
		else source, why = env.require("tools/remote_replay").source({ recordId = args.recordId, recordRevision = args.recordRevision, arguments = args.arguments }) end
		if not source then return nil, why end
		if #source.source > limits.source then
			if args.focus then store.workspace.sourceId, store.workspace.destination, store.workspace.sourceOffset = source.id, "Editor", 1; store.changed:fire({ kind = "large_source" }) end
			return { sourceId = source.id, path = source.path, bytes = source.bytes, readOnly = true, provenance = source.provenance, persistenceError = source.persistenceError }
		end
		local document
		for _, item in ipairs(store.list()) do if item.provenance == source.provenance and item.source == source.source and item.bindingId == source.bindingId then document = item; break end end
		if not document then document, why = store.create(args.name or source.name, source.source, { provenance = source.provenance, bindingId = source.bindingId, origin = "source" }); if not document then return nil, why end end
		if args.focus then
			store.workspace.sourceId, store.workspace.destination = nil, "Editor"
			local selected, err = store.select(document.id); if not selected then return nil, err end
			store.changed:fire({ kind = "preference" })
		end
		return { documentId = document.id, revision = document.revision, sourceId = source.id, bindingId = document.bindingId, bytes = #document.source, provenance = document.provenance }
	end
	return M
end
