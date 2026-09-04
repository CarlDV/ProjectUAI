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

	local M = {
		threads = {},
		activeId = nil,
		listChanged = signal.new("threads"),
	}

	function M.create(opts)
		opts = opts or {}
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
			createdAt = clock.ms(),
			updatedAt = clock.ms(),
			turns = 0,
			abortFlag = false,
			log = {},
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
		function session.send(text, onDone)
			local clean = util.trim(text)
			if clean == "" then return false, "nothing to send" end
			if session.busy then return false, "already working" end

			session.busy = true
			session.abortFlag = false
			session.turns = session.turns + 1
			if session.title == "New chat" then
				session.title = util.ellipsis(clean, 42)
				M.listChanged:fire()
			end
			session.emit("user", { text = clean })

			task.spawn(function()
				local loop = env.require("agent/loop")
				local ok, reply = pcall(loop.run, session, clean)
				session.busy = false
				permissions.denyAll()
				if not ok then
					log.error("session", "loop crashed", reply)
					session.emit("error", { message = "Internal error: " .. tostring(reply), fatal = true })
					session.emit("status", { text = "Ready" })
					reply = "Something went wrong inside the agent: " .. tostring(reply)
				end
				M.persist(session)
				if onDone then pcall(onDone, reply) end
			end)
			return true
		end

		function session.abort()
			if not session.busy then return false end
			session.abortFlag = true
			session.emit("status", { text = "Stopping" })
			permissions.denyAll("aborted")
			return true
		end

		function session.clear()
			session.ctx.clear()
			session.log = {}
			session.turns = 0
			session.title = "New chat"
			session.emit("cleared", {})
			session.emit("status", { text = "Ready" })
			M.persist(session)
		end

		function session.stats()
			local stats = session.ctx.stats()
			stats.busy = session.busy
			stats.turns = session.turns
			stats.todos = state.todoCounts()
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
	function M.persist(session)
		if not fsx.enabled or session.headless then return false end
		if session.depth and session.depth > 0 then return false end
		return fsx.writeJson(THREAD_DIR .. "/" .. session.id .. ".json", {
			id = session.id,
			title = session.title,
			updatedAt = session.updatedAt,
			createdAt = session.createdAt,
			turns = session.turns,
			context = session.ctx.serialise(),
		})
	end

	function M.restore()
		if not fsx.enabled then return 0 end
		local restored = 0
		for _, entry in ipairs(fsx.list(THREAD_DIR)) do
			if entry.name:match("%.json$") then
				local data = fsx.readJson(entry.path, nil)
				if type(data) == "table" and data.id then
					local session = M.create({ id = data.id, title = data.title })
					session.createdAt = data.createdAt or session.createdAt
					session.updatedAt = data.updatedAt or session.updatedAt
					session.turns = data.turns or 0
					session.ctx.restore(data.context)
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
