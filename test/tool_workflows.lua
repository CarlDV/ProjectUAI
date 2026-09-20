-- Headless regressions for bulk tools, bounded search and exact instance paths.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local luau = require("luau")
local passed, failed = 0, 0
local function check(label, value) assert(value, label); passed = passed + 1 end
local function contains(text, value) return tostring(text):find(value, 1, true) ~= nil end
local function scenario(name, fn)
	local ok, err = pcall(fn)
	if ok then print("  ok   " .. name)
	else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end
local function fixture()
	local h = envMock.new()
	local env = { services = h.services, hs = h.services.HttpService, plr = h.localPlayer,
		info = { folder = "UAI", version = "test" }, context = {} }
	local loaded = {}
	function env.require(id)
		if loaded[id] then return loaded[id] end
		local file = assert(io.open("src/" .. id .. ".lua", "rb"))
		local source = file:read("*a"); file:close()
		local fn = assert(luau.load(source, id))
		setfenv(fn, h.sandbox)
		loaded[id] = fn()(env)
		return loaded[id]
	end
	local registry = env.require("agent/registry")
	registry.loaded = true
	for _, group in ipairs({ "fs", "instance", "script", "skills" }) do
		for _, tool in ipairs(env.require("tools/" .. group)) do tool.group = group; registry.register(tool) end
	end
	env.require("runtime/config").set("permissions.mode", "full")
	local ctx = { session = {}, aborted = function() return false end }
	local function run(name, args, seconds)
		local result
		h.sched.spawn(function()
			result = registry.dispatch({ id = "workflow", name = name, arguments = h.json.encode(args or {}) }, ctx)
		end)
		h.sched.advance(seconds or 0.2)
		assert(result, "tool did not finish: " .. name)
		return result
	end
	local function make(class, name, parent)
		local node = h.sandbox.Instance.new(class)
		node.Name, node.Parent = name, parent or h.services.Workspace
		return node
	end
	local fs = env.require("runtime/fsx")
	local function write(path, text) assert(fs.write(path, text, { scope = "files" })) end
	return h, env, registry, run, ctx, make, write
end

scenario("every conversation receives skills-first instructions and a readable inventory", function()
	local h, env = fixture()
	local skills, prompt = env.require("runtime/skills"), env.require("agent/prompt")
	assert(skills.save("First", "Standing instructions", "A complete skill body."))
	assert(skills.save("Disabled", "Do not read", "A disabled body."))
	skills.setEnabled("Disabled.md", false)
	for _, text in ipairs({ prompt.build({}), prompt.subagent("Inspect the scene") }) do
		check("skills-first rule precedes the environment", text:find("Skills FIRST", 1, true) < text:find("Environment:", 1, true))
		check("new and resumed conversations must read every enabled skill", contains(text, "EVERY new or resumed") and contains(text, "read EVERY enabled skill"))
		check("reads precede user-facing words", contains(text, "before a greeting"))
		check("continuations and lost skill context must be reread", contains(text, "every continuation offset") and contains(text, "after compaction"))
		check("the inventory identifies enabled filenames without disabled bodies", contains(text, "First.md") and not contains(text, "Disabled.md") and not contains(text, "A complete skill body."))
		check("unavailable skills do not create retry loops", contains(text, "read is denied or unavailable"))
	end
end)

