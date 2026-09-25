-- Native Code tools address the same live model as the editor.
return function(env)
	local store = env.require("runtime/code_store")
	local runner = env.require("tools/code_runner")
	local sources = env.require("runtime/script_sources")
	local H = env.require("tools/helpers")
	local N = env.require("tools/native_helpers")
	local util = env.require("runtime/util")
	local lexer = env.require("runtime/code_lexer")
	local tools = {}
	local str, num = { type = "string" }, { type = "integer" }
	N.add(tools, "workspace_result_read", "read", "Read bounded retained detail for a large native tool result. Start with result_id; follow returned path arrays or offset. No source, object, or traffic is changed.",
		{ result_id = str, path = { type = "array", items = str, maxItems = 16 }, section = str, offset = num }, { "result_id" }, function(args) return N.read(args) end)
	local function metadata(doc, status) return { status = status or "applied", documentId = doc.id, name = doc.name, revision = doc.revision, bytes = #doc.source, readOnly = doc.readOnly == true, storage = store.storage.state } end
	local function ref(args) return args.document_id or args.tab end
	local function bind(args)
		local doc, why = store.resolve(ref(args)); if not doc then return nil, why end
		return { documentId = doc.id, revision = doc.revision }
	end
	N.add(tools, "code_tabs", "read", "List the shared Code library, live document revisions, and open/active IDs. Source is read separately.", { offset = num }, {}, function(args)
		local docs, items = store.list(), {}; local at = math.max(1, args.offset or 1)
		for i = at, math.min(#docs, at + 11) do items[#items + 1] = metadata(docs[i], "document") end
		return N.result({ items = items, activeId = store.activeId(), openIds = store.openIds(), nextOffset = at + #items <= #docs and at + #items or nil }, #items .. " documents")
	end)
	N.add(tools, "code_read", "read", "Read the latest live source or a retained version/proposal. Returns the revision for edits and Run; source pages are at most 6,000 bytes.",
		{ tab = str, document_id = str, source_id = str, version_id = str, proposal_id = str, start = num, count = num, offset = num, limit = num }, {}, function(args)
		if args.source_id then
			local page, why = sources.read(args.source_id, args.offset, math.min(args.limit or 3500, 3500)); if not page then return N.fail(why) end
			local text = page.text; page.text = nil; return N.result(page, text)
		end
		local doc, why = store.resolve(ref(args)); if not doc then return N.fail(why) end
		local source = doc.source
		if args.version_id then local found; for _, version in ipairs(doc.versions) do if version.id == args.version_id then found = version.source end end; if not found then return N.fail("Version expired") end; source = found end
		if args.proposal_id then local found; for _, proposal in ipairs(store.proposals(doc.id)) do if proposal.id == args.proposal_id then found = proposal.source end end; if not found then return N.fail("Proposal expired") end; source = found end
		local offset = args.offset or 1
		if args.start then local lines, starts = lexer.lines(source); if not starts[args.start] then return N.fail("Line is outside source") end; offset = starts[args.start]; if args.count then args.limit = math.min(3500, (starts[args.start + args.count] or #source + 1) - offset) end end
		local result = H.readSlice(doc.name, source, { offset = offset, limit = math.min(args.limit or 3500, 3500) }, 3500)
		result.data = result.data or {}; result.data.documentId, result.data.revision = doc.id, doc.revision
		if not args.version_id and not args.proposal_id then result.data.source = sources.document(doc) end
		return result
	end)
	N.add(tools, "code_write", "write", "Create or conditionally replace shared source. Existing nonempty source requires expected_revision. Saves a recoverable checkpoint and never changes the user's selection.",
		{ code = str, tab = str, document_id = str, name = str, new = { type = "boolean" }, expected_revision = num }, { "code" }, function(args, ctx, prepared)
		local doc, why
		if args.new then doc, why = store.create(args.name or args.tab, args.code, { origin = "tool" })
		else doc, why = store.update(prepared and prepared.documentId or ref(args), args.code, { expected_revision = args.expected_revision, origin = "tool" }) end
		if not doc then return N.fail(why) end; return N.result(metadata(doc), "Wrote " .. doc.name .. " at revision " .. doc.revision)
	end, function(args) if args.new then return {} end; return bind(args) end)
	N.add(tools, "code_edit", "write", "Replace an inclusive line range against expected_revision, preserving source outside the range. Never selects or runs the document.",
		{ tab = str, document_id = str, start = num, finish = num, code = str, expected_revision = num }, { "start", "finish", "code", "expected_revision" }, function(args, ctx, prepared)
		local doc, why = store.replaceLines(prepared and prepared.documentId or ref(args), args.start, args.finish, args.code, { expected_revision = args.expected_revision, origin = "tool" })
		if not doc then return N.fail(why) end; return N.result(metadata(doc), "Applied line edit at revision " .. doc.revision)
	end, bind)
	N.add(tools, "code_search", "read", "Search live documents. Literal query is the default; pattern explicitly enables a Lua pattern. Results include source offsets and revisions.",
		{ query = str, pattern = str, tab = str, document_id = str, offset = num, case_sensitive = { type = "boolean" }, whole_word = { type = "boolean" } }, {}, function(args)
		local matches, why, cursor, counts = store.search(args.query or args.pattern, { document = ref(args), pattern = args.pattern ~= nil and args.query == nil, offset = args.offset, limit = 10, caseSensitive = args.case_sensitive, wholeWord = args.whole_word })
		if not matches then return N.fail(why) end; return N.result({ items = matches, nextOffset = cursor, complete = counts.complete, retainedMatches = counts.retainedMatches }, #matches .. " matches")
	end)
	N.add(tools, "code_select", "write", "Explicitly select and open a document in the user's Code workspace.", { tab = str, document_id = str }, {}, function(args)
		local doc, why = store.select(ref(args)); if not doc then return N.fail(why) end; store.workspace.sourceId = nil; return N.result(metadata(doc), "Selected " .. doc.name)
	end)
	local run = N.add(tools, "code_run", "danger", "Run an identified stored source revision through the shared engine. Rejects source changed during approval; no source retransmission needed.",
		{ tab = str, document_id = str, expected_revision = num, timeout = { type = "number", minimum = 1, maximum = 60 } }, { "expected_revision" }, function(args, ctx, prepared)
		local snapshot, why = runner.snapshot(prepared and prepared.documentId or ref(args), args.expected_revision, "tool"); if not snapshot then return N.fail(why) end
		return runner.run(snapshot, ctx, args.timeout)
	end, bind)
	run.needs, run.timeout = { "exec" }, 65
	N.add(tools, "code_propose", "write", "Store a reviewable candidate tied to a base revision. Reports proposed; does not overwrite, select, or run live source.",
		{ tab = str, document_id = str, expected_revision = num, code = str, name = str }, { "expected_revision", "code" }, function(args)
		local proposal, why = store.propose(ref(args), args.expected_revision, args.code, args.name); if not proposal then return N.fail(why) end
		return N.result({ status = "proposed", proposalId = proposal.id, documentId = proposal.documentId, baseRevision = proposal.baseRevision }, "Proposed source change for review")
	end)
	N.add(tools, "code_versions", "read", "List recoverable source versions and pending proposals without dumping source.", { tab = str, document_id = str }, {}, function(args)
		local doc, why = store.resolve(ref(args)); if not doc then return N.fail(why) end
		local versions, proposals = {}, {}
		for _, item in ipairs(doc.versions) do versions[#versions + 1] = { id = item.id, revision = item.revision, name = item.name, at = item.at } end
		for _, item in ipairs(store.proposals(doc.id)) do proposals[#proposals + 1] = { id = item.id, baseRevision = item.baseRevision, name = item.name } end
		return N.result({ documentId = doc.id, revision = doc.revision, versions = versions, proposals = proposals }, "Retained source history")
	end)
	N.add(tools, "code_action_list", "read", "List saved action snapshots and revisions. Selecting an action does not run it.", {}, {}, function()
		local items = {}; for _, item in ipairs(store.actions()) do items[#items + 1] = { id = item.id, name = item.name, revision = item.revision, inputCount = #item.inputs } end
		return N.result({ items = items }, #items .. " saved actions")
	end)
	N.add(tools, "code_action_save", "write", "Save an inspectable source snapshot as an action with typed inputs. Updating an action is explicit and revision guarded.",
		{ document_id = str, name = str, inputs = { type = "array", items = { type = "object" } }, action_id = str, expected_revision = num, source_revision = num }, { "document_id", "name", "source_revision" }, function(args)
		local item, why = store.saveAction(args.document_id, args.name, args.inputs or {}, { id = args.action_id, expected_revision = args.expected_revision, source_revision = args.source_revision }); if not item then return N.fail(why) end
		return N.result({ id = item.id, revision = item.revision, sourceRevision = item.sourceRevision, status = "saved" }, "Saved action snapshot")
	end)
	N.add(tools, "code_action_read", "read", "Inspect a saved action's typed inputs and source snapshot before editing or running. Source is paged and the saved revision is explicit.",
		{ action_id = str, section = str, offset = num, limit = num }, { "action_id" }, function(args)
		local item, why = store.action(args.action_id); if not item then return N.fail(why) end
		if args.section == "source" then local result = H.readSlice(item.name, item.source, { offset = args.offset, limit = math.min(args.limit or 2500, 2500) }, 2500); result.data = result.data or {}; result.data.actionId, result.data.revision = item.id, item.revision; return result end
		return N.result({ actionId = item.id, revision = item.revision, name = item.name, description = item.description, inputs = item.inputs, documentId = item.documentId, sourceRevision = item.sourceRevision, bytes = #item.source }, "Saved action definition; use section=source to inspect code")
	end)
	local actionRun = N.add(tools, "code_action_run", "danger", "Run a saved action revision with validated data inputs. Input strings are never compiled or interpolated.",
		{ action_id = str, expected_revision = num, inputs = { type = "object" }, timeout = { type = "number", minimum = 1, maximum = 60 } }, { "action_id", "expected_revision" }, function(args, ctx)
		local snapshot, why = runner.actionSnapshot(args.action_id, args.expected_revision, args.inputs or {}, "tool"); if not snapshot then return N.fail(why) end; return runner.run(snapshot, ctx, args.timeout)
	end)
	actionRun.needs, actionRun.timeout = { "exec" }, 65
	return tools
end
