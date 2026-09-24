-- Bounded line LCS after stripping common edges. Large changes are exact replacements.
return function(env)
	local lexer = env.require("runtime/code_lexer")
	local M = { CELLS = 100000 }
	function M.compare(before, after)
		local a, b = lexer.lines(before), lexer.lines(after)
		local result = { before = before, after = after, rows = {}, hunks = {}, added = 0, removed = 0, replacement = false }
		if before == after then return result end
		local first, lastA, lastB = 1, #a, #b
		while first <= lastA and first <= lastB and a[first] == b[first] do first = first + 1 end
		while lastA >= first and lastB >= first and a[lastA] == b[lastB] do lastA, lastB = lastA - 1, lastB - 1 end
		local function row(kind, old, new, text)
			result.rows[#result.rows + 1] = { kind = kind, oldLine = old, newLine = new, text = text }
			if kind == "add" then result.added = result.added + 1 elseif kind == "remove" then result.removed = result.removed + 1 end
		end
		for i = 1, first - 1 do row("same", i, i, a[i]) end
		if (lastA - first + 1) * (lastB - first + 1) > M.CELLS then
			result.replacement = true
			for i = first, lastA do row("remove", i, nil, a[i]) end
			for j = first, lastB do row("add", nil, j, b[j]) end
		else
			local dp = {}; dp[lastA + 1] = {}
			for i = lastA, first, -1 do
				dp[i] = {}
				for j = lastB, first, -1 do
					dp[i][j] = a[i] == b[j] and ((dp[i + 1][j + 1] or 0) + 1) or math.max(dp[i + 1][j] or 0, dp[i][j + 1] or 0)
				end
			end
			local i, j = first, first
			while i <= lastA or j <= lastB do
				if i <= lastA and j <= lastB and a[i] == b[j] then row("same", i, j, a[i]); i, j = i + 1, j + 1
				elseif i <= lastA and (j > lastB or (dp[i + 1][j] or 0) >= (dp[i][j + 1] or 0)) then row("remove", i, nil, a[i]); i = i + 1
				else row("add", nil, j, b[j]); j = j + 1 end
			end
		end
		for i = lastA + 1, #a do row("same", i, lastB + i - lastA, a[i]) end
		local hunk
		for index, item in ipairs(result.rows) do
			if item.kind == "same" then hunk = nil
			else
				if not hunk then hunk = { first = index, last = index }; result.hunks[#result.hunks + 1] = hunk end
				hunk.last = index
			end
		end
		return result
	end
	return M
end
