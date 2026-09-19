-- Regression checks for the real in-game transcript; no image rendering.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local h = require("env").new()
local handle = assert(h.boot())
h.settle(1)
local view = handle.app.chatPanel.view
local checks = 0
local function check(label, condition)
	assert(condition, label)
	checks = checks + 1
end
local function has(root, text) return h.textOf(root):gsub("<[^>]+>", ""):find(text, 1, true) ~= nil end
view.render({ kind = "user", text = "Review execution status" })
view.render({ kind = "tool:call", id = "a", name = "run_luau", arguments = h.json.encode({ code = "return 42" }) })
view.render({ kind = "tool:call", id = "b", name = "file_read", arguments = h.json.encode({ path = "b.lua" }) })
local a, b = view.tools.a, view.tools.b
view.render({ kind = "tool:progress", id = "a", text = "ONLY_A_PROGRESS" })
check("progress targets its own tool", has(a.root, "ONLY_A_PROGRESS") and not has(b.root, "ONLY_A_PROGRESS"))
view.render({ kind = "tool:progress", text = "AMBIGUOUS_PROGRESS" })
check("ambiguous progress does not overwrite parallel tools", not has(a.root, "AMBIGUOUS_PROGRESS") and not has(b.root, "AMBIGUOUS_PROGRESS"))
view.render({ kind = "tool:error", id = "a", name = "run_luau", ok = false, text = "Stopped.", data = { status = "aborted" }, ms = 50 })
check("cancellation has its own status", has(a.root, "Stopped") and has(a.root, "Execution stopped"))
check("cancellation exposes its details", h.byName("Detail", a.root).Visible)
view.render({ kind = "tool:progress", text = "ONLY_B_PROGRESS" })
check("legacy progress still works for a single call", has(b.root, "ONLY_B_PROGRESS"))
view.render({ kind = "tool:error", id = "b", name = "file_read", ok = false, text = "Timed out.", error = "timeout", ms = 1000 })
check("timeout has its own status", has(b.root, "Timed out") and has(b.root, "Execution timed out"))
view.render({ kind = "tool:call", id = "edit", name = "file_edit", arguments = h.json.encode({ path = "code.lua", old_text = "return 1", new_text = "return 2" }) })
local edit = view.tools.edit
local listing = h.byName("Listing", edit.root)
check("exact edits show both versions", listing and has(listing, "Before") and has(listing, "After"))
check("both code listings preserve their content", has(listing, "return 1") and has(listing, "return 2"))
view.render({ kind = "tool:result", id = "edit", name = "file_edit", ok = true, text = "Replaced one occurrence.", ms = 10 })
h.settle(0.3)
check("all rows settle", next(view.tools) == nil)
check("no asynchronous UI errors", #h.errors() == 0)
check("no property type errors", #h.instanceState.typeErrors == 0)
print(string.format("Execution UI: %d checks passed", checks))
