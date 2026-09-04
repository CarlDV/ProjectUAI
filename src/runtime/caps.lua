-- What this host can actually do.
--
-- Every optional capability is probed exactly once, here, and the rest of the
-- project asks this module rather than testing for a global inline. That matters
-- for more than tidiness: the same script has to run under an executor with a
-- full filesystem, under one with only HTTP, and inside a plain client with
-- neither, and each of those has to degrade in a way the interface can explain
-- to the user instead of erroring.
return function(env)
	local M = {}

	local function callable(value)
		return type(value) == "function" and value or nil
	end

	-- Executors disagree on where the HTTP function lives. Order matters only in
	-- that the bare global is the modern spelling.
	local function findRequest()
		local candidates = {
			{ name = "request", fn = callable(request) },
			{ name = "http_request", fn = callable(http_request) },
			{ name = "syn.request", fn = type(syn) == "table" and callable(syn.request) or nil },
			{ name = "http.request", fn = type(http) == "table" and callable(http.request) or nil },
			{ name = "fluxus.request", fn = type(fluxus) == "table" and callable(fluxus.request) or nil },
		}
		for _, candidate in ipairs(candidates) do
			if candidate.fn then return candidate.fn, candidate.name end
		end
		return nil, nil
	end

	local function findClipboard()
		return callable(setclipboard)
			or callable(toclipboard)
			or (type(syn) == "table" and callable(syn.write_clipboard))
			or nil
	end

	local requestFn, requestName = findRequest()

	M.fn = {
		request = requestFn,
		readfile = callable(readfile),
		writefile = callable(writefile),
		appendfile = callable(appendfile),
		isfile = callable(isfile),
		isfolder = callable(isfolder),
		makefolder = callable(makefolder),
		listfiles = callable(listfiles),
		delfile = callable(delfile),
		delfolder = callable(delfolder),
		loadstring = callable(loadstring) or (callable(getgenv) and callable(getgenv().loadstring)) or nil,
		getgenv = callable(getgenv),
		gethui = callable(gethui),
		clipboard = findClipboard(),
		identify = callable(identifyexecutor) or callable(getexecutorname),
		websocket = (type(WebSocket) == "table" and callable(WebSocket.connect)) or nil,
		getconnections = callable(getconnections),
		firesignal = callable(firesignal),
		fireclickdetector = callable(fireclickdetector),
		firetouchinterest = callable(firetouchinterest),
		getnilinstances = callable(getnilinstances),
		getinstances = callable(getinstances),
		getscripts = callable(getscripts),
		decompile = callable(decompile),
		cloneref = callable(cloneref),
		queueTeleport = callable(queue_on_teleport),
		setfflag = callable(setfflag),
		customasset = callable(getcustomasset),
	}

	M.requestName = requestName

	-- HTTP -------------------------------------------------------------------
	-- The executor path is preferred for one specific reason: RequestAsync
	-- refuses to send a User-Agent (along with Cookie, Host and Content-Length),
	-- so it physically cannot carry the Claude Code identity. When that is the
	-- only transport available the client says so rather than silently sending
	-- Roblox's own agent string.
	if M.fn.request then
		M.http = "executor"
		M.uaSupported = true
	else
		local ok = pcall(function()
			return env.services.HttpService ~= nil
		end)
		M.http = ok and "roblox" or "none"
		M.uaSupported = false
	end

	M.fs = (M.fn.writefile ~= nil and M.fn.readfile ~= nil)
	M.exec = M.fn.loadstring ~= nil
	M.ws = M.fn.websocket ~= nil
	M.clipboard = M.fn.clipboard ~= nil
	M.hui = M.fn.gethui ~= nil
	M.hooks = M.fn.getconnections ~= nil
	M.sourceRead = M.fn.decompile ~= nil or M.fn.getscripts ~= nil

	M.executor = "unknown"
	if M.fn.identify then
		local ok, name = pcall(M.fn.identify)
		if ok and type(name) == "string" and name ~= "" then M.executor = name end
	end

	do
		local ok, isStudio = pcall(function() return env.services.RunService:IsStudio() end)
		M.studio = ok and isStudio or false
	end

	do
		local ok, tenFoot = pcall(function() return env.services.GuiService:IsTenFootInterface() end)
		M.console = ok and tenFoot or false
	end

	M.available = {
		http = M.http ~= "none",
		fs = M.fs,
		exec = M.exec,
		ws = M.ws,
		clipboard = M.clipboard,
		hooks = M.hooks,
		["ua"] = M.uaSupported,
	}

	-- Tools declare `needs = { "fs" }`; the registry checks the answer here
	-- before dispatch so an unavailable tool reports a clear reason to the model
	-- instead of erroring somewhere inside a nil call.
	function M.has(key)
		return M.available[key] == true
	end

	M.MISSING = {
		http = "no HTTP transport is available in this host",
		fs = "this host has no filesystem functions (writefile/readfile)",
		exec = "this host cannot compile code (loadstring is unavailable)",
		ws = "this host has no WebSocket support",
		clipboard = "this host has no clipboard function",
		hooks = "this host does not expose signal introspection (getconnections)",
		ua = "this host cannot set a custom User-Agent",
	}

	function M.reason(key)
		return M.MISSING[key] or ("capability '" .. tostring(key) .. "' is unavailable")
	end

	function M.summary()
		local parts = {
			"transport " .. M.http .. (M.requestName and (" (" .. M.requestName .. ")") or ""),
			"ua " .. (M.uaSupported and "yes" or "no"),
			"fs " .. (M.fs and "yes" or "no"),
			"exec " .. (M.exec and "yes" or "no"),
		}
		if M.executor ~= "unknown" then table.insert(parts, 1, M.executor) end
		return table.concat(parts, " | ")
	end

	return M
end
