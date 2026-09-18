package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, json = require("env"), require("json")
local passed = 0
local function check(label, condition) assert(condition, label); passed = passed + 1; print("ok " .. label) end
local revision, treeId = string.rep("a", 40), string.rep("b", 40)
local files = { ["bridge/server.js"] = "console.log('bridge');", ["bridge/web/index.html"] = "<html>Bridge</html>",
	["bridge/web/icon.svg"] = "<svg></svg>", ["bridge/inference.js"] = "module.exports = {};" }
local function setup()
	local h = envMock.new()
	local app = assert(h.boot()); h.settle(1)
	local failPath, badPath, writes = nil, nil, 0
	h.http.handler = function(req)
		if req.url:match("/commits/main$") then return { StatusCode = 200, Body = json.encode({ sha = revision, commit = { tree = { sha = treeId } } }) } end
		if req.url:find("/git/trees/", 1, true) then
			check("file list is pinned to resolved tree", req.url:find(treeId, 1, true))
			local tree = { { path = "README.md", type = "blob", size = 2 } }
			for path, body in pairs(files) do tree[#tree + 1] = { path = path, type = "blob", size = #body } end
			if badPath then tree[#tree + 1] = { path = badPath, type = "blob", size = 1 } end
			return { StatusCode = 200, Body = json.encode({ sha = treeId, tree = tree }) }
		end
		local path = req.url:match("/" .. revision .. "/(.+)$")
		if path then
			if path == failPath then return { StatusCode = 404, Body = "Not found" } end
			return { StatusCode = 200, Body = files[path] }
		end
		error("Unexpected download URL " .. req.url)
	end
	return h, app, function(path) failPath = path end, function(path) badPath = path end
end
do
	local h, app = setup()
	app.app.show("cowork")
	local button = h.byName("DownloadBridge")
	check("Cowork exposes download button", button ~= nil)
	h.click(button); h.settle(2)
	for path, body in pairs(files) do check("download saves " .. path, h.files["UAI/" .. path] == body) end
	check("unrelated repository files are not downloaded", h.files["UAI/README.md"] == nil)
	check("status explains local startup", h.byName("BridgeDownloadStatus").Text:find("node UAI/bridge/server.js", 1, true))
	app.env.require("runtime/fsx").migrate()
	check("migration preserves installed bridge location", h.files["UAI/bridge/server.js"] == files["bridge/server.js"] and h.files["UAI/files/bridge/server.js"] == nil)
	check("button can be used again", button.Active)
	app.destroy(); h.settle(1); check("download callbacks stay clean", #h.errors() == 0)
end
do
	local h, app, fail = setup()
	h.files["UAI/bridge/server.js"] = "existing version"
	fail("bridge/web/index.html")
	local ok, err = app.env.require("runtime/bridge_install").download()
	check("network failure is reported", not ok and err:find("Could not download", 1, true))
	check("failed fetch leaves installed version intact", h.files["UAI/bridge/server.js"] == "existing version")
	check("failure releases busy guard", not app.env.require("runtime/bridge_install").busy)
	app.destroy(); h.settle(1)
end
do
	local h, app, _, bad = setup()
	bad("bridge/../config.json")
	local ok = app.env.require("runtime/bridge_install").download()
	check("invalid file paths cannot escape bridge directory", not ok and h.files["UAI/bridge/server.js"] == nil)
	app.destroy(); h.settle(1)
end
print("bridge installer: " .. passed .. " checks passed")
