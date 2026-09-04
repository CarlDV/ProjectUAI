-- Time, scheduling and the retry curve.
--
-- os.clock reports processor time, which stops advancing while a thread is
-- yielded, so anything measuring a request or a backoff has to use a wall clock.
-- DateTime is the modern one; os.time is the fallback for hosts that lack it and
-- costs us sub-second resolution, which only ever affects display.
return function(env)
	local util = env.require("runtime/util")

	local M = {}

	local epochBase = 0
	do
		local ok, value = pcall(function()
			return DateTime.now().UnixTimestampMillis
		end)
		M.precise = ok and type(value) == "number"
		if not M.precise then epochBase = (os.time() or 0) * 1000 end
	end

	function M.ms()
		if M.precise then
			local ok, value = pcall(function() return DateTime.now().UnixTimestampMillis end)
			if ok then return value end
			M.precise = false
		end
		return (os.time() or 0) * 1000
	end

	function M.since(startMs)
		return M.ms() - (startMs or 0)
	end

	function M.stamp()
		local seconds = math.floor(M.ms() / 1000)
		local ok, text = pcall(function()
			return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("HH:mm:ss", "en-us")
		end)
		if ok and type(text) == "string" then return text end
		return string.format("%02d:%02d:%02d",
			math.floor(seconds / 3600) % 24, math.floor(seconds / 60) % 60, seconds % 60)
	end

	function M.wait(seconds)
		return task.wait(seconds)
	end

	function M.spawn(fn, ...)
		return task.spawn(fn, ...)
	end

	function M.delay(seconds, fn, ...)
		return task.delay(seconds, fn, ...)
	end

	-- Injectable so a test can pin the jitter. Nothing else should reach for
	-- math.random directly, or backoff stops being reproducible.
	function M.random()
		return math.random()
	end

	-- Trailing-edge debounce: the last call within the window wins. Returns the
	-- wrapped function plus a cancel handle, because a debounced relayout has to
	-- be cancellable when the surface it targets is destroyed.
	function M.debounce(fn, seconds)
		local generation = 0
		local function wrapped(...)
			generation = generation + 1
			local mine = generation
			local args = { ... }
			task.delay(seconds, function()
				if mine == generation then fn(unpack(args)) end
			end)
		end
		return wrapped, function() generation = generation + 1 end
	end

	-- Leading-edge throttle: fires immediately, then swallows calls for the rest
	-- of the window. Right for a resize signal that can arrive every frame.
	function M.throttle(fn, seconds)
		local lastRun = -math.huge
		return function(...)
			local now = M.ms()
			if now - lastRun < seconds * 1000 then return end
			lastRun = now
			return fn(...)
		end
	end

	function M.interval(seconds, fn)
		local alive = true
		task.spawn(function()
			while alive do
				task.wait(seconds)
				if not alive then return end
				local ok, err = pcall(fn)
				if not ok then env.require("runtime/log").warn("clock", "interval handler failed", err) end
			end
		end)
		return function() alive = false end
	end

	-- Exponential backoff with full jitter, capped. Full jitter rather than a
	-- fixed multiple because several retrying clients behind one gateway
	-- otherwise re-collide on exactly the same schedule.
	function M.backoff(attempt, opts)
		opts = opts or {}
		local base = opts.base or 0.6
		local cap = opts.cap or 20
		local ceiling = math.min(cap, base * (2 ^ math.max(attempt - 1, 0)))
		local floor = opts.floor or (ceiling * 0.35)
		return util.clamp(floor + M.random() * (ceiling - floor), 0, cap)
	end

	-- Runs fn on its own thread and stops waiting after `seconds`.
	--
	-- The timeout cannot kill the thread -- Luau has no way to -- so a runaway
	-- body keeps running in the background and the caller is told so. Elapsed time
	-- comes from task.wait's own delta rather than a clock read per frame, and the
	-- first check happens before any yield: task.spawn runs inline until the first
	-- yield, so code that never yields is already finished and must not be billed
	-- a scheduler tick.
	function M.timeout(seconds, fn)
		local done, ok, result = false, false, nil
		task.spawn(function()
			ok, result = pcall(fn)
			done = true
		end)
		if not done then
			local elapsed = 0
			repeat
				elapsed = elapsed + (task.wait() or 0)
			until done or elapsed >= seconds
		end
		if not done then return false, false, nil end
		return true, ok, result
	end

	return M
end
