-- The world around the character: geometry queries, lighting and the camera.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")

	local LIGHTING_FIELDS = {
		"ClockTime", "TimeOfDay", "Brightness", "Ambient", "OutdoorAmbient",
		"FogColor", "FogStart", "FogEnd", "GlobalShadows", "ExposureCompensation",
		"EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ShadowSoftness",
	}

	local function rootPosition()
		local character = env.plr and env.plr.Character
		local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
		return root and root.Position or nil
	end

	return {
		{
			name = "raycast",
			risk = "read",
			description = "Cast a ray and report the first thing it hits. Origin defaults to your character; direction is a vector, not a target point.",
			parameters = {
				type = "object",
				properties = {
					origin = { type = "string", description = "Start as 'x, y, z'. Defaults to your position." },
					direction = { type = "string", description = "Direction and length as 'x, y, z', e.g. '0, -50, 0' to look down 50 studs." },
					ignore_character = { type = "boolean", description = "Exclude your own character. Default true." },
				},
				required = { "direction" },
			},
			run = function(args)
				local origin = rootPosition() or Vector3.new(0, 10, 0)
				if args.origin and util.trim(args.origin) ~= "" then
					local parsed = H.coerce(args.origin, Vector3.new(0, 0, 0))
					if not parsed then return H.fail("origin must be three numbers") end
					origin = parsed
				end
				local direction = H.coerce(args.direction, Vector3.new(0, 0, 0))
				if not direction then return H.fail("direction must be three numbers") end
				if direction.Magnitude == 0 then return H.fail("direction cannot be zero") end

				local params = RaycastParams.new()
				if args.ignore_character ~= false and env.plr and env.plr.Character then
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { env.plr.Character }
				end

				local ok, result = pcall(function()
					return env.services.Workspace:Raycast(origin, direction, params)
				end)
				if not ok then return H.fail("the raycast was rejected: " .. tostring(result)) end
				if not result then
					return string.format("Nothing hit within %.1f studs from %s.", direction.Magnitude, H.show(origin))
				end

				return H.keyValues({
					{ "Hit", H.pathOf(result.Instance) },
					{ "Class", tostring(result.Instance and result.Instance.ClassName) },
					{ "Position", H.show(result.Position) },
					{ "Normal", H.show(result.Normal) },
					{ "Distance", string.format("%.2f studs", result.Distance) },
					{ "Material", tostring(result.Material and result.Material.Name or "unknown") },
				})
			end,
		},
		{
			name = "parts_near",
			risk = "read",
			description = "List parts within a radius of a point. Defaults to around your character.",
			parameters = {
				type = "object",
				properties = {
					position = { type = "string", description = "Centre as 'x, y, z'. Defaults to your position." },
					radius = { type = "number", description = "Studs, 1-500. Default 20.", minimum = 1, maximum = 500 },
					limit = { type = "integer", minimum = 1, maximum = 80 },
				},
				required = {},
			},
			run = function(args)
				local centre = rootPosition() or Vector3.new(0, 0, 0)
				if args.position and util.trim(args.position) ~= "" then
					local parsed = H.coerce(args.position, Vector3.new(0, 0, 0))
					if not parsed then return H.fail("position must be three numbers") end
					centre = parsed
				end
				local radius = util.clamp(tonumber(args.radius) or 20, 1, 500)

				local found
				local ok = pcall(function()
					found = env.services.Workspace:GetPartBoundsInRadius(centre, radius)
				end)
				if not ok or type(found) ~= "table" then
					-- Older hosts lack the spatial query; a descendant sweep is slower
					-- but produces the same answer.
					found = {}
					for _, node in ipairs(env.services.Workspace:GetDescendants()) do
						if node:IsA("BasePart") and (node.Position - centre).Magnitude <= radius then
							found[#found + 1] = node
						end
					end
				end

				if #found == 0 then
					return string.format("No parts within %.0f studs of %s.", radius, H.show(centre))
				end
				table.sort(found, function(a, b)
					return (a.Position - centre).Magnitude < (b.Position - centre).Magnitude
				end)
				return string.format("%d part(s) within %.0f studs of %s:\n%s",
					#found, radius, H.show(centre),
					H.list(found, H.limit(args.limit, 25, 80), function(part)
						return string.format("%s [%s] %.1f studs, size %s",
							H.pathOf(part), part.ClassName, (part.Position - centre).Magnitude, H.show(part.Size))
					end))
			end,
		},
		{
			name = "lighting_get",
			risk = "read",
			description = "Read the current lighting settings.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local lighting = env.services.Lighting
				local rows = {}
				for _, field in ipairs(LIGHTING_FIELDS) do
					local ok, value = pcall(function() return lighting[field] end)
					if ok and value ~= nil then rows[#rows + 1] = { field, H.show(value) } end
				end
				local effects = {}
				for _, child in ipairs(lighting:GetChildren()) do
					effects[#effects + 1] = child.Name .. " [" .. child.ClassName .. "]"
				end
				local text = H.keyValues(rows)
				if #effects > 0 then text = text .. "\nEffects: " .. table.concat(effects, ", ") end
				return text
			end,
		},
		{
			name = "lighting_set",
			risk = "write",
			description = "Change a lighting property. Client-side, so a script that reasserts lighting will overwrite it.",
			parameters = {
				type = "object",
				properties = {
					property = { type = "string", description = "e.g. 'ClockTime', 'Brightness', 'FogEnd', 'Ambient'." },
					value = { type = "string", description = "Text form: numbers plain, colours as 'r, g, b'." },
				},
				required = { "property", "value" },
			},
			run = function(args)
				local lighting = env.services.Lighting
				local name = util.trim(args.property)
				local okRead, current = pcall(function() return lighting[name] end)
				if not okRead then return H.fail("Lighting has no property '" .. name .. "'") end
				local value, err = H.coerce(args.value, current)
				if value == nil then return H.fail(err or "could not convert that value") end
				local before = H.show(current)
				local okWrite, writeErr = pcall(function() lighting[name] = value end)
				if not okWrite then return H.fail(tostring(writeErr)) end
				return H.changed(name .. " = " .. H.show(value), "Lighting", "was " .. before)
			end,
		},
		{
			name = "camera_get",
			risk = "read",
			description = "Read the camera: position, field of view, type and subject.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local camera = env.services.Workspace.CurrentCamera
				if not camera then return "There is no current camera." end
				return H.keyValues({
					{ "Position", H.show(camera.CFrame.Position) },
					{ "FieldOfView", H.show(camera.FieldOfView) },
					{ "CameraType", H.show(camera.CameraType) },
					{ "CameraSubject", camera.CameraSubject and H.pathOf(camera.CameraSubject) or "none" },
					{ "ViewportSize", H.show(camera.ViewportSize) },
				})
			end,
		},
		{
			name = "camera_set",
			risk = "write",
			description = "Change the camera's field of view, type, or position. Setting a position needs CameraType 'Scriptable' to stick.",
			parameters = {
				type = "object",
				properties = {
					field_of_view = { type = "number", description = "1-120." },
					camera_type = { type = "string", description = "e.g. 'Custom', 'Scriptable', 'Fixed'." },
					position = { type = "string", description = "'x, y, z'." },
				},
				required = {},
			},
			run = function(args)
				local camera = env.services.Workspace.CurrentCamera
				if not camera then return H.fail("there is no current camera") end
				local changes = {}

				local fov = tonumber(args.field_of_view)
				if fov then
					local clamped = util.clamp(fov, 1, 120)
					if pcall(function() camera.FieldOfView = clamped end) then
						changes[#changes + 1] = "FieldOfView = " .. H.show(clamped)
					end
				end
				if args.camera_type and util.trim(args.camera_type) ~= "" then
					local value, err = H.coerce(args.camera_type, camera.CameraType)
					if value == nil then return H.fail(err) end
					if pcall(function() camera.CameraType = value end) then
						changes[#changes + 1] = "CameraType = " .. H.show(value)
					end
				end
				if args.position and util.trim(args.position) ~= "" then
					local target = H.coerce(args.position, Vector3.new(0, 0, 0))
					if not target then return H.fail("position must be three numbers") end
					if pcall(function() camera.CFrame = CFrame.new(target) end) then
						changes[#changes + 1] = "position = " .. H.show(target)
						if camera.CameraType ~= Enum.CameraType.Scriptable then
							changes[#changes + 1] = "(CameraType is not Scriptable, so this will be overwritten next frame)"
						end
					end
				end

				if #changes == 0 then return "Nothing to change. Pass at least one value." end
				return "Camera: " .. table.concat(changes, ", ")
			end,
		},
	}
end
