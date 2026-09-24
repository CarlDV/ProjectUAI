-- One virtual list for packed slots and expanded table nodes; drafts are separate graphs.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local common = env.require("ui/code/common")
	local forms = env.require("ui/code/forms")
	local values = env.require("runtime/values")
	local util = env.require("runtime/util")
	local overlay = env.require("ui/overlay")
	local M = {}
	function M.new(parent, options)
		options = options or {}
		local root = P.frame(parent, { name = "TypedValues", size = UDim2.fromScale(1, 1) })
		local graph, expanded = options.graph or { count = 0, slots = {}, nodes = {} }, options.expanded or {}
		local bar = common.toolbar(root)
		local title, list, refresh
		local function changed()
			graph.complete = not graph.originalCount or graph.originalCount == graph.count
			if options.onChange then options.onChange(graph) end
			refresh()
		end
		local function newNode(kind)
			if kind == "table" then
				if #graph.nodes >= values.limits.tables then return nil, "Table limit reached" end
				local id = #graph.nodes + 1; graph.nodes[id] = { id = id, entries = {} }; return { kind = "table", node = id }
			end
			return { kind = kind }
		end
		local function choose(target, callback)
			local choices = { { label = "Table", value = "table" } }
			for _, kind in ipairs(forms.types) do choices[#choices + 1] = { label = kind, value = kind } end
			common.menu(target or title, "Value type", choices, function(kind)
				local node, why = newNode(kind); if not common.message(node, why) then return end
				if kind == "table" or kind == "nil" then callback(node); changed()
				else forms.typed(node, "New " .. kind, function(value) callback(value); changed(); return true end) end
			end)
		end
		title = bar.add("Values", function() end, { flex = true, trailing = false })
		if options.editable then
			bar.add("Add argument", function(button)
				if graph.count >= values.limits.slots then common.message(nil, "At most 256 arguments"); return end
				choose(button, function(node) graph.count = graph.count + 1; graph.slots[graph.count] = node end)
			end, { icon = "plus" })
		end
		local function inspect(row)
			local node = row.node
			local text
			if node.kind == "string" or node.kind == "buffer" then
				text = node.value or ""
				local label = node.encoding == "hex" and "Retained bytes as hex" or "Retained text"
				overlay.code({ title = label .. (node.truncated and " (partial)" or " (complete)"), code = text, text = text })
			else overlay.code({ title = row.path, code = values.format(node), text = values.format(node) }) end
		end
		local function activate(row, _, button)
			if row.empty then return end
			local node, menu = row.node, { { label = "Inspect retained value", value = "inspect" } }
			if node.kind == "table" then menu[#menu + 1] = { label = expanded[row.path] and "Collapse table" or "Expand table", value = "expand" } end
			if node.kind == "Instance" then menu[#menu + 1] = { label = "Reveal in Explorer", value = "reveal" } end
			if options.editable then
				if node.kind ~= "table" and node.kind ~= "opaque" and node.kind ~= "truncated" and node.kind ~= "buffer" then menu[#menu + 1] = { label = "Edit value", value = "edit" } end
				menu[#menu + 1] = { label = "Replace with another type", value = "replace" }
				menu[#menu + 1] = { label = row.parent and "Remove entry" or "Remove argument slot", value = "remove" }
				if row.parent then menu[#menu + 1] = { label = "Edit entry key", value = "key" } end
				if node.kind == "table" then menu[#menu + 1] = { label = "Add table entry", value = "add" } end
			end
			common.menu(button or title, row.path, menu, function(action)
				if action == "inspect" then inspect(row)
				elseif action == "expand" then expanded[row.path] = not expanded[row.path]; refresh()
				elseif action == "reveal" then
					local explorer = env.require("runtime/explorer")
					if common.message(explorer.select({ node.instanceId })) and options.reveal then options.reveal("Explorer") end
				elseif action == "replace" then choose(button, function(value) row.container[row.key] = value end)
				elseif action == "edit" then
					local editable = util.deepCopy(node)
					if editable.kind == "string" and editable.encoding == "hex" then common.message(nil, "Replace this binary value with a new typed value, or retain its exact bytes"); return end
					forms.typed(editable, "Edit " .. row.path, function(value) row.container[row.key] = value; changed(); return true end, { key = "value:" .. (options.key or "draft") .. ":" .. row.path })
				elseif action == "key" then forms.typed(row.entry.key, "Entry key", function(value) row.entry.key = value; changed(); return true end)
				elseif action == "remove" then
					if row.parent then table.remove(row.parent.entries, row.index) else table.remove(graph.slots, row.index); graph.count = graph.count - 1 end
					changed()
				elseif action == "add" then
					local tableNode = graph.nodes[node.node]; if not tableNode or #tableNode.entries >= 512 then common.message(nil, "Entry limit reached"); return end
					forms.form("New table entry", { { key = "kind", label = "Key type", type = "choice", choices = { "string", "number" } }, { key = "key", label = "Key", required = true } }, function(data)
						local key = data.kind == "number" and values.node(tonumber(data.key)) or values.node(data.key)
						if key.kind == "nil" then return nil, "Enter a valid numeric key" end
						tableNode.entries[#tableNode.entries + 1] = { key = key, value = values.node("") }; expanded[row.path] = true; changed(); return true
					end)
				end
			end)
		end
		local function toggle(row) if row.node and row.node.kind == "table" then expanded[row.path] = not expanded[row.path]; refresh() end end
		list = common.virtualList(root, { name = "ArgumentTree", dense = true, position = UDim2.fromOffset(0, common.barHeight()), size = UDim2.new(1, 0, 1, -common.barHeight()),
			indent = function(row) return row.depth or 0 end,
			chevron = function(row) if row.node and row.node.kind == "table" then return expanded[row.path] and "open" or "closed" end end,
			onToggle = toggle, onContextMenu = activate,
			onSelect = function(row, index, button) if row.node and row.node.kind == "table" then toggle(row) else activate(row, index, button) end end,
			label = function(row) return row.empty and row.label or row.label .. " = " .. values.format(row.node) end })
		refresh = function()
			local rows, seen = {}, {}
			local function add(node, container, key, path, label, depth, parentNode, index, entry)
				if #rows >= 2048 then return end
				rows[#rows + 1] = { node = node, container = container, key = key, path = path, label = label, depth = depth, parent = parentNode, index = index, entry = entry }
				if node.kind == "table" and expanded[path] and not seen[node.node] then
					seen[node.node] = true; local child = graph.nodes[node.node]
					if child then for i, part in ipairs(child.entries) do add(part.value, part, "value", path .. "/" .. i, values.format(part.key), depth + 1, child, i, part) end end
				end
			end
			for i = 1, graph.count do add(graph.slots[i], graph.slots, i, "Argument " .. i, tostring(i), 0, nil, i) end
			if #rows == 0 then rows[1] = { empty = true, label = "Zero values (explicit arity 0)" } end
			title.setText((options.editable and "Draft · " or "") .. graph.count .. " values" .. (graph.complete == false and " · incomplete" or ""))
			list.set(rows, true)
		end
		local handle = { root = root, list = list, render = refresh }
		function handle.set(nextGraph) graph = nextGraph or { count = 0, slots = {}, nodes = {} }; refresh() end
		function handle.destroy() root:Destroy() end
		refresh(); return handle
	end
	return M
end
