-- Bounded typed graphs. Snapshotting never invokes a table's metamethods.
return function(env)
	local util = env.require("runtime/util")
	local refs = env.require("runtime/instance_refs")
	local M = { limits = { bytes = 32768, stringBytes = 16384, depth = 12, tables = 256, values = 1024, slots = 256 } }
	local function pack(...) return { n = select("#", ...), ... } end
	M.pack = pack
	local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
	M.finite = finite
	function M.hex(text) return (text:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
	function M.unhex(text)
		if type(text) ~= "string" or #text % 2 ~= 0 or text:find("[^%x]") then error("Invalid binary encoding", 0) end
		return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
	end
	local function number(value)
		if value ~= value then return { kind = "number", special = "nan" } end
		if value == math.huge then return { kind = "number", special = "infinity" } end
		if value == -math.huge then return { kind = "number", special = "-infinity" } end
		if value == 0 and 1 / value < 0 then return { kind = "number", special = "-zero" } end
		return { kind = "number", value = value }
	end
	local componentNames = {
		Vector2 = { "X", "Y" }, Vector3 = { "X", "Y", "Z" }, Color3 = { "R", "G", "B" },
		UDim = { "Scale", "Offset" }, NumberRange = { "Min", "Max" },
	}
	function M.snapshot(values, options)
		options = options or {}; local bound = M.limits
		local graph = { count = values.n or 0, slots = {}, nodes = {}, complete = true, reasons = {}, bytes = 64 + math.min(values.n or 0, bound.slots) * 64 }
		local seen, total, started = {}, 0, os.clock()
		local function omitted(reason)
			graph.complete = false
			if #graph.reasons < 8 then graph.reasons[#graph.reasons + 1] = reason end
			return { kind = "truncated", reason = reason }
		end
		local encode
		encode = function(value, depth)
			total, graph.bytes = total + 1, graph.bytes + (depth > 0 and 64 or 0)
			if depth > bound.depth or total > bound.values or graph.bytes > bound.bytes or (options.hook and os.clock() - started > 0.002) then return omitted("snapshot budget") end
			local kind = typeof(value)
			if value == nil then return { kind = "nil" }
			elseif kind == "boolean" then return { kind = "boolean", value = value }
			elseif kind == "number" then return number(value)
			elseif kind == "string" then
				local retained = value:sub(1, math.max(0, math.min(bound.stringBytes, math.floor((bound.bytes - graph.bytes) / 2))))
				local node = { kind = "string", value = retained, encoding = "utf8", length = #value }
				if not util.validUtf8(retained) then node.encoding, node.value = "hex", M.hex(retained) end
				graph.bytes = graph.bytes + #node.value
				if #retained < #value then node.truncated = true; omitted("string truncated") end
				return node
			elseif kind == "Instance" then
				local info = refs.describe(value, options.hook)
				local node = { kind = "Instance", instanceId = info.instanceId, className = info.className, name = util.ellipsis(info.name or "", 160), path = not options.hook and util.ellipsis(info.displayPath or "", 512) or nil }
				local cost = 128 + #(node.instanceId or "") + #(node.name or "") + #(node.path or "")
				if graph.bytes + cost > bound.bytes then return omitted("instance metadata budget") end
				graph.bytes = graph.bytes + cost; return node
			elseif kind == "EnumItem" then return { kind = "EnumItem", enum = tostring(value.EnumType):gsub("^Enum%.", ""), name = value.Name }
			elseif kind == "table" then
				if seen[value] then return { kind = "table", node = seen[value] } end
				if #graph.nodes >= bound.tables then return omitted("table budget") end
				local index = #graph.nodes + 1; seen[value] = index
				local node = { id = index, entries = {} }; graph.nodes[index] = node
				local key, item = next(value)
				while key ~= nil do
					if total + 2 >= bound.values or graph.bytes + 128 >= bound.bytes or (options.hook and os.clock() - started > 0.002) then node.truncated = true; omitted("entry budget"); break end
					node.entries[#node.entries + 1] = { key = encode(key, depth + 1), value = encode(item, depth + 1) }
					key, item = next(value, key)
				end
				return { kind = "table", node = index }
			elseif componentNames[kind] then
				local components = {}; for _, key in ipairs(componentNames[kind]) do components[#components + 1] = value[key] end
				return { kind = kind, components = components }
			elseif kind == "CFrame" then return { kind = kind, components = { value:GetComponents() } }
			elseif kind == "UDim2" then return { kind = kind, components = { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset } }
			elseif kind == "Rect" then return { kind = kind, components = { value.Min.X, value.Min.Y, value.Max.X, value.Max.Y } }
			elseif kind == "BrickColor" then return { kind = kind, value = value.Number }
			elseif kind == "NumberSequence" or kind == "ColorSequence" then
				local points = {}
				for i, point in ipairs(value.Keypoints) do
					if i > 64 then return omitted("sequence keypoint budget") end
					points[i] = { time = point.Time, value = encode(point.Value, depth + 1), envelope = kind == "NumberSequence" and point.Envelope or nil }
				end
				return { kind = kind, keypoints = points }
			elseif kind == "buffer" and type(buffer) == "table" then
				local length = buffer.len(value)
				if length > math.min(bound.stringBytes, math.floor((bound.bytes - graph.bytes) / 2)) then return omitted("buffer budget") end
				local bytes = buffer.tostring(value); graph.bytes = graph.bytes + #bytes * 2
				return { kind = "buffer", value = M.hex(bytes), length = length, encoding = "hex" }
			end
			return { kind = "opaque", type = kind }
		end
		if graph.count > bound.slots then graph.count = bound.slots; graph.originalCount = values.n; omitted("argument count exceeds 256") end
		for index = 1, graph.count do
			local ok, value = pcall(encode, rawget(values, index), 0)
			graph.slots[index] = ok and value or omitted("value unavailable")
		end
		return graph
	end
	function M.node(value) return M.snapshot(pack(value)).slots[1] end
	local constructors = {
		Vector2 = function(c) return Vector2.new(unpack(c)) end, Vector3 = function(c) return Vector3.new(unpack(c)) end,
		Color3 = function(c) return Color3.new(unpack(c)) end, CFrame = function(c) return CFrame.new(unpack(c)) end,
		UDim = function(c) return UDim.new(unpack(c)) end, UDim2 = function(c) return UDim2.new(unpack(c)) end,
		Rect = function(c) return Rect.new(unpack(c)) end, NumberRange = function(c) return NumberRange.new(unpack(c)) end,
	}
	local sizes = { Vector2 = 2, Vector3 = 3, Color3 = 3, CFrame = 12, UDim = 2, UDim2 = 4, Rect = 4, NumberRange = 2 }
	function M.decode(graph, options)
		options = options or {}
		local function work()
			local valid, why = M.validateGraph(graph); if not valid then error(why or "Invalid packed graph", 0) end
			if type(graph) ~= "table" or graph.complete == false or not finite(graph.count) or graph.count < 0 or graph.count > M.limits.slots or graph.count ~= math.floor(graph.count) or type(graph.slots) ~= "table" or #graph.slots ~= graph.count then error("Incomplete packed values", 0) end
			local nodes = graph.nodes or {}; if type(nodes) ~= "table" or #nodes > M.limits.tables then error("Invalid table graph", 0) end
			local tables, visiting, done, count, bytes = {}, {}, {}, 0, 0
			for i = 1, #nodes do tables[i] = {} end
			local decode
			decode = function(node, depth)
				count = count + 1
				if count > M.limits.values or depth > M.limits.depth or type(node) ~= "table" or node.truncated then error("Invalid or truncated value graph", 0) end
				local kind = node.kind
				if kind == "nil" then return nil
				elseif kind == "boolean" then if type(node.value) ~= "boolean" then error("Invalid boolean", 0) end; return node.value
				elseif kind == "number" then
					if node.special then
						if node.special == "-zero" then return -1 / math.huge end
						if not options.allowSpecial then error("Non-finite numbers cannot be sent", 0) end
						if node.special == "nan" then return 0 / 0 elseif node.special == "infinity" then return math.huge elseif node.special == "-infinity" then return -math.huge end
					end
					if not finite(node.value) then error("Invalid number", 0) end; return node.value
				elseif kind == "string" then
					if type(node.value) ~= "string" then error("Invalid string", 0) end
					local value = node.encoding == "hex" and M.unhex(node.value) or node.value
					if node.length and node.length ~= #value then error("Incomplete string bytes", 0) end
					bytes = bytes + #value
					if bytes > M.limits.bytes or #value > M.limits.stringBytes then error("String budget exceeded", 0) end
					return value
				elseif kind == "Instance" then local value, why = refs.resolve(node.instanceId); if not value then error(why, 0) end; return value
				elseif kind == "EnumItem" then
					if type(node.enum) ~= "string" or type(node.name) ~= "string" then error("Invalid enum", 0) end
					local enum = Enum[node.enum]; local item = enum and enum[node.name]
					if typeof(item) ~= "EnumItem" then error("Unknown enum item", 0) end; return item
				elseif constructors[kind] then
					local c = node.components
					if type(c) ~= "table" or #c ~= sizes[kind] then error("Invalid " .. kind .. " components", 0) end
					for _, value in ipairs(c) do if not finite(value) then error("Components must be finite", 0) end end
					if kind == "Color3" then for _, value in ipairs(c) do if value < 0 or value > 1 then error("Color components must be 0–1", 0) end end end
					if kind == "NumberRange" and c[1] > c[2] then error("NumberRange minimum exceeds maximum", 0) end
					return constructors[kind](c)
				elseif kind == "BrickColor" then if not finite(node.value) then error("Invalid BrickColor", 0) end; return BrickColor.new(node.value)
				elseif kind == "NumberSequence" or kind == "ColorSequence" then
					local input, points, previous = node.keypoints, {}, -1
					if type(input) ~= "table" or #input < 2 or #input > 64 then error("Invalid keypoints", 0) end
					for i, point in ipairs(input) do
						if not finite(point.time) or point.time <= previous or point.time > 1 or (i == 1 and point.time ~= 0) or (i == #input and point.time ~= 1) then error("Keypoint times must increase from 0 to 1", 0) end
						previous = point.time; local value = decode(point.value, depth + 1)
						if kind == "NumberSequence" then
							if not finite(value) or not finite(point.envelope or 0) or (point.envelope or 0) < 0 then error("Invalid number keypoint", 0) end
							points[i] = NumberSequenceKeypoint.new(point.time, value, point.envelope or 0)
						else if typeof(value) ~= "Color3" then error("Invalid color keypoint", 0) end; points[i] = ColorSequenceKeypoint.new(point.time, value) end
					end
					return kind == "NumberSequence" and NumberSequence.new(points) or ColorSequence.new(points)
				elseif kind == "buffer" then
					if type(buffer) ~= "table" or not buffer.fromstring then error("Buffer construction unavailable", 0) end
					local bytesValue = M.unhex(node.value); if #bytesValue > M.limits.stringBytes then error("Buffer budget exceeded", 0) end
					return buffer.fromstring(bytesValue)
				elseif kind == "table" then
					local index = node.node; if type(index) ~= "number" or index ~= math.floor(index) or not nodes[index] then error("Dangling table reference", 0) end
					if visiting[index] then error("Cyclic tables are inspectable but cannot be replayed", 0) end
					if not done[index] then
						local spec = nodes[index]; if spec.truncated or type(spec.entries) ~= "table" then error("Incomplete table", 0) end
						visiting[index] = true; local shape, keys, maximum = nil, 0, 0
						for _, entry in ipairs(spec.entries) do
							local key, value = decode(entry.key, depth + 1), decode(entry.value, depth + 1)
							local keyType = type(key)
							if keyType ~= "string" and (keyType ~= "number" or key < 1 or key ~= math.floor(key)) then error("Unsupported remote table key", 0) end
							if shape and shape ~= keyType then error("Mixed table keys cannot be replayed", 0) end
							if tables[index][key] ~= nil or value == nil then error("Duplicate or nil table entry", 0) end
							shape, keys = keyType, keys + 1
							if keyType == "number" then maximum = math.max(maximum, key) end
							tables[index][key] = value
						end
						if shape == "number" and keys ~= maximum then error("Sparse table arrays cannot be replayed", 0) end
						visiting[index], done[index] = nil, true
					end
					return tables[index]
				end
				error("Unsupported value: " .. tostring(kind), 0)
			end
			local result = { n = graph.count }
			for i = 1, graph.count do result[i] = decode(graph.slots[i], 0) end
			return result
		end
		local ok, value = pcall(work); if not ok then return nil, tostring(value) end; return value
	end
	function M.decodeNode(node) local result, why = M.decode({ count = 1, slots = { node }, nodes = {} }); if not result then return false, why end; return true, result[1] end
	function M.equal(a, b)
		if typeof(a) ~= typeof(b) then return false end
		if type(a) == "number" and a ~= a and b ~= b then return true end
		return a == b
	end
	function M.format(node)
		if not node then return "Unavailable" end
		if node.kind == "nil" then return "nil" end
		if node.kind == "table" then return "Table #" .. tostring(node.node) end
		if node.kind == "Instance" then return (node.name or "Instance") .. " · " .. tostring(node.instanceId) end
		if node.kind == "EnumItem" then return "Enum." .. tostring(node.enum) .. "." .. tostring(node.name) end
		if node.kind == "opaque" or node.kind == "truncated" then return node.kind .. ": " .. tostring(node.type or node.reason) end
		if node.kind == "string" then return util.ellipsis(node.encoding == "hex" and ("Binary: " .. node.value) or string.format("%q", node.value), 250) .. (node.truncated and " (truncated)" or "") end
		if node.components then local out = {}; for _, value in ipairs(node.components) do out[#out + 1] = tostring(value) end; return node.kind .. "(" .. table.concat(out, ", ") .. ")" end
		if node.keypoints then return node.kind .. " (" .. #node.keypoints .. " keypoints)" end
		return tostring(node.special or node.value)
	end
	function M.quote(text)
		return '"' .. (text:gsub('[%z\1-\31\127-\255\\"]', function(char)
			if char == '"' then return '\\"' elseif char == "\\" then return "\\\\" end
			return string.format("\\%03d", char:byte())
		end)) .. '"'
	end
	function M.portable(graph, remoteId, method)
		if method ~= "FireServer" and method ~= "InvokeServer" then return nil, "Only outgoing remote methods have portable scripts" end
		local decoded, why = M.decode(graph); if not decoded then return nil, why end
		local function path(key)
			local instance, err = refs.resolve(key); if not instance then error(err, 0) end
			local parts, node = {}, instance
			while node and node ~= game do
				if #parts >= 256 then error("Portable instance path exceeds 256 levels", 0) end
				local parent = node.Parent
				if parent then
					local found = 0; for _, child in ipairs(parent:GetChildren()) do if child.Name == node.Name then found = found + 1 end end
					if found ~= 1 then error("Ambiguous instance path; portable scripts require unique sibling names", 0) end
				end
				table.insert(parts, 1, M.quote(node.Name)); node = parent
			end
			if node ~= game then error("Detached Instances do not have a portable path", 0) end
			return "exact({" .. table.concat(parts, ", ") .. "}, " .. M.quote(instance.ClassName) .. ")"
		end
		local function numeric(n) return string.format("%.17g", n) end
		local encode
		encode = function(node)
			local kind = node.kind
			if kind == "nil" then return "nil" elseif kind == "boolean" then return tostring(node.value)
			elseif kind == "number" then return node.special == "-zero" and "(-1 / math.huge)" or numeric(node.value)
			elseif kind == "string" then return M.quote(node.encoding == "hex" and M.unhex(node.value) or node.value)
			elseif kind == "Instance" then return path(node.instanceId)
			elseif kind == "EnumItem" then return "Enum[" .. M.quote(node.enum) .. "][" .. M.quote(node.name) .. "]"
			elseif kind == "table" then return "tables[" .. node.node .. "]"
			elseif node.components then local parts = {}; for _, n in ipairs(node.components) do parts[#parts + 1] = numeric(n) end; return kind .. ".new(" .. table.concat(parts, ", ") .. ")"
			elseif kind == "BrickColor" then return "BrickColor.new(" .. numeric(node.value) .. ")"
			elseif kind == "buffer" then return "buffer.fromstring(" .. M.quote(M.unhex(node.value)) .. ")"
			elseif node.keypoints then
				local points = {}; for _, point in ipairs(node.keypoints) do points[#points + 1] = kind .. "Keypoint.new(" .. numeric(point.time) .. ", " .. encode(point.value) .. (kind == "NumberSequence" and (", " .. numeric(point.envelope or 0)) or "") .. ")" end
				return kind .. ".new({" .. table.concat(points, ", ") .. "})"
			end
			error("Unsupported portable value", 0)
		end
		local ok, source = pcall(function()
			local out = { "-- Portable path-based export. Object identity is revalidated in this place.",
				"local function exact(names, class)", "  local node = game", "  for _, name in ipairs(names) do", "    local found",
				"    for _, child in ipairs(node:GetChildren()) do", "      if child.Name == name then assert(not found, 'Ambiguous path'); found = child end", "    end",
				"    assert(found, 'Missing path segment: ' .. name); node = found", "  end", "  assert(node.ClassName == class, 'Class changed'); return node", "end", "local tables = {}" }
			for i = 1, #(graph.nodes or {}) do out[#out + 1] = "tables[" .. i .. "] = {}" end
			for i, node in ipairs(graph.nodes or {}) do for _, entry in ipairs(node.entries) do out[#out + 1] = "tables[" .. i .. "][" .. encode(entry.key) .. "] = " .. encode(entry.value) end end
			out[#out + 1] = "local args = { n = " .. graph.count .. " }"
			for i, node in ipairs(graph.slots) do out[#out + 1] = "args[" .. i .. "] = " .. encode(node) end
			out[#out + 1] = "local remote = " .. path(remoteId)
			out[#out + 1] = "return remote:" .. method .. "(unpack(args, 1, args.n))"
			return table.concat(out, "\n") .. "\n"
		end)
		if not ok then return nil, tostring(source) end; return source
	end
	function M.validateGraph(graph)
		local function array(v, max) return type(v) == "table" and getmetatable(v) == nil and util.isArray(v) and #v <= max end
		local function integer(n, max) return finite(n) and n >= 0 and n == math.floor(n) and n <= max end
		local function text(v, max) return type(v) == "string" and #v <= max and util.validUtf8(v) end
		if type(graph) ~= "table" or getmetatable(graph) ~= nil or not integer(graph.count, 256) or not array(graph.slots, 256) or #graph.slots ~= graph.count or not array(graph.nodes or {}, 256) then return false, "Invalid graph envelope" end
		local graphKeys = { count = true, slots = true, nodes = true, complete = true, reasons = true, bytes = true, originalCount = true }
		for key in pairs(graph) do if not graphKeys[key] then return false, "Unknown graph metadata" end end
		if graph.complete ~= nil and type(graph.complete) ~= "boolean" then return false, "Invalid completeness" end
		if graph.originalCount ~= nil and (not integer(graph.originalCount, 1e9) or graph.originalCount < graph.count) then return false, "Invalid original arity" end
		if graph.bytes ~= nil and not integer(graph.bytes, 131072) then return false, "Invalid retained byte count" end
		if graph.reasons then if not array(graph.reasons, 8) then return false, "Invalid omission reasons" end; for _, reason in ipairs(graph.reasons) do if not text(reason, 256) then return false, "Invalid omission reason" end end end
		local count = 0
		local allowed = { ["nil"] = true, boolean = true, number = true, string = true, Instance = true, EnumItem = true, table = true, opaque = true, truncated = true, buffer = true, BrickColor = true, NumberSequence = true, ColorSequence = true }
		local function check(node, depth)
			count = count + 1
			if count > 1024 or depth > 12 or type(node) ~= "table" or getmetatable(node) ~= nil or (not allowed[node.kind] and not sizes[node.kind]) then return false end
			local nodeKeys = { kind = true, value = true, special = true, encoding = true, length = true, truncated = true, instanceId = true, name = true, className = true, path = true, enum = true, node = true, components = true, keypoints = true, reason = true, type = true }
			for key in pairs(node) do if not nodeKeys[key] then return false end end
			if node.truncated ~= nil and type(node.truncated) ~= "boolean" then return false end
			if node.reason and not text(node.reason, 256) then return false end
			if node.type and not text(node.type, 100) then return false end
			if node.kind == "boolean" and type(node.value) ~= "boolean" then return false end
			if node.kind == "number" then
				if node.special then if node.value ~= nil or (node.special ~= "nan" and node.special ~= "infinity" and node.special ~= "-infinity" and node.special ~= "-zero") then return false end
				elseif not finite(node.value) then return false end
			end
			if node.kind == "BrickColor" and not integer(node.value, 65535) then return false end
			if node.kind == "Instance" and (not text(node.instanceId, 160) or (node.name and not text(node.name, 160)) or (node.className and not text(node.className, 100)) or (node.path and not text(node.path, 512))) then return false end
			if node.kind == "EnumItem" and (not text(node.enum, 100) or not text(node.name, 100)) then return false end
			if sizes[node.kind] then
				if not array(node.components, 12) or #node.components ~= sizes[node.kind] then return false end
				for _, component in ipairs(node.components) do if not finite(component) then return false end end
			end
			if node.kind == "table" and (not finite(node.node) or node.node ~= math.floor(node.node) or not (graph.nodes or {})[node.node]) then return false end
			if node.kind == "string" or node.kind == "buffer" then
				if type(node.value) ~= "string" or #node.value > 32768 or (node.encoding ~= nil and node.encoding ~= "utf8" and node.encoding ~= "hex") then return false end
				if node.encoding == "hex" then if #node.value % 2 ~= 0 or node.value:find("[^%x]") then return false end
				elseif not util.validUtf8(node.value) or #node.value > 16384 or node.kind == "buffer" then return false end
				local length = node.encoding == "hex" and #node.value / 2 or #node.value
				if node.length ~= nil and (not integer(node.length, 1e12) or node.length < length or (not node.truncated and node.length ~= length)) then return false end
			end
			if node.kind == "NumberSequence" or node.kind == "ColorSequence" then
				if not array(node.keypoints, 64) or #node.keypoints < 2 then return false end
				local previous = -1
				for i, point in ipairs(node.keypoints) do
					if type(point) ~= "table" or not finite(point.time) or point.time <= previous or point.time > 1 or (i == 1 and point.time ~= 0) or (i == #node.keypoints and point.time ~= 1) or (point.envelope and (not finite(point.envelope) or point.envelope < 0)) or not check(point.value, depth + 1) then return false end
					for key in pairs(point) do if key ~= "time" and key ~= "value" and key ~= "envelope" then return false end end
					previous = point.time
				end
			end
			return true
		end
		for _, node in ipairs(graph.slots) do if not check(node, 0) then return false, "Invalid value node" end end
		for index, node in ipairs(graph.nodes or {}) do
			if type(node) ~= "table" or not array(node.entries, 1024) or (node.id ~= nil and node.id ~= index) or (node.truncated ~= nil and type(node.truncated) ~= "boolean") then return false, "Invalid table node" end
			for key in pairs(node) do if key ~= "id" and key ~= "entries" and key ~= "truncated" then return false, "Unknown table metadata" end end
			for _, entry in ipairs(node.entries) do if type(entry) ~= "table" or not check(entry.key, 1) or not check(entry.value, 1) then return false, "Invalid graph entry" end end
		end
		local ok, encoded = pcall(util.encode, graph); return ok and #encoded <= 131072, "Graph exceeds encoded budget"
	end
	return M
end
