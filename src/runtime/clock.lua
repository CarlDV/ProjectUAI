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

	-- Calendar ---------------------------------------------------------------
	--
	-- Activity is counted per day and per hour of the day, so both have to mean the
	-- same thing on every host: the day the person in front of the screen would
	-- name. Roblox's only calendar API is DateTime's pattern formatter, and its
	-- pattern support differs between client versions -- so the conversion is done
	-- here in arithmetic, from the epoch millisecond count plus this host's offset
	-- from UTC, and the formatter is asked for exactly one thing: that offset.
	local MINUTE_MS = 60000
	local DAY_MINUTES = 1440
	-- The widest real offsets are -12:00 (Baker Island) and +14:00 (Kiritimati).
	local OFFSET_LIMIT = 840
	local offsetMinutes = nil

	function M.offsetMinutes()
		if offsetMinutes then return offsetMinutes end
		offsetMinutes = 0
		local seconds = math.floor(M.ms() / 1000)
		local ok, text = pcall(function()
			return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("HH:mm", "en-us")
		end)
		if ok and type(text) == "string" then
			local hour, minute = text:match("^(%d%d?):(%d%d)$")
			if hour then
				local delta = (tonumber(hour) * 60 + tonumber(minute))
					- math.floor((seconds % 86400) / 60)
				if delta > OFFSET_LIMIT then delta = delta - DAY_MINUTES end
				if delta < -OFFSET_LIMIT then delta = delta + DAY_MINUTES end
				-- Quarter-hour zones exist (Nepal is +05:45); minutes of drift between
				-- the two reads do not.
				offsetMinutes = math.floor(delta / 15 + 0.5) * 15
			end
		end
		return offsetMinutes
	end

	-- Howard Hinnant's civil-from-days, which is exact for every date a client can
	-- hold and needs no leap-year table. `days` is days since 1970-01-01.
	function M.civilFromDays(days)
		local shifted = math.floor(days) + 719468
		local era = math.floor(shifted / 146097)
		local dayOfEra = shifted - era * 146097
		local yearOfEra = math.floor((dayOfEra - math.floor(dayOfEra / 1460)
			+ math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365)
		local year = yearOfEra + era * 400
		local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4)
			- math.floor(yearOfEra / 100))
		local monthPrime = math.floor((5 * dayOfYear + 2) / 153)
		local day = dayOfYear - math.floor((153 * monthPrime + 2) / 5) + 1
		local month = monthPrime + 3
		if monthPrime >= 10 then month = monthPrime - 9 end
		if month <= 2 then year = year + 1 end
		return year, month, day
	end

	function M.daysFromCivil(year, month, day)
		local y = year
		if month <= 2 then y = y - 1 end
		local era = math.floor(y / 400)
		local yearOfEra = y - era * 400
		local shift = 9
		if month > 2 then shift = -3 end
		local dayOfYear = math.floor((153 * (month + shift) + 2) / 5) + day - 1
		local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4)
			- math.floor(yearOfEra / 100) + dayOfYear
		return era * 146097 + dayOfEra - 719468
	end

	-- Local days since the epoch. The unit every per-day bucket is keyed by.
	function M.dayNumber(ms)
		local shifted = (ms or M.ms()) + M.offsetMinutes() * MINUTE_MS
		return math.floor(shifted / 86400000)
	end

	function M.keyFromDayNumber(days)
		local year, month, day = M.civilFromDays(days)
		return string.format("%04d-%02d-%02d", year, month, day)
	end

	function M.dayKey(ms)
		return M.keyFromDayNumber(M.dayNumber(ms))
	end

	-- Nil rather than a guess for anything that is not a key: these come out of a
	-- stored file, and a corrupt one must not be silently read as 1970.
	function M.dayNumberOfKey(key)
		local year, month, day = tostring(key or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
		if not year then return nil end
		return M.daysFromCivil(tonumber(year), tonumber(month), tonumber(day))
	end

	function M.hourOf(ms)
		local shifted = (ms or M.ms()) + M.offsetMinutes() * MINUTE_MS
		return math.floor((shifted % 86400000) / 3600000)
	end

	-- Monday = 1. The epoch itself was a Thursday, which is where the 3 comes from.
	function M.weekdayOfDayNumber(days)
		return ((days + 3) % 7) + 1
	end

	local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
	local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

	function M.monthName(month)
		return MONTHS[month] or "?"
	end

	function M.weekdayName(index)
		return WEEKDAYS[index] or "?"
	end

	-- "Sat 5 Jul 2026", or without the year when it is the current one -- the form a
	-- date is read in rather than the form it is stored in.
	function M.describeDay(key, todayKey)
		local days = M.dayNumberOfKey(key)
		if not days then return tostring(key) end
		local year, month, day = M.civilFromDays(days)
		local thisYear = M.civilFromDays(M.dayNumberOfKey(todayKey or M.dayKey()) or days)
		local head = string.format("%s %d %s", WEEKDAYS[M.weekdayOfDayNumber(days)], day, MONTHS[month])
		if year == thisYear then return head end
		return head .. " " .. tostring(year)
	end

	-- 12-hour clock with a meridiem, which is how a "peak hour" reads.
	function M.describeHour(hour)
		hour = math.floor(tonumber(hour) or 0) % 24
		local suffix = "AM"
		if hour >= 12 then suffix = "PM" end
		local display = hour % 12
		if display == 0 then display = 12 end
		return string.format("%d %s", display, suffix)
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
		-- Registered centrally as well as returned. A caller that forgets the
		-- canceller -- or one whose owning instance is destroyed without its
		-- Destroying handler running -- would otherwise leave a thread ticking for the
		-- lifetime of the process, and an unload could not stop it. The registry's
		-- closure both cancels and unregisters, so it is the one to hand back.
		return env.require("runtime/dispose").add(function() alive = false end, "interval")
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
