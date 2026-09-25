-- Provider setup regressions through real controls and synthetic responses.
-- No running model, credentials or executor workspace is used.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Provider editor")
local case, check = suite.case, suite.check

local function click(f, name, root)
	local control = assert(f.h.byName(name, root), "missing control: " .. name)
	f.h.click(control)
	return control
end

local function field(f, name, value)
	local row = assert(f.h.byName(name), "missing field: " .. name)
	f.h.type(assert(row:FindFirstChildOfClass("TextBox")), value)
end

local function closeMenu(f)
	if f.h.byName("MenuLayer") then f.h.press("Escape") end
end

local function preset(f, id)
	closeMenu(f)
	click(f, "Preset")
	click(f, "Option_" .. id)
end

local function key(f, value)
	click(f, "SetKey")
	field(f, "PromptField", value)
	for _, node in ipairs(f.env.root:GetDescendants()) do
		if node.ClassName == "TextLabel" and node.Text == "Save key" then
			local button = node.Parent
			while button and button.ClassName ~= "TextButton" do button = button.Parent end
			assert(button, "missing key confirmation")
			f.h.click(button)
			return
		end
	end
	error("missing Save key button")
end

local function fixture(initialPreset)
	local f = F.ui(1000, 850)
	local registry = f.env.require("provider/registry")
	local record = registry.blank(initialPreset or "custom")
	record.label, record.baseUrl, record.apiKey = "My connection", "https://editor.fixture/v1", "fixture-key"
	record.model, record.models = "manual-model", { "manual-model" }
	record.wsUrl = "wss://gateway.fixture/old-upstream"
	f.original = record
	f.env.require("ui/panels/providers").editor(record, function(id) f.saved = registry.get(id) end)
	f.h.settle(0.2)
	return f
end

local function fetch(f)
	closeMenu(f)
	click(f, "ActiveModel")
	click(f, "Option_fetch")
end

local function response(f, model, delay)
	return { StatusCode = 200, Body = f.h.json.encode({ data = { { id = model } } }), delay = delay }
end

