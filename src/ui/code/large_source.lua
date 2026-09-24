return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local sources = env.require("runtime/script_sources")
	local store = env.require("runtime/code_store")
	local M = {}
	function M.new(parent, navigate)
		local root = P.frame(parent, { name = "LargeSourceReader", size = UDim2.fromScale(1, 1) })
		local bar = common.toolbar(root)
		local label, page
		local history = {}
		local scroll = P.scroll(root, { position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 1, -common.barHeight()) })
		scroll.layout:Destroy(); scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY
		local field = P.field(scroll.instance, { role = "mono", multiline = true, height = theme.size.codeOutput * 3, bare = true })
		field.instance.TextEditable, field.instance.TextWrapped = false, false
		field.shell.AutomaticSize, field.instance.AutomaticSize = Enum.AutomaticSize.XY, Enum.AutomaticSize.XY
		local function read(offset)
			local result, why = sources.read(store.workspace.sourceId, offset)
			if not common.message(result, why) then return end
			page = result; store.workspace.sourceOffset = offset
			field.set(page.text); label.setText("Read only · " .. offset .. "/" .. page.bytes .. " bytes")
		end
		label = bar.add("Large source", function(button)
			common.menu(button, "Read-only source", { { label = "Find text", value = "find" }, { label = "Extract selection into script", value = "extract" }, { label = "Copy file / source reference", value = "reference" }, { label = "Return to editable script", value = "back" } }, function(action)
				if action == "find" then forms.form("Find in source", { { key = "text", label = "Exact text", required = true } }, function(data)
					local item, why = sources.get(store.workspace.sourceId); if not item then return nil, why end
					local at = item.source:find(data.text, (page and page.offset or 0) + 1, true) or item.source:find(data.text, 1, true)
					if not at then return nil, "No match" end; read(at); return true
				end, { key = "large-find" })
				elseif action == "extract" then
					if not page then return end
					local first, last = field.instance.SelectionStart, field.instance.CursorPosition
					local text = first > 0 and last > 0 and first ~= last and page.text:sub(math.min(first, last), math.max(first, last) - 1) or page.text
					local doc, why = store.create("Source selection.lua", text, { select = true, provenance = "Selection from " .. page.sourceId .. " at byte " .. page.offset })
					if common.message(doc, why) then store.workspace.sourceId = nil; navigate("Editor") end
				elseif action == "reference" then if page then common.copy(page.path or page.sourceId) end
				else store.workspace.sourceId = nil; navigate("Editor") end
			end)
		end, { flex = true })
		bar.add("Previous", function() read(table.remove(history) or 1) end, { icon = "arrowLeft" })
		bar.add("Next", function() if page and page.nextOffset then history[#history + 1] = page.offset; read(page.nextOffset) end end, { icon = "arrowRight" })
		local handle = { root = root, read = read, sourceId = store.workspace.sourceId }
		function handle.destroy() root:Destroy() end
		read(store.workspace.sourceOffset or 1); return handle
	end
	return M
end
