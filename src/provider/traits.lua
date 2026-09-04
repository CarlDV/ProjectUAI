-- What a model accepts, and how much it can hold.
--
-- Every gateway claims to be OpenAI-compatible and none of them publishes
-- capabilities: /models returns ids, not limits. So the facts that change how a
-- request must be built live here, in one table, rather than being rediscovered
-- from a 400 at each call site.
--
-- Matched by longest substring, the same way `usage.priceFor` resolves a price,
-- because gateways prefix and suffix ids freely -- "anthropic/claude-opus-5",
-- "claude-opus-5-1m", a dated snapshot -- and an exact-match table would miss
-- every one of them. Only families this client has a documented fact about appear;
-- an unknown id resolves to an empty trait set, which means "behave as before".
return function(env)
	local M = {}

	-- context  the input window, in tokens.
	-- output   the ceiling on a single reply, in tokens.
	-- sampling false only where temperature/top_p/top_k are *rejected* rather than
	--          ignored. Absent means "send them", which is what every other model
	--          in this client has always had.
	-- effort   the levels `output_config.effort` accepts, cheapest first, or absent
	--          where the model has no effort control.
	-- thinking "adaptive" for models that reason without a token budget and take
	--          `{ type = "adaptive" }`; "budget" for the older shape that requires
	--          `budget_tokens`. Absent means the model does not expose reasoning.
	-- default  the effort level the API itself uses when none is sent, so the
	--          interface can mark it rather than implying the client picked it.
	local FIVE = { "low", "medium", "high", "xhigh", "max" }
	local FOUR = { "low", "medium", "high", "max" }

	local TRAITS = {
		["claude-fable-5-1"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high", alwaysThinks = true },
		["claude-mythos-5-1"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high", alwaysThinks = true },
		["claude-fable-5"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high", alwaysThinks = true },
		-- Opus 5 thinks by default, unlike 4.8 and 4.7, and refuses a disabled
		-- thinking block above effort "high".
		["claude-opus-5"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high" },
		["claude-opus-4-8"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high" },
		["claude-opus-4-7"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high" },
		-- 4.6 is the last generation that still takes sampling parameters, and its
		-- effort scale has no "xhigh".
		["claude-opus-4-6"] = { context = 1000000, output = 128000,
			effort = FOUR, thinking = "adaptive", default = "high" },
		["claude-sonnet-5"] = { context = 1000000, output = 128000, sampling = false,
			effort = FIVE, thinking = "adaptive", default = "high" },
		["claude-sonnet-4-6"] = { context = 1000000, output = 128000,
			effort = FOUR, thinking = "adaptive", default = "high" },
		["claude-haiku-4-5"] = { context = 200000 },
	}

	local EMPTY = {}

	function M.of(model)
		local id = tostring(model or ""):lower()
		if id == "" then return EMPTY end
		local best, bestLength = EMPTY, 0
		for prefix, traits in pairs(TRAITS) do
			if id:find(prefix, 1, true) and #prefix > bestLength then
				best, bestLength = traits, #prefix
			end
		end
		return best
	end

	function M.contextWindow(model)
		return M.of(model).context
	end

	function M.maxOutput(model)
		return M.of(model).output
	end

	-- True unless the model is documented to reject them. Withholding a parameter a
	-- model would have accepted changes behaviour for every gateway this client
	-- talks to, so silence is not the safe default here -- only a known refusal is.
	function M.allowsSampling(model)
		return M.of(model).sampling ~= false
	end

	function M.effortLevels(model)
		return M.of(model).effort
	end

	function M.defaultEffort(model)
		return M.of(model).default
	end

	-- The nearest level this model actually has, never rounding up: asking for
	-- "xhigh" on a scale that stops at "high" must land on "high" rather than
	-- spending "max", because the setting is a ceiling the user chose.
	local RANK = { low = 1, medium = 2, high = 3, xhigh = 4, max = 5 }

	function M.nearestEffort(model, wanted)
		local levels = M.effortLevels(model)
		if not levels then return nil end
		local target = RANK[tostring(wanted or ""):lower()]
		if not target then return nil end
		local best
		for _, level in ipairs(levels) do
			local rank = RANK[level]
			if rank == target then return level end
			if rank and rank < target and (not best or RANK[best] < rank) then best = level end
		end
		-- Every level this model has sits above what was asked for, so the cheapest
		-- of them is the closest thing to it.
		return best or levels[1]
	end

	function M.thinkingStyle(model)
		return M.of(model).thinking
	end

	function M.alwaysThinks(model)
		return M.of(model).alwaysThinks == true
	end

	-- A short badge for the model pickers: "1M", "200K". Nil when unknown, so a
	-- row for an id this table has never heard of simply has no badge.
	function M.badge(model)
		local context = M.contextWindow(model)
		if not context then return nil end
		if context >= 1000000 then
			local millions = context / 1000000
			return (millions % 1 == 0) and string.format("%dM", millions)
				or string.format("%.1fM", millions)
		end
		if context >= 1000 then return string.format("%dK", math.floor(context / 1000)) end
		return tostring(context)
	end

	M.TRAITS = TRAITS

	return M
end
