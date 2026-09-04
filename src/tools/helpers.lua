-- Shared machinery for the tool groups: path resolution, value conversion in both
-- directions, and the formatting conventions every tool result follows.
--
-- Two rules drive the design. Model output is untrusted text, so a path or a
-- property value is parsed rather than trusted. And a tool result is read by a
-- model, not a person, so it is dense, labelled, and bounded -- a wall of
-- unlabelled values costs tokens and teaches nothing.
return function(env)
	local util = env.require("runtime/util")

	local H = {}

	-- Paths ------------------------------------------------------------------

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

	H.ROOT_NAMES = { "game", "workspace", "players", "lighting", "me", "character", "playergui", "camera" }

	-- "Workspace.Folder.Part", "game.Players.Someone", "me.Character.Humanoid".
	--
	-- A leading `game.` is optional, service names resolve through GetService (so a
	-- renamed service instance still works), and a segment that is not a child is
	-- reported with the path that did resolve -- which is the difference between a
	-- model fixing its own typo and a model guessing again.
	function H.resolve(path)
		local text = util.trim(path)
		if text == "" then return nil, "no path given" end

		local segments = util.split(text:gsub("^game%.", ""), ".")
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
			local child = node:FindFirstChild(segment)
			if not child then
				return nil, string.format("'%s' has no child named '%s'",
					table.concat(walked, "."), segment)
			end
			node = child
			walked[#walked + 1] = segment
		end
		return node
	end

	function H.pathOf(instance)
		if not instance then return "nil" end
		local ok, name = pcall(function() return instance:GetFullName() end)
		return ok and name or tostring(instance)
	end

	-- Values -----------------------------------------------------------------

	-- Roblox value -> compact text a model can read and, importantly, feed back in.
	function H.show(value)
		local kind = typeof(value)
		if value == nil then return "nil" end
		if kind == "Vector3" then
			return string.format("%.2f, %.2f, %.2f", value.X, value.Y, value.Z)
		end
		if kind == "Vector2" then
			return string.format("%.2f, %.2f", value.X, value.Y)
		end
		if kind == "CFrame" then
			local p = value.Position
			return string.format("%.2f, %.2f, %.2f", p.X, p.Y, p.Z)
		end
		if kind == "Color3" then
			return string.format("%d, %d, %d",
				math.floor(value.R * 255 + 0.5), math.floor(value.G * 255 + 0.5), math.floor(value.B * 255 + 0.5))
		end
		if kind == "UDim2" then
			return string.format("%.3g, %d, %.3g, %d", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
		end
		if kind == "UDim" then
			return string.format("%.3g, %d", value.Scale, value.Offset)
		end
		if kind == "NumberRange" then
			return string.format("%.3g..%.3g", value.Min, value.Max)
		end
		if kind == "EnumItem" then
			return "Enum." .. tostring(value.EnumType) .. "." .. tostring(value.Name)
		end
		if kind == "Instance" then
			return H.pathOf(value) .. " [" .. tostring(value.ClassName) .. "]"
		end
		if kind == "BrickColor" then return tostring(value.Name) end
		if kind == "number" then
			if value == math.floor(value) and math.abs(value) < 1e12 then return string.format("%d", value) end
			return string.format("%.4g", value)
		end
		if kind == "boolean" then return value and "true" or "false" end
		if kind == "string" then return value end
		if kind == "table" then return "{table}" end
		return tostring(value)
	end

	local function numbers(text, count)
		local out = {}
		for piece in tostring(text):gmatch("%-?%d+%.?%d*") do
			out[#out + 1] = tonumber(piece)
		end
		if count and #out < count then return nil end
		return out
	end

	-- Text (or a JSON object) -> a Roblox value of the same type as `current`.
	--
	-- Typing off the existing value is what makes one set_property tool work for
	-- both a Part's Vector3 Size and a Frame's UDim2 Size without the model having
	-- to know which it is looking at.
	function H.coerce(input, current)
		local wanted = typeof(current)

		if type(input) == "table" and not (wanted == "table") then
			-- JSON object form: { x = 1, y = 2, z = 3 } or { r = 255, ... }.
			local parts = input
			if wanted == "Vector3" then
				return Vector3.new(tonumber(parts.x or parts.X) or 0, tonumber(parts.y or parts.Y) or 0, tonumber(parts.z or parts.Z) or 0)
			end
			if wanted == "Vector2" then
				return Vector2.new(tonumber(parts.x or parts.X) or 0, tonumber(parts.y or parts.Y) or 0)
			end
			if wanted == "Color3" then
				local r = tonumber(parts.r or parts.R) or 0
				local g = tonumber(parts.g or parts.G) or 0
				local b = tonumber(parts.b or parts.B) or 0
				if r <= 1 and g <= 1 and b <= 1 then return Color3.new(r, g, b) end
				return Color3.fromRGB(r, g, b)
			end
			if wanted == "UDim2" then
				return UDim2.new(
					tonumber(parts.xScale or parts.sx) or 0, tonumber(parts.xOffset or parts.ox) or 0,
					tonumber(parts.yScale or parts.sy) or 0, tonumber(parts.yOffset or parts.oy) or 0)
			end
			return nil, "cannot build a " .. tostring(wanted) .. " from an object"
		end

		local text = util.trim(input)

		if wanted == "number" then
			local value = tonumber(text)
			if not value then return nil, "expected a number" end
			return value
		end
		if wanted == "boolean" then
			local lowered = text:lower()
			if lowered == "true" or lowered == "1" or lowered == "yes" then return true end
			if lowered == "false" or lowered == "0" or lowered == "no" then return false end
			return nil, "expected true or false"
		end
		if wanted == "string" then return text end
		if wanted == "Vector3" then
			local list = numbers(text, 3)
			if not list then return nil, "expected three numbers, e.g. '0, 10, 0'" end
			return Vector3.new(list[1], list[2], list[3])
		end
		if wanted == "Vector2" then
			local list = numbers(text, 2)
			if not list then return nil, "expected two numbers" end
			return Vector2.new(list[1], list[2])
		end
		if wanted == "CFrame" then
			local list = numbers(text, 3)
			if not list then return nil, "expected three numbers for a position" end
			return CFrame.new(list[1], list[2], list[3])
		end
		if wanted == "Color3" then
			local hex = text:match("^#?(%x%x%x%x%x%x)$")
			if hex then return Color3.fromHex(hex) end
			local list = numbers(text, 3)
			if not list then return nil, "expected 'r, g, b' or a hex colour" end
			if list[1] <= 1 and list[2] <= 1 and list[3] <= 1 then
				return Color3.new(list[1], list[2], list[3])
			end
			return Color3.fromRGB(list[1], list[2], list[3])
		end
		if wanted == "UDim2" then
			local list = numbers(text, 4)
			if not list then return nil, "expected four numbers: xScale, xOffset, yScale, yOffset" end
			return UDim2.new(list[1], list[2], list[3], list[4])
		end
		if wanted == "UDim" then
			local list = numbers(text, 2)
			if not list then return nil, "expected two numbers: scale, offset" end
			return UDim.new(list[1], list[2])
		end
		if wanted == "NumberRange" then
			local list = numbers(text, 1)
			if not list then return nil, "expected one or two numbers" end
			return NumberRange.new(list[1], list[2] or list[1])
		end
		if wanted == "EnumItem" then
			local enumType = tostring(current.EnumType)
			local wantedName = text:match("([%w_]+)$") or text
			local ok, items = pcall(function() return Enum[enumType]:GetEnumItems() end)
			if ok and type(items) == "table" then
				for _, item in ipairs(items) do
					if tostring(item.Name):lower() == wantedName:lower() then return item end
				end
				local names = {}
				for _, item in ipairs(items) do names[#names + 1] = item.Name end
				return nil, "expected one of: " .. table.concat(names, ", ")
			end
			return nil, "unknown enum " .. enumType
		end
		if wanted == "Instance" or current == nil then
			local instance, err = H.resolve(text)
			if instance then return instance end
			if current == nil then return text end
			return nil, err
		end
		if wanted == "BrickColor" then
			local ok, colour = pcall(function() return BrickColor.new(text) end)
			if ok then return colour end
			return nil, "unknown BrickColor"
		end
		return nil, "setting a " .. tostring(wanted) .. " is not supported"
	end

	-- Formatting -------------------------------------------------------------

	function H.describe(instance)
		if not instance then return "nil" end
		local extra = {}
		local ok = pcall(function()
			if instance:IsA("BasePart") then
				extra[#extra + 1] = "at " .. H.show(instance.Position)
			elseif instance:IsA("GuiObject") then
				extra[#extra + 1] = "size " .. H.show(instance.Size)
			elseif instance:IsA("Humanoid") then
				extra[#extra + 1] = string.format("health %s/%s", H.show(instance.Health), H.show(instance.MaxHealth))
			end
		end)
		local childCount = 0
		pcall(function() childCount = #instance:GetChildren() end)
		if childCount > 0 then extra[#extra + 1] = util.pluralise(childCount, "child") end
		return string.format("%s [%s]%s", instance.Name, instance.ClassName,
			(ok and #extra > 0) and (" " .. table.concat(extra, ", ")) or "")
	end

	-- Numbered list with an explicit note when it was cut short, so a model can
	-- tell "that is everything" from "there is more".
	function H.list(items, limit, render)
		local lines = {}
		local shown = math.min(#items, limit or #items)
		for index = 1, shown do
			lines[#lines + 1] = string.format("%d. %s", index, render and render(items[index], index) or tostring(items[index]))
		end
		if #items > shown then
			lines[#lines + 1] = string.format("... %d more (narrow the query to see them)", #items - shown)
		end
		if #lines == 0 then return "(none)" end
		return table.concat(lines, "\n")
	end

	function H.keyValues(pairsList)
		local lines = {}
		for _, entry in ipairs(pairsList) do
			lines[#lines + 1] = entry[1] .. ": " .. tostring(entry[2])
		end
		return table.concat(lines, "\n")
	end

	function H.limit(value, fallback, ceiling)
		local number = tonumber(value) or fallback
		return math.floor(util.clamp(number, 1, ceiling or 200))
	end

	-- A tool that could not do what was asked returns this rather than a bare
	-- string, so the registry can mark the call as failed and the transcript can
	-- colour it. The model sees the same sentence either way.
	function H.fail(message)
		return { ok = false, text = "Failed: " .. tostring(message) }
	end

	-- A tool that changed something says what it changed and where, because the
	-- next turn often needs the path again.
	function H.changed(what, where, detail)
		return string.format("%s on %s%s", what, where, detail and (" -> " .. detail) or "")
	end

	return H
end
