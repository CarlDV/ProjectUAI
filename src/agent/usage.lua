-- Token and cost accounting.
--
-- Providers report usage inconsistently -- some only in a streamed final chunk,
-- some not at all -- so counts are taken from the response when present and
-- estimated when not, and an estimated figure is always labelled as one. Prices
-- are a convenience, not an invoice: they are per million tokens, they date from
-- when this was written, and the panel says so.
return function(env)
	local util = env.require("runtime/util")
	local signal = env.require("runtime/signal")

	local M = {
		session = { prompt = 0, completion = 0, total = 0, cost = 0, requests = 0, estimated = false },
		turn = { prompt = 0, completion = 0, total = 0, cost = 0 },
		changed = signal.new("usage"),
		-- One request, as it was measured, rather than the running totals `changed`
		-- carries. This is the only place in the client where a model id and the tokens
		-- it actually spent are in scope together, so anything keeping a per-model
		-- history has to hear about it here.
		recorded = signal.new("usage:recorded"),
	}

	-- input, output per million tokens. Matched longest-prefix, so a dated model
	-- id still resolves.
	--
	-- The current Claude generations are listed individually because the family
	-- names no longer predict the price: an Opus has cost $5/$25 since 4.6, a third
	-- of what the 4.5-and-earlier line did, and reporting the old number made every
	-- turn in this client look three times more expensive than it was.
	local PRICES = {
		["gpt-4o-mini"] = { 0.15, 0.60 },
		["gpt-4o"] = { 2.50, 10.00 },
		["gpt-4.1-mini"] = { 0.40, 1.60 },
		["gpt-4.1"] = { 2.00, 8.00 },
		["o4-mini"] = { 1.10, 4.40 },
		["claude-haiku"] = { 1.00, 5.00 },
		["claude-sonnet"] = { 3.00, 15.00 },
		["claude-sonnet-5"] = { 2.00, 10.00 },
		["claude-opus"] = { 15.00, 75.00 },
		["claude-opus-4-6"] = { 5.00, 25.00 },
		["claude-opus-4-7"] = { 5.00, 25.00 },
		["claude-opus-4-8"] = { 5.00, 25.00 },
		["claude-opus-5"] = { 5.00, 25.00 },
		-- Covers the .1 revisions too: the id is a superstring of this prefix.
		["claude-fable-5"] = { 10.00, 50.00 },
		["claude-mythos-5"] = { 10.00, 50.00 },
		["deepseek-reasoner"] = { 0.55, 2.19 },
		["deepseek-chat"] = { 0.27, 1.10 },
		["llama-3.3-70b"] = { 0.59, 0.79 },
		["llama-3.1-8b"] = { 0.05, 0.08 },
		["mistral-large"] = { 2.00, 6.00 },
		["mistral-small"] = { 0.20, 0.60 },
		["grok-4"] = { 3.00, 15.00 },
		["grok-3-mini"] = { 0.30, 0.50 },
		["qwen"] = { 0.40, 0.80 },
		["gemini-2.5-flash"] = { 0.30, 2.50 },
	}

	function M.priceFor(model)
		local id = tostring(model or ""):lower()
		local best, bestLength = nil, 0
		for prefix, price in pairs(PRICES) do
			if id:find(prefix, 1, true) and #prefix > bestLength then
				best, bestLength = price, #prefix
			end
		end
		return best
	end

	-- Four characters per token is the usual English approximation; it is within
	-- about ten percent for prose and pessimistic for code, which is the right
	-- direction for a context budget.
	function M.estimateText(text)
		if type(text) ~= "string" then return 0 end
		return math.ceil(#text / 4)
	end

	function M.estimateMessages(messages)
		local total = 0
		for _, message in ipairs(messages or {}) do
			-- Per-message framing overhead, plus the role name.
			total = total + 4 + M.estimateText(message.content)
			-- Internal messages carry toolCalls; wire messages carry tool_calls, and
			-- the loop estimates over the wire form.
			for _, call in ipairs(message.toolCalls or message.tool_calls or {}) do
				local fn = call["function"] or {}
				total = total + 8 + M.estimateText(fn.name) + M.estimateText(fn.arguments)
			end
		end
		return total
	end

	function M.startTurn()
		M.turn = { prompt = 0, completion = 0, total = 0, cost = 0 }
	end

	-- `usage` is the provider block when it exists. `fallback` supplies estimates
	-- so a provider that reports nothing still moves the counters.
	function M.record(usage, model, fallback)
		local prompt, completion, estimated
		if type(usage) == "table" and (usage.prompt_tokens or usage.completion_tokens) then
			prompt = tonumber(usage.prompt_tokens) or 0
			completion = tonumber(usage.completion_tokens) or 0
			estimated = false
		else
			prompt = (fallback and fallback.prompt) or 0
			completion = (fallback and fallback.completion) or 0
			estimated = true
		end

		local price = M.priceFor(model)
		local cost = 0
		if price then
			cost = (prompt / 1000000) * price[1] + (completion / 1000000) * price[2]
		end

		M.turn.prompt = M.turn.prompt + prompt
		M.turn.completion = M.turn.completion + completion
		M.turn.total = M.turn.prompt + M.turn.completion
		M.turn.cost = M.turn.cost + cost

		M.session.prompt = M.session.prompt + prompt
		M.session.completion = M.session.completion + completion
		M.session.total = M.session.prompt + M.session.completion
		M.session.cost = M.session.cost + cost
		M.session.requests = M.session.requests + 1
		if estimated then M.session.estimated = true end

		local cached = util.get(usage or {}, "prompt_tokens_details.cached_tokens", 0)
		local reasoning = util.get(usage or {}, "completion_tokens_details.reasoning_tokens", 0)
		M.session.cached = (M.session.cached or 0) + (tonumber(cached) or 0)
		M.session.reasoning = (M.session.reasoning or 0) + (tonumber(reasoning) or 0)

		local delta = {
			model = model,
			prompt = prompt,
			completion = completion,
			cost = cost,
			estimated = estimated,
			cached = tonumber(cached) or 0,
			reasoning = tonumber(reasoning) or 0,
		}
		M.recorded:fire(delta)
		M.changed:fire(M.session, M.turn)
		return { prompt = prompt, completion = completion, cost = cost, estimated = estimated }
	end

	function M.reset()
		M.session = { prompt = 0, completion = 0, total = 0, cost = 0, requests = 0, estimated = false }
		M.turn = { prompt = 0, completion = 0, total = 0, cost = 0 }
		M.changed:fire(M.session, M.turn)
	end

	function M.formatCost(value)
		if value <= 0 then return "" end
		if value < 0.01 then return string.format("$%.4f", value) end
		return string.format("$%.3f", value)
	end

	function M.line()
		local parts = {
			util.formatNumber(M.session.total) .. " tokens",
			util.formatNumber(M.session.prompt) .. " in",
			util.formatNumber(M.session.completion) .. " out",
		}
		local cost = M.formatCost(M.session.cost)
		if cost ~= "" then parts[#parts + 1] = cost .. (M.session.estimated and " est." or "") end
		return table.concat(parts, "  ")
	end

	return M
end
