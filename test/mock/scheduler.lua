-- Virtual-clock cooperative scheduler standing in for Roblox's task library.
--
-- Tests must never sleep: every wait resolves against a clock the driver
-- advances by hand, so a thirty-frame reveal animation costs microseconds and
-- the interleaving is identical on every run. Errors inside spawned threads are
-- captured with a traceback instead of vanishing, which is the failure mode that
-- makes UI bugs invisible in a real client.
local M = {}

local function newSignalError(sched, co, err)
	sched.errors[#sched.errors + 1] = {
		at = sched.now,
		message = tostring(err),
		traceback = debug.traceback(co, tostring(err), 1),
	}
end

function M.new()
	local sched = {
		now = 0,
		seq = 0,
		queue = {},
		errors = {},
		resumed = 0,
	}

	-- A yield of zero still costs a frame. That is Roblox's contract -- task.wait()
	-- resumes on the next heartbeat, not instantly -- and modelling it matters:
	-- a poll loop written as `while not done do task.wait() end` would otherwise
	-- spin for ever at one virtual instant while the thread it waits on never gets
	-- to run.
	local FRAME = 1 / 60

	local function push(co, at, args, queuedAt)
		sched.seq = sched.seq + 1
		sched.queue[#sched.queue + 1] = {
			co = co,
			at = at,
			seq = sched.seq,
			args = args or {},
			queuedAt = queuedAt,
		}
	end

	-- Resumes one thread and re-queues it when it asked to wait again. A yield may
	-- hand back a number (seconds) or nothing (next frame). The value task.wait
	-- returns is the time that actually passed, not the time that was asked for,
	-- because callers accumulate it to measure a timeout.
	local function resume(entry)
		sched.resumed = sched.resumed + 1
		local args = entry.args
		if entry.queuedAt then
			args = { math.max(sched.now - entry.queuedAt, 0) }
		end
		local results = { coroutine.resume(entry.co, unpack(args)) }
		if not results[1] then
			newSignalError(sched, entry.co, results[2])
			return
		end
		if coroutine.status(entry.co) == "dead" then return end
		local requested = math.max(tonumber(results[2]) or 0, FRAME)
		push(entry.co, sched.now + requested, nil, sched.now)
	end

	function sched.spawn(fn, ...)
		local co = coroutine.create(fn)
		-- task.spawn runs the body inline until its first yield, and code that
		-- depends on that (the reference agent loop does) must see the same thing.
		resume({ co = co, at = sched.now, args = { ... } })
		return co
	end

	function sched.defer(fn, ...)
		local co = coroutine.create(fn)
		push(co, sched.now, { ... })
		return co
	end

	function sched.delay(seconds, fn, ...)
		local co = coroutine.create(fn)
		push(co, sched.now + math.max(tonumber(seconds) or 0, 0), { ... })
		return co
	end

	-- Inside a thread this yields; on the driver thread there is nothing to yield
	-- to, so it advances the clock and lets due work run instead.
	function sched.wait(seconds)
		local amount = math.max(tonumber(seconds) or 0, 0)
		if coroutine.running() then
			return coroutine.yield(amount)
		end
		sched.advance(amount)
		return amount
	end

	function sched.cancel(co)
		for i = #sched.queue, 1, -1 do
			if sched.queue[i].co == co then table.remove(sched.queue, i) end
		end
	end

	-- Runs everything due at or before the current virtual time, in insertion
	-- order, including work newly queued by that work.
	function sched.step()
		for _ = 1, 10000 do
			local best, bestIndex
			for i, entry in ipairs(sched.queue) do
				if entry.at <= sched.now + 1e-9 then
					if not best or entry.seq < best.seq then
						best, bestIndex = entry, i
					end
				end
			end
			if not best then return end
			table.remove(sched.queue, bestIndex)
			resume(best)
		end
		error("scheduler.step: 10000 resumes without draining -- probable busy loop")
	end

	-- Advances the clock in the smallest hops that land exactly on each pending
	-- wake time, so ordering never depends on the caller's step size.
	function sched.advance(seconds)
		local target = sched.now + math.max(tonumber(seconds) or 0, 0)
		sched.step()
		for _ = 1, 100000 do
			local next_at
			for _, entry in ipairs(sched.queue) do
				if entry.at <= target and (not next_at or entry.at < next_at) then next_at = entry.at end
			end
			if not next_at then break end
			sched.now = math.max(sched.now, next_at)
			sched.step()
		end
		sched.now = target
		sched.step()
	end

	-- Advances until nothing is pending, or the budget runs out. Returns whether
	-- the queue actually drained, so a test can fail on a thread that never ends.
	function sched.drain(budgetSeconds)
		local budget = tonumber(budgetSeconds) or 120
		local spent = 0
		while #sched.queue > 0 and spent < budget do
			sched.advance(0.05)
			spent = spent + 0.05
		end
		return #sched.queue == 0
	end

	function sched.pending()
		return #sched.queue
	end

	sched.api = {
		wait = sched.wait,
		spawn = sched.spawn,
		defer = sched.defer,
		delay = sched.delay,
		cancel = sched.cancel,
		synchronize = function() end,
		desynchronize = function() end,
	}

	return sched
end

return M
