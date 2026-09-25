-- One live workspace per runtime. Queries never reload disk. Views are separate
-- from persisted source; callers treat returned document records as read-only.
return function(env)
	local util = env.require("runtime/util")
	local fs = env.require("runtime/fsx")
	local clock = env.require("runtime/clock")
	local limits = env.require("runtime/code_limits")
	local actions = env.require("runtime/code_actions")
	local lexer = env.require("runtime/code_lexer")
	local codeText = env.require("runtime/code_text")
	local signal = env.require("runtime/signal")
	local M = { changed = signal.new("code"), storageChanged = signal.new("code-storage"),
		storage = { state = "unloaded" }, workspace = { destination = "Editor" }, initialized = false }
	local state, views, undo, redo, typing = nil, {}, {}, {}, {}
	local dirty, saving, scheduled, disposed, blocked = false, false, false, false, nil
	local serial, mutation = 0, 0
	local slots = { "code/workspace.json", "code/workspace.backup.json" }
	local known, pendingWrites = {}, {}
	local epoch
	local function id(prefix)
		if not epoch then
			local ok, value = pcall(function() return env.hs:GenerateGUID(false) end)
			epoch = ok and value or (tostring(clock.ms()) .. "-" .. tostring(math.random(100000, 999999)))
		end
		serial = serial + 1
		return prefix .. "_" .. epoch .. "_" .. serial
	end
	M.id = id
	local function status(value, message)
		M.storage = { state = value, message = message, generation = state and state.generation or 0 }
		M.storageChanged:fire(M.storage)
	end
	local function sourceValid(source) return type(source) == "string" and #source <= limits.source and util.validUtf8(source) end
	local function nameValid(name) return type(name) == "string" and #name > 0 and #name <= 120 and util.validUtf8(name) and not name:find("[%z\1-\31]") end
	local function integer(n) return type(n) == "number" and n >= 0 and n < 1e15 and n == math.floor(n) end
	local function boundedArray(value, max) return type(value) == "table" and util.isArray(value) and #value <= max end
	local destinations = { Editor = true, Files = true, Explorer = true, Remotes = true, Output = true, History = true, Library = true, ["Game changes"] = true }
	local function preferences(value)
		value = type(value) == "table" and value or {}
		return { destination = destinations[value.destination] and value.destination or "Editor",
			split = type(value.split) == "number" and math.max(0.25, math.min(0.65, value.split)) or 0.4,
			remoteFilter = type(value.remoteFilter) == "string" and util.ellipsis(value.remoteFilter, 200) or "",
			explorerQuery = type(value.explorerQuery) == "string" and util.ellipsis(value.explorerQuery, 200) or "" }
	end
	local function validate(value)
		if type(value) ~= "table" then return nil, "invalid workspace" end
		if value.version ~= 2 then return nil, "unsupported workspace version" end
		if not integer(value.generation) or not boundedArray(value.documents, limits.documents) or not boundedArray(value.openIds, limits.openViews) or not boundedArray(value.actions or {}, limits.actions) then return nil, "invalid workspace limits" end
		local clean = { version = 2, generation = value.generation, documents = {}, openIds = {}, actions = {}, proposals = {}, preferences = preferences(value.preferences) }
		local seen, versionBytes = {}, 0
		for _, doc in ipairs(value.documents) do
			if type(doc) ~= "table" or not nameValid(doc.id) or seen[doc.id] or not nameValid(doc.name) or not sourceValid(doc.source) or not integer(doc.revision) or not boundedArray(doc.versions or {}, limits.versions) then return nil, "invalid document" end
			seen[doc.id] = true
			local item = { id = doc.id, name = doc.name, language = "luau", source = doc.source, revision = doc.revision,
				createdAt = tonumber(doc.createdAt) or 0, updatedAt = tonumber(doc.updatedAt) or 0, versions = {} }
			-- Provenance is descriptive only. Live bindings are never restored here.
			if type(doc.bindingId) == "string" then item.bindingId = doc.bindingId end
			if type(doc.provenance) == "string" and #doc.provenance <= 2000 then item.provenance = doc.provenance end
			item.readOnly = doc.readOnly == true
			if type(doc.sourceId) == "string" then item.sourceId = doc.sourceId end
			if type(doc.sourceInfo) == "table" then
				item.sourceInfo = {}
				for _, key in ipairs({ "method", "status", "origin", "instanceId", "instancePath", "runtimeEpoch", "sourceHash", "capturedAt", "path" }) do
					local entry = doc.sourceInfo[key]
					if type(entry) == "number" or type(entry) == "boolean" or (type(entry) == "string" and #entry <= 2000) then item.sourceInfo[key] = entry end
				end
			end
			for _, version in ipairs(doc.versions or {}) do
				if type(version) ~= "table" or not nameValid(version.id) or not sourceValid(version.source) or not integer(version.revision) then return nil, "invalid source version" end
				versionBytes = versionBytes + #version.source
				item.versions[#item.versions + 1] = { id = version.id, source = version.source, revision = version.revision,
					name = util.ellipsis(version.name or "Checkpoint", 120), origin = util.ellipsis(version.origin or "saved", 40), at = tonumber(version.at) or 0 }
			end
			clean.documents[#clean.documents + 1] = item
		end
		if versionBytes > limits.versionBytes then return nil, "source history exceeds its budget" end
		local opened = {}
		for _, key in ipairs(value.openIds) do
			if not seen[key] or opened[key] then return nil, "invalid open document" end
			opened[key] = true; clean.openIds[#clean.openIds + 1] = key
		end
		if value.activeId ~= nil and not opened[value.activeId] then return nil, "invalid active document" end
		clean.activeId = value.activeId
		local actionIds = {}
		for _, item in ipairs(value.actions or {}) do
			if type(item) ~= "table" or not nameValid(item.id) or actionIds[item.id] or not nameValid(item.name) or not sourceValid(item.source) or not integer(item.revision) then return nil, "invalid action" end
			local defs, why = actions.definitions(item.inputs or {})
			if not defs then return nil, why end
			actionIds[item.id] = true
			clean.actions[#clean.actions + 1] = { id = item.id, name = item.name, source = item.source, revision = item.revision,
				inputs = defs, description = util.ellipsis(item.description or "", 500), documentId = type(item.documentId) == "string" and item.documentId or nil,
				sourceRevision = tonumber(item.sourceRevision) or 0, bindingId = type(item.bindingId) == "string" and item.bindingId or nil, createdAt = tonumber(item.createdAt) or 0, updatedAt = tonumber(item.updatedAt) or 0 }
		end
		if not boundedArray(value.proposals or {}, limits.documents * limits.proposals) then return nil, "invalid proposals" end
		local counts, proposalIds = {}, {}
		for _, proposal in ipairs(value.proposals or {}) do
			if type(proposal) ~= "table" or not seen[proposal.documentId] or not nameValid(proposal.id) or proposalIds[proposal.id] or not integer(proposal.baseRevision) or not sourceValid(proposal.source) then return nil, "invalid proposal" end
			counts[proposal.documentId] = (counts[proposal.documentId] or 0) + 1
			if counts[proposal.documentId] > limits.proposals then return nil, "too many proposals" end
			proposalIds[proposal.id] = true
			clean.proposals[#clean.proposals + 1] = { id = proposal.id, documentId = proposal.documentId, source = proposal.source,
				baseRevision = proposal.baseRevision, at = tonumber(proposal.at) or 0, name = util.ellipsis(proposal.name or "Proposed change", 120) }
		end
		return clean
	end
	M.validate = validate
	local function schedule()
		if scheduled or disposed or not fs.enabled or blocked then return end
		scheduled = true
		clock.delay(limits.flushDelay, function()
			scheduled = false
			if not disposed and dirty then M.saveNow() end
		end)
	end
	local function changed(kind, doc, origin)
		dirty, mutation = true, mutation + 1
		status(fs.enabled and (blocked and "protected" or "dirty") or "session_only", blocked)
		M.changed:fire({ kind = kind, documentId = doc and doc.id, revision = doc and doc.revision, origin = origin })
		schedule()
	end
	local function fresh(name, source)
		return { id = id("doc"), name = name or "Untitled.lua", source = source or "", language = "luau", revision = 0,
			createdAt = clock.ms(), updatedAt = clock.ms(), versions = {} }
	end
	function M.init()
		if M.initialized then return M end
		M.initialized = true
		state = { version = 2, generation = 0, documents = {}, openIds = {}, actions = {}, proposals = {} }
		if fs.enabled then
			for _, path in ipairs(slots) do
				if fs.exists(path) then
					local raw, why = fs.read(path)
					if not raw then blocked = "Workspace snapshot cannot be read: " .. tostring(why)
					elseif #raw > limits.envelope then blocked = "Workspace snapshot exceeds the supported size"
					else
						local decoded = util.decode(raw)
						local valid, invalid = validate(decoded)
						known[path] = { raw = raw, valid = valid, generation = valid and valid.generation or -1 }
						if valid and (not M.loadedSnapshot or valid.generation > state.generation) then state, M.loadedSnapshot = valid, path end
						if decoded and decoded.version ~= 2 then blocked = invalid end
					end
				end
			end
			if not M.loadedSnapshot and not blocked then
				for _, path in ipairs({ "code/tabs.json", "files/code/tabs.json" }) do
					if fs.exists(path) then
						local raw = fs.read(path)
						if not raw then blocked = "Legacy workspace cannot be read"; break end
						local old = #raw <= limits.envelope and util.decode(raw)
						if type(old) == "table" and boundedArray(old.tabs, limits.documents) and #old.tabs > 0 then
							local docs, good = {}, true
							for _, tab in ipairs(old.tabs) do
								if type(tab) ~= "table" or not sourceValid(tab.code) or not nameValid(tab.name) then good = false; break end
								docs[#docs + 1] = fresh(tab.name, tab.code)
							end
							if good then
								state.documents = docs
								for i = 1, math.min(#docs, limits.openViews) do state.openIds[i] = docs[i].id end
								state.activeId = state.openIds[math.max(1, math.min(#state.openIds, tonumber(old.active) or 1))]
								M.migratedFrom, dirty = path, true; break
							end
						end
					end
				end
			end
		end
		if #state.documents == 0 then
			local doc = fresh(); state.documents[1], state.openIds[1], state.activeId = doc, doc.id, doc.id; dirty = true
		end
		state.preferences = preferences(state.preferences)
		for key, value in pairs(state.preferences) do M.workspace[key] = value end
		status(not fs.enabled and "session_only" or blocked and "protected" or dirty and "dirty" or "saved", blocked)
		env.require("runtime/dispose").add(function() M.saveNow(); disposed = true end, "code workspace")
		if dirty then schedule() end
		return M
	end
	function M.list() M.init(); return state.documents end
	function M.preference(key, value)
		M.init()
		local nextValue = util.copy(state.preferences); nextValue[key] = value; nextValue = preferences(nextValue)
		if nextValue[key] == nil or state.preferences[key] == nextValue[key] then return end
		state.preferences, M.workspace[key] = nextValue, nextValue[key]; changed("preference", nil, "view")
	end
	function M.openIds() M.init(); return util.copy(state.openIds) end
	function M.activeId() M.init(); return state.activeId end
	function M.resolve(ref)
		M.init(); if ref == nil or ref == "" then ref = state.activeId end
		for _, doc in ipairs(state.documents) do if doc.id == ref then return doc end end
		local matches = {}
		for _, doc in ipairs(state.documents) do if doc.name == ref then matches[#matches + 1] = doc end end
		if #matches == 1 then return matches[1] end
		if #matches > 1 then return nil, "Ambiguous name; use a document ID" end
		local index = tonumber(ref)
		if index and index == math.floor(index) and state.documents[index] then return state.documents[index] end
		return nil, "Document not found"
	end
	function M.active() return M.resolve(M.activeId()) end
	function M.view(ref)
		local doc = M.resolve(ref); if not doc then return nil end
		views[doc.id] = views[doc.id] or { cursor = -1, selection = -1, x = 0, y = 0 }
		return views[doc.id]
	end
	function M.open(ref, selectIt)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		local exists = false; for _, key in ipairs(state.openIds) do if key == doc.id then exists = true end end
		if not exists then
			if #state.openIds >= limits.openViews then return nil, "Close a view first (10 open views maximum)" end
			state.openIds[#state.openIds + 1] = doc.id
		end
		if selectIt then state.activeId = doc.id end
		if doc.sourceId then doc.snapshotState = env.require("runtime/script_sources").get(doc.sourceId) and "available" or "expired" end
		changed("selection", doc, "view"); return doc
	end
	function M.select(ref) return M.open(ref, true) end
	function M.close(ref)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		env.require("runtime/script_sources").release(doc)
		for i = #state.openIds, 1, -1 do if state.openIds[i] == doc.id then table.remove(state.openIds, i) end end
		if state.activeId == doc.id then state.activeId = state.openIds[#state.openIds] end
		typing[doc.id] = nil; changed("close", doc, "user"); return true
	end
	function M.create(name, source, options)
		M.init(); options = options or {}; source = source or ""
		if not nameValid(name or "Untitled.lua") or not sourceValid(source) then return nil, "Invalid name or source; editable source is limited to 256,000 UTF-8 bytes" end
		if #state.documents >= limits.documents then return nil, "The library is full (" .. limits.documents .. " scripts). Remove one before adding another." end
		if options.select and #state.openIds >= limits.openViews then return nil, "Close a view first (10 open views maximum)" end
		local doc = fresh(name, source); doc.provenance, doc.bindingId = options.provenance, options.bindingId
		doc.readOnly, doc.sourceId, doc.sourceInfo = options.readOnly == true, options.sourceId, options.sourceInfo
		state.documents[#state.documents + 1] = doc
		if options.select then state.openIds[#state.openIds + 1], state.activeId = doc.id, doc.id end
		changed("create", doc, options.origin); return doc
	end
	function M.attachSource(ref, source)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		local snapshots = env.require("runtime/script_sources")
		snapshots.release(doc)
		doc.sourceId, doc.sourceInfo, doc.readOnly = source.id, snapshots.describe(source), source.readOnly == true
		doc.snapshotState = source.status
		changed("metadata", doc, "source"); return doc
	end
	function M.rename(ref, name)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if not nameValid(name) then return nil, "Use a name of 1–120 UTF-8 bytes" end
		if doc.name == name then return doc end
		doc.name = name; changed("rename", doc, "user"); return doc
	end
	function M.delete(ref)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		M.close(doc.id)
		for i, item in ipairs(state.documents) do if item == doc then table.remove(state.documents, i); break end end
		for i = #state.proposals, 1, -1 do if state.proposals[i].documentId == doc.id then table.remove(state.proposals, i) end end
		views[doc.id], undo[doc.id], redo[doc.id], typing[doc.id] = nil, nil, nil, nil
		changed("delete", doc, "user"); return true
	end
	local function trimVersions()
		local bytes = 0
		for _, doc in ipairs(state.documents) do
			while #doc.versions > limits.versions do table.remove(doc.versions, 1) end
			for _, version in ipairs(doc.versions) do bytes = bytes + #version.source end
			for _, stack in ipairs({ undo[doc.id] or {}, redo[doc.id] or {} }) do
				while #stack > limits.versions do table.remove(stack, 1) end
				for _, source in ipairs(stack) do bytes = bytes + #source end
			end
		end
		while bytes > limits.versionBytes do
			local chosen
			for _, doc in ipairs(state.documents) do
				if #doc.versions > 0 and (not chosen or doc.versions[1].at < chosen.versions[1].at) then chosen = doc end
			end
			if chosen then bytes = bytes - #table.remove(chosen.versions, 1).source
			else
				local stack
				for _, doc in ipairs(state.documents) do
					for _, candidate in ipairs({ undo[doc.id] or {}, redo[doc.id] or {} }) do if #candidate > 0 and (not stack or #candidate > #stack) then stack = candidate end end
				end
				if not stack then break end
				bytes = bytes - #table.remove(stack, 1)
			end
		end
	end
	local function checkpoint(doc, name, origin)
		local version = { id = id("version"), source = doc.source, revision = doc.revision, name = name or "Checkpoint", origin = origin or "user", at = clock.ms() }
		doc.versions[#doc.versions + 1] = version; trimVersions(); return version
	end
	function M.saveVersion(ref, name)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		local version = checkpoint(doc, util.ellipsis(name or "Saved version", 120)); typing[doc.id] = nil
		changed("version", doc, "user"); return version
	end
	function M.update(ref, source, options)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if doc.readOnly then return nil, "Read-only source snapshot; extract an editable copy first" end
		options = options or {}
		if options.expected_revision ~= nil and options.expected_revision ~= doc.revision then return nil, "stale_revision: read the current document before applying" end
		if options.origin == "tool" and doc.source ~= "" and options.expected_revision == nil then return nil, "expected_revision is required for an existing source document" end
		if not sourceValid(source) then return nil, "Source must be valid UTF-8 and at most 256,000 bytes; existing source was preserved" end
		if doc.source == source then return doc end
		local burst = options.origin == "typing" and typing[doc.id] and clock.ms() - typing[doc.id] < 1000
		if not burst then
			checkpoint(doc, options.label or "Before edit", options.origin)
			undo[doc.id] = undo[doc.id] or {}; table.insert(undo[doc.id], doc.source)
			while #undo[doc.id] > limits.versions do table.remove(undo[doc.id], 1) end
		end
		typing[doc.id] = options.origin == "typing" and clock.ms() or nil
		redo[doc.id] = {}; doc.source, doc.revision, doc.updatedAt = source, doc.revision + 1, clock.ms()
		trimVersions()
		changed("source", doc, options.origin); return doc
	end
	function M.replaceLines(ref, first, last, replacement, options)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		local lines, starts = lexer.lines(doc.source)
		if type(first) ~= "number" or type(last) ~= "number" or first ~= math.floor(first) or last ~= math.floor(last) or first < 1 or last < first or last > #lines or type(replacement) ~= "string" then return nil, "Invalid line range" end
		local endAt = starts[last] + #lines[last] - 1
		return M.update(doc.id, doc.source:sub(1, starts[first] - 1) .. replacement .. doc.source:sub(endAt + 1), options)
	end
	local function sourceUndo(ref, reverse)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if doc.readOnly then return nil, "Read-only source snapshot; extract an editable copy first" end
		local from, to = reverse and redo or undo, reverse and undo or redo
		if not from[doc.id] or #from[doc.id] == 0 then return nil, "No source " .. (reverse and "redo" or "undo") .. " available" end
		local source = table.remove(from[doc.id]); to[doc.id] = to[doc.id] or {}; table.insert(to[doc.id], doc.source)
		checkpoint(doc, "Before " .. (reverse and "redo" or "undo")); doc.source, doc.revision = source, doc.revision + 1; typing[doc.id] = nil
		doc.updatedAt = clock.ms(); trimVersions()
		changed("source", doc, "history"); return doc
	end
	function M.undoSource(ref) return sourceUndo(ref, false) end
	function M.redoSource(ref) return sourceUndo(ref, true) end
	function M.restoreVersion(ref, versionId, revision)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if revision == nil then return nil, "expected_revision is required" end
		for _, version in ipairs(doc.versions) do
			if version.id == versionId then return M.update(doc.id, version.source, { expected_revision = revision, origin = "restore", label = "Before restore" }) end
		end
		return nil, "Version expired"
	end
	function M.proposals(ref)
		M.init(); local out = {}
		for _, item in ipairs(state.proposals) do if not ref or item.documentId == ref then out[#out + 1] = item end end
		return out
	end
	function M.propose(ref, revision, source, name)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if doc.readOnly then return nil, "Read-only source snapshot; extract an editable copy first" end
		if not integer(revision) or not sourceValid(source) then return nil, "A base revision and bounded UTF-8 source are required" end
		if #M.proposals(doc.id) >= limits.proposals then return nil, "Resolve or discard a pending proposal first (3 per document)" end
		local proposal = { id = id("proposal"), documentId = doc.id, baseRevision = revision, source = source, name = util.ellipsis(name or "Proposed change", 120), at = clock.ms() }
		state.proposals[#state.proposals + 1] = proposal; changed("proposal", doc, "tool"); return proposal
	end
	function M.discardProposal(key)
		M.init(); for i, proposal in ipairs(state.proposals) do
			if proposal.id == key then table.remove(state.proposals, i); changed("proposal", M.resolve(proposal.documentId), "user"); return true end
		end
		return nil, "Proposal expired or already applied"
	end
	function M.applyProposal(key)
		M.init(); for index, proposal in ipairs(state.proposals) do
			if proposal.id == key then
				local current, err = M.resolve(proposal.documentId); if not current then return nil, err end
				if current.revision ~= proposal.baseRevision then return nil, "stale_revision: read the current document before applying" end
				local identical = current.source == proposal.source
				table.remove(state.proposals, index)
				local doc, why = M.update(proposal.documentId, proposal.source, { expected_revision = proposal.baseRevision, origin = "proposal", label = "Before proposal" })
				if not doc then table.insert(state.proposals, index, proposal); return nil, why end
				if identical then changed("proposal", doc, "proposal") end
				return doc
			end
		end
		return nil, "Proposal expired or already applied"
	end
	function M.search(query, options)
		M.init(); options = options or {}
		if type(query) ~= "string" or query == "" then return nil, "Enter a search" end
		local docs = state.documents
		if options.document then local doc, why = M.resolve(options.document); if not doc then return nil, why end; docs = { doc } end
		local out, count, skipped, complete = {}, 0, math.max(0, tonumber(options.offset) or 0), true
		local searchOptions = util.copy(options); searchOptions.limit = 10000
		for _, doc in ipairs(docs) do
			local found, why = codeText.search(doc.source, query, searchOptions); if not found then return nil, why end
			complete = complete and found.complete
			local lines, starts = lexer.lines(doc.source)
			for _, match in ipairs(found.items) do
				count = count + 1
				if count > skipped and #out < math.min(options.limit or 25, 25) then
					local line = codeText.lineAt(starts, match.first)
					out[#out + 1] = { documentId = doc.id, revision = doc.revision, line = line, column = codeText.column(doc.source, starts[line], match.first),
						first = match.first, last = match.last, text = util.ellipsis(lines[line], 160) }
				end
			end
		end
		return out, nil, count > skipped + #out and skipped + #out or nil, { complete = complete, retainedMatches = count }
	end

	function M.actions() M.init(); return state.actions end
	function M.action(key) M.init(); for _, item in ipairs(state.actions) do if item.id == key then return item end end; return nil, "Action not found" end
	function M.saveAction(ref, name, definitions, options)
		local doc, why = M.resolve(ref); if not doc then return nil, why end
		if doc.readOnly then return nil, "Read-only source snapshot; extract an editable copy before creating an action" end
		options = options or {}; local defs, err = actions.definitions(definitions or {}); if not defs then return nil, err end
		if options.source_revision ~= nil and options.source_revision ~= doc.revision then return nil, "stale_revision: source changed after the action comparison" end
		if not nameValid(name) then return nil, "Invalid action name" end
		local item
		if options.id then
			item, err = M.action(options.id); if not item then return nil, err end
			if options.expected_revision ~= item.revision then return nil, "stale_revision: refresh the action comparison" end
			if options.source_revision == nil then return nil, "source_revision is required when updating an action" end
		elseif #state.actions >= limits.actions then return nil, "The library is full (" .. limits.actions .. " actions). Remove one before adding another." end
		if not item then item = { id = id("action"), revision = 0, createdAt = clock.ms() }; state.actions[#state.actions + 1] = item end
		item.name, item.source, item.inputs, item.description = name, doc.source, defs, util.ellipsis(options.description or "", 500)
		item.documentId, item.sourceRevision, item.updatedAt, item.revision = doc.id, doc.revision, clock.ms(), item.revision + 1
		item.bindingId = doc.bindingId
		changed("action", doc, "user"); return item
	end
	function M.deleteAction(key)
		M.init(); for i, item in ipairs(state.actions) do if item.id == key then table.remove(state.actions, i); changed("action", nil, "user"); return true end end
		return nil, "Action not found"
	end
	function M.saveNow()
		if not M.initialized then return true end
		if not fs.enabled then status("session_only", "This host has no filesystem"); return false, "Session only" end
		if blocked then status("protected", blocked); return false, blocked end
		if saving then schedule(); return false, "Save already in progress" end
		saving = true
		local function persist()
			for _, path in ipairs(slots) do
				local expected, present = known[path], fs.exists(path)
				local current = present and fs.read(path) or nil
				if present and current == nil then
					status("failed", "Workspace data could not be read; drafts are retained and retry is required.")
					return false, M.storage.message
				end
				if pendingWrites[path] and current == pendingWrites[path].raw then
					expected, known[path] = pendingWrites[path], pendingWrites[path]
					pendingWrites[path] = nil
				end
				if (expected and current ~= expected.raw) or (not expected and present) then
					status("conflict", "Workspace changed on disk; live drafts are retained. Export them before reloading the external change.")
					return false, M.storage.message
				end
			end
			if not dirty and known[slots[1]] and known[slots[2]] and known[slots[1]].valid and known[slots[2]].valid then return true end
			status("saving")
			local revision = mutation
			local snapshot = util.deepCopy(state); snapshot.generation = state.generation + 1
			local valid, why = validate(snapshot)
			if not valid then status("failed", why); return false, why end
			local raw = util.encode(valid)
			if #raw > limits.envelope then status("failed", "Workspace exceeds 12 MiB"); return false, M.storage.message end
			local order = { slots[1], slots[2] }
			if (known[order[1]] and known[order[1]].generation or -1) > (known[order[2]] and known[order[2]].generation or -1) then order[1], order[2] = order[2], order[1] end
			for _, path in ipairs(order) do
				local old = known[path]
				if old and not old.valid and old.raw and not old.recovery then
					local recovery = "code/" .. id("recovery") .. ".json"
					local preserved = fs.write(recovery, old.raw)
					if not preserved or fs.read(recovery) ~= old.raw then status("failed", "Cannot preserve damaged snapshot before replacement"); return false, M.storage.message end
					old.recovery = recovery
				end
				pendingWrites[path] = { raw = raw, valid = valid, generation = valid.generation }
				local called, wrote = pcall(fs.write, path, raw)
				local readable, readback = pcall(fs.read, path)
				if not readable or readback == nil then status("failed", "Draft retained in memory. Saved data could not be read back; retry is required."); return false, M.storage.message end
				pendingWrites[path] = nil
				-- A failed host write may still have changed the file. Remember our
				-- readback so Retry does not mistake that damage for an external edit.
				if not called or not wrote or readback ~= raw then
					local decoded = readback and #readback <= limits.envelope and util.decode(readback)
					local recovered = decoded and validate(decoded)
					known[path] = { raw = readback, valid = recovered, generation = recovered and recovered.generation or -1 }
					dirty = true; status("failed", "Draft retained in memory. The host did not save a complete snapshot; retry is required.")
					return false, M.storage.message
				end
				known[path] = { raw = raw, valid = valid, generation = valid.generation }
				state.generation = valid.generation
			end
			dirty = mutation ~= revision
			status(dirty and "dirty" or "saved"); if dirty then schedule() end
			return true
		end
		local ok, result, why = pcall(persist)
		saving = false
		if not ok then
			dirty = true; status("failed", "Draft retained in memory. The host interrupted saving; retry is required.")
			return false, M.storage.message
		end
		return result, why
	end
	function M.preflightReplacement()
		if not M.initialized then return true end
		if not fs.enabled then return false, "Code documents are session only. Export them or enable filesystem storage before replacing UAI." end
		return M.saveNow()
	end
	function M.isDirty() return dirty end
	return M
end
