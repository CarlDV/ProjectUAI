-- Explicit remote calls and replay share typed transport and operation state.
return function(env)
	local refs = env.require("runtime/instance_refs")
	local values = env.require("runtime/values")
	local capture = env.require("runtime/remote_capture")
	local execution = env.require("tools/execution")
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local M = {}
	local serial = 0
	function M.arguments(args)
		if args.args ~= nil and args.arguments ~= nil then return nil, "Provide legacy args or packed arguments, not both" end
		if args.arguments ~= nil then return values.decode(args.arguments) end
		local list = args.args or {}
		if type(list) ~= "table" or not util.isArray(list) or #list > 256 then return nil, "Legacy args must be an array of up to 256 values" end
		local out = { n = #list }
		local examples = { vec3 = Vector3.new(), vector3 = Vector3.new(), vec2 = Vector2.new(), color3 = Color3.new(), cframe = CFrame.new() }
		for i, item in ipairs(list) do
			local prefix, rest; if type(item) == "string" then prefix, rest = item:match("^(%a+):(.*)$"); prefix = prefix and prefix:lower() end
			if prefix == "instance" then local value, why = H.resolve(rest); if not value then return nil, why end; out[i] = value
			elseif prefix == "number" then out[i] = tonumber(rest); if not values.finite(out[i]) then return nil, "Invalid numeric argument" end
			elseif prefix == "string" then out[i] = rest
			elseif prefix and examples[prefix] then local value, why = H.coerce(rest, examples[prefix]); if value == nil then return nil, why end; out[i] = value
			else out[i] = item end
		end
		return out
	end
	function M.validate(remoteId, method, graph)
		local object, why = refs.resolve(remoteId); if not object then return nil, why end
		local expected = object.ClassName == "RemoteFunction" and "InvokeServer" or (object.ClassName == "RemoteEvent" or object.ClassName == "UnreliableRemoteEvent") and "FireServer"
		if not expected or expected ~= method then return nil, "Wrong remote class or method" end
		local args, err = values.decode(graph); if not args then return nil, err end
		return { object = object, args = args }
	end
	function M.call(remoteId, method, graph, options, ctx)
		options = options or {}
		local valid, why = M.validate(remoteId, method, graph); if not valid then return { ok = false, text = why, data = { status = "not_replayable", dispatched = false } } end
		serial = serial + 1; local invocationId = "invoke:" .. refs.epoch .. ":" .. serial
		local token
		local result = execution.runOperation(function()
			local current, err = M.validate(remoteId, method, graph); if not current then error(err, 0) end
			local ruleOk, blocked = pcall(capture.ruleFor, current.object, method); if not ruleOk then blocked = nil end
			local observed, observedToken = pcall(capture.begin, current.object, method, current.args, { origin = options.replayOf and "replay" or "uai", invocationId = invocationId, replayOf = options.replayOf, blocked = blocked })
			if observed then token = observedToken end
			if blocked then error("Blocked by explicit UAI traffic rule " .. blocked, 0) end
			local leave = capture.enterInvocation(current.object, method, invocationId)
			local outcome = values.pack(pcall(function() return current.object[method](current.object, unpack(current.args, 1, current.args.n)) end))
			leave()
			if not outcome[1] then pcall(capture.finish, token, "errored", nil, type(outcome[2]) == "string" and outcome[2] or "Non-string error"); error(outcome[2], 0) end
			local returns = { n = outcome.n - 1 }; for i = 2, outcome.n do returns[i - 1] = outcome[i] end
			pcall(capture.finish, token, method == "FireServer" and "forwarded" or "returned", returns)
			return unpack(returns, 1, returns.n)
		end, { timeout = options.timeout or (method == "InvokeServer" and 8 or execution.DEFAULT_TIMEOUT) }, ctx)
		result.data = result.data or {}; result.data.invocationId, result.data.recordId, result.data.replayOf = invocationId, token and token.id, options.replayOf
		if result.returns then
			result.results = values.snapshot(result.returns)
			result.text = method == "FireServer" and ("Forwarded " .. graph.count .. " argument(s); no server acknowledgement is implied") or ("Returned " .. result.returns.n .. " value(s): " .. H.show(result.returns[1]))
			if not options.rawReturns then result.returns = nil end
		end
		if result.data.status == "outstanding" then pcall(capture.finish, token, "completion_unobserved") end
		return result
	end
	return M
end
