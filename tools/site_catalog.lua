-- Export public metadata from the actual bundle in the offline client harness.
-- No provider requests, credentials or live game state are used.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local harness = require("env").new()
local handle, err = harness.boot()
assert(handle, err)

local registry = handle.tools
local groups, tools = {}, {}
for _, group in ipairs(registry.groups()) do
	groups[#groups + 1] = { id = group.id, label = group.label, total = group.total }
end
assert(#groups == #handle.env.require("tools/init").groups, "a tool group did not load")
for _, tool in ipairs(registry.list()) do
	tools[#tools + 1] = {
		name = tool.name,
		group = tool.group,
		risk = tool.risk,
		description = tool.description,
		needs = tool.needs or {},
	}
end
table.sort(tools, function(a, b) return a.name < b.name end)
assert(#tools > 0 and #harness.errors() == 0, "catalog could not be loaded cleanly")
io.write(harness.json.encode({ version = handle.version, groups = groups, tools = tools }), "\n")
