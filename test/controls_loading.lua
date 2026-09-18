-- Focused source-level regressions for shared loading indicators.
-- Run from the repository root: luajit test/controls_loading.lua
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

-- Check the actual rendered shape, not just the presence of a tween. A complete
-- evenly dotted circle can pass a Rotation assertion while still looking static.
for _, diameter in ipairs({ 14, 16, 20 }) do
	local spinner = controls.spinner(root, { diameter = diameter })
	local rotor = spinner:FindFirstChild("Rotor")
	check("spinner " .. diameter .. " keeps a fixed layout slot", rotor ~= nil and spinner.Rotation == 0)
	local angles = {}
	local weight, sumX, sumY = 0, 0, 0
	for _, child in ipairs(rotor:GetChildren()) do
		if child:IsA("Frame") then
			local x, y = child.Position.X.Offset, child.Position.Y.Offset
			local angle = math.atan2(y, x)
			if angle < 0 then angle = angle + math.pi * 2 end
			angles[#angles + 1] = angle
			local opacity = 1 - child.BackgroundTransparency
			weight = weight + opacity
			sumX = sumX + x * opacity
			sumY = sumY + y * opacity
		end
	end
	table.sort(angles)
	local gap = 0
	for index, angle in ipairs(angles) do
		local nextAngle = angles[index + 1] or (angles[1] + math.pi * 2)
			gap = math.max(gap, nextAngle - angle)
	end
	check("spinner " .. diameter .. " has a clearly open silhouette", gap > math.pi / 2)
	check("spinner " .. diameter .. " is visibly asymmetric", math.sqrt(sumX * sumX + sumY * sumY) / weight > diameter / 16)
	local cap = rotor:FindFirstChild("LeadingCap")
	check("spinner " .. diameter .. " has a solid readable leading cap", cap and cap.BackgroundTransparency == 0 and cap.Size.X.Offset >= 2)
	local running = captured[#captured]
	check("spinner " .. diameter .. " continuously rotates its inner arc", running.target == rotor and running.info.RepeatCount == -1 and running.goals.Rotation == 360)
	spinner:Destroy()
	check("spinner " .. diameter .. " cancels on destruction", running.tween.PlaybackState == "Cancelled")
end
check("destroying spinners releases preference subscriptions", responsive.changed:count() == 0)
check("destroying spinners releases registered cleanup", dispose.count() == 0)

responsive.reduceMotion = true
local before = #captured
local spinner = controls.spinner(root)
local rotor = spinner:FindFirstChild("Rotor")
check("reduced motion creates no repeating tween", #captured == before and rotor.Rotation == 0)
responsive.reduceMotion = false
responsive.changed:fire()
local first = captured[#captured]
check("motion can be enabled while a request is running", #captured == before + 1 and first.target == rotor)
responsive.changed:fire()
check("unrelated responsive changes do not duplicate the spin", #captured == before + 1)
responsive.reduceMotion = true
responsive.changed:fire()
check("live reduced motion cancels the running tween", first.tween.PlaybackState == "Cancelled" and rotor.Rotation == 0)
responsive.reduceMotion = false
responsive.changed:fire()
local resumed = captured[#captured]
check("motion can resume without reviving cancelled tween", resumed ~= first and resumed.target == rotor)
spinner:Destroy()
check("resumed motion also cleans up", resumed.tween.PlaybackState == "Cancelled" and dispose.count() == 0 and responsive.changed:count() == 0)
responsive.changed:fire()
check("destroyed spinner cannot start again", captured[#captured] == resumed)

local unloadSpinner = controls.spinner(root)
local unloadTween = captured[#captured].tween
dispose.drain()
check("unload stops rotation and removes subscriptions", unloadTween.PlaybackState == "Cancelled" and responsive.changed:count() == 0)
unloadSpinner:Destroy()
harness.settle(1)
check("no asynchronous cleanup errors", #harness.errors() == 0)
print("controls loading: " .. passed .. " checks passed")
