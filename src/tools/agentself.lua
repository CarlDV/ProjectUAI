-- Tools the agent uses on itself: the task list, durable memory, delegation and
-- deliberate waiting.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local state = env.require("agent/state")
	local subagent = env.require("agent/subagent")
	local H = env.require("tools/helpers")

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
			run = function(args)
				local items = state.setTodos(args.items)
				if #items == 0 then return "Task list cleared." end
				local counts = state.todoCounts()
				return string.format("Task list set: %d items (%d done, %d active, %d pending).\n%s",
					counts.total, counts.done, counts.active, counts.pending, state.todoBlock())
			end,
		},
		{
			name = "todo_read",
			risk = "read",
			description = "Read the current task list.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local block = state.todoBlock()
				if not block then return "The task list is empty." end
				return block
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
			description = "Hand a self-contained investigation to a subagent with its own context, and get back a written report. Use for wide searches, repetitive inspection, or anything that would otherwise fill this conversation with tool output. The subagent cannot ask questions, so state the task completely.",
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
						description = "Which tools it gets. 'read' (default) cannot change anything; 'full' can.",
					},
					turns = { type = "integer", description = "Step limit, 1-30. Default 14.", minimum = 1, maximum = 30 },
				},
				required = { "task" },
			},
			run = function(args, ctx)
				local result, err = subagent.dispatch({
					parent = ctx and ctx.session or nil,
					task = args.task,
					preset = args.preset or "read",
					turns = args.turns,
				})
				if not result then return H.fail(err) end
				return string.format("Subagent report (%s, %d messages):\n\n%s",
					util.formatDuration(result.ms), result.messages, result.text)
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
