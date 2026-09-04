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

	-- A browser agent for the public web: search engines and CDNs answer 403 to
	-- anything else, so the web tools opt into this explicitly. Everything else,
	-- inference included, carries the Claude Code identity.
	local BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

	local RETRY_STATUS = {
		[408] = true, [409] = true, [425] = true, [429] = true,
		[500] = true, [502] = true, [503] = true, [504] = true, [522] = true, [524] = true,
	}

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
		if not ua.enabled() then return {} end
		return ua.headers({ attempt = attempt, timeout = timeout })
	end

	-- Header merge order: identity first, then the caller's, so a caller can
	-- deliberately override one value without losing the rest of the set.
	local function buildHeaders(spec, attempt)
		local headers = identityHeaders(spec.identity or "claude", attempt, spec.timeout)
		for key, value in pairs(spec.headers or {}) do
			if value ~= nil then headers[key] = tostring(value) end
		end
		if spec.body and not headers["Content-Type"] and not headers["content-type"] then
			headers["Content-Type"] = "application/json"
		end
		return headers
	end

	local function send(url, method, headers, body)
		local options = { Url = url, Method = method, Headers = headers }
		if body and body ~= "" and method ~= "GET" and method ~= "HEAD" then
			options.Body = body
		end

		if caps.fn.request then
			local ok, res = pcall(caps.fn.request, options)
			if not ok then return nil, tostring(res) end
			if type(res) ~= "table" then return nil, "empty executor response" end
			return {
				status = tonumber(res.StatusCode or res.Status) or 0,
				body = res.Body or res.ResponseData or "",
				headers = res.Headers or res.ResponseHeaders or {},
				message = res.StatusMessage,
				via = "executor",
			}
		end

		if caps.http == "none" then return nil, caps.reason("http") end
		local ok, res = pcall(function() return env.hs:RequestAsync(options) end)
		if not ok then return nil, tostring(res) end
		if type(res) ~= "table" then return nil, "empty HttpService response" end
		return {
			status = tonumber(res.StatusCode) or 0,
			body = res.Body or "",
			headers = res.Headers or {},
			message = res.StatusMessage,
			via = "roblox",
		}
	end

	-- One attempt. Returns res (with .ok) or nil plus a transport error string.
	function M.request(spec)
		local url = tostring(spec.url or "")
		if url == "" then return nil, "no url" end
		local method = (spec.method or "GET"):upper()
		local attempt = spec.attempt or 1
		local headers = buildHeaders(spec, attempt)
		local started = clock.ms()

		local res, err = send(url, method, headers, spec.body)
		local elapsed = clock.since(started)

		local entry = record({
			at = started,
			stamp = clock.stamp(),
			method = method,
			url = log.redact(url),
			tag = spec.tag or "http",
			ms = elapsed,
			status = res and res.status or 0,
			bytes = res and #tostring(res.body or "") or 0,
			via = res and res.via or (caps.fn.request and "executor" or "roblox"),
			identity = spec.identity or "claude",
			uaSent = (spec.identity ~= "none") and caps.uaSupported or false,
			error = err,
			attempt = attempt,
			-- A refusal with an empty body cannot be diagnosed from a status code
			-- alone, and until now nothing about the response was kept at all. These
			-- four are what distinguish an API decision from an edge filter: a
			-- Cloudflare 403 carries `server` and `cf-ray` and usually `cf-mitigated`,
			-- and the API's own 403 carries a JSON body. Kept short -- this is what the
			-- Requests view shows, not an archive.
			response = res and util.ellipsis(res.body, 400) or nil,
			server = res and M.header(res, "server") or nil,
			trace = res and (M.header(res, "cf-ray") or M.header(res, "x-request-id")) or nil,
			mitigated = res and M.header(res, "cf-mitigated") or nil,
		})

		if not res then
			log.warn("http", method .. " " .. entry.url .. " failed", err)
			return nil, err or "request failed"
		end

		res.ms = elapsed
		res.ok = res.status >= 200 and res.status < 300
		res.entry = entry
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

	function M.shouldRetry(res, err)
		if err then return true end
		if not res then return true end
		return RETRY_STATUS[res.status] == true
	end

	-- Retries the whole attempt sequence. `spec.attempts` caps it; `spec.onRetry`
	-- lets the caller report the wait to the interface, and `spec.aborted` lets a
	-- user cancel during the sleep rather than after it.
	function M.send(spec)
		local attempts = math.max(spec.attempts or 1, 1)
		local lastRes, lastErr
		for attempt = 1, attempts do
			if spec.aborted and spec.aborted() then return nil, "aborted" end
			local copy = util.copy(spec)
			copy.attempt = attempt
			local res, err = M.request(copy)
			lastRes, lastErr = res, err
			if res and res.ok then return res end
			if attempt >= attempts or not M.shouldRetry(res, err) then
				return res, err
			end
			local wait, why = retryDelay(res, attempt, spec.backoff)
			if spec.onRetry then
				spec.onRetry({
					attempt = attempt,
					attempts = attempts,
					wait = wait,
					reason = why,
					status = res and res.status or 0,
					error = err,
				})
			end
			-- Slice the sleep so an abort lands promptly instead of after the full
			-- backoff, which at the top of the curve is twenty seconds.
			local slept = 0
			while slept < wait do
				if spec.aborted and spec.aborted() then return nil, "aborted" end
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

	M.BROWSER_UA = BROWSER_UA

	return M
end
