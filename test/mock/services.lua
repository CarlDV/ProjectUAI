-- Roblox services and the executor globals, offline.
--
-- Everything here is programmable from a test: HTTP answers come from a handler
-- the test installs, the filesystem is a table, tweens apply their goal and fire
-- Completed on the virtual clock, and every request is logged so a test can
-- assert on the exact headers the client sent -- which is the only way to prove
-- the Claude Code identity actually reaches the wire.
local M = {}

function M.build(deps)
	local dt = deps.datatypes
	local json = deps.json
	local sched = deps.scheduler
	local Instance = deps.Instance
	local signal = deps.newSignal

	local services = {}
	local api = {}

	-- HTTP ------------------------------------------------------------------
	local http = {
		log = {},
		queued = {},
		handler = nil,
		requestCount = 0,
	}

	function http.queue(response)
		http.queued[#http.queued + 1] = response
	end

	function http.reset()
		http.log = {}
		http.queued = {}
		http.handler = nil
		http.requestCount = 0
	end

	-- Every transport funnels through here, so the log is complete regardless of
	-- whether the client chose the executor path or HttpService.
	local function dispatch(options, via)
		http.requestCount = http.requestCount + 1
		local entry = {
			via = via,
			url = options.Url or options.url,
			method = (options.Method or options.method or "GET"):upper(),
			headers = options.Headers or options.headers or {},
			body = options.Body or options.body,
			index = http.requestCount,
		}
		http.log[#http.log + 1] = entry

		local response
		if http.handler then
			response = http.handler(entry)
		end
		if not response and #http.queued > 0 then
			response = table.remove(http.queued, 1)
		end
		response = response or { StatusCode = 599, Body = "no mock response queued", Headers = {} }
		-- Every response that came off a wire carries headers, even a bodyless refusal,
		-- and the client reads their absence as "the transport gave up before anything
		-- arrived" rather than as a decision the server made. A fixture that simply
		-- omitted them would exercise that branch by accident, so the default is a
		-- realistic response and a fixture opts out of it deliberately.
		if response.headerless then
			response.Headers = {}
		elseif type(response.Headers) ~= "table" or next(response.Headers) == nil then
			response.Headers = { ["content-type"] = "application/json" }
		end
		entry.response = response
		if response.delay then sched.wait(response.delay) end
		return response
	end
	http.dispatch = dispatch

	services.HttpService = {
		JSONEncode = function(_, value) return json.encode(value) end,
		JSONDecode = function(_, text) return json.decode(text) end,
		GenerateGUID = function(_, braces)
			http.guidCount = (http.guidCount or 0) + 1
			local body = string.format("00000000-0000-4000-8000-%012d", http.guidCount)
			return braces == false and body or ("{" .. body .. "}")
		end,
		UrlEncode = function(_, text)
			return (tostring(text):gsub("[^%w%-_%.~]", function(c)
				return string.format("%%%02X", c:byte())
			end))
		end,
		RequestAsync = function(_, options)
			-- RequestAsync silently drops the headers Roblox reserves; modelling
			-- that is the point, because the client must notice it cannot send a
			-- custom User-Agent through this transport.
			local filtered = {}
			local dropped = {}
			for key, value in pairs(options.Headers or {}) do
				local lower = tostring(key):lower()
				if lower == "user-agent" or lower == "content-length" or lower == "host"
					or lower == "cookie" or lower == "accept-encoding" or lower == "connection" then
					dropped[#dropped + 1] = key
				else
					filtered[key] = value
				end
			end
			local copy = {}
			for key, value in pairs(options) do copy[key] = value end
			copy.Headers = filtered
			local response = dispatch(copy, "RequestAsync")
			http.log[#http.log].droppedHeaders = dropped
			return {
				Success = (response.StatusCode or 0) >= 200 and (response.StatusCode or 0) < 300,
				StatusCode = response.StatusCode,
				StatusMessage = response.StatusMessage or "",
				Headers = response.Headers or {},
				Body = response.Body or "",
			}
		end,
		GetAsync = function(self, url)
			local response = dispatch({ Url = url, Method = "GET" }, "GetAsync")
			return response.Body or ""
		end,
		PostAsync = function(self, url, body)
			local response = dispatch({ Url = url, Method = "POST", Body = body }, "PostAsync")
			return response.Body or ""
		end,
	}
	services.HttpService.HttpEnabled = true

	-- Players ---------------------------------------------------------------
	local players = { GetPlayers = nil }
	local playerList = {}

	local function makePlayer(name, userId)
		local player = Instance.new("Player")
		player.Name = name
		player.DisplayName = name
		player.UserId = userId
		player.Team = nil
		player.PlayerGui = Instance.new("Folder", player)
		player.PlayerGui.Name = "PlayerGui"
		local character = Instance.new("Model")
		character.Name = name
		local root = Instance.new("Part", character)
		root.Name = "HumanoidRootPart"
		root.Position = dt.Vector3.new(0, 5, 0)
		root.CFrame = dt.CFrame.new(0, 5, 0)
		local head = Instance.new("Part", character)
		head.Name = "Head"
		local humanoid = Instance.new("Humanoid", character)
		humanoid.Health = 100
		humanoid.MaxHealth = 100
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.MoveDirection = dt.Vector3.new(0, 0, 0)
		character.PrimaryPart = root
		player.Character = character
		return player
	end

	local localPlayer = makePlayer("TestPlayer", 1)
	playerList[1] = localPlayer

	services.Players = setmetatable({
		LocalPlayer = localPlayer,
		GetPlayers = function() return { unpack(playerList) } end,
		GetPlayerFromCharacter = function(_, character)
			for _, player in ipairs(playerList) do
				if player.Character == character then return player end
			end
			return nil
		end,
		GetNameFromUserIdAsync = function(_, id) return "User" .. tostring(id) end,
		GetUserIdFromNameAsync = function(_, name) return #tostring(name) end,
		GetUserThumbnailAsync = function() return "rbxthumb://type=AvatarHeadShot", true end,
		MaxPlayers = 12,
		GetPropertyChangedSignal = function(self, name)
			local store = rawget(self, "__props")
			if not store then
				store = {}
				rawset(self, "__props", store)
			end
			if not store[name] then store[name] = signal("prop:" .. name) end
			return store[name]
		end,
		addPlayer = function(name, userId)
			local player = makePlayer(name, userId or (#playerList + 1))
			playerList[#playerList + 1] = player
			if services.Players.__signals and services.Players.__signals.PlayerAdded then
				services.Players.__signals.PlayerAdded:Fire(player)
			end
			return player
		end,
	}, {
		-- rawget, or reading __signals when it is still nil re-enters this very
		-- metamethod and recurses until the stack gives out.
		__index = function(self, key)
			local store = rawget(self, "__signals")
			if not store then
				store = {}
				rawset(self, "__signals", store)
			end
			if not store[key] then store[key] = signal(key) end
			return store[key]
		end,
	})
	api.makePlayer = makePlayer
	api.playerList = playerList

	-- Input -----------------------------------------------------------------
	local uis = {
		TouchEnabled = false,
		KeyboardEnabled = true,
		MouseEnabled = true,
		GamepadEnabled = false,
		AccelerometerEnabled = false,
		GyroscopeEnabled = false,
		VREnabled = false,
		OnScreenKeyboardVisible = false,
		OnScreenKeyboardSize = dt.Vector2.new(0, 0),
		OnScreenKeyboardPosition = dt.Vector2.new(0, 0),
		MouseBehavior = nil,
		MouseIconEnabled = true,
		GetFocusedTextBox = function() return nil end,
		-- Modifier state, so a shortcut that reads it can be exercised. Keyed by the
		-- KeyCode's name because that is what a scenario has in hand.
		heldKeys = {},
		IsKeyDown = function(self, keyCode)
			local name = type(keyCode) == "table" and tostring(keyCode.Name) or tostring(keyCode)
			return rawget(self, "heldKeys")[name] == true
		end,
		GetMouseLocation = function() return dt.Vector2.new(400, 300) end,
		GetPlatform = function() return { Name = "Windows" } end,
		GetConnectedGamepads = function() return {} end,
		GetLastInputType = function() return { Name = "MouseMovement" } end,
	}
	uis.GetPropertyChangedSignal = function(self, name)
		local store = rawget(self, "__props")
		if not store then
			store = {}
			rawset(self, "__props", store)
		end
		if not store[name] then store[name] = signal("prop:" .. name) end
		return store[name]
	end
	services.UserInputService = setmetatable(uis, {
		-- rawget, or reading __signals when it is still nil re-enters this very
		-- metamethod and recurses until the stack gives out.
		__index = function(self, key)
			local store = rawget(self, "__signals")
			if not store then
				store = {}
				rawset(self, "__signals", store)
			end
			if not store[key] then store[key] = signal(key) end
			return store[key]
		end,
	})

	-- Tweens ----------------------------------------------------------------
	-- Play applies the goal immediately and fires Completed on the virtual clock.
	-- Assertions then read the settled interface, and code that waits on
	-- Completed still runs.
	local tweens = { played = 0 }
	services.TweenService = {
		Create = function(_, target, info, goals)
			local tween = {
				Instance = target,
				TweenInfo = info,
				Completed = signal("Completed"),
				PlaybackState = "Begin",
			}
			function tween.Play(self)
				tweens.played = tweens.played + 1
				for key, value in pairs(goals) do target[key] = value end
				local duration = (info and info.Time) or 0
				local delayFor = (info and info.DelayTime) or 0
				sched.delay(duration + delayFor, function()
					tween.PlaybackState = "Completed"
					tween.Completed:Fire("Completed")
				end)
				return self
			end
			tween.play = tween.Play
			function tween.Cancel() tween.PlaybackState = "Cancelled" end
			function tween.Pause() tween.PlaybackState = "Paused" end
			return tween
		end,
	}
	api.tweens = tweens

	-- Frame loop -------------------------------------------------------------
	local run = {
		IsClient = function() return true end,
		IsServer = function() return false end,
		IsStudio = function() return false end,
		IsRunning = function() return true end,
		IsRunMode = function() return true end,
		BindToRenderStep = function() end,
		UnbindFromRenderStep = function() end,
	}
	run.GetPropertyChangedSignal = function(self, name)
		local store = rawget(self, "__props")
		if not store then
			store = {}
			rawset(self, "__props", store)
		end
		if not store[name] then store[name] = signal("prop:" .. name) end
		return store[name]
	end
	services.RunService = setmetatable(run, {
		-- rawget, or reading __signals when it is still nil re-enters this very
		-- metamethod and recurses until the stack gives out.
		__index = function(self, key)
			local store = rawget(self, "__signals")
			if not store then
				store = {}
				rawset(self, "__signals", store)
			end
			if not store[key] then store[key] = signal(key) end
			return store[key]
		end,
	})
	-- Drives one frame: the client uses Heartbeat for its own polling.
	function api.frame(delta)
		local step = delta or (1 / 60)
		sched.advance(step)
		services.RunService.Heartbeat:Fire(step)
		services.RunService.RenderStepped:Fire(step)
	end

	-- Chrome, accessibility and platform hints -------------------------------
	local gui = {
		ReducedMotionEnabled = false,
		PreferredTransparency = 1,
		SelectedObject = nil,
		TouchControlsEnabled = true,
		AutoSelectGuiEnabled = true,
		GetGuiInset = function() return dt.Vector2.new(0, 36), dt.Vector2.new(0, 0) end,
		IsTenFootInterface = function() return false end,
		GetEmotesMenuOpen = function() return false end,
		Select = function() end,
	}
	gui.GetPropertyChangedSignal = function(self, name)
		local store = rawget(self, "__props")
		if not store then
			store = {}
			rawset(self, "__props", store)
		end
		if not store[name] then store[name] = signal("prop:" .. name) end
		return store[name]
	end
	services.GuiService = setmetatable(gui, {
		-- rawget, or reading __signals when it is still nil re-enters this very
		-- metamethod and recurses until the stack gives out.
		__index = function(self, key)
			local store = rawget(self, "__signals")
			if not store then
				store = {}
				rawset(self, "__signals", store)
			end
			if not store[key] then store[key] = signal(key) end
			return store[key]
		end,
	})

	-- World ------------------------------------------------------------------
	local camera = Instance.new("Camera")
	camera.Name = "Camera"
	camera.ViewportSize = dt.Vector2.new(1280, 720)
	camera.CFrame = dt.CFrame.new(0, 10, 20)
	camera.CameraSubject = localPlayer.Character and localPlayer.Character:FindFirstChild("Humanoid")
	camera.FieldOfView = 70

	local workspaceInst = Instance.new("Workspace")
	workspaceInst.Name = "Workspace"
	workspaceInst.CurrentCamera = camera
	camera.Parent = workspaceInst
	workspaceInst.Gravity = 196.2
	workspaceInst.DistributedGameTime = 0
	local terrain = Instance.new("Terrain", workspaceInst)
	terrain.Name = "Terrain"
	if localPlayer.Character then localPlayer.Character.Parent = workspaceInst end
	function workspaceInst.Raycast(_, origin, direction, _params)
		-- A flat floor at y = 0 is enough to exercise both the hit and miss paths.
		if direction.Y >= 0 or origin.Y <= 0 then return nil end
		local distance = origin.Y / -direction.Y
		if distance > 1 then return nil end
		return {
			Instance = terrain,
			Position = origin + direction * distance,
			Normal = dt.Vector3.new(0, 1, 0),
			Distance = (direction * distance).Magnitude,
			Material = { Name = "Grass" },
		}
	end
	function workspaceInst.GetPartBoundsInRadius(_, _center, _radius)
		return {}
	end
	function workspaceInst.GetPartsInPart() return {} end
	api.camera = camera
	api.workspace = workspaceInst
	services.Workspace = workspaceInst

	local lighting = Instance.new("Lighting")
	lighting.Name = "Lighting"
	lighting.ClockTime = 14
	lighting.Brightness = 2
	lighting.Ambient = dt.Color3.fromRGB(70, 70, 70)
	lighting.OutdoorAmbient = dt.Color3.fromRGB(70, 70, 70)
	lighting.FogEnd = 100000
	lighting.FogStart = 0
	lighting.GlobalShadows = true
	lighting.TimeOfDay = "14:00:00"
	services.Lighting = lighting

	local coreGui = Instance.new("Folder")
	coreGui.Name = "CoreGui"
	services.CoreGui = coreGui
	api.coreGui = coreGui

	local replicated = Instance.new("Folder")
	replicated.Name = "ReplicatedStorage"
	services.ReplicatedStorage = replicated

	-- Tag registry -----------------------------------------------------------
	local tagged = {}
	services.CollectionService = {
		AddTag = function(_, instance, tag)
			tagged[tag] = tagged[tag] or {}
			tagged[tag][#tagged[tag] + 1] = instance
			instance:AddTag(tag)
		end,
		RemoveTag = function(_, instance, tag)
			instance:RemoveTag(tag)
			for i, item in ipairs(tagged[tag] or {}) do
				if item == instance then table.remove(tagged[tag], i) end
			end
		end,
		HasTag = function(_, instance, tag) return instance:HasTag(tag) end,
		GetTagged = function(_, tag) return { unpack(tagged[tag] or {}) } end,
		GetTags = function(_, instance) return instance:GetTags() end,
		GetAllTags = function()
			local out = {}
			for tag in pairs(tagged) do out[#out + 1] = tag end
			table.sort(out)
			return out
		end,
		GetInstanceAddedSignal = function(_, tag) return signal("added:" .. tag) end,
		GetInstanceRemovedSignal = function(_, tag) return signal("removed:" .. tag) end,
	}

	-- Text measurement -------------------------------------------------------
	-- Monospace approximation. Wrapping code only needs a number that grows with
	-- the string and respects the width cap.
	local function measure(text, size, width)
		local charW = size * 0.55
		local cap = math.max(width or 1e6, charW)
		local longest, lines, current = 0, 1, 0
		for i = 1, #text do
			local c = text:sub(i, i)
			if c == "\n" then
				longest = math.max(longest, current)
				current = 0
				lines = lines + 1
			else
				current = current + charW
				if current > cap then
					longest = math.max(longest, cap)
					current = charW
					lines = lines + 1
				end
			end
		end
		longest = math.max(longest, current)
		return dt.Vector2.new(math.min(longest, cap), lines * size * 1.2)
	end
	services.TextService = {
		GetTextSize = function(_, text, size, _font, frame)
			return measure(tostring(text), size, frame and frame.X or nil)
		end,
		GetTextBoundsAsync = function(_, params)
			return measure(tostring(params.Text or ""), params.Size or 14, params.Width)
		end,
	}
	api.measure = measure

	services.Stats = {
		GetTotalMemoryUsageMb = function() return 512 end,
		DataReceiveKbps = 24,
		DataSendKbps = 8,
		HeartbeatTimeMs = 4,
		PhysicsStepTimeMs = 2,
		InstanceCount = 4200,
	}

	services.StarterGui = {
		SetCore = function() end,
		GetCore = function() return true end,
		SetCoreGuiEnabled = function() end,
		GetCoreGuiEnabled = function() return true end,
	}

	services.TeleportService = {
		Teleport = function() end,
		TeleportToPlaceInstance = function() end,
		GetLocalPlayerTeleportData = function() return nil end,
	}

	services.MarketplaceService = {
		GetProductInfo = function(_, id)
			return { Name = "Mock Place " .. tostring(id), Description = "", Creator = { Name = "Mock" } }
		end,
	}

	services.SoundService = { PlayLocalSound = function() end }
	services.Debris = { AddItem = function() end }
	services.ContentProvider = { PreloadAsync = function() end, RequestQueueSize = 0 }
	services.LogService = { GetLogHistory = function() return {} end }
	services.VirtualInputManager = {
		SendMouseButtonEvent = function() end,
		SendKeyEvent = function() end,
		SendMouseMoveEvent = function() end,
	}
	services.VirtualUser = { Button1Down = function() end, Button1Up = function() end, MoveMouse = function() end }
	services.ContextActionService = { BindAction = function() end, UnbindAction = function() end }
	services.PathfindingService = { CreatePath = function() return { ComputeAsync = function() end, GetWaypoints = function() return {} end } end }
	services.HapticService = { SetMotor = function() end }
	services.LocalizationService = { RobloxLocaleId = "en-us", SystemLocaleId = "en-us" }
	services.PolicyService = {}
	services.InsertService = {}
	services.TextChatService = {}
	services.ScriptContext = {}
	services.Selection = { Get = function() return {} end, Set = function() end }

	-- The DataModel ----------------------------------------------------------
	local gameInst = setmetatable({
		PlaceId = 123456789,
		GameId = 987654321,
		JobId = "mock-job-id",
		CreatorId = 1,
		CreatorType = { Name = "User" },
		PlaceVersion = 42,
		Workspace = workspaceInst,
		Players = services.Players,
		Lighting = lighting,
		IsLoaded = function() return true end,
		GetService = function(_, name)
			if not services[name] then
				services[name] = setmetatable({ __mockService = name }, {
					__index = function(self, key)
						local store = rawget(self, "__signals")
						if not store then
							store = {}
							rawset(self, "__signals", store)
						end
						if not store[key] then store[key] = signal(key) end
						return store[key]
					end,
				})
			end
			return services[name]
		end,
		FindService = function(_, name) return services[name] end,
		HttpGet = function(_, url)
			local response = dispatch({ Url = url, Method = "GET" }, "HttpGet")
			return response.Body or ""
		end,
		HttpGetAsync = function(self, url) return gameInst:HttpGet(url) end,
		GetFullName = function() return "game" end,
		FindFirstChild = function(_, name) return services[name] end,
		WaitForChild = function(_, name) return services[name] end,
		GetChildren = function()
			local out = {}
			for _, service in pairs(services) do
				if type(service) == "table" and service.__class then out[#out + 1] = service end
			end
			return out
		end,
		IsA = function(_, className) return className == "DataModel" or className == "Instance" end,
	}, {
		__index = function(self, key)
			if services[key] then return services[key] end
			local store = rawget(self, "__signals")
			if not store then
				store = {}
				rawset(self, "__signals", store)
			end
			if not store[key] then store[key] = signal(key) end
			return store[key]
		end,
	})
	api.game = gameInst

	api.http = http
	api.services = services
	api.localPlayer = localPlayer
	return api
end

return M
