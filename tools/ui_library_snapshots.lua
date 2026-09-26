-- Export the public showcase for offline visual inspection after manual review.
-- luajit tools/ui_library_snapshots.lua [output directory]
-- node test/render_mobile.js <output directory>
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local directory = arg[1] or "refer/ui-library-review"
local function read(path)
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a"); file:close(); return source
end
local library, example = read("dist/uai-ui.lua"), read("ui-lib/examples/showcase.lua")
local properties = {
	"Size", "Position", "AnchorPoint", "Visible", "AutomaticSize", "BackgroundColor3", "BackgroundTransparency",
	"ClipsDescendants", "ZIndex", "LayoutOrder", "Rotation", "Text", "TextSize", "TextColor3", "TextTransparency",
	"TextXAlignment", "TextYAlignment", "TextWrapped", "TextTruncate", "RichText", "Font", "LineHeight",
	"PlaceholderText", "PlaceholderColor3", "FillDirection", "SortOrder", "Padding", "HorizontalAlignment", "VerticalAlignment",
	"PaddingLeft", "PaddingRight", "PaddingTop", "PaddingBottom", "CornerRadius", "Color", "Thickness", "Transparency",
	"CanvasPosition", "ScrollingDirection", "ScrollBarThickness", "ScrollingEnabled",
}
local function serialize(value)
	if type(value) ~= "table" then return value end
	if value.EnumType then return value.Name end
	if value.Keypoints then
		local points = {}
		for _, point in ipairs(value.Keypoints) do points[#points + 1] = { time = point.Time, value = serialize(point.Value) } end
		return { keypoints = points }
	end
	if value.R then return { value.R, value.G, value.B } end
	if value.X and type(value.X) == "table" then return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset } end
	if value.X then return { value.X, value.Y } end
	if value.Scale then return { value.Scale, value.Offset } end
	return tostring(value)
end
local function tree(node)
	local result = { class = node.ClassName, name = node.Name, props = {}, children = {} }
	for _, key in ipairs(properties) do
		if node.__props[key] ~= nil or node.__defaults[key] ~= nil then result.props[key] = serialize(node[key]) end
	end
	for _, child in ipairs(node:GetChildren()) do
		if child:IsA("GuiObject") or child:IsA("UIComponent") then result.children[#result.children + 1] = tree(child) end
	end
	return result
end
for _, viewport in ipairs({ { 1280, 800, false }, { 390, 844, true }, { 844, 390, true }, { 320, 568, true } }) do
	local h = envMock.new()
	h.services.UserInputService.TouchEnabled = viewport[3]
	h.setViewport(viewport[1], viewport[2])
	h.game.HttpGet = function() return library end
	local window = assert(h.sandbox.loadstring(example, "showcase"))()
	local prefix = (viewport[3] and "mobile-" or "desktop-") .. viewport[1] .. "x" .. viewport[2]
	local function snapshot(name, keyboard)
		h.settle(0.1)
		local file = assert(io.open(directory .. "/" .. prefix .. "-" .. name .. ".json", "wb"))
		file:write(h.json.encode({ name = name, engine = "LuaJIT", width = viewport[1], height = viewport[2],
			keyboard = keyboard or 0, root = tree(window.ScreenGui) }))
		file:close()
		print("snapshot " .. prefix .. "-" .. name)
	end
	snapshot("overview")
	window:SelectTab("Controls"); snapshot("controls")
	window:Get("mode"):Open(); snapshot("dropdown"); window:_CloseOverlay()
	window:SelectTab("Appearance"); window:Get("color"):Open(); snapshot("color"); window:_CloseOverlay()
	window:SelectTab("Overview"); window:SetTheme("Light"); snapshot("light"); window:SetTheme("Dark")
	window:Dialog({ Title = "Reset session?", Content = "Your selection and progress will return to their defaults.", Buttons = {
		{ Text = "Cancel" }, { Text = "Reset", Style = "Danger" },
	} }); snapshot("dialog"); window:_CloseOverlay()
	for index = 1, 3 do window:Notify({ Title = "Workspace updated", Content = "Your selection is ready. Changes are available for this session.", Kind = "Success", Duration = 0 }) end
	snapshot("notifications")
	while #window._toasts > 0 do window._toasts[1]:Close() end
	window:Minimize(); snapshot("minimized"); window:Show()
	window:SelectTab("Overview"); window:SetTextScale(1.5); snapshot("large-text"); window:SetTextScale(1)
	if viewport[3] then
		local keyboard = math.floor(viewport[2] * 0.42)
		h.services.UserInputService.OnScreenKeyboardVisible = true
		h.services.UserInputService.OnScreenKeyboardSize = h.dt.Vector2.new(viewport[1], keyboard)
		h.services.UserInputService.OnScreenKeyboardPosition = h.dt.Vector2.new(0, viewport[2] - keyboard)
		window:_Layout(); snapshot("keyboard", keyboard)
	end
	window:Destroy()
end
