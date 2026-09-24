return function(env)
	local util = env.require("runtime/util")
	local M = {}
	local clock = env.require("runtime/clock")
	local snapshots, order, serial, retained = {}, {}, 0, 0
	local function encoded(value) local ok, text = pcall(util.encode, value); return ok and text or "" end
	local function prune()
		while #order > 0 and (#order > 20 or retained > 4 * 1024 * 1024 or clock.ms() - snapshots[order[1]].at > 300000) do
			local key = table.remove(order, 1); retained = retained - snapshots[key].bytes; snapshots[key] = nil
		end
	end
	local function keep(data, text, group)
		serial = serial + 1; local key = "native-result:" .. serial .. ":" .. clock.ms()
		local entry = { data = util.deepCopy(data), text = text, group = group or "coding", at = clock.ms(), bytes = #encoded(data) + #text }
		snapshots[key] = entry; order[#order + 1] = key; retained = retained + entry.bytes; prune(); return snapshots[key] and key
	end
	function M.fail(why) return { ok = false, text = tostring(why), data = { status = "rejected" } } end
	local readers = { coding = "workspace_result_read", instance = "instance_result_read", remotes = "remote_result_read", script = "script_result_read" }
	function M.result(data, text, group)
		if not data then return M.fail(text) end
		text = tostring(text or data.text or data.status or "Completed")
		if #encoded(data) + #text > 5600 then
			local key = keep(data, text, group)
			local reader = readers[group or "coding"]
			local summary = { resultId = key, readTool = key and reader, expiresInSeconds = 300 }
			for _, field in ipairs({ "status", "ok", "sessionId", "revision", "documentId", "batchId", "snapshotId", "nextCursor", "nextOffset", "changedCount", "omittedOutcomes", "retained", "monitored", "ruleCount" }) do if data[field] ~= nil then summary[field] = data[field] end end
			if not key then summary.detailsUnavailable = "Result exceeded retained-detail budget; inspect the affected object or batch directly" end
			return { ok = data.ok ~= false, text = util.ellipsis(text, 1200) .. (key and ("\nDetailed fields are available through " .. reader .. ".") or "\nDetails exceeded retention; inspect the affected object or operation directly."), data = summary }
		end
		return { ok = data.ok ~= false, text = text, data = data }
	end
	function M.read(args, group)
		prune(); local entry = snapshots[args.result_id]
		if not entry then return M.fail("expired: inspect the affected object or operation again") end
		if entry.group ~= (group or "coding") then return M.fail("Use the result reader in the originating tool group") end
		local value = args.section == "text" and entry.text or entry.data
		local path = args.path or {}
		if type(path) ~= "table" or #path > 16 then return M.fail("Use a path array with at most 16 keys") end
		for _, key in ipairs(path) do
			if type(value) ~= "table" then return M.fail("Path does not refer to retained data") end
			local nextValue = value[key]; if nextValue == nil and tonumber(key) then nextValue = value[tonumber(key)] end; value = nextValue
		end
		if type(value) == "string" then
			local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
			if offset > #value + 1 then return M.fail("Offset is outside retained text") end
			local byte = value:byte(offset); if byte and byte >= 128 and byte < 192 then return M.fail("Offset splits UTF-8") end
			local last = math.min(#value, offset + 599)
			while last > offset and value:byte(last + 1) and value:byte(last + 1) >= 128 and value:byte(last + 1) < 192 do last = last - 1 end
			return M.result({ value = value:sub(offset, last), offset = offset, nextOffset = last < #value and last + 1 or nil, totalBytes = #value }, "Retained text page")
		end
		if type(value) ~= "table" then return M.result({ value = value }, "Retained value") end
		local keys, items, offset, used = util.keys(value, true), {}, math.max(1, math.floor(tonumber(args.offset) or 1)), 0
		local nextOffset
		for i = offset, #keys do
			local key, item = keys[i], value[keys[i]]
			local subpath = util.copy(path); subpath[#subpath + 1] = tostring(key)
			local projected = #encoded(item) > 500 and { type = type(item), path = subpath, count = type(item) == "table" and util.count(item) or nil, bytes = type(item) == "string" and #item or nil } or item
			local row = { key = key, value = projected }; local size = #encoded(row)
			if used + size > 4000 or #items >= 20 then nextOffset = i; break end
			items[#items + 1], used = row, used + size
		end
		return M.result({ resultId = args.result_id, path = path, items = items, nextOffset = nextOffset }, "Retained result fields; follow path arrays for larger values")
	end
	function M.add(tools, name, risk, description, properties, required, run, prepare)
		tools[#tools + 1] = { name = name, risk = risk, description = description,
			parameters = { type = "object", properties = properties or {}, required = required or {} }, run = run, prepare = prepare }
		return tools[#tools]
	end
	function M.property(typeName, description) return { type = typeName, description = description } end
	function M.forGroup(group)
		local scoped = setmetatable({}, { __index = M })
		scoped.result = function(data, text) return M.result(data, text, group) end
		scoped.read = function(args) return M.read(args, group) end
		return scoped
	end
	function M.addReader(tools, group)
		M.add(tools, readers[group], "read", "Read bounded retained detail from a large result in this tool group. Follow returned path arrays and offsets; expires after five minutes.",
			{ result_id = { type = "string" }, section = { type = "string" }, offset = { type = "integer", minimum = 1 }, path = { type = "array", items = { type = "string" }, maxItems = 16 } }, { "result_id" },
			function(args) return M.read(args, group) end)
	end
	function M.projection(info)
		local out = util.copy(info); out.name = info.name and util.ellipsis(info.name, 120); out.displayPath = info.displayPath and util.ellipsis(info.displayPath, 300)
		return out
	end
	function M.page(page)
		if page and page.items then for i, item in ipairs(page.items) do page.items[i] = M.projection(item) end end
		return page
	end
	return M
end
