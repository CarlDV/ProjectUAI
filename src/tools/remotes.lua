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

	-- Typed argument forms, so a model can pass a Vector3 or an Instance through
	-- JSON without the tool having to guess from a string's shape.
	local PREFIXES = {
		vec3 = function(text) return H.coerce(text, Vector3.new(0, 0, 0)) end,
		vector3 = function(text) return H.coerce(text, Vector3.new(0, 0, 0)) end,
		vec2 = function(text) return H.coerce(text, Vector2.new(0, 0)) end,
		color3 = function(text) return H.coerce(text, Color3.new(0, 0, 0)) end,
		cframe = function(text) return H.coerce(text, CFrame.new(0, 0, 0)) end,
		instance = function(text) return H.resolve(text) end,
		number = function(text) return tonumber(text) end,
		string = function(text) return tostring(text) end,
	}

	local function convertArgs(list)
		local out = {}
		local notes = {}
		for index, item in ipairs(list or {}) do
			if type(item) == "string" then
				local prefix, rest = item:match("^(%a+):(.*)$")
				if prefix and PREFIXES[prefix:lower()] then
					local value, err = PREFIXES[prefix:lower()](rest)
					if value == nil then
						return nil, string.format("argument %d (%s) could not be converted: %s",
							index, prefix, tostring(err or "bad value"))
					end
					out[index] = value
					notes[#notes + 1] = string.format("%d=%s", index, H.show(value))
				else
					out[index] = item
					notes[#notes + 1] = string.format("%d=%q", index, util.ellipsis(item, 40))
				end
			else
				out[index] = item
				notes[#notes + 1] = string.format("%d=%s", index, H.show(item))
			end
		end
		return out, table.concat(notes, ", "), #list
	end

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

	return {
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
			run = function(args)
				local root, err = H.resolve(args.root or "game")
				if not root then return H.fail(err) end
				local needle = util.trim(args.name):lower()

				local ok, descendants = pcall(function() return root:GetDescendants() end)
				if not ok then return H.fail("could not read that subtree") end

				local hits = {}
				for _, node in ipairs(descendants) do
					local isRemote = false
					for _, class in ipairs(REMOTE_CLASSES) do
						local okA, isA = pcall(function() return node:IsA(class) end)
						if okA and isA then isRemote = true end
					end
					if isRemote and (needle == "" or tostring(node.Name):lower():find(needle, 1, true)) then
						hits[#hits + 1] = node
					end
				end

				if #hits == 0 then return "No remotes found under " .. H.pathOf(root) .. "." end
				return string.format("%d remote(s):\n%s", #hits,
					H.list(hits, H.limit(args.limit, 30, 100), function(node)
						local suffix = ""
						if caps.fn.getconnections then
							local signalName = node:IsA("RemoteFunction") and nil or "OnClientEvent"
							if signalName then
								local okConn, connections = pcall(caps.fn.getconnections, node[signalName])
								if okConn and type(connections) == "table" then
									suffix = string.format(" (%d listener%s)", #connections, #connections == 1 and "" or "s")
								end
							end
						end
						return H.pathOf(node) .. " [" .. node.ClassName .. "]" .. suffix
					end))
			end,
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
			run = function(args)
				local remote, err = findRemote(args.path, { "RemoteEvent", "UnreliableRemoteEvent" })
				if not remote then return H.fail(err) end
				local values, notes = convertArgs(args.args)
				if not values then return H.fail(notes) end
				local ok, fireErr = pcall(function() remote:FireServer(unpack(values, 1, #(args.args or {}))) end)
				if not ok then return H.fail(tostring(fireErr)) end
				return string.format("Fired %s with %d argument(s)%s",
					H.pathOf(remote), #(args.args or {}), notes ~= "" and (": " .. notes) or "")
			end,
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
			run = function(args)
				local remote, err = findRemote(args.path, { "RemoteFunction" })
				if not remote then return H.fail(err) end
				local values, notes = convertArgs(args.args)
				if not values then return H.fail(notes) end

				local finished, ok, result = clock.timeout(8, function()
					return remote:InvokeServer(unpack(values, 1, #(args.args or {})))
				end)
				if not finished then
					return "The server did not answer within 8 seconds. The call is still outstanding."
				end
				if not ok then return H.fail(tostring(result)) end
				return string.format("%s returned: %s%s",
					H.pathOf(remote), H.show(result), notes ~= "" and ("\nSent: " .. notes) or "")
			end,
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
	}
end
