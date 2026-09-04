-- Other players: who is here, what state they are in, and getting to them.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")

	-- Name matching is a case-insensitive substring over both the username and the
	-- display name, because a model working from chat has usually seen the display
	-- name and the two are frequently different.
	local function findPlayer(query)
		local needle = util.trim(query):lower()
		if needle == "" then return nil, "give a player name" end
		local matches = {}
		for _, player in ipairs(env.players:GetPlayers()) do
			local name = tostring(player.Name):lower()
			local display = tostring(player.DisplayName or ""):lower()
			if name == needle or display == needle then
				return player
			end
			if name:find(needle, 1, true) or display:find(needle, 1, true) then
				matches[#matches + 1] = player
			end
		end
		if #matches == 1 then return matches[1] end
		if #matches > 1 then
			local names = util.map(matches, function(player) return player.Name end)
			return nil, "several players match '" .. util.trim(query) .. "': " .. table.concat(names, ", ")
		end
		return nil, "no player here matches '" .. util.trim(query) .. "'"
	end

	local function rootOf(player)
		local character = player and player.Character
		if not character then return nil end
		return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	end

	local function distanceTo(player)
		local mine = rootOf(env.plr)
		local theirs = rootOf(player)
		if not mine or not theirs then return nil end
		return (theirs.Position - mine.Position).Magnitude
	end

	return {
		{
			name = "players_list",
			risk = "read",
			description = "List everyone in the server with their distance from you.",
			parameters = {
				type = "object",
				properties = {
					limit = { type = "integer", minimum = 1, maximum = 100 },
				},
				required = {},
			},
			run = function(args)
				local players = env.players:GetPlayers()
				if #players == 0 then return "No players are in the server." end
				table.sort(players, function(a, b)
					return (distanceTo(a) or math.huge) < (distanceTo(b) or math.huge)
				end)
				return string.format("%d player(s):\n%s", #players,
					H.list(players, H.limit(args.limit, 40, 100), function(player)
						local bits = { player.Name }
						if player.DisplayName and player.DisplayName ~= player.Name then
							bits[#bits + 1] = "(" .. player.DisplayName .. ")"
						end
						if player == env.plr then bits[#bits + 1] = "[you]" end
						local distance = distanceTo(player)
						if distance then bits[#bits + 1] = string.format("%.0f studs", distance) end
						if not player.Character then bits[#bits + 1] = "no character" end
						return table.concat(bits, " ")
					end))
			end,
		},
		{
			name = "player_info",
			risk = "read",
			description = "Details for one player: ids, team, character state, position and distance.",
			parameters = {
				type = "object",
				properties = { player = { type = "string", description = "Username or display name; a substring is enough." } },
				required = { "player" },
			},
			run = function(args)
				local player, err = findPlayer(args.player)
				if not player then return H.fail(err) end

				local rows = {
					{ "Name", player.Name },
					{ "DisplayName", tostring(player.DisplayName) },
					{ "UserId", tostring(player.UserId) },
					{ "AccountAge", tostring(player.AccountAge) .. " days" },
					{ "Team", player.Team and tostring(player.Team.Name) or "none" },
					{ "Is you", player == env.plr and "yes" or "no" },
				}

				local character = player.Character
				if not character then
					rows[#rows + 1] = { "Character", "not loaded" }
				else
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if humanoid then
						rows[#rows + 1] = { "Health", string.format("%s / %s",
							H.show(humanoid.Health), H.show(humanoid.MaxHealth)) }
						rows[#rows + 1] = { "WalkSpeed", H.show(humanoid.WalkSpeed) }
						local okState, state = pcall(function() return humanoid:GetState() end)
						if okState then rows[#rows + 1] = { "State", tostring(state.Name or state) } end
					end
					local root = rootOf(player)
					if root then
						rows[#rows + 1] = { "Position", H.show(root.Position) }
						local distance = distanceTo(player)
						if distance then rows[#rows + 1] = { "Distance", string.format("%.1f studs", distance) } end
					end
					rows[#rows + 1] = { "Character path", H.pathOf(character) }
				end

				return H.keyValues(rows)
			end,
		},
		{
			name = "teleport_to_player",
			risk = "write",
			description = "Move your character next to another player. Client-side only: on a server with position checks this may be reverted or punished.",
			parameters = {
				type = "object",
				properties = {
					player = { type = "string" },
					offset = { type = "number", description = "Studs to stand away from them. Default 4.", minimum = 0, maximum = 60 },
				},
				required = { "player" },
			},
			run = function(args)
				local player, err = findPlayer(args.player)
				if not player then return H.fail(err) end
				if player == env.plr then return "That is you." end

				local target = rootOf(player)
				if not target then return H.fail(player.Name .. " has no character loaded") end
				local mine = rootOf(env.plr)
				if not mine then return H.fail("your character is not loaded") end

				local offset = util.clamp(tonumber(args.offset) or 4, 0, 60)
				local destination = target.Position + Vector3.new(offset, 0, 0)
				local ok, setErr = pcall(function()
					mine.CFrame = CFrame.new(destination)
				end)
				if not ok then return H.fail(tostring(setErr)) end
				return string.format("Moved to %s at %s", player.Name, H.show(destination))
			end,
		},
	}
end
