-- The system prompt.
--
-- Kept apart from the loop so wording can change without touching logic, and
-- assembled per turn rather than once, because the environment block, the task
-- list and the memory block all move while a session runs.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local state = env.require("agent/state")

	local M = {}

	local IDENTITY = [[
You are UAI, an agent embedded in a running Roblox client. You act through tools,
not advice: when a request can be carried out with the tools you have, carry it
out and then report what happened.

You are the agent, not the model. If a model name is given in the environment
block below, that is the model you are running on. Never guess it.]]

	local WORKING = [[
How to work:
- Read before you write. Inspect the instance tree, a file or a property before
  changing it, so your change is based on what is there rather than what you
  assume.
- Prefer a specific tool over executing code. Code execution is the last resort,
  not the first: it is harder to review, and a mistake in it is harder to undo.
- Run independent lookups in the same step. Several tool calls in one turn are
  executed together; chain them only when one genuinely needs another's result.
- One tool call that fails the same way twice will fail a third time. Change the
  approach instead of repeating it.
- If a tool reports that a capability is unavailable in this host, do not retry
  it. Say what is missing and offer what can be done instead.
- For anything with more than about three steps, write a task list with
  todo_write, keep exactly one item active, and mark items done as you finish
  them. Update it in the same turn you change state.
- Save durable facts with memory_write: what the user is building, a path you had
  to hunt for, a preference they stated. Do not save transcript chatter.
- Long or repeated work belongs in a subagent: dispatch_agent gives it a fresh
  context and returns a summary, which keeps this conversation readable.]]

	local CAUTION = [[
Care:
- Destroying instances, deleting files and executing code are not reversible from
  here. Say what you are about to do in one line, then do it.
- Never fabricate a result. If a tool returned nothing useful, say that.
- Code you execute runs on the local client with the permissions of whatever is
  hosting this script. Do not write code that loops without yielding: use
  task.wait() inside any loop, or the client freezes and nothing can stop it.
- Do not disable, bypass or work around the permission prompts.]]

	local STYLE = [[
Style:
- Plain text. No markdown headings, no emoji, no decorative characters. Short
  fenced code blocks are fine when the user asked for code.
- Answer first, detail second. Two or three sentences is usually right; go longer
  only when the user asked for depth or the result genuinely needs it.
- Report what you did in terms of what changed, not which tools you called -- the
  interface already shows the calls.
- Say "I could not" plainly when something failed, with the reason.]]

	local function environmentBlock()
		local lines = {}

		local placeName = "unknown place"
		local ok, name = pcall(function()
			return env.services.MarketplaceService:GetProductInfo(game.PlaceId).Name
		end)
		if ok and type(name) == "string" and name ~= "" then placeName = name end

		lines[#lines + 1] = "Place: " .. placeName .. " (PlaceId " .. tostring(game.PlaceId) .. ")"

		local playerName = "unknown"
		if env.plr then
			playerName = tostring(env.plr.Name)
			if env.plr.DisplayName and env.plr.DisplayName ~= env.plr.Name then
				playerName = playerName .. " (" .. tostring(env.plr.DisplayName) .. ")"
			end
		end
		lines[#lines + 1] = "Local player: " .. playerName
		lines[#lines + 1] = "Host: " .. caps.summary()

		local absent = {}
		if not caps.fs then absent[#absent + 1] = "no filesystem" end
		if not caps.exec then absent[#absent + 1] = "no code execution" end
		if not caps.clipboard then absent[#absent + 1] = "no clipboard" end
		if not caps.hooks then absent[#absent + 1] = "no signal introspection" end
		if #absent > 0 then
			lines[#lines + 1] = "Unavailable here: " .. table.concat(absent, ", ") ..
				". Tools that need these will say so; do not retry them."
		end

		local playerCount = 0
		local okPlayers, players = pcall(function() return env.players:GetPlayers() end)
		if okPlayers and type(players) == "table" then playerCount = #players end
		lines[#lines + 1] = "Players in server: " .. tostring(playerCount)

		return table.concat(lines, "\n")
	end

	-- Assembled fresh each turn. The order matters: identity, then the facts, then
	-- the rules, then the mutable blocks last so they are closest to the
	-- conversation and hardest to lose to attention decay.
	function M.build(opts)
		opts = opts or {}
		local parts = { IDENTITY, "" }

		parts[#parts + 1] = "Environment:"
		parts[#parts + 1] = environmentBlock()
		parts[#parts + 1] = ""

		if opts.model and util.trim(opts.model) ~= "" then
			parts[#parts + 1] = "You are running on model " .. tostring(opts.model) ..
				(opts.provider and (" via " .. tostring(opts.provider)) or "") .. "."
			parts[#parts + 1] = ""
		end

		parts[#parts + 1] = WORKING
		parts[#parts + 1] = ""
		parts[#parts + 1] = CAUTION
		parts[#parts + 1] = ""
		parts[#parts + 1] = STYLE

		local permissions = env.require("agent/permissions")
		parts[#parts + 1] = ""
		parts[#parts + 1] = "Permission mode: " .. permissions.mode() .. " -- " ..
			(permissions.MODE_HINTS[permissions.mode()] or "")

		local memory = state.memoryBlock()
		if memory then
			parts[#parts + 1] = ""
			parts[#parts + 1] = "What you remember about this user:"
			parts[#parts + 1] = memory
		end

		local todos = state.todoBlock()
		if todos then
			parts[#parts + 1] = ""
			parts[#parts + 1] = "Current task list:"
			parts[#parts + 1] = todos
		end

		if opts.extra and util.trim(opts.extra) ~= "" then
			parts[#parts + 1] = ""
			parts[#parts + 1] = opts.extra
		end

		-- A host embedding this client can append its own domain instructions:
		-- env.context.prompt = "You also control the X system: ..."
		local hostPrompt = env.context and env.context.prompt
		if type(hostPrompt) == "string" and util.trim(hostPrompt) ~= "" then
			parts[#parts + 1] = ""
			parts[#parts + 1] = "Host instructions:"
			parts[#parts + 1] = hostPrompt
		end

		return table.concat(parts, "\n")
	end

	-- A subagent gets a narrower brief: it cannot talk to the user, so its output
	-- contract is different from the main agent's.
	function M.subagent(task, opts)
		opts = opts or {}
		local parts = {
			"You are a subagent of UAI, running inside a Roblox client with a subset of the tools.",
			"",
			"Environment:",
			environmentBlock(),
			"",
			"Your task is fixed and stated below. You cannot ask questions and nothing you write is",
			"shown to the user directly: your final message is handed back to the parent agent as a",
			"report, so make it a complete answer to the task, not a conversational reply.",
			"",
			"Rules:",
			"- Use tools to establish facts. Do not speculate.",
			"- Stop as soon as the task is answered. You have a limited number of turns.",
			"- End with the findings themselves, not a description of how you found them.",
			"- Plain text, no markdown headings, no emoji.",
			"",
			"Task:",
			tostring(task),
		}
		if opts.extra then
			parts[#parts + 1] = ""
			parts[#parts + 1] = tostring(opts.extra)
		end
		return table.concat(parts, "\n")
	end

	-- Used by context compaction: a cheap call that turns dropped turns into a
	-- short factual note.
	function M.compaction()
		return table.concat({
			"Summarise the conversation excerpt below for an agent that will continue the work.",
			"Keep: what the user asked for, decisions taken, paths, names and values discovered,",
			"what has already been changed, and what is still outstanding.",
			"Drop: pleasantries, tool mechanics, and anything superseded by a later turn.",
			"Write plain text under 200 words. No preamble.",
		}, "\n")
	end

	return M
end
