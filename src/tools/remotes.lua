-- Remotes: find them, call them, watch what the server sends.
--
-- Firing a remote is the single most consequential thing in this toolset -- it is
-- the one that talks to the server, so it is the one that can get an account
-- actioned. Both call tools are marked dangerous and neither guesses at argument
-- types: the model states them.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")

	local REMOTE_CLASSES = { "RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent" }

	local native = env.require("tools/remote_native")

	local function findRemote(path, wanted)
		local instance, err = H.resolve(path)
		if not instance then return nil, err end
		local matches = false
		for _, class in ipairs(wanted or REMOTE_CLASSES) do
			local ok, isA = pcall(function() return instance:IsA(class) end)
			if ok and isA then matches = true end
		end
		if not matches then
			return nil, string.format("%s is a %s, not a %s", H.pathOf(instance), instance.ClassName,
				table.concat(wanted or REMOTE_CLASSES, " or "))
		end
		return instance
	end

	local tools = {
		{
			name = "remotes_list",
			risk = "read",
			description = "Find remotes in the place, with how many client-side listeners each has when the host can tell.",
			parameters = {
				type = "object",
				properties = {
					root = { type = "string", description = "Where to search. Defaults to game." },
					name = { type = "string", description = "Substring filter on the remote name." },
					limit = { type = "integer", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = native.run.remotes_list,
		},
		{
			name = "remote_fire",
			risk = "danger",
			description = "Fire a RemoteEvent to the server. This is a real server call: it can change the game and can be logged or punished by anticheat. Prefix an argument with a type when it is not a plain string or number, e.g. 'vec3:0, 10, 0' or 'instance:Workspace.Door'.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to the RemoteEvent." },
					args = {
						type = "array",
						description = "Arguments in order. Strings, numbers, booleans, or a typed form such as 'vec3:1, 2, 3'.",
						-- `items` is a schema, so it has to encode as {} and not as [].
						-- An empty one means "any value", which is the intent here.
						items = util.emptyObject(),
					},
				},
				required = { "path" },
			},
			run = native.run.remote_fire,
		},
		{
			name = "remote_invoke",
			risk = "danger",
			description = "Invoke a RemoteFunction and return what the server answers. Blocks until it replies, and can hang if the server never does.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					args = { type = "array", items = util.emptyObject() },
				},
				required = { "path" },
			},
			run = native.run.remote_invoke,
		},
		{
			name = "remote_watch",
			risk = "read",
			description = "Listen to a RemoteEvent and report the next few things the server sends through it. Useful for learning a remote's argument shape before firing it.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					count = { type = "integer", description = "Calls to capture, 1-10. Default 3.", minimum = 1, maximum = 10 },
					timeout = { type = "number", description = "Seconds to wait, 1-20. Default 8.", minimum = 1, maximum = 20 },
				},
				required = { "path" },
			},
			run = function(args, ctx)
				local remote, err = findRemote(args.path, { "RemoteEvent", "UnreliableRemoteEvent" })
				if not remote then return H.fail(err) end

				local wanted = H.limit(args.count, 3, 10)
				local limit = util.clamp(tonumber(args.timeout) or 8, 1, 20)
				local captured = {}

				local connection = remote.OnClientEvent:Connect(function(...)
					if #captured >= wanted then return end
					local parts = {}
					for index = 1, select("#", ...) do
						parts[#parts + 1] = string.format("%d: %s", index, H.show((select(index, ...))))
					end
					captured[#captured + 1] = #parts > 0 and table.concat(parts, ", ") or "(no arguments)"
				end)

				local waited = 0
				while #captured < wanted and waited < limit do
					if ctx and ctx.aborted and ctx.aborted() then break end
					waited = waited + (clock.wait(0.1) or 0.1)
				end
				pcall(function() connection:Disconnect() end)

				if #captured == 0 then
					return string.format("%s sent nothing in %.0f seconds.", H.pathOf(remote), waited)
				end
				return string.format("%s fired %d time(s) in %.1fs:\n%s",
					H.pathOf(remote), #captured, waited, H.list(captured, wanted))
			end,
		},
		{
			name = "signal_watch",
			risk = "read",
			description = "Listen to any instance signal for a short window and report what fired, with argument shapes. Unlike remote_watch this works on ordinary RBXScriptSignals -- Touched, Changed, ChildAdded, MouseButton1Click -- so a game's wiring can be understood without firing anything at the server.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Dotted path to the instance." },
					signal = { type = "string", description = "Signal name, e.g. 'Touched', 'Changed', 'ChildAdded'." },
					count = { type = "integer", description = "Events to capture, 1-10. Default 3.", minimum = 1, maximum = 10 },
					timeout = { type = "number", description = "Seconds to wait, 1-20. Default 8.", minimum = 1, maximum = 20 },
				},
				required = { "path", "signal" },
			},
			run = function(args, ctx)
				local instance, err = H.resolve(args.path)
				if not instance then return H.fail(err) end

				local signalName = util.trim(tostring(args.signal or ""))
				if signalName == "" then return H.fail("no signal name given") end

				local wanted = H.limit(args.count, 3, 10)
				local limit = util.clamp(tonumber(args.timeout) or 8, 1, 20)
				local captured = {}

				-- Reading the signal is the risk-free half; connecting to it is where
				-- hosts differ, so both the read and the connect are guarded.
				local okSignal, target = pcall(function() return instance[signalName] end)
				if not okSignal or not target then
					return H.fail(instance.ClassName .. " has no signal named '" .. signalName .. "'")
				end
				local okConnect, connection = pcall(function()
					return target:Connect(function(...)
						if #captured >= wanted then return end
						local parts = {}
						for index = 1, select("#", ...) do
							parts[#parts + 1] = string.format("%d: %s", index, H.show((select(index, ...))))
						end
						captured[#captured + 1] = #parts > 0 and table.concat(parts, ", ") or "(no arguments)"
					end)
				end)
				if not okConnect or not connection then
					return H.fail("could not connect to " .. signalName .. " on " .. H.pathOf(instance))
				end

				local waited = 0
				while #captured < wanted and waited < limit do
					if ctx and ctx.aborted and ctx.aborted() then break end
					waited = waited + (clock.wait(0.1) or 0.1)
				end
				pcall(function() connection:Disconnect() end)

				if #captured == 0 then
					return string.format("%s.%s fired nothing in %.0f seconds.", H.pathOf(instance), signalName, waited)
				end
				return string.format("%s.%s fired %d time(s) in %.1fs:\n%s",
					H.pathOf(instance), signalName, #captured, waited, H.list(captured, wanted))
			end,
		},
	}
	for _, tool in ipairs(tools) do native.extend(tool) end
	for _, tool in ipairs(env.require("tools/remote_capture")) do tools[#tools + 1] = tool end
	env.require("tools/native_helpers").addReader(tools, "remotes")
	return tools
end
