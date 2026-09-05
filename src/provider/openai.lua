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
	local traits = env.require("provider/traits")

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

		-- Sampling parameters are rejected outright by the current Claude generations
		-- rather than ignored, so a model documented to refuse one is never sent it.
		-- Every other model keeps the behaviour it has always had, because
		-- withholding a parameter a gateway would have honoured is its own bug.
		local temperature = request.temperature
		if temperature == nil then temperature = config.get("agent.temperature", 0.4) end
		if temperature and traits.allowsSampling(record.model) then
			body.temperature = temperature
		end

		local maxTokens = M.cappedMaxTokens(record, request.maxTokens or config.get("agent.maxTokens", 4096))
		if maxTokens and maxTokens > 0 then body.max_tokens = maxTokens end

		-- Reasoning depth, spelled the way the chat-completions wire spells it. Only
		-- sent to a model with a scale to place it on, and clamped to that scale, so
		-- asking for more than a model has is a smaller request rather than a refusal.
		local effort = M.effortFor(record, request)
		if effort then body.reasoning_effort = effort end

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
		[403] = "the provider refused the request -- the key may lack access to it",
		[404] = "endpoint or model not found -- check the base URL and model name",
		[413] = "the request was too large",
		[422] = "the provider could not process the request",
		[429] = "rate limited",
		[500] = "the provider had an internal error",
		[502] = "the provider gateway is unavailable",
		[503] = "the provider is overloaded",
		[529] = "the provider is overloaded",
	}

	-- An HTML body on a refusal is not the API talking.
	--
	-- A gateway answers in JSON. A whole HTML document -- especially one opening with
	-- Cloudflare's `<!--[if lt IE 7]>` conditional-comment block -- means the request was
	-- stopped in front of the API and never reached the account, the key or the model. So
	-- naming any of those as a possible cause, which the 403 text did, sends the reader
	-- off to check three things that are all fine. The response headers say which edge it
	-- was: `server`, `cf-ray` and `cf-mitigated` are already kept for the Requests view.
	local function edgeBlock(res)
		if not res then return nil end
		local body = util.trim(tostring(res.body or ""))
		if body == "" then return nil end
		local head = body:sub(1, 400):lower()
		local looksHtml = body:sub(1, 1) == "<"
			and (head:find("<!doctype", 1, true) or head:find("<html", 1, true)
				or head:find("<!--[if", 1, true))
		if not looksHtml then return nil end
		local bits = {}
		local server = util.trim(tostring(http.header(res, "server") or ""))
		local mitigated = util.trim(tostring(http.header(res, "cf-mitigated") or ""))
		local ray = util.trim(tostring(http.header(res, "cf-ray") or ""))
		if server ~= "" then bits[#bits + 1] = server end
		if mitigated ~= "" then bits[#bits + 1] = "cf-mitigated " .. mitigated end
		if ray ~= "" then bits[#bits + 1] = ray end
		return #bits > 0 and table.concat(bits, ", ") or "an edge in front of the API"
	end

	function M.errorText(res, err)
		if err and not res then return tostring(err) end
		local status = res and res.status or 0
		-- Checked before the status table, because the status is the least informative
		-- thing about this class of failure.
		local edge = edgeBlock(res)
		if edge then
			return string.format(
				"stopped before it reached the API (%d) by %s. It answered with an HTML page "
				.. "rather than JSON, so the key, the model and the account are not implicated -- "
				.. "the request itself was refused. Turning off the Claude Code identity for this "
				.. "provider is the one thing this client can change about how it looks.",
				status, edge)
		end
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

	-- The output ceiling a refusal names, or nil when it names nothing usable.
	--
	-- Every model has its own max_tokens limit and no endpoint publishes it: /models
	-- reports ids, not capabilities. The one place the number appears is the 400 that
	-- comes back when a request exceeds it, and the wording is different everywhere --
	-- "max_tokens: 200000 > 64000, which is the maximum allowed number of output
	-- tokens for claude-sonnet-4-5-20250929", "max_tokens is too large: 200000. This
	-- model supports at most 16384 completion tokens", "must be less than or equal to
	-- 8192". What they share is that the limit is the largest number in the sentence
	-- below what was sent, so that is what is taken.
	--
	-- The floor is a thousand and it is load-bearing: the status code is part of the
	-- text this is handed, and clamping a reply ceiling to 400 tokens because "(400)"
	-- appeared in the prefix would be worse than the original error. Nothing caps
	-- output below a thousand tokens.
	function M.ceilingFromMessage(message, current)
		current = tonumber(current) or 0
		if current <= 0 then return nil end
		local best
		for digits in tostring(message or ""):gmatch("%d+") do
			local number = tonumber(digits)
			if number and number >= 1000 and number < current and (not best or number > best) then
				best = number
			end
		end
		if best then return best end
		-- Nothing quotable. Halving converges in a couple of attempts and cannot loop,
		-- because each attempt is a fresh request against a smaller number.
		local halved = math.floor(current / 2)
		return (halved >= 1000) and halved or nil
	end

	-- The ceiling to actually send: what the user asked for, lowered to whatever this
	-- record has already been told its model allows.
	--
	-- Kept per model rather than per record, because the limit belongs to the model.
	-- Pointing a record at a wider Claude has to stop clamping it to the narrower
	-- one's limit, and there would be nothing on screen to explain it if it did not:
	-- the slider would read 64k while every request asked for 32k.
	function M.cappedMaxTokens(record, wanted)
		wanted = tonumber(wanted) or 0
		-- What the model documents comes first, so a slider set above a model's
		-- ceiling costs nothing to discover. What a refusal actually taught this
		-- record still applies after it, because the gateway is the final word on
		-- what it will accept.
		local documented = traits.maxOutput(record.model)
		if documented and wanted > documented then wanted = documented end
		local cap = record.maxTokensCap
		if type(cap) ~= "table" or cap.model ~= record.model then return wanted end
		local limit = tonumber(cap.tokens) or 0
		if limit > 0 and wanted > limit then return limit end
		return wanted
	end

	-- The effort level to send, or nil for none. Both adapters ask this and differ
	-- only in how the answer is spelled on the wire.
	--
	-- Clamped to the model's own scale rather than passed through, because the scales
	-- differ by generation -- "xhigh" arrived after 4.6 -- and a level a model has
	-- never heard of is a refusal rather than a rounding.
	function M.effortFor(record, request)
		local wanted = request and request.effort
		if wanted == nil then wanted = config.get("agent.effort", "high") end
		wanted = tostring(wanted or "")
		if wanted == "" or wanted == "off" then return nil end
		return traits.nearestEffort(record and record.model, wanted)
	end

	-- Stores what a refusal named, against the model it came from. Both adapters call
	-- this; the record persists, so the lesson outlives the session.
	function M.rememberMaxTokens(record, tokens)
		record.maxTokensCap = { model = record.model, tokens = tokens }
		registry.save(record, { force = true })
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
			-- Ordered after the rename on purpose: a gateway that wants the other field
			-- name says so in a message this would otherwise read as a size complaint.
			match = "max_tokens",
			apply = function(body, message)
				-- Only ever driven by a live refusal. Replayed from record.repairs there
				-- is no message, and halving on every request would be a silent bug.
				if not message then return nil end
				local current = body.max_tokens or body.max_completion_tokens
				if not current then return nil end
				local allowed = M.ceilingFromMessage(message, current)
				if not allowed or allowed >= current then return nil end
				if body.max_tokens then body.max_tokens = allowed end
				if body.max_completion_tokens then body.max_completion_tokens = allowed end
				return string.format("lowered max_tokens from %d to %d", current, allowed)
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
			-- Not every gateway that relays to a reasoning model forwards the field
			-- that asks for a depth. Dropping it costs the setting, not the turn.
			match = "reasoning_effort",
			apply = function(body)
				if body.reasoning_effort ~= nil then
					body.reasoning_effort = nil
					return "dropped reasoning_effort"
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
				local note = entry.apply(body, message)
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
				if key == "max_tokens" then
					-- A value, not a switch, so it cannot ride in record.repairs -- that
					-- list replays a key with no error text to read a number out of.
					M.rememberMaxTokens(record, body.max_tokens or body.max_completion_tokens)
				else
					remember(record, key)
				end
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
