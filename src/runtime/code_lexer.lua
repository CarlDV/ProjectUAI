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
		local eq = text:sub(at):match("^%[(=*)%[")
		return eq and ("]" .. eq .. "]"), eq and (#eq + 2)
	end
	function M.line(text, state)
		state = state or ""
		local spans, i = {}, 1
		local function add(kind, a, b) spans[#spans + 1] = { kind = kind, first = a, last = b }; i = b + 1 end
		while i <= #text do
			if state ~= "" then
				local kind, close = state:sub(1, 1) == "c" and "comment" or "string", state:sub(2)
				local stop = text:find(close, i, true)
				add(kind, i, stop and (stop + #close - 1) or #text)
				if stop then state = "" end
			else
				local char, rest = text:sub(i, i), text:sub(i)
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
					local word = rest:match("^[%a_][%w_]*")
					add(keywords[word] and "keyword" or "text", i, i + #word - 1)
				elseif char:match("%d") or rest:match("^%.%d") then
					local number = rest:match("^0[xX][%x_]+%.?[%x_]*[pP][%+%-]?[%d_]+") or rest:match("^0[xX][%x_]+")
						or rest:match("^0[bB][01_]+") or rest:match("^%d[%d_]*%.?[%d_]*[eE][%+%-]?[%d_]+")
						or rest:match("^%.%d[%d_]*") or rest:match("^%d[%d_]*%.?[%d_]*")
					if number:sub(-1) == "." and rest:sub(#number + 1, #number + 1) == "." then number = number:sub(1, -2) end
					add("number", i, i + #number - 1)
				else add("text", i, i) end
			end
		end
		return spans, state
	end
	function M.scan(source, previous)
		local lines, starts = M.lines(source)
		local result = { lines = lines, starts = starts, spans = {}, states = {} }
		local state = ""
		for i, line in ipairs(lines) do
			if previous and previous.lines[i] == line and (i == 1 or previous.states[i - 1] == state) then
				result.spans[i], state = previous.spans[i], previous.states[i]
			else result.spans[i], state = M.line(line, state) end
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
	return M
end
