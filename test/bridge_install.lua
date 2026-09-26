package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock, json = require("env"), require("json")
local passed = 0
local function check(label, condition) assert(condition, label); passed = passed + 1; print("ok " .. label) end
local revision, treeId, blobSha = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
local files = {
    ["bridge/server.js"] = "console.log('bridge');", ["bridge/inference.js"] = "module.exports = {};",
    ["bridge/picture-store.js"] = "module.exports = {};", ["bridge/launcher.js"] = "module.exports = {};",
    ["bridge/web/index.html"] = "<html>Bridge</html>", ["bridge/web/icon.png"] = "PNG" .. string.char(0, 128, 255),
    ["bridge/web/assets/nested.css"] = "body{}",
}
local function setup(options)
    options = options or {}
    local h = envMock.new()
    local app = assert(h.boot()); h.settle(1)
    local controls, fetched = {}, {}
    local caps = app.env.require("runtime/caps")
    local originalWrite = caps.fn.writefile
    caps.fn.writefile = function(path, content)
        if path:find("UAI/bridge/", 1, true) then
            assert(path:sub(-4) == ".txt", "executor rejects executable extensions")
            if controls.failWrite and path:find(controls.failWrite, 1, true) then
                controls.failWrite = nil
                h.files[path] = "partial write"
                error("fixture write failure")
            end
        end
        return originalWrite(path, content)
    end
    h.http.handler = function(req)
        if req.url:match("/commits/main$") then
            return { StatusCode = 200, Body = json.encode({ sha = controls.badRevision or revision, commit = { tree = { sha = treeId } } }) }
        end
        if req.url:find("/git/trees/", 1, true) then
            check("file list uses resolved tree", req.url:find(treeId, 1, true))
            local tree = {
                { path = "README.md", type = "blob", size = 2 },
                { path = "bridge/README.md", type = "blob", size = 2 },
                { path = "bridge/tests/runtime.test.js", type = "blob", size = 2 },
                { path = "bridge/test-old.js", type = "blob", size = 2 },
            }
            for path, body in pairs(files) do
                if path ~= controls.missing then tree[#tree + 1] = { path = path, type = "blob", size = #body, sha = controls.badBlob or blobSha } end
            end
            if controls.badPath then tree[#tree + 1] = { path = controls.badPath, type = "blob", size = 1, sha = blobSha } end
            return { StatusCode = 200, Body = json.encode({ sha = controls.wrongTree or treeId, tree = tree, truncated = controls.truncated }) }
        end
        local path = req.url:match("/" .. revision .. "/(.+)$")
        if path then
            fetched[#fetched + 1] = path
            if path == controls.failFetch then return { StatusCode = 404, Body = "Not found" } end
            assert(files[path], "only runtime assets may be fetched: " .. path)
            return { StatusCode = 200, Body = path == controls.shortFile and "x" or files[path] }
        end
        error("Unexpected download URL " .. req.url)
    end
    return h, app, controls, fetched
end
local function installedPrefix(h)
    local launcher = h.files["UAI/bridge/start.txt"] or ""
    local packageId = launcher:match("require%('%./packages/([^/]+)/launcher%.js%.txt'%)")
    return packageId and ("UAI/bridge/packages/" .. packageId .. "/")
end
do
    local h, app = setup()
    app.app.show("cowork")
    local button = h.byName("DownloadBridge")
    check("Cowork exposes download and copy-start controls", button ~= nil and h.byName("CopyBridgeStart") ~= nil)
    h.click(button); h.settle(2)
    local prefix = installedPrefix(h)
    check("launcher selects a pinned package", prefix and prefix:find(revision, 1, true))
    for path, body in pairs(files) do check("restricted filesystem saves " .. path, h.files[prefix .. path:sub(8) .. ".txt"] == body) end
    check("runtime files are not written with blocked extensions", h.files["UAI/bridge/server.js"] == nil)
    check("setup explains the .txt start command", h.byName("BridgeDownloadStatus").Text:find("node UAI/bridge/start.txt", 1, true))
    app.env.require("runtime/fsx").migrate()
    check("migration preserves the bridge launcher", installedPrefix(h) == prefix and h.files["UAI/files/bridge/start.txt"] == nil)
    check("download button is reusable", button.Active)
    app.destroy(); h.settle(1); check("download callbacks stay clean", #h.errors() == 0)
end
for _, failure in ipairs({
    { failFetch = "bridge/web/index.html" }, { shortFile = "bridge/server.js" },
    { badPath = "bridge/../config.json" }, { truncated = true }, { wrongTree = string.rep("d", 40) },
    { badRevision = "main" }, { badBlob = "invalid" }, { missing = "bridge/launcher.js" },
    { failWrite = "/web/index.html.txt" }, { failWrite = "/bridge/start.txt" },
}) do
    local h, app, controls = setup()
    h.files["UAI/bridge/start.txt"] = "old launcher"
    h.files["UAI/bridge/server.js"] = "old bridge"
    for key, value in pairs(failure) do controls[key] = value end
    local ok, err = app.env.require("runtime/bridge_install").download()
    local label = next(failure)
    check(label .. " is reported", not ok and type(err) == "string")
    check(label .. " preserves launcher", h.files["UAI/bridge/start.txt"] == "old launcher")
    check(label .. " preserves existing bridge", h.files["UAI/bridge/server.js"] == "old bridge")
    check(label .. " releases busy guard", not app.env.require("runtime/bridge_install").busy)
    app.destroy(); h.settle(1)
end
do
    local h, app, controls = setup()
    local installer = app.env.require("runtime/bridge_install")
    check("initial installation succeeds", installer.download())
    local oldLauncher, prefix = h.files["UAI/bridge/start.txt"], installedPrefix(h)
    controls.failWrite = "/web/index.html.txt"
    check("failed reinstall is reported", not installer.download())
    check("same-revision failure keeps the old launcher", h.files["UAI/bridge/start.txt"] == oldLauncher)
    check("same-revision failure keeps the old package intact", h.files[prefix .. "web/index.html.txt"] == files["bridge/web/index.html"])
    app.destroy(); h.settle(1)
end
print("bridge installer: " .. passed .. " checks passed")
