-- Optional native streaming for gateways accepting UAI's chat envelope protocol.
-- This is not the OpenAI Responses or Realtime WebSocket API.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local sse = env.require("net/sse")
	local urls = env.require("net/url")
	local limits = sse.limits
	local M = { available = caps.ws }
	local workers, connections, alive, active = 0, 0, true, {}
	function M.stream(spec)
		if not alive then return nil, "aborted" end
		if not caps.fn.websocket then return nil, caps.reason("ws") end
		local parsedUrl = urls.parse(spec.url)
		if not parsedUrl or (parsedUrl.scheme ~= "ws" and parsedUrl.scheme ~= "wss") then
			return nil, "socket URL must use ws:// or wss://; nothing was dispatched"
		end
		if workers >= 4 or connections >= 4 then return nil, "native socket worker limit reached before dispatch" end
		local socket, messageConn, closeConn, mode
		local frames, bytes, messages = {}, 0, 0
		local accepting, finished, failure, sawFinish, released, dispatched = true, false, nil, false, false, false
		local timeout = tonumber(spec.timeout) or 120
		if timeout ~= timeout then timeout = 120 end
		local deadline = clock.ms() + math.max(1, math.min(300, timeout)) * 1000
		local function aborted()
			if not alive then return true end
			if not spec.aborted then return false end
			local ok, value = pcall(spec.aborted); return not ok or value == true
		end
		local function fail(message)
			failure, finished = message, true
			return false, message
		end
		local function payload(text)
			if finished then return true end
			text = util.trim(text)
			if text == "" then return true end
			if text == "[DONE]" then finished = true; return true end
			if #text > limits.frame or #frames >= limits.chunks then return fail("malformed_stream: socket frame budget exceeded") end
			local decoded = util.decode(text)
			if type(decoded) ~= "table" then return fail("malformed_stream: invalid socket JSON") end
			if decoded.error or decoded.type == "error" then return fail("malformed_stream: gateway reported a stream error") end
			if type(decoded.choices) ~= "table" and type(decoded.usage) ~= "table" then
				return fail("malformed_stream: gateway must return Chat Completions chunks, not Responses or Realtime events")
			end
			local choice = type(decoded.choices) == "table" and decoded.choices[1]
			sawFinish = sawFinish or (type(choice) == "table" and type(choice.finish_reason) == "string" and choice.finish_reason ~= "")
			-- Canonical JSON keeps pretty-printed/multiline frames valid in the
			-- assembled SSE body without adding unprefixed data lines.
			local canonical = util.encode(decoded)
			frames[#frames + 1] = "data: " .. canonical
			if spec.onFrame and not pcall(spec.onFrame, canonical) then return fail("malformed_stream: socket frame callback failed") end
			return true
		end
		local decoder = sse.decoder(function(frame) return payload(frame.data) end)
		local function receive(message)
			if not accepting or finished or aborted() then return end
			messages = messages + 1
			if type(message) ~= "string" or messages > limits.chunks or bytes + #message > limits.body then
				fail("malformed_stream: socket frame budget exceeded"); return
			end
			bytes = bytes + #message
			if message == "" then return end
			if not mode then message = message:gsub("^\239\187\191", "") end
			local clean = util.trim(message)
			if decoder.idle() and (clean:sub(1, 1) == "{" or clean == "[DONE]") then
				payload(clean); return
			end
			mode = "sse"
			-- Older gateways send one complete data: line per socket message,
			-- without SSE delimiters. Continue accepting those at event boundaries.
			local single = message:match("^data: ?([^\r\n]*)$")
			if decoder.idle() and single and (util.trim(single) == "[DONE]" or type(util.decode(single)) == "table") then
				message = message .. "\n\n"
			end
			local ok, why = decoder.push(message)
			if not ok then fail(why) end
		end
		local function close()
			if not released then released = true; connections = math.max(0, connections - 1) end
			accepting = false
			if messageConn then pcall(function() messageConn:Disconnect() end); messageConn = nil end
			if closeConn then pcall(function() closeConn:Disconnect() end); closeConn = nil end
			if socket then local old = socket; socket = nil; pcall(function() old:Close() end) end
		end
		if aborted() then return nil, "aborted" end
		active[close] = true; workers, connections = workers + 1, connections + 1
		clock.spawn(function()
			local ok = pcall(function()
				local envelope = util.encode({ path = spec.path or "/v1/chat/completions", headers = spec.headers or {}, body = spec.body })
				local connected = caps.fn.websocket(spec.url)
				if not accepting or aborted() or clock.ms() >= deadline then
					if connected then pcall(function() connected:Close() end) end
					return
				end
				socket = connected
				if not socket or not socket.OnMessage or not socket.OnClose then error("socket does not expose events", 0) end
				messageConn = socket.OnMessage:Connect(function(message)
					if not pcall(receive, message) then fail("malformed_stream: socket frame processing failed") end
				end)
				closeConn = socket.OnClose:Connect(function()
					if not accepting or finished then return end
					if mode == "sse" then
						local complete, why = decoder.finish()
						if not complete then fail(why); return end
					end
					if not finished and not sawFinish then
						fail(dispatched and "malformed_stream: socket closed before completion" or "socket closed before dispatch")
					end
					finished = true
				end)
				if accepting and not finished and not aborted() then
					-- Once Send is entered, even an exception may follow delivery. No
					-- automatic HTTP fallback is safe from this point onward.
					dispatched = true
					socket:Send(envelope)
				end
			end)
			workers = math.max(0, workers - 1)
			if not ok and accepting then
				fail(dispatched and "deadline: native socket send failed; outcome unknown; automatic retry is disabled"
					or "native socket setup failed before dispatch")
			end
		end)
		while not finished and not aborted() and clock.ms() < deadline do clock.wait(0.05) end
		if aborted() then failure = "aborted"
		elseif not finished then
			failure = dispatched and "deadline: socket outcome is unknown; automatic retry is disabled"
				or "socket connection did not complete before dispatch"
		end
		close(); active[close] = nil
		if failure then return nil, failure end
		if #frames == 0 then return nil, "malformed_stream: socket closed without data" end
		return table.concat(frames, "\n\n") .. "\n\ndata: [DONE]\n\n"
	end
	function M.state() return { workers = workers, connections = connections, alive = alive, limit = 4 } end
	env.require("runtime/dispose").add(function() alive = false; for close in pairs(active) do close() end; active = {} end, "native sockets")
	return M
end
