-- Line-state Luau lexer. Raw source is never rewritten by presentation.
return function(env)
	local M = {}
	local keywords = {}
	for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while continue export type typeof"):gmatch("%S+") do keywords[word] = true end
	function M.lines(source)
		local lines, starts, first = {}, {}, 1
		for line in (source .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1], starts[#starts + 1] = line, first
			first = first + #line + 1
		end
		return lines, starts
	end
	function M.escape(text) return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")) end
	local function longAt(text, at)
		local eq = text:match("^%[(=*)%[", at)
		return eq and ("]" .. eq .. "]"), eq and (#eq + 2)
	end
	function M.line(text, state)
		state = state or ""
		local spans, i = {}, 1
		local function add(kind, a, b)
			local previous = spans[#spans]
			if previous and previous.kind == kind and previous.last + 1 == a then previous.last = b
			else spans[#spans + 1] = { kind = kind, first = a, last = b } end
			i = b + 1
		end
		while i <= #text do
			if state ~= "" then
				local kind, close = state:sub(1, 1) == "c" and "comment" or "string", state:sub(2)
				local stop = text:find(close, i, true)
				add(kind, i, stop and (stop + #close - 1) or #text)
				if stop then state = "" end
			else
				local char, rest = text:sub(i, i), text:sub(i, i + 2)
				if rest:sub(1, 2) == "--" then
					local close, width = longAt(text, i + 2)
					if close then
						local stop = text:find(close, i + 2 + width, true)
						add("comment", i, stop and (stop + #close - 1) or #text)
						if not stop then state = "c" .. close end
					else add("comment", i, #text) end
				elseif char == '"' or char == "'" or char == string.char(96) then
					local j = i + 1
					while j <= #text do
						if text:sub(j, j) == "\\" then j = j + 2
						elseif text:sub(j, j) == char then j = j + 1; break
						else j = j + 1 end
					end
					add("string", i, math.min(#text, j - 1))
				elseif char == "[" and longAt(text, i) then
					local close, width = longAt(text, i)
					local stop = text:find(close, i + width, true)
					add("string", i, stop and (stop + #close - 1) or #text)
					if not stop then state = "s" .. close end
				elseif char:match("[%a_]") then
					local word = text:match("^[%a_][%w_]*", i)
					local call = text:match("^%s*%(", i + #word)
					add(keywords[word] and "keyword" or call and "call" or "text", i, i + #word - 1)
				elseif char:match("%d") or rest:match("^%.%d") then
					local number = text:match("^0[xX][%x_]+%.?[%x_]*[pP][%+%-]?[%d_]+", i) or text:match("^0[xX][%x_]+", i)
						or text:match("^0[bB][01_]+", i) or text:match("^%d[%d_]*%.?[%d_]*[eE][%+%-]?[%d_]+", i)
						or text:match("^%.%d[%d_]*", i) or text:match("^%d[%d_]*%.?[%d_]*", i)
					if number:sub(-1) == "." and text:sub(i + #number, i + #number) == "." then number = number:sub(1, -2) end
					add("number", i, i + #number - 1)
				else add("text", i, i) end
			end
		end
		return spans, state
	end
	function M.scan(source, previous)
		if previous and previous.source == source then return previous end
		local lines, starts = M.lines(source)
		local prefix, suffix = 0, 0
		if previous then
			while prefix < math.min(#lines, #previous.lines) and lines[prefix + 1] == previous.lines[prefix + 1] do prefix = prefix + 1 end
			while suffix < math.min(#lines, #previous.lines) - prefix and lines[#lines - suffix] == previous.lines[#previous.lines - suffix] do suffix = suffix + 1 end
		end
		local result = { source = source, lines = lines, starts = starts, spans = {}, states = {}, added = {}, removed = {}, lexed = 0, reused = 0 }
		for i = prefix + 1, #lines - suffix do result.added[#result.added + 1] = lines[i] end
		if previous then for i = prefix + 1, #previous.lines - suffix do result.removed[#result.removed + 1] = previous.lines[i] end end
		local state = ""
		for i, line in ipairs(lines) do
			local oldIndex = previous and (i <= prefix and i or i > #lines - suffix and i + #previous.lines - #lines or nil)
			if oldIndex and (oldIndex == 1 and "" or previous.states[oldIndex - 1]) == state then
				result.spans[i], state = previous.spans[oldIndex], previous.states[oldIndex]; result.reused = result.reused + 1
			else result.spans[i], state = M.line(line, state); result.lexed = result.lexed + 1 end
			result.states[i] = state
		end
		return result
	end
	function M.rich(line, spans, colors)
		local result = {}
		for _, span in ipairs(spans) do
			local text, color = M.escape(line:sub(span.first, span.last)), colors[span.kind]
			result[#result + 1] = color and ('<font color="' .. color .. '">' .. text .. '</font>') or text
		end
		return table.concat(result)
	end
	function M.highlight(source, colors, previous)
		local scanned, out = M.scan(source, previous), {}
		for i, line in ipairs(scanned.lines) do out[i] = M.rich(line, scanned.spans[i], colors) end
		return table.concat(out, "\n"), scanned
	end
	function M.richWindow(line, spans, colors, first, last)
		local clipped = {}
		for _, span in ipairs(spans) do
			if span.first > last then break end
			if span.last >= first then clipped[#clipped + 1] = { kind = span.kind, first = math.max(first, span.first) - first + 1, last = math.min(last, span.last) - first + 1 } end
		end
		return M.rich(line:sub(first, last), clipped, colors)
	end
	return M
end
