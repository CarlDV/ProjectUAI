-- Instance tree: inspection, property access, creation and removal.
--
-- Luau cannot enumerate an instance's properties, so reads work from a curated
-- list per class family plus whatever the caller names explicitly. That is a
-- deliberate trade: a short labelled block the model can act on beats a reflection
-- trick that returns four hundred fields.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local scan = env.require("tools/scan")
	local refs = env.require("runtime/instance_refs")
	local fields = env.require("runtime/instance_fields")
	local N = env.require("tools/native_helpers").forGroup("instance")

	local native = env.require("tools/instance_native")
	local SCAN_CAP = 20000

	local schema = env.require("runtime/instance_schema")
	local propertyNames = schema.names

	local function readProperties(instance, extra)
		local rows = {}
		for _, name in ipairs(propertyNames(instance, extra)) do
			local ok, value = fields.read(instance, "property", name)
			if ok and value ~= nil and typeof(value) ~= "function" then
				local shown = H.show(value)
				-- Source can be enormous; it has its own tool.
				if name == "Source" then shown = string.format("<%d characters, use script_source>", #tostring(value)) end
				rows[#rows + 1] = { name, shown }
			end
		end
		return rows
	end

	-- Depth-limited walk. The cap is on nodes visited rather than depth alone,
	-- because one folder with nine thousand parts is the common shape and a depth
	-- limit alone would not save us from it.
	local function walk(root, maxDepth, perLevel)
		local lines = {}
		local visited = 0
		local function recurse(node, depth, prefix)
			if depth > maxDepth then return end
			local ok, children = pcall(function() return node:GetChildren() end)
			if not ok then return end
			local shown = math.min(#children, perLevel)
			for index = 1, shown do
				local child = children[index]
				visited = visited + 1
				if visited > SCAN_CAP then return end
				lines[#lines + 1] = prefix .. H.describe(child) .. " (" .. refs.id(child) .. ")"
				recurse(child, depth + 1, prefix .. "  ")
			end
			if #children > shown then
				lines[#lines + 1] = prefix .. string.format("... %d more children", #children - shown)
			end
		end
		recurse(root, 1, "")
		return lines, visited
	end

	local tools = {
		{
			name = "instance_tree",
			risk = "read",
			description = "List the children of an instance as an indented tree. Start here when exploring an unfamiliar game.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path, e.g. 'Workspace.Map' or 'me.Character'. Defaults to Workspace." },
					depth = { type = "integer", description = "Levels to descend, 1-6. Default 2.", minimum = 1, maximum = 6 },
					limit = { type = "integer", description = "Children shown per level, 1-80. Default 30.", minimum = 1, maximum = 80 },
				},
				required = {},
			},
			run = function(args)
				local root, err = H.resolve(args.path or "Workspace")
				if not root then return H.fail(err) end
				local lines, visited = walk(root, H.limit(args.depth, 2, 6), H.limit(args.limit, 30, 80))
				if #lines == 0 then
					return H.pathOf(root) .. " [" .. root.ClassName .. "] has no children."
				end
				return N.result({ instanceId = refs.id(root), shown = visited }, string.format("%s [%s], %d nodes shown:\n%s",
					H.pathOf(root), root.ClassName, visited, table.concat(lines, "\n")))
			end,
		},
		{
			name = "instance_find",
			risk = "read",
			description = "Search a subtree for instances by name and/or class. Stops when the requested result count is reached. For selected properties and paginated results, use instance_query.",
			parameters = {
				type = "object",
				properties = {
					name = { type = "string", description = "Substring of the instance name." },
					class = { type = "string", description = "Class name, matched with IsA, e.g. 'BasePart' or 'RemoteEvent'." },
					root = { type = "string", description = "Where to search. Defaults to Workspace; use 'game' to search everything." },
					limit = { type = "integer", description = "Maximum results, 1-100. Default 25.", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = function(args, ctx)
				local needle = util.trim(args.name):lower()
				local class = util.trim(args.class)
				if needle == "" and class == "" then
					return "Give a name, a class, or both."
				end
				local root, err = H.resolve(args.root or "Workspace")
				if not root then return H.fail(err) end

				local limit = H.limit(args.limit, 25, 100)
				local hits = {}
				local stats = scan.descendants(root, ctx, function(node)
					local matches = true
					if needle ~= "" and not tostring(node.Name):lower():find(needle, 1, true) then matches = false end
					if matches and class ~= "" then
						local okA, isA = pcall(function() return node:IsA(class) end)
						matches = okA and isA
					end
					if matches then hits[#hits + 1] = node end
					if #hits >= limit then return false end
				end, SCAN_CAP)
				if stats.reason == "aborted" then return { ok = false, text = "Search stopped.", data = { status = "aborted" } } end
				if stats.reason == "unreadable root" then return H.fail("could not read that subtree") end
				local note = stats.complete and "" or " Search incomplete; use instance_query or narrow the root."

				if #hits == 0 then
					return string.format("No match under %s (%d instances scanned).%s", H.pathOf(root), stats.scanned, note)
				end
				return N.result({ scanned = stats.scanned, complete = stats.complete }, string.format("%d match(es) under %s.%s\n%s", #hits, H.pathOf(root), note,
					H.list(hits, limit, function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "] (" .. refs.id(node) .. ")"
					end)))
			end,
		},
		{
			name = "instance_get",
			risk = "read",
			description = "Read an instance's properties, attributes and tags. Do this before setting anything.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to the instance." },
					properties = {
						type = "array",
						description = "Extra property names to read beyond the usual set for this class.",
						items = { type = "string" },
					},
				},
				required = { "path" },
			},
			run = native.run.instance_get,
		},
		{
			name = "instance_set",
			risk = "write",
			description = "Set one property on one instance. The value is converted to the property's existing type, so 'Size' takes '4, 1, 2' on a part and '0, 200, 0, 40' on a GUI frame.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					property = { type = "string" },
					value = { type = "string", description = "Text form of the value. Numbers comma-separated; colours as 'r, g, b' or '#rrggbb'; enums by name." },
				},
				required = { "path", "property", "value" },
			},
			run = native.run.instance_set,
		},
		{
			name = "instance_create",
			risk = "write",
			description = "Create an instance and parent it. Properties are applied after creation, in the order given.",
			parameters = {
				type = "object",
				properties = {
					class = { type = "string", description = "Class name, e.g. 'Part', 'Folder', 'Highlight'." },
					parent = { type = "string", description = "Dotted path for the parent. Defaults to Workspace." },
					name = { type = "string", description = "Name for the new instance." },
					properties = {
						type = "object",
						description = "Property name to text value, applied after creation.",
					},
				},
				required = { "class" },
			},
			run = native.run.instance_create,
		},
		{
			name = "instance_clone",
			risk = "write",
			description = "Clone an instance. The copy keeps its children.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					parent = { type = "string", description = "Where the copy goes. Defaults to the original's parent." },
					name = { type = "string", description = "Name for the copy." },
				},
				required = { "path" },
			},
			run = native.run.instance_clone,
		},
		{
			name = "instance_destroy",
			risk = "danger",
			description = "Destroy an instance and everything under it. This cannot be undone.",
			parameters = {
				type = "object",
				properties = { path = { type = "string" } },
				required = { "path" },
			},
			run = native.run.instance_destroy,
		},
		{
			name = "instance_parent",
			risk = "write",
			description = "Reparent an instance.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					parent = { type = "string", description = "New parent path, or 'nil' to detach it." },
				},
				required = { "path", "parent" },
			},
			run = native.run.instance_parent,
		},
		{
			name = "instance_attribute",
			risk = "write",
			description = "Read or write an attribute on an instance. Omit value to read.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					name = { type = "string" },
					value = { type = "string", description = "Omit to read. Numbers, booleans and strings are detected automatically." },
				},
				required = { "path", "name" },
			},
			run = native.run.instance_attribute,
		},
		{
			name = "instance_tagged",
			risk = "read",
			description = "List instances carrying a CollectionService tag, or list every tag in use.",
			parameters = {
				type = "object",
				properties = {
					tag = { type = "string", description = "Omit to list all tags in the place." },
					limit = { type = "integer", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = function(args)
				local service = env.services.CollectionService
				if not args.tag or util.trim(args.tag) == "" then
					local ok, tags = pcall(function() return service:GetAllTags() end)
					if not ok or type(tags) ~= "table" or #tags == 0 then return "No tags are in use here." end
					return util.pluralise(#tags, "tag") .. ": " .. table.concat(tags, ", ")
				end
				local ok, tagged = pcall(function() return service:GetTagged(util.trim(args.tag)) end)
				if not ok or type(tagged) ~= "table" then return H.fail("could not read that tag") end
				if #tagged == 0 then return "Nothing is tagged '" .. util.trim(args.tag) .. "'." end
				return N.result({ total = #tagged }, string.format("%d instance(s) tagged '%s':\n%s", #tagged, util.trim(args.tag),
					H.list(tagged, H.limit(args.limit, 25, 100), function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "] (" .. refs.id(node) .. ")"
					end)))
			end,
		},
	}
	for _, tool in ipairs(env.require("tools/instance_bulk")) do tools[#tools + 1] = tool end
	for _, tool in ipairs(tools) do native.extend(tool) end
	for _, tool in ipairs(env.require("tools/explorer")) do tools[#tools + 1] = tool end
	N.addReader(tools, "instance")
	return tools
end
