-- A standalone consumer: declarations and application logic only.
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
local window = UI:CreateWindow({
	Id = "uai-session-tools",
	Title = "Session tools",
	Subtitle = "A focused workspace for this session",
})
local main = window:Tab({ Title = "Main", Icon = "sliders" })
local actions = main:Section({ Title = "Selection" })
local enabled = actions:Toggle({ Id = "enabled", Text = "Enable processing", Default = true })
local amount = actions:Slider({ Id = "amount", Text = "Amount", Description = "How many items to include.", Min = 1, Max = 20, Step = 1, Default = 5 })
local function process()
	if not enabled:Get() then
		window:Notify({ Title = "Processing is off", Content = "Enable processing to continue.", Kind = "Info" })
		return
	end
	-- Replace this line with your application's behavior.
	print("Process", amount:Get(), "items")
	window:Notify({ Title = "Finished", Content = tostring(amount:Get()) .. " items processed.", Kind = "Success" })
end
actions:Button({ Text = "Process selection", ActionText = "Run", Style = "Primary", Callback = process })
actions:Keybind({ Id = "process-key", Text = "Process shortcut", Default = Enum.KeyCode.K, Callback = process })
window:OnDestroy(function()
	-- Restore temporary application state or release domain resources here.
end)
return window
