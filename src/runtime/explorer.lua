-- Lazy native Explorer model. Rebuilding a view never rebuilds this service.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local schema = env.require("runtime/instance_schema")
	local values = env.require("runtime/values")
	local fields = env.require("runtime/instance_fields")
	local scan = env.require("runtime/instance_scan")
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local caps = env.require("runtime/caps")
	local M = { changed = env.require("runtime/signal").new("explorer"), selectedIds = {}, selectionRevision = 0,
		expanded = {}, drafts = {}, bookmarks = {}, view = { rows = {}, y = 0 }, primaryId = nil }
	local branches, cursors, snapshots, queries, sequence = {}, {}, {}, {}, 0
	local function token(prefix) sequence = sequence + 1; return prefix .. ":" .. refs.epoch .. ":" .. sequence end
	local SERVICE_ORDER = {
		Workspace = 1, Players = 2, Lighting = 3, MaterialService = 4, NetworkClient = 5,
		ReplicatedFirst = 6, ReplicatedStorage = 7, ServerScriptService = 8, ServerStorage = 9,
		StarterGui = 10, StarterPack = 11, StarterPlayer = 12, Teams = 13, SoundService = 14,
		TextChatService = 15, Chat = 16, VoiceChatService = 17, LocalizationService = 18,
		TestService = 19, PolicyService = 20, HttpService = 21, InsertService = 22,
		Debris = 23, TweenService = 24,
	}
	local function projection(object)
		local item = refs.describe(object)
		item.name, item.displayPath = util.ellipsis(item.name or "Unavailable", 160), util.ellipsis(item.displayPath or "", 512)
		local ok, ch = pcall(function() return object:GetChildren() end)
		item.hasChildren = ok and type(ch) == "table" and #ch > 0
		return item
	end
	local function querySignature(args)
		return util.encode({ args.rootId or refs.id(game), tostring(args.name or ""):lower(), args.class or "", args.tag or "", args.pattern == true, args.kind or "" })
	end
	local function prune(map, max)
		local list = {}; for key, item in pairs(map) do
			if item.at and clock.ms() - item.at > 300000 then
				refs.release(item); if item.disconnect then item.disconnect() end; map[key] = nil
			else list[#list + 1] = { key = key, at = item.at or 0 } end
		end
		table.sort(list, function(a, b) return a.at < b.at end)
		for i = 1, math.max(0, #list - max) do local item = map[list[i].key]; refs.release(item); if item.disconnect then item.disconnect() end; map[list[i].key] = nil end
	end
	function M.state()
		return { epoch = refs.epoch, rootId = refs.id(game), selectedIds = util.copy(M.selectedIds), primaryId = M.primaryId,
			selectionRevision = M.selectionRevision, metadata = schema.coverage, metadataVersion = schema.version,
			nilInstances = caps.fn.getnilinstances ~= nil, query = M.querySummary }
	end
	function M.select(ids, mode, expected)
		mode = mode or "replace"
		if expected ~= nil and expected ~= M.selectionRevision then return nil, "stale_revision: selection changed" end
		if mode ~= "replace" and mode ~= "add" and mode ~= "remove" and mode ~= "clear" then return nil, "Invalid selection mode" end
		if type(ids or {}) ~= "table" or #(ids or {}) > 20 then return nil, "Select at most 20 objects" end
		local result, present = {}, {}
		if mode == "add" or mode == "remove" then for _, key in ipairs(M.selectedIds) do present[key] = true end end
		for _, key in ipairs(ids or {}) do
			if mode ~= "clear" then local object, why = refs.resolve(key); if not object then return nil, why end end
			if mode == "remove" then present[key] = nil elseif mode ~= "clear" then present[key] = true end
		end
		for _, key in ipairs(M.selectedIds) do if present[key] then result[#result + 1] = key; present[key] = nil end end
		for _, key in ipairs(ids or {}) do if present[key] then result[#result + 1] = key; present[key] = nil end end
		if #result > 20 then return nil, "Select at most 20 objects" end
		refs.release(M); for _, key in ipairs(result) do refs.pin(key, M) end
		M.selectedIds, M.primaryId, M.selectionRevision = result, result[#result], M.selectionRevision + 1
		M.changed:fire({ kind = "selection", revision = M.selectionRevision }); return M.state()
	end
	function M.children(parentId, cursor, limit, root)
		if root and root ~= "nil" and root ~= "bookmarks" then return nil, "Unknown logical root" end
		limit = math.max(1, math.min(math.floor(tonumber(limit) or 25), 100))
		local parent, why, children, readable
		if root == "nil" then
			if not caps.fn.getnilinstances then return nil, "Nil-instance discovery is unavailable" end
			readable, children = pcall(caps.fn.getnilinstances); parentId = "nil"
		elseif root == "bookmarks" then
			children, readable, parentId = {}, true, "bookmarks"
			for _, key in ipairs(M.bookmarks) do local object = refs.resolve(key); if object then children[#children + 1] = object end end
		else
			parent, why = refs.resolve(parentId or refs.id(game)); if not parent then return nil, why end
			parentId = refs.id(parent); readable, children = pcall(function() return parent:GetChildren() end)
		end
		if not readable or type(children) ~= "table" then return nil, "Children are unavailable" end
		local branch = branches[parentId]
		if not branch then
			branch = { revision = 0, at = clock.ms() }; branches[parentId] = branch
			if parent then
				local connections = {}
				local function invalidate() branch.revision = branch.revision + 1; M.changed:fire({ kind = "branch", parentId = parentId }) end
				pcall(function() connections[1] = parent.ChildAdded:Connect(invalidate); connections[2] = parent.ChildRemoved:Connect(invalidate) end)
				branch.disconnect = function() for _, c in ipairs(connections) do c:Disconnect() end end
			end
		end
		branch.at = clock.ms(); prune(branches, 64)
		local sortable, signature = {}, 5381
		local isGameRoot = parentId == refs.id(game)
		for i = 1, math.min(#children, 20000) do
			local object = children[i]
			local ok, name, class = pcall(function() return object.Name, object.ClassName end)
			if ok then
				-- Skip internal artifacts like FilteredSelection if at game root
				if not (isGameRoot and (name == "FilteredSelection" or class == "FilteredSelection" or name == "")) then
					local key = refs.id(object, true)
					sortable[#sortable + 1] = { object = object, name = name, class = class, id = key }
					local identity = key .. ":" .. class .. ":" .. name
					for j = 1, #identity do signature = (signature * 33 + identity:byte(j)) % 4294967296 end
				end
			end
		end
		if isGameRoot then
			table.sort(sortable, function(a, b)
				local aOrder = SERVICE_ORDER[a.name] or SERVICE_ORDER[a.class] or 9999
				local bOrder = SERVICE_ORDER[b.name] or SERVICE_ORDER[b.class] or 9999
				if aOrder ~= bOrder then return aOrder < bOrder end
				if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
				return a.id < b.id
			end)
		else
			table.sort(sortable, function(a, b)
				local aName = tostring(a.name or ""):lower()
				local bName = tostring(b.name or ""):lower()
				if aName ~= bName then return aName < bName end
				if a.class ~= b.class then return a.class < b.class end
				return a.id < b.id
			end)
		end
		local at = 1
		if cursor then
			local stored = cursors[cursor]
			if not stored or stored.parentId ~= parentId or stored.revision ~= branch.revision or stored.signature ~= signature or clock.ms() - stored.at > 300000 then return nil, "stale_cursor: refresh this branch" end
			at = stored.next
		end
		local items = {}
		for i = at, math.min(#sortable, at + limit - 1) do items[#items + 1] = projection(sortable[i].object) end
		local nextCursor
		if at + #items <= #sortable then
			nextCursor = token("children"); cursors[nextCursor] = { parentId = parentId, revision = branch.revision, signature = signature, next = at + #items, at = clock.ms() }; prune(cursors, 128)
		end
		return { items = items, parentId = parentId, revision = branch.revision, nextCursor = nextCursor, total = #children, omitted = math.max(0, #children - #sortable), complete = #children == #sortable }
	end
	function M.collapse(parentId)
		local branch = branches[parentId]
		if branch and branch.disconnect then branch.disconnect() end
		branches[parentId] = nil; M.expanded[parentId] = nil
		for key, cursor in pairs(cursors) do if cursor.parentId == parentId then cursors[key] = nil end end
	end
	function M.query(args, ctx)
		args = args or {}; prune(queries, 8)
		local signature = querySignature(args)
		local query, at
		if args.cursor then
			local page = cursors[args.cursor]; query = page and queries[page.queryId]; at = page and page.next
			if not query or page.at + 300000 < clock.ms() or query.signature ~= signature then return nil, "stale_cursor: start a new query with the same filters" end
		else
			local root, why = refs.resolve(args.rootId or refs.id(game)); if not root then return nil, why end
			local needle, class, tag = tostring(args.name or ""):lower(), tostring(args.class or ""), args.tag
			if args.pattern then local good = pcall(string.find, "", needle); if not good then return nil, "Invalid name pattern" end end
			query = { id = token("query"), at = clock.ms(), items = {}, signature = signature }; queries[query.id] = query; at = 1
			query.stats = scan.descendants(root, ctx, function(object)
				local ok, matches = pcall(function()
					local remote = object.ClassName == "RemoteEvent" or object.ClassName == "RemoteFunction" or object.ClassName == "UnreliableRemoteEvent"
					return (args.kind ~= "remote" or remote) and (needle == "" or object.Name:lower():find(needle, 1, not args.pattern)) and (class == "" or object:IsA(class)) and (not tag or object:HasTag(tag))
				end)
				if ok and matches then query.items[#query.items + 1] = projection(object) end
				return #query.items < 1000
			end, 20000)
		end
		local result = { items = {}, queryId = query.id, scanned = query.stats.scanned, complete = query.stats.complete, reason = query.stats.reason, snapshotAt = query.at, unreadable = query.stats.unreadable, elapsedMs = clock.ms() - query.at }
		local limit = math.max(1, math.min(tonumber(args.limit) or 25, 100))
		for i = at, math.min(#query.items, at + limit - 1) do result.items[#result.items + 1] = query.items[i] end
		if at + #result.items <= #query.items then result.nextCursor = token("query-page"); cursors[result.nextCursor] = { queryId = query.id, next = at + #result.items, at = clock.ms() }; prune(cursors, 128) end
		M.querySummary = { queryId = query.id, scanned = query.stats.scanned, matches = #query.items, complete = query.stats.complete }
		return result
	end
	function M.properties(ids, section, names)
		ids = ids or M.selectedIds; section = section or "properties"
		if type(ids) ~= "table" or #ids < 1 or #ids > 20 or (names and #names > 100) then return nil, "Choose 1–20 objects and up to 100 fields" end
		if section ~= "properties" and section ~= "attributes" and section ~= "tags" then return nil, "Invalid property section" end
		prune(snapshots, 19)
		local snapshot = { id = token("properties"), at = clock.ms(), fields = {} }
		local result = { items = {}, snapshotId = snapshot.id, expiresAt = snapshot.at + 300000, coverage = schema.coverage }
		local common
		for _, key in ipairs(ids) do
			local object, why = refs.resolve(key); if not object then return nil, why end
			local available
			if names then available = names
			elseif section == "properties" then available = schema.names(object); table.insert(available, 1, "Parent")
			else
				local ok, data = pcall(function() return section == "attributes" and object:GetAttributes() or object:GetTags() end)
				if not ok then return nil, "Fields are unavailable" end
				available = section == "tags" and data or util.keys(data, true)
			end
			local map = {}; for _, name in ipairs(available) do map[name] = true end
			if not common then common = map else for name in pairs(common) do if not map[name] then common[name] = nil end end end
		end
		local kind = section == "attributes" and "attribute" or section == "tags" and "tag" or "property"
		for _, name in ipairs(util.keys(common, true)) do
			if #result.items * #ids >= 100 then result.partial = true; break end
			local row = { key = name, kind = kind, category = kind == "property" and schema.category(name) or section, writable = kind ~= "property" or schema.writable(name), observations = {} }
			local first, firstSet
			for _, key in ipairs(ids) do
				local object = refs.resolve(key); local ok, value = fields.read(object, kind, name)
				local node = ok and (name == "Source" and { kind = "source", bytes = type(value) == "string" and #value or 0 } or values.node(value)) or { kind = "unavailable" }
				row.valueType = row.valueType or (ok and typeof(value) or "unavailable")
				if not ok then row.writable = false end
				row.observations[#row.observations + 1] = { instanceId = key, value = node, readable = ok }
				if firstSet and not values.equal(value, first) then row.mixed = true end
				if not firstSet then first, firstSet = value, true end
				if ok and name ~= "Source" then snapshot.fields[key .. ":" .. kind .. ":" .. name] = node end
			end
			result.items[#result.items + 1] = row
		end
		for _, key in ipairs(ids) do refs.pin(key, snapshot) end
		snapshots[snapshot.id] = snapshot; return result
	end
	function M.expected(snapshotId, key, kind, field)
		prune(snapshots, 20); local snapshot = snapshots[snapshotId]
		if not snapshot then return nil, "expired: inspect these fields again" end
		local value = snapshot.fields[key .. ":" .. kind .. ":" .. field]
		if not value then return nil, "This field was not read in that snapshot" end
		return util.deepCopy(value)
	end
	function M.observe(ids, callback)
		local connections, alive = {}, true
		local function changed() if alive then callback() end end
		for i = 1, math.min(#ids, 20) do
			local object = refs.resolve(ids[i])
			if object then
				pcall(function() connections[#connections + 1] = object.Changed:Connect(changed) end)
				pcall(function() connections[#connections + 1] = object.AttributeChanged:Connect(changed) end)
				pcall(function() connections[#connections + 1] = object.Destroying:Connect(changed) end)
			end
		end
		return function() alive = false; for _, connection in ipairs(connections) do connection:Disconnect() end end
	end
	function M.bookmark(key, remove)
		for i, id in ipairs(M.bookmarks) do if id == key then
			if remove then table.remove(M.bookmarks, i); refs.release(M.bookmarks); for _, remaining in ipairs(M.bookmarks) do refs.pin(remaining, M.bookmarks) end end
			return true
		end end
		if remove then return true end
		if #M.bookmarks >= 20 then return nil, "At most 20 session bookmarks" end
		local target, why = refs.pin(key, M.bookmarks); if not target then return nil, why end
		M.bookmarks[#M.bookmarks + 1] = key; return true
	end
	env.require("runtime/dispose").add(function()
		for _, branch in pairs(branches) do if branch.disconnect then branch.disconnect() end end
		for _, snapshot in pairs(snapshots) do refs.release(snapshot) end
		refs.release(M); refs.release(M.bookmarks); M.changed:clear(); branches, queries, snapshots, cursors = {}, {}, {}, {}
	end, "native explorer")
	return M
end
