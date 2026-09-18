-- Focused inline-markdown regressions; no Roblox client or network needed.
local colour = { ToHex = function() return "CCAABB" end }
local theme = { color = { accentHot = colour, textTertiary = colour }, codeFontEnumName = "Code" }
local markdown = assert(loadfile("src/ui/markdown.lua"))()({
	require = function(id)
		if id == "ui/theme" then return theme end
		if id == "runtime/util" then return {} end
		error("unexpected dependency: " .. tostring(id))
	end,
})
local checked = 0
local function check(label, source, expected)
	local actual = markdown.inline(source)
	assert(actual == expected, label .. "\nexpected: " .. expected .. "\nactual: " .. actual)
	checked = checked + 1
end

check("snake-case identifier", "foo_bar_baz", "foo_bar_baz")
check("double-underscore identifier", "foo__bar__baz", "foo__bar__baz")
check("triple-underscore identifier", "foo___bar___baz", "foo___bar___baz")
check("leading identifier underscores", "__init__method", "__init__method")
check("numeric identifier boundaries", "version_2_beta", "version_2_beta")
check("ordinary emphasis", "Read _this_ now.", "Read <i>this</i> now.")
check("start and end boundaries", "_this_", "<i>this</i>")
check("adjacent emphasis", "_one_ _two_ _three_", "<i>one</i> <i>two</i> <i>three</i>")
check("punctuation boundaries", "(_yes_), _indeed_!", "(<i>yes</i>), <i>indeed</i>!")
check("bold underscores", "__strong__", "<b>strong</b>")
check("bold italic underscores", "___both___", "<b><i>both</i></b>")
check("mixed identifier and emphasis", "foo_bar _yes_", "foo_bar <i>yes</i>")
check("asterisk emphasis unchanged", "*yes* **strong**", "<i>yes</i> <b>strong</b>")
check("nested emphasis", "**strong _inside_**", "<b>strong <i>inside</i></b>")
check("escaped rich text", "_a < b & c_", "<i>a &lt; b &amp; c</i>")
local tick = string.char(96)
check("inline code stays literal", tick .. "foo_bar_baz * _" .. tick,
	'<font color="#CCAABB"><font face="Code">foo_bar_baz * _</font></font>')
check("escaped inline code", tick .. "<value>&" .. tick,
	'<font color="#CCAABB"><font face="Code">&lt;value&gt;&amp;</font></font>')
check("links keep identifiers", "[snake_case_name](https://example.test/foo_bar_baz)",
	'<b>snake_case_name</b> <font color="#CCAABB">https://example.test/foo_bar_baz</font>')
check("backslash escapes are literal", "\\*not emphasis\\* \\_plain\\_ \\| \\\\ \\<tag>",
	"*not emphasis* _plain_ | \\ &lt;tag&gt;")
check("multiple backticks protect pipes and emphasis", "``a ` | **b**``",
	'<font color="#CCAABB"><font face="Code">a ` | **b**</font></font>')
check("code delimiters match the entire run", "``a ` b``",
	'<font color="#CCAABB"><font face="Code">a ` b</font></font>')
check("unmatched code runs stay visible", "before ``a | b` after", "before ``a | b` after")
check("code span edge-space normalisation", "`` `a` ``",
	'<font color="#CCAABB"><font face="Code">`a`</font></font>')
check("code span all-space content survives", "`   `",
	'<font color="#CCAABB"><font face="Code">   </font></font>')
check("backslashes do not escape code closers", "`a\\` tail",
	'<font color="#CCAABB"><font face="Code">a\\</font></font> tail')
check("escaped first tick leaves a shorter opener", "\\``a|b`",
	'`<font color="#CCAABB"><font face="Code">a|b</font></font>')
check("non-ASCII and markup stay visible", "**東京 café 😀** <font size=\"99\">&lt;b&gt;</font>",
	'<b>東京 café 😀</b> &lt;font size=&quot;99&quot;&gt;&amp;lt;b&amp;gt;&lt;/font&gt;')
check("literal placeholder cannot consume content", "\1CODE1\1 `kept`",
	'\1CODE1\1 <font color="#CCAABB"><font face="Code">kept</font></font>')
check("new placeholder cannot be forged", "\1\1\1\1\1 `safe` \1\1\1\1\1",
	'\1\1\1\1\1 <font color="#CCAABB"><font face="Code">safe</font></font> \1\1\1\1\1')
theme.codeFontEnumName = "RobotoMono"
check("code font follows theme", "`café | 東京`",
	'<font color="#CCAABB"><font face="RobotoMono">café | 東京</font></font>')
print("markdown regressions: " .. checked .. " passed")
