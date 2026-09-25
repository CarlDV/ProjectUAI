-- Bounded, replayable history. Dialogue, dispatch summaries and detailed activity
-- have independent budgets: a noisy worker cannot evict the user's conversation.
return function(env)
	local util = env.require("runtime/util")
	local M = {}
	local FIELD_CAP, EVENT_BYTES = 24000, 65536
	local BUDGETS = {
		conversation = { events = 512, bytes = 1048576 },
		lifecycle = { events = 128, bytes = 262144 },
		activity = { events = 256, bytes = 262144 },
	}
	local KINDS = {
		user = "conversation", ["assistant:text"] = "conversation",
		compact = "conversation", error = "conversation", abort = "conversation",
		["subagent:start"] = "lifecycle", ["subagent:done"] = "lifecycle",
		["turn:start"] = "activity", ["turn:end"] = "activity",
		["assistant:reasoning"] = "activity", ["tool:call"] = "activity",
		["tool:result"] = "activity", ["tool:error"] = "activity",
		["subagent:text"] = "activity", ["subagent:tool"] = "activity",
		["subagent:tool:done"] = "activity", ["request:retry"] = "activity",
		["provider:switch"] = "activity",
	}
	M.limits = { events = 896, bytes = 1572864, field = FIELD_CAP, budgets = BUDGETS }
	function M.durable(kind) return KINDS[kind] ~= nil end
	local function finite(value)
		return type(value) == "number" and value == value and math.abs(value) < math.huge
	end
	local function count(value)
		return finite(value) and math.max(0, math.min(1e12, math.floor(value))) or 0
	end

	-- Only primitives cross the retention boundary. Prioritize identity and content
	-- before optional fields, and never retain callbacks, Instances or result graphs.
	local function clean(payload, cap)
		local copy, bytes, fields = {}, 64, 0
		local function keep(key)
			if copy[key] ~= nil or key == "retainedBytes" or key == "transcriptId" then return end
			if type(key) ~= "string" or #key > 80 or fields >= 64 then return end
			local value = payload[key]
			if type(value) == "string" then
				local remaining = EVENT_BYTES - bytes - #key - 32
				if remaining <= 0 then return end
				copy[key] = util.sanitise(util.truncate(value, math.min(cap or FIELD_CAP, remaining)))
				bytes = bytes + #copy[key] + #key + 8
			elseif type(value) == "boolean" or finite(value) then
				copy[key] = value; bytes = bytes + #key + 16
			else return end
			fields = fields + 1
		end
		for _, key in ipairs({ "kind", "id", "call", "callId", "at", "name", "label", "text", "message", "arguments" }) do keep(key) end
		for key in pairs(payload) do keep(key) end
		copy.retainedBytes = bytes
		return copy, bytes
	end

	function M.new(owner)
		local store = { revision = 0, recovered = 0 }
		local sequence, entries, pending, agents, lanes = 0, {}, {}, {}, {}
		function store.reset()
			owner.log, owner.logBytes = {}, 0
			entries, pending, agents, lanes = {}, {}, {}, {}
			store.omitted, store.recovered = {}, 0
			for name in pairs(BUDGETS) do lanes[name] = { events = 0, bytes = 0 }; store.omitted[name] = 0 end
			store.revision = store.revision + 1
		end
		store.reset()

		local function groupFor(event, lane)
			local kind, key, opening, closing = event.kind, nil, false, false
			if kind == "tool:call" or kind == "tool:result" or kind == "tool:error" then
				if event.id then key = "tool:" .. tostring(event.id) end
				opening, closing = kind == "tool:call", kind ~= "tool:call"
			elseif kind == "subagent:tool" or kind == "subagent:tool:done" then
				if event.id and event.callId then key = "child:" .. tostring(event.id) .. ":" .. tostring(event.callId) end
				opening, closing = kind == "subagent:tool", kind == "subagent:tool:done"
			elseif kind == "subagent:start" or kind == "subagent:done" then
				if event.id then key = "agent:" .. tostring(event.id) end
				opening, closing = kind == "subagent:start", kind == "subagent:done"
			elseif kind == "turn:start" or kind == "turn:end" then
				key, opening, closing = "turn", kind == "turn:start", kind == "turn:end"
			end
			local group = key and not opening and pending[key] or nil
			if not group then
				group = { key = key, lane = lane, open = opening }
				if key and opening then
					if pending[key] then pending[key].open = false end
					pending[key] = group
				end
			end
			if closing then
				group.open, group.live = false, nil
				if key and pending[key] == group then pending[key] = nil end
			end
			if lane == "lifecycle" and event.id then
				group.agentId = event.id; agents[event.id] = group
			elseif kind:sub(1, 9) == "subagent:" and event.id then
				group.parent = agents[event.id]
			end
			return group
		end

		local function evict(group)
			local kept, removed = {}, {}
			for _, event in ipairs(owner.log) do
				local entry = entries[event.transcriptId]
				if entry.group == group or entry.group.parent == group then
					local lane = lanes[entry.lane]
					lane.events, lane.bytes = lane.events - 1, lane.bytes - event.retainedBytes
					owner.logBytes = owner.logBytes - event.retainedBytes
					store.omitted[entry.lane] = store.omitted[entry.lane] + 1
					entries[event.transcriptId] = nil; removed[entry.group] = true
				else kept[#kept + 1] = event end
			end
			for item in pairs(removed) do
				if item.key and pending[item.key] == item then pending[item.key] = nil end
				if item.agentId and agents[item.agentId] == item then agents[item.agentId] = nil end
				item.live = nil
			end
			owner.log = kept; store.revision = store.revision + 1
		end

		local function trim(name)
			local lane, budget = lanes[name], BUDGETS[name]
			while lane.events > budget.events or lane.bytes > budget.bytes do
				local oldest, completed
				for _, event in ipairs(owner.log) do
					local entry = entries[event.transcriptId]
					if entry.lane == name then
						oldest = oldest or entry.group
						if not entry.group.open then completed = entry.group; break end
					end
				end
				if not oldest then break end
				-- A pending call's arguments survive newer finished calls. A hard bound
				-- still applies even to malformed hosts that never finish their calls.
				evict(completed or oldest)
			end
		end

		function store.append(payload)
			if type(payload) ~= "table" then return nil end
			local laneName = KINDS[payload.kind]
			if not laneName then
				local key = payload.kind == "tool:progress" and payload.id and ("tool:" .. tostring(payload.id))
					or payload.kind == "subagent:status" and payload.id and ("agent:" .. tostring(payload.id))
				if key and pending[key] then pending[key].live = clean(payload, 4000) end
				return nil
			end
			local event, bytes = clean(payload)
			sequence = sequence + 1; event.transcriptId = sequence
			local group, lane = groupFor(event, laneName), lanes[laneName]
			entries[sequence] = { event = event, group = group, lane = laneName }
			owner.log[#owner.log + 1], owner.logBytes = event, owner.logBytes + bytes
			lane.events, lane.bytes = lane.events + 1, lane.bytes + bytes
			trim(laneName)
			return event
		end

		function store.get(id) return entries[id] and entries[id].event or nil end
		function store.snapshot()
			local out = {}
			for _, event in ipairs(owner.log) do out[#out + 1] = util.copy(event) end
			return out
		end
		function store.live()
			local out = {}
			for _, group in pairs(pending) do if group.live then out[#out + 1] = util.copy(group.live) end end
			return out
		end
		function store.metadata()
			return { version = 2, omitted = util.copy(store.omitted), recovered = store.recovered }
		end

		-- Older FIFO files can contain only worker activity. Recover dialogue still
		-- present in model context, matching occurrences so repeated prompts survive
		-- without duplicating the overlap. Compacted-away text cannot be recovered.
		function store.restore(events, ctx, metadata)
			store.reset()
			local history, seen = {}, {}
			local function identity(kind, text) return kind .. "\0" .. util.truncate(tostring(text or ""), FIELD_CAP) end
			for _, event in ipairs(type(events) == "table" and events or {}) do
				if type(event) == "table" and KINDS[event.kind] then
					history[#history + 1] = event
					if event.kind == "user" or event.kind == "assistant:text" then
						local key = identity(event.kind, event.text); seen[key] = (seen[key] or 0) + 1
					end
				end
			end
			if type(metadata) == "table" and metadata.version == 2 then
				for name in pairs(BUDGETS) do store.omitted[name] = count(type(metadata.omitted) == "table" and metadata.omitted[name]) end
				store.recovered = count(metadata.recovered)
			else
				local recovered = {}
				local messages = ctx and ctx.messages or {}
				-- Match the retained suffix first when a person repeated the same prompt.
				for index = #messages, 1, -1 do
					local item = messages[index]
					local kind = item.role == "user" and "user" or item.role == "assistant" and "assistant:text"
					if kind and type(item.content) == "string" and util.trim(item.content) ~= "" then
						local key = identity(kind, item.content)
						if (seen[key] or 0) > 0 then seen[key] = seen[key] - 1
						else table.insert(recovered, 1, { kind = kind, text = item.content, at = item.at, model = item.model, recovered = true }) end
					end
				end
				if #recovered > 0 then
					local combined = {}
					for _, event in ipairs(recovered) do combined[#combined + 1] = { event = event, order = #combined + 1 } end
					for _, event in ipairs(history) do combined[#combined + 1] = { event = event, order = #combined + 1 } end
					table.sort(combined, function(a, b)
						local at, bt = count(a.event.at), count(b.event.at)
						if at ~= bt then return at < bt end
						return a.order < b.order
					end)
					history = {}; for _, entry in ipairs(combined) do history[#history + 1] = entry.event end
					store.recovered = #recovered
				end
			end
			for _, event in ipairs(history) do store.append(event) end
		end
		return store
	end
	return M
end
