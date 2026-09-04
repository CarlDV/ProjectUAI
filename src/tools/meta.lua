-- Metadata about the place, the client build and Roblox users.
return function(env)
	local util = env.require("runtime/util")
	local http = env.require("net/http")
	local H = env.require("tools/helpers")

	return {
		{
			name = "game_info",
			risk = "read",
			description = "Identify the place this client is in: name, ids, creator, player counts.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local rows = {
					{ "PlaceId", tostring(game.PlaceId) },
					{ "GameId", tostring(game.GameId) },
					{ "JobId", tostring(game.JobId) },
					{ "PlaceVersion", tostring(game.PlaceVersion) },
				}

				local okInfo, info = pcall(function()
					return env.services.MarketplaceService:GetProductInfo(game.PlaceId)
				end)
				if okInfo and type(info) == "table" then
					rows[#rows + 1] = { "Name", tostring(info.Name) }
					if info.Creator and info.Creator.Name then
						rows[#rows + 1] = { "Creator", tostring(info.Creator.Name) }
					end
					if info.Description and util.trim(info.Description) ~= "" then
						rows[#rows + 1] = { "Description", util.ellipsis(info.Description, 200) }
					end
				end

				local okPlayers, players = pcall(function() return env.players:GetPlayers() end)
				if okPlayers then
					rows[#rows + 1] = { "Players", string.format("%d of %d", #players, env.players.MaxPlayers or 0) }
				end

				local okTime, gameTime = pcall(function() return env.services.Workspace.DistributedGameTime end)
				if okTime then rows[#rows + 1] = { "Server uptime", util.formatDuration(gameTime * 1000) } end

				return H.keyValues(rows)
			end,
		},
		{
			name = "place_info",
			risk = "read",
			needs = { "http" },
			description = "Look up any Roblox place or asset by id.",
			parameters = {
				type = "object",
				properties = {
					id = { type = "integer", description = "Place or asset id. Defaults to the current place." },
				},
				required = {},
			},
			run = function(args)
				local id = tonumber(args.id) or game.PlaceId
				local okInfo, info = pcall(function()
					return env.services.MarketplaceService:GetProductInfo(id)
				end)
				if okInfo and type(info) == "table" and info.Name then
					local rows = {
						{ "Name", tostring(info.Name) },
						{ "AssetId", tostring(id) },
						{ "Type", tostring(info.AssetTypeId or "unknown") },
						{ "Creator", info.Creator and tostring(info.Creator.Name) or "unknown" },
						{ "Created", tostring(info.Created or "unknown") },
						{ "Updated", tostring(info.Updated or "unknown") },
					}
					if info.Description and util.trim(info.Description) ~= "" then
						rows[#rows + 1] = { "Description", util.ellipsis(info.Description, 300) }
					end
					return H.keyValues(rows)
				end

				-- MarketplaceService fails for some asset types; the web API answers
				-- for more of them.
				local decoded, err = http.json({
					url = "https://economy.roblox.com/v2/assets/" .. tostring(id) .. "/details",
					method = "GET",
					attempts = 2,
					tag = "tool:place_info",
				})
				if not decoded then return H.fail(err or "asset lookup failed") end
				return H.keyValues({
					{ "Name", tostring(decoded.Name) },
					{ "AssetId", tostring(decoded.AssetId or id) },
					{ "Creator", decoded.Creator and tostring(decoded.Creator.Name) or "unknown" },
					{ "Description", util.ellipsis(tostring(decoded.Description or ""), 300) },
				})
			end,
		},
		{
			name = "user_lookup",
			risk = "read",
			needs = { "http" },
			description = "Look up a Roblox account by username or id.",
			parameters = {
				type = "object",
				properties = {
					username = { type = "string" },
					user_id = { type = "integer" },
				},
				required = {},
			},
			run = function(args)
				local userId = tonumber(args.user_id)

				if not userId then
					local username = util.trim(args.username)
					if username == "" then return "Give a username or a user id." end
					local decoded, err = http.json({
						url = "https://users.roblox.com/v1/usernames/users",
						method = "POST",
						headers = { ["Content-Type"] = "application/json" },
						body = util.encode({ usernames = { username }, excludeBannedUsers = false }),
						attempts = 2,
						tag = "tool:user_lookup",
					})
					if not decoded then return H.fail(err or "lookup failed") end
					local first = decoded.data and decoded.data[1]
					if not first then return "No account is named '" .. username .. "'." end
					userId = first.id
				end

				local decoded, err = http.json({
					url = "https://users.roblox.com/v1/users/" .. tostring(userId),
					method = "GET",
					attempts = 2,
					tag = "tool:user_lookup",
				})
				if not decoded then return H.fail(err or "lookup failed") end
				return H.keyValues({
					{ "Username", tostring(decoded.name) },
					{ "DisplayName", tostring(decoded.displayName) },
					{ "UserId", tostring(decoded.id) },
					{ "Created", tostring(decoded.created) },
					{ "Banned", tostring(decoded.isBanned) },
					{ "Description", util.ellipsis(tostring(decoded.description or ""), 240) },
				})
			end,
		},
		{
			name = "roblox_version",
			risk = "read",
			needs = { "http" },
			description = "Report the current Roblox client release version.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local decoded, err = http.json({
					url = "https://clientsettingscdn.roblox.com/v2/client-version/WindowsPlayer/channel/live",
					method = "GET",
					attempts = 2,
					tag = "tool:roblox_version",
				})
				if not decoded then return H.fail(err or "version lookup failed") end
				return H.keyValues({
					{ "Version", tostring(decoded.version) },
					{ "Upload", tostring(decoded.clientVersionUpload) },
					{ "Bootstrapper", tostring(decoded.bootstrapperVersion or "unknown") },
				})
			end,
		},
	}
end
