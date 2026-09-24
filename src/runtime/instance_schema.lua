-- UAI-authored supported-property catalog, revision 2026-09-23. Not a full API dump.
return function(env)
	local M = { version = "2026-09-23", coverage = "supported properties" }
	local COMMON = { "Name", "ClassName" }

	local BY_CLASS = {
		{ "BasePart", { "Position", "Size", "Orientation", "Anchored", "CanCollide", "CanTouch", "Transparency", "Color", "Material", "Massless", "Shape", "Reflectance" } },
		{ "Model", { "PrimaryPart", "WorldPivot" } },
		{ "GuiObject", { "Position", "Size", "AnchorPoint", "Visible", "BackgroundColor3", "BackgroundTransparency", "ZIndex", "LayoutOrder", "Rotation", "ClipsDescendants", "AutomaticSize", "AbsolutePosition", "AbsoluteSize" } },
		{ "TextLabel", { "Text", "TextColor3", "TextSize", "Font", "TextWrapped", "RichText", "TextXAlignment", "TextYAlignment", "TextTransparency" } },
		{ "TextButton", { "Text", "TextColor3", "TextSize", "Font", "AutoButtonColor" } },
		{ "TextBox", { "Text", "PlaceholderText", "TextColor3", "TextSize", "ClearTextOnFocus", "MultiLine" } },
		{ "ImageLabel", { "Image", "ImageColor3", "ImageTransparency", "ScaleType" } },
		{ "ScrollingFrame", { "CanvasSize", "CanvasPosition", "ScrollBarThickness", "AutomaticCanvasSize", "ScrollingEnabled" } },
		{ "ScreenGui", { "Enabled", "DisplayOrder", "IgnoreGuiInset", "ResetOnSpawn", "ZIndexBehavior" } },
		{ "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight", "Sit", "PlatformStand", "MoveDirection", "RigType" } },
		{ "Player", { "DisplayName", "UserId", "AccountAge", "Team", "TeamColor", "CharacterAppearanceId" } },
		{ "Camera", { "CFrame", "FieldOfView", "CameraType", "CameraSubject", "Focus" } },
		{ "Sound", { "SoundId", "Volume", "Playing", "Looped", "TimePosition", "PlaybackSpeed" } },
		{ "Light", { "Brightness", "Color", "Range", "Enabled", "Shadows" } },
		{ "Lighting", { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "FogColor", "FogStart", "FogEnd", "GlobalShadows", "ExposureCompensation" } },
		{ "ValueBase", { "Value" } },
		{ "Decal", { "Texture", "Transparency", "Face" } },
		{ "Tool", { "RequiresHandle", "CanBeDropped", "Enabled", "ToolTip" } },
		{ "ProximityPrompt", { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled" } },
		{ "Attachment", { "Position", "WorldPosition", "Axis" } },
		{ "UIListLayout", { "FillDirection", "Padding", "SortOrder", "HorizontalAlignment", "VerticalAlignment", "Wraps" } },
		{ "UIPadding", { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } },
		{ "UIStroke", { "Color", "Thickness", "Transparency", "ApplyStrokeMode" } },
		{ "UICorner", { "CornerRadius" } },
		{ "UIScale", { "Scale" } },
		{ "CanvasGroup", { "GroupTransparency", "GroupColor3" } },
		{ "Script", { "Enabled", "RunContext" } },
		{ "LuaSourceContainer", { "Source" } },
		{ "Terrain", { "WaterColor", "WaterTransparency", "WaterWaveSize" } },
		{ "SpawnLocation", { "Enabled", "Neutral", "TeamColor", "Duration" } },
		{ "Seat", { "Occupant", "Disabled" } },
	}

	local cache = {}
	function M.names(instance, extra)
		local names, seen = {}, {}
		local function add(name)
			if type(name) == "string" and name ~= "" and not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
		local class = instance.ClassName
		if cache[class] then for _, name in ipairs(cache[class]) do add(name) end
		else
			for _, name in ipairs(COMMON) do add(name) end
			for _, entry in ipairs(BY_CLASS) do
				local ok, isA = pcall(function() return instance:IsA(entry[1]) end)
				if ok and isA then for _, name in ipairs(entry[2]) do add(name) end end
			end
			cache[class] = {}; for i, name in ipairs(names) do cache[class][i] = name end
		end
		for _, name in ipairs(extra or {}) do add(name) end
		return names
	end

	M.readOnly = { ClassName = true, Source = true, Parent = true, AbsolutePosition = true, AbsoluteSize = true, UserId = true, AccountAge = true, MoveDirection = true, Occupant = true, WorldPosition = true }
	M.reference = { Parent = true, PrimaryPart = true, CameraSubject = true, Team = true, ObjectValue = true }
	function M.writable(name) return not M.readOnly[name] end
	local categories = {
		Name = "Identity", ClassName = "Identity", Parent = "Identity", Source = "Source",
		Position = "Transform", Size = "Transform", Orientation = "Transform", CFrame = "Transform", WorldPivot = "Transform", AnchorPoint = "Transform", Rotation = "Transform",
		Color = "Appearance", Transparency = "Appearance", Material = "Appearance", Reflectance = "Appearance", Text = "Appearance", TextColor3 = "Appearance", Image = "Appearance", BackgroundColor3 = "Appearance",
		Anchored = "Physics", CanCollide = "Physics", CanTouch = "Physics", Massless = "Physics",
	}
	function M.category(name) return categories[name] or "Behavior" end
	return M
end
