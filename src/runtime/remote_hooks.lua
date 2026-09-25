-- Inert until explicit Start. A reusable forwarding cell preserves other hooks.
-- Invoke outcomes stay unverified until a host-specific yielding fixture passes.
return function(env)
	local caps = env.require("runtime/caps")
	local util = env.require("runtime/util")
	local M = {}
	local lease, retained = nil, false
	local function pack(...) return { n = select("#", ...), ... } end
	function M.coverage()
		return { namecall = util.copy(caps.remoteHooks.namecall), direct = util.copy(caps.remoteHooks.direct),
			invokeOutcomes = util.copy(caps.remoteHooks.invokeOutcomes), incomingCallbacks = "unavailable",
			wrapperStatus = lease and "active observation wrappers" or retained and "retained forwarding wrappers; observation and rules disabled" or "no wrappers installed by this runtime" }
	end
	function M.start(observer, rule, mode)
		if lease then return nil, "Outgoing backend already has an owner" end
		mode = mode or "namecall"
		if mode == "auto" then
			local errors = {}
			for _, backend in ipairs({ "namecall", "direct" }) do
				local available = backend == "namecall" and caps.fn.hookmetamethod and caps.fn.getnamecallmethod or backend == "direct" and caps.fn.hookfunction
				if available then
					local result, why = M.start(observer, rule, backend)
					if result then return result end
					errors[#errors + 1] = backend .. ": " .. tostring(why)
				end
			end
			return nil, #errors > 0 and table.concat(errors, "\n") or "This host cannot intercept outgoing calls. Incoming events are available in the capture mode menu."
		end
		if mode ~= "namecall" and mode ~= "direct" then return nil, "Unknown interception backend" end
		if mode == "namecall" and (not caps.fn.hookmetamethod or not caps.fn.getnamecallmethod) then return nil, "Namecall interception is unavailable; choose Incoming events or UAI calls" end
		if mode == "direct" and not caps.fn.hookfunction then return nil, "Direct-method interception is unavailable" end
		local globals = caps.fn.getgenv and caps.fn.getgenv() or _G
		local broker = rawget(globals, "__UAI_REMOTE_BROKER_V1")
		if broker ~= nil and (type(broker) ~= "table" or broker.version ~= 1) then return nil, "An incompatible UAI interception broker is installed" end
		if not broker then broker = { version = 1, cells = {}, functions = {} }; rawset(globals, "__UAI_REMOTE_BROKER_V1", broker) end
		broker.functions = broker.functions or {}
		for _, cell in pairs(broker.cells) do if cell.observer then return nil, "An existing UAI capture owns the backend" end end
		local acquired = {}
		local function install(key, method, sample)
			local original = mode == "direct" and sample[method] or nil
			local cell = broker.cells[key] or (original and broker.functions[original])
			if not cell then
				cell = { key = key, method = method, observing = setmetatable({}, { __mode = "k" }), mainThread = {} }
				local namecall = mode == "namecall"
				local getMethod = caps.fn.getnamecallmethod
				local function forward(receiver, ...)
					-- Read namecall identity before any observer or engine call.
					local called = namecall and getMethod() or method
					if cell.probe == receiver and called == cell.probeMethod then cell.probeResult = pack(...); return end
					local ownerThread = coroutine.running() or cell.mainThread
					if cell.observing[ownerThread] then return cell.previous(receiver, ...) end
					local observe, block = cell.observer, cell.rule
					if not observe and not block then return cell.previous(receiver, ...) end
					if called ~= "FireServer" and called ~= "InvokeServer" then return cell.previous(receiver, ...) end
					local valid, class = pcall(function() return receiver.ClassName end)
					if not valid or (class ~= "RemoteEvent" and class ~= "UnreliableRemoteEvent" and class ~= "RemoteFunction") then return cell.previous(receiver, ...) end
					if (called == "InvokeServer") ~= (class == "RemoteFunction") then return cell.previous(receiver, ...) end
					local token, blocked
					if block then local ok, result = pcall(block, receiver, called); if ok then blocked = result end end
					if observe then
						cell.observing[ownerThread] = true
						local ok, result = pcall(observe, "begin", receiver, called, pack(...), blocked)
						cell.observing[ownerThread] = nil; if ok then token = result end
					end
					if blocked then
						if called == "InvokeServer" then error("UAI blocked this InvokeServer call by an explicit local-error rule", 0) end
						return
					end
					if called == "InvokeServer" and not cell.invokeVerified then return cell.previous(receiver, ...) end
					-- This wrapper is used for non-yielding events; yielding invokes are
					-- enabled only by a separately verified backend contract.
					local result = pack(pcall(cell.previous, receiver, ...))
					if cell.observer and token then cell.observing[ownerThread] = true; pcall(cell.observer, "finish", token, result); cell.observing[ownerThread] = nil end
					if not result[1] then error(result[2], 0) end
					return unpack(result, 2, result.n)
				end
				local closure = caps.fn.newcclosure and caps.fn.newcclosure(forward) or forward
				local ok, previous
				if mode == "namecall" then ok, previous = pcall(caps.fn.hookmetamethod, game, "__namecall", closure)
				else ok, previous = pcall(caps.fn.hookfunction, sample[method], closure) end
				if not ok or type(previous) ~= "function" then return nil, "Hook installation failed; host error text was omitted" end
				cell.previous = previous; broker.cells[key] = cell
				retained = true
				if original then broker.functions[original] = cell end
			end
			cell.observer, cell.rule = observer, rule
			retained = true
			cell.invokeVerified = caps.remoteHooks.invokeOutcomes.state == "verified"
			local found = false; for _, existing in ipairs(acquired) do if existing == cell then found = true end end
			if not found then acquired[#acquired + 1] = cell end
			return cell
		end
		local ok, why = pcall(function()
			if mode == "namecall" then
				local cell, err = install("namecall"); if not cell then error(err, 0) end
				-- Owned detached probes skip the predecessor when intercepted.
				-- Routing and network behavior still depend on the host.
				for _, class in ipairs({ "RemoteEvent", "UnreliableRemoteEvent", "RemoteFunction" }) do
					local probe = Instance.new(class); cell.probe, cell.probeMethod = probe, class == "RemoteFunction" and "InvokeServer" or "FireServer"
					local tested = pcall(function() if class == "RemoteFunction" then probe:InvokeServer("uai-probe", nil, false, nil) else probe:FireServer("uai-probe", nil, false, nil) end end)
					cell.probe = nil; probe:Destroy()
					local result = cell.probeResult; cell.probeResult = nil
					if not tested or not result or result.n ~= 4 or result[1] ~= "uai-probe" or result[3] ~= false then error("Namecall fixture failed for " .. class, 0) end
				end
			else
				for _, class in ipairs({ "RemoteEvent", "UnreliableRemoteEvent", "RemoteFunction" }) do
					local sample = Instance.new(class); local method = class == "RemoteFunction" and "InvokeServer" or "FireServer"
					local cell, err = install(class .. ":" .. method, method, sample)
					if not cell then sample:Destroy(); error(err, 0) end
					do
						cell.probe, cell.probeMethod = sample, method; local tested = pcall(function() sample[method](sample, "uai-probe", nil, false, nil) end); cell.probe = nil
						local result = cell.probeResult; cell.probeResult = nil
						if not tested or not result or result.n ~= 4 or result[1] ~= "uai-probe" or result[3] ~= false then sample:Destroy(); error("Direct-method fixture failed", 0) end
					end
					sample:Destroy()
				end
			end
		end)
		if not ok then for _, cell in ipairs(acquired) do cell.observer, cell.rule, cell.probe = nil, nil, nil end; caps.remoteHooks[mode] = { state = "failed", reason = tostring(why) }; return nil, tostring(why) end
		lease = acquired; caps.remoteHooks[mode] = { state = "verified", routing = "verified", forwarding = "available_unverified", reason = "Owned event/unreliable/function argument routing passed; native forwarding and Invoke outcomes need separate host verification" }
		local coverage = M.coverage(); coverage.backend = mode; return coverage
	end
	function M.stop()
		if lease then for _, cell in ipairs(lease) do cell.observer, cell.rule, cell.probe = nil, nil, nil end end
		lease = nil
		-- No generic restore API proves ownership. Reuse the transparent cells on
		-- the next Start instead of overwriting hooks installed after UAI.
	end
	env.require("runtime/dispose").add(M.stop, "outgoing interception lease")
	return M
end
