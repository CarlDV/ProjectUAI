-- Measure long lines in bounded UTF-8 chunks and reuse their prefix widths.
return function(env)
	local text = env.require("runtime/code_text")
	local P = env.require("ui/primitives")
	local M = {}
	function M.line(value)
		local metric = { width = 0, chunks = {} }
		local at = 1
		while at <= #value do
			local after = text.clamp(value, at + 2048)
			local width = P.measureText(value:sub(at, after - 1), { role = "mono" }).X
			metric.chunks[#metric.chunks + 1] = { first = at, after = after, x = metric.width, width = width }
			metric.width, at = metric.width + width, after
		end
		return metric
	end
	function M.at(metric, value, offset)
		offset = text.clamp(value, offset)
		local low, high = 1, #metric.chunks
		while low < high do local mid = math.ceil((low + high) / 2); if metric.chunks[mid].first <= offset then low = mid else high = mid - 1 end end
		local chunk = metric.chunks[low]
		if not chunk then return 0 end
		if offset >= chunk.after then return chunk.x + chunk.width end
		return chunk.x + P.measureText(value:sub(chunk.first, offset - 1), { role = "mono" }).X
	end
	function M.window(metric, value, left, width)
		if #value <= 2048 then return 0, 1, #value + 1 end
		local low, high = 1, #metric.chunks
		while low < high do local mid = math.ceil((low + high) / 2); if metric.chunks[mid].x <= left then low = mid else high = mid - 1 end end
		local first = metric.chunks[low]
		local after = first.after
		for i = low + 1, math.min(#metric.chunks, low + 3) do
			local chunk = metric.chunks[i]
			if chunk.x > left + width then break end
			after = chunk.after
		end
		return first.x, first.first, after
	end
	return M
end
