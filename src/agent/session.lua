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
	local attachments = env.require("runtime/attachments")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")
	local context = env.require("agent/context")
	local transcript = env.require("agent/transcript")
	local hooks = env.require("agent/hooks")
	local permissions = env.require("agent/permissions")
	local state = env.require("agent/state")

	local THREAD_DIR = "sessions"
	-- Disk history survives eviction. Unsaved/ephemeral threads stay in memory.
	local THREAD_LIMIT = 64
	local running, alive = 0, true

	-- How long a pasted message may be before it stops being a message. A long script
	-- pasted into the composer is reference material, not a request: sent whole it
	-- drowns the turn, and the model's only use for it is file_read anyway. Over this
	-- the body goes to pastes/ and the conversation carries a pointer -- the user's
	-- words plus "the code is in this file" -- which is the same information for a
	-- fraction of the context.
	local PASTE_CAP = attachments.INLINE_LIMIT

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

	-- Published for the composer's paste detection, so the two halves of the feature
	-- share one number rather than each keeping a copy that drifts.
	M.PASTE_CAP = PASTE_CAP

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
			-- Tools this conversation must not be offered at all -- not denied, absent.
			-- The registry's definitions() reads it; the field is opt-in so a session
			-- that wants everything (the main conversation) does not have to say so.
			toolExclude = opts.toolExclude,
			budgetSeconds = opts.budgetSeconds,
			-- Set by whoever created the session, and read by the loop in place of the
			-- global switch: a subagent carries its own budget, so lifting it is a
			-- decision the dispatcher takes per child rather than one a conversation
			-- inherits from a setting.
			unlimited = opts.unlimited == true,
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
			toolEpoch = {},
			abortFlag = false,
			log = {},
			logBytes = 0,
			-- The plan for this conversation's job. agent/state owns the shape of it;
			-- the list lives here so two conversations cannot overwrite each other's.
			todos = {},
		}

		session.transcript = transcript.new(session)
		session.appendLog = session.transcript.append
		function session.emit(kind, payload)
			if session.removed or not alive then return end
			payload = util.copy(payload or {})
			payload.kind = kind
			payload.at = clock.ms()
			session.updatedAt = payload.at
			if kind == "status" then session.status = payload.text or session.status end
			if kind == "request:start" then session.liveRequest, session.livePreview = payload, nil
			elseif kind == "assistant:preview" then session.livePreview = payload
			elseif kind == "request:done" then session.liveRequest = nil; if payload.error then session.livePreview = nil end
			elseif kind == "assistant:complete" or kind == "abort" or kind == "error" or kind == "cleared" or (kind == "status" and payload.text == "Ready") then
				session.liveRequest, session.livePreview = nil, nil
			end
			if not session.headless then
				local retained = session.appendLog(payload)
				payload.transcriptId = retained and retained.transcriptId or nil
			end
			hooks.run("onEvent", { session = session, event = payload })
			session.events:fire(payload)
			M.anyEvent:fire(session, payload)
		end

		function session.aborted()
			return session.abortFlag == true or session.removed == true or not alive
		end

		function session.toolContext()
			-- A later send clears abortFlag. Old tool workers must not come back to
			-- life when that happens after a stopped or failed turn.
			local epoch = session.toolEpoch
			local cancelled = false
			local function aborted()
				cancelled = cancelled or session.toolEpoch ~= epoch or session.aborted()
				return cancelled
			end
			return {
				env = env,
				session = session,
				depth = session.depth,
				emit = function(kind, text)
					if not aborted() then session.emit(kind, type(text) == "table" and text or { text = text }) end
				end,
				progress = function(text)
					if not aborted() then session.emit("tool:progress", { text = tostring(text) }) end
				end,
				aborted = aborted,
			}
		end

		-- Runs on its own thread so the interface stays responsive, and guards
		-- against re-entry: two prompts in flight would interleave tool results
		-- into one transcript.
		--
		-- Two conversations may run at once, though -- that is the point of threads --
		-- so everything in here that reaches outside the session has to name it.
		function session.send(text, onDone, files)
			text = tostring(text or "")
			local clean = util.trim(text)
			if clean == "" then return false, "nothing to send" end
			if session.busy or session.preparing then return false, "already working" end
			if session.removed then return false, "conversation no longer exists" end
			files = files or {}
			if type(files) ~= "table" or not util.isArray(files) or #files > 32 then return false, "invalid attachment list" end

			local title = util.ellipsis(clean, 42)
			-- This boundary also covers Quick Chat, bridge clients and host scripts.
			-- Never turn a failed upload into an enormous inference request.
			if #text > PASTE_CAP or #files > 0 then
				local preparation = {}
				session.preparing = preparation
				local ok, prepared, why = pcall(function()
					local readable = false
					for _, tool in ipairs(env.require("agent/registry").definitions({ only = session.toolFilter,
						groups = session.toolGroups, exclude = session.toolExclude })) do
						if tool["function"].name == "file_read" then readable = true; break end
					end
					if not readable then return nil, "Enable the Files tools and file storage to send long inputs as files." end
					for _, file in ipairs(files) do
						if type(file) ~= "table" or type(file.path) ~= "string" or type(file.bytes) ~= "number" then return nil, "invalid attachment reference" end
						local content, err = fsx.readUser(file.path)
						if not content or #content ~= file.bytes then return nil, "attachment is missing or changed: " .. file.path .. ". " .. tostring(err or "Attach it again.") end
					end
					if #text <= PASTE_CAP then return clean end
					local entry, err = attachments.save(text)
					if not entry then return nil, err end
					return attachments.reference(entry) .. "\n\nRead this file for the user's complete input, including any request at the end."
				end)
				if session.preparing ~= preparation then return false, "message preparation was cancelled; your draft was kept" end
				session.preparing = nil
				if not ok or not prepared then return false, ok and why or tostring(prepared) end
				clean = prepared
			end

			if not alive or running >= 8 then return false, "Eight native session workers are already active; wait for a turn to finish" end
			running = running + 1
			session.busy = true
			session.abortFlag = false
			session.turns = session.turns + 1
			session.toolEpoch = {}
			if session.title == "New chat" and not session.named then
				session.title = title
			end
			session.emit("user", { text = clean })
			-- The list is where "this one is still working" is visible while you are
			-- reading another conversation, so a busy flag that moves is a list change.
			M.listChanged:fire()

			task.spawn(function()
				local ok, reply = pcall(function()
					return env.require("agent/loop").run(session, clean)
				end)
				if not ok then session.abortFlag = true end
				running = math.max(0, running - 1)
				session.busy = false
				if session.removed or not alive then return end
				-- Only this conversation's prompts. It used to clear every pending
				-- request in the client, so one conversation finishing a turn silently
				-- denied whatever another was waiting on -- and a denied write is
				-- reported to that model as the user refusing it.
				permissions.denyAll(nil, session)
				-- Its questions too: a turn that ended still had an ask on screen, which
				-- the user could then answer for a conversation that had moved on.
				pcall(function() env.require("ui/panels/ask").sweep(session) end)
				if not ok then
					log.error("session", "loop crashed", reply)
					session.emit("error", { message = "The native agent stopped after an internal error", fatal = true })
					reply = "The native agent stopped after an internal error. Your conversation is retained."
					session.emit("turn:end", { text = reply, failed = true })
					session.emit("status", { text = "Ready" })
				end
				M.persist(session)
				M.listChanged:fire()
				if onDone and not session.removed then pcall(onDone, reply) end
			end)
			return true
		end

		function session.abort()
			session.toolEpoch = {}
			session.abortFlag = session.busy == true
			local capture = env.loadedModules and env.loadedModules["runtime/remote_capture"]
			if capture then capture.revokeAgent(session.id) end
			if session.preparing then session.preparing = nil; return true end
			local loops = env.loadedModules and env.loadedModules["runtime/chatloops"]
			local stoppedLoops = loops and loops.stop(nil, session) or 0
			if not session.busy then return stoppedLoops > 0 end
			session.abortFlag = true
			session.emit("status", { text = "Stopping" })
			permissions.denyAll("aborted", session)
			pcall(function() env.require("ui/panels/ask").sweep(session) end)
			return true
		end

		-- Fold older turns into the summary now, on the user's command, without
		-- starting a turn. Reuses the busy interlock so a send cannot interleave with
		-- the mutation, and persists the trimmed conversation when it changes.
		function session.compact(onDone)
			if session.busy or session.preparing then return false, "already working" end
			if session.removed then return false, "conversation no longer exists" end
			if not alive or running >= 8 then return false, "Eight native session workers are already active; wait for a turn to finish" end
			running = running + 1
			session.busy = true
			session.abortFlag = false
			session.emit("status", { text = "Compacting" })
			M.listChanged:fire()
			task.spawn(function()
				local ok, summary = pcall(function()
					return env.require("agent/loop").compact(session)
				end)
				running = math.max(0, running - 1)
				session.busy = false
				if session.removed or not alive then return end
				session.emit("status", { text = "Ready" })
				if not ok then log.error("session", "manual compaction crashed", summary) end
				if ok and summary then M.persist(session) end
				M.listChanged:fire()
				if onDone then pcall(onDone, ok and summary ~= nil, ok and summary or nil) end
			end)
			return true
		end

		function session.clear()
			if session.busy then return false, "Stop this turn before clearing its conversation" end
			session.preparing = nil
			attachments.clearUploads(session.id)
			local loops = env.loadedModules and env.loadedModules["runtime/chatloops"]
			if loops then loops.stop(nil, session) end
			local subagents = env.loadedModules and env.loadedModules["agent/subagent"]
			if subagents then subagents.stopAll(session) end
			session.ctx.clear()
			session.transcript.reset()
			session.viewState = nil
			session.turns = 0
			session.toolEpoch = {}
			session.abortFlag = false
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
		table.sort(out, function(a, b)
			if a.updatedAt ~= b.updatedAt then return (a.updatedAt or 0) > (b.updatedAt or 0) end
			return a.id < b.id
		end)
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
				for _, event in ipairs(session.log) do
					if event.kind == "user" or event.kind == "assistant:text" then
						local body = tostring(event.text or "")
						local at = body:lower():find(needle, 1, true)
						if at then
							where = event.kind == "user" and "message" or "reply"
							snippet = util.ellipsis(body:sub(math.max(at - 40, 1)), 120)
							break
						end
					end
				end
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
		session.preparing, session.removed = nil, true
		attachments.clearUploads(id)
		session.abort(); session.events:clear()
		local subagents = env.loadedModules and env.loadedModules["agent/subagent"]
		if subagents then subagents.stopAll(session) end
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
			if not victim.busy and not victim.preparing and victim.id ~= M.activeId and fsx.enabled and M.persist(victim) then
				victim.removed = true; victim.abort(); victim.events:clear(); M.threads[victim.id] = nil
				attachments.clearUploads(victim.id)
				local subagents = env.loadedModules and env.loadedModules["agent/subagent"]
				if subagents then subagents.stopAll(victim) end
			end
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
		if not fsx.enabled or session.headless or session.removed then return false end
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
			turns = session.turns, opencodeSession = session.opencodeSession,
			context = session.ctx.serialise(),
			transcript = session.transcript.snapshot(),
			transcriptState = session.transcript.metadata(),
		})
	end

	function M.restore()
		if not fsx.enabled then return 0 end
		local restored, candidates = 0, {}
		local function timestamp(value)
			local number = tonumber(value)
			return number and number == number and number > 0 and number < math.huge and number or 0
		end
		local function readThread(entry)
			if entry.isDir or not entry.name:match("%.json$") then return nil end
			local raw = fsx.read(entry.path)
			local data = raw and #raw <= 12 * 1024 * 1024 and util.decode(raw)
			if type(data) ~= "table" or type(data.id) ~= "string" or #data.id > 120
				or not data.id:match("^[%w_-]+$") or entry.name ~= data.id .. ".json" then return nil end
			return data
		end
		-- Keep only candidate metadata while finding the newest files; a host listing
		-- is alphabetic, not ordered by conversation activity.
		for _, entry in ipairs(fsx.list(THREAD_DIR)) do
			local data = readThread(entry)
			if data and not M.threads[data.id] then
				candidates[#candidates + 1] = { entry = entry, id = data.id, updatedAt = timestamp(data.updatedAt) }
				table.sort(candidates, function(a, b)
					if a.updatedAt ~= b.updatedAt then return a.updatedAt > b.updatedAt end
					return a.id < b.id
				end)
				if #candidates > THREAD_LIMIT then table.remove(candidates) end
			end
		end
		local slots = math.max(0, THREAD_LIMIT - #M.list())
		for index = 1, math.min(slots, #candidates) do
			local candidate = candidates[index]
			local data = readThread(candidate.entry)
			if data and data.id == candidate.id and not M.threads[data.id] then
				local session = M.create({
					id = data.id,
					title = type(data.title) == "string" and util.ellipsis(data.title, 60) or nil,
					placeId = tonumber(data.placeId),
					placeName = type(data.placeName) == "string" and data.placeName or nil,
				})
				session.named = data.named == true
				session.createdAt = timestamp(data.createdAt)
				session.updatedAt = timestamp(data.updatedAt)
				session.turns = math.floor(timestamp(data.turns)); session.opencodeSession = data.opencodeSession
				session.ctx.restore(data.context)
				session.transcript.restore(data.transcript, session.ctx, data.transcriptState)
				M.threads[session.id] = session
				restored = restored + 1
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

	M.limits = { threads = THREAD_LIMIT, workers = 8, events = transcript.limits.events,
		transcriptBytes = transcript.limits.bytes, transcriptBudgets = transcript.limits.budgets }
	env.require("runtime/dispose").add(function()
		alive = false
		for _, item in pairs(M.threads) do item.abort(); item.events:clear() end
		M.anyEvent:clear(); M.listChanged:clear()
	end, "native sessions")
	return M
end
