-- Infinite Yield commands, native configuration, and plugin authoring.
-- The dispatcher runs commands; the event editor and live settings need their
-- own adapter because they are not exposed as commands in upstream IY.
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
	local H = env.require("tools/helpers")
	local iy = env.require("runtime/iy")
	local store = env.require("runtime/iy_store")
	local control = env.require("runtime/iy_control")
	local plugins = env.require("runtime/iy_plugins")

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
			timeout = 120,
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
			run = function(args, ctx)
				local command, commandErr = control.command(args.command)
				if not command then return H.fail(commandErr) end
				local ready, why = iy.ensure()
				if not ready then return H.fail(why) end
				command, commandErr = control.command(args.command)
				if not command then return H.fail(commandErr) end
				if ctx and ctx.aborted and ctx.aborted() then return H.fail("cancelled before dispatching the command") end

				local ok, err = iy.exec(command)
				if not ok then return H.fail(err) end
				-- execCmd spawns its own thread, so "accepted" is the honest word:
				-- a command that errors inside IY is reported by IY, not to us.
				return "Accepted by IY: " .. command .. ". Commands run asynchronously; this does not confirm completion."
			end,
		},
		{
			name = "iy_cmds",
			risk = "read",
			timeout = 120,
			description = "List Infinite Yield commands, optionally filtered by a keyword or limited to "
				.. "one plugin's commands. Shows names, aliases, plugin origin, and argument signatures "
				.. "and descriptions when IY exposes them. Use it before iy_cmd to check syntax.",
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
				local ok, err = iy.ensure()
				if not ok then return H.fail(err) end

				local cmds = iy.cmdsTable()
				if type(cmds) ~= "table" then return H.fail("IY is loaded but its command table is not reachable") end

				local needle = util.trim(tostring(args.filter or "")):lower()
				local pluginNeedle = util.trim(tostring(args.plugin or "")):lower()
				local shown = H.limit(args.limit, LIST_CAP, 300)
				local descriptions = {}
				for _, entry in ipairs(iy.descriptions() or {}) do
					if type(entry) == "table" and type(entry.NAME) == "string" and type(entry.DESC) == "string" then
						-- A slash inside [argument hints] does not introduce an alias.
						local names = entry.NAME:gsub("%b[]", "")
						for part in names:gmatch("[^/]+") do
							local token = util.trim(part):match("^(%S+)")
							if token and not descriptions[token:lower()] then
								descriptions[token:lower()] = { signature = entry.NAME, desc = entry.DESC }
							end
						end
					end
				end

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
								local description = descriptions[nameLower]
								if not description and type(cmd.ALIAS) == "table" then
									for _, alias in ipairs(cmd.ALIAS) do
										if type(alias) == "string" and descriptions[alias:lower()] then
											description = descriptions[alias:lower()]
											break
										end
									end
								end
								if description then
									label = label .. " | " .. description.signature .. " - " .. util.ellipsis(description.desc:gsub("%s+", " "), 120)
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
			name = "iy_players",
			risk = "read",
			timeout = 120,
			description = "Resolve an IY selector to concrete names in the live server (read-only). Keywords: "
				.. "all, others, me, random, #<n>, %<team>, allies, enemies, team, nonteam, friends, nonfriends, guests, "
				.. "bacons, age<n>, nearest, farthest, group<id>, alive, dead, rad<n>, cursor, npcs. "
				.. "Supports + include/- exclude, comma-separated lists, and @name for username-only prefix matching. "
				.. "Uses the running IY's selector behavior; resolve targets before iy_cmd.",
			parameters = { type = "object", properties = {
				selector = { type = "string", minLength = 1, maxLength = 1000, description = "IY selector, e.g. all, others, rad50, PlayerName." },
				limit = { type = "integer", minimum = 1, maximum = 200, description = "Maximum names shown; default 50." },
			}, required = { "selector" } },
			run = function(args, ctx)
				if type(args.selector) ~= "string" or util.trim(args.selector) == "" then return H.fail("selector must not be empty") end
				local ok, err = iy.ensure()
				if not ok then return H.fail(err) end
				if ctx and ctx.aborted and ctx.aborted() then return H.fail("cancelled before resolving players") end
				local selector = util.trim(args.selector)
				local names, reason = iy.resolvePlayers(selector)
				if not names then return H.fail(reason) end
				local text = string.format("Selector '%s' matched no players right now.", selector)
				if #names > 0 then
					text = string.format("Selector '%s' matched %d player(s):\n", selector, #names) .. H.list(names, H.limit(args.limit, 50, 200))
				end
				return { text = text, data = { names = names, count = #names } }
			end,
		},
		{
			name = "iy_control",
			risk = "write",
			timeout = 120,
			description = "Inspect and configure Infinite Yield's saved events, keybinds, aliases, waypoints and settings. "
				.. "Inspect first for current 1-based binding indexes, event fields and defaults. Supports OnExecute, OnSpawn, OnDied, "
				.. "OnDamage, OnKilled, OnJoin, OnLeave and OnChatted. Event commands can use $1/$2 arguments; native IY ignores "
				.. "commands containing 'plugin'. Edits refresh IY's editor and request its normal save. Waypoints default to the current place. "
				.. "Use iy_cmd to execute commands, iy_plugin_write for plugins/custom events. stop_loops sends breakloops.",
			parameters = {
				type = "object",
				properties = {
					action = { type = "string", enum = { "inspect", "configure", "event_add", "event_update", "event_remove", "event_clear", "event_fire", "keybind_add", "keybind_remove", "alias_add", "alias_remove", "alias_clear", "waypoint_add", "waypoint_remove", "waypoint_clear", "stop_loops" } },
					section = { type = "string", enum = { "all", "events", "keybinds", "settings", "aliases", "waypoints" }, description = "What to inspect. Default all." },
					event = { type = "string", description = "Native event name; required for event actions, optional inspect filter." },
					index = { type = "integer", minimum = 1, description = "Current 1-based binding index from inspect, for update/remove." },
					command = { type = "string", minLength = 1, maxLength = 4000, description = "IY command for events/keybinds; alias_add uses its first token as the target command name." },
					alias = { type = "string", minLength = 1, maxLength = 50, description = "Single alias name for alias_add/alias_remove." },
					name = { type = "string", minLength = 1, maxLength = 100, description = "Waypoint name for waypoint_add/waypoint_remove." },
					position = { type = "object", properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } }, required = { "x", "y", "z" }, description = "waypoint_add coordinates; omit for your current root position. Coordinates are floored." },
					all_places = { type = "boolean", description = "waypoint_clear only: also clear saved waypoints in other places. Default false." },
					persist = { type = "boolean", description = "Request IY's normal save; default true. false is session-only, except command-backed settings require saving." },
					delay = { type = "number", minimum = 0, maximum = 3600, description = "Event command delay in seconds, default 0." },
					conditions = { type = "object", properties = {
						player = { type = "string", description = "me, all, or an IY player selector. Victim for OnKilled." },
						killer = { type = "string", description = "OnKilled killer selector, default all." },
						health_below = { type = "number", minimum = 0, description = "OnDamage: health <= this threshold; 0 matches any health." },
						message = { type = "string", maxLength = 500, description = "OnChatted: case-insensitive Lua pattern; empty matches any message." },
					} },
					arguments = { type = "array", items = { type = "string" }, maxItems = 2, description = "event_fire only: actual player names and message/health in the event's field order. Health may be a numeric string." },
					key = { type = "string", description = "keybind_add: a Roblox KeyCode name such as F, or LeftClick/RightClick." },
					toggle = { type = "string", maxLength = 4000, description = "Optional command for alternating presses, e.g. unfly after fly." },
					on_release = { type = "boolean", description = "Run on key release; cannot be combined with toggle." },
					settings = { type = "object", properties = {
						mode = { type = "string", enum = { "off", "hidden", "visible" }, description = "UAI integration mode. Change this alone to enable IY before configuring it." },
						prefix = { type = "string", minLength = 1, maxLength = 8 },
						keep_open = { type = "boolean" },
						keep_on_teleport = { type = "boolean" },
						chat_logs = { type = "boolean" },
						join_logs = { type = "boolean" },
						esp_transparency = { type = "number", minimum = 0, maximum = 1 },
						gui_scale = { type = "number", minimum = 0.4, maximum = 2, description = "Dispatch IY's guiscale command; applies asynchronously and saves through IY." },
						logs_webhook = { type = "string", maxLength = 500, description = "Chat log webhook HTTP(S) URL, or empty to disable. IY's command applies asynchronously and saves." },
					} },
					offset = { type = "integer", minimum = 1, description = "Inspect continuation offset." },
					limit = { type = "integer", minimum = 1, maximum = 50, description = "Inspect page size; default 25." },
				},
				required = { "action" },
			},
			run = function(args, ctx)
				local result, err = control.run(args, ctx)
				if not result then return H.fail(err) end
				return { text = util.encode(result), data = result }
			end,
		},
		{
			name = "iy_plugin_read",
			risk = "read",
			description = "Read an authored .iy plugin from the executor workspace, or omit plugin to get a multi-command "
				.. "template. Follow nextOffset for long sources. Use this before updating a plugin with iy_plugin_write.",
			parameters = { type = "object", properties = {
				plugin = { type = "string", description = "Plain plugin filename, with or without .iy. Omit for the template." },
				offset = { type = "integer", minimum = 1 },
				limit = { type = "integer", minimum = 4, maximum = 20000, description = "Maximum source bytes; limited by the tool result budget." },
			}, required = {} },
			run = function(args)
				if not args.plugin then return H.readSlice("IY plugin template", plugins.template, args) end
				local source, err, name = plugins.read(args.plugin)
				if not source then return H.fail(err) end
				return H.readSlice(name, source, args)
			end,
		},
		{
			name = "iy_plugin_write",
			risk = "danger",
			needs = { "fs", "exec" },
			timeout = 120,
			description = "Create or update a custom Infinite Yield .iy plugin. Get the template with iy_plugin_read. "
				.. "Source may declare shared locals/globals above local Plugin, and must return a table with PluginName, "
				.. "PluginDescription and Commands. Each command has ListName, Description, Aliases and Function(args, speaker). "
				.. "Checks syntax before saving. By default executes setup once, validates the returned table and loads/reloads it "
				.. "through IY, returning actual registered command names. load=false only saves syntax-checked source. "
				.. "Set overwrite=true to replace an existing file. Reloading replaces commands; plugin-owned event connections "
				.. "or loops need cleanup in the plugin's own setup/unload command.",
			parameters = { type = "object", properties = {
				plugin = { type = "string", minLength = 1, maxLength = 83, description = "Plain filename, e.g. myplugin.iy. Paths and IY_FE.iy are refused." },
				source = { type = "string", minLength = 1, maxLength = 256000, description = "Complete Luau plugin source, including return Plugin; multiple commands and top-level globals are supported." },
				overwrite = { type = "boolean", description = "Explicitly replace an existing file; default false." },
				load = { type = "boolean", description = "Load/reload after saving. Default true; false never executes the source." },
			}, required = { "plugin", "source" } },
			run = function(args, ctx)
				local result, err = plugins.write(args, ctx)
				if not result then return H.fail(err) end
				return { text = util.encode(result), data = result }
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
			timeout = 120,
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
