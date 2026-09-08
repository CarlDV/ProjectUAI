-- The code tab's tool set: tabs the agent can write into, read back, edit by
-- line range, and search -- modelled on the reference client's Code tools, with
-- the same operations (list/switch/write/read/lines/grep) and the same rule the
-- reference client learned the hard way: the agent never switches the user's
-- view, it addresses a tab by name or index instead.
--
-- Execution is deliberately not one of these. run_luau already exists, is
-- permission-gated as the dangerous thing it is, and reports through the
-- transcript where the user is looking; a second path that runs code without
-- that gate would be a hole, not a convenience.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local LOG_CAP = 120

	-- Shared with the panel's own Run button, which is the same contract without
	-- the permission gate (the user pressed it). Kept here rather than in the
	-- panel so there is one description of what running code reports.
	local function runWithCapture(fn, seconds)
		local logs = {}
		local truncatedLogs = false
		local globals = (caps.fn.getgenv and caps.fn.getgenv()) or _G
		local sandbox = setmetatable({
			print = function(...)
				if #logs >= LOG_CAP then
					truncatedLogs = true
					return
				end
				local parts = {}
				for index = 1, select("#", ...) do
					parts[#parts + 1] = H.show((select(index, ...)))
				end
				logs[#logs + 1] = table.concat(parts, "\t")
			end,
			warn = function(...)
				if #logs >= LOG_CAP then
					truncatedLogs = true
					return
				end
				local parts = {}
				for index = 1, select("#", ...) do
					parts[#parts + 1] = H.show((select(index, ...)))
				end
				logs[#logs + 1] = "[warn] " .. table.concat(parts, "\t")
			end,
		}, { __index = globals, __newindex = globals })
		if setfenv then pcall(setfenv, fn, sandbox) end

		local started = clock.ms()
		local finished, ok, result = clock.timeout(seconds or 10, fn)

		local output = {}
		if not finished then
			output[#output + 1] = string.format(
				"Timed out after %ds and was left running in the background. It was not stopped -- Luau cannot kill a thread. Do not retry the same code; make it finish or yield.",
				seconds or 10)
		elseif not ok then
			output[#output + 1] = "Runtime error: " .. tostring(result)
		else
			output[#output + 1] = string.format("Ran in %s.", util.formatDuration(clock.since(started)))
			if result ~= nil then output[#output + 1] = "Returned: " .. H.show(result) end
		end

		if #logs > 0 then
			output[#output + 1] = "Output:\n" .. table.concat(logs, "\n")
			if truncatedLogs then
				output[#output + 1] = string.format("(output stopped after %d lines)", LOG_CAP)
			end
		end
		return table.concat(output, "\n")
	end

	local tools = {}

	local function tabNote(tab, active)
		if tab == active then return "" end
		return string.format(" (tab: %s)", tab.name)
	end

	local function syntaxSuffix(code)
		local compile = caps.fn.loadstring
		if not compile then return "" end
		local ok, fnOrErr = pcall(compile, code)
		if ok and type(fnOrErr) == "function" then return "" end
		return " -- Syntax error: " .. tostring(fnOrErr)
	end

	local function listTabs()
		local store = env.require("ui/panels/code_store")
		local tabs = store.list()
		local active = store.active()
		local lines = {}
		for index, tab in ipairs(tabs) do
			local count = select(2, tostring(tab.code or ""):gsub("\n", "\n")) + 1
			lines[#lines + 1] = string.format("%d: %s (%d line%s)%s",
				index, tab.name, count, count == 1 and "" or "s",
				tab == active and " [active]" or "")
		end
		return table.concat(lines, "\n")
	end

	tools[#tools + 1] = {
		name = "code_tabs",
		risk = "read",
		description = "List the tabs in the shared code editor, with which one is active. The user sees the same tabs in the Code panel.",
		parameters = { type = "object", properties = {}, required = {} },
		run = function()
			return listTabs()
		end,
	}

	tools[#tools + 1] = {
		name = "code_write",
		risk = "write",
		description = "Write or fully replace the code in a tab of the shared code editor. Defaults to the active tab; name a tab to write without switching the user's view. The code appears in the Code panel immediately.",
		parameters = {
			type = "object",
			properties = {
				code = { type = "string", description = "The full Luau source to write." },
				tab = { type = "string", description = "Optional tab name or index. Omit for the active tab." },
				name = { type = "string", description = "Optional name when creating a new tab (used with new)." },
				new = { type = "boolean", description = "Create a new tab for this code rather than replacing one." },
			},
			required = { "code" },
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local code = tostring(args.code or "")
			local tab, err

			if args.new then
				tab, err = store.addTab(args.name or args.tab, code)
				if not tab then return H.fail(err) end
			else
				tab, err = store.write(args.tab, code)
				if not tab then return H.fail(err) end
			end

			local count = select(2, code:gsub("\n", "\n")) + 1
			return string.format("Wrote %d line%s to %s.%s%s",
				count, count == 1 and "" or "s", tab.name,
				tabNote(tab, store.active()), syntaxSuffix(code))
		end,
	}

	tools[#tools + 1] = {
		name = "code_read",
		risk = "read",
		description = "Read a tab of the shared code editor. Defaults to the active tab.",
		parameters = {
			type = "object",
			properties = {
				tab = { type = "string", description = "Optional tab name or index. Omit for the active tab." },
				start = { type = "integer", description = "Optional first line to return (1-based)." },
				count = { type = "integer", description = "Optional number of lines to return." },
			},
			required = {},
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local tab, err = store.resolve(args.tab)
			if not tab then return H.fail(err) end
			local code = tostring(tab.code or "")
			if util.trim(code) == "" then
				return string.format("%s is empty.%s", tab.name, tabNote(tab, store.active()))
			end

			local lines = util.lines(code)
			local from = math.max(1, math.floor(tonumber(args.start) or 1))
			local count = math.floor(tonumber(args.count) or #lines)
			local to = math.min(#lines, from + count - 1)

			local shown = {}
			for index = from, to do
				shown[#shown + 1] = string.format("%d: %s", index, lines[index])
			end
			local header = string.format("%s, %d line%s (showing %d-%d):",
				tab.name, #lines, #lines == 1 and "" or "s", from, to)
			return header .. "\n" .. table.concat(shown, "\n")
		end,
	}

	tools[#tools + 1] = {
		name = "code_edit",
		risk = "write",
		description = "Replace a range of lines in a tab of the shared code editor. Cheaper than rewriting the whole tab when changing one function.",
		parameters = {
			type = "object",
			properties = {
				start = { type = "integer", description = "First line to replace (1-based)." },
				finish = { type = "integer", description = "Last line to replace (inclusive)." },
				code = { type = "string", description = "The replacement lines." },
				tab = { type = "string", description = "Optional tab name or index. Omit for the active tab." },
			},
			required = { "start", "finish", "code" },
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local tab, err = store.replaceLines(args.tab, args.start, args.finish, args.code)
			if not tab then return H.fail(err) end
			local count = select(2, tostring(tab.code):gsub("\n", "\n")) + 1
			return string.format("Replaced lines %d-%d in %s, now %d lines.%s%s",
				math.floor(args.start), math.floor(args.finish), tab.name, count,
				tabNote(tab, store.active()), syntaxSuffix(tab.code))
		end,
	}

	tools[#tools + 1] = {
		name = "code_search",
		risk = "read",
		description = "Search the code editor's tabs with a Lua pattern. Returns the tab, line number and line for every match.",
		parameters = {
			type = "object",
			properties = {
				pattern = { type = "string", description = "Lua pattern to search for. Plain strings work too." },
				tab = { type = "string", description = "Optional tab name or index to search. Omit to search all tabs." },
			},
			required = { "pattern" },
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local pattern = tostring(args.pattern or "")
			if pattern == "" then return H.fail("no pattern was given") end
			local matches, err = store.search(pattern, args.tab)
			if not matches then return H.fail(err) end
			if #matches == 0 then
				return args.tab and "No matches in that tab." or "No matches in any tab."
			end
			local cap = math.min(#matches, 40)
			local shown = {}
			for index = 1, cap do
				shown[#shown + 1] = util.ellipsis(matches[index], 200)
			end
			local note = #matches > cap and string.format("\n(and %d more)", #matches - cap) or ""
			return string.format("%d match(es):\n%s%s", #matches, table.concat(shown, "\n"), note)
		end,
	}

	tools[#tools + 1] = {
		name = "code_select",
		risk = "write",
		description = "Switch which tab of the code editor is active. This changes the user's view, so prefer addressing a tab by name in code_write and code_read instead.",
		parameters = {
			type = "object",
			properties = {
				tab = { type = "string", description = "Tab name or index." },
			},
			required = { "tab" },
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local tab, err = store.select(args.tab)
			if not tab then return H.fail(err) end
			return "Active tab is now " .. tab.name .. "."
		end,
	}

	tools[#tools + 1] = {
		name = "code_run",
		risk = "danger",
		needs = { "exec" },
		description = "Run the code in a tab of the shared code editor and report its output. Same contract as run_luau, but reads the tab rather than an argument, so the user can read and edit the code before it runs.",
		parameters = {
			type = "object",
			properties = {
				tab = { type = "string", description = "Optional tab name or index. Omit for the active tab." },
			},
			required = {},
		},
		run = function(args)
			local store = env.require("ui/panels/code_store")
			local tab, err = store.resolve(args.tab)
			if not tab then return H.fail(err) end
			local code = tostring(tab.code or "")
			if util.trim(code) == "" then
				return H.fail(tab.name .. " is empty")
			end

			local compile = caps.fn.loadstring
			if not compile then return H.fail("this host cannot compile Luau") end
			local ok, fnOrErr = pcall(compile, code)
			if not ok or type(fnOrErr) ~= "function" then
				return H.fail("compile error: " .. tostring(fnOrErr))
			end

			local output = runWithCapture(fnOrErr, 10)
			return string.format("Ran %s.%s\n%s", tab.name, tabNote(tab, store.active()), output)
		end,
	}

	-- The runner rides on the returned list so the panel can reach it without the
	-- registry: a group module's return value is the flat tool list, and a plain
	-- Lua table can carry one extra field nobody iterates.
	tools.runWithCapture = runWithCapture
	return tools
end