for _, id in ipairs({ "ollama", "lmstudio", "vllm", "llamacpp", "sglang" }) do
	case(id .. " applies local defaults when chosen inside Add Provider", function()
		local f = fixture()
		preset(f, id)
		local expected = f.env.require("provider/catalog").get(id)
		check("local setup documentation is shown", f.h.byName("KeyLinkUrl").Text == expected.docs)
		check("setup link is not described as a key vendor", f.h.textOf():find("Server setup and API documentation", 1, true) ~= nil)
		click(f, "SaveProvider")
		local saved = assert(f.saved, "provider was not saved")
		check("chosen server/protocol saved", saved.preset == id and saved.baseUrl == expected.baseUrl and saved.api == "openai")
		check("neutral identity and optional auth survive the UI", saved.claudeUa == false and saved.authStyle == "none")
		check("another upstream's gateway is cleared", saved.wsUrl == "")
		check("typed name, key and model survive", saved.label == "My connection" and saved.apiKey == "fixture-key"
			and saved.model == "manual-model" and #saved.models == 1)
		check("editing did not mutate the original record", f.original.preset == "custom" and f.original.wsUrl ~= "")
		check("setup never performs inference", f.h.http.requestCount == 0)
		f.healthy(); f.close()
	end)
end

case("reselecting the current preset preserves its gateway", function()
	local f = fixture("openai")
	preset(f, "openai")
	click(f, "SaveProvider")
	check("same preset keeps its gateway", f.saved and f.saved.wsUrl == f.original.wsUrl)
	check("no connection test was dispatched", f.h.http.requestCount == 0)
	f.healthy(); f.close()
end)

local changes = {
	{ "URL", function(f, changed) field(f, "BaseUrl", changed and "https://other.fixture/prefix/v1" or f.original.baseUrl) end },
	{ "protocol", function(f, changed) click(f, "Segment_" .. (changed and "anthropic" or "openai"), f.h.byName("Protocol")) end },
	{ "auth header", function(f, changed) click(f, "Segment_" .. (changed and "x-api-key" or "bearer"), f.h.byName("AuthStyle")) end },
	{ "key", function(f, changed) key(f, changed and "fixture-replacement" or "fixture-key") end },
	{ "preset", function(f, changed)
		preset(f, changed and "ollama" or "custom")
		if not changed then field(f, "BaseUrl", f.original.baseUrl) end
	end },
}

for _, change in ipairs(changes) do
	case(change[1] .. " edits discard fetched choices and supersede pending discovery", function()
		local f = fixture()
		local requests = 0
		f.h.http.handler = function(entry)
			check("discovery only makes GET requests", entry.method == "GET")
			requests = requests + 1
			return response(f, ({ "before-edit", "obsolete-pending", "current-model" })[requests], requests == 2 and 20 or 0)
		end
		fetch(f)
		check("successful discovery opens its choices", f.h.byName("Option_model:before-edit") ~= nil)
		check("manual choice stays available", f.h.byName("Option_model:manual-model") ~= nil)
		closeMenu(f)
		change[2](f, true)
		click(f, "ActiveModel")
		check("previous fetched choice expires", f.h.byName("Option_model:before-edit") == nil)
		check("connection edit preserves manual choice", f.h.byName("Option_model:manual-model") ~= nil)
		click(f, "Option_fetch")
		check("fetch is pending", not f.h.byName("ActiveModel").Active and requests == 2)
		change[2](f, false)
		check("edited connection can fetch without waiting for the old server", f.h.byName("ActiveModel").Active)
		fetch(f)
		check("new connection's result is offered", f.h.byName("Option_model:current-model") ~= nil)
		f.h.sched.advance(22)
		check("late old response cannot replace the choices", f.h.byName("Option_model:current-model") ~= nil
			and f.h.byName("Option_model:obsolete-pending") == nil)
		closeMenu(f)
		click(f, "SaveProvider")
		check("manual selection survives all connection edits", f.saved and f.saved.model == "manual-model" and #f.saved.models == 1)
		check("exactly three requested discoveries", requests == 3)
		f.healthy(); f.close()
	end)
end

case("an open menu cannot select a model fetched for a previous connection", function()
	local f = fixture()
	f.h.http.handler = function() return response(f, "previous-connection-model", 0) end
	fetch(f)
	check("old connection's menu is open", f.h.byName("Option_model:previous-connection-model") ~= nil)
	field(f, "BaseUrl", "https://changed.fixture/v1")
	click(f, "Option_model:previous-connection-model")
	click(f, "SaveProvider")
	check("obsolete menu selection cannot change the model", f.saved and f.saved.model == "manual-model" and #f.saved.models == 1)
	f.healthy(); f.close()
end)

case("changing away and back cannot revive the original pending fetch", function()
	local f = fixture()
	f.h.http.handler = function() return response(f, "obsolete-round-trip", 10) end
	fetch(f)
	field(f, "BaseUrl", "https://temporary.fixture/v1")
	field(f, "BaseUrl", f.original.baseUrl)
	f.h.sched.advance(12)
	check("a matching URL does not revive an old request", f.h.byName("MenuLayer") == nil)
	click(f, "ActiveModel")
	check("obsolete models stay absent", f.h.byName("Option_model:obsolete-round-trip") == nil)
	check("manual model remains available", f.h.byName("Option_model:manual-model") ~= nil)
	check("no unrequested refetch", f.h.http.requestCount == 1)
	f.healthy(); f.close()
end)

case("an uncooperative old discovery cannot unlock or overwrite a newer fetch", function()
	local f = fixture()
	local requests = 0
	-- Deliberately ignore cancellation to exercise the editor's final publication
	-- check independently of the transport's cooperative abort handling.
	f.env.require("provider/models").discover = function()
		requests = requests + 1
		local index = requests
		f.h.sched.wait(index == 1 and 4 or 10)
		return { index == 1 and "late-old" or "latest" }, "1 model from synthetic discovery"
	end
	fetch(f)
	field(f, "BaseUrl", "https://new.fixture/v1")
	fetch(f)
	f.h.sched.advance(3)
	check("older completion cannot enable the newer pending picker", not f.h.byName("ActiveModel").Active)
	check("older completion cannot open a menu", f.h.byName("MenuLayer") == nil)
	f.h.sched.advance(10)
	check("newest completion enables the picker", f.h.byName("ActiveModel").Active)
	check("only newest choices are shown", f.h.byName("Option_model:latest") ~= nil and f.h.byName("Option_model:late-old") == nil)
	check("exactly the requested operations ran", requests == 2)
	f.healthy(); f.close()
end)

suite.finish()
