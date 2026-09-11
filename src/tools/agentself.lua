-- Tools the agent uses on itself: the task list, durable memory, delegation and
-- deliberate waiting.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local config = env.require("runtime/config")
	local state = env.require("agent/state")
	local subagent = env.require("agent/subagent")
	local H = env.require("tools/helpers")

	-- How long ask_user waits for a person before giving up on them, in seconds.
	-- Ten minutes rather than the permission prompt's three: a question is asked at
	-- the start of a turn and the user may be mid-game, while a permission prompt
	-- arrives during work they are already watching.
	local ASK_TIMEOUT = 600

	return {
		{
			name = "todo_write",
			risk = "read",
			description = "Replace the task list with the full set of items and their statuses. Use for any job with more than about three steps; keep exactly one item active.",
			parameters = {
				type = "object",
				properties = {
					items = {
						type = "array",
						description = "The complete list, in order. Sending a partial list deletes the rest.",
						items = {
							type = "object",
							properties = {
								text = { type = "string", description = "What the step is, in the imperative." },
								status = { type = "string", enum = { "pending", "active", "done", "dropped" } },
							},
							required = { "text" },
						},
					},
				},
				required = { "items" },
			},
			run = function(args, ctx)
				-- Written to the conversation that asked, not to the client: two
				-- conversations open at once each keep their own plan.
				local session = ctx and ctx.session or nil
				local items = state.setTodos(args.items, session)
				if #items == 0 then return "Task list cleared." end
				local counts = state.todoCounts(session)
				return string.format("Task list set: %d items (%d done, %d active, %d pending).\n%s",
					counts.total, counts.done, counts.active, counts.pending, state.todoBlock(session))
			end,
		},
		{
			name = "todo_read",
			risk = "read",
			description = "Read the current task list.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function(_, ctx)
				local block = state.todoBlock(ctx and ctx.session or nil)
				if not block then return "The task list is empty." end
				return block
			end,
		},
		{
			-- The model's side of a question it cannot answer from the world. A
			-- permission prompt asks "may I" and the permission layer owns it; this
			-- asks "which" or "what" and the answer is a fact, not a decision about
			-- the agent's own conduct -- so it is a tool result like any other and
			-- rides the same turn, rather than a modal the loop knows about.
			--
			-- Headless is refused in words rather than by omission: a subagent that
			-- asks a question has misunderstood its brief -- nothing it writes reaches
			-- the user directly -- and the message it gets back says so, which teaches
			-- the next dispatch rather than costing it a turn to rediscover.
			name = "ask_user",
			risk = "read",
			-- Not the generic tool timeout. A person is being waited on and people are
			-- slower than any tool; the generic wall would report them as lost. This is
			-- the wall the wait loop below honours, stated once here so the two cannot
			-- drift apart -- the loop gives up a fraction before the registry kills the
			-- call, so the model hears "nobody answered" rather than "did not finish".
			timeout = ASK_TIMEOUT + 5,
			description = "Ask the user one question and wait for their answer. Use when a request is genuinely ambiguous -- two ways to read it, a choice of targets, a preference you cannot infer -- and answering it wrong would waste work. Offer concrete options when the plausible answers are few; omit them for an open question. The answer comes back as this call's result. You cannot ask from a subagent.",
			parameters = {
				type = "object",
				properties = {
					question = {
						type = "string",
						description = "The question itself, one or two sentences, in the words you would use to the user.",
					},
					options = {
						type = "array",
						description = "The concrete answers to pick from, 2 to 4. Omit entirely for an open question.",
						items = { type = "string" },
					},
				},
				required = { "question" },
			},
			run = function(args, ctx)
				local session = ctx and ctx.session or nil
				if session and session.headless then
					return H.fail("a subagent has no user to ask. Answer with your best reading of the task, or state what you could not determine.")
				end
				local question = util.trim(tostring(args.question or ""))
				if question == "" then return H.fail("a question is required") end
				local options = {}
				for index, value in ipairs(type(args.options) == "table" and args.options or {}) do
					local clean = util.trim(tostring(value))
					if clean ~= "" then options[#options + 1] = clean end
					if #options >= 4 then break end
				end
				if #options == 1 then options = {} end

				-- The loop blocks on this thread for as long as the user takes, so the
				-- answer has to come back through a channel the interface can reach: an
				-- event carrying a resolve closure, exactly the shape the permission
				-- prompt already uses. Nothing here trusts a listener to exist -- with
				-- none, the wall is the timeout and the model is told nobody answered.
				local answered, reply = false, nil
				local function resolve(text)
					if answered then return end
					answered = true
					reply = text
				end

				if ctx and ctx.emit then
					ctx.emit("ask:user", {
						question = question,
						options = options,
						resolve = resolve,
					})
				end

				local waited = 0
				while not answered and waited < (ASK_TIMEOUT) do
					if ctx and ctx.aborted and ctx.aborted() then
						resolve("The turn was stopped before you answered.")
						return "The user stopped the turn. Ask again in a new message if the question still matters."
					end
					waited = waited + (clock.wait(0.1) or 0.1)
				end

				if not answered then
					return "Nobody answered within ten minutes. Continue with your best reading of the request, and say you had to assume an answer."
				end
				local text = util.trim(tostring(reply or ""))
				if text == "" then
					return "The user dismissed the question without answering. Continue with your best reading, and say you had to assume an answer."
				end
				return "The user answered: " .. text
			end,
		},
		{
			name = "memory_write",
			risk = "read",
			description = "Save a durable fact about this user or project under a short key. Survives context compaction and restarts. Use for preferences, paths and goals, not for transcript chatter.",
			parameters = {
				type = "object",
				properties = {
					key = { type = "string", description = "Short snake_case key, e.g. 'preferred_shape' or 'main_build_path'." },
					value = { type = "string", description = "The fact, in one or two sentences." },
				},
				required = { "key", "value" },
			},
			run = function(args)
				local ok, note = state.remember(args.key, args.value)
				if not ok then return H.fail(note) end
				return "Remembered: " .. tostring(note)
			end,
		},
		{
			name = "memory_read",
			risk = "read",
			description = "List everything currently remembered, or read one key.",
			parameters = {
				type = "object",
				properties = {
					key = { type = "string", description = "Omit to list every memory." },
				},
				required = {},
			},
			run = function(args)
				if args.key and util.trim(args.key) ~= "" then
					local value = state.recall(args.key)
					if not value then return "Nothing is stored under '" .. tostring(args.key) .. "'." end
					return tostring(args.key) .. ": " .. value
				end
				local list = state.memoryList()
				if #list == 0 then return "Nothing is remembered yet." end
				return H.list(list, 60, function(entry) return entry.key .. ": " .. entry.value end)
			end,
		},
		{
			name = "memory_forget",
			risk = "read",
			description = "Delete one remembered key.",
			parameters = {
				type = "object",
				properties = { key = { type = "string" } },
				required = { "key" },
			},
			run = function(args)
				if state.forget(args.key) then return "Forgot '" .. tostring(args.key) .. "'." end
				return "Nothing was stored under '" .. tostring(args.key) .. "'."
			end,
		},
		{
			name = "dispatch_agent",
			risk = "write",
			description = "Hand a self-contained investigation to a subagent with its own context, and get back a written report. Use for wide searches, repetitive inspection, or anything that would otherwise fill this conversation with tool output. Call it several times in one step to run that many subagents at once: they work in parallel and you wait once, not once each. A subagent cannot ask questions, so state the task completely. The call blocks until its report is ready. The report carries an id you can send follow-ups to with agent_followup, so ask for the first slice of a big job rather than describing all of it.",
			-- Not the generic tool timeout. A subagent runs for minutes by design, and a
			-- caller that gives up first throws away work the user has paid for: the
			-- child cannot be killed, so it finishes into a void.
			timeout = function() return subagent.toolTimeout() end,
			parameters = {
				type = "object",
				properties = {
					task = {
						type = "string",
						description = "The complete task, including what counts as a finished answer.",
					},
					preset = {
						type = "string",
						enum = { "read", "web", "game", "full" },
						description = "Which tools it gets. 'read' cannot change anything; 'full' can. Unset uses the configured default, which is 'full'.",
					},
					turns = { type = "integer", description = "Step limit, 1-30. Default 14.", minimum = 1, maximum = 30 },
				},
				required = { "task" },
			},
			run = function(args, ctx)
				local result, err = subagent.dispatch({
					parent = ctx and ctx.session or nil,
					-- Which call this is, so the transcript can nest the subagent's live
					-- feed under the row the user is already looking at.
					callId = ctx and ctx.callId or nil,
					task = args.task,
					-- The default preset is a setting, so it can be widened or narrowed once
					-- for every dispatch rather than only when the model names one. Permission
					-- mode still gates what actually runs, and a prompt raised inside a child
					-- is forwarded to the parent's stream.
					preset = args.preset or config.get("agent.subagentPreset", "full"),
					turns = args.turns,
				})
				if not result then return H.fail(err) end
				-- The id, in both branches. Without it the report is a dead end: a child
				-- that stopped at its step limit says so in its own words and the parent
				-- had no way to say "carry on" -- the only move left was to describe the
				-- whole job again to a fresh subagent that knew none of it.
				if result.aborted then
					return string.format("Subagent %s stopped early (%s, %d messages). What it had:\n\n%s",
						result.id, util.formatDuration(result.ms), result.messages, result.text)
				end
				return string.format(
					"Subagent report from %s (%s, %d messages).%s\n\n%s",
					result.id, util.formatDuration(result.ms), result.messages,
					result.resumable and string.format(
						" It kept its context: send it more with agent_followup, agent \"%s\".", result.id) or "",
					result.text)
			end,
		},
		{
			name = "agent_followup",
			risk = "write",
			description = "Send another message to a subagent that has already reported, keeping everything it found. Use this instead of dispatching a fresh one whenever you want more from the same investigation: 'you stopped at the step limit, carry on', 'now check X as well', 'quote that line verbatim'. It is far cheaper than a new dispatch, which would have to rediscover what this one already knows. Takes the id from the report. Blocks until it answers again.",
			timeout = function() return subagent.toolTimeout() end,
			parameters = {
				type = "object",
				properties = {
					agent = {
						type = "string",
						description = "The subagent's id, as printed in its report.",
					},
					message = {
						type = "string",
						description = "What you want from it now. It still cannot ask questions, so be complete.",
					},
					turns = {
						type = "integer",
						description = "Step limit for this follow-up, 1-30. Defaults to the configured one.",
						minimum = 1,
						maximum = 30,
					},
				},
				required = { "agent", "message" },
			},
			run = function(args, ctx)
				local result, err = subagent.followUp({
					parent = ctx and ctx.session or nil,
					callId = ctx and ctx.callId or nil,
					id = args.agent,
					task = args.message,
					turns = args.turns,
				})
				if not result then return H.fail(err) end
				if result.aborted then
					return string.format("Subagent %s stopped early (%s). What it had:\n\n%s",
						result.id, util.formatDuration(result.ms), result.text)
				end
				return string.format("Subagent %s answered (%s, %d messages).%s\n\n%s",
					result.id, util.formatDuration(result.ms), result.messages,
					result.resumable and " Still open for another follow-up." or "",
					result.text)
			end,
		},
		{
			name = "wait",
			risk = "read",
			description = "Pause for a few seconds before continuing, to let something in the game settle or a change take effect.",
			parameters = {
				type = "object",
				properties = {
					seconds = { type = "number", description = "0.1 to 10.", minimum = 0.1, maximum = 10 },
				},
				required = { "seconds" },
			},
			run = function(args, ctx)
				local seconds = util.clamp(tonumber(args.seconds) or 1, 0.1, 10)
				local waited = 0
				while waited < seconds do
					if ctx and ctx.aborted and ctx.aborted() then
						return string.format("Waited %.1fs, then stopped.", waited)
					end
					waited = waited + (clock.wait(math.min(0.25, seconds - waited)) or 0.25)
				end
				return string.format("Waited %.1f seconds.", seconds)
			end,
		},
	}
end
