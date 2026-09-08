-- Shared state for the code tab: the tab list, the active tab, and persistence.
--
-- Lives outside the panel because tools cannot reach a closure: a write_code
-- call has to land in the same tabs the panel renders, whether or not the panel
-- is open. The panel reads and writes through here too, so there is exactly one
-- copy of the state rather than two that can disagree.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local signal = env.require("runtime/signal")
	local fsx = env.require("runtime/fsx")
	local log = env.require("runtime/log")

	local M = { changed = signal.new("code") }

	local FILE = "code/tabs.json"
	local MAX_TABS = 10

	local function blank()
		return {
			{ id = "tab1", name = "Tab 1", code = "" },
		}
	end

	-- The persisted shape: { tabs = { { name, code } }, active = n }. Ids are not
	-- persisted -- they are per-session handles, and a stored id colliding with a
	-- freshly generated one would be a coincidence the interface cannot afford.
	local function load()
		local data = fsx.readJson(FILE, nil)
		local tabs = {}
		if type(data) == "table" and type(data.tabs) == "table" then
			for index, entry in ipairs(data.tabs) do
				if index > MAX_TABS then break end
				if type(entry) == "table" then
					tabs[#tabs + 1] = {
						id = "tab" .. tostring(index),
						name = type(entry.name) == "string" and entry.name ~= ""
							and entry.name or ("Tab " .. tostring(index)),
						code = type(entry.code) == "string" and entry.code or "",
					}
				end
			end
		end
		if #tabs == 0 then tabs = blank() end

		local active = tabs[1]
		local wanted = tonumber(data and data.active) or 1
		if tabs[wanted] then active = tabs[wanted] end
		M.state = { tabs = tabs, active = active }
		return tabs, active
	end

	-- Writes the tab list and the active tab's id. Accepts the panel's live tab
	-- objects rather than the store's own, because the panel is the surface that
	-- owns the edit in flight.
	function M.save(tabs, activeId)
		local data = { tabs = {}, active = 1 }
		for index, tab in ipairs(tabs) do
			if index > MAX_TABS then break end
			data.tabs[#data.tabs + 1] = { name = tab.name, code = tab.code or "" }
			if activeId and tab.id == activeId then data.active = #data.tabs end
		end
		if #data.tabs == 0 then data.tabs = blank() end
		fsx.writeJson(FILE, data)

		-- Refresh the in-memory copy the tools read, without notifying the panel
		-- that caused the write: it already shows this state.
		M.state = { tabs = tabs, active = activeId }
	end

	function M.load()
		local tabs, active = load()
		return tabs
	end

	function M.activeId()
		load()
		return M.state.active and M.state.active.id or nil
	end

	-- The tab a tool's "current tab" means: the persisted active one. Tools never
	-- invent their own current tab, or a write_code with no tab argument and a
	-- write_code with one would be two states.
	function M.active()
		load()
		return M.state.active
	end

	function M.list()
		load()
		return M.state.tabs
	end

	-- Resolves a tool's tab argument: nil/empty for the active tab, a number for
	-- an index, a string for a name. Returns the tab and a readable label for
	-- error messages.
	function M.resolve(reference)
		load()
		local tabs = M.state.tabs
		if reference == nil or reference == "" then
			return M.state.active, nil
		end
		local index = tonumber(reference)
		if index then
			local tab = tabs[math.floor(index)]
			if tab then return tab, nil end
			return nil, string.format("no tab numbered %d (there are %d)", math.floor(index), #tabs)
		end
		local wanted = tostring(reference):lower()
		for _, tab in ipairs(tabs) do
			if tostring(tab.name):lower() == wanted then return tab, nil end
		end
		local names = {}
		for position, tab in ipairs(tabs) do
			names[#names + 1] = position .. ": " .. tab.name
		end
		return nil, "no tab called '" .. tostring(reference) .. "' (open: " .. table.concat(names, ", ") .. ")"
	end

	-- Mutations for the tool set. Each writes through, then notifies, so an open
	-- panel picks the change up and a closed one reads it on next open.

	function M.write(reference, code)
		local tab, err = M.resolve(reference)
		if not tab then return nil, err end
		tab.code = tostring(code or "")
		M.save(M.state.tabs, M.state.active and M.state.active.id or nil)
		M.changed:fire()
		return tab, nil
	end

	function M.addTab(name, code)
		load()
		if #M.state.tabs >= MAX_TABS then
			return nil, "the tab limit (" .. MAX_TABS .. ") is reached"
		end
		local tab = {
			id = "tab" .. tostring(#M.state.tabs + 1),
			name = name and name ~= "" and name or ("Tab " .. tostring(#M.state.tabs + 1)),
			code = code or "",
		}
		M.state.tabs[#M.state.tabs + 1] = tab
		M.save(M.state.tabs, tab.id)
		M.changed:fire()
		return tab, nil
	end

	function M.select(reference)
		local tab, err = M.resolve(reference)
		if not tab then return nil, err end
		M.state.active = tab
		M.save(M.state.tabs, tab.id)
		M.changed:fire()
		return tab, nil
	end

	function M.rename(reference, name)
		local tab, err = M.resolve(reference)
		if not tab then return nil, err end
		local trimmed = util.trim(tostring(name or ""))
		if trimmed == "" then return nil, "a tab needs a name" end
		tab.name = trimmed
		M.save(M.state.tabs, M.state.active and M.state.active.id or nil)
		M.changed:fire()
		return tab, nil
	end

	-- Line-ranged edits, the reference client's replace_lines: cheaper than a
	-- whole-file rewrite for a model working on one function, and the same
	-- operation the user can do by hand in the box.
	function M.replaceLines(reference, startLine, endLine, replacement)
		local tab, err = M.resolve(reference)
		if not tab then return nil, err end
		local lines = util.lines(tostring(tab.code or ""))
		local from = math.max(1, math.floor(tonumber(startLine) or 1))
		local to = math.min(#lines, math.floor(tonumber(endLine) or from))
		if from > #lines then
			return nil, string.format("line %d is past the end (the tab has %d lines)", from, #lines)
		end
		if to < from then to = from end

		local incoming = util.lines(tostring(replacement or ""))
		local result = {}
		for index = 1, from - 1 do result[#result + 1] = lines[index] end
		for _, line in ipairs(incoming) do result[#result + 1] = line end
		for index = to + 1, #lines do result[#result + 1] = lines[index] end

		tab.code = table.concat(result, "\n")
		M.save(M.state.tabs, M.state.active and M.state.active.id or nil)
		M.changed:fire()
		return tab, nil
	end

	-- Cross-tab search, the reference client's grep.
	function M.search(pattern, reference)
		load()
		local targets
		if reference and reference ~= "" then
			local tab, err = M.resolve(reference)
			if not tab then return nil, err end
			targets = { tab }
		else
			targets = M.state.tabs
		end

		local matches = {}
		for _, tab in ipairs(targets) do
			for index, line in ipairs(util.lines(tostring(tab.code or ""))) do
				local ok, found = pcall(string.find, line, pattern)
				if ok and found then
					matches[#matches + 1] = string.format("%s:%d: %s", tab.name, index, line)
				end
			end
		end
		return matches, nil
	end
	return M
end
