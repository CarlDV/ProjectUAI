return function(env)
	local sources = env.require("runtime/script_sources")
	local store = env.require("runtime/code_store")
	local limits = env.require("runtime/code_limits")
	local M = {}
	function M.open(args, ctx)
		local count = (args.instanceId and 1 or 0) + (args.sourceId and 1 or 0) + (args.path and 1 or 0) + (args.recordId and 1 or 0)
		if count ~= 1 then return nil, "Choose exactly one script, source, file, or captured call" end
		local source, why, detail
		if args.instanceId then source, why, detail = sources.inspect(args.instanceId, ctx, { decompile = args.decompile, refresh = args.refresh })
		elseif args.sourceId then source, why, detail = sources.get(args.sourceId)
		elseif args.path then source, why, detail = sources.fromFile(args.path)
		else source, why, detail = env.require("tools/remote_replay").source({ recordId = args.recordId, recordRevision = args.recordRevision, arguments = args.arguments }) end
		if not source then return nil, why, detail end
		if ctx and ctx.aborted then
			local ok, cancelled = pcall(ctx.aborted)
			if not ok or cancelled then return nil, "Source request was cancelled" end
		end
		if #source.source > limits.source then
			if args.focus then
				sources.release(store.workspace); sources.pin(source.id, store.workspace)
				store.workspace.sourceId, store.workspace.sourceInfo, store.workspace.destination, store.workspace.sourceOffset = source.id, sources.describe(source), "Editor", 1
				store.changed:fire({ kind = "large_source" })
			end
			local result = sources.describe(source); result.sourceId, result.readOnly = source.id, true; return result
		end
		local document
		for _, item in ipairs(store.list()) do if item.provenance == source.provenance and item.source == source.source and item.bindingId == source.bindingId then document = item; break end end
		if not document then
			document, why = store.create(args.name or source.name, source.source, { provenance = source.provenance, bindingId = source.bindingId,
				origin = "source", readOnly = source.readOnly, sourceId = source.id, sourceInfo = sources.describe(source) })
			if not document then return nil, why end
		end
		store.attachSource(document.id, source)
		if args.focus then
			sources.release(store.workspace); store.workspace.sourceId, store.workspace.destination = nil, "Editor"
			local selected, err = store.select(document.id); if not selected then return nil, err end
			store.changed:fire({ kind = "preference" })
		end
		local result = sources.describe(source)
		result.documentId, result.revision, result.sourceId, result.bindingId = document.id, document.revision, source.id, document.bindingId
		return result
	end
	function M.extract(args)
		local item, why
		if args.documentId then item, why = store.resolve(args.documentId) else item, why = sources.get(args.sourceId) end
		if not item then return nil, why end
		local text = env.require("runtime/code_text")
		local first, after = args.first or 1, args.after or #item.source + 1
		if not text.boundary(item.source, first) or not text.boundary(item.source, after) or after < first then return nil, "Choose a valid UTF-8 source range" end
		local doc, err = store.create(args.name or ("Extracted " .. (item.name or "source.lua")), item.source:sub(first, after - 1),
			{ select = true, provenance = "Editable extraction from " .. item.id .. " bytes " .. first .. "–" .. (after - 1), origin = "extract" })
		if doc then sources.release(store.workspace); store.workspace.sourceId, store.workspace.destination = nil, "Editor"; store.changed:fire({ kind = "preference" }) end
		return doc, err
	end
	function M.caller(recordId, options, ctx)
		options = options or {}
		local records = env.require("runtime/remote_store")
		local record, why = records.get(recordId); if not record then return nil, why end
		local caller = record.caller
		if not caller or not caller.scriptId then return nil, "Calling script identity was not captured" end
		local refs = env.require("runtime/instance_refs")
		if caller.runtimeEpoch and caller.runtimeEpoch ~= refs.epoch then return nil, "Calling script belongs to an expired runtime" end
		local item, err, detail = sources.inspect(caller.scriptId, ctx, { decompile = options.decompile, refresh = options.refresh }); if not item then return nil, err, detail end
		local text, matches, terms = env.require("runtime/code_text"), {}, {}
		local path = record.pathAtCapture
		if not path then local object = refs.resolve(record.remoteId); if object then path = refs.describe(object).displayPath end end
		if type(path) == "string" and path ~= "" then terms[#terms + 1] = { value = path, kind = "path" } end
		if type(record.name) == "string" and record.name ~= "" and record.name ~= path then terms[#terms + 1] = { value = record.name, kind = "name" } end
		for _, term in ipairs(terms) do
			local found = text.search(item.source, term.value, { limit = 30 })
			for _, match in ipairs(found and found.items or {}) do
				local covered = false
				for _, existing in ipairs(matches) do if existing.first <= match.first and existing.after >= match.after then covered = true; break end end
				if not covered and #matches < 30 then match.query, match.kind = term.value, term.kind; matches[#matches + 1] = match end
			end
		end
		table.sort(matches, function(a, b) return a.first < b.first end)
		local _, starts = env.require("runtime/code_lexer").lines(item.source)
		local provenance = sources.describe(item); provenance.callSites = {}
		for _, match in ipairs(matches) do
			provenance.callSites[#provenance.callSites + 1] = { first = match.first, last = match.last, line = text.lineAt(starts, match.first), query = match.query,
				evidence = "remote " .. match.kind .. " text match; call site is not verified" }
		end
		local annotated, annotationError = records.annotateCaller(recordId, provenance); if not annotated then return nil, annotationError end
		local opened, problem, failure = M.open({ sourceId = item.id, focus = options.focus }, ctx)
		if opened and opened.documentId then
			local view = store.view(opened.documentId); local match = matches[1]
			if match then
				view.cursor, view.selection, view.sourceSearch = match.after, match.first, match.query
				if options.focus then store.changed:fire({ kind = "source_navigation", documentId = opened.documentId }) end
			end
		elseif opened and options.focus and matches[1] then
			store.workspace.sourceOffset = matches[1].first; store.changed:fire({ kind = "large_source" })
		end
		return opened, problem, failure
	end
	return M
end
