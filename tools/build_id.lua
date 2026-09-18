-- Deterministic content identity, independent of checkout path, time and CRLF.
-- Two integer rolling hashes stay below Lua's exact integer limit throughout.
return function(version, modules, bootstrap)
	local first, second = 5381, 2166136261
	local function add(value)
		value = tostring(value):gsub("\r\n", "\n"):gsub("%s+$", "")
		for index = 1, #value do
			local byte = value:byte(index)
			first = (first * 33 + byte) % 4294967291
			second = (second * 65599 + byte) % 4294967279
		end
		first = (first * 33) % 4294967291
		second = (second * 65599) % 4294967279
	end
	add(version)
	for _, module in ipairs(modules) do add(module.id); add(module.source) end
	add(bootstrap)
	return string.format("%s-%08x%08x", version, first, second)
end
