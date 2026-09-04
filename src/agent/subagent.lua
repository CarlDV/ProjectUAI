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

	function M.budgetSeconds()
		return math.max(tonumber(config.get("agent.subagentBudget", 240)) or 240, 15)
	end

	function M.toolTimeout()
		return M.budgetSeconds() + SLACK_SECONDS
	end

	-- The card in the transcript is titled with the task, so the first line of it is
	-- what the user reads to tell three concurrent subagents apart.
	local function labelFor(task)
		local first = tostring(task):match("^%s*([^\n]*)") or ""
		first = util.trim(first)
		if first == "" then first = "task" end
		return util.ellipsis(first, 64)
	end

	-- Blocks until the subagent finishes. The caller is already on a tool thread, so
	-- yielding here is correct; the tool timeout above it comes from M.toolTimeout so
	-- it outlasts the child rather than the other way round, and `turns` bounds the
	-- token spend.
	function M.dispatch(opts)
		local parent = opts.parent
		local depth = (parent and parent.depth or 0) + 1

		if not M.available(depth - 1) then
			return nil, "subagent depth limit reached (" .. tostring(config.get("agent.subagentDepth", 2)) .. ")"
		end

		local task_text = util.trim(opts.task)
		if task_text == "" then return nil, "a subagent needs a task" end

		local id = util.uid("agent")
		local label = labelFor(task_text)
		local groups = M.PRESETS[opts.preset or "read"]
		local child = session.create({
			title = "subagent",
			depth = depth,
			headless = true,
			maxTurns = opts.turns or config.get("agent.subagentTurns", 14),
			toolGroups = groups,
			budgetSeconds = opts.budgetSeconds or M.budgetSeconds(),
			stream = false,
		})

		-- Live view.
		--
		-- The transcript renders the parent's event stream and nothing else, so a
		-- subagent that wants to be watched has to speak through it. Every event carries
		-- the child's id, which keys the card, and the id of the tool call that started
		-- it, which tells the view what to nest the card under.
		--
		-- Tool RESULTS are summarised to one line rather than forwarded: absorbing that
		-- volume is the entire point of a subagent, and the parent's log is bounded. What
		-- does go across is names, outcomes and timings, because that is the difference
		-- between watching work happen and watching a spinner.
		local function announce(kind, payload)
			if not parent then return end
			payload = payload or {}
			payload.id = id
			payload.call = opts.callId
			payload.label = label
			parent.emit(kind, payload)
		end

		if parent then
			-- Stop has to reach the child. Without this, aborting the turn left every
			-- dispatched subagent running out its full budget against a conversation
			-- that had already moved on -- billed, invisible, and unstoppable.
			local parentAborted = parent.aborted
			child.aborted = function()
				return child.abortFlag == true or parentAborted() == true
			end

			local calls = 0
			child.events:connect(function(event)
				if event.kind == "tool:call" then
					calls = calls + 1
					announce("subagent:tool", {
						callId = event.id,
						name = event.name,
						risk = event.risk,
						arguments = util.ellipsis(tostring(event.arguments or ""):gsub("%s+", " "), 160),
						index = calls,
					})
				elseif event.kind == "tool:result" or event.kind == "tool:error" then
					announce("subagent:tool:done", {
						callId = event.id,
						name = event.name,
						ok = event.kind == "tool:result",
						ms = event.ms,
						summary = util.ellipsis(tostring(event.text or ""):gsub("%s+", " "), 140),
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
						announce("subagent:status", { text = tostring(event.text) })
					end
				elseif event.kind == "error" then
					announce("subagent:status", { text = tostring(event.message), bad = true })
				elseif event.kind == "permission:ask" then
					-- Nothing is subscribed to a headless session, so a prompt raised
					-- inside a subagent has to surface on the parent's stream or it
					-- would sit unanswered until its own deadline.
					parent.emit("permission:ask", event)
				end
			end)
		end

		local started = clock.ms()
		local loop = env.require("agent/loop")

		-- The brief replaces the main system prompt rather than appending to it.
		-- Carrying it on the session (instead of swapping the prompt module's
		-- builder) is what makes two subagents dispatched in the same batch safe.
		child.systemPrompt = prompt.subagent(task_text, { extra = opts.extra })

		announce("subagent:start", {
			task = util.ellipsis(task_text, 400),
			preset = opts.preset or "read",
			turns = child.maxTurns,
			budget = child.budgetSeconds,
			depth = depth,
		})

		local ok, reply = pcall(loop.run, child, task_text)

		local elapsed = clock.since(started)
		if not ok then
			log.warn("subagent", "failed", reply)
			local note = "the subagent failed: " .. util.ellipsis(tostring(reply), 200)
			announce("subagent:done", { ms = elapsed, ok = false, text = note })
			return nil, note
		end

		local stats = child.ctx.stats()
		local aborted = child.aborted() == true
		log.info("subagent", string.format("finished in %s over %d messages%s",
			util.formatDuration(elapsed), stats.messages, aborted and " (stopped)" or ""))

		announce("subagent:done", {
			ms = elapsed,
			ok = not aborted,
			aborted = aborted,
			messages = stats.messages,
			turns = stats.turns,
			text = util.ellipsis(tostring(reply), 600),
		})

		return {
			text = tostring(reply),
			ms = elapsed,
			messages = stats.messages,
			turns = stats.turns,
			aborted = aborted,
		}
	end

	return M
end
