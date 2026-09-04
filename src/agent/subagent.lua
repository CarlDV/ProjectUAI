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

	-- Blocks until the subagent finishes. The caller is already on a tool thread,
	-- so yielding here is correct; the tool timeout above it is what bounds the
	-- total wait, and `turns` bounds the token spend.
	function M.dispatch(opts)
		local parent = opts.parent
		local depth = (parent and parent.depth or 0) + 1

		if not M.available(depth - 1) then
			return nil, "subagent depth limit reached (" .. tostring(config.get("agent.subagentDepth", 2)) .. ")"
		end

		local task_text = util.trim(opts.task)
		if task_text == "" then return nil, "a subagent needs a task" end

		local groups = M.PRESETS[opts.preset or "read"]
		local child = session.create({
			title = "subagent",
			depth = depth,
			headless = true,
			maxTurns = opts.turns or config.get("agent.subagentTurns", 14),
			toolGroups = groups,
			budgetSeconds = opts.budgetSeconds or 240,
			stream = false,
		})

		-- Progress is forwarded to the parent so the user sees the subagent working
		-- rather than a frozen tool call, but its tool results are not: that volume
		-- is exactly what the subagent exists to absorb.
		if parent then
			child.events:connect(function(event)
				if event.kind == "tool:call" then
					parent.emit("tool:progress", {
						text = string.format("subagent: %s", tostring(event.name)),
					})
				elseif event.kind == "status" then
					parent.emit("tool:progress", { text = "subagent: " .. tostring(event.text):lower() })
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

		local ok, reply = pcall(loop.run, child, task_text)

		local elapsed = clock.since(started)
		if not ok then
			log.warn("subagent", "failed", reply)
			return nil, "the subagent failed: " .. util.ellipsis(tostring(reply), 200)
		end

		local stats = child.ctx.stats()
		log.info("subagent", string.format("finished in %s over %d messages",
			util.formatDuration(elapsed), stats.messages))

		return {
			text = tostring(reply),
			ms = elapsed,
			messages = stats.messages,
			turns = stats.turns,
		}
	end

	return M
end
