-- Capture storage is bounded independently of rendering and transport.
return function(env)
	local values = env.require("runtime/values")
	local util = env.require("runtime/util")
	local refs = env.require("runtime/instance_refs")
	local clock = env.require("runtime/clock")
	local M = { changed = env.require("runtime/signal").new("remote-records"), generation = 0, sequence = 0,
		limits = { records = 1000, bytes = 4 * 1024 * 1024, pending = 128, pins = 10, pinBytes = 1024 * 1024 } }
	local records, index, pins, cursors, bytes, pending = {}, {}, {}, {}, 0, 0
	local function counters() return { admitted = 0, ignored = 0, evicted = 0, truncated = 0, observerFailed = 0, pendingOverflow = 0 } end
	M.counters, M.lifetime = counters(), counters()
	function M.count(kind, count) M.counters[kind] = (M.counters[kind] or 0) + (count or 1); M.lifetime[kind] = (M.lifetime[kind] or 0) + (count or 1) end
	local function notify(kind, key) M.changed:fire({ kind = kind, recordId = key, generation = M.generation }) end
	function M.summary(record)
		return { id = record.id, sequence = record.sequence, revision = record.revision, sessionId = record.sessionId, remoteId = record.remoteId,
			name = record.name, className = record.className, method = record.method, direction = record.direction, origin = record.origin,
			outcome = record.outcome, argumentCount = record.arguments.count, resultCount = record.results and record.results.count,
			complete = record.arguments.complete, replayOf = record.replayOf, startedAt = record.startedAt, invocationId = record.invocationId, offline = record.offline == true }
	end
	local function evict()
		while #records > M.limits.records or bytes > M.limits.bytes do
			local old = table.remove(records, 1); bytes = bytes - old.bytes; index[old.id] = nil
			if old.outcome == "pending" and not pins[old.id] then pending = math.max(0, pending - 1); M.count("pendingEvicted") end
			M.count("evicted")
		end
	end
	function M.begin(meta, packed, options)
		local graph = values.snapshot(packed, options)
		M.sequence = M.sequence + 1
		local record = util.copy(meta)
		record.id, record.sequence, record.revision = "call:" .. refs.epoch .. ":" .. M.sequence, M.sequence, 1
		record.dataGeneration, record.arguments, record.startedAt = M.generation, graph, clock.ms()
		record.outcome, record.bytes = meta.outcome or "pending", graph.bytes + 1024
		if record.outcome == "pending" then
			if pending >= M.limits.pending then record.outcome = "completion_unobserved"; M.count("pendingOverflow") else pending = pending + 1 end
		end
		if not graph.complete then M.count("truncated") end
		records[#records + 1], index[record.id], bytes = record, record, bytes + record.bytes
		M.count("admitted"); evict(); notify("record", record.id)
		return { id = record.id, generation = M.generation }
	end
	function M.finish(token, outcome, result, reason)
		if not token or token.generation ~= M.generation then return end
		local record = index[token.id] or pins[token.id]
		if not record or record.outcome ~= "pending" then return end
		pending = math.max(0, pending - 1); record.outcome, record.revision = outcome, record.revision + 1
		record.error = reason and util.ellipsis(reason, 1000) or nil
		if result then
			record.results = values.snapshot(result); local added = record.results.bytes
			record.bytes = record.bytes + added; if index[record.id] then bytes = bytes + added end
			if not record.results.complete then M.count("truncated") end
		end
		record.ms = clock.ms() - record.startedAt; evict(); notify("outcome", record.id)
	end
	function M.stopPending()
		for _, record in ipairs(records) do if record.outcome == "pending" then record.outcome, record.revision = "completion_unobserved", record.revision + 1 end end
		for _, record in pairs(pins) do if record.outcome == "pending" then record.outcome, record.revision = "completion_unobserved", record.revision + 1 end end
		pending = 0; notify("stop")
	end
	function M.get(key, revision)
		local record = index[key] or pins[key]
		if not record then return nil, "expired: capture was cleared or evicted" end
		if revision ~= nil and revision ~= record.revision then return nil, "stale_revision: refresh this call" end
		return util.deepCopy(record)
	end
	function M.pin(key)
		local record, why = M.get(key); if not record then return nil, why end
		if pins[key] then return true end
		local total = record.bytes; for _, pinned in pairs(pins) do total = total + pinned.bytes end
		if util.count(pins) >= M.limits.pins or total > M.limits.pinBytes then return nil, "Close a pinned capture before opening another" end
		record = index[key] or pins[key] or record
		pins[key] = record; if not record.offline then refs.pin(record.remoteId, record) end; return true
	end
	function M.unpin(key) if pins[key] then if not index[key] and pins[key].outcome == "pending" then pending = math.max(0, pending - 1) end; refs.release(pins[key]); pins[key] = nil end end
	function M.clear()
		for key in pairs(pins) do M.unpin(key) end
		records, index, cursors, bytes, pending = {}, {}, {}, 0, 0
		M.generation = M.generation + 1; M.counters = counters(); notify("clear")
	end
	function M.state() return { retained = #records, bytes = bytes, generation = M.generation, oldest = records[1] and records[1].sequence, newest = M.sequence, counters = util.copy(M.counters), lifetime = util.copy(M.lifetime), offlineSessionId = "offline:" .. refs.epoch } end
	-- The UI follows the newest *matching* calls. Filtering only the last N raw
	-- sequences hides quiet remotes as soon as a busy remote fills that window.
	function M.latest(args)
		args = args or {}
		local before = tonumber(args.before_sequence) or M.sequence + 1
		if not values.finite(before) or before < 1 or before ~= math.floor(before) then return nil, "Invalid sequence offset" end
		local filter, limit = tostring(args.name or ""):lower(), math.max(1, math.min(tonumber(args.limit) or 100, 100))
		local reverse = {}
		local result = { items = {}, generation = M.generation, oldest = records[1] and records[1].sequence }
		for i = #records, 1, -1 do
			local record = records[i]
			if record.sequence < before and (not args.session_id or record.sessionId == args.session_id)
				and (filter == "" or (record.name or ""):lower():find(filter, 1, true))
				and (not args.direction or record.direction == args.direction) and (not args.method or record.method == args.method)
				and (not args.origin or record.origin == args.origin) and (not args.outcome or record.outcome == args.outcome)
				and (not args.remote_id or record.remoteId == args.remote_id) then
				if #reverse >= limit then result.hasOlder = true; break end
				reverse[#reverse + 1] = M.summary(record)
			end
		end
		for i = #reverse, 1, -1 do result.items[#result.items + 1] = reverse[i] end
		result.first = result.items[1] and result.items[1].sequence
		result.last = result.items[#result.items] and result.items[#result.items].sequence
		return result
	end
	function M.page(args)
		args = args or {}; local after = tonumber(args.after_sequence) or 0
		if not values.finite(after) or after < 0 or after ~= math.floor(after) then return nil, "Invalid sequence offset" end
		local filter = tostring(args.name or ""):lower(); local session = args.session_id
		local signature = util.encode({ filter, session or "", args.direction or "", args.method or "", args.origin or "", args.outcome or "", args.remote_id or "" })
		if args.cursor then
			local cursor = cursors[args.cursor]
			if not cursor or cursor.generation ~= M.generation or cursor.signature ~= signature or clock.ms() - cursor.at > 300000 then return nil, "stale_cursor: capture query changed" end
			after = cursor.after
		end
		local result = { items = {}, oldest = records[1] and records[1].sequence, generation = M.generation }
		if result.oldest and after > 0 and after + 1 < result.oldest then result.gap = { first = after + 1, last = result.oldest - 1 } end
		local limit = math.max(1, math.min(tonumber(args.limit) or 25, 100)); local last
		for _, record in ipairs(records) do
			if record.sequence > after and (not session or record.sessionId == session) and (filter == "" or (record.name or ""):lower():find(filter, 1, true))
				and (not args.direction or record.direction == args.direction) and (not args.method or record.method == args.method)
				and (not args.origin or record.origin == args.origin) and (not args.outcome or record.outcome == args.outcome)
				and (not args.remote_id or record.remoteId == args.remote_id) then
				if #result.items >= limit then
					local key = "calls:" .. M.generation .. ":" .. last .. ":" .. tostring(clock.ms())
					if util.count(cursors) > 128 then cursors = {} end
					cursors[key] = { after = last, generation = M.generation, signature = signature, at = clock.ms() }; result.nextCursor = key; break
				end
				result.items[#result.items + 1] = M.summary(record); last = record.sequence
			end
		end
		return result
	end
	function M.read(key, section, nodeId, offset, revision)
		local record, why = M.get(key, revision); if not record then return nil, why end
		local result = M.summary(record)
		if section == "summary" then result.path, result.caller, result.error = record.pathAtCapture, record.caller, record.error; return result end
		if section ~= "caller" and section ~= "arguments" and section ~= "results" then return nil, "Invalid capture section" end
		if section == "caller" then result.caller = record.caller or { status = "unavailable" }; return result end
		local graph = section == "arguments" and record.arguments or section == "results" and record.results
		if not graph then result.error = record.error; result.message = "No observed " .. tostring(section); return result end
		local list = graph.slots
		if nodeId then if not graph.nodes[nodeId] then return nil, "Unknown graph node" end; list = graph.nodes[nodeId].entries end
		result.values, result.count, result.complete, result.reasons = {}, graph.count, graph.complete, graph.reasons
		local at, used = math.max(1, tonumber(offset) or 1), 0
		for i = at, #list do
			local item = util.deepCopy(list[i]); local size = #util.encode(item)
			if used + size > 4500 then
				if #result.values == 0 then result.values[1] = { kind = "large_value", preview = values.format(item.value or item), index = i, nodeId = nodeId, bytes = size, message = "Use remote_capture_bytes with this section, index and optional node_id (field=key/value for table entries)" }; result.nextOffset = i + 1 <= #list and i + 1 or nil
				else result.nextOffset = i end
				break
			end
			result.values[#result.values + 1], used = item, used + size
		end
		return result
	end
	function M.readBytes(args)
		local record, why = M.get(args.record_id, args.record_revision); if not record then return nil, why end
		local graph = args.section == "arguments" and record.arguments or args.section == "results" and record.results
		if not graph then return nil, "That section has no retained values" end
		local node = graph.slots[args.index or 1]
		if args.node_id then
			local tableNode = graph.nodes[args.node_id]; local entry = tableNode and tableNode.entries[args.index or 1]
			node = entry and entry[args.field == "key" and "key" or "value"]
		end
		if not node or (node.kind ~= "string" and node.kind ~= "buffer") then return nil, "Select a retained string or buffer" end
		local raw = node.encoding == "hex" and values.unhex(node.value) or node.value
		local offset, count = math.floor(tonumber(args.byte_offset) or 1), math.max(1, math.min(math.floor(tonumber(args.byte_limit) or 700), 700))
		if offset < 1 or offset > #raw + 1 then return nil, "Byte offset is outside the retained value" end
		local last = math.min(#raw, offset + count - 1)
		if node.encoding ~= "hex" then
			local first = raw:byte(offset); if first and first >= 128 and first < 192 then return nil, "Byte offset splits a UTF-8 character" end
			while last > offset and raw:byte(last + 1) and raw:byte(last + 1) >= 128 and raw:byte(last + 1) < 192 do last = last - 1 end
			if raw:byte(last + 1) and raw:byte(last + 1) >= 128 and raw:byte(last + 1) < 192 then return nil, "Slice is too small for a complete UTF-8 character" end
		end
		local slice = raw:sub(offset, last)
		return { recordId = record.id, revision = record.revision, encoding = node.encoding or "utf8", value = node.encoding == "hex" and values.hex(slice) or slice,
			offset = offset, nextByteOffset = last < #raw and last + 1 or nil, retainedBytes = #raw, originalBytes = node.length or #raw, truncated = node.truncated == true }
	end
	function M.exportRecords(keys)
		local out = {}; for _, key in ipairs(keys) do local record, why = M.get(key); if not record then return nil, why end; out[#out + 1] = record end; return out
	end
	function M.import(list)
		if type(list) ~= "table" or not util.isArray(list) or #list > M.limits.records then return nil, "Import record limit exceeded" end
		for _, record in ipairs(list) do
			if type(record) ~= "table" or not values.validateGraph(record.arguments) or (record.results and not values.validateGraph(record.results)) then return nil, "Invalid capture graph" end
			for _, key in ipairs({ "remoteId", "name", "className", "method", "direction", "origin", "outcome", "pathAtCapture", "sessionId", "error" }) do if record[key] ~= nil and (type(record[key]) ~= "string" or #record[key] > (key == "pathAtCapture" and 1024 or 1000)) then return nil, "Invalid capture metadata: " .. key end end
			if record.method ~= "FireServer" and record.method ~= "InvokeServer" and record.method ~= "OnClientEvent" then return nil, "Invalid capture method" end
			if record.direction ~= "incoming" and record.direction ~= "outgoing" then return nil, "Invalid capture direction" end
		end
		for _, source in ipairs(list) do
			M.sequence = M.sequence + 1
			local record = { arguments = util.deepCopy(source.arguments), results = source.results and util.deepCopy(source.results), caller = { status = "offline" } }
			for _, key in ipairs({ "remoteId", "name", "className", "method", "direction", "origin", "outcome", "pathAtCapture", "sessionId", "error" }) do record[key] = source[key] end
			record.name, record.className = util.ellipsis(record.name or "Offline remote", 160), util.ellipsis(record.className or "Unknown", 100)
			record.startedAt = values.finite(source.startedAt) and source.startedAt or 0
			record.id, record.sequence, record.revision = "call:" .. refs.epoch .. ":" .. M.sequence, M.sequence, 1
			record.originalSessionId, record.sessionId = record.sessionId, "offline:" .. refs.epoch
			record.offline, record.dataGeneration = true, M.generation
			record.bytes = #util.encode(record) + 2048
			records[#records + 1], index[record.id], bytes = record, record, bytes + record.bytes
		end
		evict(); notify("import"); return #list
	end
	env.require("runtime/dispose").add(function() M.clear(); M.changed:clear() end, "remote capture buffer")
	return M
end
