-- Agent-owned state that outlives a single turn: the task list the model keeps,
-- and the memory it writes to.
--
-- Both are model-writable, which is the point -- a long task survives context
-- compaction because the plan is not in the transcript -- and both are bounded,
-- because a model given an unbounded store will fill it.
--
-- Memory is the client's, deliberately: a fact about the person using it is not a
-- fact about one conversation. A task list is the opposite -- it is the plan for
-- the job in front of it -- so it lives on the session, which is what lets two
-- conversations work at once. It did not, and one global list was the whole bug:
-- starting a second conversation replaced the first one's plan in the strip *and*
-- in the system prompt it was about to be sent, so a running turn resumed against
-- somebody else's steps.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")

	local TODO_LIMIT = 24
	local MEMORY_LIMIT = 60
	local MEMORY_VALUE_CAP = 600

	local M = {
		todosChanged = signal.new("todos"),
		memoryChanged = signal.new("memory"),
	}

	-- Todos -----------------------------------------------------------------

	local STATUS = { pending = true, active = true, done = true, dropped = true }

	-- Where a list lives when there is no session in scope. Nothing in the client
	-- reaches this any more; it exists so a caller that loses its session writes
	-- somewhere harmless rather than raising, and so a test can drive the store
	-- without building a session.
	local orphan = { todos = {} }

	local function holderFor(session)
		if type(session) ~= "table" then return orphan end
		session.todos = session.todos or {}
		return session
	end

	function M.todoList(session)
		return holderFor(session).todos
	end

	-- The whole list is replaced rather than patched. A model that edits one item
	-- at a time drifts out of sync with its own plan; handing back the full list
	-- every time keeps the transcript and the panel identical.
	function M.setTodos(items, session)
		local out = {}
		for index, item in ipairs(items or {}) do
			if index > TODO_LIMIT then break end
			local text = util.trim(type(item) == "table" and (item.text or item.title) or item)
			if text ~= "" then
				local status = type(item) == "table" and tostring(item.status or "pending"):lower() or "pending"
				if not STATUS[status] then status = "pending" end
				out[#out + 1] = {
					id = index,
					text = util.ellipsis(text, 160),
					status = status,
					note = type(item) == "table" and item.note or nil,
				}
			end
		end
		local holder = holderFor(session)
		holder.todos = out
		-- The session goes with the list, so a strip showing one conversation can
		-- ignore another conversation's plan instead of painting it.
		M.todosChanged:fire(out, holder ~= orphan and holder or nil)
		return out
	end

	function M.todoCounts(session)
		local list = M.todoList(session)
		local counts = { pending = 0, active = 0, done = 0, dropped = 0, total = #list }
		for _, item in ipairs(list) do
			counts[item.status] = (counts[item.status] or 0) + 1
		end
		return counts
	end

	function M.clearTodos(session)
		local holder = holderFor(session)
		holder.todos = {}
		M.todosChanged:fire({}, holder ~= orphan and holder or nil)
	end

	-- Rendered into the system prompt each turn so the plan cannot be forgotten,
	-- and into the transcript panel for the user.
	function M.todoBlock(session)
		local list = M.todoList(session)
		if #list == 0 then return nil end
		local marks = { pending = "[ ]", active = "[>]", done = "[x]", dropped = "[-]" }
		local lines = {}
		for _, item in ipairs(list) do
			lines[#lines + 1] = string.format("%s %s", marks[item.status] or "[ ]", item.text)
		end
		return table.concat(lines, "\n")
	end

	-- Memory ----------------------------------------------------------------

	local function entries()
		local stored = config.get("memory.entries", {})
		if type(stored) ~= "table" then return {} end
		return stored
	end

	function M.memoryEnabled()
		return config.get("memory.enabled", true) ~= false
	end

	function M.remember(key, value)
		local cleanKey = util.trim(key):gsub("%s+", "_")
		if cleanKey == "" then return false, "a memory needs a key" end
		if not M.memoryEnabled() then return false, "memory is disabled in settings" end
		local list = entries()
		local text = util.ellipsis(util.trim(value), MEMORY_VALUE_CAP)
		if text == "" then return false, "a memory needs a value" end

		local replaced = false
		for _, entry in ipairs(list) do
			if entry.key == cleanKey then
				entry.value = text
				entry.at = clock.ms()
				replaced = true
			end
		end
		if not replaced then
			if #list >= MEMORY_LIMIT then
				-- Oldest out. A model that keeps writing should lose its earliest
				-- notes rather than start failing.
				table.sort(list, function(a, b) return (a.at or 0) < (b.at or 0) end)
				table.remove(list, 1)
			end
			list[#list + 1] = { key = cleanKey, value = text, at = clock.ms() }
		end
		config.set("memory.entries", list)
		M.memoryChanged:fire(list)
		return true, (replaced and "updated " or "saved ") .. cleanKey
	end

	function M.recall(key)
		for _, entry in ipairs(entries()) do
			if entry.key == util.trim(key) then return entry.value end
		end
		return nil
	end

	function M.forget(key)
		local list = entries()
		local kept = {}
		local removed = 0
		for _, entry in ipairs(list) do
			if entry.key == util.trim(key) then
				removed = removed + 1
			else
				kept[#kept + 1] = entry
			end
		end
		config.set("memory.entries", kept)
		M.memoryChanged:fire(kept)
		return removed > 0
	end

	function M.memoryList()
		local list = entries()
		table.sort(list, function(a, b) return tostring(a.key) < tostring(b.key) end)
		return list
	end

	function M.clearMemory()
		config.set("memory.entries", {})
		M.memoryChanged:fire({})
	end

	function M.memoryBlock()
		if not M.memoryEnabled() then return nil end
		local list = M.memoryList()
		if #list == 0 then return nil end
		local lines = {}
		for _, entry in ipairs(list) do
			lines[#lines + 1] = "- " .. entry.key .. ": " .. entry.value
		end
		return table.concat(lines, "\n")
	end

	return M
end
