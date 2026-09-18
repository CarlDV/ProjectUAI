-- Source-only UI regressions; does not read or rebuild dist/uai.lua.
-- Run: luajit test/panel_layout_regressions.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local h = require("env").new()
local luau = require("luau")
local cache = {}
local env = { services = h.services, uis = h.services.UserInputService,
	tween = h.services.TweenService, guisvc = h.services.GuiService,
	hs = h.services.HttpService, plr = h.localPlayer, context = {}, info = {} }
function env.require(id)
	if cache[id] then return cache[id] end
	local path = "src/" .. id .. ".lua"
	local file = assert(io.open(path, "rb"))
	local source = file:read("*a")
	file:close()
	local chunk, problems = luau.load(source, path)
	assert(chunk, problems and problems[1] and problems[1].msg)
	setfenv(chunk, h.sandbox)
	cache[id] = chunk()(env)
	return cache[id]
end
local signal = env.require("runtime/signal")
local util = env.require("runtime/util")
local values = {}
local config = { changed = signal.new("config") }
function config.get(path, default)
	local value = values[path]
	if value == nil then return default end
	return value
end
function config.set(path, value)
	values[path] = value
	config.changed:fire(path)
end
cache["runtime/config"] = config
local target = 44
local responsive = { mode = "panel", reduceMotion = true, changed = signal.new("responsive"),
	minTarget = function() return target end, describe = function() return "test viewport" end }
