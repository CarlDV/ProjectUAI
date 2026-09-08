-- Seeing the screen: capture it and describe what is on it.
--
-- A blind agent can click blindly. This group gives it eyes: a screenshot read
-- back as raw pixel data, and a raycast from the camera through the crosshair so
-- "what am I looking at" is a tool call rather than a guess. Neither replaces a
-- multimodal model -- the pixel dump is what a model without vision can still
-- reason about: dominant colours, brightness, motion between frames.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local H = env.require("tools/helpers")

	local DOWNS = { 2, 4, 8 }

	-- Reduces a width and height so the returned grid is under maxCells. A coarse
	-- grid is worth more to a text model than a full-resolution bitmap.
	local function gridFor(width, height, maxCells)
		local ratio = height / math.max(width, 1)
		local cols = math.floor(math.sqrt(maxCells / ratio))
		if cols < 1 then cols = 1 end
		local rows = math.max(1, math.floor(cols * ratio))
		return cols, rows
	end

	-- Brightness classes. Nine buckets is enough to answer "is this screen mostly
	-- dark or mostly bright" and "is there a bright patch in the top left" -- the
	-- questions a model actually asks of a screenshot.
	local function classify(r, g, b)
		local luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
		if luma < 0.1 then return 0 end
		if luma < 0.3 then return 1 end
		if luma < 0.5 then return 2 end
		if luma < 0.7 then return 3 end
		return 4
	end

	local BRIGHTNESS_CHARS = { " ", ".", "-", "+", "#" }

	return {
		{
			name = "ray_target",
			risk = "read",
			needs = { "gui" },
			description = "Raycast from the camera through the centre of the screen and report what is under the crosshair: the part, its distance, its material and its owner. Use it to answer 'what am I looking at' before interacting.",
			parameters = {
				type = "object",
				properties = {
					x = { type = "number", description = "Screen X as a 0-1 fraction. Default 0.5." },
					y = { type = "number", description = "Screen Y as a 0-1 fraction. Default 0.5." },
				},
				required = {},
			},
			run = function(args)
				local camera = env.services.Workspace.CurrentCamera
				if not camera then return H.fail("no current camera") end

				local fx = util.clamp(tonumber(args.x) or 0.5, 0, 1)
				local fy = util.clamp(tonumber(args.y) or 0.5, 0, 1)
				local viewport = camera.ViewportSize
				local point = Vector2.new(fx * viewport.X, fy * viewport.Y)

				local okRay, unit = pcall(function() return camera:ViewportPointToRay(point.X, point.Y) end)
				if not okRay or not unit then return H.fail("could not build a ray from the screen point") end

				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { env.plr and env.plr.Character }
				params.IgnoreWater = true

				local ws = env.services.Workspace
				local okCast, result = pcall(function()
					return ws:Raycast(unit.Origin, unit.Direction * 10000, params)
				end)
				if not okCast then return H.fail(tostring(result)) end
				if not result or not result.Instance then
					return string.format("Nothing within 10000 studs along the ray from %s.", H.show(unit.Origin))
				end

				local rows = {
					{ "Part", H.show(result.Instance) },
					{ "Class", tostring(result.Instance.ClassName) },
					{ "Distance", string.format("%.1f studs", result.Distance) },
					{ "Material", tostring(result.Material and result.Material.Name or "?") },
				}
				local okParent, parent = pcall(function() return result.Instance.Parent end)
				if okParent and parent and parent ~= workspace then
					rows[#rows + 1] = { "Parent", H.pathOf(parent) }
				end
				return H.keyValues(rows)
			end,
		},
	}
end