scenario("skills_read recovers the full UTF-8 body across result caps", function()
	local h, env, registry, run = fixture()
	env.require("runtime/config").set("agent.resultCap", 600)
	local body = ("Read every instruction: \231\149\140\240\159\153\130.\n"):rep(600)
	assert(env.require("runtime/fsx").write("long.md", "---\nname: Long\ndescription: Complete playbook.\n---\n" .. body, { scope = "skills" }))
	local offset, pieces = 1, {}
	repeat
		local result = run("skills_read", { name = "long.md", offset = offset, limit = 64000 })
		check("skill page stays inside the result cap", result.ok and not result.truncated and #result.text <= 600)
		check("skill page has complete UTF-8", env.require("runtime/util").validUtf8(result.text))
		pieces[#pieces + 1] = result.text:match("^[^\n]*\n(.*)$")
		local nextOffset = result.data.nextOffset
		check("continuations always advance or end", nextOffset == nil or nextOffset > offset)
		offset = nextOffset
		assert(#pieces < 100, "skill pagination stalled")
	until not offset
	check("all instructions arrive exactly once", table.concat(pieces) == body and #pieces > 1)
	check("an offset past the body is refused", not run("skills_read", { name = "long.md", offset = #body + 2 }).ok)
	env.require("runtime/skills").setEnabled("long.md", false)
	check("disabled skill reads are refused", not run("skills_read", { name = "long.md" }).ok)
end)

scenario("skill inventories paginate beyond forty and duplicate names resolve by filename", function()
	local h, env, registry, run = fixture()
	local fs = env.require("runtime/fsx")
	for index = 1, 55 do
		assert(fs.write(string.format("skill-%02d.md", index), "---\nname: Shared\ndescription: A standing playbook.\n---\nBody " .. index, { scope = "skills" }))
	end
	env.require("runtime/config").set("agent.resultCap", 600)
	local pieces, offset = {}, 1
	repeat
		local result = run("skills_list", { offset = offset, limit = 64000 })
		check("inventory pages fit the result budget", result.ok and not result.truncated and #result.text <= 600)
		pieces[#pieces + 1] = result.text:match("^[^\n]*\n(.*)$")
		offset = result.data.nextOffset
		assert(#pieces < 100, "inventory pagination stalled")
	until not offset
	local inventory = table.concat(pieces)
	for index = 1, 55 do check("every enabled file is discoverable", contains(inventory, string.format("skill-%02d.md", index))) end
	check("duplicate display names can be read by exact filename", contains(run("skills_read", { name = "skill-55.md" }).text, "Body 55"))
end)

scenario("restricted subagents can read skills without gaining skill mutation tools", function()
	local h, env, registry, run, ctx = fixture()
	local subagent = env.require("agent/subagent")
	local children = {}
	env.require("agent/loop").run = function(child) children[#children + 1] = child; return "done" end
	for _, preset in ipairs({ "read", "web", "game", "full" }) do
		local completed
		h.sched.spawn(function() completed = subagent.dispatch({ task = "Inspect", preset = preset }) end)
		h.sched.advance(0.2)
		check("subagent dispatch completes", completed ~= nil)
		local child = children[#children]
		local names = {}
		for _, definition in ipairs(registry.definitions({ groups = child.toolGroups, exclude = child.toolExclude })) do names[definition["function"].name] = true end
		check(preset .. " can list and read skills", names.skills_list and names.skills_read)
		check(preset .. " keeps its mutation scope", (names.skills_write == true) == (preset == "full") and (names.skills_install == true) == (preset == "full") and (names.skills_delete == true) == (preset == "full"))
		ctx.session = child
		local result = run("skills_write", { name = preset, description = "test", body = "Only full can save." })
		check(preset .. " scope is also enforced at dispatch", result.ok == (preset == "full"))
	end
	check("subagent checks have no scheduler errors", #h.sched.errors == 0)
end)

scenario("a subagent failure releases its slot and cannot revive old workers on follow-up", function()
	local h, env = fixture()
	local subagent, loop = env.require("agent/subagent"), env.require("agent/loop")
	local failedContext, freshContext
	loop.run = function(child) failedContext = child.toolContext(); error("failed child") end
	local result, err
	h.sched.spawn(function() result, err = subagent.dispatch({ task = "Inspect", preset = "read" }) end)
	h.sched.advance(0.2)
	check("a failed child releases its running slot", result == nil and contains(err, "failed child") and subagent.live == 0)
	local record = subagent.records[1]
	check("a failed child is marked aborted", record.session.aborted())
	loop.run = function(child) freshContext = child.toolContext(); return "recovered" end
	h.sched.spawn(function() result = subagent.followUp({ id = record.id, task = "Continue" }) end)
	h.sched.advance(0.2)
	check("follow-up starts a fresh tool lifetime", result ~= nil and failedContext.aborted() and not freshContext.aborted() and subagent.live == 0)
	check("subagent recovery has no scheduler errors", #h.errors() == 0)
end)

scenario("file writes and appends reject oversized payloads before touching disk", function()
	local h, env, registry, run, ctx, make, write = fixture()
	local maximum = env.require("tools/workspace").MAX_BYTES
	local oversized = string.rep("x", maximum + 1)
	write("existing.txt", "keep")
	for _, name in ipairs({ "file_write", "file_append" }) do
		local tool = registry.get(name)
		check("payload limit is advertised", tool.parameters.properties.content.maxLength == maximum)
		check("oversized dispatch is rejected", not run(name, { path = "existing.txt", content = oversized }).ok)
		check("existing content is preserved", h.files["UAI/files/existing.txt"] == "keep")
		local rejected = tool.run({ path = "oversized.txt", content = oversized })
		check("runtime also guards callers outside schema validation", rejected.ok == false and contains(rejected.text, "at most 2 MiB") and h.files["UAI/files/oversized.txt"] == nil)
	end
	local boundary = string.rep("x", maximum)
	check("the advertised write boundary is accepted", run("file_write", { path = "boundary.txt", content = boundary }).ok and #h.files["UAI/files/boundary.txt"] == maximum)
	check("small appends still work", run("file_append", { path = "existing.txt", content = " more" }).ok and h.files["UAI/files/existing.txt"] == "keep more")
end)

scenario("quoted paths and live instance links resolve exactly", function()
	local h, env, registry, run, ctx, make = fixture()
	local H = env.require("tools/helpers")
	local node = h.services.Workspace
	for _, name in ipairs({ "Room.A", "Switch[1]", 'say"hello', "back\\slash", "  padded  ", "", "界", "line\nbreak" }) do
		node = make("Folder", name, node)
		local path = H.pathOf(node)
		check("round trip: " .. name, H.resolve(path) == node)
	end
	check("game service alias works", H.resolve("game.Workspace") == h.services.Workspace)
	check("character reference works", h.localPlayer.Character and H.resolve("me.Character") == h.localPlayer.Character)
	check("camera link works", H.resolve("Workspace.CurrentCamera") == h.services.Workspace.CurrentCamera)
	for _, path in ipairs({ "Workspace..Part", 'Workspace["open"', "Workspace[print(1)]", "Workspace." }) do
		check("malformed path refused: " .. path, H.resolve(path) == nil)
	end
	check("source-like names were not executed", #h.console.out == 0)
	check("string coercion preserves whitespace", H.coerce("\n hello  \n", "") == "\n hello  \n")
	check("nonfinite numbers are refused", H.coerce(math.huge, 0) == nil)
	check("ordinary numbers still work", H.coerce("1.25", 0) == 1.25)
end)

scenario("queries combine filtering, projections and early stopping", function()
	local h, env, registry, run, ctx, make = fixture()
	local zone = make("Folder", "QueryZone")
	for index = 1, 3000 do
		local part = make("Part", "Block" .. index, zone)
		part.Anchored = index % 2 == 0
		part:SetAttribute("Index", index)
		part:AddTag("block")
	end
	rawset(zone, "GetDescendants", function() error("whole-tree allocation must not run") end)
	local childrenCalls, original = 0, zone.GetChildren
	rawset(zone, "GetChildren", function(self) childrenCalls = childrenCalls + 1; return original(self) end)
	local one = run("instance_query", { root = "Workspace.QueryZone", class = "BasePart", tag = "block", limit = 1,
		properties = { "Anchored" }, attributes = { "Index" } })
	check("query succeeds without GetDescendants", one.ok)
	check("only the first node is inspected", one.data.scanned == 1 and childrenCalls == 1)
	check("property and attribute returned together", one.data.items[1].properties.Anchored == "false" and one.data.items[1].attributes.Index == "1")
	check("query returns a continuation", one.data.nextOffset == 2)
	local found = run("instance_find", { root = "Workspace.QueryZone", name = "Block", limit = 1 })
	check("existing find also stops early", found.ok and contains(found.text, "1 match(es)") and childrenCalls == 2)
	check("no asynchronous errors", #h.sched.errors == 0)
	print("       early-result check: 1 node inspected in a 3,000-node subtree")
end)

scenario("instance pages retain all matches and isolate missing paths", function()
	local h, env, registry, run, ctx, make = fixture()
	local zone = make("Folder", "Pages")
	for index = 1, 5 do make("Part", "Pick." .. index, zone) end
	local offset, seen, count = nil, {}, 0
	repeat
		local result = run("instance_query", { root = "Workspace.Pages", class = "Part", limit = 2, offset = offset, properties = { "Name" } })
		check("query page succeeds", result.ok and not result.truncated)
		for _, item in ipairs(result.data.items) do
			check("page has no duplicate", not seen[item.path])
			seen[item.path], count = true, count + 1
			check("reported path resolves", env.require("tools/helpers").resolve(item.path) ~= nil)
		end
		offset = result.data.nextOffset
	until not offset
	check("all five matches were returned", count == 5)
	local many = run("instance_get_many", { paths = { 'Workspace.Pages["Pick.1"]', "Workspace.Missing", 'Workspace.Pages["Pick.3"]' },
		properties = { "Name", "Source" } })
	check("partial success is retained", many.ok and #many.data.results == 3)
	check("missing path has its own failure", not many.data.results[2].ok and contains(many.data.results[2].error, "has no child"))
	check("source is not dumped into a bulk response", many.data.results[1].properties.Source == "<use script_source>")
	env.require("runtime/config").set("agent.resultCap", 600)
	local small = run("instance_get_many", { paths = { 'Workspace.Pages["Pick.1"]', 'Workspace.Pages["Pick.2"]', 'Workspace.Pages["Pick.3"]', 'Workspace.Pages["Pick.4"]', 'Workspace.Pages["Pick.5"]' }, properties = { "Name" } })
	check("inspection obeys the output budget", not small.truncated and #small.text <= 600)
	check("overflow has a resumable index", small.data.nextIndex and small.data.nextIndex > 1)
end)

scenario("large scans respond to Stop", function()
	local h, env, registry, run, ctx, make = fixture()
	local zone = make("Folder", "AbortZone")
	for index = 1, 3000 do make("Part", "Block" .. index, zone) end
	local stopped = false
	ctx.aborted = function() return stopped end
	h.sched.delay(0.01, function() stopped = true end)
	local result = run("instance_query", { root = "Workspace.AbortZone", name = "does not exist" })
	check("scan reports cancellation", not result.ok and result.data.status == "aborted")
	check("scan did not visit the whole tree", result.data.scanned < 3000)
end)

scenario("file search reports exact positions and resumes without duplicates", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("src/alpha.lua", 'local Item = "界"\nreturn Item\n')
	write("src/nested/beta.lua", "local item = 3\n")
	write("src/ignore.txt", "item\n")
	write("binary.lua", "\0item")
	assert(env.require("runtime/fsx").write("config.json", "private-marker"))
	local cursor, seen, count = nil, {}, 0
	repeat
		local result = run("file_search", { query = "item", glob = "*.lua", limit = 1, cursor = cursor })
		check("search page succeeds", result.ok and not result.truncated)
		for _, hit in ipairs(result.data.matches) do
			local key = hit.path .. ":" .. hit.line
			check("matching line returned only once", not seen[key])
			seen[key], count = true, count + 1
			local source = env.require("runtime/fsx").read(hit.path, { scope = "files" })
			check("offset points at the literal", source:sub(hit.offset, hit.offset + 3):lower() == "item")
		end
		cursor = result.data.nextCursor
	until not cursor
	check("all eligible matches found", count == 3)
	local exact = run("file_search", { query = "Item", path = "src", glob = "*.lua", case_sensitive = true })
	check("case-sensitive search is literal", #exact.data.matches == 2)
	local oneFile = run("file_search", { query = "item", path = "src/nested/beta.lua" })
	check("single-file roots work", oneFile.ok and #oneFile.data.matches == 1)
	local private = run("file_search", { query = "private-marker" })
	check("client state is outside the search scope", #private.data.matches == 0)
	check("invalid traversal is refused", not run("file_search", { query = "item", path = "../" }).ok)
	check("multiline search is explicit about its limit", not run("file_search", { query = "a\nb" }).ok)
end)

scenario("search failures and line-budget continuation remain usable", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("long.lua", ("nothing here\n"):rep(50001) .. "needle\n")
	local first = run("file_search", { query = "needle" }, 1.2)
	check("bounded search returns a cursor", first.ok and #first.data.matches == 0 and first.data.nextCursor.line == 50001)
	check("cursor includes a direct byte offset", first.data.nextCursor.offset > 1)
	check("line accounting stays within the page budget", first.data.scannedLines == 50000)
	local second = run("file_search", { query = "needle", cursor = first.data.nextCursor })
	check("continuation crosses the scan budget", second.ok and #second.data.matches == 1 and second.data.matches[1].line == 50002)
	check("continuation avoids rescanning the prefix", second.data.scannedLines == 2)
	local caps = env.require("runtime/caps")
	local original = caps.fn.readfile
	caps.fn.readfile = function(path) if path:find("long.lua", 1, true) then error("unreadable fixture") end; return original(path) end
	local broken = run("file_search", { query = "needle" })
	check("unreadable files are not empty search success", not broken.ok and #broken.data.errors == 1 and not broken.data.complete)
	check("failure summary is visible", contains(broken.text, "1 read error"))
	check("failure identifies the file and cause", contains(broken.text, "long.lua") and contains(broken.text, "unreadable fixture"))
end)

scenario("search supports shallow basename listings and bounded glob matching", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("src/root.lua", "needle")
	write("src/nested/deep.lua", "needle")
	write("src/nested/a[1].lua", "needle")
	local caps = env.require("runtime/caps")
	local list = caps.fn.listfiles
	caps.fn.listfiles = function(path)
		local result = {}
		for _, entry in ipairs(list(path)) do
			local relative = entry:sub(#path + 2)
			if not relative:find("/", 1, true) then result[#result + 1] = relative end
		end
		return result
	end
	local result = run("file_search", { query = "needle", path = "src", glob = "*.lua" })
	check("shallow hosts search all subfolders", result.ok and #result.data.matches == 3)
	local literal = run("file_search", { query = "needle", path = "src", glob = "a[1].lua" })
	check("glob punctuation remains literal", literal.ok and #literal.data.matches == 1)
	local W = env.require("tools/workspace")
	check("glob question mark matches one Unicode character", W.matches("界.lua", "?.lua"))
	check("many wildcards do not cause exponential pattern matching", not W.matches(("a"):rep(180), ("*a"):rep(50) .. "z"))
	check("glob suffix matching stays exact", not W.matches("module.luau", "*.lua"))
end)

scenario("skipped oversized files consume the search read budget", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("a-large.lua", ("x"):rep(9 * 1024 * 1024))
	write("z-small.lua", "needle")
	local caps, reads = env.require("runtime/caps"), 0
	local originalRead = caps.fn.readfile
	caps.fn.readfile = function(...) reads = reads + 1; return originalRead(...) end
	local first = run("file_search", { query = "needle" })
	check("oversized reads stop the page before another file", first.ok and reads == 1 and first.data.skipped == 1)
	check("skipped files still give a forward cursor", not first.data.complete and first.data.nextCursor.path == "z-small.lua")
	local nextPage = run("file_search", { query = "needle", cursor = first.data.nextCursor })
	check("continuation reaches the next file without rereading the large one", nextPage.ok and reads == 2 and #nextPage.data.matches == 1)
end)

scenario("batch reads share output space and preserve per-file continuations", function()
	local h, env, registry, run, ctx, make, write = fixture()
	local text = ("界🙂\n"):rep(200)
	write("one.lua", text)
	write("two.lua", "two")
	assert(env.require("runtime/fsx").write("paste.txt", "saved", { scope = "pastes" }))
	local result = run("file_read_many", { reads = { { path = "one.lua" }, { path = "missing.lua" }, { path = "UAI/pastes/paste.txt" } } })
	check("valid batch reads survive one missing file", result.ok and #result.data.results == 3 and not result.data.results[2].ok)
	check("pastes share the same read rules", result.data.results[3].ok and contains(result.text, "saved"))
	check("long file has continuation offset", result.data.results[1].slice.nextOffset > 1)
	check("UTF-8 output remains valid", env.require("runtime/util").validUtf8(result.text))
	local caps, nativeReads = env.require("runtime/caps"), 0
	local originalRead = caps.fn.readfile
	caps.fn.readfile = function(...) nativeReads = nativeReads + 1; return originalRead(...) end
	local repeated = run("file_read_many", { reads = {
		{ path = "one.lua", limit = 64 }, { path = "two.lua" }, { path = "one.lua", offset = 65, limit = 64 },
	} })
	check("repeated slices reuse one native read per file", repeated.ok and #repeated.data.results == 3 and nativeReads == 2)
	write("two.lua", "updated")
	local fresh = run("file_read_many", { reads = { { path = "two.lua" } } })
	check("read cache ends with the call", fresh.ok and contains(fresh.text, "updated"))
	caps.fn.readfile = originalRead
	env.require("runtime/config").set("agent.resultCap", 600)
	local requests = { { path = "one.lua", limit = 64 }, { path = "two.lua" }, { path = "paste.txt" } }
	local small = run("file_read_many", { reads = requests })
	check("small batch stays inside the registry cap", small.ok and not small.truncated and #small.text <= 600)
	check("unread files get a continuation index", small.data.nextIndex and small.data.nextIndex > 1)
	local rest = run("file_read_many", { reads = requests, start_index = small.data.nextIndex })
	check("next batch finishes the remaining requests", rest.ok and rest.data.nextIndex == nil)
end)

scenario("multiple edits validate together and use one write", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("edit.lua", "hello world\nvalue=1\nend\n")
	local caps = env.require("runtime/caps")
	local writes, originalWrite = 0, caps.fn.writefile
	caps.fn.writefile = function(...) writes = writes + 1; return originalWrite(...) end
	local result = run("file_edit_many", { path = "edit.lua", edits = {
		{ old_text = "hello", new_text = "hi" },
		{ old_text = "hi world", new_text = "hello again" },
		{ old_text = "end\n", new_text = "" },
	} })
	check("all edits succeeded", result.ok and result.data.edits == 3)
	check("edits use one write", writes == 1)
	check("edits see previous replacements", env.require("runtime/fsx").read("edit.lua", { scope = "files" }) == "hello again\nvalue=1\n")
	writes = 0
	local refused = run("file_edit_many", { path = "edit.lua", edits = {
		{ old_text = "hello", new_text = "hi" },
		{ old_text = "missing", new_text = "oops" },
	} })
	check("later failure prevents every write", not refused.ok and writes == 0)
	check("failed batch preserves original bytes", contains(env.require("runtime/fsx").read("edit.lua", { scope = "files" }), "hello again"))
	check("failure identifies the edit", contains(refused.text, "edit 2"))
	local noop = run("file_edit_many", { path = "edit.lua", edits = { { old_text = "hello", new_text = "hello" } } })
	check("no-op batches avoid disk writes", noop.ok and not noop.data.changed and writes == 0)
end)

scenario("batch schema limits and permissions are enforced", function()
	local h, env, registry, run, ctx, make, write = fixture()
	check("empty reads refused", not run("file_read_many", { reads = {} }).ok)
	check("empty edits refused", not run("file_edit_many", { path = "x", edits = {} }).ok)
	local paths = {}
	for index = 1, 21 do paths[index] = "Workspace" end
	local tooMany = run("instance_get_many", { paths = paths })
	check("oversized arrays refused", not tooMany.ok and contains(tooMany.text, "at most 20"))
	registry.setGroupEnabled("fs", false)
	check("new file tools obey disabled groups", not run("file_search", { query = "text" }).ok)
	registry.setGroupEnabled("fs", true)
	env.require("runtime/config").set("permissions.mode", "readonly")
	local available = {}
	for _, definition in ipairs(registry.definitions()) do available[definition["function"].name] = true end
	check("batch reads available in readonly mode", available.file_search and available.file_read_many and available.instance_get_many and available.instance_query)
	check("batch edits omitted in readonly mode", not available.file_edit_many)
	check("no unexpected scheduler errors", #h.sched.errors == 0)
end)

scenario("edit batches reject stale files and stop before writes", function()
	local h, env, registry, run, ctx, make, write = fixture()
	write("stale.lua", "value=1")
	local caps, reads = env.require("runtime/caps"), 0
	local originalRead, originalWrite = caps.fn.readfile, caps.fn.writefile
	caps.fn.readfile = function(path)
		reads = reads + 1
		if reads == 2 then originalWrite(path, "changed elsewhere") end
		return originalRead(path)
	end
	local stale = run("file_edit_many", { path = "stale.lua", edits = { { old_text = "value=1", new_text = "value=2" } } })
	check("stale preflight fails", not stale.ok and contains(stale.text, "file changed"))
	check("external update survives", originalRead("UAI/files/stale.lua") == "changed elsewhere")
	caps.fn.readfile = originalRead
	write("large.txt", ("a"):rep(131072))
	local writes, stopped = 0, false
	caps.fn.writefile = function(...) writes = writes + 1; return originalWrite(...) end
	ctx.aborted = function() return stopped end
	h.sched.delay(0.01, function() stopped = true end)
	local result = run("file_edit_many", { path = "large.txt", edits = { { old_text = "a", new_text = "b", replace_all = true } } })
	check("cancellation prevents every write", not result.ok and writes == 0)
	check("cancelled edits report an aborted status", result.data and result.data.status == "aborted")
	check("cancelled batch leaves original contents", originalRead("UAI/files/large.txt") == ("a"):rep(131072))
end)

print(string.format("Tool workflows: %d checks passed, %d scenarios failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
