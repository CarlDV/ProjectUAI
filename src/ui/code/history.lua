-- Source history and game-field history share a timeline/review layout.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local tabs = env.require("ui/code/tabs")
	local forms = env.require("ui/code/forms")
	local preview = env.require("ui/code/preview")
	local store = env.require("runtime/code_store")
	local changes = env.require("runtime/changes")
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local clock = env.require("runtime/clock")
	local util = env.require("runtime/util")
	local M = {}
	local function age(at)
		local seconds = math.max(0, math.floor((clock.ms() - (at or 0)) / 1000))
		if seconds < 60 then return "Just now" elseif seconds < 3600 then return math.floor(seconds / 60) .. "m ago" elseif seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
		local ok, text = pcall(os.date, "%d %b", math.floor((at or 0) / 1000)); return ok and text or "Earlier"
	end
	local function timestamp(at)
		local ok, text = pcall(os.date, "%d %b %Y, %H:%M:%S", math.floor((at or 0) / 1000)); return ok and text or age(at)
	end
	local function objectInfo(record)
		local object = refs.resolve(record.instanceId)
		if not object then return "Unavailable object", record.instanceId end
		local info = refs.describe(object); return info.name or info.className, info.displayPath or info.name
	end
	local function afterValue(record)
		return record.uncertain and "Unknown" or values.format(record.after)
	end
	function M.new(parent, gameChanges, navigate)
		local root = P.frame(parent, { name = gameChanges and "GameChanges" or "SourceHistory", size = UDim2.fromScale(1, 1), clip = true })
		local handle = { root = root, alive = true, visible = true }
		local render, layout, renderDetail
		local selected, selectedId, documentId, reviewRevision, previewView, valuePreview, renderedKey, fieldLayout
		local remembered, filter, query, section, detailOpen, fieldIndex = {}, "all", "", "changes", false, 1
		local resultText, paneWidth = "", nil
		local bar = common.toolbar(root)
		local title = bar.add(gameChanges and "Game changes" or "History", function(button)
			if gameChanges then return end
			local options = {}; for _, doc in ipairs(store.list()) do options[#options + 1] = { label = doc.name, value = doc.id, selected = doc.id == store.activeId() } end
			common.menu(button, "Script history", options, function(id) common.message(store.select(id)) end)
		end, { flex = true, trailing = not gameChanges and "chevron" or false })
		local saveButton
		if gameChanges then
			bar.add("Explorer", function() if navigate then navigate("Explorer") end end, { tight = true, name = "ChangesExplorer" })
		else
			saveButton = bar.add("Save version", function()
				local doc = store.active(); if not doc then return end
				forms.form("Save a source version", { { key = "name", label = "Version name", required = true, default = "Version r" .. doc.revision } }, function(data)
					local version, why = store.saveVersion(doc.id, data.name)
					if not version then return nil, why end
					selectedId, filter, resultText = version.id, "all", "Version saved"; render(); return true
				end, { submit = "Save version", key = "history-save-version" })
			end, { tight = true, name = "SaveSourceVersion" })
		end
		local captionHeight = theme.text.caption.height + 12
		local caption = P.text(root, { name = "HistorySummary", text = "", role = "caption", color = theme.color.textSecondary, truncate = true,
			position = UDim2.fromOffset(10, common.barHeight()), size = UDim2.new(1, -20, 0, captionHeight) })
		local top = common.barHeight() + captionHeight
		local body = P.frame(root, { name = "HistoryBody", position = UDim2.fromOffset(0, top), size = UDim2.new(1, 0, 1, -top), clip = true })
		local timeline = P.frame(body, { name = "HistoryTimeline", clip = true })
		local detail = P.frame(body, { name = "HistoryReview", clip = true })
		local filters = tabs.new(timeline, { name = "HistoryFilters", size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(id) filter = id; render() end })
		local search = P.field(timeline, { name = "HistorySearch", placeholder = gameChanges and "Filter objects or fields" or "Filter versions", role = "small", onChange = function(text) query = text; if render then render() end end })
		search.shell.Position, search.shell.Size = UDim2.fromOffset(8, common.barHeight() + 8), UDim2.new(1, -16, 0, common.barHeight())
		local listTop = common.barHeight() * 2 + 16
		local list = common.virtualList(timeline, { name = "HistoryEntries", position = UDim2.fromOffset(0, listTop), size = UDim2.new(1, 0, 1, -listTop), rowHeight = 58,
			detail = function(item) return item.description end, meta = function(item) return item.meta end, metaWidth = 70,
			onSelect = function(item)
				selectedId, detailOpen, resultText, fieldIndex = item.id, true, "", 1
				if documentId then remembered[documentId] = selectedId end
				render(); layout()
			end })
		local empty = P.text(timeline, { name = "HistoryEmpty", text = "", wrap = true, color = theme.color.textSecondary,
			position = UDim2.fromOffset(18, listTop + 24), size = UDim2.new(1, -36, 0, 110) })
		local actions = common.toolbar(detail, { name = "HistoryReviewActions", gap = 4, padding = 4 })
		local backButton = actions.add("", function() detailOpen = false; layout() end, { icon = "arrowLeft", iconOnly = true, name = "BackToHistory" })
		local applyButton = actions.add(gameChanges and "Undo fields" or "Restore version", function()
			if not selected then return end
			if gameChanges then
				local result = changes.undo(selected.id)
				resultText = result.text
				if result.conflicts and #result.conflicts > 0 then
					local names = {}; for _, item in ipairs(result.conflicts) do names[#names + 1] = item.key end
					resultText = resultText .. ": " .. table.concat(names, ", ")
				elseif result.unrecovered and #result.unrecovered > 0 then resultText = resultText .. ": " .. table.concat(result.unrecovered, ", ") end
			else
				local item = selected
				local result, why
				if item.proposal then result, why = store.applyProposal(item.id) else result, why = store.restoreVersion(item.documentId, item.id, reviewRevision) end
				resultText = result and (item.proposal and "Proposal applied" or "Version restored") or tostring(why)
			end
			render()
		end, { name = gameChanges and "UndoGameFields" or "RestoreSourceVersion", variant = "primary", tight = true })
		local function copySelected()
			if not selected then return end
			if not gameChanges then common.copy((selected.version or selected.proposal).source); return end
			local lines = {}
			for _, record in ipairs(selected.batch.records) do local _, path = objectInfo(record); lines[#lines + 1] = path .. " · " .. record.key .. "\nBefore: " .. values.format(record.before) .. "\nAfter: " .. afterValue(record) end
			common.copy(table.concat(lines, "\n\n"))
		end
		actions.add("Copy", copySelected, { name = "CopyHistoryEntry", tight = true })
		local secondary = actions.add(gameChanges and "Reveal" or "Discard", function()
			if not selected then return end
			if gameChanges then
				local record = selected.batch.records[fieldIndex] or selected.batch.records[1]
				if record and common.message(env.require("runtime/explorer").select({ record.instanceId })) and navigate then navigate("Explorer") end
			elseif selected.proposal then common.message(store.discardProposal(selected.id)) end
		end, { name = gameChanges and "RevealChangedObject" or "DiscardSourceProposal", tight = true })
		local heading = P.text(detail, { name = "HistoryReviewTitle", text = "Select an entry", role = "body", truncate = true, position = UDim2.fromOffset(12, common.barHeight() + 8), size = UDim2.new(1, -24, 0, theme.text.body.height) })
		local metadata = P.text(detail, { name = "HistoryReviewMetadata", text = "", role = "caption", wrap = true, color = theme.color.textSecondary,
			position = UDim2.fromOffset(12, common.barHeight() + theme.text.body.height + 10), size = UDim2.new(1, -24, 0, theme.text.caption.height * 2) })
		local notice = P.text(detail, { name = "HistoryReviewNotice", text = "", role = "caption", wrap = true, color = theme.color.warn })
		local detailTabs = tabs.new(detail, { name = "HistoryReviewTabs", size = UDim2.new(1, 0, 0, common.barHeight()), onSelect = function(id) section = id; renderDetail() end })
		local content = P.frame(detail, { name = "HistoryReviewContent", bg = theme.color.codeSurface, clip = true })
		local reviewEmpty = P.text(detail, { name = "HistoryReviewEmpty", text = gameChanges and "Select an edit to inspect its before and after values." or "Select a version or proposal to review its changes.", wrap = true, color = theme.color.textSecondary,
			position = UDim2.fromOffset(20, 24), size = UDim2.new(1, -40, 0, 90) })
		local function fieldReview(batch)
			local trayHeight = 140
			local tray = P.frame(content, { name = "ChangedFieldValues", position = UDim2.new(0, 0, 1, -trayHeight), size = UDim2.new(1, 0, 0, trayHeight), bg = theme.color.codeSurface, clip = true })
			local pathLabel = P.text(tray, { name = "ChangedFieldPath", text = "", role = "caption", color = theme.color.codeGutter, truncate = true, position = UDim2.fromOffset(10, 0), size = UDim2.new(1, -20, 0, 30) })
			local beforeHost = P.frame(tray, { name = "BeforeField", position = UDim2.fromOffset(0, 30), size = UDim2.new(0.5, -3, 1, -30), clip = true })
			local afterHost = P.frame(tray, { name = "AfterField", position = UDim2.new(0.5, 3, 0, 30), size = UDim2.new(0.5, -3, 1, -30), clip = true })
			P.text(beforeHost, { text = "Before", role = "caption", color = theme.color.codeRemoveText, position = UDim2.fromOffset(10, 0), size = UDim2.new(1, -20, 0, 22) })
			P.text(afterHost, { text = "After", role = "caption", color = theme.color.codeAddText, position = UDim2.fromOffset(10, 0), size = UDim2.new(1, -20, 0, 22) })
			local beforeValues = P.frame(beforeHost, { position = UDim2.fromOffset(0, 22), size = UDim2.new(1, 0, 1, -22), clip = true })
			local afterValues = P.frame(afterHost, { position = UDim2.fromOffset(0, 22), size = UDim2.new(1, 0, 1, -22), clip = true })
			local fieldsList
			local rows = {}
			for index, record in ipairs(batch.records) do
				local name, path = objectInfo(record)
				rows[index] = { id = tostring(index), index = index, record = record, label = name .. " · " .. record.key, path = path, selected = index == fieldIndex,
					description = values.format(record.before) .. "  →  " .. afterValue(record) }
			end
			local function selectField(index)
				fieldIndex = math.max(1, math.min(#rows, index)); local item = rows[fieldIndex]; if not item then return end
				for i, row in ipairs(rows) do row.selected = i == fieldIndex end
				fieldsList.set(rows, true)
				pathLabel.Text = item.path .. " · " .. item.record.kind .. " · " .. item.record.key
				if valuePreview then valuePreview.destroy() end
				local before = preview.new(beforeValues, values.format(item.record.before), "BeforeValue")
				local after = preview.new(afterValues, afterValue(item.record) .. (item.record.uncertain and ("\n" .. tostring(item.record.reason or "The final value could not be read.")) or ""), "AfterValue")
				valuePreview = { destroy = function() before.destroy(); after.destroy() end }
			end
			fieldsList = common.virtualList(content, { name = "ChangedFields", size = UDim2.new(1, 0, 1, -trayHeight), rowHeight = 58, detail = function(item) return item.description end, onSelect = function(item) selectField(item.index) end })
			selectField(fieldIndex)
			local function sizeTray()
				local height = math.min(trayHeight, math.max(100, content.AbsoluteSize.Y * 0.46))
				tray.Position, tray.Size = UDim2.new(0, 0, 1, -height), UDim2.new(1, 0, 0, height)
				fieldsList.root.Size = UDim2.new(1, 0, 1, -height)
			end
			fieldLayout = content:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeTray); sizeTray()
			handle.fields = fieldsList
		end
		renderDetail = function()
			if not handle.alive or not handle.visible then return end
			local hasSelection = selected ~= nil
			actions.root.Visible, heading.Visible, metadata.Visible, content.Visible, reviewEmpty.Visible = hasSelection, hasSelection, hasSelection, hasSelection, not hasSelection
			detailTabs.root.Visible = hasSelection and not gameChanges
			secondary.instance.Visible = hasSelection and (gameChanges or selected.proposal ~= nil)
			notice.Visible = false
			if not selected then return end
			local doc = not gameChanges and store.resolve(selected.documentId)
			local source = selected.version or selected.proposal
			local conflict = doc and selected.proposal and doc.revision ~= selected.proposal.baseRevision
			reviewRevision = doc and doc.revision
			heading.Text = selected.label
			local message = resultText
			if gameChanges then
				local batch = selected.batch
				metadata.Text = timestamp(batch.at) .. " · " .. batch.origin .. "\n" .. #batch.records .. " fields · " .. batch.status
				applyButton.setEnabled(batch.status == "applied")
				if batch.status == "partial" and message == "" then message = "Some final values are unknown. Inspect the recorded fields." end
			else
				metadata.Text = timestamp(source.at) .. "\nCurrent r" .. doc.revision .. " → " .. (selected.proposal and ("Proposal based on r" .. source.baseRevision) or ("Saved r" .. source.revision))
				applyButton.setText(selected.proposal and "Apply proposal" or "Restore version")
				applyButton.setEnabled(not conflict and doc.source ~= source.source)
				if conflict and message == "" then message = "This proposal is based on an older revision. Review it against the current source." end
				detailTabs.set({ { id = "changes", label = "Changes" }, { id = "source", label = selected.proposal and "Proposed source" or "Saved source" }, { id = "current", label = "Current source" } }, section)
			end
			local detailTop = common.barHeight() + theme.text.body.height + theme.text.caption.height * 2 + 20
			notice.Text, notice.Visible = message, message ~= ""
			if message ~= "" then
				local height = math.max(theme.text.caption.height + 8, P.measureText(message, { role = "caption", width = math.max(80, detail.AbsoluteSize.X - 24) }).Y + 8)
				notice.Position, notice.Size = UDim2.fromOffset(12, detailTop), UDim2.new(1, -24, 0, height)
				detailTop = detailTop + height
			end
			detailTabs.root.Position = UDim2.fromOffset(0, detailTop)
			if not gameChanges then detailTop = detailTop + common.barHeight() end
			content.Position, content.Size = UDim2.fromOffset(0, detailTop), UDim2.new(1, 0, 1, -detailTop)
			local key = selected.id .. ":" .. (gameChanges and selected.batch.status or doc.revision) .. ":" .. section
			if key == renderedKey then return end
			renderedKey = key
			if fieldLayout then fieldLayout:Disconnect(); fieldLayout = nil end
			if previewView then previewView.destroy(); previewView = nil end
			if valuePreview then valuePreview.destroy(); valuePreview = nil end
			common.clear(content); handle.fields = nil
			if gameChanges then fieldReview(selected.batch)
			elseif section == "changes" then previewView = env.require("ui/code/diff_view").new(content, doc.source, source.source)
			else previewView = preview.new(content, section == "current" and doc.source or source.source, "HistorySourcePreview") end
		end
		render = function()
			if not handle.alive or not handle.visible then return end
			local items, all, counts = {}, {}, { all = 0, versions = 0, proposals = 0, applied = 0, undone = 0 }
			if gameChanges then
				for _, batch in ipairs(changes.list()) do
					local objects, names, fields = {}, {}, {}
					for _, record in ipairs(batch.records) do
						local name = objectInfo(record); fields[#fields + 1] = record.key
						if not objects[record.instanceId] then objects[record.instanceId] = true; names[#names + 1] = name end
					end
					local label = #batch.records == 1 and (names[1] .. " · " .. batch.records[1].key) or (util.pluralise(#batch.records, "field") .. " · " .. util.pluralise(#names, "object"))
					local status = { applied = "Applied", undone = "Undone", partial = "Partial" }
					all[#all + 1] = { id = batch.id, batch = batch, label = label, kind = batch.status, at = batch.at, description = batch.origin .. " · " .. age(batch.at), meta = status[batch.status] or batch.status,
						searchText = table.concat(names, " ") .. " " .. table.concat(fields, " ") .. " " .. batch.origin, color = batch.status == "partial" and theme.color.warn or nil }
				end
			else
				local doc = store.active(); saveButton.setEnabled(doc ~= nil)
				if documentId ~= (doc and doc.id) then documentId = doc and doc.id; selectedId = documentId and remembered[documentId]; detailOpen, resultText = false, "" end
				title.setText(doc and doc.name or "No script open")
				if doc then
					for _, proposal in ipairs(store.proposals(doc.id)) do
						all[#all + 1] = { id = proposal.id, documentId = doc.id, proposal = proposal, label = proposal.name, kind = "proposals", at = proposal.at, description = "Proposal · " .. age(proposal.at), meta = proposal.baseRevision ~= doc.revision and "Conflict" or ("r" .. proposal.baseRevision), color = proposal.baseRevision ~= doc.revision and theme.color.warn or nil }
					end
					for i = #doc.versions, 1, -1 do
						local version = doc.versions[i]
						all[#all + 1] = { id = version.id, documentId = doc.id, version = version, label = version.name, kind = "versions", at = version.at, description = (version.origin == "typing" and "Editing" or version.origin == "tool" and "Tool edit" or "Version") .. " · " .. age(version.at), meta = "r" .. version.revision }
					end
				end
			end
			for _, item in ipairs(all) do
				counts.all = counts.all + 1; counts[item.kind] = (counts[item.kind] or 0) + 1
				if (filter == "all" or filter == item.kind) and (query == "" or (item.label .. " " .. item.description .. " " .. (item.searchText or "")):lower():find(query:lower(), 1, true)) then items[#items + 1] = item end
			end
			if gameChanges then
				caption.Text = util.pluralise(counts.all, "edit") .. " · " .. counts.applied .. " can be undone · Local properties and attributes"
				filters.set({ { id = "all", label = "All " .. counts.all }, { id = "applied", label = "Undoable " .. counts.applied }, { id = "undone", label = "Undone " .. counts.undone } }, filter)
			else
				caption.Text = counts.versions .. " versions · " .. counts.proposals .. " proposals" .. (store.active() and (" · Current r" .. store.active().revision) or "")
				filters.set({ { id = "all", label = "All " .. counts.all }, { id = "versions", label = "Versions " .. counts.versions }, { id = "proposals", label = "Proposals " .. counts.proposals } }, filter)
			end
			selected = nil; for _, item in ipairs(items) do if item.id == selectedId then selected = item; break end end
			selected = selected or items[1]; selectedId = selected and selected.id
			for _, item in ipairs(items) do item.selected = item.id == selectedId end
			list.set(items, true)
			empty.Visible = #items == 0
			empty.Text = (query ~= "" or filter ~= "all") and "No matching entries. Try another filter." or gameChanges and "No field edits yet.\n\nProperty and attribute edits appear here with their before and after values." or "No versions yet.\n\nEdit this script or save a named version to start its history."
			if not selected then detailOpen = false end
			renderDetail(); layout()
		end
		local divider = env.require("ui/code/splitter").new(body, function(position)
			paneWidth = math.max(240, math.min(root.AbsoluteSize.X - 380, position.X - body.AbsolutePosition.X)); layout()
		end)
		layout = function()
			if not handle.alive then return end
			local wide = root.AbsoluteSize.X >= 720
			local width = math.max(240, math.min(root.AbsoluteSize.X - 380, paneWidth or root.AbsoluteSize.X * 0.32))
			timeline.Visible, detail.Visible = wide or not detailOpen, wide or detailOpen
			timeline.Size = wide and UDim2.new(0, width, 1, 0) or UDim2.fromScale(1, 1)
			detail.Position, detail.Size = UDim2.fromOffset(wide and width + 6 or 0, 0), UDim2.new(1, wide and -width - 6 or 0, 1, 0)
			backButton.instance.Visible = not wide
			divider.root.Position, divider.root.Size = UDim2.fromOffset(width, 0), UDim2.new(0, 6, 1, 0)
			divider.root.Visible = wide and handle.visible
			list.render(); renderDetail()
		end
		local off = (gameChanges and changes.changed or store.changed):connect(render)
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
		function handle.setVisible(visible) handle.visible = visible; list.visible = visible; if visible then render() end; divider.root.Visible = visible and root.AbsoluteSize.X >= 720 end
		function handle.destroy() handle.alive = false; off(); divider.destroy(); if fieldLayout then fieldLayout:Disconnect() end; if previewView then previewView.destroy() end; if valuePreview then valuePreview.destroy() end; root:Destroy() end
		handle.list, handle.render = list, render
		layout(); render(); return handle
	end
	return M
end
