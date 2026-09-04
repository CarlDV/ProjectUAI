-- Optional real streaming over a WebSocket.
--
-- This is opt-in and only useful with a gateway that speaks the small envelope
-- protocol below, because no standard OpenAI-compatible endpoint accepts chat
-- completions over a socket. It exists because it is the only way to get genuine
-- token-by-token output in Roblox: every HTTP transport available here returns a
-- finished body, so `stream = true` over HTTP can never arrive incrementally.
--
-- Envelope sent as the first (and only) client frame:
--     { "path": "/v1/chat/completions", "headers": { ... }, "body": { ... } }
-- Frames received are raw SSE `data:` payloads, or bare JSON chunks. `[DONE]`
-- ends the exchange, as does the socket closing.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")

	local M = {}

	M.available = caps.ws

	-- Returns the concatenated SSE body so the caller can hand it to net/sse,
	-- exactly as it would an HTTP response. onFrame is called per chunk for live
	-- rendering.
	function M.stream(spec)
		if not caps.fn.websocket then return nil, caps.reason("ws") end

		local ok, socket = pcall(caps.fn.websocket, spec.url)
		if not ok or not socket then return nil, "websocket connect failed: " .. tostring(socket) end

		local frames = {}
		local finished, failure = false, nil

		local messageConn = socket.OnMessage and socket.OnMessage:Connect(function(message)
			local text = tostring(message or "")
			-- A frame may be a raw payload or a full SSE line; strip the prefix so
			-- both shapes reach the parser identically.
			local payload = text:match("^data:%s?(.*)$") or text
			if util.trim(payload) == "[DONE]" then
				finished = true
				return
			end
			frames[#frames + 1] = "data: " .. payload
			if spec.onFrame then
				local okFrame, err = pcall(spec.onFrame, payload)
				if not okFrame then log.warn("ws", "frame handler failed", err) end
			end
		end)

		local closeConn = socket.OnClose and socket.OnClose:Connect(function()
			finished = true
		end)

		local sent, sendErr = pcall(function()
			socket:Send(util.encode({
				path = spec.path or "/v1/chat/completions",
				headers = spec.headers or {},
				body = spec.body,
			}))
		end)
		if not sent then
			pcall(function() socket:Close() end)
			return nil, "websocket send failed: " .. tostring(sendErr)
		end

		local waited = 0
		local limit = spec.timeout or 120
		while not finished and waited < limit do
			if spec.aborted and spec.aborted() then
				failure = "aborted"
				break
			end
			waited = waited + (clock.wait(0.05) or 0.05)
		end

		if messageConn then pcall(function() messageConn:Disconnect() end) end
		if closeConn then pcall(function() closeConn:Disconnect() end) end
		pcall(function() socket:Close() end)

		if failure then return nil, failure end
		if not finished and waited >= limit then
			return nil, "websocket timed out after " .. tostring(limit) .. "s"
		end
		if #frames == 0 then return nil, "websocket closed without data" end
		return table.concat(frames, "\n\n") .. "\n\ndata: [DONE]\n\n"
	end

	return M
end
