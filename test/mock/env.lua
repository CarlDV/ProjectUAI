-- Assembles the offline client environment: the global sandbox the bundle runs
-- inside, an in-memory filesystem, and the executor functions.
--
-- The bundle is loaded exactly as a game would load it -- one chunk, through the
-- same bootstrap -- so what the scenarios exercise is the shipped artifact rather
-- than a rearranged copy of it.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path

local luau = require("luau")
local json = require("json")
local scheduler = require("scheduler")
local datatypes = require("datatypes")
local instanceMock = require("instance")
local servicesMock = require("services")

local M = {}

function M.new(opts)
	opts = opts or {}
	local sched = scheduler.new()
	local dt = datatypes
	local Instance, instanceState = instanceMock.build(dt)
	local Enum, unknownEnums = datatypes.makeEnum()

	local api = servicesMock.build({
		datatypes = dt,
		json = json,
		scheduler = sched,
		Instance = Instance,
		newSignal = instanceMock.newSignal,
	})

	-- An in-memory filesystem. Paths are kept exactly as the client writes them so a
	-- test can assert on the layout, not just the contents.
	local files = {}
	local folders = { [""] = true }

	local function normalise(path)
		return tostring(path):gsub("\\", "/"):gsub("^/+", "")
	end

	local console = { out = {}, warnings = {} }

	local BASE_EPOCH = 1767225600000

	local sandbox
	sandbox = {
		game = api.game,
		workspace = api.workspace,
		Instance = Instance,
		Enum = Enum,
		task = sched.api,
		tick = function() return sched.now end,
		time = function() return sched.now end,
		wait = function(seconds) return sched.wait(seconds) end,
		typeof = function(value)
			if type(value) == "table" then
				local meta = getmetatable(value)
				if type(meta) == "table" and meta.__type then return meta.__type end
				if type(meta) == "table" and type(meta.__index) == "table" and meta.__index.__type then
					return meta.__index.__type
				end
			end
			return type(value)
		end,
		print = function(...)
			local parts = {}
			for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
			console.out[#console.out + 1] = table.concat(parts, "\t")
		end,
		warn = function(...)
			local parts = {}
			for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
			console.warnings[#console.warnings + 1] = table.concat(parts, "\t")
		end,
		DateTime = {
			now = function()
				return {
					UnixTimestampMillis = BASE_EPOCH + math.floor(sched.now * 1000),
					UnixTimestamp = math.floor(BASE_EPOCH / 1000 + sched.now),
				}
			end,
			fromUnixTimestamp = function(seconds)
				return {
					UnixTimestamp = seconds,
					UnixTimestampMillis = seconds * 1000,
					FormatLocalTime = function(_, _pattern) return "00:00:00" end,
					FormatUniversalTime = function(_, _pattern) return "00:00:00" end,
				}
			end,
		},
	}

	for _, name in ipairs({
		"Vector2", "Vector3", "UDim", "UDim2", "Color3", "CFrame", "TweenInfo",
		"Rect", "NumberRange", "NumberSequence", "NumberSequenceKeypoint",
		"ColorSequence", "ColorSequenceKeypoint", "Font", "Random",
	}) do
		sandbox[name] = dt[name]
	end

	sandbox.RaycastParams = {
		new = function()
			return setmetatable({ FilterDescendantsInstances = {}, FilterType = nil, IgnoreWater = false }, {
				__type = "RaycastParams",
			})
		end,
	}
	sandbox.OverlapParams = sandbox.RaycastParams
	sandbox.BrickColor = { new = function(name) return setmetatable({ Name = tostring(name) }, { __type = "BrickColor" }) end }

	-- Executor surface. Absent entirely when the scenario asks for a vanilla
	-- client, which is what exercises the degraded paths.
	if opts.executor ~= false then
		sandbox.identifyexecutor = function() return "OfflineHarness 1.0" end
		sandbox.getgenv = function() return sandbox end
		sandbox.gethui = function() return api.coreGui end

		sandbox.request = function(options)
			local response = api.http.dispatch(options, "executor")
			return {
				StatusCode = response.StatusCode,
				Body = response.Body,
				Headers = response.Headers or {},
				Success = (response.StatusCode or 0) < 400,
			}
		end

		sandbox.writefile = function(path, content)
			files[normalise(path)] = tostring(content)
		end
		sandbox.appendfile = function(path, content)
			local key = normalise(path)
			files[key] = (files[key] or "") .. tostring(content)
		end
		sandbox.readfile = function(path)
			local key = normalise(path)
			if files[key] == nil then error("no such file: " .. key, 0) end
			return files[key]
		end
		sandbox.isfile = function(path) return files[normalise(path)] ~= nil end
		sandbox.isfolder = function(path) return folders[normalise(path)] == true end
		sandbox.makefolder = function(path) folders[normalise(path)] = true end
		sandbox.delfile = function(path) files[normalise(path)] = nil end
		sandbox.delfolder = function(path)
			local prefix = normalise(path) .. "/"
			folders[normalise(path)] = nil
			for key in pairs(files) do
				if key:sub(1, #prefix) == prefix then files[key] = nil end
			end
		end
		sandbox.listfiles = function(path)
			local prefix = normalise(path)
			if prefix ~= "" then prefix = prefix .. "/" end
			local out = {}
			for key in pairs(files) do
				if key:sub(1, #prefix) == prefix then out[#out + 1] = key end
			end
			for key in pairs(folders) do
				if key ~= "" and key:sub(1, #prefix) == prefix and key ~= prefix:sub(1, -2) then
					out[#out + 1] = key
				end
			end
			table.sort(out)
			return out
		end

		sandbox.setclipboard = function(text)
			sandbox.__clipboard = tostring(text)
		end

		-- loadstring has to compile Luau, which offline means going back through the
		-- same transform the harness itself uses.
		sandbox.loadstring = function(source, chunkName)
			local fn, problems = luau.load(source, chunkName or "runtime", { entry = true })
			if not fn then
				local first = problems and problems[1]
				return nil, first and (tostring(first.line) .. ": " .. tostring(first.msg)) or "compile failed"
			end
			setfenv(fn, sandbox)
			return fn
		end
	end

	-- Anything not named above falls through to the real standard library. Nothing
	-- else does: a misspelled Roblox global stays nil and fails loudly.
	setmetatable(sandbox, {
		__index = function(_, key)
			return _G[key]
		end,
	})
	sandbox._G = sandbox

	instanceState.viewport = api.camera.ViewportSize

	local harness = {
		sandbox = sandbox,
		sched = sched,
		http = api.http,
		services = api.services,
		game = api.game,
		workspace = api.workspace,
		camera = api.camera,
		coreGui = api.coreGui,
		players = api.playerList,
		localPlayer = api.localPlayer,
		Instance = Instance,
		instanceState = instanceState,
		files = files,
		folders = folders,
		console = console,
		unknownEnums = unknownEnums,
		dt = dt,
		json = json,
		frame = api.frame,
		makePlayer = api.makePlayer,
	}

	-- Loads dist/uai.lua and returns whatever the bootstrap returned.
	function harness.boot(bundlePath)
		local path = bundlePath or "dist/uai.lua"
		local file = io.open(path, "rb")
		if not file then return nil, "cannot read " .. path end
		local source = file:read("*a")
		file:close()

		local fn, problems = luau.load(source, path, { entry = true })
		if not fn then
			local lines = {}
			for _, problem in ipairs(problems or {}) do
				lines[#lines + 1] = string.format("%s:%d: %s", path, problem.line or 0, problem.msg or "?")
			end
			return nil, table.concat(lines, "\n")
		end

		setfenv(fn, sandbox)
		local ok, result = pcall(fn, opts.context)
		if not ok then return nil, tostring(result) end
		harness.handle = result
		return result
	end

	-- Drives the frame loop until nothing is pending, so animations settle and any
	-- spawned thread has run.
	function harness.settle(seconds)
		local budget = seconds or 2
		local spent = 0
		while spent < budget do
			api.frame(1 / 30)
			spent = spent + (1 / 30)
			if sched.pending() == 0 then break end
		end
		return sched.pending()
	end

	function harness.errors()
		return sched.errors
	end

	-- Walks the mounted interface. Used to assert that a surface exists and to dump
	-- it when one does not.
	function harness.screen()
		for _, child in ipairs(api.coreGui:GetChildren()) do
			if child.ClassName == "ScreenGui" then return child end
		end
		return nil
	end

	function harness.find(root, predicate)
		local out = {}
		for _, node in ipairs((root or harness.screen()):GetDescendants()) do
			if predicate(node) then out[#out + 1] = node end
		end
		return out
	end

	function harness.textOf(root)
		local parts = {}
		for _, node in ipairs((root or harness.screen()):GetDescendants()) do
			local text = node.__props and node.__props.Text
			if type(text) == "string" and text ~= "" then parts[#parts + 1] = text end
		end
		return table.concat(parts, "\n")
	end

	function harness.dump(root)
		return instanceMock.dump(root or harness.screen(), { props = { "Text", "Visible" } })
	end

	-- Input simulation. Enough of an InputObject for the drag, resize and press
	-- paths: a position, a type, a state, and the Changed signal the drag handlers
	-- listen to for the release.
	local function inputObject(kind, x, y)
		local input = {
			UserInputType = kind,
			UserInputState = Enum.UserInputState.Begin,
			Position = dt.Vector3.new(x or 0, y or 0, 0),
			Delta = dt.Vector3.new(0, 0, 0),
			KeyCode = Enum.KeyCode.Unknown,
		}
		input.Changed = instanceMock.newSignal("Changed")
		return input
	end

	-- Changes the viewport the way a rotation or a window resize would, and tells
	-- both the camera and the geometry resolver about it.
	function harness.setViewport(width, height)
		api.camera.ViewportSize = dt.Vector2.new(width, height)
		instanceState.viewport = api.camera.ViewportSize
		api.camera:GetPropertyChangedSignal("ViewportSize"):Fire()
		harness.settle(1.5)
	end

	function harness.click(gui)
		if not gui then return false, "no instance" end
		if gui.__signals and gui.__signals.Activated then
			gui.__signals.Activated:Fire()
		elseif gui.Activated then
			gui.Activated:Fire()
		end
		if gui.__signals and gui.__signals.MouseButton1Click then
			gui.__signals.MouseButton1Click:Fire()
		end
		harness.settle(0.6)
		return true
	end

	-- Press, move, release: the sequence a drag or a resize is made of. The move is
	-- fired on UserInputService, which is where the handlers listen for it.
	function harness.drag(gui, fromX, fromY, toX, toY, kind)
		local inputType = kind or Enum.UserInputType.MouseButton1
		local input = inputObject(inputType, fromX, fromY)
		gui.InputBegan:Fire(input)

		local move = inputObject(Enum.UserInputType.MouseMovement, toX, toY)
		api.services.UserInputService.InputChanged:Fire(move)
		harness.settle(0.2)

		input.UserInputState = Enum.UserInputState.End
		input.Changed:Fire()
		if gui.__signals and gui.__signals.InputEnded then
			gui.__signals.InputEnded:Fire(input)
		end
		harness.settle(0.6)
	end

	function harness.type(field, text)
		field.Text = tostring(text)
		harness.settle(0.1)
		if field.__signals and field.__signals.FocusLost then
			field.__signals.FocusLost:Fire(true)
		end
		harness.settle(0.4)
	end

	-- Finds one descendant by name, which is how the scenarios reach a control
	-- without knowing the tree shape.
	function harness.byName(name, root)
		for _, node in ipairs((root or harness.screen()):GetDescendants()) do
			if node.__props.Name == name then return node end
		end
		return nil
	end

	function harness.allByName(name, root)
		local out = {}
		for _, node in ipairs((root or harness.screen()):GetDescendants()) do
			if node.__props.Name == name then out[#out + 1] = node end
		end
		return out
	end

	return harness
end

return M
