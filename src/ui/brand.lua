-- An original, code-drawn asterisk. Each ray has its own angle and proportion;
-- the open gaps and softly cut ends stay legible at small interface sizes.
-- No backing tile, external assets, theme tint or animation is required.
return function(env)
	local M = { color = Color3.fromRGB(220, 126, 91) }
	local RAYS = {
		{ -8, 0.440, 0.086 }, { 24, 0.365, 0.105 }, { 58, 0.425, 0.080 },
		{ 91, 0.390, 0.096 }, { 126, 0.445, 0.078 }, { 158, 0.380, 0.106 },
		{ 192, 0.435, 0.088 }, { 225, 0.370, 0.105 }, { 257, 0.445, 0.079 },
		{ 291, 0.390, 0.096 }, { 325, 0.430, 0.082 },
	}

	function M.draw(parent, size)
		local frame = Instance.new("Frame", parent)
		frame.Name = "IconBrand"
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromOffset(size, size)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		Instance.new("UIAspectRatioConstraint", frame).AspectRatio = 1
		for index, ray in ipairs(RAYS) do
			local radians = math.rad(ray[1])
			local overlap = 0.055
			local centre = (ray[2] - overlap) * 0.5
			local piece = Instance.new("Frame", frame)
			piece.Name = "Ray" .. index
			piece.BorderSizePixel = 0
			piece.BackgroundColor3 = M.color
			piece.AnchorPoint = Vector2.new(0.5, 0.5)
			piece.Position = UDim2.fromScale(0.49 + math.cos(radians) * centre, 0.51 + math.sin(radians) * centre)
			piece.Size = UDim2.fromScale(ray[2] + overlap, ray[3])
			piece.Rotation = ray[1]
			piece.ZIndex = 2
			Instance.new("UICorner", piece).CornerRadius = UDim.new(0, size * 0.009)
		end
		return frame
	end

	return M
end
