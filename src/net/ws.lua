-- Optional native streaming for gateways accepting the chat envelope protocol.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local limits = env.require("net/sse").limits
	local M = { available = caps.ws }
	local workers, connections, alive, active = 0, 0, true, {}
	function M.stream(spec)
		if not caps.fn.websocket then return nil, caps.reason("ws") end
		if not alive or workers >= 4 or connections >= 4 then return nil, "deadline: native socket worker limit reached" end
		local socket, messageConn, closeConn
		local frames, bytes = {}, 0
		local accepting, finished, failure, sawFinish, released = true, false, nil, false, false
		local deadline = clock.ms() + math.max(1, math.min(300, tonumber(spec.timeout) or 120)) * 1000
		local function aborted()
			if not alive then return true end
			if not spec.aborted then return false end
			local ok, value = pcall(spec.aborted); return not ok or value == true
		end
		local function close()
			if not released then released = true; connections = math.max(0, connections - 1) end
			accepting = false
			if messageConn then pcall(function() messageConn:Disconnect() end); messageConn = nil end
			if closeConn then pcall(function() closeConn:Disconnect() end); closeConn = nil end
			if socket then local old = socket; socket = nil; pcall(function() old:Close() end) end
		end
		active[close] = true; workers, connections = workers + 1, connections + 1
		clock.spawn(function()
			local ok = pcall(function()
				local connected = caps.fn.websocket(spec.url)
				if not accepting or aborted() or clock.ms() >= deadline then
					if connected then pcall(function() connected:Close() end) end
					return
				end
				socket = connected
				if not socket or not socket.OnMessage or not socket.OnClose then error("socket does not expose events", 0) end
				messageConn = socket.OnMessage:Connect(function(message)
					if not accepting or finished or aborted() then return end
					if type(message) ~= "string" or #message > limits.frame or #frames >= limits.chunks or bytes + #message > limits.body then
						failure, finished = "malformed_stream: socket frame budget exceeded", true; return
					end
					local payload = message:match("^data:%s?(.*)$") or message
					if util.trim(payload) == "[DONE]" then finished = true; return end
					local decoded = util.decode(payload)
					if type(decoded) ~= "table" then failure, finished = "malformed_stream: invalid socket JSON", true; return end
					local choice = type(decoded.choices) == "table" and decoded.choices[1]
					sawFinish = sawFinish or (type(choice) == "table" and choice.finish_reason ~= nil and choice.finish_reason ~= "")
					frames[#frames + 1], bytes = "data: " .. payload, bytes + #message
					if spec.onFrame then
						local callbackOk = pcall(spec.onFrame, payload)
						if not callbackOk then failure, finished = "malformed_stream: socket frame callback failed", true end
					end
				end)
				closeConn = socket.OnClose:Connect(function()
					if not accepting or finished then return end
					finished = true
					if not sawFinish then failure = "malformed_stream: socket closed before completion" end
				end)
				if accepting and not aborted() then
					socket:Send(util.encode({ path = spec.path or "/v1/chat/completions", headers = spec.headers or {}, body = spec.body }))
				end
			end)
			workers = math.max(0, workers - 1)
			if not ok and accepting then failure, finished = "deadline: native socket setup or send failed; outcome unknown; automatic retry is disabled", true end
		end)
		while not finished and not aborted() and clock.ms() < deadline do clock.wait(0.05) end
		if aborted() then failure = "aborted" elseif not finished then failure = "deadline: socket outcome is unknown; automatic retry is disabled" end
		close(); active[close] = nil
		if failure then return nil, failure end
		if #frames == 0 then return nil, "malformed_stream: socket closed without data" end
		return table.concat(frames, "\n\n") .. "\n\ndata: [DONE]\n\n"
	end
	function M.state() return { workers = workers, connections = connections, alive = alive, limit = 4 } end
	env.require("runtime/dispose").add(function() alive = false; for close in pairs(active) do close() end; active = {} end, "native sockets")
	return M
end
