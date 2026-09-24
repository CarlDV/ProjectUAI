-- Shared diagnostic paths. Bracket segments are JSON, never executable source.
return function(env)
	local util = env.require("runtime/util")
	local M = {}
	local ROOTS = {
		game = function() return game end,
		workspace = function() return env.services.Workspace end,
		players = function() return env.services.Players end,
		lighting = function() return env.services.Lighting end,
		replicatedstorage = function() return env.services.ReplicatedStorage end,
		replicatedfirst = function() return env.services.ReplicatedFirst end,
		starterplayer = function() return env.services.StarterPlayer end,
		startergui = function() return env.services.StarterGui end,
		soundservice = function() return env.services.SoundService end,
		teams = function() return env.services.Teams end,
		me = function() return env.plr end,
		localplayer = function() return env.plr end,
		character = function() return env.plr and env.plr.Character end,
		playergui = function() return env.plr and env.plr:FindFirstChild("PlayerGui") end,
		camera = function() return env.services.Workspace.CurrentCamera end,
	}

	M.ROOT_NAMES = { "game", "workspace", "players", "lighting", "me", "character", "playergui", "camera" }

	-- Bracket segments are JSON strings, never executable Luau. They make names
	-- containing dots, quotes or brackets round-trip through every path tool.
	local function segmentsOf(text)
		local parts, at = {}, 1
		if #text > 4096 then return nil, "instance path is too long" end
		while at <= #text do
			if text:sub(at, at) == "[" then
				at = at + 1
				while text:sub(at, at):match("%s") do at = at + 1 end
				if text:sub(at, at) ~= '"' then return nil, 'use ["exact name"] for a bracketed path segment' end
				local start = at
				at = at + 1
				while at <= #text do
					local char = text:sub(at, at)
					if char == "\\" then at = at + 2
					elseif char == '"' then break
					else at = at + 1 end
				end
				local value = util.decode(text:sub(start, at))
				if type(value) ~= "string" then return nil, "invalid quoted instance name" end
				parts[#parts + 1] = value
				at = at + 1
				while text:sub(at, at):match("%s") do at = at + 1 end
				if text:sub(at, at) ~= "]" then return nil, "unclosed bracket in instance path" end
				at = at + 1
			else
				local finish = text:find("[%.%[%]]", at) or (#text + 1)
				if finish == at then return nil, "empty or malformed instance path segment" end
				parts[#parts + 1] = text:sub(at, finish - 1)
				at = finish
			end
			if at <= #text then
				local char = text:sub(at, at)
				if char == "." then
					at = at + 1
					if at > #text or text:sub(at, at) == "[" then return nil, "empty instance path segment" end
				elseif char ~= "[" then return nil, "invalid instance path separator" end
			end
		end
		return parts
	end

	local INSTANCE_LINKS = { Character = true, CurrentCamera = true, PrimaryPart = true }

	-- "Workspace.Folder.Part", "game.Players.Someone", "me.Character.Humanoid".
	--
	-- A leading `game.` is optional, service names resolve through GetService (so a
	-- renamed service instance still works), and a segment that is not a child is
	-- reported with the path that did resolve -- which is the difference between a
	-- model fixing its own typo and a model guessing again.
	function M.resolve(path)
		local text = util.trim(path)
		if text == "" then return nil, "no path given" end

		local segments, parseErr = segmentsOf(text)
		if not segments then return nil, parseErr end
		if #segments == 0 then return nil, "no path given" end

		local first = tostring(segments[1]):lower()
		local node
		if ROOTS[first] then
			node = ROOTS[first]()
			if not node then return nil, "'" .. segments[1] .. "' does not exist right now" end
			table.remove(segments, 1)
		else
			-- Try it as a service name before giving up.
			local ok, service = pcall(function() return game:GetService(segments[1]) end)
			if ok and service then
				node = service
				table.remove(segments, 1)
			else
				node = env.services.Workspace
			end
		end

		local walked = { node.Name }
		for _, segment in ipairs(segments) do
			local ambiguous = false
			local okChild, child = pcall(function()
				local found
				for _, candidate in ipairs(node:GetChildren()) do if candidate.Name == segment then if found then ambiguous = true; break end; found = candidate end end
				return found
			end)
			if ambiguous then return nil, "Ambiguous path segment '" .. segment .. "'; inspect children and use an instance_id" end
			if not okChild then return nil, "could not inspect '" .. table.concat(walked, ".") .. "'" end
			if not child and node == game then
				local okService, service = pcall(function() return game:GetService(segment) end)
				if okService then child = service end
			end
			if not child and INSTANCE_LINKS[segment] then
				local okLink, linked = pcall(function() return node[segment] end)
				if okLink and typeof(linked) == "Instance" then child = linked end
			end
			if not child then
				return nil, string.format("'%s' has no child named '%s'",
					table.concat(walked, "."), segment)
			end
			node = child
			walked[#walked + 1] = segment
		end
		return node
	end

	function M.pathOf(instance)
		if not instance then return "nil" end
		local ok, name = pcall(function()
			local parts, node, depth = {}, instance, 0
			while node and node ~= game do
				depth = depth + 1
				if depth > 256 then return instance:GetFullName() end
				table.insert(parts, 1, tostring(node.Name))
				node = node.Parent
			end
			if #parts == 0 then return "game" end
			local out = ""
			for index, part in ipairs(parts) do
				if part == "" or part:find('[%.%[%]"\\%c]') or part:match("^%s") or part:match("%s$") then
					out = out .. "[" .. util.encode(part) .. "]"
				else
					out = out .. (index > 1 and "." or "") .. part
				end
			end
			return out
		end)
		return ok and name or tostring(instance)
	end

	return M
end
