-- Behavioral checks against the actual standalone distribution, never source
-- replacements. Manually review changes before running this file.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local passed = 0
local function check(label, condition)
	assert(condition, label)
	passed = passed + 1
	print("ok " .. label)
end
local function count(map) local total = 0; for _ in pairs(map) do total = total + 1 end; return total end
local function boot(options)
	local harness = envMock.new(options)
	local ui, why = harness.boot("dist/uai-ui.lua")
	assert(ui, why)
	return harness, ui
end
local h, UI = boot()
local E, dt = h.sandbox.Enum, h.dt
check("loading the library mounts nothing and makes no HTTP requests", #h.coreGui:GetChildren() == 0 and #h.http.log == 0)
local window = UI:CreateWindow({ Id = "test", Title = "Library contract", Search = true })
local tab = window:Tab({ Title = "Main" })
local section = tab:Section({ Title = "Actions", Collapsible = true })
local uis = h.services.UserInputService
local focused
uis.GetFocusedTextBox = function() return focused end
local function node(name, parent) return assert(h.byName(name, parent or window.ScreenGui), "missing " .. name) end
local function input(kind, x, y, key)
	return { UserInputType = kind, KeyCode = key or E.KeyCode.Unknown, Position = dt.Vector3.new(x or 0, y or 0, 0) }
end
local function key(name) return input(E.UserInputType.Keyboard, 0, 0, E.KeyCode[name]) end
check("fixed attribution is part of the window and launcher", node("Attribution", window.Frame).Text == "Project UAI | UI LIB." and node("Attribution", node("Restore")).Text == "Project UAI | UI LIB.")
check("public metadata points to this repository", UI.Version == "1.1.0" and UI.URL:find("Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua", 1, true) ~= nil)
check("window chrome draws the mark and leaves the window controls unfilled",
	node("Brand", window._header) ~= nil and window._minimize.BackgroundTransparency == 1 and window._close.BackgroundTransparency == 1)
local changes, commits = 0, 0
local toggle = section:Toggle({ Id = "enabled", Text = "Enable", Default = true, Callback = function() changes = changes + 1 end })
local checkbox = section:Checkbox({ Id = "check", Text = "Remember", Default = false })
local slider = section:Slider({ Id = "amount", Text = "Amount", Min = -1, Max = 1, Step = 0.1, Default = 0, Callback = function() changes = changes + 1 end, OnCommit = function() commits = commits + 1 end })
local text = section:Input({ Id = "text", Text = "Name", Default = "hello", MaxLength = 5 })
local numeric = section:Input({ Id = "numeric", Text = "Limit", Numeric = true, Default = 4, Min = 1, Max = 10 })
local dropdown = section:Dropdown({ Id = "choice", Text = "Choice", Options = { "A", "B", "C" }, Default = "A" })
local multi = section:Dropdown({ Id = "multi", Text = "Include", Options = { "A", "B", "C" }, Default = { "A" }, Multi = true })
local segmented = section:Segmented({ Id = "segment", Text = "Mode", Options = { "Fast", "Balanced", "Quiet" }, Default = "Balanced" })
local targetPlayer = section:Dropdown({
	Id = "players", Text = "Player", Default = 1, Options = {
		{ Label = "TestPlayer", Value = 1, Image = "rbxthumb://type=AvatarHeadShot&id=1&w=150&h=150" },
		{ Label = "Builder", Value = 2 },
	},
})
local color = section:ColorPicker({ Id = "color", Text = "Color", Default = dt.Color3.fromRGB(217, 119, 87), Alpha = 0.75 })
section:Label({ Text = "A label" })
section:Paragraph({ Text = "Paragraph", Content = "A wrapping body." })
section:Divider({ Text = "Display" })
local badge = section:Badge({ Id = "badge", Text = "Status", Default = "Ready", Kind = "Success" })
local progress = section:Progress({ Id = "progress", Text = "Progress", Default = 25 })
check("construction is callback-free", changes == 0 and commits == 0)
check("all controls are registered without invalid Roblox properties", window:Get("amount") == slider and #h.instanceState.typeErrors == 0)
check("duplicate control IDs are rejected", not pcall(function() section:Toggle({ Id = "enabled" }) end))
check("invalid slider range is rejected", not pcall(function() section:Slider({ Min = 10, Max = 10 }) end))
local oldCount = #section.Controls
check("invalid constructor leaves no partial control", not pcall(function() section:Dropdown({ Id = "bad-default", Options = { "A" }, Default = "B" }) end) and #section.Controls == oldCount and window:Get("bad-default") == nil)
check("option images must be strings", not pcall(function() section:Dropdown({ Id = "bad-image", Options = { { Label = "X", Value = "x", Image = 5 } } }) end) and window:Get("bad-image") == nil)
local defaultToggle = section:Toggle({ Text = "Default" })
check("omitting a toggle default means false", defaultToggle:Get() == false)
defaultToggle:Destroy()
check("NaN values are rejected", not pcall(function() slider:Set(0 / 0) end))
toggle:Set(false)
toggle:Set(false)
check("false values and duplicate updates are handled", toggle:Get() == false and changes == 1)
local observed = 0
local unsubscribe = toggle:OnChanged(function(value) if value then observed = observed + 1 end end)
toggle:Set(true); unsubscribe(); toggle:Set(false, true)
check("value subscriptions unsubscribe and silent updates stay silent", observed == 1 and changes == 2)
node("Toggle", checkbox.Frame).Activated:Fire()
check("checkbox has a real activation path", checkbox:Get() == true)
slider:Set(0.37, true)
check("fractional slider steps are relative to Min", math.abs(slider:Get() - 0.4) < 0.000001)
slider:Set(30, true)
check("slider programmatic values clamp", slider:Get() == 1)
local uneven = section:Slider({ Text = "Uneven range", Min = 0, Max = 10, Step = 3 })
uneven:Set(10)
check("non-divisible slider maximum is reachable", uneven:Get() == 10)
uneven:Destroy()

local hit, track = node("Slider", slider.Frame), node("Track", slider.Frame)
local function pointer(kind, fraction)
	return input(kind, track.AbsolutePosition.X + track.AbsoluteSize.X * fraction, track.AbsolutePosition.Y)
end
local first, second = pointer(E.UserInputType.Touch, 0.2), pointer(E.UserInputType.Touch, 0.9)
hit.InputBegan:Fire(first)
check("touch press updates the slider", math.abs(slider:Get() + 0.6) < 0.000001)
hit.InputBegan:Fire(second); uis.InputChanged:Fire(second)
uis.InputChanged:Fire(pointer(E.UserInputType.MouseMovement, 0.8))
uis.InputEnded:Fire(second)
check("another finger or mouse cannot hijack a touch gesture", math.abs(slider:Get() + 0.6) < 0.000001 and commits == 0)
first.Position = pointer(E.UserInputType.Touch, 0.7).Position
uis.InputChanged:Fire(first); uis.InputEnded:Fire(first); uis.InputEnded:Fire(first)
check("original touch ends and commits exactly once", math.abs(slider:Get() - 0.4) < 0.000001 and commits == 1)
hit.InputBegan:Fire(pointer(E.UserInputType.MouseButton1, 0.4))
uis.InputChanged:Fire(pointer(E.UserInputType.MouseMovement, 0.8))
uis.InputEnded:Fire(pointer(E.UserInputType.MouseButton1, 0.8))
check("mouse release outside a slider commits", math.abs(slider:Get() - 0.6) < 0.000001 and commits == 2)
slider:SetDisabled(true)
hit.InputBegan:Fire(first)
check("disabled slider ignores pointer input", slider:Get() == 0.6 and window._gesture == nil)
slider:SetDisabled(false)
hit.InputBegan:Fire(key("Right"))
check("keyboard adjusts the slider", math.abs(slider:Get() - 0.7) < 0.000001)
local victim
victim = section:Slider({ Text = "Teardown", Callback = function() victim:Destroy() end })
local victimHit = node("Slider", victim.Frame)
victimHit.InputBegan:Fire(input(E.UserInputType.MouseButton1, victimHit.AbsolutePosition.X + 20))
check("a callback may destroy its own control during a gesture", not victim.Alive and window._gesture == nil)

text:Set("😀ab")
check("text limits preserve UTF-8 boundaries", text:Get() == "😀a")
local numericField = node("Input", numeric.Frame)
numericField.Text = "invalid"; numericField.FocusLost:Fire()
check("invalid numeric draft preserves the last valid value", numeric:Get() == 4 and node("Validation", numeric.Frame).Visible)
numericField.Text = "7"; numericField.FocusLost:Fire()
check("numeric draft commits after correction", numeric:Get() == 7 and not node("Validation", numeric.Frame).Visible)
local live = section:Input({ Text = "Live amount", Numeric = true, Live = true, Default = 1 })
local liveField = node("Input", live.Frame)
liveField.Focused:Fire(); liveField.Text = "1."
check("live numeric input preserves an unfinished decimal", live:Get() == 1 and liveField.Text == "1.")
liveField.Text = "1.5"
check("live numeric input accepts fractional edits", live:Get() == 1.5)
liveField.Text = "-"
check("incomplete numeric drafts preserve committed state", live:Get() == 1.5 and liveField.Text == "-")
liveField.Text = "2.50"; liveField.FocusLost:Fire()
check("focus loss canonicalizes a live draft", live:Get() == 2.5 and liveField.Text == "2.5")
live:OnChanged(function(value) if value == 3 then live:Set(4, true) end end)
liveField.Text = "3"
check("live callbacks can replace their value without stale draft rendering", live:Get() == 4 and liveField.Text == "4")
live:Destroy()
progress:Set(130); badge:Set("Complete")
check("progress and status have live state", progress:Get() == 100 and badge:Get() == "Complete")

local menu = dropdown:Open()
local lastOption = node("Option_3", menu.Root)
check("a short dropdown fits its choices without unnecessary scrolling", lastOption.AbsolutePosition.Y + lastOption.AbsoluteSize.Y <= menu.Body.AbsolutePosition.Y + menu.Body.AbsoluteSize.Y - 8)
node("SearchOptions", menu.Root).Text = "B"
check("dropdown search filters visible choices", not node("Option_1", menu.Root).Visible and node("Option_2", menu.Root).Visible)
node("Option_2", menu.Root).Activated:Fire()
check("single selection closes its picker", dropdown:Get() == "B" and window._overlay == nil)
local fieldAvatar = node("Avatar", targetPlayer.Frame)
check("the selected player profile renders at the start of the closed field",
	fieldAvatar.Visible and node("AvatarImage", fieldAvatar).Image:find("rbxthumb", 1, true) ~= nil
		and node("AvatarInitial", fieldAvatar).Text == "T")
menu = targetPlayer:Open()
local firstRow, secondRow = node("Option_1", menu.Root), node("Option_2", menu.Root)
local rowAvatar = node("Avatar", firstRow)
check("a player option shows its profile before its label",
	rowAvatar.Visible and rowAvatar.AbsolutePosition.X < node("OptionLabel", firstRow).AbsolutePosition.X
		and h.byName("Avatar", secondRow) == nil)
node("Option_2", menu.Root).Activated:Fire()
check("choosing an option without an image clears the field avatar",
	targetPlayer:Get() == 2 and not fieldAvatar.Visible)
targetPlayer:Set(1, true)
menu = multi:Open()
node("Option_2", menu.Root).Activated:Fire()
check("multi-select stays open and adds a value", #multi:Get() == 2 and not menu.Closed)
local copy = multi:Get(); copy[1] = "corruption"
check("array getters do not expose internal state", multi:Get()[1] == "A")
menu:Close()
multi:SetOptions({ "B", "D" })
check("dynamic options prune missing selections", #multi:Get() == 1 and multi:Get()[1] == "B")
local beforeChoices = multi:Get()[1]
check("invalid options leave existing choices intact", not pcall(function() multi:SetOptions({ "X", "X" }) end) and multi:Get()[1] == beforeChoices)
dropdown:SetOptions({})
menu = dropdown:Open()
check("empty dropdown has a clear state", node("EmptyOptions", menu.Root).Visible and dropdown:Get() == nil)
menu:Close()
segmented:Set("Quiet")
check("segmented control updates selection", segmented:Get() == "Quiet")

local picker = color:Open()
node("Hex", picker.Root).Text = "#00FF00"; node("Hex", picker.Root).FocusLost:Fire()
node("Cancel", picker.Root).Activated:Fire()
check("color cancel leaves committed state unchanged", color:Get().R > 0.8 and color:GetAlpha() == 0.75)
picker = color:Open()
node("Hex", picker.Root).Text = "#00FF00"; node("Hex", picker.Root).FocusLost:Fire()
node("Apply", picker.Root).Activated:Fire()
check("color Apply commits the draft", color:Get().G == 1 and color:Get().R == 0)
color:SetAlpha(0.25)
check("alpha can be updated separately", color:GetAlpha() == 0.25)
check("out-of-range color components are rejected", not pcall(function() color:Set(dt.Color3.new(1.1, 0, 0)) end) and color:Get().G == 1)
picker = color:Open()
node("Hex", picker.Root).Text = "invalid"; node("Hex", picker.Root).FocusLost:Fire()
node("Apply", picker.Root).Activated:Fire()
check("invalid color draft cannot be applied", not picker.Closed and node("Validation", picker.Root).Visible)
picker:Close()

local activation, rebound = {}, 0
local binding = section:Keybind({ Id = "key", Text = "Hold", Default = E.KeyCode.K, Mode = "Hold", Callback = function(active) activation[#activation + 1] = active end, OnChanged = function() rebound = rebound + 1 end })
uis.InputBegan:Fire(key("K"), true)
check("processed keys do not activate a binding", #activation == 0)
focused = numericField; numericField.Focused:Fire(); uis.InputBegan:Fire(key("K"), false); focused = nil; numericField.FocusLost:Fire()
check("typing does not activate a binding", #activation == 0)
uis.InputBegan:Fire(key("K"), false); uis.InputEnded:Fire(key("K"), true)
check("hold key releases even when the release is processed", #activation == 2 and activation[1] == true and activation[2] == false)
uis.InputBegan:Fire(key("K"), false); window:Minimize()
check("minimizing releases held logic and retains branded launcher", activation[#activation] == false and not window.Visible and node("Restore").Visible)
local launcher = node("Restore")
check("the minimized pill carries the mark, title, status and attribution",
	node("Brand", launcher) ~= nil and node("RestoreTitle", launcher).Text == "Library contract"
		and node("RestoreDetail", launcher).Text ~= "" and node("Attribution", launcher).Text == "Project UAI | UI LIB.")
local pillStart = launcher.AbsolutePosition
launcher.InputBegan:Fire(input(E.UserInputType.MouseButton1, pillStart.X + 10, pillStart.Y + 10))
uis.InputChanged:Fire(input(E.UserInputType.MouseMovement, pillStart.X + 70, pillStart.Y + 10))
uis.InputEnded:Fire(input(E.UserInputType.MouseButton1, pillStart.X + 70, pillStart.Y + 10))
check("the pill can be dragged out of the way", launcher.AbsolutePosition.X > pillStart.X + 20 and not window.Visible)
launcher.Activated:Fire()
check("a drag release does not restore the window", not window.Visible)
launcher.InputBegan:Fire(input(E.UserInputType.Touch, launcher.AbsolutePosition.X + 10, launcher.AbsolutePosition.Y + 10))
launcher.Activated:Fire()
check("a click restores the minimized window", window.Visible and not launcher.Visible)
window:Minimize()
local launcherScale = node("LauncherScale", launcher)
window:Notify({ Title = "While minimized", Duration = 0 })
check("a notification while minimized nudges the pill", launcherScale.Scale > 1)
h.settle(0.3)
check("the nudged pill settles back", launcherScale.Scale == 1)
while #window._toasts > 0 do window._toasts[1]:Close() end
window:Show()
node("Keybind", binding.Frame).Activated:Fire(); uis.InputBegan:Fire(key("L"), false)
check("key capture updates the binding without activation", binding:Get() == E.KeyCode.L and rebound == 1 and window._capture == nil)
node("Keybind", binding.Frame).Activated:Fire(); window:Hide(); uis.InputBegan:Fire(key("M"), false)
check("hiding cancels pending key capture", binding:Get() == E.KeyCode.L and window._capture == nil)
window:Show()
check("window toggle key cannot be rebound", not pcall(function() binding:Set(E.KeyCode.RightShift) end))
local tab2 = window:Tab({ Title = "Second" })
tab2:Select(); uis.InputBegan:Fire(key("L"), false); uis.InputEnded:Fire(key("L"))
check("shortcuts stay available across tabs", activation[#activation] == false and #activation == 6)
tab:Select()

local secret = section:Input({ Id = "secret", Text = "Transient", Default = "not saved", Persist = false })
toggle:Set(false, true); slider:Set(0.3, true)
local saved = window:ExportConfig()
local document = h.json.decode(saved)
check("config omits transient values and serializes typed colors and keys", document.values.secret == nil and document.values.color.value.alpha == 0.25 and document.values.key.value == "L")
toggle:Set(true, true); slider:Set(0.9, true); color:SetAlpha(1, true); binding:Set(nil, true)
local oldChanges, oldActivations = changes, #activation
local ok, restored = window:ImportConfig(saved)
check("config round-trips booleans, sliders, colors and keybinds", ok and restored >= 10 and toggle:Get() == false and slider:Get() == 0.3 and color:GetAlpha() == 0.25 and binding:Get() == E.KeyCode.L)
check("import is silent and does not activate keybinds", changes == oldChanges and #activation == oldActivations)
document.values.enabled.value = true; document.values.amount.value = "bad"
ok = window:ImportConfig(h.json.encode(document))
check("invalid import is atomic", not ok and toggle:Get() == false and slider:Get() == 0.3)
document = h.json.decode(saved); document.window = "another-script"
check("configs cannot target a different window", not window:ImportConfig(h.json.encode(document)))
local configComplete = false
local stop = toggle:OnChanged(function() configComplete = slider:Get() == 0.3 end)
toggle:Set(true, true); slider:Set(0.8, true)
window:ImportConfig(saved, { Silent = false }); stop()
check("opt-in callbacks see the complete restored state", configComplete)
ok, saved = window:SaveConfig("default")
check("explicit filesystem save verifies its contents", ok and type(h.files[saved]) == "string")
slider:Set(0.8, true); ok = window:LoadConfig("default")
check("explicit profile load restores saved state", ok and slider:Get() == 0.3)
check("profile names cannot traverse directories", not window:SaveConfig("../escape"))

local transaction = UI:CreateWindow({ Id = "config-cleanup", ToggleKey = false })
local transactionSection = transaction:Tab("Main"):Section("State")
local restoredFlag = transactionSection:Toggle({ Id = "z-value", Default = true })
local releasedAfterRestore, releaseCount = false, 0
transactionSection:Keybind({ Id = "a-key", Default = E.KeyCode.J, Mode = "Hold", Callback = function(active)
	if not active then
		releasedAfterRestore, releaseCount = restoredFlag:Get(), releaseCount + 1
		transaction:Destroy()
	end
end })
local transactionConfig = transaction:ExportConfig()
restoredFlag:Set(false, true); uis.InputBegan:Fire(key("J"), false)
local imported = transaction:ImportConfig(transactionConfig)
check("config releases active holds after restoring all values, even when cleanup destroys the window", imported and releasedAfterRestore and releaseCount == 1 and not transaction.Alive)

window._search.Text = "no matching label"
check("search has an empty state", node("EmptySearch").Visible)
window._search.Text = "Amount"
check("search filters by control label", slider.Frame.Visible and not toggle.Frame.Visible and not node("EmptySearch").Visible)
window._search.Text = ""
section:SetCollapsed(true)
check("collapsing a section hides its body", not section._body.Visible)
window._search.Text = "Amount"
check("search reveals a matching collapsed section", section._body.Visible)
window._search.Text = ""; section:SetCollapsed(false)

for _, viewport in ipairs({ { 1280, 720, false }, { 390, 844, true }, { 844, 390, true }, { 320, 568, true } }) do
	uis.TouchEnabled = viewport[3]
	h.setViewport(viewport[1], viewport[2])
	window:_Layout()
	local size, position = window.Frame.AbsoluteSize, window.Frame.AbsolutePosition
	check("window stays in " .. viewport[1] .. "x" .. viewport[2], position.X >= 0 and position.Y >= 0 and position.X + size.X <= viewport[1] and position.Y + size.Y <= viewport[2])
	check("controls retain readable width at " .. viewport[1], slider._slot.AbsoluteSize.X > 150 and toggle._label.AbsoluteSize.X > 100)
	check("the header mark stays visible at " .. viewport[1], window._brand.Visible)
	if viewport[3] then check("touch targets remain at least 44px", window.Target >= 44) end
end
window:SetTextScale(1.5)
check("large text expands controls without shrinking the UI", window.Target >= 54 and slider.Frame.AbsoluteSize.Y > 90)
check("large-text status rows preserve label width on a small phone", badge._label.AbsoluteSize.X > 200 and badge._slot.AbsolutePosition.Y > badge._label.AbsolutePosition.Y)
uis.OnScreenKeyboardVisible = true; uis.OnScreenKeyboardSize = dt.Vector2.new(320, 260); uis.OnScreenKeyboardPosition = dt.Vector2.new(0, 308)
window:_Layout()
check("window footer avoids the software keyboard", window.Frame.AbsolutePosition.Y + window.Frame.AbsoluteSize.Y <= 308)
uis.OnScreenKeyboardVisible = false
window:SetTextScale(1); h.setViewport(1280, 720); uis.TouchEnabled = false; window:_Layout()
window:SetTheme("Light")
check("theme updates existing surfaces", window.Frame.BackgroundColor3.R > 0.9)
window:SetTheme("Dark")

local dialog = window:Dialog({ Title = "Review", Content = "Proceed?", Dismissible = false, Buttons = { { Text = "Done", Style = "Primary" } } })
uis.InputBegan:Fire(key("Escape"), false)
check("nondismissible dialog ignores Escape", not dialog.Closed)
node("DialogAction_1", dialog.Root).Activated:Fire()
check("dialog buttons close and attribution is library-owned", dialog.Closed and window._overlay == nil)
local snapshots = { scope = count(window._scope.items), paint = count(window._paint), reflow = count(window._reflow) }
for _ = 1, 20 do dropdown:Open():Close() end
check("repeated pickers do not retain scopes or theme/layout subscriptions", snapshots.scope == count(window._scope.items) and snapshots.paint == count(window._paint) and snapshots.reflow == count(window._reflow))
local calls = 0
local action = section:Button({ Text = "Async", Callback = function() h.sandbox.task.wait(0.1); calls = calls + 1 end })
action:Press(); action:Press(); h.settle(0.2)
check("loading buttons suppress duplicate actions", calls == 1 and not action.Loading)
local failure = section:Button({ Text = "Error", Callback = function() error("expected callback failure") end })
failure:Press(); h.settle(0.2)
check("callback exceptions are reported without breaking the library", not failure.Loading and #window._toasts > 0 and #h.errors() == 0)
for index = 1, 5 do window:Notify({ Title = "Notice " .. index, Duration = 0 }) end
check("notifications are bounded", #window._toasts == 3)
uis.TouchEnabled = true; h.setViewport(320, 240); window:_Layout()
local newest
for index = 1, 3 do
	newest = window:Notify({ Title = string.rep("Long title ", 30), Content = string.rep("x", 799) .. "😀", Duration = 0, Action = { Text = "Open" } })
end
local occupied, visible = 0, 0
for _, toast in ipairs(window._toasts) do
	if toast.Frame.Visible then occupied = occupied + toast.Frame.Size.Y.Offset; visible = visible + 1 end
end
check("long notifications fit a short viewport and prioritize the newest", newest.Frame.Visible and visible < 3 and occupied + (visible - 1) * 8 <= window._toastHost.Size.Y.Offset)
check("notification truncation preserves UTF-8 boundaries", #node("Message", newest.Frame).Text == 799)
newest:Close()
check("closing the newest notification reveals a retained notice", window._toasts[#window._toasts].Frame.Visible)
uis.TouchEnabled = false; h.setViewport(1280, 720); window:_Layout()
local cleaned = 0
window:Give(function() cleaned = cleaned + 1 end)
local unrelated = h.Instance.new("ScreenGui", h.coreGui)
unrelated.Name = "Another application"
local independent = UI:CreateWindow({ Id = "independent", Title = "Other window" })
local noKey = UI:CreateWindow({ Id = "no-shortcut", ToggleKey = false, Search = false })
check("search defaults on and can be explicitly disabled", independent._search ~= nil and noKey._search == nil)
uis.InputBegan:Fire(key("RightShift"), false)
check("false disables a window's default shortcut", noKey.Visible and noKey.ToggleKey == false)
noKey:Destroy()
local newUI = assert(h.boot("dist/uai-ui.lua"))
local replacement = newUI:CreateWindow({ Id = "test" })
check("rerun destroys only the matching owned window and cleans logic once", not window.Alive and cleaned == 1 and independent.Alive and unrelated.Parent == h.coreGui)
window:Destroy()
check("destruction is idempotent", cleaned == 1)
check("destroyed handles no longer retain paint or global listeners", count(window._scope.items) == 0 and count(window._paint) == 0 and count(window._reflow) == 0)
newUI:DestroyAll()
check("DestroyAll preserves nonlibrary GUIs", not replacement.Alive and not independent.Alive and unrelated.Parent == h.coreGui)
check("all scenarios avoid uncaught tasks and invalid property types", #h.errors() == 0 and #h.instanceState.typeErrors == 0)

local bare, bareUI = boot()
bare.sandbox.writefile, bare.sandbox.makefolder, bare.sandbox.readfile = nil, nil, nil
local bareWindow = bareUI:CreateWindow({ Id = "bare", Parent = bare.localPlayer:FindFirstChildOfClass("PlayerGui") })
bareWindow:Tab("Main"):Section("Settings"):Toggle({ Id = "test", Default = true })
check("JSON config works without executor filesystem functions", bareWindow:ImportConfig(bareWindow:ExportConfig()) == true)
check("missing filesystem is reported instead of crashing", bareWindow:SaveConfig("default") == false and bareWindow:LoadConfig("default") == false)
bareWindow.ScreenGui:Destroy()
check("external ScreenGui removal releases the library window", not bareWindow.Alive and bareUI:GetWindow("bare") == nil)

local function read(path) local file = assert(io.open(path, "rb")); local source = file:read("*a"); file:close(); return source end
for _, name in ipairs({ "starter", "showcase" }) do
	local demo = envMock.new()
	local fetched = 0
	demo.game.HttpGet = function(_, url)
		assert(url == UI.URL, "example uses a different library URL")
		fetched = fetched + 1
		return read("dist/uai-ui.lua")
	end
	local fn = assert(demo.sandbox.loadstring(read("ui-lib/examples/" .. name .. ".lua"), name))
	local result = fn()
	demo.settle(0.1)
	check(name .. " example runs with the public loadstring contract", result.Alive and fetched == 1 and #demo.errors() == 0 and #demo.instanceState.typeErrors == 0)
	result:Destroy()
end
print("UI LIB: " .. passed .. " checks passed")
