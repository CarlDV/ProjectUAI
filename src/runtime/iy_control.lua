-- Native IY configuration, using the event editor's SaveData/LoadData contract.
-- Source reviewed: EdgeIY/infiniteyield master/source, 2026-09-20. Event entries
-- are { command, ordered filters, delay }; player 0 means self and 1 means all.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local iy = env.require("runtime/iy")
	local M = {}

	local EVENTS = {
		{ name = "OnExecute", fields = {}, defaults = {} },
		{ name = "OnSpawn", fields = { "player" }, defaults = { 0 } },
		{ name = "OnDied", fields = { "player" }, defaults = { 0 } },
		{ name = "OnDamage", fields = { "player", "health_below" }, defaults = { 0, 0 } },
		{ name = "OnKilled", fields = { "player", "killer" }, defaults = { 0, 1 } },
		{ name = "OnJoin", fields = { "player" }, defaults = { 1 } },
		{ name = "OnLeave", fields = { "player" }, defaults = { 1 } },
		{ name = "OnChatted", fields = { "player", "message" }, defaults = { 1, 0 } },
	}
	local SETTINGS = {
		prefix = { global = "prefix", kind = "string" },
		keep_open = { global = "StayOpen", kind = "boolean" },
		keep_on_teleport = { global = "KeepInfYield", kind = "boolean" },
		chat_logs = { global = "logsEnabled", kind = "boolean" },
		join_logs = { global = "jLogsEnabled", kind = "boolean" },
		esp_transparency = { global = "espTransparency", kind = "number", min = 0, max = 1 },
	}
	local COMMAND_SETTINGS = { gui_scale = "guiscale", logs_webhook = "chatlogswebhook" }
	local function finite(value)
		return type(value) == "number" and value == value and value > -math.huge and value < math.huge
	end
	local function cancelled(ctx)
		return ctx and ctx.aborted and ctx.aborted()
	end
	local function refresh(fn)
		if type(fn) == "function" then
			local ok, err = pcall(fn)
			if not ok then return tostring(err) end
		end
	end
	local function persist(wanted)
		if wanted == false then return "session only" end
		if iy.value("nosaves") ~= false or not caps.fn.writefile then return "session only: IY saving is unavailable" end
		local save = iy.value("updatesaves")
		if type(save) ~= "function" then return "session only: IY's save function is unavailable" end
		local ok, err = pcall(save)
		-- updatesaves queues an asynchronous write; it does not acknowledge disk I/O.
		return ok and "save requested through IY" or ("live, but saving failed: " .. tostring(err))
	end
	local function changed(args, detail, warning)
		return { action = args.action, result = detail, persistence = persist(args.persist), warning = warning }
	end
	local function findCommand(name)
		for _, entry in ipairs(iy.cmdsTable() or {}) do
			if type(entry) == "table" and type(entry.NAME) == "string" then
				if entry.NAME:lower() == name then return entry end
				if type(entry.ALIAS) == "table" then
					for _, alias in ipairs(entry.ALIAS) do
						if type(alias) == "string" and alias:lower() == name then return entry end
					end
				end
			end
		end
	end
	local function named(value, label, maximum)
		if type(value) ~= "string" then return nil, label .. " must be a string" end
		value = util.trim(value)
		if value == "" or #value > maximum or value:find("%c") then
			return nil, label .. " must contain 1-" .. maximum .. " bytes without control characters"
		end
		return value
	end
	local function clearTable(list)
		for key in pairs(list) do list[key] = nil end
	end
	local function removeWhere(list, matches)
		local removed = 0
		for index = #list, 1, -1 do
			if matches(list[index]) then table.remove(list, index); removed = removed + 1 end
		end
		return removed
	end

	function M.command(value)
		if type(value) ~= "string" then return nil, "command must be a string" end
		local command = util.trim(value)
		local prefix = iy.value("prefix")
		if type(prefix) == "string" and prefix ~= "" and command:sub(1, #prefix) == prefix then
			command = util.trim(command:sub(#prefix + 1))
		elseif command:sub(1, 1) == ";" then command = util.trim(command:sub(2)) end
		if command == "" or #command > 4000 then return nil, "command must contain 1–4000 bytes" end
		return command
	end

	local function eventData()
		local editor = iy.value("eventEditor")
		if type(editor) ~= "table" or type(editor.SaveData) ~= "function" or type(editor.LoadData) ~= "function" then
			return nil, "this IY does not expose its event editor"
		end
		local ok, source = pcall(editor.SaveData)
		if not ok then return nil, "could not read IY events: " .. tostring(source) end
		local data, err = util.decode(source)
		if type(data) ~= "table" then return nil, "invalid IY event data: " .. tostring(err) end
		return data, nil, editor
	end
	local function eventSpec(name)
		for _, spec in ipairs(EVENTS) do
			if spec.name:lower() == tostring(name or ""):lower() then return spec end
		end
	end
	local function indexOf(value, list)
		return finite(value) and value == math.floor(value) and value >= 1 and value <= #list and value or nil
	end
	local function filtersFor(spec, values, previous)
		if values ~= nil and type(values) ~= "table" then return nil, "conditions must be an object" end
		local out, allowed = util.deepCopy(previous or spec.defaults), {}
		for index, field in ipairs(spec.fields) do
			allowed[field] = true
			local value = values and values[field]
			if value ~= nil then
				if field == "player" or field == "killer" then
					if type(value) ~= "string" or util.trim(value) == "" or #value > 200 then
						return nil, field .. " must be me, all, or an IY player selector"
					end
					value = util.trim(value)
					if value:lower() == "me" then value = 0 elseif value:lower() == "all" then value = 1 end
				elseif field == "health_below" then
					if not finite(value) or value < 0 then return nil, "health_below must be a nonnegative number (0 matches any health)" end
				elseif field == "message" then
					if type(value) ~= "string" or #value > 500 then return nil, "message must be a Lua pattern of at most 500 bytes" end
					local ok, err = pcall(string.find, "", value:lower())
					if not ok then return nil, "invalid message pattern: " .. tostring(err) end
					if value == "" then value = 0 end
				end
				out[index] = value
			end
		end
		for field in pairs(values or {}) do
			if not allowed[field] then return nil, spec.name .. " has no " .. tostring(field) .. " condition" end
		end
		return out
	end

	local function inspect(args)
		local out = { mode = iy.getMode() }
		local section = args.section or "all"
		if section ~= "all" and section ~= "events" and section ~= "keybinds" and section ~= "settings" and section ~= "aliases" and section ~= "waypoints" then
			return nil, "section must be all, events, keybinds, settings, aliases, or waypoints"
		end
		local limit = math.max(1, math.min(50, math.floor(tonumber(args.limit) or 25)))
		local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
		if section == "all" or section == "events" then
			local data, err = eventData()
			if data then
				local bindings, total, definitions = {}, 0, {}
				for _, name in ipairs(util.keys(data, true)) do
					if type(name) == "string" and type(data[name]) == "table" then
						local spec = eventSpec(name)
						definitions[#definitions + 1] = { name = name, fields = spec and spec.fields,
							defaults = spec and spec.defaults, count = #data[name] }
						if not args.event or name:lower() == args.event:lower() then
							for index, binding in ipairs(data[name]) do
								total = total + 1
								if total >= offset and #bindings < limit then
									bindings[#bindings + 1] = { event = name, index = index, command = binding[1], filters = binding[2], delay = binding[3] or 0 }
								end
							end
						end
					end
				end
				out.events = { definitions = definitions, bindings = bindings, total = total,
					nextOffset = offset + #bindings <= total and offset + #bindings or nil }
			else out.events = { unavailable = err } end
		end
		if section == "all" or section == "keybinds" then
			local binds = iy.value("binds")
			if type(binds) == "table" then
				local items = {}
				for index = offset, math.min(#binds, offset + limit - 1) do
					local bind = binds[index]
					items[#items + 1] = { index = index, key = bind.KEY, command = bind.COMMAND, on_release = bind.ISKEYUP == true, toggle = bind.TOGGLE }
				end
				out.keybinds = { items = items, total = #binds, nextOffset = offset + #items <= #binds and offset + #items or nil }
			else out.keybinds = { unavailable = "IY's keybind table is not exposed" } end
		end
		if section == "all" or section == "aliases" then
			local aliases = iy.value("aliases")
			if type(aliases) == "table" then
				local items = {}
				for index = offset, math.min(#aliases, offset + limit - 1) do
					local entry, item = aliases[index], { index = index }
					if type(entry) == "table" and type(entry.CMD) == "string" and type(entry.ALIAS) == "string" then
						item.command, item.alias = entry.CMD, entry.ALIAS
					else item.malformed = "expected CMD and ALIAS strings" end
					items[#items + 1] = item
				end
				out.aliases = { items = items, total = #aliases, nextOffset = offset + #items <= #aliases and offset + #items or nil }
			else out.aliases = { unavailable = "IY's alias table is not exposed" } end
		end
		if section == "all" or section == "waypoints" then
			local waypoints, all = iy.value("WayPoints"), iy.value("AllWaypoints")
			if type(waypoints) == "table" then
				local items = {}
				for index = offset, math.min(#waypoints, offset + limit - 1) do
					local entry, item = waypoints[index], { index = index }
					local coord = type(entry) == "table" and entry.COORD
					if type(entry) == "table" and type(entry.NAME) == "string" and type(coord) == "table" and finite(coord[1]) and finite(coord[2]) and finite(coord[3]) then
						item.name, item.x, item.y, item.z = entry.NAME, coord[1], coord[2], coord[3]
					else item.malformed = "expected NAME and three finite COORD numbers" end
					items[#items + 1] = item
				end
				out.waypoints = { items = items, total = #waypoints, placeId = iy.value("PlaceId"),
					allPlacesTotal = type(all) == "table" and #all or nil,
					nextOffset = offset + #items <= #waypoints and offset + #items or nil }
			else out.waypoints = { unavailable = "IY's waypoint table is not exposed" } end
		end
		if section == "all" or section == "settings" then
			out.settings = {}
			for key, spec in pairs(SETTINGS) do out.settings[key] = iy.value(spec.global) end
			out.settings.gui_scale = iy.value("guiScale")
			out.settings.logs_webhook = iy.value("logsWebhook") or ""
			out.saving = iy.value("nosaves") == false and type(iy.value("updatesaves")) == "function"
		end
		return out
	end

	local function configure(args, ctx)
		if type(args.settings) ~= "table" or next(args.settings) == nil then return nil, "provide settings to change" end
		for key, value in pairs(args.settings) do
			local spec = SETTINGS[key]
			if key == "mode" then
				if value ~= "off" and value ~= "hidden" and value ~= "visible" then return nil, "invalid IY mode" end
			elseif COMMAND_SETTINGS[key] then
				if args.persist == false then return nil, key .. " uses an IY command that saves automatically; omit persist=false" end
				if key == "gui_scale" then
					if not finite(value) or value < 0.4 or value > 2 then return nil, "gui_scale must be between 0.4 and 2" end
				elseif type(value) ~= "string" or #value > 500 or (value ~= "" and (not value:match("^https?://[^/%s?#]+") or value:find("[%s%c\\]"))) then
					return nil, "logs_webhook must be an HTTP(S) URL without whitespace or backslashes, or empty to disable"
				end
			elseif not spec then return nil, "unknown IY setting: " .. tostring(key)
			elseif type(value) ~= spec.kind then return nil, key .. " must be " .. spec.kind
			elseif spec.kind == "number" and (not finite(value) or value < spec.min or value > spec.max) then
				return nil, key .. " is outside its supported range"
			elseif key == "prefix" and (#value < 1 or #value > 8 or value:find("%s")) then
				return nil, "prefix must be 1–8 characters without whitespace"
			end
		end
		local mode = args.settings.mode
		if mode and util.count(args.settings) == 1 then
			if cancelled(ctx) then return nil, "cancelled before changing IY" end
			iy.setMode(mode)
			return { action = args.action, settings = args.settings, persistence = "integration mode saved in UAI" }
		end
		if mode == "off" then return nil, "set IY settings before switching the integration off" end
		local ok, err = iy.ensure()
		if not ok then return nil, err end
		if cancelled(ctx) then return nil, "cancelled before changing IY" end
		for key in pairs(args.settings) do
			if COMMAND_SETTINGS[key] then
				if not findCommand(COMMAND_SETTINGS[key]) then return nil, "this IY does not expose command " .. COMMAND_SETTINGS[key] end
			elseif key ~= "mode" and type(iy.value(SETTINGS[key].global)) ~= SETTINGS[key].kind then
				return nil, "this IY does not expose setting " .. key
			end
		end
		local dispatched = {}
		for _, key in ipairs({ "gui_scale", "logs_webhook" }) do
			local value = args.settings[key]
			if value ~= nil then
				local command = COMMAND_SETTINGS[key] .. (value == "" and "" or (" " .. tostring(value)))
				local accepted, reason = iy.exec(command)
				if not accepted then
					return nil, "could not dispatch " .. key .. ": " .. tostring(reason)
						.. (#dispatched > 0 and "; earlier commands were accepted and may still apply" or "")
				end
				dispatched[#dispatched + 1] = command
			end
		end
		for key, value in pairs(args.settings) do
			if key == "mode" then iy.setMode(value)
			elseif not COMMAND_SETTINGS[key] then iy.assign(SETTINGS[key].global, value) end
		end
		-- Keep IY's own visible controls in sync with the live values.
		local function property(name, key, value)
			local instance = iy.value(name)
			if instance then pcall(function() instance[key] = value end) end
		end
		if args.settings.prefix then
			property("PrefixBox", "Text", args.settings.prefix)
			property("Cmdbar", "PlaceholderText", "Command Bar (" .. args.settings.prefix .. ")")
		end
		if args.settings.keep_open ~= nil then property("On", "BackgroundTransparency", args.settings.keep_open and 0 or 1) end
		if args.settings.chat_logs ~= nil then property("Toggle", "Text", args.settings.chat_logs and "Enabled" or "Disabled") end
		if args.settings.join_logs ~= nil then property("Toggle_2", "Text", args.settings.join_logs and "Enabled" or "Disabled") end
		local result = changed(args, args.settings, #dispatched > 0 and "IY applies the dispatched commands asynchronously and requests its own saves; inspect settings to confirm." or nil)
		if #dispatched > 0 then result.dispatched = dispatched end
		return result
	end

	function M.run(args, ctx)
		if args.action == "configure" then return configure(args, ctx) end
		local ok, err = iy.ensure()
		if not ok then return nil, err end
		if cancelled(ctx) then return nil, "cancelled before changing IY" end
		if args.action == "inspect" then return inspect(args) end
		if args.action == "stop_loops" then
			local accepted, reason = iy.exec("breakloops")
			if not accepted then return nil, reason end
			return { result = "Accepted breakloops; this stops IY repeat prefixes, not event bindings or individual commands' own loops." }
		end
		if tostring(args.action):sub(1, 6) == "event_" then
			local spec = eventSpec(args.event)
			if not spec then return nil, "choose a native IY event from inspect; custom events can be defined by an IY plugin" end
			local data, reason, editor = eventData()
			if not data then return nil, reason end
			local list = data[spec.name]
			if type(list) ~= "table" then return nil, spec.name .. " is not registered in this IY" end
			if args.action == "event_fire" then
				if type(editor.FireEvent) ~= "function" then return nil, "IY's event dispatcher is unavailable" end
				local values = args.arguments or {}
				if type(values) ~= "table" or not util.isArray(values) or #values ~= #spec.fields then
					return nil, "arguments must match the event fields in order: " .. table.concat(spec.fields, ", ")
				end
				for index, field in ipairs(spec.fields) do
					if field == "health_below" then
						if not finite(tonumber(values[index])) then return nil, "health argument must be a number" end
						values[index] = tonumber(values[index])
					elseif type(values[index]) ~= "string" then return nil, field .. " argument must be a string" end
				end
				local fired, fireErr = pcall(editor.FireEvent, spec.name, unpack(values))
				if not fired then return nil, "IY rejected the event: " .. tostring(fireErr) end
				return { result = "Accepted " .. spec.name .. "; matching commands run asynchronously." }
			end
			local index = indexOf(args.index, list)
			if args.action == "event_remove" then
				if not index then return nil, "binding index is out of range; inspect events again" end
				table.remove(list, index)
			elseif args.action == "event_clear" then data[spec.name] = {}
			elseif args.action == "event_add" or args.action == "event_update" then
				if args.action == "event_update" and not index then return nil, "binding index is out of range; inspect events again" end
				if args.action == "event_add" and #list >= 100 then return nil, "this event already has 100 bindings" end
				local previous = args.action == "event_update" and list[index] or nil
				local command, commandErr = M.command(args.command or (previous and previous[1]))
				if not command then return nil, commandErr end
				if command:lower():find("plugin", 1, true) then return nil, "IY ignores event commands containing 'plugin'; use the plugin tools to load plugins" end
				local filters, filterErr = filtersFor(spec, args.conditions, previous and previous[2])
				if not filters then return nil, filterErr end
				local delay = args.delay
				if delay == nil then delay = previous and previous[3] or 0 end
				if not finite(delay) or delay < 0 or delay > 3600 then return nil, "delay must be between 0 and 3600 seconds" end
				index = previous and index or #list + 1
				list[index] = { command, filters, delay }
			else return nil, "unknown event action" end
			local loaded, loadErr = pcall(editor.LoadData, util.encode(data))
			if not loaded then return nil, "IY could not apply the event data: " .. tostring(loadErr) end
			return changed(args, { event = spec.name, index = index, count = #data[spec.name] }, refresh(editor.Refresh))
		end
		if args.action == "keybind_add" or args.action == "keybind_remove" then
			local binds = iy.value("binds")
			if type(binds) ~= "table" then return nil, "IY's keybind table is unavailable" end
			local index
			if args.action == "keybind_remove" then
				index = indexOf(args.index, binds)
				if not index then return nil, "keybind index is out of range; inspect keybinds again" end
				local toggles = iy.value("toggleOn")
				if type(toggles) == "table" then toggles[binds[index]] = nil end
				table.remove(binds, index)
			else
				if #binds >= 100 then return nil, "IY already has 100 keybinds" end
				local key = tostring(args.key or ""):gsub("^Enum%.KeyCode%.", "")
				if key ~= "LeftClick" and key ~= "RightClick" then
					local valid, enum = pcall(function() return Enum.KeyCode[key] end)
					if not valid or not enum or key == "Unknown" then return nil, "key must be a Roblox KeyCode name, LeftClick, or RightClick" end
					key = tostring(enum)
				end
				local command, commandErr = M.command(args.command)
				if not command then return nil, commandErr end
				local toggle
				if args.toggle then
					toggle, commandErr = M.command(args.toggle)
					if not toggle then return nil, commandErr end
					if args.on_release then return nil, "toggle bindings run on key press, not release" end
				end
				for i, bind in ipairs(binds) do
					if bind.KEY == key and bind.COMMAND == command and bind.TOGGLE == toggle and (bind.ISKEYUP == true) == (args.on_release == true) then
						return { result = "Keybind already exists", index = i }
					end
				end
				index = #binds + 1
				binds[index] = { COMMAND = command, KEY = key, ISKEYUP = args.on_release == true, TOGGLE = toggle }
			end
			return changed(args, { index = index, count = #binds }, refresh(iy.value("refreshbinds")))
		end
		if args.action == "alias_add" or args.action == "alias_remove" or args.action == "alias_clear" then
			local aliases, custom = iy.value("aliases"), iy.value("customAlias")
			if type(aliases) ~= "table" or type(custom) ~= "table" then return nil, "IY's alias tables are unavailable" end
			local alias, command
			if args.action == "alias_clear" then
				clearTable(custom)
				clearTable(aliases)
			else
				alias, err = named(args.alias, "alias", 50)
				if not alias then return nil, err end
				alias = alias:lower()
				if args.action == "alias_add" then
					local prefix = iy.value("prefix")
					if alias:find("[%s\\%^]") or alias:find("^[;!]") or (type(prefix) == "string" and prefix ~= "" and alias:sub(1, #prefix) == prefix:lower()) then
						return nil, "alias must be one command token without an IY prefix, history/repeat marker, or command separator"
					end
					if custom[alias] ~= nil then return nil, "alias '" .. alias .. "' already exists" end
					for _, entry in ipairs(aliases) do
						if type(entry) == "table" and type(entry.ALIAS) == "string" and entry.ALIAS:lower() == alias then return nil, "alias '" .. alias .. "' already exists" end
					end
					if findCommand(alias) then return nil, "alias '" .. alias .. "' conflicts with an IY command" end
					command, err = M.command(args.command)
					if not command then return nil, err end
					command = command:match("^(%S+)"):lower()
					local entry = findCommand(command)
					if not entry then return nil, "no IY command named '" .. command .. "' to alias" end
					custom[alias] = entry
					aliases[#aliases + 1] = { CMD = command, ALIAS = alias }
				else
					if custom[alias] == nil then return nil, "no such alias: " .. alias end
					custom[alias] = nil
					removeWhere(aliases, function(entry) return type(entry) == "table" and type(entry.ALIAS) == "string" and entry.ALIAS:lower() == alias end)
				end
			end
			return changed(args, { alias = alias, command = command, count = #aliases }, refresh(iy.value("refreshaliases")))
		end
		if args.action == "waypoint_add" or args.action == "waypoint_remove" or args.action == "waypoint_clear" then
			local waypoints, all = iy.value("WayPoints"), iy.value("AllWaypoints")
			if type(waypoints) ~= "table" then return nil, "IY's waypoint table is unavailable" end
			local placeId = iy.value("PlaceId")
			if not finite(placeId) then placeId = 0 end
			local function inPlace(entry)
				return type(entry) == "table" and (entry.GAME == nil or entry.GAME == placeId)
			end
			local name
			if args.action ~= "waypoint_clear" then
				name, err = named(args.name, "name", 100)
				if not name then return nil, err end
			end
			local removed, savedRemoved
			if args.action == "waypoint_add" then
				-- IY's GUI inserts the name into loadpos/delete command strings.
				if name:find("\\", 1, true) then return nil, "waypoint names must not contain IY's backslash command separator" end
				local x, y, z
				if args.position ~= nil then
					if type(args.position) ~= "table" then return nil, "position must contain finite x, y, z numbers" end
					x, y, z = args.position.x, args.position.y, args.position.z
					if not finite(x) or not finite(y) or not finite(z) then return nil, "position must contain finite x, y, z numbers" end
				else
					local found
					found, x, y, z = pcall(function()
						local getRoot = iy.value("getRoot")
						if type(getRoot) ~= "function" then return end
						local root = getRoot(env.plr and env.plr.Character)
						local position = root and root.Position
						if position then return position.X, position.Y, position.Z end
					end)
					if not found or not finite(x) or not finite(y) or not finite(z) then return nil, "no position given and your character has no root part" end
				end
				if cancelled(ctx) then return nil, "cancelled before changing IY" end
				local entry = { NAME = name, COORD = { math.floor(x), math.floor(y), math.floor(z) }, GAME = placeId }
				waypoints[#waypoints + 1] = entry
				if type(all) == "table" and all ~= waypoints then all[#all + 1] = util.deepCopy(entry) end
			elseif args.action == "waypoint_remove" then
				local function matches(entry)
					return type(entry) == "table" and type(entry.NAME) == "string" and entry.NAME:lower() == name:lower()
				end
				removed = removeWhere(waypoints, matches)
				if type(all) == "table" and all ~= waypoints then
					savedRemoved = removeWhere(all, function(entry) return inPlace(entry) and matches(entry) end)
				end
				if removed + (savedRemoved or 0) == 0 then return nil, "no waypoint named '" .. name .. "' in this place" end
			else
				removed = #waypoints
				clearTable(waypoints)
				if type(all) == "table" and all ~= waypoints then
					if args.all_places == true then savedRemoved = #all; clearTable(all)
					else savedRemoved = removeWhere(all, inPlace) end
				end
			end
			return changed(args, { name = name, count = #waypoints, placeId = placeId, removed = removed, savedRemoved = savedRemoved,
				all_places = args.action == "waypoint_clear" and args.all_places == true or nil }, refresh(iy.value("refreshwaypoints")))
		end
		return nil, "unknown IY control action"
	end
	return M
end
