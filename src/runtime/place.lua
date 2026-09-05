-- Which place this is.
--
-- The place is the closest thing a Roblox client has to a project: it is what the
-- work is *in*, it is stable across sessions, and it is what a list of conversations
-- wants to be grouped by. Two of the three facts about it are free -- the id, the
-- version and the server instance are properties on `game` -- and the fourth, the
-- name, is a web call that yields and can fail.
--
-- So the name is asked for once, in the background, and every reader takes whatever
-- is known at the time. Nothing here blocks and nothing here invents a name: an
-- unresolved place is "Place 1818" until the call comes back, which is honest and is
-- also a usable label.
return function(env)
	local util = env.require("runtime/util")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")

	local M = {
		id = 0,
		gameId = 0,
		version = 0,
		jobId = "",
		name = "",
		creator = "",
		resolved = false,
		asking = false,
		changed = signal.new("place"),
	}

	pcall(function() M.id = tonumber(game.PlaceId) or 0 end)
	pcall(function() M.gameId = tonumber(game.GameId) or 0 end)
	pcall(function() M.version = tonumber(game.PlaceVersion) or 0 end)
	pcall(function() M.jobId = tostring(game.JobId or "") end)

	-- The id is always available, so there is always a label.
	function M.label()
		if util.trim(M.name) ~= "" then return M.name end
		if M.id > 0 then return "Place " .. tostring(M.id) end
		return "This place"
	end

	-- A stable key for grouping. Studio and a solo run have no job id and a place with
	-- no id at all is possible in a local test, so the id is the key and the string is
	-- there to be a table key rather than to be read.
	function M.key()
		return "place:" .. tostring(M.id)
	end

	function M.resolve()
		if M.resolved or M.asking then return end
		if M.id <= 0 then return end
		M.asking = true
		task.spawn(function()
			local ok, info = pcall(function()
				return env.services.MarketplaceService:GetProductInfo(M.id)
			end)
			M.asking = false
			if not ok or type(info) ~= "table" then
				-- Normal, not exceptional: the endpoint is rate limited and a client
				-- without HTTP access to it simply keeps the id as its label.
				log.debug("place", "could not read the place name", info)
				return
			end
			M.resolved = true
			M.name = tostring(info.Name or "")
			if type(info.Creator) == "table" then M.creator = tostring(info.Creator.Name or "") end
			M.changed:fire(M)
		end)
	end

	function M.describe()
		local parts = { M.label() }
		if M.version > 0 then parts[#parts + 1] = "v" .. tostring(M.version) end
		if util.trim(M.creator) ~= "" then parts[#parts + 1] = "by " .. M.creator end
		return table.concat(parts, "  ")
	end

	-- Every fact this module has, as rows a panel can render. Only what was actually
	-- read: a field that is empty is absent rather than "unknown".
	function M.facts()
		local out = {}
		local function add(key, value)
			if value ~= nil and tostring(value) ~= "" and tostring(value) ~= "0" then
				out[#out + 1] = { key = key, value = tostring(value) }
			end
		end
		add("Place", M.label())
		add("Place id", M.id)
		add("Version", M.version)
		add("Universe", M.gameId)
		add("Server", M.jobId)
		add("Creator", M.creator)
		return out
	end

	return M
end
