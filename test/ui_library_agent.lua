-- The built client supplies the same guide to both main and delegated agents.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local h = require("env").new()
local client, why = h.boot("dist/uai.lua")
assert(client, why)
h.settle(0.5)
local passed = 0
local function check(label, condition) assert(condition, label); passed = passed + 1; print("ok " .. label) end
local tool
for _, definition in ipairs(client.env.require("tools/gui")) do
	if definition.name == "ui_library_docs" then tool = definition end
end
check("UI library reference is a read-only tool without executor requirements", tool and tool.risk == "read" and tool.needs == nil)
local docs = client.env.require("runtime/ui_library_docs")
check("reference identifies the canonical standalone loader", tool.run({}):find(docs.url, 1, true) ~= nil)
local before = #h.http.log
local rootsBefore = #h.coreGui:GetChildren()
for _, name in ipairs({ "quickstart", "controls", "layout", "lifecycle", "configuration", "recipes", "development" }) do
	local offset, slices, parts = 1, 0, {}
	repeat
		local page = tool.run({ section = name, offset = offset, limit = 512 })
		assert(page.data and page.data.offset == offset)
		parts[#parts + 1] = page.text:match("^[^\n]*\n(.*)$")
		offset, slices = page.data.nextOffset, slices + 1
		assert(slices < 100, "reference pagination did not finish")
	until not offset
	check(name .. " reference pages preserve the exact guide", table.concat(parts) == docs.sections[name])
end
check("reference reads make no HTTP requests", #h.http.log == before)
check("unknown section returns a tool failure", tool.run({ section = "missing" }).ok == false)
local prompt = client.env.require("agent/prompt")
local main, child = prompt.build(), prompt.subagent("Create a script UI")
for _, phrase in ipairs({ "Project UAI UI LIB", "ui_library_docs", "window:Give", "Project UAI | UI LIB.", docs.url }) do
	check("both agents receive " .. phrase, main:find(phrase, 1, true) and child:find(phrase, 1, true))
end
check("reading UI docs does not mount a script window", #h.coreGui:GetChildren() == rootsBefore)
check("client has no uncaught asynchronous errors", #h.errors() == 0)
client.unload()
print("UI library agent integration: " .. passed .. " checks passed")
