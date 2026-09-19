-- Search and inspection together, with pages sized to the actual result budget.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local scan = env.require("tools/scan")

	local names = { type = "array", maxItems = 12, items = { type = "string", minLength = 1, maxLength = 64 } }
	local function defaults(node)
		if node:IsA("BasePart") then return { "Position", "Size", "Anchored" } end
		if node:IsA("Humanoid") then return { "Health", "MaxHealth", "WalkSpeed" } end
		if node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then return { "Text", "Visible" } end
		if node:IsA("GuiObject") then return { "Visible", "AbsolutePosition", "AbsoluteSize" } end
		if node:IsA("ValueBase") then return { "Value" } end
		return {}
	end

	local function project(node, properties, attributes)
		local row = { path = H.pathOf(node), class = node.ClassName, properties = util.emptyObject() }
		local fields, attrs, failures = {}, {}, {}
		local function shown(value)
			local text = H.show(value)
			if #text > 256 then row.truncated = true end
			return util.ellipsis(text, 256)
		end
		for _, key in ipairs(properties or defaults(node)) do
			if key == "Source" then fields[key] = "<use script_source>"
			else
				local ok, value = pcall(function() return node[key] end)
				if ok and type(value) ~= "function" then fields[key] = shown(value)
				else failures[key] = "property is unreadable" end
			end
		end
		for _, key in ipairs(attributes or {}) do
			local ok, value = pcall(function() return node:GetAttribute(key) end)
			if ok then attrs[key] = shown(value)
			else failures["attribute:" .. key] = "attribute is unreadable" end
		end
		if next(fields) then row.properties = fields end
		if next(attrs) then row.attributes = attrs end
		if next(failures) then row.errors = failures end
		return row
	end

	local function query(args, ctx)
		local root, err = H.resolve(args.root or "Workspace")
		if not root then return H.fail(err) end
		local cap = H.resultBudget()
		if cap < 512 then return H.fail("instance_query needs a result budget of at least 512 bytes") end
		local needle, class = util.trim(args.name):lower(), util.trim(args.class)
		local limit, remaining = args.limit or 20, cap - 240
		local items, lines, nextOffset, tooLarge = {}, {}, nil, false
		local stats = scan.descendants(root, ctx, function(node, index)
			local ok, matches = pcall(function()
				if needle ~= "" and not node.Name:lower():find(needle, 1, true) then return false end
				if class ~= "" and not node:IsA(class) then return false end
				if args.tag then
					local found = false
					for _, tag in ipairs(node:GetTags()) do if tag == args.tag then found = true; break end end
					if not found then return false end
				end
				return true
			end)
			if not ok or not matches then return end
			local row = project(node, args.properties, args.attributes)
			local text = util.encode(row)
			if #text + 1 > remaining then
				nextOffset, tooLarge = index, #items == 0
				return false
			end
			items[#items + 1], lines[#lines + 1] = row, text
			remaining = remaining - #text - 1
			if #items >= limit then nextOffset = index + 1; return false end
		end, 20000, args.offset or 1)
		if tooLarge then return H.fail("one result exceeds the output budget; request fewer properties or increase agent.resultCap") end
		if nextOffset and nextOffset > 20000 then nextOffset = nil; stats.reason = "scan limit" end
		local summary = string.format("%d instance(s); %d nodes scanned; %d unreadable subtree(s).", #items, stats.scanned, stats.unreadable)
		if stats.reason == "scan limit" then summary = summary .. " Scan limit reached; narrow root." end
		if stats.reason == "aborted" then summary = summary .. " Stopped." end
		local footer = nextOffset and ("\nContinue with offset=" .. nextOffset .. " and the same query. The tree is live.") or ""
		return { ok = stats.reason ~= "aborted" and stats.reason ~= "unreadable root", text = summary .. "\n" .. table.concat(lines, "\n") .. footer,
			data = { items = items, scanned = stats.scanned, nextOffset = nextOffset, complete = stats.complete,
				unreadable = stats.unreadable, status = stats.reason == "aborted" and "aborted" or "completed" } }
	end

	local function getMany(args, ctx)
		local cap = H.resultBudget()
		if cap < 512 then return H.fail("batch inspection needs a result budget of at least 512 bytes") end
		local start = args.start_index or 1
		if start > #args.paths then return H.fail("start_index is beyond the paths array") end
		local rows, lines, remaining, succeeded = {}, {}, cap - 160, 0
		local nextIndex, stopped = start, false
		for index = start, #args.paths do
			if ctx and ctx.aborted and ctx.aborted() then stopped = true; break end
			local node, err = H.resolve(args.paths[index])
			local row = node and project(node, args.properties, args.attributes) or { path = args.paths[index], error = util.ellipsis(err, 200) }
			row.index, row.ok = index, node ~= nil
			local text = util.encode(row)
			if #text + 1 > remaining then
				if #rows == 0 then return H.fail("one result exceeds the output budget; request fewer properties or increase agent.resultCap") end
				break
			end
			lines[#lines + 1], rows[#rows + 1] = text, row
			remaining, nextIndex = remaining - #text - 1, index + 1
			if node then succeeded = succeeded + 1 end
		end
		if nextIndex > #args.paths then nextIndex = nil end
		local footer = nextIndex and ("\nContinue with start_index=" .. nextIndex .. " using the same paths.") or ""
		return { ok = succeeded > 0 and not stopped,
			text = string.format("%d instance(s) read; %d failed.%s\n", succeeded, #rows - succeeded, stopped and " Stopped." or "") .. table.concat(lines, "\n") .. footer,
			data = { results = rows, nextIndex = nextIndex, status = stopped and "aborted" or "completed" } }
	end

	return {
		{
			name = "instance_query", risk = "read",
			description = "Find instances and read selected properties/attributes in one call. Name is a case-insensitive substring; class uses IsA. Stops as soon as a page fills, without collecting the entire subtree. Search is capped at 20,000 nodes.",
			parameters = { type = "object", properties = {
				root = { type = "string", description = "Default Workspace." },
				name = { type = "string" }, class = { type = "string" }, tag = { type = "string", minLength = 1 },
				properties = names, attributes = names,
				limit = { type = "integer", minimum = 1, maximum = 100, description = "Default 20; also bounded by result size." },
				offset = { type = "integer", minimum = 1, maximum = 20000, description = "Resume at the returned traversal offset." },
			}, required = {} },
			run = query,
		},
		{
			name = "instance_get_many", risk = "read",
			description = "Inspect up to 20 known instance paths at once. Select only the properties and attributes needed; compact class defaults are used otherwise. Missing paths do not discard successful reads.",
			parameters = { type = "object", properties = {
				paths = { type = "array", minItems = 1, maxItems = 20, items = { type = "string", minLength = 1, maxLength = 4096 } },
				properties = names, attributes = names,
				start_index = { type = "integer", minimum = 1, maximum = 20, description = "Resume at this request index if the result budget filled." },
			}, required = { "paths" } },
			run = getMany,
		},
	}
end
