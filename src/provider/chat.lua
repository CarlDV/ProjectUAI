-- Picks the wire protocol for a provider record.
--
-- Two adapters implement the same contract -- provider/openai for anything speaking
-- /chat/completions, provider/anthropic for the Messages API -- and this is the only
-- place that decides which one a record uses. Everything above it (the agent loop,
-- the transcript, the connection test) is written against one shape and does not
-- know there is a choice.
--
-- `record.api` is the switch. It is absent on every record saved before the second
-- adapter existed, and absent means OpenAI, so nothing needs migrating.
return function(env)
	local M = {}

	M.STYLES = {
		{ value = "openai", label = "Chat completions" },
		{ value = "anthropic", label = "Anthropic messages" },
	}

	function M.styleOf(record)
		return (tostring(record and record.api or "openai") == "anthropic")
			and "anthropic" or "openai"
	end

	function M.adapterFor(record)
		if M.styleOf(record) == "anthropic" then
			return env.require("provider/anthropic")
		end
		return env.require("provider/openai")
	end

	function M.complete(record, request)
		return M.adapterFor(record).complete(record, request)
	end

	function M.errorText(record, res, err)
		return M.adapterFor(record).errorText(res, err)
	end

	-- The headers a record's requests carry, including the ones its wire protocol
	-- requires. Model discovery hits the same host, so it asks for these too rather
	-- than assembling auth itself and getting the Anthropic case wrong.
	function M.headers(record)
		local adapter = M.adapterFor(record)
		if adapter.headers then return adapter.headers(record) end
		local headers = env.require("provider/registry").authHeaders(record)
		for key, value in pairs(record.headers or {}) do headers[key] = value end
		return headers
	end

	-- The path a record's completions go to, for the Providers panel to show.
	function M.endpointOf(record)
		local adapter = M.adapterFor(record)
		if adapter.endpoint then return adapter.endpoint(record) end
		return env.require("provider/registry").endpoint(record, "/chat/completions")
	end

	return M
end
