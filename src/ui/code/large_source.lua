return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local sources = env.require("runtime/script_sources")
	local documents = env.require("tools/source_documents")
	local text = env.require("runtime/code_text")
	local clock = env.require("runtime/clock")
	local store = env.require("runtime/code_store")
	local M = {}
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "LargeSourceReader", size = UDim2.fromScale(1, 1) })
		local handle = { root = root, sourceId = store.workspace.sourceId, info = store.workspace.sourceInfo, alive = true, visible = true }
		local bar = common.toolbar(root)
		local label, page, previous, nextButton
		local history, matches, matchIndex, query = {}, nil, 0, nil
		local requestGeneration = 0
		local function remember(offset)
			history[#history + 1] = offset
			if #history > 256 then table.remove(history, 1) end
		end
		local scroll = P.scroll(root, { position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 1, -common.barHeight()) })
		scroll.layout:Destroy(); scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY
		local field = P.field(scroll.instance, { role = "mono", multiline = true, height = theme.size.codeOutput * 3, bare = true })
		field.instance.TextEditable, field.instance.TextWrapped = false, false
		field.shell.AutomaticSize, field.instance.AutomaticSize = Enum.AutomaticSize.XY, Enum.AutomaticSize.XY
		local function read(offset, match)
			if not handle.alive then return nil, "Source view closed" end
			local item, why = sources.pin(handle.sourceId, handle)
			if not item then
				page = nil; handle.expired = true
				field.set("-- Expired source snapshot. Open the source menu and choose Refresh source.")
				label.setText("Expired snapshot · Refresh source")
				previous.setEnabled(false); nextButton.setEnabled(false)
				return nil, why
			end
			local result, problem = sources.read(handle.sourceId, offset)
			if not result then return nil, problem end
			handle.expired, handle.info, page = false, sources.describe(item), result
			store.workspace.sourceOffset = offset
			field.set(page.text)
			label.setText("Read only · bytes " .. offset .. "–" .. (offset + #page.text - 1) .. "/" .. page.bytes
				.. (matches and (" · " .. matchIndex .. "/" .. #matches.items .. (matches.complete and " matches" or "+ matches")) or ""))
			previous.setEnabled(#history > 0 or offset > 1); nextButton.setEnabled(page.nextOffset ~= nil)
			scroll.instance.CanvasPosition = Vector2.new(0, 0)
			if match then
				pcall(function() field.instance:CaptureFocus() end)
				field.instance.SelectionStart = math.max(1, match.first - offset + 1)
				field.instance.CursorPosition = math.min(#page.text + 1, match.after - offset + 1)
			end
			return true
		end
		local function find(value)
			local item, why = sources.get(handle.sourceId); if not item then return nil, why end
			if value ~= query then matches, why = text.search(item.source, value); query, matchIndex = value, 0 end
			if not matches then return nil, why end
			if #matches.items == 0 then return nil, "No match" end
			matchIndex = matchIndex % #matches.items + 1
			local match = matches.items[matchIndex]
			if page then remember(page.offset) end
			return read(match.first, match)
		end
		function handle.openFind()
			forms.form("Find in full source", { { key = "text", label = "Exact text (Next repeats the search)", required = true, default = query or "" } }, function(data) return find(data.text) end, { key = "large-find", submit = "Find" })
		end
		local function refresh()
			local info = handle.info or {}
			if not info.instanceId and not info.path then common.message(nil, "This captured snapshot has expired. Capture or generate its source again."); return end
			requestGeneration = requestGeneration + 1; local generation = requestGeneration
			label.setText("Refreshing source…")
			clock.spawn(function()
				local result, why = documents.open({ instanceId = info.instanceId, path = not info.instanceId and info.path or nil,
					decompile = info.method == "decompiled", refresh = true, focus = true }, { requestOwner = handle,
						aborted = function() return not handle.alive or not handle.visible or generation ~= requestGeneration or store.workspace.sourceId ~= handle.sourceId end })
				if handle.alive then if common.message(result, why) then navigate("Editor") else label.setText("Refresh failed · Retry from menu") end end
			end)
		end
		label = bar.add("Large source", function(button)
			common.menu(button, "Read-only source", { { label = "Find text", value = "find" }, { label = "Next match", value = "match" },
				{ label = "Extract selection / page into script", value = "extract" }, { label = "Refresh source", value = "refresh" },
				{ label = "Copy source reference", value = "reference" }, { label = "Return to editable script", value = "back" } }, function(action)
				if action == "find" then handle.openFind()
				elseif action == "match" then if query then common.message(find(query)) else handle.openFind() end
				elseif action == "refresh" then refresh()
				elseif action == "extract" then
					if not page then common.message(nil, "Refresh this source before extracting a range"); return end
					local a, b = field.instance.SelectionStart, field.instance.CursorPosition
					local first, after = 1, #page.text + 1
					if a > 0 and b > 0 and a ~= b then local _; _, first, after = text.slice(page.text, a, b) end
					local doc, why = documents.extract({ sourceId = handle.sourceId, first = page.offset + first - 1, after = page.offset + after - 1, name = "Source selection.lua" })
					if common.message(doc, why) then navigate("Editor") end
				elseif action == "reference" then common.copy((handle.info and handle.info.path) or handle.sourceId)
				else sources.release(store.workspace); store.workspace.sourceId = nil; navigate("Editor") end
			end)
		end, { flex = true })
		previous = bar.add("Previous", function() common.message(read(table.remove(history) or 1)) end, { icon = "arrowLeft" })
		nextButton = bar.add("Next", function()
			if page and page.nextOffset then remember(page.offset); common.message(read(page.nextOffset)) end
		end, { icon = "arrowRight" })
		function handle.setVisible(visible)
			if handle.visible == visible then return end
			handle.visible = visible
			if visible then read(store.workspace.sourceOffset or 1)
			else requestGeneration = requestGeneration + 1; sources.cancel(handle) end
		end
		function handle.destroy() if not handle.alive then return end; handle.alive = false; sources.cancel(handle); root:Destroy() end
		handle.read, handle.find, handle.refresh = read, find, refresh
		read(store.workspace.sourceOffset or 1); sources.release(store.workspace)
		return handle
	end
	return M
end
