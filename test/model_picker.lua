package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local h = envMock.new()
local app = assert(h.boot()); h.settle(1)
local passed = 0
local function check(label, condition) assert(condition, label); passed = passed + 1 end
local providers = app.providers
local record = providers.blank("custom")
record.id, record.label, record.baseUrl, record.key = "picker-test", "Test endpoint", "https://test.invalid/v1", "test-key"
record.model = "claude-opus-5"
record.models = { "claude-opus-5", "vendor/free:free", "vendor/paid", "vendor/second:free" }
assert(providers.save(record, { force = true }))
providers.setActive(record.id)
local picker = app.env.require("ui/panels/modelpicker").open()
h.settle(1)
check("reopening returns the same live picker", app.env.require("ui/panels/modelpicker").open() == picker)
local root = h.byName("ModelPicker")
local search = h.byName("ModelFilter"):FindFirstChildOfClass("TextBox")
local paid = h.byName("Model_vendor/paid")
local free = h.byName("Model_vendor/free:free")
check("picker is narrower than previous dialog", picker.card.Size.X.Offset <= 520)
check("rows have no redundant second line", h.byName("Detail", paid) == nil)
check("row fits in one control height", paid.Size.Y.Offset <= 44)
search.Text = "free"
check("filter hides nonmatches", not paid.Visible and free.Visible)
check("typing keeps search instance alive", search.Parent ~= nil)
search.Text = "no-match"
check("empty state is explicit", h.byName("EmptySearch").Visible)
search.Text = ""
h.click(h.byName("FreeOnly"))
check("free-only filter hides paid models", not paid.Visible and free.Visible)
check("free-only filter does not delete provider models", #providers.active().models == 4)
h.click(free)
check("selection writes provider model", providers.active().model == "vendor/free:free")
check("selection preserves the model row instance", h.byName("Model_vendor/free:free") == free)
check("search remains the same after selection", h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search)
check("unsupported effort uses no visible row", not h.byName("Section_ReasoningEffort").Visible)
h.click(h.byName("FreeOnly"))
h.click(h.byName("Model_claude-opus-5"))
h.click(h.byName("Effort_low"))
check("effort changes real setting", app.config.get("agent.effort") == "low")
for _, height in ipairs({ 380, 180, 100 }) do
	picker.scroll.instance.AbsoluteSize = h.dt.Vector2.new(280, height)
	local scroll = h.byName("ModelScroll", root)
	local parentHeight = picker.content.Size.Y.Offset
	local listHeight = scroll.Size.Y.Scale * parentHeight + scroll.Size.Y.Offset
	check("model list stays usable at height " .. height, listHeight >= 68)
	check("small viewport gains outer scrolling " .. height, height >= parentHeight or picker.scroll.instance.ScrollingEnabled)
	check("only one scroll owns the gesture " .. height, picker.scroll.instance.ScrollingEnabled ~= scroll.ScrollingEnabled)
end
search.Text = "free"
local beforeFilterHeight = picker.content.Size.Y.Offset
search.Text = "no-match"
check("compact filtering removes empty list space", picker.content.Size.Y.Offset < beforeFilterHeight)
search.Text = ""
local chip = h.byName("ModelChip", app.app.chatPanel.composer.shell)
local chipSurface = h.byName("ComposerSurface", app.app.chatPanel.composer.shell)
chipSurface.AbsoluteSize = h.dt.Vector2.new(760, 60)
providers.setModel(record.id, "x")
local shortWidth = chip.Size.X.Offset
providers.setModel(record.id, "a-considerably-longer-model-name")
check("composer chip sizes to its model label", shortWidth < chip.Size.X.Offset)
check("short chip does not reserve the maximum width", shortWidth < app.env.require("ui/theme").size.composerModel)
h.services.UserInputService.TouchEnabled = true
app.env.require("ui/responsive").refresh("test")
h.settle(1)
check("picker search survives changing input devices", h.byName("ModelFilter"):FindFirstChildOfClass("TextBox") == search)
check("provider selector grows to touch floor", h.byName("Section_Endpoint").Size.Y.Offset >= 44)
check("model rows grow to touch floor", h.byName("Model_vendor/paid").Size.Y.Offset >= 44)
picker.close(); h.settle(1)
check("no asynchronous errors", #h.errors() == 0)
check("no property type errors", #h.instanceState.typeErrors == 0)
print("model picker: " .. passed .. " checks passed")
