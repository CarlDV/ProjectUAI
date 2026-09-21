-- Run the existing offline scenarios with the real Luau compiler/runtime.
-- Lune supplies Luau, not Roblox's GUI renderer or live services; the same
-- deterministic service/instance harness is used as in the LuaJIT suite.
-- Usage: lune run test/lune_runner test/mobile_ui.lua [bundle] [baseline bundle]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local compiled = 0
local function compileTree(path)
	for _, name in ipairs(fs.readDir(path)) do
		local entry = path .. "/" .. name
		if fs.isDir(entry) then compileTree(entry)
		elseif name:match("%.lua$") then
			luau.compile(fs.readFile(entry), { optimizationLevel = 2 })
			compiled += 1
		end
	end
end
compileTree("src")
luau.compile(fs.readFile("init.lua"), { optimizationLevel = 2 })
luau.compile(fs.readFile("dist/uai.lua"), { optimizationLevel = 2 })
print(string.format("Lune: compiled %d modules, bootstrap and shipped bundle", compiled))

local compat = table.clone(getfenv())
compat._G = compat
compat.package = { path = "test/?.lua;test/mock/?.lua;" }
compat.unpack = table.unpack
-- LuaJIT reports nil on the test driver; Lune runs it in a managed coroutine.
-- Keep virtual waits on the driver advancing the mock clock, not yielding that
-- managed coroutine without a native scheduler wakeup.
local driver = coroutine.running()
compat.coroutine = table.clone(coroutine)
compat.coroutine.running = function()
	local thread = coroutine.running()
	return thread ~= driver and thread or nil
end
compat.os = table.clone(os)
compat.os.exit = process.exit
local scriptPath = process.args[1] or "test/mobile_ui.lua"
compat.arg = { [0] = scriptPath }
for index = 2, #process.args do compat.arg[index - 1] = process.args[index] end

-- Only the file APIs exercised by the tests. No application filesystem/HTTP
-- escapes the harness: those remain its in-memory, scripted implementations.
compat.io = {}
function compat.io.open(path, mode)
	local writing = mode and (mode:find("w", 1, true) or mode:find("a", 1, true))
	if not writing and not fs.isFile(path) then return nil, "file not found: " .. path end
	local body = fs.isFile(path) and fs.readFile(path) or ""
	if mode and mode:find("w", 1, true) then body = "" end
	local file = {}
	function file:read(format)
		assert(format == "*a", "unsupported test read format: " .. tostring(format))
		return body
	end
	function file:write(...)
		for index = 1, select("#", ...) do body ..= tostring(select(index, ...)) end
		return self
	end
	function file:close() if writing then fs.writeFile(path, body) end end
	return file
end
local function write(...)
	local parts = {}
	for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
	stdio.write(table.concat(parts))
end
compat.io.write = write
compat.io.stdout = { setvbuf = function() end, write = function(_, ...) write(...) end }
compat.io.stderr = compat.io.stdout
compat.print = function(...)
	local parts = {}
	for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
	stdio.write(table.concat(parts, "\t") .. "\n")
end

function compat.loadstring(source, name)
	local ok, fn = pcall(luau.load, source, {
		debugName = name or "test chunk", environment = compat, injectGlobals = false,
	})
	if ok then return fn end
	return nil, tostring(fn)
end
function compat.loadfile(path)
	if not fs.isFile(path) then return nil, "file not found: " .. path end
	return compat.loadstring(fs.readFile(path), "@" .. path)
end
function compat.dofile(path) return assert(compat.loadfile(path))() end
local loaded = {}
function compat.require(name)
	if loaded[name] ~= nil then return loaded[name] end
	if name == "bit" then return bit32 end
	for pattern in compat.package.path:gmatch("[^;]+") do
		local path = pattern:gsub("%?", (name:gsub("%.", "/")))
		if fs.isFile(path) then
			local result = compat.dofile(path)
			loaded[name] = result == nil and true or result
			return loaded[name]
		end
	end
	error("test module not found: " .. name)
end
stdio.write("Lune: running " .. scriptPath .. "\n")
compat.dofile(scriptPath)
stdio.write("Lune: scenario file completed\n")
process.exit(0)
