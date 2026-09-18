-- Focused source-level regressions for shared control gestures.
-- Run from the repository root: luajit test/controls_interactions.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path

local envMock = require("env")
local luau = require("luau")
local harness = envMock.new()
local cache = {}
local captured = {}
local serviceTween = harness.services.TweenService
local env = {
	services = harness.services,
	uis = harness.services.UserInputService,
	guisvc = harness.services.GuiService,
	tween = {
		Create = function(_, target, info, goals)
			local tween = serviceTween:Create(target, info, goals)
			captured[#captured + 1] = { tween = tween, target = target, info = info, goals = goals }
			return tween
		end,
	},
}
function env.require(id)
	if cache[id] then return cache[id] end
	local path = "src/" .. id .. ".lua"
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a")
	file:close()
	local chunk, problems = luau.load(source, path)
	assert(chunk, problems and problems[1] and problems[1].msg)
	setfenv(chunk, harness.sandbox)
	cache[id] = chunk()(env)
	return cache[id]
end
local signal = env.require("runtime/signal")
cache["runtime/config"] = {
	get = function(_, default) return default end,
	changed = signal.new("config"),
}
local responsive = {
	reduceMotion = false,
	changed = signal.new("responsive"),
	minTarget = function() return 28 end,
}
cache["ui/responsive"] = responsive
cache["ui/icons"] = {}
local controls = env.require("ui/controls")
local dispose = env.require("runtime/dispose")
local root = harness.Instance.new("Frame")
local passed = 0
local function check(label, condition)
	assert(condition, label)
	passed = passed + 1
	print("ok " .. label)
end

root.Size = harness.dt.UDim2.fromOffset(320, 240)
local commits, changes = 0, 0
local slider = controls.slider(root, {
	min = 0, max = 100, step = 1, value = 25,
	onChange = function() changes = changes + 1 end,
	onCommit = function() commits = commits + 1 end,
})
local hit = slider.instance:FindFirstChildOfClass("TextButton")
local track = slider.instance:FindFirstChild("Track")
local Enum = harness.sandbox.Enum
local function input(kind, share)
	return {
		UserInputType = kind,
		Position = harness.dt.Vector3.new(track.AbsolutePosition.X + track.AbsoluteSize.X * share, 0, 0),
	}
end
local first = input(Enum.UserInputType.Touch, 0.2)
local second = input(Enum.UserInputType.Touch, 0.9)
hit.InputBegan:Fire(first)
check("initiating touch changes the slider", slider.value == 20 and changes == 1)
hit.InputBegan:Fire(second)
check("a second finger cannot replace the active gesture", slider.value == 20 and changes == 1)
env.uis.InputChanged:Fire(second)
check("another finger cannot move the active slider", slider.value == 20)
env.uis.InputChanged:Fire(input(Enum.UserInputType.MouseMovement, 0.8))
check("mouse movement cannot hijack a touch gesture", slider.value == 20)
env.uis.InputEnded:Fire(input(Enum.UserInputType.MouseButton1, 0.8))
env.uis.InputEnded:Fire(second)
check("unrelated pointer releases do not commit touch", commits == 0)
first.Position = input(Enum.UserInputType.Touch, 0.7).Position
env.uis.InputChanged:Fire(first)
check("original touch keeps ownership after unrelated releases", slider.value == 70)
hit.InputEnded:Fire(first)
env.uis.InputEnded:Fire(first)
check("local and global release commit once", commits == 1)
first.Position = input(Enum.UserInputType.Touch, 0.4).Position
env.uis.InputChanged:Fire(first)
check("released touch cannot continue moving the slider", slider.value == 70)

local mouse = input(Enum.UserInputType.MouseButton1, 0.3)
hit.InputBegan:Fire(mouse)
env.uis.InputChanged:Fire(second)
check("touch movement cannot hijack mouse dragging", slider.value == 30)
env.uis.InputChanged:Fire(input(Enum.UserInputType.MouseMovement, 0.6))
check("mouse moves still update while dragging", slider.value == 60)
env.uis.InputEnded:Fire(second)
check("touch release cannot end mouse dragging", commits == 1)
env.uis.InputEnded:Fire(input(Enum.UserInputType.MouseButton1, 0.6))
check("mouse release outside the slider commits", commits == 2)
env.uis.InputChanged:Fire(input(Enum.UserInputType.MouseMovement, 0.95))
check("released mouse cannot keep updating", slider.value == 60)

hit.InputBegan:Fire(first)
local priorChanges = changes
slider.instance:Destroy()
env.uis.InputChanged:Fire(first)
env.uis.InputEnded:Fire(first)
check("destroying an active slider releases its global listeners", changes == priorChanges and commits == 2 and dispose.count() == 0)

-- A setting can rebuild its whole panel from onChange. The same gesture must
-- not start fresh hover tweens against controls destroyed by that callback.
local victim
local victimCommits = 0
victim = controls.slider(root, {
	min = 0, max = 100,
	onChange = function() victim.instance:Destroy() end,
	onCommit = function() victimCommits = victimCommits + 1 end,
})
local victimHit = victim.instance:FindFirstChildOfClass("TextButton")
local before = #captured
victimHit.InputBegan:Fire(input(Enum.UserInputType.MouseButton1, 0.5))
check("synchronous panel teardown prevents subsequent feedback tweens", #captured == before and dispose.count() == 0)
env.uis.InputEnded:Fire(input(Enum.UserInputType.MouseButton1, 0.5))
check("a destroyed slider never commits after teardown", victimCommits == 0)
harness.settle(1)
check("gesture cleanup has no asynchronous errors", #harness.errors() == 0)
print("controls interactions: " .. passed .. " checks passed")
