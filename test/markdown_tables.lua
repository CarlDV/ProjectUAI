-- Source-only parser and renderer regressions. No bundle, boot or network.
-- Run: luajit test/markdown_tables.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local h = require("env").new()
local env = { services = h.services, tween = h.services.TweenService }
local modules = {}
function env.require(id)
	if modules[id] then return modules[id] end
	local chunk = assert(loadfile("src/" .. id .. ".lua"))
	setfenv(chunk, h.sandbox)
	modules[id] = chunk()(env)
	return modules[id]
end
local signal = env.require("runtime/signal")
modules["runtime/config"] = { get = function(_, default) return default end, changed = signal.new() }
modules["ui/responsive"] = {
	viewport = h.dt.Vector2.new(1000, 800), changed = signal.new(), reduceMotion = true,
	minTarget = function() return 28 end,
}
local markdown, theme = env.require("ui/markdown"), env.require("ui/theme")
local util, renderer = env.require("runtime/util"), env.require("ui/chat/table")
local checked = 0
local function check(label, value) assert(value, label); checked = checked + 1 end
local function equal(label, actual, expected)
	check(label .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")", actual == expected)
end
local function parse(source)
	local blocks = markdown.blocks(source)
	equal("single table block", #blocks, 1)
	equal("table recognised", blocks[1].kind, "table")
	return blocks[1]
end
local function noTables(label, source)
	for _, block in ipairs(markdown.blocks(source)) do check(label, block.kind ~= "table") end
end

local ordinary = parse("| Name | Status | Count |\n| :--- | :---: | ---: |\n| café | **ready** | 42 |")
equal("three columns", ordinary.columns, 3)
equal("header values", table.concat(ordinary.header, ","), "Name,Status,Count")
equal("delimiter alignment", table.concat(ordinary.align, ","), "left,center,right")
equal("inline source is preserved", ordinary.rows[1][2], "**ready**")
equal("non-ASCII source preserved", ordinary.rows[1][1], "café")
local outer = parse(" A | B\n--- | ---:\nx | y |\n| z | q")
equal("optional outer pipes can vary by row", #outer.rows, 2)
equal("no phantom trailing cell", outer.rows[1][2], "y")
equal("no phantom leading cell", outer.rows[2][1], "z")
local one = parse("| Header |\n| :---: |\n| value |")
equal("one-column table", one.columns, 1)
equal("one-column alignment", one.align[1], "center")
local shortDelimiter = parse("A | B\n- | :-:\nx | y")
equal("GFM short delimiters", shortDelimiter.align[2], "center")

local escaped = parse([=[| Literal | Code | Other |
| --- | --- | --- |
| a\|b | `x|y` | ``a ` | b`` |
| slash\\ | `x\|y` | last\| |
| escaped \` | tail | end |]=])
equal("escaped pipe stays in one cell", escaped.rows[1][1], "a\\|b")
equal("escaped pipe displays literally", markdown.inline(escaped.rows[1][1]), "a|b")
equal("code pipe stays in one cell", escaped.rows[1][2], "`x|y`")
equal("multiple tick code pipe stays in one cell", escaped.rows[1][3], "``a ` | b``")
equal("even slash parity leaves structural pipe", escaped.rows[2][1], "slash\\\\")
equal("code-cell escaped pipe is normalised", escaped.rows[2][2], "`x|y`")
equal("escaped trailing pipe is content", markdown.inline(escaped.rows[2][3]), "last|")
equal("escaped tick does not swallow a cell", escaped.rows[3][2], "tail")
local unmatched = parse("A | B\n--- | ---\n`open | value\n``open ` | next")
equal("unmatched single tick does not swallow separator", unmatched.rows[1][2], "value")
equal("mismatched tick lengths do not swallow separator", unmatched.rows[2][2], "next")
local slash = parse("A | B\n--- | ---\nx" .. string.rep("\\", 3) .. "|y | z")
equal("odd slash parity escapes pipe", markdown.inline(slash.rows[1][1]), "x\\|y")
local shortened = parse("A | B\n--- | ---\n\\``x|y` | z")
equal("partially escaped tick run still protects code pipe", shortened.rows[1][2], "z")
equal("partially escaped code stays in first cell", shortened.rows[1][1], "\\``x|y`")

local unevenSource = "A | B\n--- | ---\n| lone |\n| x | y | 東京 |\n||"
local uneven = parse(unevenSource)
equal("extra columns retained", uneven.columns, 3)
equal("extra header is unnamed", uneven.header[3], "")
equal("extra column defaults left", uneven.align[3], "left")
equal("short row padded", table.concat(uneven.rows[1], ","), "lone,,")
equal("extra cell retained", uneven.rows[2][3], "東京")
equal("empty row retained", table.concat(uneven.rows[3], ","), ",,")
equal("original source retained for fallback", uneven.text, unevenSource)
local singleBody = parse("A | B\n--- | ---\nshort row")
equal("GFM pipe-less body row is padded", singleBody.rows[1][2], "")
local headerOnly = parse("A | B\n--- | ---")
equal("header-only table", #headerOnly.rows, 0)
local adjacent = markdown.blocks("Intro\nA | B\n--- | ---\nx | y\n# End")
equal("table interrupts preceding paragraph", adjacent[1].text, "Intro")
equal("table interrupts without blank line", adjacent[2].kind, "table")
equal("heading ends table without blank line", adjacent[3].kind, "heading")
for _, separator in ipairs({ "--- | nope", "--- |", "--- | --- | ---", "--- | :", "--- | -- --", "--- | ::---", "--- | ---::", "--- | `---`" }) do
	noTables("malformed delimiter falls back: " .. separator, "A | B\n" .. separator)
end
local malformed = "A | B\n--- | nope\nx | y"
equal("malformed table fallback preserves source", markdown.blocks(malformed)[1].text, malformed)
noTables("plain setext-like text is not a table", "Title\n---")
noTables("escaped pipes alone cannot establish a table", "A\\|B\n---\\|---")
noTables("pipes inside code cannot establish a table", "`A|B`\n`---|---`")
local crlf = parse("A | B\r\n--- | ---\r\nx | y\r\n")
equal("CRLF cells clean", crlf.rows[1][2], "y")

for _, fence in ipairs({ "```", "````", "~~~", "~~~~" }) do
	local source = fence .. "markdown\nA | B\n--- | ---\nx | y\n" .. fence
	local blocks = markdown.blocks(source)
	equal("fence is code: " .. fence, blocks[1].kind, "code")
	equal("fence contains table source intact", blocks[1].text, "A | B\n--- | ---\nx | y")
	noTables("fences never parse tables", source)
end
local unterminated = markdown.blocks("```md\nA | B\n--- | ---\n~~~\nx | y")
check("wrong fence type does not close", unterminated[1].unterminated)
equal("wrong fence retained in code", unterminated[1].text, "A | B\n--- | ---\n~~~\nx | y")
local fenceText = markdown.blocks("```md\n```not-a-closer\nA | B\n--- | ---\n```")
equal("closing fence cannot have trailing text", fenceText[1].text, "```not-a-closer\nA | B\n--- | ---")
local mixed = markdown.blocks("Intro\n\nA | B\n--- | ---\nx | y\n\nAfter\n\nC | D\n--- | ---\n# Heading\n- bullet\n> quote\n```md\nA | B\n--- | ---\n```")
local kinds = {}
for _, block in ipairs(mixed) do kinds[#kinds + 1] = block.kind end
equal("tables coexist with ordinary blocks", table.concat(kinds, ","), "text,table,text,table,heading,bullets,quote,code")
noTables("quote context stays quoted", "> A | B\n> --- | ---")
local markup = parse("<b>東京</b> | café & 😀\n--- | ---\n<font size=\"99\">x</font> | &lt;b&gt;")
check("table text is valid UTF-8", util.validUtf8(markup.text))
equal("cell markup is escaped", markdown.inline(markup.rows[1][1]), "&lt;font size=&quot;99&quot;&gt;x&lt;/font&gt;")

-- The mock does not lay out text or emit derived AbsoluteSize events. Publish
-- engine measurements explicitly, then assert the renderer's resulting geometry.
local screen = h.Instance.new("ScreenGui", h.coreGui)
local parent = h.Instance.new("Frame", screen)
parent.Size = h.dt.UDim2.fromOffset(720, 600)
local asyncErrors = {}
modules["ui/responsive"].changed.onError = function(err) asyncErrors[#asyncErrors + 1] = err end
local function catchSignals(root)
	for _, node in ipairs(root:GetDescendants()) do
		for _, event in pairs(node.__signals) do event.onError = function(err) asyncErrors[#asyncErrors + 1] = err end end
	end
	for _, event in pairs(root.__signals) do event.onError = function(err) asyncErrors[#asyncErrors + 1] = err end end
end
local function find(root, name) return assert(root:FindFirstChild(name, true), name .. " missing") end
local function resize(root, width)
	root.AbsoluteSize = h.dt.Vector2.new(width, 0)
	h.settle()
end
local root = renderer.render(parent, { block = ordinary, layoutOrder = 7 })
catchSignals(root)
equal("renderer retains block order", root.LayoutOrder, 7)
local viewport, grid = find(root, "TableViewport"), find(root, "TableGrid")
local header, body = find(root, "TableHeader"), find(root, "TableRow_1")
equal("distinct header surface", header.BackgroundColor3, theme.color.surfaceRaised)
equal("body alignment follows delimiter", tostring(find(body, "Cell_2").TextXAlignment), "Enum.TextXAlignment.Center")
equal("numeric alignment follows delimiter", tostring(find(body, "Cell_3").TextXAlignment), "Enum.TextXAlignment.Right")
check("safe formatted content reaches label", find(body, "Cell_2").Text == "<b>ready</b>")
equal("non-ASCII reaches label", find(body, "Cell_1").Text, "café")
for column = 1, 3 do
	equal("header and body share column width", find(header, "Cell_" .. column).Size.X.Offset, find(body, "Cell_" .. column).Size.X.Offset)
	equal("header and body share column origin", find(header, "Cell_" .. column).Position.X.Offset, find(body, "Cell_" .. column).Position.X.Offset)
end
equal("explicit scroll canvas", tostring(viewport.AutomaticCanvasSize), "Enum.AutomaticSize.None")
check("wide table stays in reading column", grid.Size.X.Offset <= 720)
check("short wide table needs no hint", not find(root, "TableHint").Visible)
check("no clipped cell text", not find(body, "Cell_1").ClipsDescendants)
equal("cell has auto height only", tostring(find(body, "Cell_1").AutomaticSize), "Enum.AutomaticSize.Y")

local tallCell = find(body, "Cell_2")
tallCell.TextBounds = h.dt.Vector2.new(100, 143)
h.settle()
check("row grows to measured tallest cell", body.Size.Y.Offset >= 143 + theme.space.sm * 2)
check("row stays below header", body.Position.Y.Offset >= header.Size.Y.Offset)
equal("canvas reaches end of final row", viewport.CanvasSize.Y.Offset, body.Position.Y.Offset + body.Size.Y.Offset)
tallCell.TextBounds = h.dt.Vector2.new(100, 24)
h.settle()
check("row shrinks when text reflows", body.Size.Y.Offset < 143)
tallCell.AbsoluteSize = h.dt.Vector2.new(tallCell.Size.X.Offset, 176)
h.settle()
check("automatic label height also protects row geometry", body.Size.Y.Offset >= 176 + theme.space.sm * 2)
tallCell.AbsoluteSize = h.dt.Vector2.new(tallCell.Size.X.Offset, 24)
h.settle()
resize(root, 220)
check("narrow table scrolls horizontally", grid.Size.X.Offset > 220)
check("horizontal scroll is enabled", viewport.ScrollingEnabled)
check("overflow is explained", find(root, "TableHint").Text:find("Scroll across", 1, true))
for column = 1, 3 do
	check("column retains readable minimum", find(body, "Cell_" .. column).Size.X.Offset >= theme.size.keyColumn - theme.space.md * 2)
end
viewport.CanvasPosition = h.dt.Vector2.new(9999, 9999)
resize(root, 900)
equal("widening clamps horizontal scroll", viewport.CanvasPosition.X, 0)
equal("widening clamps vertical scroll", viewport.CanvasPosition.Y, 0)
equal("responsive width consumes available column", grid.Size.X.Offset, 900 - theme.size.scrollbar)

local longLines = { "Name | Description", "--- | ---" }
for index = 1, 90 do longLines[#longLines + 1] = "Row " .. index .. " | " .. string.rep("東京 café & 😀 ", 8) end
local long = renderer.render(parent, { block = parse(table.concat(longLines, "\n")), maxHeight = 240 })
catchSignals(long)
local longViewport = find(long, "TableViewport")
check("long table bounded", longViewport.Size.Y.Offset <= 240)
check("all rows remain present", find(long, "TableRow_90") ~= nil)
check("last row keeps all text", find(find(long, "TableRow_90"), "Cell_2").Text:find("東京 café &amp; 😀", 1, true))
check("full canvas extends beyond viewport", longViewport.CanvasSize.Y.Offset > longViewport.Size.Y.Offset)
check("long table hint states row count", find(long, "TableHint").Text:find("90 rows", 1, true))
local previousBottom = find(long, "TableHeader").Size.Y.Offset
for index = 1, 90 do
	local row = find(long, "TableRow_" .. index)
	assert(row.Position.Y.Offset >= previousBottom, "long-table row overlap at " .. index)
	previousBottom = row.Position.Y.Offset + row.Size.Y.Offset
end
equal("long-table canvas reaches last row bottom", longViewport.CanvasSize.Y.Offset, previousBottom)
local oldHeight = longViewport.Size.Y.Offset
modules["ui/responsive"].viewport = h.dt.Vector2.new(320, 300)
modules["ui/responsive"].changed:fire()
h.settle()
check("viewport responds to screen height", longViewport.Size.Y.Offset < oldHeight)
local proportions = renderer.render(parent, { block = parse("ID | Description\n--- | ---\n1 | " .. string.rep("long ", 40)) })
local proportionalRow = find(proportions, "TableRow_1")
check("content-heavy columns get more room", find(proportionalRow, "Cell_2").Size.X.Offset > find(proportionalRow, "Cell_1").Size.X.Offset)
local safe = renderer.render(parent, { block = markup })
equal("rendered raw markup never injects tags", find(find(safe, "TableHeader"), "Cell_1").Text, "&lt;b&gt;東京&lt;/b&gt;")
equal("entity-like text is escaped once", find(find(safe, "TableRow_1"), "Cell_2").Text, "&amp;lt;b&amp;gt;")
local sparse = renderer.render(parent, { block = uneven })
equal("renderer preserves extra cell", find(find(sparse, "TableRow_2"), "Cell_3").Text, "東京")
local empty = renderer.render(parent, { block = headerOnly })
check("header-only renderer has positive height", find(empty, "TableViewport").Size.Y.Offset > 0)

-- TextService can be unavailable on an older client; initial sizing must remain
-- UTF-8-aware and recover to engine measurements without dropping long content.
local textService = env.services.TextService
env.services.TextService = { GetTextSize = function() error("unavailable") end }
local fallback = renderer.render(parent, { block = parse("ASCII | Unicode\n--- | ---\n" .. string.rep("x", 8)
	.. " | " .. string.rep("界", 8)) })
local fallbackRow = find(fallback, "TableRow_1")
equal("fallback counts Unicode characters rather than bytes", find(fallbackRow, "Cell_1").Size.X.Offset,
	find(fallbackRow, "Cell_2").Size.X.Offset)
check("fallback has positive row height", fallbackRow.Size.Y.Offset > 0)
env.services.TextService = textService
fallback:Destroy()

-- Destruction must detach text/size and responsive listeners, even with a
-- deferred layout already queued by streaming/rebuilding the transcript.
local resizeSignal = root:GetPropertyChangedSignal("AbsoluteSize")
local boundsSignal = tallCell:GetPropertyChangedSignal("TextBounds")
local sizeSignal = tallCell:GetPropertyChangedSignal("AbsoluteSize")
equal("one bounds listener", boundsSignal.Count(), 1)
equal("one auto-size listener", sizeSignal.Count(), 1)
local subscriptions = modules["ui/responsive"].changed:count()
resizeSignal:Fire()
tallCell.TextBounds = h.dt.Vector2.new(100, 600)
local lastCanvas = viewport.CanvasSize.Y.Offset
root:Destroy()
equal("responsive listener released", modules["ui/responsive"].changed:count(), subscriptions - 1)
equal("bounds listener released", boundsSignal.Count(), 0)
equal("auto-size listener released", sizeSignal.Count(), 0)
equal("root measurement listener released", resizeSignal.Count(), 0)
h.settle()
equal("queued layout cannot touch destroyed tree", viewport.CanvasSize.Y.Offset, lastCanvas)
for _, node in ipairs({ long, proportions, safe, sparse, empty }) do node:Destroy() end
equal("all table responsive listeners released", modules["ui/responsive"].changed:count(), 0)
equal("no callback errors", #asyncErrors, 0)
equal("no task errors", #h.errors(), 0)
equal("no property type errors", #h.instanceState.typeErrors, 0)
print("markdown tables: " .. checked .. " checks passed")
