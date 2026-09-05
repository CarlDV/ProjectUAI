-- Activity history.
--
-- Everything the home card and the Usage panel show is counted here, from events
-- the client genuinely observed, and nothing is modelled or interpolated: a figure
-- either has a record behind it or it is absent. That is the whole contract of this
-- module, and it is why the counters are so plain.
--
-- Two things follow from it. Tokens are only ever counted from the moment this file
-- first exists -- `agent/usage` has always been in-memory, so there is no history to
-- recover and inventing one would be worse than a zero. Messages and conversations
-- *can* be recovered, because every persisted transcript carries the real timestamp
-- of every message in it, so the first run seeds those from disk and says so.
--
-- Buckets are local days and local hours, because "yesterday" and "11 AM" are the
-- user's, not UTC's. runtime/clock owns that conversion.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local fsx = env.require("runtime/fsx")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")
	local dispose = env.require("runtime/dispose")

	local FILE = "stats.json"
	-- Thirteen months of days. Past that the oldest is dropped, which is also the
	-- ceiling on how far back any window can reach -- stated here because the panel
	-- says "all" and that is what all means.
	local DAY_LIMIT = 400
	-- Ids of conversations already counted, so resuming one after a restart does not
	-- count it twice. Only twenty transcripts are ever kept on disk, so a window of
	-- sixty-four covers every conversation that could still be resumed.
	local SEEN_LIMIT = 64
	local TOOL_LIMIT = 120
	local SAVE_SECONDS = 2

	-- The comparison Claude Code's home card makes. 76,944 words in the first
	-- edition; at the four-characters-per-token estimate this client uses everywhere
	-- else that is a little under 100,000 tokens, which is the divisor. It is an
	-- estimate of the book, not of the count -- the token figure itself is measured.
	local BOOK = { title = "Harry Potter and the Philosopher's Stone", tokens = 100000 }

	local M = {
		changed = signal.new("stats"),
		loaded = false,
		observing = false,
		BOOK = BOOK,
		DAY_LIMIT = DAY_LIMIT,
	}

	local function blankTotals()
		return {
			sessions = 0, messages = 0, userMessages = 0, replies = 0,
			tokensIn = 0, tokensOut = 0, cached = 0, reasoning = 0,
			cost = 0, requests = 0, toolCalls = 0, toolErrors = 0, errors = 0,
		}
	end

	local function blank()
		return {
			version = 1,
			startedAt = clock.ms(),
			-- Nil until the first request is recorded, and the Usage panel prints it
			-- rather than implying the token columns cover the whole history.
			tokensFrom = nil,
			seededAt = nil,
			days = {},
			hours = {},
			models = {},
			tools = {},
			seen = {},
			totals = blankTotals(),
		}
	end

	M.data = blank()

	local seenSet = {}

	local function rebuildSeen()
		seenSet = {}
		for _, id in ipairs(M.data.seen or {}) do seenSet[tostring(id)] = true end
	end

	-- Numbers come back from JSON as numbers, but a hand-edited or half-written file
	-- can hold anything, and one string in a counter would poison every sum.
	local function number(value)
		return tonumber(value) or 0
	end

	local function sanitiseCounters(source, template)
		local out = {}
		for key, fallback in pairs(template) do
			out[key] = number(util.get(source or {}, key, fallback))
		end
		return out
	end

	local DAY_TEMPLATE = {
		sessions = 0, messages = 0, userMessages = 0, replies = 0,
		tokensIn = 0, tokensOut = 0, cost = 0, requests = 0,
		toolCalls = 0, toolErrors = 0, errors = 0,
	}

	local function blankDay()
		return sanitiseCounters({}, DAY_TEMPLATE)
	end

	function M.load()
		local stored = fsx.readJson(FILE, nil)
		M.data = blank()
		if type(stored) == "table" then
			M.data.startedAt = number(stored.startedAt) > 0 and number(stored.startedAt) or M.data.startedAt
			M.data.tokensFrom = tonumber(stored.tokensFrom)
			M.data.seededAt = tonumber(stored.seededAt)
			M.data.totals = sanitiseCounters(stored.totals, blankTotals())
			M.data.estimated = stored.estimated == true
			if type(stored.days) == "table" then
				for key, record in pairs(stored.days) do
					if clock.dayNumberOfKey(key) and type(record) == "table" then
						local day = sanitiseCounters(record, DAY_TEMPLATE)
						day.hours = {}
						for hour, count in pairs(type(record.hours) == "table" and record.hours or {}) do
							local index = tonumber(hour)
							if index and index >= 0 and index <= 23 then
								day.hours[tostring(math.floor(index))] = number(count)
							end
						end
						day.models = {}
						for id, entry in pairs(type(record.models) == "table" and record.models or {}) do
							if type(id) == "string" and type(entry) == "table" then
								day.models[id] = {
									requests = number(entry.requests),
									tokensIn = number(entry.tokensIn),
									tokensOut = number(entry.tokensOut),
									cost = number(entry.cost),
								}
							end
						end
						M.data.days[key] = day
					end
				end
			end
			if type(stored.tools) == "table" then
				for name, count in pairs(stored.tools) do
					if type(name) == "string" then M.data.tools[name] = number(count) end
				end
			end
			if type(stored.seen) == "table" then
				for _, id in ipairs(stored.seen) do
					if type(id) == "string" then M.data.seen[#M.data.seen + 1] = id end
				end
			end
		end
		rebuildSeen()
		M.loaded = true
		return M.data
	end

	function M.saveNow()
		if not fsx.enabled then return false, "no filesystem" end
		local ok, err = fsx.writeJson(FILE, M.data)
		if not ok then log.warn("stats", "could not persist activity history", err) end
		return ok, err
	end

	local flush = clock.debounce(function() M.saveNow() end, SAVE_SECONDS)

	function M.save()
		flush()
	end

	-- Recording ---------------------------------------------------------------

	-- Get-or-create for one local day, trimming the oldest when the window is full.
	-- The trim is by day number rather than by string order so a key from a future
	-- year cannot sort itself into the middle of the set.
	local function dayFor(ms)
		local key = clock.dayKey(ms)
		local record = M.data.days[key]
		if record then return record, key end
		record = blankDay()
		record.hours = {}
		record.models = {}
		M.data.days[key] = record

		local keys = {}
		for existing in pairs(M.data.days) do keys[#keys + 1] = existing end
		if #keys > DAY_LIMIT then
			table.sort(keys, function(a, b)
				return (clock.dayNumberOfKey(a) or 0) < (clock.dayNumberOfKey(b) or 0)
			end)
			for index = 1, #keys - DAY_LIMIT do M.data.days[keys[index]] = nil end
		end
		return record, key
	end

	local function bump(record, key, amount)
		record[key] = number(record[key]) + (amount or 1)
	end

	local function touchHour(day, ms)
		local hour = tostring(clock.hourOf(ms))
		day.hours[hour] = number(day.hours[hour]) + 1
		M.data.hours[hour] = number(M.data.hours[hour]) + 1
	end

	-- `quiet` seeds from disk without republishing per row: the first run would
	-- otherwise fire the signal a few thousand times before the interface exists.
	function M.recordMessage(role, at, quiet)
		local day = dayFor(at)
		bump(day, "messages")
		bump(M.data.totals, "messages")
		if role == "user" then
			bump(day, "userMessages")
			bump(M.data.totals, "userMessages")
		else
			bump(day, "replies")
			bump(M.data.totals, "replies")
		end
		touchHour(day, at)
		if not quiet then
			M.save()
			M.changed:fire(M.data)
		end
	end

	-- A conversation counts once, the first time something is actually said in it: a
	-- thread object exists from the moment a panel opens and counting those would
	-- report a session for every time the window was looked at.
	function M.recordSession(id, at, quiet)
		local key = tostring(id or "")
		if key ~= "" then
			if seenSet[key] then return false end
			seenSet[key] = true
			M.data.seen[#M.data.seen + 1] = key
			while #M.data.seen > SEEN_LIMIT do table.remove(M.data.seen, 1) end
		end
		local day = dayFor(at)
		bump(day, "sessions")
		bump(M.data.totals, "sessions")
		if not quiet then
			M.save()
			M.changed:fire(M.data)
		end
		return true
	end

	function M.counted(id)
		return seenSet[tostring(id or "")] == true
	end

	-- One inference request, after the fact, with whatever the provider reported.
	-- `delta` is what agent/usage measured for this request alone.
	function M.recordRequest(delta)
		delta = delta or {}
		local at = delta.at or clock.ms()
		local day = dayFor(at)
		local tokensIn = number(delta.prompt)
		local tokensOut = number(delta.completion)
		local cost = number(delta.cost)

		bump(day, "requests")
		bump(day, "tokensIn", tokensIn)
		bump(day, "tokensOut", tokensOut)
		bump(day, "cost", cost)
		bump(M.data.totals, "requests")
		bump(M.data.totals, "tokensIn", tokensIn)
		bump(M.data.totals, "tokensOut", tokensOut)
		bump(M.data.totals, "cached", number(delta.cached))
		bump(M.data.totals, "reasoning", number(delta.reasoning))
		bump(M.data.totals, "cost", cost)
		if delta.estimated then M.data.estimated = true end
		if not M.data.tokensFrom then M.data.tokensFrom = at end

		local model = util.trim(tostring(delta.model or ""))
		if model ~= "" then
			local perDay = day.models[model]
			if not perDay then
				perDay = { requests = 0, tokensIn = 0, tokensOut = 0, cost = 0 }
				day.models[model] = perDay
			end
			bump(perDay, "requests")
			bump(perDay, "tokensIn", tokensIn)
			bump(perDay, "tokensOut", tokensOut)
			bump(perDay, "cost", cost)

			local lifetime = M.data.models[model]
			if not lifetime then
				lifetime = { requests = 0, tokensIn = 0, tokensOut = 0, cost = 0, firstAt = at }
				M.data.models[model] = lifetime
			end
			bump(lifetime, "requests")
			bump(lifetime, "tokensIn", tokensIn)
			bump(lifetime, "tokensOut", tokensOut)
			bump(lifetime, "cost", cost)
			lifetime.lastAt = at
		end

		M.save()
		M.changed:fire(M.data)
	end

	function M.recordTool(name, ok, at)
		local day = dayFor(at)
		bump(day, "toolCalls")
		bump(M.data.totals, "toolCalls")
		if not ok then
			bump(day, "toolErrors")
			bump(M.data.totals, "toolErrors")
		end
		local key = util.trim(tostring(name or ""))
		if key ~= "" then
			if M.data.tools[key] == nil and util.count(M.data.tools) >= TOOL_LIMIT then
				-- A tool list is bounded by the registry, so this only trips if a host
				-- registers its own; dropping the new name is better than growing
				-- without limit.
				key = nil
			end
			if key then M.data.tools[key] = number(M.data.tools[key]) + 1 end
		end
		M.save()
	end

	function M.recordError(at)
		local day = dayFor(at)
		bump(day, "errors")
		bump(M.data.totals, "errors")
		M.save()
	end

	-- Recovering what is already on disk ---------------------------------------

	-- A persisted transcript carries the real timestamp of every message in it, so
	-- the conversations and messages of a client that has been in use since before
	-- this file existed are real history rather than a guess, and are counted once.
	--
	-- Tokens are deliberately not seeded. Nothing on disk records them, and an
	-- estimate would be a number with no measurement behind it.
	function M.seedFromSessions(list)
		if M.data.seededAt then return 0 end
		local messages, conversations = 0, 0
		for _, session in ipairs(list or {}) do
			local first = nil
			for _, message in ipairs((session.ctx and session.ctx.messages) or {}) do
				local role = tostring(message.role or "")
				local body = util.trim(tostring(message.content or ""))
				-- An assistant turn with no prose is a tool-call round, not a reply.
				if role == "user" or (role == "assistant" and body ~= "") then
					local at = tonumber(message.at) or tonumber(session.createdAt) or clock.ms()
					M.recordMessage(role, at, true)
					messages = messages + 1
					if not first then first = at end
				end
			end
			if first and M.recordSession(session.id, first, true) then
				conversations = conversations + 1
			end
		end
		M.data.seededAt = clock.ms()
		if messages > 0 then
			log.info("stats", string.format("%s recovered from %s already on disk",
				util.pluralise(messages, "message"), util.pluralise(conversations, "conversation")))
		end
		M.saveNow()
		M.changed:fire(M.data)
		return messages
	end

	-- Observation --------------------------------------------------------------

	function M.observe()
		if M.observing then return function() end end
		M.observing = true
		local hooks = env.require("agent/hooks")
		local usage = env.require("agent/usage")

		-- Every session event passes through the hook bus, which is how this stays out
		-- of the loop and the session object entirely.
		local unhook = hooks.register("onEvent", function(payload)
			local event = payload and payload.event
			local session = payload and payload.session
			if type(event) ~= "table" then return end
			-- A subagent's requests and tokens are work the conversation asked for and
			-- are counted with it, but its messages are not messages anyone typed or
			-- read: counting those would inflate the card by however many helpers a
			-- turn happened to dispatch.
			local nested = session ~= nil
				and (session.headless == true or (tonumber(session.depth) or 0) > 0)
			local kind = event.kind
			local at = tonumber(event.at) or clock.ms()

			if kind == "user" then
				if nested then return end
				if session then M.recordSession(session.id, at) end
				M.recordMessage("user", at)
			elseif kind == "assistant:text" then
				if nested then return end
				if util.trim(tostring(event.text or "")) ~= "" then
					M.recordMessage("assistant", at)
				end
			elseif kind == "tool:result" then
				M.recordTool(event.name, event.ok ~= false, at)
			elseif kind == "tool:error" then
				M.recordTool(event.name, false, at)
			elseif kind == "error" then
				M.recordError(at)
			end
		end, { name = "stats", order = -1000 })

		local untoken = usage.recorded:connect(function(delta) M.recordRequest(delta) end)

		dispose.add(unhook, "stats.events")
		dispose.add(untoken, "stats.usage")
		-- The last few seconds of a session are the ones the debounce has not written
		-- yet, and an unload is exactly when they would be lost.
		dispose.add(function() M.saveNow() end, "stats.flush")
		return unhook
	end

	function M.init()
		if M.loaded then return M end
		M.load()
		M.observe()
		local ok, err = pcall(function()
			M.seedFromSessions(env.require("agent/session").list())
		end)
		if not ok then log.warn("stats", "could not read history from disk", err) end
		return M
	end

	-- Reading ------------------------------------------------------------------

	local RANGES = { all = 0, ["30d"] = 30, ["7d"] = 7 }
	M.RANGES = { { value = "all", label = "All" }, { value = "30d", label = "30d" }, { value = "7d", label = "7d" } }

	local function dayIsActive(day)
		return number(day.messages) > 0 or number(day.requests) > 0 or number(day.sessions) > 0
	end

	-- A streak is consecutive active days ending today, or ending yesterday when
	-- today has not started yet -- otherwise every streak would read as broken until
	-- the first message of the morning.
	local function streaksOf(active, today, from)
		local current, cursor = 0, today
		if not active[cursor] then cursor = cursor - 1 end
		while active[cursor] and (from == nil or cursor >= from) do
			current = current + 1
			cursor = cursor - 1
		end

		local ordered = {}
		for value in pairs(active) do ordered[#ordered + 1] = value end
		table.sort(ordered)
		local longest, run = 0, 0
		for index, value in ipairs(ordered) do
			if index > 1 and value == ordered[index - 1] + 1 then
				run = run + 1
			else
				run = 1
			end
			if run > longest then longest = run end
		end
		return current, longest
	end

	-- Everything the home card shows for one range, aggregated from the day records
	-- so that "all" and "7d" are the same computation over a different span rather
	-- than two sources that can disagree.
	function M.window(range)
		if not RANGES[range] then range = "all" end
		local span = RANGES[range]
		local today = clock.dayNumber()
		local from = nil
		if span > 0 then from = today - (span - 1) end

		local out = {
			range = range,
			today = clock.keyFromDayNumber(today),
			fromKey = from and clock.keyFromDayNumber(from) or nil,
			activeDays = 0,
			sessions = 0, messages = 0, userMessages = 0, replies = 0,
			tokensIn = 0, tokensOut = 0, tokens = 0, cost = 0,
			requests = 0, toolCalls = 0, toolErrors = 0, errors = 0,
			estimated = M.data.estimated == true,
			hours = {},
			models = {},
			tokensFrom = M.data.tokensFrom,
			startedAt = M.data.startedAt,
		}
		local active, perModel = {}, {}

		for key, day in pairs(M.data.days) do
			local index = clock.dayNumberOfKey(key)
			if index and index <= today and (from == nil or index >= from) then
				out.sessions = out.sessions + number(day.sessions)
				out.messages = out.messages + number(day.messages)
				out.userMessages = out.userMessages + number(day.userMessages)
				out.replies = out.replies + number(day.replies)
				out.tokensIn = out.tokensIn + number(day.tokensIn)
				out.tokensOut = out.tokensOut + number(day.tokensOut)
				out.cost = out.cost + number(day.cost)
				out.requests = out.requests + number(day.requests)
				out.toolCalls = out.toolCalls + number(day.toolCalls)
				out.toolErrors = out.toolErrors + number(day.toolErrors)
				out.errors = out.errors + number(day.errors)
				for hour, count in pairs(day.hours or {}) do
					out.hours[hour] = number(out.hours[hour]) + number(count)
				end
				for id, entry in pairs(day.models or {}) do
					local row = perModel[id]
					if not row then
						row = { id = id, requests = 0, tokensIn = 0, tokensOut = 0, cost = 0 }
						perModel[id] = row
					end
					row.requests = row.requests + number(entry.requests)
					row.tokensIn = row.tokensIn + number(entry.tokensIn)
					row.tokensOut = row.tokensOut + number(entry.tokensOut)
					row.cost = row.cost + number(entry.cost)
				end
				if dayIsActive(day) then
					active[index] = true
					out.activeDays = out.activeDays + 1
				end
			end
		end

		out.tokens = out.tokensIn + out.tokensOut
		out.currentStreak, out.longestStreak = streaksOf(active, today, from)

		local peakHour, peakCount = nil, 0
		for hour = 0, 23 do
			local count = number(out.hours[tostring(hour)])
			if count > peakCount then peakHour, peakCount = hour, count end
		end
		out.peakHour = peakHour
		out.peakHourCount = peakCount

		for _, row in pairs(perModel) do
			row.tokens = row.tokensIn + row.tokensOut
			local lifetime = M.data.models[row.id]
			row.firstAt = lifetime and lifetime.firstAt or nil
			row.lastAt = lifetime and lifetime.lastAt or nil
			out.models[#out.models + 1] = row
		end
		-- Tokens first, then requests: two models with one request each are ordered by
		-- which actually did the work.
		table.sort(out.models, function(a, b)
			if a.tokens ~= b.tokens then return a.tokens > b.tokens end
			if a.requests ~= b.requests then return a.requests > b.requests end
			return a.id < b.id
		end)
		for _, row in pairs(out.models) do
			row.share = out.tokens > 0 and (row.tokens / out.tokens)
				or (out.requests > 0 and (row.requests / out.requests) or 0)
		end
		out.topModel = out.models[1]
		return out
	end

	-- One column per week, seven rows per column, ending on the week that contains
	-- today. Every cell names the day it stands for, so a cell with no record is
	-- reported as a real day with nothing on it rather than as a gap.
	function M.heatmap(weeks)
		weeks = math.max(math.floor(tonumber(weeks) or 26), 1)
		local today = clock.dayNumber()
		-- Monday-based columns, so the last column is the current week.
		local weekday = clock.weekdayOfDayNumber(today)
		local lastMonday = today - (weekday - 1)
		local firstMonday = lastMonday - (weeks - 1) * 7

		local peak = 0
		local columns = {}
		for column = 1, weeks do
			local cells = {}
			for row = 1, 7 do
				local index = firstMonday + (column - 1) * 7 + (row - 1)
				local key = clock.keyFromDayNumber(index)
				local day = M.data.days[key]
				local value = day and (number(day.tokensIn) + number(day.tokensOut)) or 0
				local messages = day and number(day.messages) or 0
				if value > peak then peak = value end
				cells[row] = {
					key = key,
					day = index,
					future = index > today,
					tokens = value,
					messages = messages,
					sessions = day and number(day.sessions) or 0,
					requests = day and number(day.requests) or 0,
					active = day ~= nil and dayIsActive(day),
				}
			end
			columns[column] = cells
		end

		-- Four levels, so a quiet day still reads as activity next to a heavy one.
		for _, cells in ipairs(columns) do
			for _, cell in ipairs(cells) do
				cell.level = 0
				if cell.active then
					cell.level = 1
					if peak > 0 and cell.tokens > 0 then
						local share = cell.tokens / peak
						if share > 0.66 then
							cell.level = 4
						elseif share > 0.33 then
							cell.level = 3
						else
							cell.level = 2
						end
					end
				end
			end
		end
		return { columns = columns, weeks = weeks, peak = peak, fromKey = clock.keyFromDayNumber(firstMonday) }
	end

	-- The comparison the home card ends on. Absent below one whole book, because
	-- "0.4x a book" is a sentence nobody wants and a rounding away from claiming a
	-- book that was not written.
	function M.comparison(tokens)
		local value = number(tokens)
		if value < BOOK.tokens then return nil end
		local times = value / BOOK.tokens
		local rendered = string.format("%d", math.floor(times + 0.5))
		if times < 10 then rendered = string.format("%.1f", times) end
		return string.format("You've used ~%s\195\151 more tokens than %s.", rendered, BOOK.title)
	end

	function M.topTools(limit)
		local out = {}
		for name, count in pairs(M.data.tools) do
			out[#out + 1] = { name = name, count = number(count) }
		end
		table.sort(out, function(a, b)
			if a.count ~= b.count then return a.count > b.count end
			return a.name < b.name
		end)
		if limit and #out > limit then out = util.slice(out, 1, limit) end
		return out
	end

	function M.reset()
		M.data = blank()
		M.data.seededAt = clock.ms()
		rebuildSeen()
		M.saveNow()
		M.changed:fire(M.data)
	end

	return M
end
