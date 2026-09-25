-- HTTP header names are case-insensitive. Later maps deliberately win.
return function()
	local M = {}
	function M.merge(...)
		local out, names = {}, {}
		for i = 1, select("#", ...) do
			for key, value in pairs(select(i, ...) or {}) do
				if type(key) == "string" and value ~= nil then
					local name = key:lower()
					if names[name] then out[names[name]] = nil end
					names[name], out[key] = key, tostring(value)
				end
			end
		end
		return out
	end
	function M.get(headers, wanted)
		wanted = wanted:lower()
		for key, value in pairs(headers or {}) do if key:lower() == wanted then return value end end
	end
	return M
end
