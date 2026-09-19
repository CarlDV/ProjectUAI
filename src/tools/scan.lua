-- Incremental tree inspection: early results do not allocate the entire place.
return function(env)
	local clock = env.require("runtime/clock")
	local M = {}

	function M.descendants(root, ctx, visit, limit, offset)
		local stats = { scanned = 0, unreadable = 0, complete = true }
		local stack = {}
		local function children(node)
			local ok, items = pcall(function() return node:GetChildren() end)
			if not ok then
				stats.unreadable = stats.unreadable + 1
				return false
			end
			if #items > 0 then stack[#stack + 1] = { items = items, at = 1 } end
			return true
		end
		if ctx and ctx.aborted and ctx.aborted() then
			stats.complete, stats.reason = false, "aborted"
			return stats
		end
		if not children(root) then
			stats.complete, stats.reason = false, "unreadable root"
			return stats
		end
		local lastYield = clock.ms()
		while #stack > 0 do
			local frame = stack[#stack]
			local node = frame.items[frame.at]
			if not node then
				stack[#stack] = nil
			else
				if stats.scanned >= (limit or 20000) then
					stats.complete, stats.reason = false, "scan limit"
					break
				end
				frame.at = frame.at + 1
				stats.scanned = stats.scanned + 1
				if stats.scanned % 256 == 0 then
					if clock.since(lastYield) >= 8 or stats.scanned % 2048 == 0 then
						task.wait()
						lastYield = clock.ms()
					end
					if ctx and ctx.aborted and ctx.aborted() then
						stats.complete, stats.reason = false, "aborted"
						break
					end
				end
				if stats.scanned >= (offset or 1) and visit(node, stats.scanned) == false then
					stats.complete, stats.reason = false, "page full"
					break
				end
				children(node)
			end
		end
		if stats.unreadable > 0 then stats.complete = false end
		return stats
	end

	return M
end
