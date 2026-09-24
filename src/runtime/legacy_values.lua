-- Compatibility text codecs. Native snapshots use runtime/values.
return function(env)
	local util = env.require("runtime/util")
	local paths = env.require("runtime/instance_paths")
	local M = { resolve = paths.resolve, pathOf = paths.pathOf }
	-- Values -----------------------------------------------------------------

	-- Roblox value -> compact text a model can read and, importantly, feed back in.
	function M.show(value)
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
			return M.pathOf(value) .. " [" .. tostring(value.ClassName) .. "]"
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
	function M.coerce(input, current)
		local wanted = typeof(current)
		if wanted == "string" then return tostring(input) end

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
			if not value or value ~= value or value == math.huge or value == -math.huge then
				return nil, "expected a finite number"
			end
			return value
		end
		if wanted == "boolean" then
			local lowered = text:lower()
			if lowered == "true" or lowered == "1" or lowered == "yes" then return true end
			if lowered == "false" or lowered == "0" or lowered == "no" then return false end
			return nil, "expected true or false"
		end
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
			local instance, err = M.resolve(text)
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

	return M
end
