-- Offline checker: lints, transpiles and parses every module, then verifies the
-- env.require graph and flags suspicious globals.
--
--   luajit test/check.lua            (from the repo root)
--   luajit test/check.lua src/ui     (restrict to a subtree)
--
-- Exit status is 1 when anything failed, so this can gate a build.

local ROOT = (function()
	local self = arg and arg[0] or "test/check.lua"
	local dir = self:gsub("[\\/][^\\/]*$", "")
	return (dir == self) and "." or (dir .. "/..")
end)()

package.path = ROOT .. "/test/?.lua;" .. package.path
local luau = require("luau")

local WINDOWS = package.config:sub(1, 1) == "\\"

local function listFiles(dir)
	local out = {}
	local cmd
	if WINDOWS then
		cmd = 'dir /b /s "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul'
	else
		cmd = 'find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null'
	end
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		local clean = line:gsub("\\", "/"):gsub("%s+$", "")
		if clean ~= "" then out[#out + 1] = clean end
	end
	pipe:close()
	table.sort(out)
	return out
end

local function readAll(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local body = fh:read("*a")
	fh:close()
	return body
end

-- Everything a module is allowed to reach without declaring it: the Lua 5.1
-- base library, the Luau additions, the Roblox datatype constructors and
-- globals, and the executor functions (which modules must still feature-detect
-- before calling -- that is a runtime concern, not a name-resolution one).
local ALLOWED = {}
for word in ([[
_G _VERSION assert collectgarbage dofile error getfenv getmetatable ipairs load loadstring next pairs
pcall print rawequal rawget rawlen rawset require select setfenv setmetatable tonumber tostring type
unpack xpcall coroutine debug math os string table utf8 bit32 buffer os newproxy self
task typeof tick time DateTime Enum Instance game workspace script shared plugin
Vector2 Vector3 Vector2int16 Vector3int16 CFrame Color3 Color3uint8 ColorSequence ColorSequenceKeypoint
NumberRange NumberSequence NumberSequenceKeypoint BrickColor UDim UDim2 Rect Region3 Region3int16
Ray Random TweenInfo PhysicalProperties Font FontFace Faces Axes RaycastParams OverlapParams
CatalogSearchParams PathWaypoint TextChatMessage Content SharedTable os
delay spawn wait warn settings stats version elapsedTime printidentity require
getgenv getrenv getfenv setfenv gethui identifyexecutor getexecutorname
readfile writefile appendfile isfile isfolder makefolder listfiles delfile delfolder
setclipboard toclipboard request http_request syn fluxus http WebSocket
getconnections firesignal fireclickdetector firetouchinterest fireproximityprompt
hookfunction hookmetamethod getrawmetatable setreadonly isreadonly cloneref clonefunction
getnilinstances getinstances getscripts getloadedmodules getgc getsenv getcallingscript checkcaller
decompile getscriptclosure getcustomasset setfflag queue_on_teleport setthreadidentity getthreadidentity
crypt base64 lz4 messagebox rconsoleprint rconsoleclear setidentity getidentity
keypress keyrelease mouse1click mouse2click mouse1press mouse1release mousemoveabs mousemoverel
]]):gmatch("[%w_]+") do
	ALLOWED[word] = true
end

local KEYWORDS = {}
for word in ([[
and break do else elseif end false for function if in local nil not or repeat return then true until while
export type continue goto
]]):gmatch("[%w_]+") do
	KEYWORDS[word] = true
end

-- Names the file introduces itself. Approximate on purpose: it over-collects
-- rather than under-collects, so the global report stays quiet enough to read.
local function declaredNames(mask)
	local names = {}
	local function add(list)
		for word in list:gmatch("[%a_][%w_]*") do names[word] = true end
	end
	for decl in mask:gmatch("local%s+([%w_%s,]+)") do add(decl) end
	for decl in mask:gmatch("local%s+function%s+([%w_]+)") do names[decl] = true end
	for decl in mask:gmatch("function%s+([%w_%.%:]+)%s*%(([^%)]*)%)") do add(decl) end
	for params in mask:gmatch("function%s*%(([^%)]*)%)") do add(params) end
	for params in mask:gmatch("function%s*[%w_%.%:]*%s*%(([^%)]*)%)") do add(params) end
	for decl in mask:gmatch("for%s+([%w_%s,]+)%s*=") do add(decl) end
	for decl in mask:gmatch("for%s+([%w_%s,]+)%s+in%s") do add(decl) end
	return names
end

local function suspiciousGlobals(src)
	local mask = luau.mask(src)
	local lineOf = luau.lineIndex(src)
	local declared = declaredNames(mask)
	-- A file may widen the allowlist for itself: the bootstrap legitimately
	-- reaches for names the bundler injects around it.
	for list in src:gmatch("%-%-!globals ([^\n]+)") do
		for word in list:gmatch("[%w_]+") do declared[word] = true end
	end
	local seen, out = {}, {}
	local at = 1
	while true do
		local a, b, word = mask:find("([%a_][%w_]*)", at)
		if not a then break end
		at = b + 1
		local before = mask:sub(a - 1, a - 1)
		-- A digit before the match means this is the tail of a number literal such
		-- as 1e12, not the start of an identifier.
		local isField = (before == "." or before == ":" or before:match("%d") ~= nil)
		-- `name = value` is a table key or an assignment target, not a read, so
		-- it says nothing about whether the name resolves. Whitespace before the
		-- '=' is normal, hence the skip.
		local tail = mask:match("^%s*(=?=?)", b + 1)
		local isKey = tail == "="
		if not isField and not isKey and not KEYWORDS[word] and not declared[word]
			and not ALLOWED[word] and not seen[word] then
			seen[word] = true
			out[#out + 1] = { line = lineOf(a), name = word }
		end
	end
	return out
end

local targets = {}
if arg and arg[1] then
	for i = 1, #arg do targets[#targets + 1] = arg[i] end
else
	targets = { ROOT .. "/src" }
end

local files = {}
-- `dir /b /s` and `find` both answer with absolute paths, so the module id is
-- taken from the text after the scanned folder's own name rather than by
-- subtracting the (possibly relative) base string.
local function addTree(dir)
	local base = dir:gsub("\\", "/"):gsub("/+$", "")
	local tail = base:match("([^/]+)$") or base
	local pattern = ".*/" .. tail:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") .. "/(.+)$"
	for _, path in ipairs(listFiles(base)) do
		local rel = (path:match(pattern) or path:match("([^/]+)$")):gsub("%.lua$", "")
		files[#files + 1] = { path = path, id = rel }
	end
end

for _, target in ipairs(targets) do
	if target:match("%.lua$") then
		files[#files + 1] = { path = target:gsub("\\", "/") }
	else
		addTree(target)
	end
end
if not (arg and arg[1]) then
	local entry = ROOT .. "/init.lua"
	if readAll(entry) then files[#files + 1] = { path = entry:gsub("\\", "/") } end
end

local known, order = {}, {}
for _, item in ipairs(files) do
	if item.id then
		known[item.id] = item.path
		order[#order + 1] = item.id
	end
end

local failures, warnings, checked = 0, 0, 0

print("uai check: " .. #files .. " file(s)")
print(("-"):rep(72))

for _, item in ipairs(files) do
	local path = item.path
	local src = readAll(path)
	local label = path:gsub("^%./", ""):gsub(".*/ProjectUAI/", "")
	if not src then
		print("FAIL " .. label .. "\n       cannot read file")
		failures = failures + 1
	else
		checked = checked + 1
		local fn, problems = luau.load(src, label, { entry = item.id == nil })
		if not fn then
			failures = failures + 1
			print("FAIL " .. label)
			for _, p in ipairs(problems or {}) do
				print(string.format("       %s:%d: %s", label, p.line or 0, p.msg or "?"))
			end
		else
			local notes = {}
			for _, dep in ipairs(luau.requires(src)) do
				if dep.dynamic then
					local prefix = dep.path:gsub("[^/]*$", "")
					local anyUnder = false
					for id in pairs(known) do
						if id:sub(1, #prefix) == prefix then anyUnder = true end
					end
					if not anyUnder then
						notes[#notes + 1] = string.format("%s:%d: require target not found: '%s...' (computed)", label, dep.line, dep.path)
					end
				elseif not known[dep.path] then
					notes[#notes + 1] = string.format("%s:%d: require target not found: '%s'", label, dep.line, dep.path)
				end
			end
			for _, g in ipairs(suspiciousGlobals(src)) do
				notes[#notes + 1] = string.format("%s:%d: undeclared global '%s'", label, g.line, g.name)
			end
			if #notes == 0 then
				print("ok   " .. label)
			else
				local hard = false
				for _, note in ipairs(notes) do
					if note:find("require target not found") then hard = true end
				end
				if hard then failures = failures + 1 else warnings = warnings + #notes end
				print((hard and "FAIL " or "warn ") .. label)
				for _, note in ipairs(notes) do print("       " .. note) end
			end
		end
	end
end

print(("-"):rep(72))
print(string.format("parsed %d, modules %d, failures %d, warnings %d", checked, #order, failures, warnings))
os.exit(failures > 0 and 1 or 0)
