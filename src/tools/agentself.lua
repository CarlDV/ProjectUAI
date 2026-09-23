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

	-- A previous conversation rendered for review by the agent. Built from the
	-- durable transcript (the full persisted history), falling back to the model
	-- context for a thread that predates stored logs. Condensed by default: long
	-- turns are shortened and tool runs collapsed, so a whole conversation fits in
	-- one bounded read; full=true returns every turn verbatim for byte-sliced paging.
	local REVIEW_USER_CAP, REVIEW_REPLY_CAP = 500, 900
	local function turnText(text, full, limit)
		text = util.trim(tostring(text or ""))
		if full or #text <= limit then return text end
		return util.ellipsis(text, limit)
	end
	local function readableTranscript(session, full)
		local parts = {}
		if session.ctx.summary and util.trim(session.ctx.summary) ~= "" then
			parts[#parts + 1] = "[earlier turns, summarised: " .. util.trim(session.ctx.summary) .. "]"
		end
		local tools = {}
		local function flush()
			if #tools > 0 then parts[#parts + 1] = "[ran " .. table.concat(tools, ", ") .. "]"; tools = {} end
		end
		for _, event in ipairs(session.log or {}) do
			local kind = event.kind
			if kind == "user" then
				flush(); parts[#parts + 1] = "User: " .. turnText(event.text, full, REVIEW_USER_CAP)
			elseif kind == "assistant:text" then
				flush()
				local text = turnText(event.text, full, REVIEW_REPLY_CAP)
				if text ~= "" then parts[#parts + 1] = "Assistant: " .. text end
			elseif kind == "tool:call" then
				tools[#tools + 1] = tostring(event.name or "tool")
			elseif kind == "compact" then
				flush(); parts[#parts + 1] = "[conversation compacted here]"
			elseif kind == "error" then
				flush(); parts[#parts + 1] = "[error: " .. util.ellipsis(tostring(event.message or ""), 160) .. "]"
			end
		end
		flush()
		if #parts == 0 then
			for _, message in ipairs(session.ctx.messages or {}) do
				if message.role == "user" then
					parts[#parts + 1] = "User: " .. turnText(message.content, full, REVIEW_USER_CAP)
				elseif message.role == "assistant" and util.trim(tostring(message.content or "")) ~= "" then
					parts[#parts + 1] = "Assistant: " .. turnText(message.content, full, REVIEW_REPLY_CAP)
				end
			end
		end
		return table.concat(parts, "\n\n")
	end

	-- The opening request of a thread, for list previews and triage. A thread with
	-- no user message has nothing to review, and returns nil so the list can skip it.
	local function openingLine(session)
		for _, event in ipairs(session.log or {}) do
			if event.kind == "user" and type(event.text) == "string" and util.trim(event.text) ~= "" then
				return util.ellipsis(util.trim(event.text), 140)
			end
		end
		for _, message in ipairs(session.ctx.messages or {}) do
			if message.role == "user" and util.trim(tostring(message.content or "")) ~= "" then
				return util.ellipsis(util.trim(tostring(message.content)), 140)
			end
		end
		return nil
	end

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
			-- Reading other conversations. A user who has discussed a build in three
			-- threads this week should not have to re-explain it in the fourth, and the
			-- agent should not have to re-derive it. Read-only by construction: it
			-- searches the session store, and the transcripts it reads are the durable
			-- ones on disk as well as the live ones.
			name = "conversation_search",
			risk = "read",
			description = "Search this user's other conversations for something they or the agent said earlier. Use it when the current request refers to earlier work -- 'like last time', 'the script you fixed', 'my usual setup' -- and the facts are not in this conversation. Returns the matching lines with which conversation they came from and its [id]; read the whole thread with conversation_read. This conversation is not searched; you already have it.",
			parameters = {
				type = "object",
				properties = {
					query = {
						type = "string",
						description = "The words to look for, as the user would have written them.",
					},
					limit = {
						type = "integer",
						description = "Maximum matches. Default 5.",
						minimum = 1,
						maximum = 12,
					},
				},
				required = { "query" },
			},
			run = function(args, ctx)
				local sessions = env.require("agent/session")
				local current = ctx and ctx.session or nil
				local needle = util.trim(tostring(args.query or "")):lower()
				if needle == "" then return H.fail("a query is required") end
				local limit = util.clamp(tonumber(args.limit) or 5, 1, 12)

				local lines, seen = {}, {}

				-- Pasted material first: a script the user pasted last week is often the
				-- thing "that code I sent you" refers to, and it lives in files rather
				-- than in any conversation's context -- the conversation holds only the
				-- pointer.
				local fsx = env.require("runtime/fsx")
				if fsx.enabled then
					for _, entry in ipairs(fsx.list("", { scope = "pastes" })) do
						if not entry.isDir and #lines < limit then
							local body = fsx.read(entry.path, { scope = "pastes" })
							if body then
								local at = body:lower():find(needle, 1, true)
								if at then
									lines[#lines + 1] = string.format("pasted in pastes/%s: %s",
										entry.name, util.ellipsis(body:sub(math.max(at - 60, 1)), 320))
								end
							end
						end
					end
				end

				-- All conversation text: the context the model saw plus the transcript
				-- the user read. The transcript is where a restored conversation keeps
				-- everything -- a context that has been compacted holds a summary, not
				-- the words -- so searching only ctx.messages would silently miss old
				-- threads.
				for _, session in ipairs(sessions.list()) do
					if session ~= current and not session.headless then
						local entries = {}
						for _, message in ipairs(session.ctx.messages or {}) do
							local role = message.role == "user" and "the user"
								or (message.role == "assistant" and "you" or nil)
							if role then
								entries[#entries + 1] = { role = role, text = tostring(message.content or "") }
							end
						end
						for _, event in ipairs(session.log or {}) do
							if (event.kind == "user" or event.kind == "assistant:text")
								and type(event.text) == "string" then
								entries[#entries + 1] = {
									role = event.kind == "user" and "the user" or "you",
									text = event.text,
								}
							end
						end
						for _, entry in ipairs(entries) do
							if #lines >= limit then break end
							local at = entry.text:lower():find(needle, 1, true)
							if at then
								-- One line per conversation, the first match, stated once:
								-- a thread that mentioned the term six times is one
								-- lead, not six results.
								if seen[session.id] then break end
								seen[session.id] = true
								lines[#lines + 1] = string.format('%s in "%s" [%s]: %s',
									entry.role, session.title, session.id,
									util.ellipsis(entry.text:sub(math.max(at - 60, 1)), 320))
								break
							end
						end
					end
					if #lines >= limit then break end
				end

				if #lines == 0 then
					return string.format("No other conversation or paste mentions '%s'. The user may be thinking of something from before this client kept threads, or of work in this conversation.", tostring(args.query))
				end
				return string.format("%d match%s elsewhere (read a full thread with conversation_read using its [id]):\n%s",
					#lines, #lines == 1 and "" or "es", table.concat(lines, "\n"))
			end,
		},
		{
			-- The survey: what conversations exist, with the ids the reader needs.
			name = "conversation_list",
			risk = "read",
			description = "List this user's other conversations for review, most recent first, each with its id, title, place, age, size and opening request. Use it to triage which past thread is relevant, then read that one with conversation_read. Untouched empty chats are omitted; the current conversation is marked and does not need reading. Query filters on the title or the opening request.",
			parameters = {
				type = "object",
				properties = {
					query = { type = "string", description = "Optional: only conversations whose title or opening request contains this text." },
					offset = { type = "integer", minimum = 1 },
					limit = { type = "integer", minimum = 1, maximum = 30, description = "Maximum rows. Default 10." },
				},
				required = {},
			},
			run = function(args, ctx)
				local sessions = env.require("agent/session")
				local current = ctx and ctx.session or nil
				local needle = util.trim(tostring(args.query or "")):lower()
				local all = {}
				for _, session in ipairs(sessions.list()) do
					if not session.headless then
						local preview = openingLine(session)
						-- A thread with no user message is an untouched chat: nothing to review.
						if preview and (needle == "" or tostring(session.title):lower():find(needle, 1, true)
							or preview:lower():find(needle, 1, true)) then
							all[#all + 1] = { session = session, preview = preview }
						end
					end
				end
				if #all == 0 then
					return needle == "" and "This client has no other conversations to review yet."
						or ("Nothing matches '" .. tostring(args.query) .. "' in other conversations.")
				end
				local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
				local limit = util.clamp(tonumber(args.limit) or 10, 1, 30)
				local now = clock.ms()
				local lines, shown = {}, {}
				for index = offset, math.min(#all, offset + limit - 1) do
					local session, preview = all[index].session, all[index].preview
					local ago = session.updatedAt and (util.formatDuration(math.max(now - session.updatedAt, 0)) .. " ago") or "unknown age"
					lines[#lines + 1] = string.format('%s [%s]%s -- %s, %s%s\n    %s',
						session.title, session.id,
						session.placeName and (" in " .. session.placeName) or "",
						util.pluralise(session.turns or 0, "turn"), ago,
						session == current and " (this conversation)" or "", preview)
					shown[#shown + 1] = { id = session.id, title = session.title, turns = session.turns or 0,
						place = session.placeName, current = session == current, preview = preview }
				end
				local nextOffset = offset + limit <= #all and offset + limit or nil
				local header = string.format("%d conversation%s%s. Read one with conversation_read [id] (add full=true for verbatim text):",
					#all, #all == 1 and "" or "s",
					nextOffset and (", showing " .. offset .. "-" .. (offset + #lines - 1)) or "")
				return { text = header .. "\n" .. table.concat(lines, "\n"),
					data = { total = #all, conversations = shown, nextOffset = nextOffset } }
			end,
		},
		{
			-- Reading a whole thread, not just a search snippet. This is what turns
			-- "the user mentioned a build last week" into the actual decisions taken.
			name = "conversation_read",
			risk = "read",
			description = "Read one of this user's other conversations by id (from conversation_list or conversation_search). Condensed by default: the whole thread with long turns shortened and tool runs collapsed, so a review costs one bounded read. Pass full=true for the verbatim transcript in UTF-8-safe byte slices, following nextOffset for the rest. Use it after a list or search points at a relevant thread, so you carry forward what was decided instead of re-deriving or re-asking it.",
			parameters = {
				type = "object",
				properties = {
					id = { type = "string", description = "The conversation id, as shown in [brackets] by conversation_list or conversation_search." },
					full = { type = "boolean", description = "Return every turn verbatim instead of the condensed review. Use only when you need exact wording; it costs more slices." },
					offset = { type = "integer", minimum = 1, description = "Byte offset to continue from; use the nextOffset from the previous read." },
					limit = { type = "integer", minimum = 200, maximum = 6000, description = "Maximum bytes to return in this slice." },
				},
				required = { "id" },
			},
			run = function(args, ctx)
				local sessions = env.require("agent/session")
				local id = util.trim(tostring(args.id or ""))
				if id == "" then return H.fail("a conversation id is required; list them with conversation_list") end
				local session = sessions.threads[id]
				if not session then
					for _, candidate in ipairs(sessions.list()) do
						if candidate.title == args.id then session = candidate; break end
					end
				end
				if not session then return H.fail("no conversation with id '" .. id .. "'. Use conversation_list for current ids.") end
				if session.headless then return H.fail("that id is an internal subagent session, not a conversation.") end
				local full = args.full == true
				local body = readableTranscript(session, full)
				if util.trim(body) == "" then body = "(this conversation has no readable messages yet)" end
				if not full then
					body = "(condensed: long turns are shortened and tool runs collapsed; call again with full=true for verbatim text)\n\n" .. body
				end
				local label = string.format('Conversation "%s" [%s]%s (%s)', session.title, session.id,
					session.placeName and (" in " .. session.placeName) or "", full and "full" or "condensed")
				return H.readSlice(label, body, args, 4000)
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
						id = util.uid("ask"),
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
