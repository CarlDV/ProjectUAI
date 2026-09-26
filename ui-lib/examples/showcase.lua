-- Every public control, using the exact loader agents put in standalone scripts.
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
local window = UI:CreateWindow({
	Id = "uai-library-showcase",
	Title = "Fieldwork",
	Subtitle = "A considered set of tools for your session",
	Search = true,
})

local overview = window:Tab({ Title = "Overview", Icon = "grid" })
local controls = window:Tab({ Title = "Controls", Icon = "sliders" })
local appearance = window:Tab({ Title = "Appearance", Icon = "code" })
local preferences = window:Tab({ Title = "Preferences", Icon = "check" })

local session = overview:Section({ Title = "Session", Description = "Small, purposeful controls. One consistent interface." })
session:Badge({ Text = "Workspace", Default = "Ready", Kind = "Success" })
local automatic = session:Toggle({ Id = "automatic", Text = "Automatic updates", Description = "Keep the workspace current as things change.", Default = true })
local radius = session:Slider({ Id = "radius", Text = "Selection radius", Description = "The reach of your next selection.", Min = 10, Max = 100, Step = 5, Default = 40, Suffix = " studs" })
local progress = session:Progress({ Id = "progress", Text = "Session progress", Default = 64, Persist = false })
session:Button({
	Text = "Refresh workspace", Description = "Run a sample action using the current values.", ActionText = "Refresh", Style = "Primary",
	Callback = function()
		progress:Set(math.min(100, progress:Get() + 12))
		window:Notify({ Title = "Workspace refreshed", Content = "Selection radius: " .. radius:Get() .. " studs.", Kind = "Success" })
	end,
})

local inputs = controls:Section({ Title = "Inputs", Description = "Values stay separate from your application logic." })
inputs:Input({ Id = "name", Text = "Workspace name", Default = "My workspace", Placeholder = "Give this workspace a name" })
inputs:Input({ Id = "limit", Text = "Item limit", Description = "A number between 1 and 100.", Numeric = true, Min = 1, Max = 100, Default = 20 })
inputs:Dropdown({
	Id = "mode", Text = "Selection mode", Default = "nearest",
	Options = { { Label = "Nearest first", Value = "nearest" }, { Label = "In view", Value = "visible" }, { Label = "All available", Value = "all" } },
})
inputs:Dropdown({ Id = "filters", Text = "Include", Multi = true, Default = { "Players", "Objects" }, Options = { "Players", "Objects", "Markers", "Effects" } })
inputs:Checkbox({ Id = "remember", Text = "Remember selection", Description = "Preserve your selection between refreshes.", Default = true })
inputs:Keybind({
	Id = "shortcut", Text = "Quick notification", Default = Enum.KeyCode.K,
	Callback = function() window:Notify({ Title = "Shortcut received", Content = "Your keybind is connected." }) end,
})

local style = appearance:Section({ Title = "Appearance", Description = "The same visual language, with room for your preferences." })
style:Segmented({ Id = "theme", Text = "Theme", Options = { "Dark", "Light" }, Default = "Dark", Callback = function(value) window:SetTheme(value, window:Get("color"):Get()) end })
style:ColorPicker({ Id = "color", Text = "Accent color", Description = "Preview a color before applying it.", Default = Color3.fromRGB(217, 119, 87), Alpha = 1, Callback = function(value)
	window:SetTheme(window:Get("theme"):Get(), value)
end })
style:Slider({ Id = "text-scale", Text = "Text size", Min = 0.85, Max = 1.5, Step = 0.05, Default = 1, Suffix = "×", Callback = function(value) window:SetTextScale(value) end })
style:Divider({ Text = "Details" })
style:Label({ Text = "Built for desktop and touch", Description = "Resize the window or rotate your device to see the layout adapt." })
style:Paragraph({ Text = "A familiar foundation", Content = "Warm neutrals, careful spacing, and a single accent keep the controls clear. Your script supplies the behavior." })

local profiles = preferences:Section({ Title = "Preferences", Description = "Save a profile explicitly whenever you need it." })
profiles:Input({ Id = "notes", Text = "Session notes", MultiLine = true, Placeholder = "A few notes for this session…", Persist = false })
profiles:Button({ Text = "Save profile", ActionText = "Save", Callback = function()
	local ok, result = window:SaveConfig("default")
	window:Notify({ Title = ok and "Profile saved" or "Could not save", Content = tostring(result), Kind = ok and "Success" or "Warning" })
end })
profiles:Button({ Text = "Load profile", ActionText = "Load", Callback = function()
	local ok, result = window:LoadConfig("default")
	if ok then
		window:SetTheme(window:Get("theme"):Get(), window:Get("color"):Get())
		window:SetTextScale(window:Get("text-scale"):Get())
	end
	window:Notify({ Title = ok and "Profile loaded" or "Could not load", Content = ok and "Your controls have been restored." or tostring(result), Kind = ok and "Success" or "Warning" })
end })
local more = preferences:Section({ Title = "More", Collapsible = true })
more:Button({ Text = "About this workspace", ActionText = "About", Callback = function()
	window:Dialog({ Title = "Fieldwork", Content = "An example built entirely with Project UAI UI LIB. Each control is declared once; the library handles the interface." })
end })
more:Button({ Text = "Reset session", ActionText = "Reset", Style = "Danger", Callback = function()
	window:Confirm({ Title = "Reset this session?", Content = "Return the selection and progress to their defaults.", ConfirmText = "Reset", Danger = true, Callback = function()
		automatic:Reset(); radius:Reset(); progress:Reset()
	end })
end })
return window
