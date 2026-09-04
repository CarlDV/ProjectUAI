-- Instance tree: inspection, property access, creation and removal.
--
-- Luau cannot enumerate an instance's properties, so reads work from a curated
-- list per class family plus whatever the caller names explicitly. That is a
-- deliberate trade: a short labelled block the model can act on beats a reflection
-- trick that returns four hundred fields.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")

	local SCAN_CAP = 20000

	local COMMON = { "Name", "ClassName" }

	local BY_CLASS = {
		{ "BasePart", { "Position", "Size", "Orientation", "Anchored", "CanCollide", "CanTouch", "Transparency", "Color", "Material", "Massless", "Shape", "Reflectance" } },
		{ "Model", { "PrimaryPart", "WorldPivot" } },
		{ "GuiObject", { "Position", "Size", "AnchorPoint", "Visible", "BackgroundColor3", "BackgroundTransparency", "ZIndex", "LayoutOrder", "Rotation", "ClipsDescendants", "AutomaticSize", "AbsolutePosition", "AbsoluteSize" } },
		{ "TextLabel", { "Text", "TextColor3", "TextSize", "Font", "TextWrapped", "RichText", "TextXAlignment", "TextYAlignment", "TextTransparency" } },
		{ "TextButton", { "Text", "TextColor3", "TextSize", "Font", "AutoButtonColor" } },
		{ "TextBox", { "Text", "PlaceholderText", "TextColor3", "TextSize", "ClearTextOnFocus", "MultiLine" } },
		{ "ImageLabel", { "Image", "ImageColor3", "ImageTransparency", "ScaleType" } },
		{ "ScrollingFrame", { "CanvasSize", "CanvasPosition", "ScrollBarThickness", "AutomaticCanvasSize", "ScrollingEnabled" } },
		{ "ScreenGui", { "Enabled", "DisplayOrder", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior" } },
		{ "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight", "Sit", "PlatformStand", "MoveDirection", "RigType" } },
		{ "Player", { "DisplayName", "UserId", "AccountAge", "Team", "TeamColor", "CharacterAppearanceId" } },
		{ "Camera", { "CFrame", "FieldOfView", "CameraType", "CameraSubject", "Focus" } },
		{ "Sound", { "SoundId", "Volume", "Playing", "Looped", "TimePosition", "PlaybackSpeed" } },
		{ "Light", { "Brightness", "Color", "Range", "Enabled", "Shadows" } },
		{ "Lighting", { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "FogColor", "FogStart", "FogEnd", "GlobalShadows", "ExposureCompensation" } },
		{ "ValueBase", { "Value" } },
		{ "Decal", { "Texture", "Transparency", "Face" } },
		{ "Tool", { "RequiresHandle", "CanBeDropped", "Enabled", "ToolTip" } },
		{ "ProximityPrompt", { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled" } },
		{ "Attachment", { "Position", "WorldPosition", "Axis" } },
		{ "UIListLayout", { "FillDirection", "Padding", "SortOrder", "HorizontalAlignment", "VerticalAlignment", "Wraps" } },
		{ "UIPadding", { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } },
		{ "UIStroke", { "Color", "Thickness", "Transparency", "ApplyStrokeMode" } },
		{ "UICorner", { "CornerRadius" } },
		{ "UIScale", { "Scale" } },
		{ "CanvasGroup", { "GroupTransparency", "GroupColor3" } },
		{ "Script", { "Enabled", "RunContext" } },
		{ "LuaSourceContainer", { "Source" } },
		{ "Terrain", { "WaterColor", "WaterTransparency", "WaterWaveSize" } },
		{ "SpawnLocation", { "Enabled", "Neutral", "TeamColor", "Duration" } },
		{ "Seat", { "Occupant", "Disabled" } },
	}

	local function propertyNames(instance, extra)
		local names, seen = {}, {}
		local function add(name)
			if type(name) == "string" and name ~= "" and not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
		for _, name in ipairs(COMMON) do add(name) end
		for _, entry in ipairs(BY_CLASS) do
			local ok, isA = pcall(function() return instance:IsA(entry[1]) end)
			if ok and isA then
				for _, name in ipairs(entry[2]) do add(name) end
			end
		end
		for _, name in ipairs(extra or {}) do add(name) end
		return names
	end

	local function readProperties(instance, extra)
		local rows = {}
		for _, name in ipairs(propertyNames(instance, extra)) do
			local ok, value = pcall(function() return instance[name] end)
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
				lines[#lines + 1] = prefix .. H.describe(child)
				recurse(child, depth + 1, prefix .. "  ")
			end
			if #children > shown then
				lines[#lines + 1] = prefix .. string.format("... %d more children", #children - shown)
			end
		end
		recurse(root, 1, "")
		return lines, visited
	end

	return {
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
				return string.format("%s [%s], %d nodes shown:\n%s",
					H.pathOf(root), root.ClassName, visited, table.concat(lines, "\n"))
			end,
		},
		{
			name = "instance_find",
			risk = "read",
			description = "Search a subtree for instances by name and/or class. Name matching is a case-insensitive substring.",
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
			run = function(args)
				local needle = util.trim(args.name):lower()
				local class = util.trim(args.class)
				if needle == "" and class == "" then
					return "Give a name, a class, or both."
				end
				local root, err = H.resolve(args.root or "Workspace")
				if not root then return H.fail(err) end

				local ok, descendants = pcall(function() return root:GetDescendants() end)
				if not ok then return H.fail("could not read that subtree") end

				local limit = H.limit(args.limit, 25, 100)
				local hits, scanned = {}, 0
				for _, node in ipairs(descendants) do
					scanned = scanned + 1
					if scanned > SCAN_CAP then break end
					local matches = true
					if needle ~= "" and not tostring(node.Name):lower():find(needle, 1, true) then matches = false end
					if matches and class ~= "" then
						local okA, isA = pcall(function() return node:IsA(class) end)
						matches = okA and isA
					end
					if matches then hits[#hits + 1] = node end
				end

				if #hits == 0 then
					return string.format("No match under %s (%d instances scanned).", H.pathOf(root), scanned)
				end
				return string.format("%d match(es) under %s:\n%s", #hits, H.pathOf(root),
					H.list(hits, limit, function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "]"
					end))
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local blocks = { H.pathOf(instance) .. " [" .. instance.ClassName .. "]" }
				blocks[#blocks + 1] = H.keyValues(readProperties(instance, args.properties))

				local okAttrs, attributes = pcall(function() return instance:GetAttributes() end)
				if okAttrs and type(attributes) == "table" and util.count(attributes) > 0 then
					local rows = {}
					for _, key in ipairs(util.keys(attributes, true)) do
						rows[#rows + 1] = { key, H.show(attributes[key]) }
					end
					blocks[#blocks + 1] = "Attributes:\n" .. H.keyValues(rows)
				end

				local okTags, tags = pcall(function() return instance:GetTags() end)
				if okTags and type(tags) == "table" and #tags > 0 then
					blocks[#blocks + 1] = "Tags: " .. table.concat(tags, ", ")
				end

				local okChildren, children = pcall(function() return instance:GetChildren() end)
				if okChildren then
					blocks[#blocks + 1] = util.pluralise(#children, "child")
				end

				return table.concat(blocks, "\n")
			end,
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end
				local name = util.trim(args.property)

				local okRead, current = pcall(function() return instance[name] end)
				if not okRead then
					return H.fail(string.format("%s has no property '%s'", instance.ClassName, name))
				end

				local value, convertErr = H.coerce(args.value, current)
				if value == nil then return H.fail(convertErr or "could not convert that value") end

				local before = H.show(current)
				local okWrite, writeErr = pcall(function() instance[name] = value end)
				if not okWrite then
					return H.fail(string.format("%s.%s could not be set: %s", instance.ClassName, name, tostring(writeErr)))
				end

				local after = H.show(select(2, pcall(function() return instance[name] end)))
				return H.changed(name .. " = " .. after, H.pathOf(instance), "was " .. before)
			end,
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
			run = function(args)
				local okNew, instance = pcall(function() return Instance.new(tostring(args.class)) end)
				if not okNew or not instance then
					return H.fail("'" .. tostring(args.class) .. "' is not a creatable class")
				end

				if args.name and util.trim(args.name) ~= "" then instance.Name = util.trim(args.name) end

				local applied, failed = {}, {}
				for key, raw in pairs(args.properties or {}) do
					local okRead, current = pcall(function() return instance[key] end)
					if okRead then
						local value, convertErr = H.coerce(raw, current)
						if value ~= nil then
							local okWrite = pcall(function() instance[key] = value end)
							if okWrite then
								applied[#applied + 1] = key
							else
								failed[#failed + 1] = key
							end
						else
							failed[#failed + 1] = key .. " (" .. tostring(convertErr) .. ")"
						end
					else
						failed[#failed + 1] = key .. " (no such property)"
					end
				end

				local parent, parentErr = H.resolve(args.parent or "Workspace")
				if not parent then
					instance:Destroy()
					return H.fail("parent not found: " .. tostring(parentErr))
				end
				instance.Parent = parent

				local note = string.format("Created %s at %s", instance.ClassName, H.pathOf(instance))
				if #applied > 0 then note = note .. "\nSet: " .. table.concat(applied, ", ") end
				if #failed > 0 then note = note .. "\nCould not set: " .. table.concat(failed, ", ") end
				return note
			end,
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end
				local okClone, copy = pcall(function() return instance:Clone() end)
				if not okClone or not copy then
					return H.fail("that instance cannot be cloned (Archivable may be false)")
				end
				if args.name and util.trim(args.name) ~= "" then copy.Name = util.trim(args.name) end
				local parent = instance.Parent
				if args.parent and util.trim(args.parent) ~= "" then
					local resolved, parentErr = H.resolve(args.parent)
					if not resolved then
						copy:Destroy()
						return H.fail("parent not found: " .. tostring(parentErr))
					end
					parent = resolved
				end
				copy.Parent = parent
				return "Cloned to " .. H.pathOf(copy)
			end,
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end
				local full = H.pathOf(instance)
				local okCount, children = pcall(function() return #instance:GetDescendants() end)
				local okDestroy, destroyErr = pcall(function() instance:Destroy() end)
				if not okDestroy then return H.fail(tostring(destroyErr)) end
				return string.format("Destroyed %s%s", full,
					okCount and (" and " .. util.pluralise(children, "descendant")) or "")
			end,
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end
				local was = H.pathOf(instance)
				if util.trim(args.parent):lower() == "nil" then
					local ok, setErr = pcall(function() instance.Parent = nil end)
					if not ok then return H.fail(tostring(setErr)) end
					return "Detached " .. was
				end
				local parent, parentErr = H.resolve(args.parent)
				if not parent then return H.fail(parentErr) end
				local ok, setErr = pcall(function() instance.Parent = parent end)
				if not ok then return H.fail(tostring(setErr)) end
				return string.format("Moved %s to %s", was, H.pathOf(instance))
			end,
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
			run = function(args)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end
				if args.value == nil then
					local ok, value = pcall(function() return instance:GetAttribute(args.name) end)
					if not ok then return H.fail("could not read that attribute") end
					if value == nil then return "Attribute '" .. tostring(args.name) .. "' is not set." end
					return tostring(args.name) .. " = " .. H.show(value)
				end
				local text = util.trim(args.value)
				local value = tonumber(text)
				if value == nil then
					if text:lower() == "true" then value = true
					elseif text:lower() == "false" then value = false
					else value = text end
				end
				local ok, setErr = pcall(function() instance:SetAttribute(args.name, value) end)
				if not ok then return H.fail(tostring(setErr)) end
				return H.changed("attribute " .. tostring(args.name) .. " = " .. H.show(value), H.pathOf(instance))
			end,
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
				return string.format("%d instance(s) tagged '%s':\n%s", #tagged, util.trim(args.tag),
					H.list(tagged, H.limit(args.limit, 25, 100), function(node)
						return H.pathOf(node) .. " [" .. node.ClassName .. "]"
					end))
			end,
		},
	}
end
