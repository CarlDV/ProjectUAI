-- Sessions: the object the interface talks to, and the thread list behind it.
--
-- A session owns a conversation, an event stream and a busy flag. The loop is a
-- pure function over a session, so a subagent is just another session with a
-- smaller tool set and no interface attached -- which is why this module, not the
-- loop, is where threads and persistence live.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local fsx = env.require("runtime/fsx")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")
	local context = env.require("agent/context")
	local hooks = env.require("agent/hooks")
	local permissions = env.require("agent/permissions")
	local state = env.require("agent/state")

	local THREAD_DIR = "sessions"
	local THREAD_LIMIT = 20

	-- Which events are the transcript, as opposed to the running commentary around one.
	--
	-- Only these are written to disk. The rest are either meaningless after the fact -- a
	-- status line, a request that has already finished, a progress tick, a token count --
	-- or not serialisable at all: a `permission:ask` payload carries the closure that
	-- answers it, and encoding that would fail the whole write.
	local DURABLE = {
		["user"] = true,
		["assistant:text"] = true,
		["assistant:reasoning"] = true,
		["tool:call"] = true,
		["tool:result"] = true,
		["tool:error"] = true,
		["subagent:start"] = true,
		["subagent:text"] = true,
		["subagent:tool"] = true,
		["subagent:tool:done"] = true,
		["subagent:done"] = true,
		["request:retry"] = true,
		["provider:switch"] = true,
		["compact"] = true,
		["error"] = true,
		["abort"] = true,
	}

	-- How much of a conversation a file carries. The in-memory log holds 400 events; a
	-- stored one holds the most recent 300, any single string in it is capped, and the
	-- whole thing is capped again -- because 300 events times one 12000-character tool
	-- result is a three-megabyte write, and this is written after every turn.
	local TRANSCRIPT_LIMIT = 300
	local FIELD_CAP = 12000
	local TRANSCRIPT_BYTES = 262144

	local function transcriptOf(session)
		local durable = {}
		for _, event in ipairs(session.log) do
			if DURABLE[tostring(event.kind)] then durable[#durable + 1] = event end
		end
		-- Newest first while the budget is spent, then reversed: what a reader wants back
		-- from a long conversation is the end of it.
		local newest = {}
		local budget = TRANSCRIPT_BYTES
		for index = #durable, math.max(#durable - TRANSCRIPT_LIMIT + 1, 1), -1 do
			local event = durable[index]
			local copy, cost = {}, 0
			for key, value in pairs(event) do
				local kind = type(value)
				if kind == "string" then
					if #value > FIELD_CAP then
						copy[key] = (util.truncate(value, FIELD_CAP,
							"the rest was not kept in the stored transcript"))
					else
						copy[key] = value
					end
					cost = cost + #copy[key] + #tostring(key)
				elseif kind == "number" or kind == "boolean" then
					copy[key] = value
					cost = cost + 12
				end
				-- Anything else -- a table, a function, an instance -- is dropped. No
				-- durable event needs one to render, and one stray field would take the
				-- whole file's write with it.
			end
			if #newest > 0 and cost > budget then break end
			budget = budget - cost
			newest[#newest + 1] = copy
		end
		local out = {}
		for index = #newest, 1, -1 do out[#out + 1] = newest[index] end
		return out
	end

	local M = {
		threads = {},
		activeId = nil,
		listChanged = signal.new("threads"),
		-- Every event from every session, with the session it came from.
		--
		-- A per-session stream is what a panel showing one conversation wants, and it is
		-- what the transcript uses. It is the wrong shape for anything that has to answer
		-- a conversation nobody is looking at -- and the permission prompt is exactly
		-- that: it subscribed to the active session only, so a second conversation left
		-- running in the background raised a prompt into a stream with no listener and sat
		-- there until its own deadline denied every call it had asked for.
		anyEvent = signal.new("session:any"),
	}

	function M.create(opts)
		opts = opts or {}
		local place = env.require("runtime/place")
		local session = {
			id = opts.id or util.uid("s"),
			title = opts.title or "New chat",
			ctx = context.new(),
			events = signal.new("session"),
			status = "Ready",
			busy = false,
			depth = opts.depth or 0,
			maxTurns = opts.maxTurns,
			toolFilter = opts.toolFilter,
			toolGroups = opts.toolGroups,
			budgetSeconds = opts.budgetSeconds,
			stream = opts.stream,
			headless = opts.headless == true,
			-- Which place the conversation happened in. A client is loaded into one game
			-- at a time and the transcripts outlive the visit, so without this the list
			-- is a flat pile of titles with no way to tell last week's game from this
			-- one. Recorded at creation rather than read at display time, because by the
			-- time anyone reads it they are somewhere else.
			placeId = opts.placeId or place.id,
			placeName = opts.placeName or place.label(),
			createdAt = clock.ms(),
			updatedAt = clock.ms(),
			turns = 0,
			abortFlag = false,
			log = {},
			-- The plan for this conversation's job. agent/state owns the shape of it;
			-- the list lives here so two conversations cannot overwrite each other's.
			todos = {},
		}

		-- Every event is mirrored into a bounded per-session log so a panel opened
		-- mid-turn can render what it missed, and so the transcript survives a
		-- switch away and back.
		function session.emit(kind, payload)
			payload = payload or {}
			payload.kind = kind
			payload.at = clock.ms()
			session.updatedAt = payload.at
			if kind == "status" then session.status = payload.text or session.status end
			if not session.headless then
				session.log[#session.log + 1] = payload
				if #session.log > 400 then table.remove(session.log, 1) end
			end
			hooks.run("onEvent", { session = session, event = payload })
			session.events:fire(payload)
			M.anyEvent:fire(session, payload)
		end

		function session.aborted()
			return session.abortFlag == true
		end

		function session.toolContext()
			return {
				env = env,
				session = session,
				depth = session.depth,
				emit = function(kind, text)
					session.emit(kind, type(text) == "table" and text or { text = text })
				end,
				progress = function(text)
					session.emit("tool:progress", { text = tostring(text) })
				end,
				aborted = session.aborted,
			}
		end

		-- Runs on its own thread so the interface stays responsive, and guards
		-- against re-entry: two prompts in flight would interleave tool results
		-- into one transcript.
		--
		-- Two conversations may run at once, though -- that is the point of threads --
		-- so everything in here that reaches outside the session has to name it.
		function session.send(text, onDone)
			local clean = util.trim(text)
			if clean == "" then return false, "nothing to send" end
			if session.busy then return false, "already working" end

			session.busy = true
			session.abortFlag = false
			session.turns = session.turns + 1
			if session.title == "New chat" and not session.named then
				session.title = util.ellipsis(clean, 42)
			end
			session.emit("user", { text = clean })
			-- The list is where "this one is still working" is visible while you are
			-- reading another conversation, so a busy flag that moves is a list change.
			M.listChanged:fire()

			task.spawn(function()
				local loop = env.require("agent/loop")
				local ok, reply = pcall(loop.run, session, clean)
				session.busy = false
				-- Only this conversation's prompts. It used to clear every pending
				-- request in the client, so one conversation finishing a turn silently
				-- denied whatever another was waiting on -- and a denied write is
				-- reported to that model as the user refusing it.
				permissions.denyAll(nil, session)
				if not ok then
					log.error("session", "loop crashed", reply)
					session.emit("error", { message = "Internal error: " .. tostring(reply), fatal = true })
					session.emit("status", { text = "Ready" })
					reply = "Something went wrong inside the agent: " .. tostring(reply)
				end
				M.persist(session)
				M.listChanged:fire()
				if onDone then pcall(onDone, reply) end
			end)
			return true
		end

		function session.abort()
			if not session.busy then return false end
			session.abortFlag = true
			session.emit("status", { text = "Stopping" })
			permissions.denyAll("aborted", session)
			return true
		end

		function session.clear()
			session.ctx.clear()
			session.log = {}
			session.turns = 0
			session.title = "New chat"
			-- The plan goes with the conversation it belonged to.
			state.clearTodos(session)
			session.emit("cleared", {})
			session.emit("status", { text = "Ready" })
			M.persist(session)
		end

		-- A title the user typed wins over the one derived from the first message, and
		-- keeps winning: the derivation only ever fires while the title is still the
		-- placeholder.
		function session.rename(title)
			local clean = util.ellipsis(util.trim(title), 60)
			if clean == "" then return false, "a conversation needs a title" end
			session.title = clean
			session.named = true
			M.listChanged:fire()
			M.persist(session)
			return true
		end

		-- Nothing about this conversation is written to disk. The composer's isolation
		-- toggle is what turns it on, for the same reason a worktree exists: somewhere
		-- to try something without it becoming part of the history.
		function session.setEphemeral(value)
			session.ephemeral = value == true
			if session.ephemeral and fsx.enabled then
				fsx.delete(THREAD_DIR .. "/" .. session.id .. ".json")
			else
				M.persist(session)
			end
			M.listChanged:fire()
			return session.ephemeral
		end

		function session.stats()
			local stats = session.ctx.stats()
			stats.busy = session.busy
			stats.turns = session.turns
			stats.todos = state.todoCounts(session)
			return stats
		end

		return session
	end

	-- Threads ---------------------------------------------------------------

	function M.current()
		if M.activeId and M.threads[M.activeId] then return M.threads[M.activeId] end
		return M.newThread()
	end

	function M.newThread(opts)
		local session = M.create(opts)
		M.threads[session.id] = session
		M.activeId = session.id
		M.trimThreads()
		M.listChanged:fire()
		return session
	end

	function M.switch(id)
		if not M.threads[id] then return false end
		M.activeId = id
		M.listChanged:fire()
		return true
	end

	function M.list()
		local out = {}
		for _, session in pairs(M.threads) do out[#out + 1] = session end
		table.sort(out, function(a, b) return (a.updatedAt or 0) > (b.updatedAt or 0) end)
		return out
	end

	-- The conversations currently running a turn, newest activity first.
	--
	-- Switching conversation does not stop the one you left -- its loop is on its own
	-- thread and keeps going -- so more than one can be working at a time, and the
	-- interface needs to be able to say which. Anything that reads "is the agent
	-- busy" from the active session alone is asking the wrong question.
	function M.busy()
		local out = {}
		for _, session in ipairs(M.list()) do
			if session.busy then out[#out + 1] = session end
		end
		return out
	end

	function M.busyCount()
		return #M.busy()
	end

	-- Conversations grouped by the place they happened in, most recently used group
	-- first, with the place the client is in now always at the top -- that is the one
	-- a new conversation would join.
	function M.groups()
		local place = env.require("runtime/place")
		local byPlace, order = {}, {}
		for _, session in ipairs(M.list()) do
			local key = tostring(session.placeId or 0)
			local group = byPlace[key]
			if not group then
				local label = session.placeName
				if label == nil or util.trim(tostring(label)) == "" then
					-- A transcript from before the place was recorded, or from a host that
					-- could not read it. "Place 0" would read as a place.
					label = (session.placeId and session.placeId > 0)
						and ("Place " .. key) or "Unknown place"
				end
				group = {
					placeId = session.placeId or 0,
					-- The name recorded when the conversation started, except for the
					-- current place, where the live label is better: it may have resolved
					-- since, and a place can be renamed.
					label = label,
					sessions = {},
					updatedAt = 0,
					current = (session.placeId or 0) == place.id,
				}
				if group.current then group.label = place.label() end
				byPlace[key] = group
				order[#order + 1] = group
			end
			group.sessions[#group.sessions + 1] = session
			if (session.updatedAt or 0) > group.updatedAt then group.updatedAt = session.updatedAt or 0 end
		end
		table.sort(order, function(a, b)
			if a.current ~= b.current then return a.current end
			if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end
			return tostring(a.label) < tostring(b.label)
		end)
		return order
	end

	-- Title, then the transcript. A search that only matched titles would miss the
	-- conversation you remember by something that was said in it.
	function M.search(query)
		local needle = util.trim(tostring(query or "")):lower()
		if needle == "" then return {} end
		local out = {}
		for _, session in ipairs(M.list()) do
			local where, snippet = nil, nil
			if tostring(session.title):lower():find(needle, 1, true) then
				where = "title"
			end
			if not where then
				for _, message in ipairs(session.ctx.messages or {}) do
					local body = tostring(message.content or "")
					local at = body:lower():find(needle, 1, true)
					if at then
						where = message.role == "user" and "message" or "reply"
						snippet = util.ellipsis(body:sub(math.max(at - 40, 1)), 120)
						break
					end
				end
			end
			if where then
				out[#out + 1] = { session = session, where = where, snippet = snippet }
			end
		end
		return out
	end

	function M.remove(id)
		local session = M.threads[id]
		if not session then return false end
		if session.busy then session.abort() end
		M.threads[id] = nil
		if fsx.enabled then fsx.delete(THREAD_DIR .. "/" .. id .. ".json") end
		if M.activeId == id then
			local remaining = M.list()
			M.activeId = remaining[1] and remaining[1].id or nil
			if not M.activeId then M.newThread() end
		end
		M.listChanged:fire()
		return true
	end

	function M.trimThreads()
		local ordered = M.list()
		for index = THREAD_LIMIT + 1, #ordered do
			local victim = ordered[index]
			if not victim.busy and victim.id ~= M.activeId then M.remove(victim.id) end
		end
	end

	-- Persistence is best-effort by design: a host with no filesystem simply keeps
	-- everything in memory for the session, and nothing above here cares.
	--
	-- The transcript goes in the file as well as the context. It did not, and the
	-- consequence was the one thing about restored conversations anybody would notice:
	-- the sidebar listed them, switching to one worked, and the panel showed the
	-- greeting card -- because the transcript is a pure function of `session.log` and
	-- `log` was the one field restore left empty. `ctx.serialise` is not a substitute:
	-- it keeps what the *model* needs to continue, which has no reasoning, no timings,
	-- no risk levels and no tool arguments.
	function M.persist(session)
		if not fsx.enabled or session.headless then return false end
		if session.depth and session.depth > 0 then return false end
		if session.ephemeral then return false end
		return fsx.writeJson(THREAD_DIR .. "/" .. session.id .. ".json", {
			id = session.id,
			title = session.title,
			named = session.named == true,
			placeId = session.placeId,
			placeName = session.placeName,
			updatedAt = session.updatedAt,
			createdAt = session.createdAt,
			turns = session.turns,
			context = session.ctx.serialise(),
			transcript = transcriptOf(session),
		})
	end

	function M.restore()
		if not fsx.enabled then return 0 end
		local restored = 0
		for _, entry in ipairs(fsx.list(THREAD_DIR)) do
			if entry.name:match("%.json$") then
				local data = fsx.readJson(entry.path, nil)
				if type(data) == "table" and data.id then
					local session = M.create({
						id = data.id,
						title = data.title,
						placeId = tonumber(data.placeId),
						placeName = data.placeName,
					})
					session.named = data.named == true
					session.createdAt = data.createdAt or session.createdAt
					session.updatedAt = data.updatedAt or session.updatedAt
					session.turns = data.turns or 0
					session.ctx.restore(data.context)
					-- Replayed by the view in the order it happened. A file written before
					-- transcripts were stored simply has none, and that conversation opens on
					-- the greeting exactly as it used to.
					if type(data.transcript) == "table" then
						for _, event in ipairs(data.transcript) do
							if type(event) == "table" and event.kind then
								session.log[#session.log + 1] = event
							end
						end
					end
					M.threads[session.id] = session
					restored = restored + 1
				end
			end
		end
		if restored > 0 then
			local ordered = M.list()
			M.activeId = ordered[1] and ordered[1].id or nil
			log.info("session", util.pluralise(restored, "conversation") .. " restored")
			M.listChanged:fire()
		end
		return restored
	end

	return M
end
