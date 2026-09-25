-- The only module that performs an HTTP request.
--
-- Centralising it buys three things the client depends on: the Claude Code
-- identity cannot be omitted by a forgetful caller, every request lands in one
-- redacted history the Logs panel reads, and retry policy is written once rather
-- than per call site.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local ua = env.require("net/ua")
	local signal = env.require("runtime/signal")

	local HISTORY_LIMIT = 60
	local MAX_BODY, MAX_WORKERS = 8 * 1024 * 1024, 8
	local workers, alive = 0, true
	local function aborted(spec)
		if not alive then return true end
		if not spec.aborted then return false end
		local ok, value = pcall(spec.aborted); return not ok or value == true
	end
	local function terminal(err)
		local value = tostring(err or ""):lower()
		return value == "aborted" or value:find("deadline", 1, true) ~= nil or value:find("timed out", 1, true) ~= nil
			or value:find("timeout", 1, true) ~= nil or value:find("response_limit:", 1, true) ~= nil or value:find("malformed:", 1, true) ~= nil
			or value:find("malformed_stream:", 1, true) ~= nil
	end

	-- A browser agent for the public web: search engines and CDNs answer 403 to
	-- anything else, so the web tools opt into this explicitly. Everything else,
	-- inference included, carries the Claude Code identity.
	local BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

	-- Statuses that are always worth another attempt, regardless of what the body
	-- says. Everything in 5xx joins them by range below.
	local RETRY_STATUS = {
		[408] = true, [409] = true, [425] = true, [429] = true, [499] = true,
	}

	-- How long an attempt has to run before "nothing came back" reads as a deadline
	-- rather than a decision, in milliseconds.
	--
	-- A refusal arrives in milliseconds: an edge filter and an exhausted quota both
	-- answer immediately. Only a transport that ran out of time takes tens of seconds
	-- to produce nothing at all, and by then the gateway has accepted the request and
	-- billed the whole prompt. Retrying that re-sends every token to arrive at the same
	-- wall, so above this an empty answer ends the sequence instead of extending it.
	local DEADLINE_FLOOR = 10000

	-- Substrings that mean "transient", wherever they appear in a response body.
	--
	-- These gateways report an overloaded or rate-limited upstream in the body and
	-- pick the status code almost at random, so the text is the more reliable signal.
	-- The list is taken from the reference proxy that sits in front of them, which
	-- sees the upstream errors this client only ever sees second-hand -- including the
	-- Chinese quota wording, which arrives under a 403.
	local TRANSIENT_MARKERS = {
		"rate_limit", "chatratelimited",
		"upstream_provider_rate_limit", "server_is_overloaded",
		"service_unavailable_error", "server_error", "overloaded_error",
		"internal_server_error", "temporarily unavailable", "please try again",
		"用户额度不足", "剩余额度",
	}

	local function transient(body)
		if type(body) ~= "string" or body == "" then return false end
		local lowered = body:lower()
		for _, marker in ipairs(TRANSIENT_MARKERS) do
			if lowered:find(marker, 1, true) then return true end
		end
		return false
	end

	-- A gateway that answers 200 and then puts the failure in the body. Detected
	-- structurally -- a decodable object carrying an `error`, or an SSE frame whose
	-- type is "error" -- and never by substring, because a reply that happens to
	-- discuss rate limits must not be mistaken for one.
	local function errorPayload(body)
		if type(body) ~= "string" or body == "" then return nil end
		local function check(text)
			local decoded = util.decode(text)
			if type(decoded) ~= "table" then return nil end
			if decoded.type == "error" then return decoded end
			if decoded.error ~= nil then return decoded end
			return nil
		end
		local direct = check(body)
		if direct then return direct end
		for line in body:gmatch("[^\r\n]+") do
			local data = line:match("^data:%s*(.+)$")
			if data and data ~= "[DONE]" then
				local hit = check(data)
				if hit then return hit end
			end
		end
		return nil
	end

	local M = {
		history = {},
		changed = signal.new("http"),
		count = 0,
	}

	function M.header(res, name)
		local headers = res and res.headers
		if type(headers) ~= "table" then return nil end
		local wanted = tostring(name):lower()
		for key, value in pairs(headers) do
			if type(key) == "string" and key:lower() == wanted then
				-- Some transports hand back a list of values for one header.
				if type(value) == "table" then return value[1] end
				return value
			end
		end
		return nil
	end

	local function record(entry)
		M.count = M.count + 1
		entry.id = M.count
		M.history[#M.history + 1] = entry
		if #M.history > HISTORY_LIMIT then table.remove(M.history, 1) end
		M.changed:fire(entry)
		return entry
	end

	local function identityHeaders(kind, attempt, timeout)
		if kind == "none" then return {} end
		if kind == "browser" then
			return {
				["User-Agent"] = BROWSER_UA,
				["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
				["Accept-Language"] = "en-US,en;q=0.9",
			}
		end
		if kind == "openrouter" then
			return {
				["User-Agent"] = "ProjectUAI/1.0.0",
				["HTTP-Referer"] = "https://carldv.github.io/ProjectUAI/",
				["X-Title"] = "Project UAI",
				["X-OpenRouter-Title"] = "Project UAI",
				["X-OpenRouter-Categories"] = "game,cli-agent",
			}
		end
		if not ua.enabled() then return {} end
		return ua.headers({ attempt = attempt, timeout = timeout })
	end

	-- Header merge order: identity first, then the caller's, so a caller can
	-- deliberately override one value without losing the rest of the set.
	local function buildHeaders(spec, attempt)
		local url = tostring(spec.url or "")
		local isOpenRouter = url:find("openrouter.ai", 1, true) ~= nil
		local identity = isOpenRouter and "openrouter" or (spec.identity or "claude")

		local headers = identityHeaders(identity, attempt, spec.timeout)
		for key, value in pairs(spec.headers or {}) do
			if value ~= nil then headers[key] = tostring(value) end
		end
		-- A gateway requiring this identity must retain it even when the global
		-- preference is off or a saved custom header would otherwise replace it.
		if spec.identityRequired and identity == "claude" then
			local required = ua.headers({ attempt = attempt, timeout = spec.timeout, required = true })
			local names = {}
			for key in pairs(required) do names[key:lower()] = true end
			for key in pairs(headers) do
				if names[key:lower()] then headers[key] = nil end
			end
			for key, value in pairs(required) do headers[key] = value end
		end

		if isOpenRouter then
			-- Ensure OpenRouter attribution headers are always present for rankings and app stats
			if not headers["HTTP-Referer"] and not headers["http-referer"] then
				headers["HTTP-Referer"] = "https://carldv.github.io/ProjectUAI/"
			end
			if not headers["X-Title"] and not headers["x-title"] then
				headers["X-Title"] = "Project UAI"
			end
			if not headers["X-OpenRouter-Title"] and not headers["x-openrouter-title"] then
				headers["X-OpenRouter-Title"] = "Project UAI"
			end
			if not headers["X-OpenRouter-Categories"] and not headers["x-openrouter-categories"] then
				headers["X-OpenRouter-Categories"] = "game,cli-agent"
			end
			if not headers["User-Agent"] and not headers["user-agent"] then
				headers["User-Agent"] = "ProjectUAI/1.0.0"
			end
			-- Suppress Claude Code / Stainless headers for OpenRouter
			headers["x-app"] = nil
			headers["X-Stainless-Lang"] = nil
			headers["X-Stainless-Package-Version"] = nil
			headers["X-Stainless-OS"] = nil
			headers["X-Stainless-Arch"] = nil
			headers["X-Stainless-Runtime"] = nil
			headers["X-Stainless-Runtime-Version"] = nil
			headers["X-Stainless-Retry-Count"] = nil
			headers["X-Stainless-Timeout"] = nil
		end

		if spec.body and not headers["Content-Type"] and not headers["content-type"] then
			headers["Content-Type"] = "application/json"
		end
		return headers
	end

	-- Socket envelopes can carry the same required identity as HTTP requests.
	function M.headersFor(spec)
		return buildHeaders(spec, spec.attempt or 1)
	end

	-- What a transport hands back when it never got an answer varies: some set
	-- Success = false, some invent a status code. What they share is that nothing came
	-- off the wire -- no body and no headers -- and a real HTTP reply always carries at
	-- least one header. Reporting that as a status writes a number into the log no
	-- server ever sent, and the retry policy then reasons about a refusal nobody
	-- issued: the gateway had already accepted the request and billed the prompt.
	local function normalise(res, via)
		local headers = res.Headers or res.ResponseHeaders or {}
		if type(headers) ~= "table" then headers = {} end
		local body = res.Body or res.ResponseData or ""
		if type(body) ~= "string" then return nil, "malformed: transport body is not text" end
		if #body > MAX_BODY then return nil, "response_limit: response exceeds 8 MiB" end
		if body == "" and next(headers) == nil then
			local said = util.trim(tostring(res.StatusMessage or ""))
			return nil, said ~= "" and said or "the transport returned no response"
		end
		return {
			status = tonumber(res.StatusCode or res.Status) or 0,
			body = body,
			headers = headers,
			message = res.StatusMessage,
			via = via,
		}
	end

	local function send(url, method, headers, body, timeout)
		local options = { Url = url, Method = method, Headers = headers }
		if body and body ~= "" and method ~= "GET" and method ~= "HEAD" then
			options.Body = body
		end

		if caps.fn.request then
			-- Set only on this path: RequestAsync accepts a fixed set of keys. Not every
			-- executor honours it either, which is why an attempt that runs long is also
			-- recognised after the fact rather than only prevented here.
			if timeout and timeout > 0 then options.Timeout = math.floor(timeout) end
			local ok, res = pcall(caps.fn.request, options)
			if not ok then return nil, tostring(res) end
			if type(res) ~= "table" then return nil, "empty executor response" end
			return normalise(res, "executor")
		end

		if caps.http == "none" then return nil, caps.reason("http") end
		local ok, res = pcall(function() return env.hs:RequestAsync(options) end)
		if not ok then return nil, tostring(res) end
		if type(res) ~= "table" then return nil, "empty HttpService response" end
		return normalise(res, "roblox")
	end

	-- One attempt. Returns res (with .ok) or nil plus a transport error string.
	function M.request(spec)
		local url = tostring(spec.url or "")
		if url == "" then return nil, "no url" end
		local method = (spec.method or "GET"):upper()
		local attempt = spec.attempt or 1
		local headers = buildHeaders(spec, attempt)
		local started = clock.ms()

		if aborted(spec) then return nil, "aborted", 0 end
		if workers >= MAX_WORKERS then return nil, "deadline: native HTTP worker limit reached", 0 end
		local deadline = math.min(tonumber(spec.deadlineMs) or math.huge, started + math.max(1, math.min(300, tonumber(spec.timeout) or 120)) * 1000)
		if deadline <= started then return nil, "deadline: request budget expired", 0 end
		local pending = { done = false, accepting = true }
		workers = workers + 1
		clock.spawn(function()
			local ok, response, problem = pcall(function()
				if spec.relay then return env.require("net/relay").request(spec, headers, M.request) end
				return send(url, method, headers, spec.body, math.max(0.001, (deadline - clock.ms()) / 1000))
			end)
			workers = math.max(0, workers - 1)
			if pending.accepting then pending.res, pending.err, pending.done = ok and response or nil, ok and problem or "Native HTTP transport failed", true end
		end)
		while not pending.done and not aborted(spec) and clock.ms() < deadline do clock.wait(0.05) end
		pending.accepting = false
		local res, err = pending.res, pending.err
		if aborted(spec) then res, err = nil, "aborted"
		elseif not pending.done or clock.ms() > deadline then res, err = nil, "deadline: transport outcome is unknown; automatic retry is disabled" end
		if res and (type(res.body) ~= "string" or #res.body > MAX_BODY) then res, err = nil, "response_limit: response exceeds its text budget" end
		if err then err = log.redact(util.ellipsis(tostring(err), 1000)) end
		local elapsed = clock.since(started)

		-- `spec.silent` keeps a request out of the history and out of the log. The web
		-- bridge polls continuously for as long as it is enabled, and against a
		-- 60-entry ceiling that would evict the inference calls the Requests view
		-- exists to explain. A silent caller reports its own failures instead.
		local entry = {
			at = started,
			stamp = clock.stamp(),
			method = method,
			url = log.redact(url),
			tag = spec.tag or "http",
			ms = elapsed,
			status = res and res.status or 0,
			bytes = res and #tostring(res.body or "") or 0,
			via = res and res.via or (caps.fn.request and "executor" or "roblox"),
			identity = (url:find("openrouter.ai", 1, true) and "openrouter") or spec.identity or "claude",
			uaSent = ((spec.identity ~= "none") or url:find("openrouter.ai", 1, true)) and caps.uaSupported or false,
			error = err,
			attempt = attempt,
			-- A refusal with an empty body cannot be diagnosed from a status code
			-- alone, and until now nothing about the response was kept at all. These
			-- four are what distinguish an API decision from an edge filter: a
			-- Cloudflare 403 carries `server` and `cf-ray` and usually `cf-mitigated`,
			-- and the API's own 403 carries a JSON body. Kept short -- this is what the
			-- Requests view shows, not an archive.
			response = res and log.redact(util.ellipsis(res.body, 400)) or nil,
			server = res and M.header(res, "server") or nil,
			trace = res and (M.header(res, "cf-ray") or M.header(res, "x-request-id")) or nil,
			mitigated = res and M.header(res, "cf-mitigated") or nil,
		}
		if not spec.silent then record(entry) end

		if not res then
			-- How long it ran is the whole diagnosis: a transport that refuses fails at
			-- once, one that ran out of time fails slowly, and only the second is a
			-- deadline. The caller needs the number to tell them apart.
			if not spec.silent then
				log.warn("http", string.format("%s %s failed after %s", method, entry.url,
					util.formatDuration(elapsed)), err)
			end
			return nil, err or "request failed", elapsed
		end

		res.ms = elapsed
		res.ok = res.status >= 200 and res.status < 300
		res.entry = entry
		if spec.silent then
			return res
		end
		if not res.ok then
			log.warn("http", string.format("%s %s -> %d", method, entry.url, res.status),
				util.ellipsis(res.body, 240))
		else
			log.debug("http", string.format("%s %s -> %d in %s", method, entry.url, res.status,
				util.formatDuration(elapsed)))
		end
		return res
	end

	-- Retry-After is seconds or an HTTP date. Only the numeric form is honoured:
	-- parsing an RFC date to save a couple of seconds is not worth the code, and
	-- the backoff curve is a sane fallback.
	local function retryDelay(res, attempt, opts)
		if res then
			local header = M.header(res, "retry-after")
			local seconds = tonumber(header)
			if seconds and seconds > 0 then return math.min(seconds, 60), "retry-after" end
		end
		return clock.backoff(attempt, opts), "backoff"
	end

	-- Whether an attempt is worth repeating, and why -- the reason is reported to the
	-- transcript so a slow turn explains itself rather than just being slow. `info`
	-- carries what the response cannot: how long the attempt took, which is the only
	-- way to tell a refusal apart from a deadline when neither carries a body.
	--
	-- `info.skipStatus` is a caller's veto over the statuses it would rather handle
	-- itself: a provider with a key pool passes 429 so the transport does not sleep
	-- its way through a backoff on a key that rotation can replace at once.
	function M.shouldRetry(res, err, info)
		if (res and res.terminal) or terminal(err) then return false end
		local elapsed = tonumber(info and info.elapsed) or 0
		local status = res and res.status or 0
		local body = tostring(res and res.body or "")

		-- The caller's veto is consulted first and answers completely: a status it
		-- named is not retried here, whatever the body says.
		if info and type(info.skipStatus) == "table" and info.skipStatus[status] then
			return false, "status " .. tostring(status) .. " (left to the caller)"
		end

		-- An attempt that ran this long and returned nothing hit a deadline, whatever
		-- status was attached to it -- most often none at all, because the transport gave
		-- up rather than the server answering. The next attempt re-sends the entire
		-- prompt to reach the same wall, and the gateway bills it on arrival, so the
		-- sequence ends here and says why instead of paying three times over.
		--
		-- Retry-After is the exception, and the only one: a server naming a moment to
		-- come back has told us the request will work later, which is precisely what a
		-- deadline cannot promise.
		local told = res and tonumber(M.header(res, "retry-after"))
		if elapsed >= DEADLINE_FLOOR and util.trim(body) == "" and not told then
			return false, string.format("nothing returned after %s", util.formatDuration(elapsed))
		end

		-- The transport itself failed. Nothing was decided upstream, so try again.
		if err then return true, "transport error" end
		if not res then return true, "no response" end

		if RETRY_STATUS[status] then return true, "status " .. tostring(status) end
		if status >= 500 and status <= 599 then return true, "status " .. tostring(status) end

		-- A 403 from these gateways is usually an edge filter or an exhausted shared
		-- quota pool rather than a decision about this key: in the log that prompted
		-- this they arrive interleaved with 200s on the same endpoint, seconds apart.
		-- A genuine permission refusal explains itself in the body, so one that
		-- explains nothing gets another attempt and one that does is reported.
		if status == 403 then
			if util.trim(body) == "" then return true, "403 with no explanation" end
			if transient(body) then return true, "403, upstream busy" end
			return false
		end

		if res.ok then
			local payload = errorPayload(body)
			if payload then
				local text = type(payload.error) == "table" and tostring(payload.error.message or "")
					or tostring(payload.error or payload.message or "")
				if transient(text) or transient(body) then return true, "error inside a 200" end
			end
			return false
		end

		if transient(body) then return true, "upstream busy" end
		return false
	end

	-- Retries the whole attempt sequence. `spec.attempts` caps it; `spec.onRetry`
	-- lets the caller report the wait to the interface, and `spec.aborted` lets a
	-- user cancel during the sleep rather than after it.
	function M.send(spec)
		local attempts = math.max(1, math.min(8, tonumber(spec.attempts) or 1))
		local deadline = tonumber(spec.deadlineMs) or (clock.ms() + math.max(1, math.min(300, tonumber(spec.timeout) or 120)) * 1000)
		local lastRes, lastErr
		for attempt = 1, attempts do
			if aborted(spec) then return nil, "aborted" end
			local copy = util.copy(spec)
			copy.attempt, copy.deadlineMs = attempt, deadline
			if clock.ms() >= deadline then return nil, "deadline: request budget expired" end
			local res, err, failedMs = M.request(copy)
			lastRes, lastErr = res, err
			-- Asked before the success check, because a 200 can carry the failure in
			-- its body and returning that as a reply is worse than retrying it.
			local retry, why = M.shouldRetry(res, err, {
				elapsed = res and res.ms or failedMs,
				skipStatus = spec.skipStatus,
			})
			if not retry then
				-- A deadline is the one outcome the caller cannot read off the response,
				-- because there is no response to read. The transport's own words for it
				-- stay in the log entry rather than the message: they are usually a raise
				-- from inside the executor ("Argument 1 missing or nil") and say nothing
				-- a reader can act on, where the wait and its cause do.
				if why and not res then
					return nil, "deadline: " .. why .. " -- the transport gave up while the request was still " ..
						"running. A smaller context budget or reply ceiling fits inside it."
				end
				return res, err
			end
			if attempt >= attempts then return res, err end
			local wait, source = retryDelay(res, attempt, spec.backoff)
			if spec.onRetry then
				local callbackOk = pcall(spec.onRetry, {
					attempt = attempt,
					attempts = attempts,
					wait = wait,
					reason = why or source,
					status = res and res.status or 0,
					error = err,
				})
				if not callbackOk then log.warn("http", "retry callback failed safely") end
			end
			-- Slice the sleep so an abort lands promptly instead of after the full
			-- backoff, which at the top of the curve is twenty seconds.
			local slept = 0
			while slept < wait do
				if clock.ms() >= deadline then return nil, "deadline: request budget expired during backoff" end
				if aborted(spec) then return nil, "aborted" end
				local step = math.min(0.25, wait - slept)
				clock.wait(step)
				slept = slept + step
			end
		end
		return lastRes, lastErr
	end

	function M.json(spec)
		local res, err = M.send(spec)
		if not res then return nil, err, nil end
		local decoded, decodeErr = util.decode(res.body)
		if decoded == nil then return nil, decodeErr or "invalid json", res end
		return decoded, nil, res
	end

	function M.clearHistory()
		M.history = {}
		M.changed:fire(nil)
	end

	M.terminal = terminal
	M.limits = { body = MAX_BODY, workers = MAX_WORKERS }
	function M.workers() return workers end
	env.require("runtime/dispose").add(function() alive = false; M.changed:clear() end, "native HTTP workers")
	M.BROWSER_UA = BROWSER_UA

	return M
end
