-- Agent-owned state that outlives a single turn: the task list the model keeps,
-- and the memory it writes to.
--
-- Both are model-writable, which is the point -- a long task survives context
-- compaction because the plan is not in the transcript -- and both are bounded,
-- because a model given an unbounded store will fill it.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")

	local TODO_LIMIT = 24
	local MEMORY_LIMIT = 60
	local MEMORY_VALUE_CAP = 600

	local M = {
		todos = {},
		todosChanged = signal.new("todos"),
		memoryChanged = signal.new("memory"),
	}

	-- Todos -----------------------------------------------------------------

	local STATUS = { pending = true, active = true, done = true, dropped = true }

	-- The whole list is replaced rather than patched. A model that edits one item
	-- at a time drifts out of sync with its own plan; handing back the full list
	-- every time keeps the transcript and the panel identical.
	function M.setTodos(items)
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
		M.todos = out
		M.todosChanged:fire(out)
		return out
	end

	function M.todoCounts()
		local counts = { pending = 0, active = 0, done = 0, dropped = 0, total = #M.todos }
		for _, item in ipairs(M.todos) do
			counts[item.status] = (counts[item.status] or 0) + 1
		end
		return counts
	end

	function M.clearTodos()
		M.todos = {}
		M.todosChanged:fire({})
	end

	-- Rendered into the system prompt each turn so the plan cannot be forgotten,
	-- and into the transcript panel for the user.
	function M.todoBlock()
		if #M.todos == 0 then return nil end
		local marks = { pending = "[ ]", active = "[>]", done = "[x]", dropped = "[-]" }
		local lines = {}
		for _, item in ipairs(M.todos) do
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
