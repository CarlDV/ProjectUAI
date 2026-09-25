-- One explicit capture session shared by native views and agent tools.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local store = env.require("runtime/remote_store")
	local hooks = env.require("runtime/remote_hooks")
	local scan = env.require("runtime/instance_scan")
	local values = env.require("runtime/values")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local util = env.require("runtime/util")
	local M = { changed = env.require("runtime/signal").new("remote-session"), status = "idle", revision = 0,
		ruleRevision = 0, rules = {}, filter = { include = {}, exclude = {} }, view = { y = 0, draft = {}, filter = "" } }
	local connections, incoming, serial, disposed = {}, {}, 0, false
	local durationTick
	local incomingCount, incomingLimit = 0, 2048
	local correlation = setmetatable({}, { __mode = "k" })
	local main = {}; local root, scope, mode, owner = nil, {}, "uai", nil
	local function thread() return coroutine.running() or main end
	local function emit() M.revision = M.revision + 1; M.changed:fire({ status = M.status, revision = M.revision, sessionId = M.sessionId }) end
	local function remote(object) local class = object.ClassName; return class == "RemoteEvent" or class == "UnreliableRemoteEvent" or class == "RemoteFunction" end
	function M.state()
		if M.expiresAt and clock.ms() >= M.expiresAt and (M.status == "running" or M.status == "paused") then
			M.stop("duration reached")
		end
		local result = store.state()
		result.status, result.sessionId, result.revision = M.status, M.sessionId, M.revision
		result.mode, result.backend, result.monitored, result.omitted = mode, M.backend, incomingCount, M.omitted or 0
		result.incomingLimit = incomingLimit
		result.owner, result.selectedId, result.ruleCount, result.ruleRevision = owner, M.selectedId, #M.rules, M.ruleRevision
		result.ownerSessionId, result.reason = M.ownerSessionId, M.reason
		result.coverage, result.filter, result.expiresAt = hooks.coverage(), util.deepCopy(M.filter), M.expiresAt
		result.scopeIds, result.rootId = util.keys(scope), root and refs.id(root)
		return result
	end
	function M.coverageText()
		local current = M.state()
		local text = { "UAI calls: exact arguments and observed returns through managed transport.", "Incoming: " .. current.monitored .. " subscribed events; function callbacks are unavailable." }
		local namecall, direct, outcomes = current.coverage.namecall, current.coverage.direct, current.coverage.invokeOutcomes
		text[#text + 1] = "Namecall: " .. namecall.state .. ". " .. (namecall.reason or "")
		text[#text + 1] = "Direct methods: " .. direct.state .. ". " .. (direct.reason or "")
		text[#text + 1] = "Intercepted Invoke results: " .. outcomes.state .. ". " .. (outcomes.reason or "Original calls are forwarded; completion is not claimed.")
		text[#text + 1] = "Selected mode: " .. mode .. (M.backend and (" / " .. M.backend) or "") .. ". Scope omissions: " .. current.omitted .. "."
		text[#text + 1] = "Routing probes use owned detached objects and do not invoke the predecessor when intercepted. Network behavior is host-dependent; probes do not prove forwarding, errors, yields, or hook coexistence."
		text[#text + 1] = "After Stop: " .. current.coverage.wrapperStatus .. "."
		return table.concat(text, "\n")
	end
	function M.ruleFor(object, method)
		for _, rule in ipairs(M.rules) do if rule.remoteId == refs.id(object, true) and rule.method == method then return rule.id end end
	end
	local function admitted(object, method, direction, origin)
		if M.status ~= "running" then return false end
		if mode == "uai" and origin ~= "uai" and origin ~= "replay" then return false end
		if mode == "incoming" and direction ~= "incoming" then return false end
		if mode == "outgoing" and direction ~= "outgoing" then return false end
		local key = refs.id(object, true)
		if next(scope) and not scope[key] and not (root and object:IsDescendantOf(root)) then return false end
		if root and not next(scope) and object ~= root and not object:IsDescendantOf(root) then return false end
		if M.filter.exclude[key] or (next(M.filter.include) and not M.filter.include[key]) then return false end
		if M.filter.method and M.filter.method ~= method then return false end
		return true
	end
	function M.begin(object, method, packed, options)
		options = options or {}; local direction, origin = options.direction or "outgoing", options.origin or "unknown"
		local ok, allowed = pcall(admitted, object, method, direction, origin)
		if not ok or not allowed then if M.status == "running" then store.count("ignored") end; return nil end
		local info = refs.describe(object, options.hook)
		local caller = { status = "unavailable" }
		if options.hook and caps.fn.getcallingscript then
			local got, script = pcall(caps.fn.getcallingscript)
			if got and typeof(script) == "Instance" then
				local description = refs.describe(script, true)
				caller = { status = "available", scriptId = description.instanceId, name = description.name, className = description.className, runtimeEpoch = refs.epoch, capturedAt = clock.ms(), provenance = "host getcallingscript (unverified attribution)" }
			end
		end
		local outcome = options.blocked and "blocked" or options.unobserved and "completion_unobserved" or direction == "incoming" and "received" or "pending"
		local good, token = pcall(store.begin, { sessionId = M.sessionId, remoteId = info.instanceId, name = util.ellipsis(info.name or "Remote", 160), className = info.className,
			pathAtCapture = info.displayPath, pathProvenance = options.hook and "resolve on inspection" or "capture time", method = method, direction = direction, origin = origin,
			invocationId = options.invocationId, replayOf = options.replayOf, outcome = outcome, caller = caller, ruleId = options.blocked, filterRevision = M.revision }, packed, options)
		if not good then store.count("observerFailed"); return nil end
		if token then token.method = method end
		return token
	end
	function M.finish(token, outcome, result, err) store.finish(token, outcome, result, err) end
	function M.enterInvocation(object, method, invocationId)
		local key = thread(); local previous = correlation[key]
		correlation[key] = { object = object, method = method, invocationId = invocationId }
		return function() correlation[key] = previous end
	end
	local function observe(kind, object, method, packed, blocked)
		if kind == "finish" then
			local token, result = object, method
			if result[1] then local returns = { n = result.n - 1 }; for i = 2, result.n do returns[i - 1] = result[i] end; store.finish(token, token.method == "FireServer" and "forwarded" or "returned", returns)
			else store.finish(token, "errored", nil, type(result[2]) == "string" and result[2] or "Non-string error") end
			return
		end
		local current = correlation[thread()]
		if current and current.object == object and current.method == method then return nil end
		local origin = "hooked_unknown"
		if caps.remoteHooks.attribution == "verified" and caps.fn.checkcaller then local ok, own = pcall(caps.fn.checkcaller); if ok then origin = own and "executor" or "game" end end
		return M.begin(object, method, packed, { hook = true, origin = origin, blocked = blocked,
			unobserved = method == "InvokeServer" and caps.remoteHooks.invokeOutcomes.state ~= "verified" })
	end
	local function disconnect()
		for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
		for _, entry in pairs(incoming) do for _, connection in ipairs(entry) do pcall(function() connection:Disconnect() end) end end
		connections, incoming, incomingCount = {}, {}, 0; hooks.stop()
		for _, rule in ipairs(M.rules) do refs.release(rule) end
		M.rules = {}; M.ruleRevision = M.ruleRevision + 1
	end
	function M.stop(reason)
		if durationTick then durationTick(); durationTick = nil end
		M.status = disposed and "disposed" or reason == "duration reached" and "expired" or "stopped"; M.expiresAt = nil
		disconnect(); store.stopPending(); refs.release(M); root, scope = nil, {}; M.reason = reason; emit(); return M.state()
	end
	local function subscribe(object, sessionId)
		if M.sessionId ~= sessionId or (M.status ~= "starting" and M.status ~= "running" and M.status ~= "paused") then return end
		if not remote(object) or object.ClassName == "RemoteFunction" then return end
		local key = refs.id(object); if incoming[key] then return end
		if incomingCount >= incomingLimit then M.omitted = (M.omitted or 0) + 1; return end
		local ok, connection = pcall(function()
			return object.OnClientEvent:Connect(function(...)
				if M.sessionId ~= sessionId or not incoming[key] then return end
				M.begin(object, "OnClientEvent", values.pack(...), { direction = "incoming", origin = "server" })
			end)
		end)
		if ok and connection then
			local entry = { connection }; incoming[key] = entry; incomingCount = incomingCount + 1
			local function remove()
				if M.sessionId ~= sessionId or incoming[key] ~= entry then return end
				incoming[key] = nil; incomingCount = math.max(0, incomingCount - 1); for _, item in ipairs(entry) do item:Disconnect() end
			end
			pcall(function() entry[#entry + 1] = object.Destroying:Connect(remove) end)
			pcall(function() entry[#entry + 1] = object.AncestryChanged:Connect(function() if object.Parent == nil then remove() end end) end)
		else M.omitted = (M.omitted or 0) + 1 end
	end
	function M.start(options, ctx)
		options = options or {}
		if disposed then return nil, "Capture service is disposed" end
		if options.mode ~= "uai" and options.mode ~= "incoming" and options.mode ~= "outgoing" and options.mode ~= "combined" then return nil, "Choose UAI calls, incoming, outgoing, or combined" end
		if options.persistent and options.duration then return nil, "Choose a duration or persistent capture, not both" end
		if options.duration and (not values.finite(options.duration) or options.duration < 1 or options.duration > 300) then return nil, "Capture duration must be 1–300 seconds" end
		if M.status == "starting" then return nil, "Capture is already starting" end
		local desired = util.encode({ mode = options.mode, ids = options.ids or {}, rootId = options.rootId, backend = options.backend, duration = options.duration, persistent = options.persistent })
		if M.status == "running" or M.status == "paused" then
			if M.configuration == desired then return M.state() end
			if options.expected_revision ~= M.revision then return nil, "stale_revision: a capture is already active" end
		end
		if type(options.ids or {}) ~= "table" or not util.isArray(options.ids or {}) or #(options.ids or {}) > 128 then return nil, "Choose at most 128 exact remotes" end
		local targets, newScope, newRoot = {}, {}, nil
		for _, key in ipairs(options.ids or {}) do local object, why = refs.resolve(key); if not object then return nil, why end; if not remote(object) then return nil, "Capture targets must be remotes" end; if not newScope[key] then targets[#targets + 1], newScope[key] = object, true end end
		if options.rootId then local object, why = refs.resolve(options.rootId); if not object then return nil, why end; newRoot = object end
		if options.mode ~= "uai" and #targets == 0 and not newRoot then return nil, "Choose explicit remotes or a subtree before starting capture" end
		if ctx and ctx.aborted and ctx.aborted() then return nil, "aborted" end
		local replacing = M.status == "running" or M.status == "paused"
		if replacing then M.stop("reconfigured") end
		serial = serial + 1; M.sessionId = "capture:" .. refs.epoch .. ":" .. serial
		local sessionId = M.sessionId
		M.status, M.configuration, M.omitted, M.reason = "starting", desired, 0, nil
		M.backend = (options.mode == "outgoing" or options.mode == "combined") and (options.backend or "namecall") or nil
		M.ownerSessionId = ctx and ctx.sessionId or nil
		mode, owner, scope, root = options.mode, ctx and ctx.origin or "user", newScope, newRoot
		M.filter = { include = {}, exclude = {} }; emit()
		local success, why = pcall(function()
			if mode == "outgoing" or mode == "combined" then
				local installed, err = hooks.start(observe, M.ruleFor, options.backend)
				if not installed then error(err, 0) end
				M.backend = installed.backend
			end
			if mode == "incoming" or mode == "combined" then
				for _, object in ipairs(targets) do subscribe(object, sessionId) end
				if root then
					-- Subscribe to changes before the yielding scan, so a remote created
					-- during startup cannot fall between discovery and live observation.
					connections[#connections + 1] = root.DescendantAdded:Connect(function(object)
						if M.sessionId == sessionId then subscribe(object, sessionId) end
					end)
					connections[#connections + 1] = root.DescendantRemoving:Connect(function(object)
						if M.sessionId ~= sessionId then return end
						if not remote(object) then return end
						local key = refs.id(object, true); local entry = incoming[key]
						if entry then for _, connection in ipairs(entry) do connection:Disconnect() end; incoming[key] = nil; incomingCount = math.max(0, incomingCount - 1) end
					end)
					if remote(root) then subscribe(root, sessionId) end
					local stats = scan.descendants(root, { aborted = function() return M.sessionId ~= sessionId or M.status ~= "starting" or (ctx and ctx.aborted and ctx.aborted()) end }, function(object) subscribe(object, sessionId) end, 20000)
					if M.sessionId ~= sessionId or M.status ~= "starting" then error("aborted", 0) end
					if not stats.complete then M.omitted = M.omitted + 1 end
				end
			end
			if ctx and ctx.aborted and ctx.aborted() then error("aborted", 0) end
		end)
		if M.sessionId ~= sessionId or M.status ~= "starting" then return nil, "aborted: capture startup was stopped or superseded" end
		if not success then
			disconnect(); refs.release(M); M.status = "faulted"
			M.reason = (replacing and "Reconfiguration failed; the previous capture was stopped and all rules were disarmed. " or "Capture failed; all rules were disarmed. ") .. util.ellipsis(tostring(why), 600)
			emit(); return nil, M.reason
		end
		for key in pairs(scope) do refs.pin(key, M) end
		M.status = "running"
		if not options.persistent then
			local duration = options.duration or 30; M.expiresAt = clock.ms() + duration * 1000
			local function expire() if M.sessionId == sessionId and M.expiresAt and clock.ms() >= M.expiresAt and (M.status == "running" or M.status == "paused") then M.stop("duration reached") end end
			durationTick = clock.interval(0.25, expire)
		end
		emit(); return M.state()
	end
	function M.control(action, sessionId, revision)
		if sessionId ~= M.sessionId or revision ~= M.revision then return nil, "stale_revision: refresh capture state" end
		if action == "stop" then return M.stop("explicit stop") end
		if action == "clear" then store.clear(); M.selectedId = nil; emit(); return M.state() end
		if action == "pause" and M.status == "running" then M.status = "paused"
		elseif action == "resume" and M.status == "paused" then M.status = "running"
		else return nil, "That action is unavailable in the current capture state" end
		emit(); return M.state()
	end
	function M.setFilter(filter, revision)
		if revision ~= M.revision then return nil, "stale_revision: refresh capture state" end
		if type(filter) ~= "table" then return nil, "Invalid admission filter" end
		local nextFilter = { include = {}, exclude = {}, method = filter.method }
		if nextFilter.method and nextFilter.method ~= "FireServer" and nextFilter.method ~= "InvokeServer" and nextFilter.method ~= "OnClientEvent" then return nil, "Invalid method filter" end
		for _, kind in ipairs({ "include", "exclude" }) do
			if type(filter[kind] or {}) ~= "table" or #(filter[kind] or {}) > 128 then return nil, "Filter limit is 128 handles" end
			for _, key in ipairs(filter[kind] or {}) do local object, why = refs.resolve(key); if not object then return nil, why end; nextFilter[kind][key] = true end
		end
		M.filter = nextFilter; emit(); return M.state()
	end
	function M.setRule(action, args, origin)
		if args.revision ~= M.revision or args.sessionId ~= M.sessionId then return nil, "stale_revision: refresh capture state" end
		if action == "clear" then for _, item in ipairs(M.rules) do refs.release(item) end; M.rules = {}
		elseif action == "remove" then
			local found = false; for i = #M.rules, 1, -1 do if M.rules[i].id == args.ruleId then refs.release(M.rules[i]); table.remove(M.rules, i); found = true end end
			if not found then return nil, "Rule not found" end
		elseif action == "add" then
			if (M.status ~= "running" and M.status ~= "paused") or (mode ~= "outgoing" and mode ~= "combined") then return nil, "Traffic rules require an active outgoing backend" end
			if #M.rules >= 20 then return nil, "At most 20 traffic rules" end
			local object, why = refs.resolve(args.remoteId); if not object then return nil, why end
			local method = object.ClassName == "RemoteFunction" and "InvokeServer" or "FireServer"
			if not remote(object) or args.method ~= method then return nil, "Invalid remote method" end
			if method == "InvokeServer" and args.policy ~= "local_error" then return nil, "InvokeServer blocking requires explicit local_error policy" end
			serial = serial + 1; local rule = { id = "rule:" .. refs.epoch .. ":" .. serial, remoteId = args.remoteId, method = method, policy = args.policy, origin = origin or "user", ownerSessionId = args.ownerSessionId }
			refs.pin(rule.remoteId, rule); M.rules[#M.rules + 1] = rule
		else return nil, "Unknown rule action" end
		M.ruleRevision = M.ruleRevision + 1; emit(); return M.state()
	end
	function M.revokeAgent(sessionId)
		local changed = false
		for i = #M.rules, 1, -1 do if M.rules[i].origin == "tool" and (not sessionId or M.rules[i].ownerSessionId == sessionId) then refs.release(M.rules[i]); table.remove(M.rules, i); changed = true end end
		if owner == "tool" and (not sessionId or M.ownerSessionId == sessionId) and (M.status == "running" or M.status == "paused" or M.status == "starting") then M.stop("agent authorization revoked")
		elseif changed then M.ruleRevision = M.ruleRevision + 1; emit() end
	end
	function M.adopt() owner = "user"; M.ownerSessionId = nil; emit() end
	function M.select(key)
		if key then local ok, why = store.pin(key); if not ok then return nil, why end end
		if M.selectedId and M.selectedId ~= key then store.unpin(M.selectedId) end
		M.selectedId = key; M.changed:fire({ kind = "selection", recordId = key }); return true
	end
	env.require("runtime/dispose").add(function() disposed = true; M.stop("unload"); M.changed:clear(); correlation = {} end, "native remote capture")
	return M
end
