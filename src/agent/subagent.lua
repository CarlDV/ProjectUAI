-- Subagent dispatch.
--
-- A subagent is a full session with a smaller tool set, its own context and no
-- interface. It exists to keep long or repetitive work out of the main
-- conversation: the parent pays for one paragraph of report instead of forty tool
-- results, and a search that goes nowhere costs the main context nothing.
--
-- Depth is capped because a subagent that can spawn subagents indefinitely is a
-- fork bomb with a token bill.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")
	local prompt = env.require("agent/prompt")
	local session = env.require("agent/session")

	local M = {}

	-- Groups a subagent may be given. Anything that changes the world is absent
	-- from the read-only preset, which is the default: the point of a subagent is
	-- usually to go and find out, and a delegated write is hard for the user to
	-- attribute afterwards.
	M.PRESETS = {
		read = { instance = true, world = true, players = true, perf = true, meta = true, web = true, net = true, fs = true },
		web = { web = true, net = true },
		game = { instance = true, world = true, players = true, gui = true, remotes = true, meta = true },
		full = nil,
	}

	-- The register.
	--
	-- `live` was a bare counter, which is enough to enforce a ceiling and nothing else:
	-- there was no way to ask what is running, what it was asked to do, or to stop one
	-- of them without stopping the whole turn. A dispatch is the longest-lived and least
	-- visible thing this client does -- minutes of work, its own context, its own tool
	-- calls, and a transcript card that scrolls away -- so each one gets a record here
	-- that outlives its card, and the interface reads this rather than the log.
	--
	-- Bounded, because a long session dispatches a lot: running records are never
	-- dropped, finished ones are kept newest-first up to the history limit.
	--
	-- Of those, only the newest few keep the session they ran on. A child's context is
	-- the expensive half of it -- every tool result it collected -- and holding two dozen
	-- of them for the life of the client would make delegation the largest thing in
	-- memory. So a record outlives its session: the newest are resumable, the rest keep
	-- their report and lose the context behind it.
	local HISTORY = 24
	local RESUMABLE = 6

	M.records = {}
	M.changed = signal.new("subagents")

	local function announceChange()
		M.changed:fire(M.records)
	end

	local function isLive(record)
		return record.status == "running" or record.status == "queued"
	end

	-- Newest first, which is the order the register is held in, so the count runs from
	-- the most recent finished dispatch outward. It used to run from the oldest, which
	-- inverted both rules: the twenty-four kept were the oldest twenty-four, and the
	-- dispatch that had just reported back was the first one dropped.
	local function trimHistory()
		local finished = 0
		local kept = {}
		for _, record in ipairs(M.records) do
			if isLive(record) then
				kept[#kept + 1] = record
			else
				finished = finished + 1
				if finished <= HISTORY then
					if finished > RESUMABLE then
						-- Nothing can address this one any more, so neither reference earns its
						-- keep: the child's context, and the conversation that was waiting on
						-- it. `parentTitle` is a string and stays, because the card still says
						-- where the dispatch came from.
						record.session = nil
						record.parent = nil
					end
					kept[#kept + 1] = record
				end
			end
		end
		M.records = kept
	end

	local function track(record)
		record.startedAt = clock.ms()
		record.status = "queued"
		record.calls = 0
		record.finishedCalls = 0
		record.tools = {}
		table.insert(M.records, 1, record)
		trimHistory()
		announceChange()
		return record
	end

	-- Newest first, running before finished: what a panel wants to draw in order.
	function M.list()
		local running, done = {}, {}
		for _, record in ipairs(M.records) do
			if isLive(record) then
				running[#running + 1] = record
			else
				done[#done + 1] = record
			end
		end
		local out = {}
		for _, record in ipairs(running) do out[#out + 1] = record end
		for _, record in ipairs(done) do out[#out + 1] = record end
		return out
	end

	function M.running()
		local out = {}
		for _, record in ipairs(M.records) do
			if isLive(record) then out[#out + 1] = record end
		end
		return out
	end

	-- The finished dispatches that still have their context, newest first: the ones a
	-- follow-up can be sent to.
	function M.resumable()
		local out = {}
		for _, record in ipairs(M.records) do
			if record.session and not isLive(record) then out[#out + 1] = record end
		end
		return out
	end

	function M.get(id)
		for _, record in ipairs(M.records) do
			if record.id == id then return record end
		end
		return nil
	end

	-- Finds the dispatch the model named.
	--
	-- The id is what the report hands back, so that is the exact match. A label prefix
	-- is accepted too: a model that has lost the id reaches for the task's first line
	-- instead, and refusing that spends a step teaching it nothing.
	function M.find(reference)
		local needle = util.trim(tostring(reference or ""))
		if needle == "" then return nil end
		local exact = M.get(needle)
		if exact then return exact end
		local lowered = needle:lower()
		for _, record in ipairs(M.records) do
			if tostring(record.label):lower():find(lowered, 1, true) then return record end
		end
		return nil
	end

	-- Stops one dispatch without stopping the turn that asked for it.
	--
	-- The child notices between steps, so this returns before it has actually stopped;
	-- the record says so until its loop unwinds. There is no way to kill a Luau thread,
	-- which is why the flag is the mechanism everywhere in this client.
	function M.stop(id)
		local record = M.get(id)
		if not record or not record.session then return false end
		if not isLive(record) then return false end
		record.session.abortFlag = true
		record.stopping = true
		announceChange()
		log.info("subagent", "stop requested for " .. tostring(record.label))
		return true
	end

	function M.stopAll()
		local stopped = 0
		for _, record in ipairs(M.running()) do
			if M.stop(record.id) then stopped = stopped + 1 end
		end
		return stopped
	end

	-- Clears the finished ones. Running dispatches are left alone.
	function M.clearHistory()
		local kept = {}
		for _, record in ipairs(M.records) do
			if isLive(record) then kept[#kept + 1] = record end
		end
		M.records = kept
		announceChange()
		return true
	end

	function M.available(depth)
		local limit = config.get("agent.subagentDepth", 2)
		return (depth or 0) < limit
	end

	-- How long a subagent may run, and how long the tool that started it waits.
	--
	-- Both come from one number on purpose. They used to be independent: the child was
	-- given four minutes and the call that started it was bounded by the generic
	-- `agent.toolTimeout` of twenty-five seconds, so nearly every dispatch was reported
	-- to the model as "did not finish within 25s and was left running in the
	-- background" -- and it was, against a caller that had stopped listening. The
	-- report arrived a minute later with nowhere to go, and the model, asked what its
	-- subagents found, could only say it never heard back.
	--
	-- The slack covers one request. A child notices its own deadline between steps, so
	-- it returns a moment after the budget expires rather than exactly on it, and the
	-- tool has to still be there to take the answer.
	local SLACK_SECONDS = 60

	-- Whether a child runs with its clocks off. Read per run rather than captured, so
	-- flipping the switch applies to the next dispatch and to the next follow-up on a
	-- child that has already reported.
	function M.unlimited()
		return config.get("agent.subagentUnlimited", false) == true
	end

	function M.budgetSeconds()
		return math.max(tonumber(config.get("agent.subagentBudget", 240)) or 240, 15)
	end

	-- A day, and it is not a deadline in disguise: with the ceiling lifted there is no
	-- budget to derive a timeout from, and the honest bound on the call above is "as
	-- long as the child takes". A caller that gives up first is the failure this number
	-- exists to avoid -- the child cannot be killed, so it finishes into a void and the
	-- user pays for a report nobody collects.
	local FOREVER_SECONDS = 86400

	function M.toolTimeout()
		if M.unlimited() then return FOREVER_SECONDS end
		return M.budgetSeconds() + SLACK_SECONDS
	end

	-- Width, not just depth.
	--
	-- Several dispatch_agent calls in one step run at the same time, which is the
	-- point: three searches in parallel cost one step instead of three. What that
	-- leaves unbounded is the tree. `agent.toolConcurrency` caps one batch, so it caps
	-- a parallel dispatch from the main conversation -- but a subagent given the
	-- `full` preset dispatches its own batch under its own cap, and two levels of
	-- that multiply rather than add. This is the ceiling on live children anywhere,
	-- and the depth cap above is no substitute for it.
	M.live = 0

	function M.concurrencyLimit()
		return math.max(tonumber(config.get("agent.subagentConcurrency", 8)) or 8, 1)
	end

	-- A dispatch over the ceiling waits for a slot instead of failing: the model has
	-- already paid for the step that asked, and a refusal would spend another one
	-- learning that it asked for too much at once.
	--
	-- The wait is bounded and comes out of the child's own budget, which is what keeps
	-- `toolTimeout` a valid bound on the call above it. Without that subtraction a
	-- queued child could finish after the tool that started it had given up, and a
	-- report nobody is left to collect is exactly the failure the budget and the
	-- timeout were tied together to prevent.
	--
	-- Returns the budget to run on, `nil` when there is no budget to run against, or
	-- `false` when the turn was stopped while queued. An unlimited child has nothing to
	-- subtract from, so its wait is capped by the ceiling alone.
	local QUEUE_CEILING = 45

	local function waitForSlot(budget, aborted)
		local ceiling = budget and math.min(QUEUE_CEILING, budget / 4) or QUEUE_CEILING
		local waited = 0
		while M.live >= M.concurrencyLimit() and waited < ceiling do
			if aborted and aborted() then return false end
			waited = waited + (clock.wait(0.2) or 0.2)
		end
		if waited <= 0 then return budget end
		log.info("subagent", string.format("queued %.1fs for a slot (%d live)", waited, M.live))
		if not budget then return nil end
		return math.max(budget - waited, 15)
	end

	-- The card in the transcript is titled with the task, so the first line of it is
	-- what the user reads to tell three concurrent subagents apart.
	local function labelFor(task)
		local first = tostring(task):match("^%s*([^\n]*)") or ""
		first = util.trim(first)
		if first == "" then first = "task" end
		return util.ellipsis(first, 64)
	end

	-- Live view.
	--
	-- The transcript renders the parent's event stream and nothing else, so a subagent
	-- that wants to be watched has to speak through it. Every event carries the child's
	-- id, which keys the card, and the id of the tool call that started it, which tells
	-- the view what to nest the card under.
	--
	-- One subscription per child, made with it and kept for the rest of its life: a
	-- follow-up runs the same session again, and a second subscription would draw every
	-- row twice. Which conversation to narrate into is read off the record rather than
	-- captured here, for the same reason -- the turn asking a follow-up is a different
	-- tool call, sometimes in a different conversation, and the card has to appear under
	-- the row the user is looking at now.
	--
	-- Tool RESULTS are summarised to one line rather than forwarded: absorbing that
	-- volume is the entire point of a subagent, and the parent's log is bounded. What
	-- does go across is names, outcomes and timings, because that is the difference
	-- between watching work happen and watching a spinner.
	local function wire(record, child)
		local function announce(kind, payload)
			local parent = record.parent
			if not parent then return end
			payload = payload or {}
			payload.id = record.id
			payload.call = record.callId
			payload.label = record.label
			parent.emit(kind, payload)
		end
		record.announce = announce

		-- Stop has to reach the child, from whichever conversation is waiting on it.
		-- Without this, aborting the turn left every dispatched subagent running out its
		-- full budget against a conversation that had already moved on -- billed,
		-- invisible and unstoppable.
		child.aborted = function()
			if child.abortFlag == true then return true end
			local parent = record.parent
			return parent ~= nil and parent.aborted() == true
		end

		child.events:connect(function(event)
			if event.kind == "tool:call" then
				record.calls = (record.calls or 0) + 1
				record.currentTool = tostring(event.name)
				-- Names only, and the last twelve of them: the register is read by a
				-- panel that lists every dispatch in the session, so it cannot hold
				-- their arguments as well.
				record.tools[#record.tools + 1] = tostring(event.name)
				if #record.tools > 12 then table.remove(record.tools, 1) end
				announceChange()
				announce("subagent:tool", {
					callId = event.id,
					name = event.name,
					risk = event.risk,
					-- Forwarded whole, and summarised by the view instead.
					--
					-- A child session is headless and therefore keeps no log of its own, so
					-- this event is the only record that the call ever happened. At 160
					-- characters, whitespace-collapsed, the Luau a subagent executed was
					-- unrecoverable -- and a subagent is exactly where the long-running code
					-- in this client gets run. The parent's log is bounded at 400 events,
					-- which is what caps the cost of keeping it.
					arguments = tostring(event.arguments or ""),
					index = record.calls,
				})
			elseif event.kind == "tool:result" or event.kind == "tool:error" then
				record.finishedCalls = (record.finishedCalls or 0) + 1
				announceChange()
				announce("subagent:tool:done", {
					callId = event.id,
					name = event.name,
					ok = event.kind == "tool:result",
					ms = event.ms,
					summary = util.ellipsis(tostring(event.text or ""):gsub("%s+", " "), 140),
					-- The full result as well, for the row that can open. `summary` is what
					-- the collapsed line shows and stays short.
					text = tostring(event.text or ""),
				})
			elseif event.kind == "assistant:text" then
				if util.trim(tostring(event.text or "")) ~= "" then
					announce("subagent:text", { text = util.ellipsis(util.trim(event.text), 400) })
				end
			elseif event.kind == "status" then
				-- "Ready" is the child's own idle text and means nothing on a card that
				-- reports its finish separately. Dropping it here rather than in the
				-- view keeps one entry per turn out of the parent's bounded log.
				if tostring(event.text) ~= "Ready" then
					record.statusText = tostring(event.text)
					announceChange()
					announce("subagent:status", { text = tostring(event.text) })
				end
			elseif event.kind == "error" then
				record.statusText = tostring(event.message)
				announceChange()
				announce("subagent:status", { text = tostring(event.message), bad = true })
			elseif event.kind == "permission:ask" then
				-- Nothing is subscribed to a headless session, so a prompt raised
				-- inside a subagent has to surface on the parent's stream or it
				-- would sit unanswered until its own deadline.
				local parent = record.parent
				if parent then parent.emit("permission:ask", event) end
			end
		end)
	end

	-- One run of a child: the slot, the announcement, the loop and the report. Shared
	-- by the first dispatch and by every follow-up, so a resumed subagent is watched,
	-- counted and bounded exactly like a fresh one.
	--
	-- Everything a run needs is read here rather than fixed when the child was created,
	-- because a second turn is a different turn: a different caller, and possibly a
	-- different answer from the unlimited switch.
	local function runChild(record, text, opts)
		opts = opts or {}
		local child = record.session
		local unlimited = M.unlimited()
		local announce = record.announce

		local budget = waitForSlot(unlimited and nil or (opts.budgetSeconds or M.budgetSeconds()),
			record.parent and record.parent.aborted or nil)
		if budget == false then
			record.status = "stopped"
			record.ms = clock.since(record.startedAt)
			record.report = "Stopped before it started."
			announceChange()
			return nil, "the turn was stopped before this subagent started"
		end

		child.abortFlag = false
		child.unlimited = unlimited
		child.budgetSeconds = budget
		if opts.turns then child.maxTurns = opts.turns end
		record.status = "running"
		record.stopping = nil
		record.startedAt = clock.ms()
		record.budget = budget
		record.unlimited = unlimited
		record.turns = child.maxTurns
		record.runs = (record.runs or 0) + 1
		announceChange()

		announce("subagent:start", {
			task = util.ellipsis(text, 400),
			preset = record.preset,
			turns = unlimited and 0 or child.maxTurns,
			budget = budget,
			unlimited = unlimited,
			depth = record.depth,
			followUp = record.runs > 1,
		})

		-- Counted around the pcall rather than around the whole setup, so a raise
		-- anywhere inside cannot leak a slot and permanently narrow the ceiling.
		local started = clock.ms()
		M.live = M.live + 1
		local ok, reply = pcall(env.require("agent/loop").run, child, text)
		M.live = math.max(M.live - 1, 0)

		local elapsed = clock.since(started)
		if not ok then
			log.warn("subagent", "failed", reply)
			local note = "the subagent failed: " .. util.ellipsis(tostring(reply), 200)
			record.status = "failed"
			record.ms = elapsed
			record.report = note
			record.currentTool = nil
			announceChange()
			announce("subagent:done", { ms = elapsed, ok = false, text = note })
			return nil, note
		end

		local stats = child.ctx.stats()
		local aborted = child.aborted() == true
		log.info("subagent", string.format("finished in %s over %d messages%s",
			util.formatDuration(elapsed), stats.messages, aborted and " (stopped)" or ""))

		record.status = aborted and "stopped" or "done"
		record.ms = elapsed
		record.messages = stats.messages
		record.turnsUsed = stats.turns
		record.report = tostring(reply)
		record.currentTool = nil
		record.stopping = nil
		-- Now that this one has finished, it is the newest resumable record -- which is
		-- what pushes the oldest past the line and releases the context behind it.
		trimHistory()
		announceChange()

		announce("subagent:done", {
			ms = elapsed,
			ok = not aborted,
			aborted = aborted,
			messages = stats.messages,
			turns = stats.turns,
			resumable = record.session ~= nil and not aborted,
			text = util.ellipsis(tostring(reply), 600),
		})

		return {
			id = record.id,
			text = tostring(reply),
			ms = elapsed,
			messages = stats.messages,
			turns = stats.turns,
			aborted = aborted,
			resumable = record.session ~= nil,
		}
	end

	-- Blocks until the subagent finishes. The caller is already on a tool thread, so
	-- yielding here is correct; the tool timeout above it comes from M.toolTimeout so it
	-- outlasts the child rather than the other way round.
	function M.dispatch(opts)
		local parent = opts.parent
		local depth = (parent and parent.depth or 0) + 1

		if not M.available(depth - 1) then
			return nil, "subagent depth limit reached (" .. tostring(config.get("agent.subagentDepth", 2)) .. ")"
		end

		local task_text = util.trim(opts.task)
		if task_text == "" then return nil, "a subagent needs a task" end

		local turns = opts.turns or config.get("agent.subagentTurns", 14)

		-- Registered before the queue wait, so a dispatch parked waiting for a slot is
		-- visible as one rather than looking like nothing happened.
		local record = track({
			id = util.uid("agent"),
			label = labelFor(task_text),
			task = task_text,
			preset = opts.preset or "read",
			depth = depth,
			-- The conversation currently waiting on this child, and the tool call inside
			-- it. Both move when a follow-up arrives from somewhere else, which is why
			-- they live on the record rather than in a closure.
			parent = parent,
			callId = opts.callId,
			parentId = parent and parent.id or nil,
			parentTitle = parent and parent.title or nil,
			turns = turns,
		})

		local child = session.create({
			title = "subagent",
			depth = depth,
			headless = true,
			maxTurns = turns,
			toolGroups = M.PRESETS[opts.preset or "read"],
			-- Streaming is left to the provider and the Ask-for-streams setting, the
			-- same as the main conversation. It used to be refused here, on the reading
			-- that a child with no interface has nothing to stream into -- but no Roblox
			-- transport delivers a body incrementally anyway, so that bought nothing and
			-- cost the two things the streamed shape carries: reasoning text, and the
			-- per-request usage block some gateways report token counts in at all. Every
			-- subagent request landing without one was enough to mark the whole session's
			-- cost readout estimated.
		})
		-- The record is what the Subagents panel reads, so it is kept whether or not
		-- there is a parent transcript to narrate into. The wiring below is therefore
		-- unconditional; only the forwarding inside it is not.
		record.session = child

		-- The brief replaces the main system prompt rather than appending to it, and it
		-- is a function so that every turn -- including a follow-up months of tool calls
		-- later -- is built against the environment and the switches in force then.
		-- Carrying it on the session, instead of swapping the prompt module's builder, is
		-- what makes two subagents dispatched in the same batch safe.
		child.systemPrompt = function()
			return prompt.subagent(task_text, {
				extra = opts.extra,
				unlimited = M.unlimited(),
			})
		end

		wire(record, child)
		return runChild(record, task_text, {
			turns = opts.turns,
			budgetSeconds = opts.budgetSeconds,
		})
	end

	-- A second turn on a subagent that has already reported back.
	--
	-- A dispatch used to be one shot: the child answered, its context went on the floor,
	-- and a parent that wanted one more fact had to describe the whole job again to a
	-- fresh subagent that would go and rediscover it. This continues the same
	-- conversation instead -- the child still has everything it found -- which is what
	-- makes a subagent that stopped at a limit worth talking to rather than worth
	-- replacing, and what lets the parent steer one instead of only reading it.
	function M.followUp(opts)
		local record = M.find(opts.id)
		if not record then
			local open = M.resumable()
			if #open == 0 then
				return nil, "no subagent is open for a follow-up. Dispatch one with dispatch_agent first."
			end
			local names = {}
			for _, candidate in ipairs(open) do
				names[#names + 1] = string.format("%s (%s)", candidate.id, candidate.label)
			end
			return nil, string.format("no subagent matches '%s'. Open for a follow-up: %s",
				tostring(opts.id), table.concat(names, "; "))
		end
		if isLive(record) then
			return nil, "that subagent is still working. Its report will arrive on the call that started it."
		end
		if not record.session then
			return nil, "that subagent's context has already been released, so there is nothing to continue. Dispatch a new one with what you know."
		end

		local text = util.trim(opts.task)
		if text == "" then return nil, "a follow-up needs a message" end

		record.parent = opts.parent or record.parent
		record.callId = opts.callId
		return runChild(record, text, { turns = opts.turns })
	end

	return M
end