cache["ui/responsive"] = responsive
cache["ui/icons"] = { draw = function() end, chevron = function() end, check = function() end }
local warnings = {}
cache["runtime/log"] = { entries = {}, changed = signal.new("log"),
	warn = function(...) warnings[#warnings + 1] = { ... } end,
	redact = function(text) return text end, export = function() return "" end,
	clear = function() end }
cache["runtime/caps"] = { clipboard = true, fn = { clipboard = function() end },
	http = "executor", has = function() return true end, summary = function() return "test" end,
	reason = function() return "Unavailable" end }
local dt, Enum = h.dt, h.sandbox.Enum
local root = h.Instance.new("Frame")
root.Size = dt.UDim2.fromOffset(900, 700)
local function mount(width)
	local frame = h.Instance.new("Frame", root)
	frame.Size = dt.UDim2.fromOffset(width or 360, 600)
	return frame
end
local function find(parent, name) return assert(parent:FindFirstChild(name, true), name) end
local function labels(parent, text)
	local out = {}
	for _, child in ipairs(parent:GetDescendants()) do
		if child:IsA("TextLabel") and child.Text == text then out[#out + 1] = child end
	end
	return out
end
local passed = 0
local function check(label, condition)
	assert(condition, label)
	passed = passed + 1
	print("ok " .. label)
end
local P = env.require("ui/primitives")
local theme = env.require("ui/theme")
local R = env.require("ui/settingsrows")
local lastModal, lastMenu, menuCount = nil, nil, 0
local dialogWidth = 400
cache["ui/overlay"] = {
	toast = function() end,
	menu = function(props) lastMenu = props; menuCount = menuCount + 1 end,
	modal = function()
		local card = mount(400)
		local modal = { card = card, content = P.column(card, {}), footer = P.row(card, {}) }
		function modal.close() modal.closed = true; card:Destroy() end
		lastModal = modal
		return modal
	end,
	dialog = function()
		local card = mount(dialogWidth)
		local dialog = { card = card, width = dialogWidth, closeInset = 52 }
		function dialog.close() dialog.closed = true; card:Destroy() end
		return dialog
	end,
}
local records = {
	{ id = "first", label = "One", baseUrl = "https://one.invalid/v1", apiKey = "", model = "test",
		models = { "test" }, enabled = false, health = {} },
	{ id = "second", label = string.rep("Long provider ", 12), baseUrl = "https://two.invalid/v1",
		apiKey = "", model = "test", models = { "test" }, health = {} },
}
local active = records[1]
local providers = { changed = signal.new("providers"),
	list = function() return records end, active = function() return active end,
	get = function(id) for _, record in ipairs(records) do if record.id == id then return record end end end,
	count = function() return #records end, cooling = function() return false end,
	keysOf = function() return {} end,
	endpoint = function(record, suffix) return record.baseUrl .. suffix end,
	normaliseBaseUrl = function(url) return url end,
	validate = function() return true, {} end }
cache["provider/registry"] = providers
cache["provider/catalog"] = { presets = {}, get = function() return nil end }
cache["provider/models"] = { list = function(record) return record.models end,
	discover = function() h.sandbox.task.wait(0.3); return { "fetched" }, "Fetched" end }
cache["provider/chat"] = { STYLES = { { value = "openai", label = "Chat" } },
	styleOf = function() return "openai" end, endpointOf = function(record) return record.baseUrl .. "/chat/completions" end }
cache["provider/traits"] = { badge = function() return nil end }
local providerPanel = env.require("ui/panels/providers")
local parent = mount()
local panel = providerPanel.new(parent)
local rail = find(parent, "ProviderList")
local first = find(rail, "Provider_first")
check("provider strip uses intrinsic tabs", first.AutomaticSize == Enum.AutomaticSize.X and first.Size.X.Scale == 0)
check("intrinsic provider label has no circular Fill sizing", find(first, "Label"):FindFirstChildOfClass("UIFlexItem") == nil)
check("long provider names have a width cap", find(find(rail, "Provider_second"), "Label"):FindFirstChildOfClass("UISizeConstraint") ~= nil)
check("one Active badge across rail and detail", #labels(parent, "Active") == 1)
check("strip stays left aligned and reserves scrollbar height", rail:FindFirstChildOfClass("UIListLayout").HorizontalAlignment == Enum.HorizontalAlignment.Left
	and rail.HorizontalScrollBarInset == Enum.ScrollBarInset.ScrollBar and first.Size.Y.Offset >= target)
panel.scroll.instance.CanvasPosition = dt.Vector2.new(0, 340)
providers.changed:fire("saved")
check("provider save retains detail scroll", panel.scroll.instance.CanvasPosition.Y == 340)
records[1].health.lastError = "Latest failure"
providers.changed:fire("health")
check("provider health event updates error text in place", find(parent, "HealthError").Text == "Latest failure"
	and find(parent, "HealthError").Visible and panel.scroll.instance.CanvasPosition.Y == 340)
records[1].health.lastError = ""
providers.changed:fire("health")
check("provider recovery hides obsolete error", not find(parent, "HealthError").Visible)
local detailTitle = find(parent, "ProviderTitle")
responsive.mode = "window"
panel.root.AbsoluteSize = dt.Vector2.new(800, 600)
check("provider rail reflows wide without rebuilding detail", rail.ScrollingDirection == Enum.ScrollingDirection.Y
	and find(parent, "ProviderTitle") == detailTitle)
panel.root.AbsoluteSize = dt.Vector2.new(360, 600)
check("desktop resize returns provider strip to horizontal", rail.ScrollingDirection == Enum.ScrollingDirection.X)
check("axis switch resets incompatible scroll offset", rail.CanvasPosition.X == 0 and rail.CanvasPosition.Y == 0)
panel.select("second")
check("selecting a different provider starts at its header", panel.scroll.instance.CanvasPosition.Y == 0)
parent:Destroy()
check("provider teardown releases data and layout signals", providers.changed:count() == 0 and responsive.changed:count() == 0)
providerPanel.editor(records[1])
local picker = find(lastModal.card, "ActiveModel")
picker.Activated:Fire()
lastMenu.onSelect("fetch")
lastModal.close()
local beforeMenus = menuCount
h.settle(0.7)
check("late model discovery cannot reopen a closed provider editor", menuCount == beforeMenus)

-- Tool rebuilds retain expanded state and the list's flex allocation.
local permissions = { changed = signal.new("permissions"), ruleFor = function() return "default" end }
function permissions.setRule() permissions.changed:fire() end
cache["agent/permissions"] = permissions
local tool = { name = string.rep("long_tool_", 8), group = "test", risk = "read", description = "Test tool", parameters = {} }
cache["agent/registry"] = { GROUP_LABELS = { test = "Test" }, stats = function() return { total = 1, byGroup = { test = 1 }, unavailable = {} } end,
	list = function() return { tool } end, missingCapability = function() return nil end,
	groupEnabled = function() return true end, groupLabel = function(group) return group end }
cache["agent/schema"] = { describe = function() return "No parameters" end }
parent = mount()
local tools = env.require("ui/panels/tools").new(parent)
find(parent, "ToolDetailsToggle").Activated:Fire()
find(parent, "ToolList").CanvasPosition = dt.Vector2.new(0, 160)
find(parent, "Segment_allow").Activated:Fire()
check("changing permission keeps tool details expanded", find(parent, "ToolDetails").Visible)
check("tool rebuild retains scroll and flex holder", find(parent, "ToolList").CanvasPosition.Y == 160
	and find(parent, "ToolListHolder"):FindFirstChildOfClass("UIFlexItem") ~= nil)
check("long tool names wrap above badges", labels(parent, tool.name)[1].TextWrapped)
parent:Destroy()
check("tools unsubscribe on destruction", permissions.changed:count() == 0)
local created = h.instanceState.count
permissions.changed:fire()
check("dead tools panel cannot rebuild", created == h.instanceState.count)

local http = { history = {}, changed = signal.new("http"), clearHistory = function() end }
cache["net/http"] = http
http.history = { { method = "GET", tag = string.rep("trace", 20), status = 200,
	url = "https://test.invalid", ms = 100, identity = "none" } }
for _ = 1, 3 do
	parent = mount()
	local logs = env.require("ui/panels/logs").new(parent)
	find(parent, "LogList").CanvasPosition = dt.Vector2.new(0, 120)
	logs.refresh()
	check("log refresh retains bounded list holder", find(parent, "LogListHolder"):FindFirstChildOfClass("UIFlexItem") ~= nil)
	check("log refresh retains reading position", find(parent, "LogList").CanvasPosition.Y == 120)
	http.changed:fire()
	parent:Destroy()
end
h.settle(0.4)
check("reopened logs leave no subscriptions", http.changed:count() == 0 and cache["runtime/log"].changed:count() == 0)

local live = { id = "child", label = "Worker", task = "Work", status = "running", preset = "read", startedAt = 0 }
local agents = { changed = signal.new("agents"), PRESETS = { read = { test = true } },
	list = function() return { live } end, running = function() return { live } end,
	concurrencyLimit = function() return 3 end, unlimited = function() return false end,
	budgetSeconds = function() return 60 end }
cache["agent/subagent"] = agents
parent = mount()
env.require("ui/panels/agents").new(parent)
local stopButton = find(parent, "Stop")
local elapsedLabel = find(parent, "Elapsed")
check("agent action buttons wrap within narrow cards", stopButton.Parent:FindFirstChildOfClass("UIListLayout").Wraps == true)
local listeners = responsive.changed:count()
h.settle(1.1)
check("agent clock preserves card and button identity", find(parent, "Stop") == stopButton and find(parent, "Elapsed") == elapsedLabel)
check("agent clock does not add spinner subscriptions", responsive.changed:count() == listeners)
config.set("agent.subagentConcurrency", 4)
h.settle(0.3)
check("agent settings still refresh without clock rebuilds", find(parent, "Stop") ~= stopButton)
agents.changed:fire()
parent:Destroy()
h.settle(0.4)
check("agents release timer and pending redraw", agents.changed:count() == 0 and responsive.changed:count() == 0)

-- Settings controls are tested at actual row widths, without a layout-engine mock.
parent = mount()
values["enabled"] = true
local toggle = R.toggle(parent, { label = "Explicit off", path = "enabled", value = false })
check("explicit false is not replaced by config true", toggle.value == false)
local slot, setting = R.setting(parent, { label = "Label", width = 240 })
setting.AbsoluteSize = dt.Vector2.new(180, 40)
check("narrow setting stacks and clamps its control", slot.Size.X.Offset == 180
	and setting:FindFirstChildOfClass("UIListLayout").FillDirection == Enum.FillDirection.Vertical)
R.field(parent, { name = "OrderedField", label = "Field", hint = "Ordered hint", value = "", layoutOrder = 4 })
check("field hint follows its input", labels(parent, "Ordered hint")[1].LayoutOrder == 6)
local number = R.number(parent, "Long numeric setting label", nil, "number", 0, 10, 1)
check("numeric setting label can grow vertically", labels(number, "Long numeric setting label")[1].AutomaticSize == Enum.AutomaticSize.Y)
local actionsRow = R.actions(parent, { { text = string.rep("Remove long provider ", 10) } })
actionsRow.AbsoluteSize = dt.Vector2.new(180, 40)
local actionLabel = actionsRow:FindFirstChildWhichIsA("TextLabel", true)
check("one oversized action fits inside a narrow pane", actionLabel:FindFirstChildOfClass("UISizeConstraint").MaxSize.X
	== 180 - theme.space.md * 2 and actionLabel.TextTruncate == Enum.TextTruncate.AtEnd)
parent:Destroy()

local sessions = { listChanged = signal.new("sessions"), current = function() return { id = "session", title = "Current" } end,
	groups = function() return {} end }
cache["agent/session"] = sessions
local bridge = { changed = signal.new("bridge"), status = function() return { running = false, url = "localhost" } end }
cache["net/bridge"] = bridge
parent = mount()
env.require("ui/panels/cowork").rows(parent)
local copy = find(parent, "CopyBridgeUrl")
check("cowork actions wrap on narrow cards", copy.Parent:FindFirstChildOfClass("UIListLayout").Wraps == true)
parent:Destroy()
check("cowork releases both state subscriptions", bridge.changed:count() == 0 and sessions.listChanged:count() == 0)

-- Real pane builder, stubbed stores: two skills must keep their shared layout.
for _, id in ipairs({ "runtime/config_transfer", "runtime/fsx", "agent/usage", "agent/stats", "net/ua", "ui/quickchat" }) do cache[id] = {} end
cache["runtime/place"] = { changed = signal.new("place") }
cache["agent/state"] = { memoryList = function() return {} end, memoryChanged = signal.new("memory") }
cache["agent/hooks"] = { KINDS = {} }
local skills = { changed = signal.new("skills"), list = function() return {
	{ file = "one.md", name = "One", description = "First", enabled = true },
	{ file = "two.md", name = "Two", description = "Second", enabled = true },
} end }
cache["runtime/skills"] = skills
parent = mount()
env.require("ui/settingspanes").render("skills", parent)
local skillsList = find(parent, "SkillsList")
local layout = skillsList:FindFirstChildOfClass("UIListLayout")
skills.changed:fire()
check("skills refresh preserves list layout and both rows", layout ~= nil and skillsList:FindFirstChildOfClass("UIListLayout") == layout
	and find(skillsList, "Skill_one.md").LayoutOrder < find(skillsList, "Skill_two.md").LayoutOrder)
parent:Destroy()
check("skills pane releases subscriptions", skills.changed:count() == 0)

local paneBuilds = 0
local entries = { { id = "one", label = "One", icon = "gear" }, { id = "two", label = "Second category", icon = "gear" } }
cache["ui/settingspanes"] = { PANES = entries, pane = function(id) for _, entry in ipairs(entries) do if entry.id == id then return entry end end end,
	sections = function() return { { title = "Test", panes = entries } } end,
	render = function(_, container) paneBuilds = paneBuilds + 1; P.field(container, { name = "LiveInput" }) end }
local dialog = env.require("ui/panels/settingsdialog").open("one")
local nav = find(dialog.card, "Categories")
local input = find(dialog.card, "LiveInput")
check("settings tabs are intrinsic and exclude close-button region", find(nav, "Category_one").AutomaticSize == Enum.AutomaticSize.X
	and nav.Size.X.Offset == -dialog.closeInset)
dialog.select("one")
check("reselecting category preserves its live form", paneBuilds == 1 and find(dialog.card, "LiveInput") == input)
dialog.card.AbsoluteSize = dt.Vector2.new(800, 600)
check("settings dialog reflows on container resize", nav.ScrollingDirection == Enum.ScrollingDirection.Y)
dialog.card.AbsoluteSize = dt.Vector2.new(360, 600)
check("settings resize retains active input", nav.ScrollingDirection == Enum.ScrollingDirection.X
	and paneBuilds == 1 and find(dialog.card, "LiveInput") == input)
dialog.close()

parent = mount(240)
local sidebar = env.require("ui/sidebar").new(parent, { panel = "chat", canBack = function() return false end,
	canForward = function() return false end })
check("expanded sidebar navigation lives inside the scroll viewport", find(parent, "ActionRows").Parent == find(parent, "HistoryScroll"))
local mode = find(parent, "ModeSwitcher")
check("sidebar mode targets retain floor after padding", mode.Size.Y.Offset - theme.space.hair * 2 >= target)
local actions = find(parent, "ActionRows")
sidebar.renderHistory()
check("history refresh preserves navigation", find(parent, "ActionRows") == actions)
parent:Destroy()
h.settle(0.5)
for _, floor in ipairs({ 28, 44, 48 }) do
	target = floor
	config.set("ui.fontScale", 1.4)
	responsive.mode = "panel"
	parent = mount(320)
	local scaled = providerPanel.new(parent)
	local tab = find(parent, "Provider_first")
	check("scaled provider tab clears target and text at floor " .. floor,
		tab.Size.Y.Offset >= floor and tab.Size.Y.Offset >= theme.text.small.height)
	local longLabel = find(find(parent, "Provider_second"), "Label")
	check("scaled long tab stays width-bounded at floor " .. floor,
		longLabel:FindFirstChildOfClass("UISizeConstraint").MaxSize.X == theme.size.menuMin)
	parent:Destroy()
end
check("no UI callback warnings", #warnings == 0)
check("no asynchronous errors", #h.errors() == 0)
check("no property type errors", #h.instanceState.typeErrors == 0)
print("panel layout regressions: " .. passed .. " checks passed")
