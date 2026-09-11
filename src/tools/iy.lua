-- Infinite Yield commands: run them, list them, inspect them -- and reach the
-- community plugin store.
--
-- The whole of IY is reachable through one dispatcher, so the tool set is small
-- on purpose. Every command -- noclip, fly, esp, remotespy, plugin loads -- is
-- the same execCmd call; what the tools add is discovery (a searchable list of
-- what exists) and honesty (status that says which route IY came by and what
-- the host can do).
--
-- The plugin tools sit on top of runtime/iy_store: the store's catalogue is
-- searched in conversation, and an install downloads the .iy, saves it into
-- the executor workspace and registers it with the running IY. There is no
-- store interface to browse -- asking for a plugin and having it appear is the
-- whole design.
--
-- `iy_cmd` is risk "write" even though plenty of IY commands only read, because
-- the argument is a raw command string the permission engine cannot look
-- inside: gating it as the worst thing it can do is the only honest label. The
-- install tools carry the same label for the same reason -- a plugin is code.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local H = env.require("tools/helpers")
	local iy = env.require("runtime/iy")
	local store = env.require("runtime/iy_store")

	local LIST_CAP = 80

	return {
		{
			name = "iy_status",
			risk = "read",
			description = "Report Infinite Yield: the Settings mode, whether it is loaded, how it was "
				.. "obtained (already running, or loaded by this client), the command count and prefix. "
				.. "Call this before iy_cmd when you do not know whether IY is available.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				return H.keyValues(iy.status())
			end,
		},
		{
			name = "iy_cmd",
			risk = "write",
			description = "Run an Infinite Yield command by its command string, exactly as typed into "
				.. "IY's own bar: 'speed 100', 'noclip', 'tp PlayerName', 'esp players'. Supports IY's "
				.. "repeat prefixes ('5^speed 100', 'inf^0.5^esp'). Check iy_status first; when the "
				.. "setting is on but IY is not loaded, this call loads it.",
			parameters = {
				type = "object",
				properties = {
					command = { type = "string", description = "The command string, without IY's ';' prefix." },
				},
				required = { "command" },
			},
			run = function(args)
				local command = util.trim(tostring(args.command or ""))
				if command == "" then return H.fail("no command given") end

				-- A command that starts with the chat prefix is the common slip;
				-- execCmd wants the bare command. Strip only one leading ';'.
				if command:sub(1, 1) == ";" then command = util.trim(command:sub(2)) end
				if command == "" then return H.fail("nothing after the prefix") end

				if not iy.isLoaded() then
					local ok, err = iy.ensure()
					if not ok then return H.fail(err) end
				end

				local ok, err = iy.exec(command)
				if not ok then return H.fail(err) end
				-- execCmd spawns its own thread, so "accepted" is the honest word:
				-- a command that errors inside IY is reported by IY, not to us.
				return "Ran: " .. command
			end,
		},
		{
			name = "iy_cmds",
			risk = "read",
			description = "List Infinite Yield commands, optionally filtered by a keyword or limited to "
				.. "one plugin's commands. Each line is the name, its aliases, and the plugin it came "
				.. "from (core commands show none). Use it to find the exact spelling before iy_cmd.",
			parameters = {
				type = "object",
				properties = {
					filter = { type = "string", description = "Case-insensitive substring to match against command names and aliases." },
					plugin = { type = "string", description = "Only commands from this plugin, e.g. 'emotemanager.iy'." },
					limit = { type = "integer", description = "Maximum lines. Default 80." },
				},
				required = {},
			},
			run = function(args)
				if not iy.isLoaded() then
					local ok, err = iy.ensure()
					if not ok then return H.fail(err) end
				end

				local cmds = iy.cmdsTable()
				if type(cmds) ~= "table" then return H.fail("IY is loaded but its command table is not reachable") end

				local needle = util.trim(tostring(args.filter or "")):lower()
				local pluginNeedle = util.trim(tostring(args.plugin or "")):lower()
				local shown = H.limit(args.limit, LIST_CAP, 300)

				local lines, matched, plugins = {}, 0, {}
				for _, cmd in ipairs(cmds) do
					if type(cmd) == "table" and type(cmd.NAME) == "string" then
						local name = cmd.NAME
						local nameLower = name:lower()
						local aliasHit = false
						if needle ~= "" and type(cmd.ALIAS) == "table" then
							for _, alias in ipairs(cmd.ALIAS) do
								if type(alias) == "string" and alias:lower():find(needle, 1, true) then
									aliasHit = true
									break
								end
							end
						end
						local nameMatch = needle == "" or nameLower:find(needle, 1, true) or aliasHit
						local pluginMatch = true
						if pluginNeedle ~= "" then
							local origin = type(cmd.PLUGIN) == "string" and cmd.PLUGIN:lower() or ""
							pluginMatch = origin ~= "" and origin:find(pluginNeedle, 1, true) ~= nil
						end
						if nameMatch and pluginMatch then
							matched = matched + 1
							if #lines < shown then
								local label = name
								if type(cmd.ALIAS) == "table" and #cmd.ALIAS > 0 then
									label = label .. " (alias: " .. table.concat(cmd.ALIAS, ", ") .. ")"
								end
								if type(cmd.PLUGIN) == "string" and cmd.PLUGIN ~= "" then
									label = label .. " [" .. cmd.PLUGIN .. "]"
									if not plugins[cmd.PLUGIN] then
										plugins[cmd.PLUGIN] = true
									end
								end
								lines[#lines + 1] = label
							end
						end
					end
				end

				if matched == 0 then
					return "No commands matched."
				end
				local head = string.format("%d of %d command%s matched",
					matched, #cmds, #cmds == 1 and "" or "s")
				return head .. "\n" .. H.list(lines, shown)
			end,
		},
		{
			name = "iy_plugin_search",
			risk = "read",
			needs = { "http" },
			description = "Search the Infinite Yield community plugin store (iyplugins.pages.dev, "
				.. "several hundred plugins) by name, author or filename. Returns matches with "
				.. "their authors. Use it when the user asks for a feature core IY does not have, "
				.. "then install with iy_plugin_install.",
			parameters = {
				type = "object",
				properties = {
					query = { type = "string", description = "What to look for, e.g. 'dex', 'esp', 'aimlock'." },
					limit = { type = "integer", description = "Maximum results. Default 10." },
				},
				required = { "query" },
			},
			run = function(args)
				local query = util.trim(tostring(args.query or ""))
				if query == "" then return H.fail("no query given") end

				local results, err = store.search(query, H.limit(args.limit, 10, 30))
				if not results then return H.fail(err) end
				if #results == 0 then
					return "Nothing on the store matches '" .. query .. "'."
				end

				local lines = {}
				for index, entry in ipairs(results) do
					local author = entry.author ~= "" and (" by " .. entry.author) or ""
					local file = entry.file and (" [" .. entry.file.name .. "]") or ""
					lines[#lines + 1] = entry.name .. author .. file
				end
				return string.format("%d plugin%s matched '%s':\n%s",
					#results, #results == 1 and "" or "s", query, H.list(lines, 30))
			end,
		},
		{
			name = "iy_plugin_install",
			risk = "write",
			description = "Install a plugin from the Infinite Yield store: downloads its .iy file, "
				.. "saves it to the workspace and registers it with the running Infinite Yield, "
				.. "whose commands then work through iy_cmd. Accepts the plugin name ('dexrecontinued'), "
				.. "a filename ('dexrecontinued.iy') or the store id.",
			parameters = {
				type = "object",
				properties = {
					plugin = { type = "string", description = "The plugin's name, filename or store id." },
				},
				required = { "plugin" },
			},
			run = function(args)
				local ok, result = store.install(args.plugin)
				if not ok then return H.fail(result) end
				return "Installed " .. result
					.. ". Its commands are live; list them with iy_cmds filtered by the plugin name."
			end,
		},
		{
			name = "iy_plugin_uninstall",
			risk = "write",
			description = "Remove a plugin: unregisters its commands from Infinite Yield and deletes "
				.. "its .iy file. Accepts the name with or without the .iy ending.",
			parameters = {
				type = "object",
				properties = {
					plugin = { type = "string", description = "The plugin's name or filename." },
				},
				required = { "plugin" },
			},
			run = function(args)
				local ok, result = store.uninstall(args.plugin)
				if not ok then return H.fail(result) end
				return "Removed " .. result
			end,
		},
	}
end
