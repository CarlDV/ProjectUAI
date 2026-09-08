-- The game half of the web bridge.
--
-- A Roblox client cannot listen for a connection, so it cannot be talked to -- it
-- can only talk. This module is therefore a client of a small local process
-- (bridge/server.js) rather than a server: it pushes the session's events up and
-- long-polls for anything typed in the browser.
--
-- Two threads, because the two directions have different rhythms. Events must
-- leave promptly and in order, so they are batched off a queue every fraction of a
-- second. Commands arrive rarely, so that direction is one request held open for
-- eighteen seconds at a time -- which reads as instant and costs three requests a
-- minute, where a busy poll would cost hundreds.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local config = env.require("runtime/config")
	local dispose = env.require("runtime/dispose")
	local caps = env.require("runtime/caps")
	local http = env.require("net/http")
	local signal = env.require("runtime/signal")

	-- Fired on a state transition only -- started, stopped, reachable, unreachable --
	-- so the Settings panel can show the truth without polling for it.
	local M = { running = false, online = false, lastError = nil, changed = signal.new("bridge") }

	-- Longest a single string may be on the wire. A tool result can be the whole
	-- source of a script; the browser shows a preview and the in-game view remains
	-- the place to read the rest.
	local FIELD_CAP = 4000
	local QUEUE_CAP = 200
	local DRAIN_SECONDS = 0.15
	local POLL_TIMEOUT = 25

	-- What the browser renders. Everything else -- reasoning, usage, request and turn
	-- bookkeeping, compaction -- stays in the client, so a thinking block does not
	-- travel over the wire to be discarded on arrival.
	local FORWARD = {
		["user"] = true,
		["assistant:text"] = true,
		["tool:call"] = true,
		["tool:result"] = true,
		["tool:error"] = true,
		["tool:progress"] = true,
		["status"] = true,
		["error"] = true,
		["abort"] = true,
		["cleared"] = true,
		["provider:switch"] = true,
		["permission:ask"] = true,
		["subagent:start"] = true,
		["subagent:done"] = true,
		-- The running commentary around a turn. None of it is conversation, but the
		-- browser's telemetry, latency readouts and live subagent cards are built
		-- from exactly these.
		["assistant:reasoning"] = true,
		["request:start"] = true,
		["request:retry"] = true,
		["request:done"] = true,
		["usage"] = true,
		["turn:start"] = true,
		["turn:end"] = true,
		["compact"] = true,
		["subagent:text"] = true,
		["subagent:tool"] = true,
		["subagent:tool:done"] = true,
	}

	-- Event payloads are not automatically safe to encode. `permission:ask` carries
	-- the resolve function the in-game panel calls, and signal.lua exists precisely
	-- so that payloads like it can hold non-serialisable values. Anything that is
	-- not a string, number, boolean or table is dropped rather than encoded.
	local function scrub(value, depth)
		local kind = type(value)
		if kind == "string" then return util.ellipsis(value, FIELD_CAP) end
		if kind == "number" or kind == "boolean" then return value end
		if kind ~= "table" or depth > 5 then return nil end
		local out = {}
		for key, item in pairs(value) do
			local keyKind = type(key)
			if keyKind == "string" or keyKind == "number" then
				local cleaned = scrub(item, depth + 1)
				if cleaned ~= nil then out[key] = cleaned end
			end
		end
		return out
	end

	local queue = {}
	local snapshotPending = nil

	local function enqueue(payload)
		if type(payload) ~= "table" or not FORWARD[payload.kind] then return end
		queue[#queue + 1] = scrub(payload, 0)
		-- Dropping the oldest rather than the newest: a browser that reconnects gets
		-- a fresh snapshot anyway, so the recent end is the half worth keeping.
		while #queue > QUEUE_CAP do table.remove(queue, 1) end
	end

	-- A browser can open at any point in a turn, so the game sends its whole
	-- transcript on connect and whenever the active thread changes. session.log is
	-- already bounded to 400 entries, which is the same ceiling the in-game view
	-- redraws from.
	local function snapshotOf(session)
		local out = {}
		for _, payload in ipairs(session.log or {}) do
			if FORWARD[payload.kind] then out[#out + 1] = scrub(payload, 0) end
		end
		return out
	end

	local attachedId, detach = nil, nil

	-- The browser follows the active thread rather than owning one, so switching
	-- conversations in-game moves the browser with it. Re-checked on every drain
	-- because a switch is not announced to this module directly.
	local function attach()
		local sessions = env.require("agent/session")
		local session = sessions.current()
		if attachedId == session.id then return session end
		if detach then
			pcall(detach)
			detach = nil
		end
		attachedId = session.id
		detach = session.events:connect(enqueue)
		snapshotPending = snapshotOf(session)
		return session
	end

	local function base()
		return "http://127.0.0.1:" .. tostring(config.get("bridge.port", 8790))
	end

	local function headers()
		return { ["Authorization"] = "Bearer " .. tostring(config.get("bridge.token", "")) }
	end

	-- `identity = "none"` because the Claude Code headers identify this client to an
	-- inference gateway and mean nothing to a local relay. `silent` keeps the poll
	-- out of the Requests view.
	local function call(spec)
		spec.headers = headers()
		spec.identity = "none"
		spec.silent = true
		spec.tag = "bridge"
		return http.request(spec)
	end

	local function runCommand(command)
		if type(command) ~= "table" then return end
		local sessions = env.require("agent/session")
		local kind = tostring(command.type or "")

		if kind == "send" then
			local session = attach()
			local ok, why = session.send(tostring(command.text or ""))
			-- A refusal has to travel back, or the browser shows a message it sent and
			-- then nothing at all. session.send declines while a turn is in flight.
			if not ok then
				enqueue({ kind = "error", message = tostring(why or "could not send"), fatal = false })
			end
		elseif kind == "abort" then
			sessions.current().abort()
		elseif kind == "clear" then
			sessions.current().clear()
		elseif kind == "permission" then
			-- The same door the in-game panel uses: the agent left a resolve function
			-- behind and whoever answers first calls it. No new authority is created
			-- here, and an id that has already been answered is simply absent.
			local permissions = env.require("agent/permissions")
			local entry = permissions.pending[tostring(command.id or "")]
			if entry and type(entry.resolve) == "function" then
				entry.resolve(command.allow == true, command.remember == true)
			end
		elseif kind == "provider" then
			env.require("provider/registry").setActive(tostring(command.id or ""))
		elseif kind == "model" then
			env.require("provider/registry").setModel(tostring(command.provider or ""), tostring(command.model or ""))
		elseif kind == "models:discover" then
			-- Discovery is a network round trip, so it runs on its own thread: the
			-- poller must not park behind it or the browser would stall for seconds.
			local providers = env.require("provider/registry")
			local record = providers.get(tostring(command.provider or ""))
			if record then
				clock.spawn(function()
					local models = env.require("provider/models")
					local ids, note = models.discover(record, { force = true })
					local count = type(ids) == "table" and #ids or 0
					log.info("bridge", "model discovery: " .. tostring(note) .. " (" .. count .. " models)")
				end)
			end
		elseif kind == "thread" then
			env.require("agent/session").switch(tostring(command.id or ""))
		elseif kind == "thread:new" then
			env.require("agent/session").newThread()
		elseif kind == "thread:delete" then
			env.require("agent/session").remove(tostring(command.id or ""))
		elseif kind == "thread:rename" then
			local target = env.require("agent/session").threads[tostring(command.id or "")]
			if target and target.rename then target.rename(tostring(command.title or "")) end
		elseif kind == "permission-mode" then
			env.require("agent/permissions").setMode(tostring(command.mode or "ask"))
		elseif kind == "subagent:stop" then
			env.require("agent/subagent").stop(tostring(command.id or ""))
		else
			log.warn("bridge", "unknown command from the browser", kind)
		end
	end

	-- Reported once per streak rather than per attempt: with the bridge not running,
	-- a per-attempt warning would be the only thing in the log.
	local function offline(reason)
		local moved = M.online or M.lastError == nil
		M.online = false
		M.lastError = reason
		if moved then
			log.warn("bridge", "not reachable", reason)
			M.changed:fire()
		end
	end

	local function onlineNow()
		if M.online then return end
		M.online = true
		M.lastError = nil
		log.info("bridge", "connected to the local bridge")
		M.changed:fire()
	end

	local alive = false

	-- The browser's panels are drawn from the same modules the in-game interface
	-- reads, so nothing in the web UI is a guess: providers and their real model
	-- lists, the tool registry, threads, subagents, usage and the host's
	-- capabilities all arrive as they are. Pushed at most once a second and only
	-- when the encoded form changed, so a still session costs nothing.
	local function stateOf()
		local sessions = env.require("agent/session")
		local providers = env.require("provider/registry")
		local models = env.require("provider/models")
		local registry = env.require("agent/registry")
		local subagents = env.require("agent/subagent")
		local usage = env.require("agent/usage")
		local permissions = env.require("agent/permissions")
		local place = env.require("runtime/place")

		pcall(function() registry.load() end)

		local threads = {}
		for _, session in ipairs(sessions.list()) do
			threads[#threads + 1] = {
				id = session.id,
				title = session.title,
				place = session.placeName,
				busy = session.busy == true,
				turns = session.turns or 0,
				updatedAt = session.updatedAt or 0,
				active = session.id == sessions.activeId,
			}
		end

		local providerList = {}
		for _, record in ipairs(providers.list()) do
			local health = record.health or {}
			providerList[#providerList + 1] = {
				id = record.id,
				label = record.label,
				model = record.model,
				models = models.list(record),
				enabled = record.enabled ~= false,
				health = {
					ok = health.ok or 0,
					fail = health.fail or 0,
					lastError = health.lastError or "",
				},
				cooling = providers.cooling(record),
			}
		end

		local tools = {}
		for _, tool in ipairs(registry.list()) do
			tools[#tools + 1] = {
				name = tool.name,
				group = tool.group,
				description = tool.description,
				risk = tool.risk or "write",
			}
		end

		local subs = {}
		for _, record in ipairs(subagents.list()) do
			subs[#subs + 1] = {
				id = record.id,
				label = record.label,
				task = record.task,
				preset = record.preset,
				status = record.status,
				ms = record.ms,
				messages = record.messages,
				report = record.report and util.ellipsis(record.report, 600) or nil,
			}
		end

		local activeRecord = providers.active()
		local current = sessions.current()

		return {
			place = { id = place.id, name = place.label() },
			caps = { executor = caps.executor, http = caps.http, summary = caps.summary() },
			agent = {
				status = current.status,
				busy = current.busy == true,
				provider = activeRecord and activeRecord.label or nil,
				model = activeRecord and activeRecord.model or nil,
			},
			usage = {
				prompt = usage.session.prompt,
				completion = usage.session.completion,
				total = usage.session.total,
				cost = usage.session.cost,
				requests = usage.session.requests,
				estimated = usage.session.estimated == true,
			},
			permissions = { mode = permissions.mode(), pending = permissions.pendingCount() },
			threads = threads,
			providers = providerList,
			activeProvider = activeRecord and activeRecord.id or nil,
			tools = tools,
			subagents = subs,
		}
	end

	local lastStateJson, lastStateAt = nil, 0
	local STATE_EVERY = 1

	local function drain()
		attach()
		local stateDue = nil
		if clock.since(lastStateAt) >= STATE_EVERY then
			lastStateAt = clock.ms()
			local ok, built = pcall(stateOf)
			if ok then
				local encoded = util.encode(built)
				if encoded ~= lastStateJson then
					lastStateJson = encoded
					stateDue = built
				end
			end
		end
		if #queue == 0 and snapshotPending == nil and stateDue == nil then return true end
		local batch = queue
		local snapshot = snapshotPending
		queue = {}
		snapshotPending = nil

		local res, err = call({
			url = base() .. "/api/agent/events",
			method = "POST",
			body = util.encode({ events = batch, snapshot = snapshot, state = stateDue }),
			timeout = 10,
		})
		if res and res.ok then return true end

		-- Put the batch back in front rather than dropping it: the queue may have
		-- grown while the request was in flight, and these are the older half. A
		-- message the browser never receives is worse than one that arrives late.
		snapshotPending = snapshot or snapshotPending
		for index = #batch, 1, -1 do table.insert(queue, 1, batch[index]) end
		while #queue > QUEUE_CAP do table.remove(queue, 1) end
		return false, err or ("status " .. tostring(res and res.status or 0))
	end

	local function uploadLoop()
		local attempt = 0
		while alive do
			local ok, reason = drain()
			if ok then
				attempt = 0
				clock.wait(DRAIN_SECONDS)
			else
				attempt = attempt + 1
				offline(reason)
				clock.wait(clock.backoff(attempt, { cap = 10 }))
			end
		end
	end

	local function pollLoop()
		local attempt = 0
		while alive do
			local res, err = call({
				url = base() .. "/api/agent/inbox",
				method = "GET",
				timeout = POLL_TIMEOUT,
			})
			-- The request parked for up to eighteen seconds; an unload during that
			-- window means the answer is no longer wanted.
			if not alive then return end

			if res and res.ok then
				attempt = 0
				onlineNow()
				local decoded = util.decode(res.body)
				local commands = type(decoded) == "table" and decoded.commands or nil
				local handled = 0
				if type(commands) == "table" then
					for _, command in ipairs(commands) do
						handled = handled + 1
						-- One bad command must not stop the poller: that would take the
						-- browser offline until the next reload.
						local ok, err2 = pcall(runCommand, command)
						if not ok then log.warn("bridge", "command failed", err2) end
					end
				end
				-- The bridge is expected to hold this request open until it has
				-- something to say. One that answers empty straight away -- an older
				-- build, or a proxy that will not park a connection -- would otherwise
				-- turn this loop into a flood of requests.
				if handled == 0 and (res.ms or 0) < 1000 then clock.wait(1) end
			else
				attempt = attempt + 1
				offline(err or ("status " .. tostring(res and res.status or 0)))
				clock.wait(clock.backoff(attempt, { cap = 10 }))
			end
		end
	end

	local unregister = nil

	local function shutdown()
		alive = false
		M.running = false
		M.online = false
		if detach then pcall(detach) end
		detach, attachedId = nil, nil
		queue = {}
		snapshotPending = nil
	end

	function M.start()
		if M.running then return true end
		if not caps.has("http") then return false, caps.reason("http") end
		if util.trim(tostring(config.get("bridge.token", ""))) == "" then
			return false, "no token yet -- run bridge/server.js and paste the token it prints"
		end

		M.running = true
		alive = true
		M.lastError = nil
		attach()
		clock.spawn(uploadLoop)
		clock.spawn(pollLoop)
		-- Two threads that outlive the interface, so unloading has to be able to
		-- stop them. The canceller is kept rather than discarded because stopping
		-- from Settings has to unregister as well, or the drain would run it twice.
		unregister = dispose.add(shutdown, "bridge")
		log.info("bridge", "polling " .. base())
		M.changed:fire()
		return true
	end

	function M.stop()
		if not M.running then return false end
		if unregister then
			unregister()
			unregister = nil
		else
			shutdown()
		end
		log.info("bridge", "stopped")
		M.changed:fire()
		return true
	end

	-- One place decides whether the bridge should be up, so boot and the Settings
	-- toggle cannot disagree about it.
	function M.sync()
		if config.get("bridge.enabled", false) == true then return M.start() end
		M.stop()
		return false
	end

	function M.status()
		return {
			running = M.running,
			online = M.online,
			url = base(),
			queued = #queue,
			error = M.lastError,
		}
	end

	-- Any route that changes the setting takes effect, whether that is the Settings
	-- panel, a console call or a host script, so the panel only has to write config
	-- rather than orchestrate this. A port or token change aims the connection
	-- somewhere new, so it is torn down and rebuilt rather than adjusted in place.
	dispose.add(config.changed:connect(function(path)
		if path ~= nil and not util.startsWith(tostring(path), "bridge.") then return end
		if M.running then M.stop() end
		if config.get("bridge.enabled", false) == true then M.start() end
	end), "bridge config")

	return M






end
