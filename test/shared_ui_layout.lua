-- Source-level shared UI regressions. No bundle or application boot required.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local luau = require("luau")
local h = envMock.new()

-- This source scenario opens quick chat and captures focus. The general instance
-- mock does not model TextBox focus, so supply the lifecycle used by this test.
local newInstance = h.Instance.new
local focusedBox
function h.Instance.new(className, parent)
	local instance = newInstance(className, parent)
	if className == "TextBox" then
		function instance.ReleaseFocus(_, enterPressed)
			if focusedBox ~= instance then return end
			focusedBox = nil
			instance.FocusLost:Fire(enterPressed == true)
		end
		function instance.CaptureFocus()
			if focusedBox == instance then return end
			if focusedBox then focusedBox:ReleaseFocus() end
			focusedBox = instance
			instance.Focused:Fire()
		end
		instance.Destroying:Connect(function() if focusedBox == instance then focusedBox = nil end end)
	end
	return instance
end
h.services.UserInputService.GetFocusedTextBox = function() return focusedBox end
local cache, captured = {}, {}
local env = {
	services = h.services, uis = h.services.UserInputService, guisvc = h.services.GuiService,
	tween = { Create = function(_, target, info, goals)
		local tween = h.services.TweenService:Create(target, info, goals)
		captured[#captured + 1] = { target = target, goals = goals, tween = tween }
		return tween
	end },
}
function env.require(id)
	if cache[id] then return cache[id] end
	local file = assert(io.open("src/" .. id .. ".lua", "rb"))
	local source = file:read("*a"); file:close()
	local chunk, problems = luau.load(source, id)
	assert(chunk, problems and problems[1] and problems[1].msg)
	setfenv(chunk, h.sandbox)
	cache[id] = chunk()(env)
	return cache[id]
end
local signal = env.require("runtime/signal")
local settings = {}
cache["runtime/config"] = {
	get = function(path, default) if settings[path] ~= nil then return settings[path] end return default end,
	set = function(path, value) settings[path] = value end,
	changed = signal.new("config"),
}
cache["runtime/caps"] = { clipboard = false }
cache["ui/icons"] = { draw = function() end, check = function() end, close = function() end, chevron = function() end }
cache["ui/brand"] = { draw = function() end }
cache["agent/session"] = { current = function() return { send = function() return true end } end }
cache["provider/registry"] = { active = function() return { label = "Provider" } end }
local responsive = env.require("ui/responsive")
local P = env.require("ui/primitives")
local theme = env.require("ui/theme")
local overlay = env.require("ui/overlay")
local dispose = env.require("runtime/dispose")
local V, U, E = h.dt.Vector2, h.dt.UDim2, h.sandbox.Enum
local root = h.Instance.new("Frame")
local passed = 0
local function check(label, value)
	assert(value, label)
	passed = passed + 1
	print("ok " .. label)
end
local function viewport(width, height, keyboard, inset)
	responsive.viewport = V.new(width, height)
	responsive.inset = V.new(0, inset or 36)
	responsive.keyboardHeight = keyboard or 0
	responsive.bottomInset = 0
	responsive.mode = width < 520 and "sheet" or "window"
	root.Size = U.fromOffset(width, height - responsive.inset.Y)
	root.Position = U.fromOffset(0, responsive.inset.Y)
	responsive.changed:fire({ reason = "test" })
end
viewport(1000, 700)
local bounds = responsive.usableRect(root, 8)
check("safe bounds do not subtract the top inset twice", bounds.y == 8 and bounds.height == 648)

local row = P.rowButton(root, { auto = "Y", vertical = true })
check("auto-height row content retains the parent's width", row.row.Size.X.Scale == 1 and row.row.Size.Y.Offset == 0)
local chip = P.rowButton(root, { auto = "X", size = U.fromOffset(0, 28) })
local chipLabel = chip.label("A short label")
check("auto-width row labels contribute intrinsic width", chipLabel.AutomaticSize == E.AutomaticSize.X and chipLabel:FindFirstChildOfClass("UIFlexItem") == nil)
local large = P.text(root, { text = "A", auto = "X", textSize = 32, line = 1.5 })
check("auto-width text honours custom line height", large.Size.Y.Offset >= 48)
local horizontal = P.scroll(root, { horizontal = true })
horizontal.instance.AbsoluteWindowSize = V.new(100, 30)
horizontal.instance.AbsoluteCanvasSize = V.new(300, 30)
horizontal.instance.CanvasPosition = V.new(0, 0)
check("horizontal atBottom checks the scroll axis", not horizontal.atBottom(0))
horizontal.toBottom()
check("horizontal toBottom reaches the trailing edge", horizontal.atBottom(0) and horizontal.instance.CanvasPosition.X == 200)
local paddedScroll = P.scroll(root, { padding = { x = 12, top = 4, bottom = 8 } })
paddedScroll.instance.AbsoluteWindowSize = V.new(200, 100)
check("nested scroll viewport excludes its padding", paddedScroll.viewportSize().X == 176 and paddedScroll.viewportSize().Y == 88)
local flexScroll = P.scroll(root, { flex = "Fill" })
P.text(flexScroll.instance, { text = "Clear me" })
flexScroll.clear()
check("clearing scroll content preserves flex layout metadata", flexScroll.instance:FindFirstChildOfClass("UIFlexItem") ~= nil and flexScroll.instance:FindFirstChildOfClass("TextLabel") == nil)
local controls = env.require("ui/controls")
local options = { { label = "I", value = "i" }, { label = "Longer option", value = "long" } }
local segmentWidth = controls.segmentedWidth(options)
check("equal segments reserve the longest label in each share", segmentWidth >= (P.measureText("Longer option", { role = "label" }).X + theme.space.md * 2) * 2)

for _, density in ipairs({ "comfortable", "compact" }) do
	for _, scale in ipairs({ 0.85, 1, 1.4 }) do
		settings["ui.density"], settings["ui.fontScale"] = density, scale
		theme.rebuild()
		local badge, badgeLabel = P.badge(root, { text = "Scaled status", dot = true })
		local badgePadding = badge:FindFirstChildOfClass("UIPadding")
		check("badge fits scaled caption at " .. density .. "/" .. scale,
			badge.Size.Y.Offset - badgePadding.PaddingTop.Offset - badgePadding.PaddingBottom.Offset >= theme.text.caption.height
			and badge.AutomaticSize == E.AutomaticSize.XY and badgeLabel.AutomaticSize == E.AutomaticSize.XY)
		badge:Destroy()
		for _, input in ipairs({ "pointer", "touch", "console" }) do
			responsive.touch, responsive.console = input == "touch", input == "console"
			local segments = controls.segmented(root, { options = options })
			local padding = segments.instance:FindFirstChildOfClass("UIPadding")
			local targetHeight = segments.instance.Size.Y.Offset - padding.PaddingTop.Offset - padding.PaddingBottom.Offset
			check("segment hit area fits " .. input .. " at " .. density .. "/" .. scale,
				targetHeight >= responsive.minTarget() and targetHeight >= theme.text.label.height)
			segments.instance:Destroy()
		end
	end
end
settings["ui.density"], settings["ui.fontScale"] = nil, nil
responsive.touch, responsive.console = false, false
theme.rebuild()

-- Headshots must initiate loading without blocking UI construction. Exercise
-- delayed readiness, failures, and closing a view while the native API yields.
env.plr = h.localPlayer
local profile = env.require("ui/profile")
local thumbnailApi, preloadApi = h.services.Players.GetUserThumbnailAsync, h.services.ContentProvider.PreloadAsync
local thumbnailCalls, preloadCalls = 0, 0
local resolvedImage = "rbxassetid://123456789"
h.services.Players.GetUserThumbnailAsync = function(_, userId, kind, size)
	thumbnailCalls = thumbnailCalls + 1
	check("avatar requests the local player's headshot", userId == h.localPlayer.UserId and kind == E.ThumbnailType.HeadShot and size == E.ThumbnailSize.Size150x150)
	if thumbnailCalls == 1 then return "", false end
	return resolvedImage, true
end
h.services.ContentProvider.PreloadAsync = function(_, images)
	preloadCalls = preloadCalls + 1
	check("avatar is renderable while loading", images[1].ImageTransparency == 0)
	if images[1].Image == resolvedImage then images[1].IsLoaded = true end
end
local avatar = profile.avatar(root, profile.identity(), theme.size.profileAvatar)
check("avatar construction does not wait for thumbnail requests", thumbnailCalls == 0 and avatar:FindFirstChild("AvatarInitial").Visible)
h.sched.advance(0.1)
check("pending thumbnails keep the initial", thumbnailCalls == 1 and avatar:FindFirstChild("AvatarInitial").Visible)
h.sched.advance(1.1)
check("ready thumbnails replace the initial after preload", avatar:FindFirstChild("AvatarImage").Image == resolvedImage and not avatar:FindFirstChild("AvatarInitial").Visible)
h.sched.advance(4)
check("successful avatars stop retrying", thumbnailCalls == 2 and preloadCalls == 2)
avatar:Destroy()

thumbnailCalls = 0
h.services.Players.GetUserThumbnailAsync = function() thumbnailCalls = thumbnailCalls + 1; error("thumbnail unavailable") end
h.services.ContentProvider.PreloadAsync = function() error("image fetch failed") end
local failedAvatar = profile.avatar(root, profile.identity(), theme.size.profileAvatar)
h.sched.advance(4)
check("failed thumbnail requests stay bounded and retain the initial", thumbnailCalls == 3 and failedAvatar:FindFirstChild("AvatarInitial").Visible)
failedAvatar:Destroy()

local finishedFetch, latePreload = false, false
local nativeCancel, avatarCancellations = h.sandbox.task.cancel, 0
h.sandbox.task.cancel = function(thread) avatarCancellations = avatarCancellations + 1; return nativeCancel(thread) end
h.services.Players.GetUserThumbnailAsync = function() h.sched.wait(1); finishedFetch = true; return resolvedImage, true end
h.services.ContentProvider.PreloadAsync = function() latePreload = true end
local closedAvatar = profile.avatar(root, profile.identity(), theme.size.profileAvatarLarge)
h.sched.advance(0.1)
closedAvatar:Destroy()
h.sched.advance(2)
check("closing an avatar lets the native request finish and discards its result", finishedFetch and not latePreload and avatarCancellations == 0)

local finishedPreload = false
h.services.Players.GetUserThumbnailAsync = function() return resolvedImage, true end
h.services.ContentProvider.PreloadAsync = function() h.sched.wait(1); finishedPreload = true end
local preloadingAvatar = profile.avatar(root, profile.identity(), theme.size.profileAvatar)
h.sched.advance(0.1)
preloadingAvatar:Destroy()
h.sched.advance(2)
check("destroying an avatar during preload leaves its continuation alive", finishedPreload and avatarCancellations == 0 and #h.sched.errors == 0)
h.sandbox.task.cancel = nativeCancel

local originalName, originalId = env.plr.DisplayName, env.plr.UserId
env.plr.DisplayName, env.plr.UserId = "界面", 0
local invalidIdentity = profile.identity()
local invalidAvatar = profile.avatar(root, invalidIdentity, theme.size.profileAvatar)
check("invalid user IDs retain a complete Unicode initial", invalidIdentity.initial == "界" and not invalidAvatar:FindFirstChild("AvatarImage"))
invalidAvatar:Destroy()
env.plr.DisplayName, env.plr.UserId = originalName, originalId
h.services.Players.GetUserThumbnailAsync, h.services.ContentProvider.PreloadAsync = thumbnailApi, preloadApi

local facts, factValue = controls.keyValue(root, { key = "A detailed property name", value = "A value that should remain readable", keyWidth = 140 })
local factLayout = facts:FindFirstChildOfClass("UIListLayout")
local factKey
for _, child in ipairs(facts:GetChildren()) do if child:IsA("TextLabel") and child ~= factValue then factKey = child end end
check("wide key/value rows retain their two columns", factLayout.FillDirection == E.FillDirection.Horizontal and factValue.Size.X.Offset == -(140 + theme.space.sm))
facts.AbsoluteSize = V.new(190, 60)
check("narrow key/value rows stack with full-width wrapped keys and values", factLayout.FillDirection == E.FillDirection.Vertical
	and factKey.Size.X.Scale == 1 and factKey.TextWrapped and factKey.TextTruncate == E.TextTruncate.None
	and factValue.Size.X.Scale == 1 and factValue.Size.X.Offset == 0)
facts.AbsoluteSize = V.new(480, 60)
check("key/value rows restore columns when widened", factLayout.FillDirection == E.FillDirection.Horizontal and factKey.Size.X.Offset == 140 and not factKey.TextWrapped)
facts:Destroy()

overlay.mount(root)
local modal = overlay.modal({ title = "Choose a model", scroll = true, height = 520 })
check("empty footer reserves no band", modal.footer.Size.Y.Offset == 0 and not modal.footer.Visible)
local header = modal.card:FindFirstChild("Header")
check("header title width is resolved without auto-height flex", header:FindFirstChild("TitleScroll"):FindFirstChildOfClass("UIFlexItem") == nil)
local closeButton = P.button(modal.footer, { text = "Done", size = "sm" })
h.settle(0.1)
check("populated footer fits its control with compact padding", modal.footer.Visible and modal.footer.Size.Y.Offset == closeButton.instance.Size.Y.Offset + theme.space.sm * 2)
local oldBodyHeight = modal.scroll.instance.Size.Y.Offset
closeButton.instance.Visible = false; h.settle(0.1)
check("hiding the last footer action restores body space", not modal.footer.Visible and modal.footer.Size.Y.Offset == 0 and modal.scroll.instance.Size.Y.Offset > oldBodyHeight)
closeButton.instance.Visible = true; h.settle(0.1)
check("showing an action revives a collapsed footer", modal.footer.Visible and modal.scroll.instance.Size.Y.Offset == oldBodyHeight)
modal.footer.Visible = false; h.settle(0.1)
check("explicitly hiding the footer removes its band and divider", modal.footer.Size.Y.Offset == 0 and not modal.card:FindFirstChild("FooterDivider").Visible)
modal.relayout(); h.settle(0.1)
check("relayout preserves explicitly hidden footers", not modal.footer.Visible and modal.footer.Size.Y.Offset == 0)
modal.footer.Visible = true; h.settle(0.1)
check("explicitly showing the footer restores its controls", modal.footer.Visible and modal.scroll.instance.Size.Y.Offset == oldBodyHeight)
closeButton.instance.Size = U.fromOffset(80, 64); h.settle(0.1)
check("footer reacts to resized controls without a layout event", modal.footer.Size.Y.Offset == 64 + theme.space.sm * 2)
closeButton.instance:Destroy(); h.settle(0.1)
check("removing footer controls restores body room", modal.footer.Size.Y.Offset == 0 and modal.scroll.instance.Size.Y.Offset > oldBodyHeight)
viewport(360, 640, 420)
bounds = responsive.usableRect(overlay.layer, theme.space.md)
check("keyboard-visible modal can shrink below modalMin", modal.card.Size.Y.Offset <= bounds.height and modal.card.Size.Y.Offset < theme.size.modalMin)
check("keyboard-visible body never has a negative height", modal.scroll.instance.Size.Y.Offset >= 0)
check("modal lies within usable keyboard bounds", modal.card.AbsolutePosition.Y >= 36 + bounds.y - 1 and modal.card.AbsolutePosition.Y + modal.card.AbsoluteSize.Y <= 640 - 420)
local count = responsive.changed:count()
modal.scrim:Destroy()
check("external modal destruction unregisters its handle and layout", modal.closed and #overlay.open == 0 and responsive.changed:count() == count - 1)

viewport(1000, 700)
local short = overlay.modal({ title = "Prompt" })
local layout = short.content:FindFirstChildOfClass("UIListLayout")
layout.AbsoluteContentSize = V.new(200, 600)
h.settle(0.1)
check("content-sized prompts gain a bounded scrolling body", short.card.Size.Y.Offset <= responsive.usableRect(overlay.layer, theme.space.lg).height and short.scroll.instance.ScrollingEnabled)
short.close(); h.settle(1)
check("modal exits complete and release the scrim", short.scrim.Parent == nil)
local locked = overlay.modal({ title = "Waiting", dismissable = false })
env.uis.InputBegan:Fire({ KeyCode = E.KeyCode.Escape }, false)
check("Escape honours nondismissable modals", not locked.closed)
locked.close(); h.settle(1)

local target = P.frame(root, { position = U.fromOffset(120, 80), size = U.fromOffset(40, 28) })
local menu = overlay.menu({ target = target, options = { { label = "A deliberately long menu action", value = "go", detail = "Secondary line" } } })
check("menu width follows its text rather than a tiny anchor", menu.card.Size.X.Offset > theme.size.menuMin)
local menuY = menu.card.Position.Y.Offset
target.Position = U.fromOffset(120, 180)
target:GetPropertyChangedSignal("AbsolutePosition"):Fire()
check("open menu follows a moving anchor", menu.card.Position.Y.Offset > menuY)
viewport(240, 300, 180)
bounds = responsive.usableRect(overlay.layer, theme.space.xs)
check("menu dimensions remain inside narrow keyboard room", menu.card.Size.X.Offset <= bounds.width and menu.card.Size.Y.Offset <= bounds.height)
target:Destroy()
check("destroying menu target closes and unregisters menu", menu.closed and #overlay.open == 0)
local holder = P.frame(root, { size = U.fromOffset(240, 200) })
target = P.frame(holder, { size = U.fromOffset(100, 28) })
local hiddenMenu = overlay.menu({ target = target, options = { { label = "Close with parent" } } })
holder.Visible = false
check("hiding an anchor ancestor dismisses its detached menu", hiddenMenu.closed)
viewport(240, 180)
target = P.frame(root, { position = U.fromOffset(80, 50), size = U.fromOffset(100, 44) })
responsive.touch = true
local tightMenu = overlay.menu({ target = target, options = { { label = "First", value = 1 }, { label = "Second", value = 2 }, { label = "Third", value = 3 } } })
bounds = responsive.usableRect(overlay.layer, theme.space.xs)
check("short menus use safe room when neither anchor side fits a touch row", tightMenu.card.Size.Y.Offset == math.floor(bounds.height))
check("short menu rows retain full touch height inside their scroll", tightMenu.card:FindFirstChild("Option_1", true).Size.Y.Offset >= 44
	and tightMenu.card:FindFirstChild("Options").ScrollingEnabled)
tightMenu.close(); target:Destroy(); responsive.touch = false
target = P.frame(root, { size = U.fromOffset(80, 28) })
local shortcutMenu = overlay.menu({ target = target, options = { { label = "A readable action", shortcut = "Ctrl + Shift + Enter" } } })
local keycap = shortcutMenu.card:FindFirstChild("Keycap", true)
check("narrow menus prioritise action labels over optional shortcuts", not keycap.Visible)
viewport(1000, 700)
check("menu shortcuts return when the viewport has room", keycap.Visible)
shortcutMenu.close(); target:Destroy()

local windowModule = env.require("ui/window")
viewport(1000, 700)
local window = windowModule.new(root)
window.show(); window.hide(); window.show(); h.settle(1)
check("rapid hide-show keeps the window opaque and visible", window.root.Visible and window.root.ClassName == "Frame" and window.root.BackgroundTransparency == 0)
local inputSignal = require("instance").newSignal
local finger = { UserInputType = E.UserInputType.Touch, Position = h.dt.Vector3.new(100, 100, 0), Changed = inputSignal("finger") }
window.header.InputBegan:Fire(finger)
local beforeX = window.root.Position.X.Offset
env.uis.InputChanged:Fire({ UserInputType = E.UserInputType.Touch, Position = h.dt.Vector3.new(190, 100, 0) })
check("window drag ignores unrelated fingers", window.root.Position.X.Offset == beforeX)
finger.Position = h.dt.Vector3.new(140, 100, 0)
env.uis.InputChanged:Fire(finger)
check("window drag follows the initiating finger", window.root.Position.X.Offset ~= beforeX)
env.uis.WindowFocusReleased:Fire()
beforeX = window.root.Position.X.Offset
finger.Position = h.dt.Vector3.new(180, 100, 0)
env.uis.InputChanged:Fire(finger)
check("focus loss cancels drag and its input listener", window.root.Position.X.Offset == beforeX and finger.Changed:Count() == 0)
viewport(360, 640, 420)
bounds = responsive.usableRect(root, theme.space.sm)
check("sheet height floor cannot cover the keyboard", window.root.Size.Y.Offset <= bounds.height)
check("sheet fits its parent coordinates", window.root.AbsolutePosition.Y >= 36 and window.root.AbsolutePosition.Y + window.root.AbsoluteSize.Y <= 220)
count = responsive.changed:count()
window.root:Destroy()
check("external window destruction releases responsive subscription", responsive.changed:count() == count - 1 and not window.visible)

viewport(844, 390)
responsive.touch, responsive.mode, responsive.bottomInset = true, "panel", 24
local mobile = windowModule.new(root, { minHeight = 300 })
mobile.show()
bounds = responsive.usableRect(root, theme.space.sm, false)
local startX, startY = mobile.root.Position.X.Offset, mobile.root.Position.Y.Offset
check("landscape mobile panel leaves room to move without resizing", mobile.root.Size.Y.Offset < bounds.height)
h.drag(mobile.header, 600, 30, 450, 60)
check("mobile panel moves on both axes before resizing", mobile.root.Position.X.Offset ~= startX and mobile.root.Position.Y.Offset ~= startY)
local mobileGrip = mobile.root:FindFirstChild("ResizeGrip")
local gripPosition = mobileGrip.AbsolutePosition
h.drag(mobileGrip, gripPosition.X, gripPosition.Y, gripPosition.X - 60, gripPosition.Y - 40)
check("shrinking the mobile panel creates safe vertical drag room", mobile.root.Size.Y.Offset < bounds.height)
startY = mobile.root.Position.Y.Offset
local headerPosition = mobile.header.AbsolutePosition
h.drag(mobile.header, headerPosition.X + 100, headerPosition.Y + 10, headerPosition.X + 80, headerPosition.Y + 35)
check("resized mobile panel moves vertically and stays inside the safe rectangle", mobile.root.Position.Y.Offset > startY
	and mobile.root.Position.Y.Offset + mobile.root.Size.Y.Offset <= bounds.y + bounds.height)
mobile.destroy()
responsive.touch = false

viewport(1000, 700)
local quick = env.require("ui/quickchat")
quick.bind()
quick.mount(overlay.layer)
check("quick chat reserves control height before list measurement", quick.card.Size.Y.Offset > theme.space.md * 2 + theme.size.control * 2)
quick.show(); quick.hide(); quick.show(); h.settle(1)
check("quick chat entrance finishes after rapid reopen", quick.visible and quick.root.Visible and quick.scale.Scale == 1)
quick.scrim.Activated:Fire()
h.settle(1)
check("binding before mount still gives a working quick scrim", not quick.visible and not quick.root.Visible)
quick.root:Destroy()
check("destroying quick chat resets mount state", not quick.mounted)
quick.mount(overlay.layer); quick.show(); quick.scrim.Activated:Fire(); h.settle(1)
check("remounted quick chat retains scrim dismissal", not quick.visible)
quick.field.set("Keep this draft")
local previousQuick = quick.root
theme.changed:fire()
h.settle(1)
check("quick chat rebuilds theme tokens without dropping drafts", quick.root ~= previousQuick and quick.field.get() == "Keep this draft")
viewport(360, 640, 470)
quick.show(); h.settle(1)
check("quick chat remains bounded with an extreme keyboard", quick.card.Size.Y.Offset <= responsive.usableRect(overlay.layer, theme.space.md).height and quick.card:FindFirstChild("QuickBody") ~= nil)

local tweenTarget = P.frame(root)
local completed = 0
local first = P.animate(tweenTarget, "enter", { BackgroundTransparency = 0 }, function() completed = completed + 1 end)
P.animate(tweenTarget, "exit", { BackgroundTransparency = 1 }, function() completed = completed + 10 end)
first.Completed:Fire(E.PlaybackState.Cancelled)
h.settle(1)
check("retargeted animations suppress stale completion handlers", completed == 10)

root:Destroy()
local screen = h.Instance.new("ScreenGui")
responsive.init(screen)
local camera = h.services.Workspace.CurrentCamera
local initialCount = camera:GetPropertyChangedSignal("ViewportSize"):Count()
responsive.init(screen)
check("responsive reinitialisation does not duplicate camera listeners", camera:GetPropertyChangedSignal("ViewportSize"):Count() == initialCount)
local replacement = h.Instance.new("Camera")
replacement.ViewportSize = V.new(900, 600)
h.services.Workspace.CurrentCamera = replacement
check("camera replacement disconnects the old viewport listener", camera:GetPropertyChangedSignal("ViewportSize"):Count() == 0 and replacement:GetPropertyChangedSignal("ViewportSize"):Count() == 1)
replacement.ViewportSize = V.new(860, 560)
screen:Destroy()
h.settle(1)
check("responsive destruction releases replacement camera and queued refresh", not responsive.ready and replacement:GetPropertyChangedSignal("ViewportSize"):Count() == 0)
dispose.drain()
h.settle(1)
check("focused shared UI scenarios have no asynchronous errors", #h.errors() == 0)
check("focused shared UI scenarios assign valid property types", #h.instanceState.typeErrors == 0)
local function unknownNames(items)
	local names = {}
	for name in pairs(items) do names[#names + 1] = name end
	table.sort(names)
	return table.concat(names, ", ")
end
check("shared UI reads only known properties: " .. unknownNames(h.instanceState.unknownReads), next(h.instanceState.unknownReads) == nil)
check("shared UI uses only known enums: " .. unknownNames(h.unknownEnums), next(h.unknownEnums) == nil)
print("shared UI layout: " .. passed .. " checks passed")
