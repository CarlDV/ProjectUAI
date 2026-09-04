-- The OpenAI chat-completions adapter.
--
-- One request shape in, one normalised result out. Everything vendor-specific
-- lives here: auth style, the streaming decision, error extraction, and the
-- parameter repairs that make the same call work across a dozen gateways that all
-- claim to be OpenAI-compatible and none of which quite are.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local http = env.require("net/http")
	local sse = env.require("net/sse")
	local registry = env.require("provider/registry")

	local M = {}

	-- Messages are rewritten into the wire shape rather than passed through, so a
	-- field the context store finds useful (reasoning text, timing, ids) cannot
	-- leak into a payload and trip a gateway that rejects unknown fields.
	function M.wireMessages(messages)
		local out = {}
		for _, message in ipairs(messages or {}) do
			local entry = { role = message.role }
			if message.role == "tool" then
				entry.tool_call_id = message.tool_call_id
				entry.content = tostring(message.content or "")
			elseif message.toolCalls and #message.toolCalls > 0 then
				-- An assistant turn that called tools must replay those calls
				-- verbatim, and content may legitimately be an empty string.
				entry.content = message.content or ""
				entry.tool_calls = {}
				for _, call in ipairs(message.toolCalls) do
					entry.tool_calls[#entry.tool_calls + 1] = {
						id = call.id,
						type = "function",
						["function"] = {
							name = call["function"] and call["function"].name or call.name,
							arguments = call["function"] and call["function"].arguments or call.arguments or "{}",
						},
					}
				end
			else
				entry.content = tostring(message.content or "")
			end
			out[#out + 1] = entry
		end
		return out
	end

	function M.buildBody(record, request)
		local body = {
			messages = M.wireMessages(request.messages),
		}

		-- Azure takes the model from the deployment in the URL and rejects the
		-- field; everyone else requires it.
		if record.preset ~= "azure" and util.trim(record.model) ~= "" then
			body.model = record.model
		end

		if request.tools and #request.tools > 0 then
			body.tools = request.tools
			body.tool_choice = request.toolChoice or "auto"
			if request.parallelToolCalls ~= false then
				body.parallel_tool_calls = true
			end
		end

		local temperature = request.temperature
		if temperature == nil then temperature = config.get("agent.temperature", 0.4) end
		if temperature then body.temperature = temperature end

		local maxTokens = request.maxTokens or config.get("agent.maxTokens", 4096)
		if maxTokens and maxTokens > 0 then body.max_tokens = maxTokens end

		if request.stream then
			body.stream = true
			body.stream_options = { include_usage = true }
		end

		for key, value in pairs(record.params or {}) do body[key] = value end
		for key, value in pairs(request.extra or {}) do body[key] = value end
		return body
	end

	-- Error text, in the order gateways actually use. A 401 with an empty body is
	-- common enough that the status alone has to produce something readable.
	local STATUS_TEXT = {
		[400] = "the provider rejected the request",
		[401] = "the API key was rejected",
		[402] = "the account is out of credit",
		[403] = "the provider refused the request -- the key may lack access to it, or an edge filter blocked the call",
		[404] = "endpoint or model not found -- check the base URL and model name",
		[413] = "the request was too large",
		[422] = "the provider could not process the request",
		[429] = "rate limited",
		[500] = "the provider had an internal error",
		[502] = "the provider gateway is unavailable",
		[503] = "the provider is overloaded",
		[529] = "the provider is overloaded",
	}

	function M.errorText(res, err)
		if err and not res then return tostring(err) end
		local status = res and res.status or 0
		local decoded = res and util.decode(res.body) or nil
		local message
		if type(decoded) == "table" then
			if type(decoded.error) == "table" then
				message = decoded.error.message or decoded.error.type or decoded.error.code
			elseif type(decoded.error) == "string" then
				message = decoded.error
			elseif type(decoded.message) == "string" then
				message = decoded.message
			elseif type(decoded.detail) == "string" then
				message = decoded.detail
			end
		end
		if not message or message == "" then
			local raw = res and util.trim(res.body) or ""
			if raw ~= "" and #raw < 400 and not raw:find("^<") then
				message = raw
			end
		end
		local prefix = STATUS_TEXT[status]
		-- A refusal that carries no body at all is worth naming as such. It usually
		-- means the call never reached the API, so nothing about the key or the model
		-- accounts for it, and the answer is in the response headers the Requests view
		-- now keeps rather than anywhere in this string.
		if (not message or message == "") and res and util.trim(res.body or "") == "" then
			return string.format("%s (%d), and the response had no body -- see the Requests view",
				prefix or "the request was refused", status)
		end
		if message and prefix then return string.format("%s (%d): %s", prefix, status, message) end
		if message then return string.format("%s (%d)", message, status) end
		if prefix then return string.format("%s (%d)", prefix, status) end
		return string.format("request failed with status %d", status)
	end

	-- Gateways reject different subsets of the payload. Rather than maintaining a
	-- per-vendor allowlist that goes stale, a 400 whose text names a field is
	-- repaired once and retried -- and the repair is remembered on the record so
	-- the next turn does not pay for it again.
	local REPAIRS = {
		{
			match = "max_completion_tokens",
			apply = function(body)
				if body.max_tokens then
					body.max_completion_tokens = body.max_tokens
					body.max_tokens = nil
					return "renamed max_tokens to max_completion_tokens"
				end
			end,
		},
		{
			match = "temperature",
			apply = function(body)
				if body.temperature ~= nil then
					body.temperature = nil
					return "dropped temperature"
				end
			end,
		},
		{
			match = "parallel_tool_calls",
			apply = function(body)
				if body.parallel_tool_calls ~= nil then
					body.parallel_tool_calls = nil
					return "dropped parallel_tool_calls"
				end
			end,
		},
		{
			match = "stream_options",
			apply = function(body)
				if body.stream_options ~= nil then
					body.stream_options = nil
					return "dropped stream_options"
				end
			end,
		},
		{
			match = "tool_choice",
			apply = function(body)
				if body.tool_choice ~= nil then
					body.tool_choice = nil
					return "dropped tool_choice"
				end
			end,
		},
	}

	local function repair(body, message)
		local lowered = tostring(message or ""):lower()
		for _, entry in ipairs(REPAIRS) do
			if lowered:find(entry.match, 1, true) then
				local note = entry.apply(body)
				if note then return note, entry.match end
			end
		end
		return nil
	end

	local function applyRemembered(record, body)
		for _, key in ipairs(record.repairs or {}) do
			for _, entry in ipairs(REPAIRS) do
				if entry.match == key then entry.apply(body) end
			end
		end
	end

	local function remember(record, key)
		record.repairs = record.repairs or {}
		for _, existing in ipairs(record.repairs) do
			if existing == key then return end
		end
		record.repairs[#record.repairs + 1] = key
		registry.save(record, { force = true })
	end

	-- Performs one completion against one provider. Returns result, nil on success
	-- or nil, message on failure. Retries inside net/http cover transport and
	-- 5xx/429; the provider chain above this handles a dead endpoint.
	function M.complete(record, request)
		local wantStream = request.stream
		if wantStream == nil then wantStream = record.stream ~= false and config.get("agent.stream", true) end

		local body = M.buildBody(record, util.merge(request, { stream = wantStream }))
		applyRemembered(record, body)

		local url = registry.endpoint(record, "/chat/completions")
		local headers = registry.authHeaders(record)
		for key, value in pairs(record.headers or {}) do headers[key] = value end
		headers["Accept"] = wantStream and "text/event-stream" or "application/json"

		local started = clock.ms()
		local attemptsAllowed = request.attempts or config.get("agent.retries", 3)

		local function fire(payload)
			-- A socket is only used when the record names one and the host has
			-- WebSocket support; otherwise the SSE body arrives whole over HTTP.
			if wantStream and util.trim(record.wsUrl) ~= "" and caps.ws then
				local ws = env.require("net/ws")
				local streamBody, wsErr = ws.stream({
					url = record.wsUrl,
					path = "/chat/completions",
					headers = headers,
					body = payload,
					aborted = request.aborted,
					onFrame = request.onFrame,
					timeout = request.timeout or 120,
				})
				if streamBody then
					return { ok = true, status = 200, body = streamBody, via = "websocket", ms = clock.since(started) }
				end
				log.warn("provider", "websocket stream failed, falling back to http", wsErr)
			end
			return http.send({
				url = url,
				method = "POST",
				headers = headers,
				body = util.encode(payload),
				identity = (record.claudeUa ~= false) and "claude" or "none",
				attempts = attemptsAllowed,
				aborted = request.aborted,
				onRetry = request.onRetry,
				tag = "chat:" .. record.id,
				timeout = request.timeout,
			})
		end

		local res, err = fire(body)

		-- One parameter repair, then one more attempt. Repeating this would turn a
		-- misconfigured provider into a request storm.
		if res and res.status == 400 then
			local message = M.errorText(res, nil)
			local note, key = repair(body, message)
			if note then
				log.info("provider", record.label .. ": " .. note .. ", retrying")
				remember(record, key)
				if request.onRetry then
					request.onRetry({ attempt = 1, attempts = 2, wait = 0, reason = note, status = 400 })
				end
				res, err = fire(body)
			end
		end

		if not res or not res.ok then
			local message = M.errorText(res, err)
			registry.markFail(record, message)
			return nil, message, res
		end

		local parsed
		if sse.looksStreamed(res.body) then
			parsed = sse.parse(res.body)
		else
			local decoded, decodeErr = util.decode(res.body)
			if type(decoded) ~= "table" then
				local message = "provider returned a body that is not JSON: " .. tostring(decodeErr)
				registry.markFail(record, message)
				return nil, message, res
			end
			if decoded.error then
				local message = M.errorText(res, nil)
				registry.markFail(record, message)
				return nil, message, res
			end
			parsed = sse.fromResponse(decoded)
		end

		if parsed.streamError then
			registry.markFail(record, parsed.streamError)
			return nil, "stream error: " .. parsed.streamError, res
		end

		local hasText = util.trim(parsed.content) ~= ""
		local hasCalls = #(parsed.toolCalls or {}) > 0
		if not hasText and not hasCalls and util.trim(parsed.reasoning) == "" then
			-- An empty completion is not an error the model can act on, so it is
			-- reported as a failure and the chain may try elsewhere.
			local message = "the provider returned an empty completion"
			registry.markFail(record, message)
			return nil, message, res
		end

		parsed.ms = clock.since(started)
		parsed.provider = record.id
		parsed.providerLabel = record.label
		parsed.via = res.via
		parsed.streamed = parsed.frames and parsed.frames > 0 or false
		registry.markOk(record, parsed.ms)
		return parsed, nil, res
	end

	return M
end
