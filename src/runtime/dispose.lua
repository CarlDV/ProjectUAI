-- The disposer registry.
--
-- Everything this client leaves running outside its own instance tree -- a timer, a
-- repeating tween, a connection to a service that outlives the interface, a
-- subscription to a long-lived signal -- registers its cleanup here. Destroying the
-- ScreenGui is not unloading: a `clock.interval` keeps ticking against a destroyed
-- label, an InputBegan handler keeps firing, and a second boot then has two of
-- everything. Draining this is what makes an unload real.
--
-- Deliberately dependency-free so anything can require it, including runtime/clock.
return function(env)
	local M = { entries = {}, draining = false }

	-- Returns a canceller that also unregisters, so a caller that cleans up early
	-- does not leave a dead entry behind for the drain to trip over.
	function M.add(fn, label)
		if type(fn) ~= "function" then return function() end end
		local entry = { fn = fn, label = label or "anonymous", alive = true }
		M.entries[#M.entries + 1] = entry
		return function()
			if not entry.alive then return end
			entry.alive = false
			pcall(entry.fn)
		end
	end

	-- An RBXScriptConnection from a signal that outlives the UI.
	function M.connection(connection, label)
		if type(connection) ~= "table" and type(connection) ~= "userdata" then
			return function() end
		end
		return M.add(function()
			pcall(function() connection:Disconnect() end)
		end, label or "connection")
	end

	-- A tween that repeats forever and so never releases its target on its own.
	function M.tween(tween, label)
		if not tween then return function() end end
		return M.add(function()
			pcall(function() tween:Cancel() end)
		end, label or "tween")
	end

	function M.count()
		local alive = 0
		for _, entry in ipairs(M.entries) do
			if entry.alive then alive = alive + 1 end
		end
		return alive
	end

	-- Runs every cleanup once, newest first, and never raises: an unload that stops
	-- halfway because one handler errored is worse than one that reports at the end.
	function M.drain()
		if M.draining then return 0 end
		M.draining = true
		local ran, failed = 0, {}
		for index = #M.entries, 1, -1 do
			local entry = M.entries[index]
			if entry.alive then
				entry.alive = false
				local ok, err = pcall(entry.fn)
				ran = ran + 1
				if not ok then failed[#failed + 1] = entry.label .. ": " .. tostring(err) end
			end
		end
		M.entries = {}
		M.draining = false
		return ran, failed
	end

	return M
end
