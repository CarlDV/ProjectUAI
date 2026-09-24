return function(env)
	local schema = env.require("runtime/instance_schema")
	local M = {}
	function M.read(instance, kind, key)
		return pcall(function()
			if kind == "attribute" then return instance:GetAttribute(key) end
			if kind == "tag" then return instance:HasTag(key) end
			return instance[key]
		end)
	end
	function M.write(instance, kind, key, value)
		return pcall(function()
			if kind == "attribute" then instance:SetAttribute(key, value)
			elseif kind == "tag" then if value then instance:AddTag(key) else instance:RemoveTag(key) end
			else instance[key] = value end
		end)
	end
	function M.validate(kind, key, value, before)
		if type(key) ~= "string" or #key < 1 or #key > 100 or key:find("[%z\1-\31]") then return false, "Invalid field name" end
		if kind ~= "property" and kind ~= "attribute" and kind ~= "tag" then return false, "Unknown field operation" end
		if kind == "property" then
			if not schema.writable(key) then return false, key .. " is read-only here; use the dedicated operation" end
			if before ~= nil and typeof(before) ~= typeof(value) and not (typeof(before) == "Instance" and value == nil) then return false, "Expected a " .. typeof(before) .. " for " .. key end
			if before == nil and value ~= nil and typeof(value) ~= "Instance" then return false, "Nil reference fields require an Instance or nil" end
			if typeof(before) == "EnumItem" and before.EnumType ~= value.EnumType then return false, "Wrong enum domain" end
		elseif kind == "attribute" then
			local allowed = { string = true, number = true, boolean = true, Vector2 = true, Vector3 = true, Color3 = true, CFrame = true, UDim = true, UDim2 = true, Rect = true, NumberRange = true, NumberSequence = true, ColorSequence = true, BrickColor = true }
			if value ~= nil and not allowed[typeof(value)] then return false, "Unsupported attribute type" end
		elseif type(value) ~= "boolean" then return false, "Tag membership must be a boolean" end
		return true
	end
	return M
end
