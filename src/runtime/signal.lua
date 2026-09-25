-- A signal that does not depend on BindableEvent. The client fans a lot of small
-- events out to the interface, and going through Roblox instances for that costs
-- a round trip per fire and loses non-serialisable payloads such as functions --
-- which the permission prompt relies on.
return function(env)
	local M = {}

	local Signal = {}
	Signal.__index = Signal

	function M.new(name)
		return setmetatable({ name = name or "signal", handlers = {}, firing = false }, Signal)
	end

	function Signal:connect(fn)
		if type(fn) ~= "function" then return function() end end
		local entry = { fn = fn, alive = true }
		self.handlers[#self.handlers + 1] = entry
		return function()
			entry.alive = false
			entry.fn = nil; self:compact()
		end
	end

	function Signal:once(fn)
		local disconnect
		disconnect = self:connect(function(...)
			disconnect()
			fn(...)
		end)
		return disconnect
	end

	-- Handlers are copied before the walk so a handler that connects or
	-- disconnects during a fire cannot reshape the list underneath it. Errors are
	-- contained: one broken subscriber must not stop the rest of the interface
	-- from seeing an event.
	function Signal:fire(...)
		self.depth = (self.depth or 0) + 1
		if self.depth > 32 then self.depth = self.depth - 1; self.dropped = (self.dropped or 0) + 1; return end
		self.firing = true
		local snapshot = {}
		for index, entry in ipairs(self.handlers) do snapshot[index] = entry end
		for _, entry in ipairs(snapshot) do
			if entry.alive then
				local ok, err = pcall(entry.fn, ...)
				if not ok and self.onError then pcall(self.onError, err) end
			end
		end
		self.depth = self.depth - 1; self.firing = self.depth > 0; self:compact()
	end

	function Signal:compact()
		if self.firing then return end
		local kept = {}
		for _, entry in ipairs(self.handlers) do
			if entry.alive then kept[#kept + 1] = entry end
		end
		self.handlers = kept
	end

	function Signal:count()
		local total = 0
		for _, entry in ipairs(self.handlers) do
			if entry.alive then total = total + 1 end
		end
		return total
	end

	function Signal:clear()
		for _, entry in ipairs(self.handlers) do entry.alive, entry.fn = false, nil end
		self.handlers = {}
	end

	return M
end
