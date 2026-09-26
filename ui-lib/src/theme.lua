-- The public library follows the application's warm neutral palette. Tokens
-- live here; script authors choose content and behavior, never row geometry.
return function(env)
	local rgb = Color3.fromRGB
	local M = {}
	M.Dark = {
		Canvas = rgb(30, 30, 28), Sidebar = rgb(23, 23, 22),
		Surface = rgb(35, 35, 33), Raised = rgb(42, 42, 39),
		Hover = rgb(50, 50, 46), Pressed = rgb(62, 62, 57),
		Border = rgb(74, 74, 71), Subtle = rgb(62, 62, 57),
		Text = rgb(245, 244, 238), Secondary = rgb(194, 191, 181),
		Muted = rgb(163, 161, 152), Disabled = rgb(108, 107, 102),
		Accent = rgb(217, 119, 87), OnAccent = rgb(23, 23, 22),
		Primary = rgb(245, 244, 238), OnPrimary = rgb(23, 23, 22),
		Success = rgb(135, 203, 160), Warning = rgb(237, 189, 111),
		Danger = rgb(245, 145, 143), Scrim = rgb(12, 12, 11),
	}
	M.Light = {
		Canvas = rgb(247, 246, 242), Sidebar = rgb(238, 236, 230),
		Surface = rgb(255, 254, 251), Raised = rgb(240, 238, 232),
		Hover = rgb(229, 226, 218), Pressed = rgb(216, 213, 204),
		Border = rgb(148, 145, 135), Subtle = rgb(199, 195, 184),
		Text = rgb(35, 35, 32), Secondary = rgb(73, 72, 65),
		Muted = rgb(100, 98, 88), Disabled = rgb(133, 130, 121),
		Accent = rgb(157, 68, 43), OnAccent = rgb(255, 254, 251),
		Primary = rgb(35, 35, 32), OnPrimary = rgb(255, 254, 251),
		Success = rgb(34, 108, 68), Warning = rgb(132, 83, 18),
		Danger = rgb(166, 47, 48), Scrim = rgb(12, 12, 11),
	}
	M.Size = {
		Target = 40, TouchTarget = 44, Gap = 12, Pad = 20,
		Header = 76, Footer = 30, Sidebar = 172, Tabs = 52,
		Radius = 10, FieldRadius = 6, Scrollbar = 3,
		Width = 780, Height = 580, Compact = 640,
	}
	M.Type = { Title = 20, Heading = 15, Body = 14, Caption = 12, Small = 11 }
	function M.resolve(name, accent)
		assert(name == nil or name == "Dark" or name == "Light", "Theme must be Dark or Light")
		local result = {}
		for key, value in pairs(M[name or "Dark"]) do result[key] = value end
		if accent ~= nil then
			assert(typeof(accent) == "Color3", "Accent must be a Color3")
			result.Accent = accent
			local luminance = accent.R * 0.2126 + accent.G * 0.7152 + accent.B * 0.0722
			result.OnAccent = luminance > 0.5 and rgb(23, 23, 22) or rgb(255, 254, 251)
		end
		result.Selected = result.Raised:Lerp(result.Accent, 0.16)
		return result
	end
	return M
end
