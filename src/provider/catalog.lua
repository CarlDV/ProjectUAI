-- Built-in provider presets.
--
-- A preset is a base URL and an auth style, nothing more. It deliberately does not
-- carry a model list: the only authority on which models an endpoint serves is the
-- endpoint, so models come from GET /v1/models or from the user typing one in. A
-- hardcoded list goes stale, and offering a model the provider does not have wastes
-- a turn on a 404 that looks like a bug.
return function(env)
	local M = {}

	-- authStyle: bearer | x-api-key | api-key | both | none
	--   both sends Authorization and x-api-key together, which is what several
	--   self-hosted relays expect and what the reference client did unconditionally.
	-- requires: "executor" marks an endpoint a vanilla client cannot reach --
	--   RequestAsync refuses loopback and private addresses.
	M.presets = {
		{
			id = "openai",
			label = "OpenAI",
			baseUrl = "https://api.openai.com/v1",
			authStyle = "bearer",
			keyHint = "sk-...",
			docs = "https://platform.openai.com/api-keys",
		},
		{
			id = "openrouter",
			label = "OpenRouter",
			baseUrl = "https://openrouter.ai/api/v1",
			authStyle = "bearer",
			keyHint = "sk-or-...",
			docs = "https://openrouter.ai/keys",
			-- OpenRouter reads both of these for attribution, and sending only one of
			-- them is a shape no real client produces.
			headers = {
				["X-Title"] = "Project UAI",
				["HTTP-Referer"] = "https://github.com/CarlDV/ProjectUAI",
			},
			note = "Lists several hundred models. Fetch them and pick, or type the id shown on openrouter.ai.",
		},
		{
			id = "anthropic",
			label = "Anthropic (OpenAI-compatible)",
			baseUrl = "https://api.anthropic.com/v1",
			authStyle = "x-api-key",
			keyHint = "sk-ant-...",
			docs = "https://console.anthropic.com/settings/keys",
			-- The compatibility route wants the version header; it is harmless
			-- elsewhere but only defaulted on here.
			headers = { ["anthropic-version"] = "2023-06-01" },
			note = "Anthropic's OpenAI-compatible endpoint. Tool calling works; some sampling fields are ignored.",
		},
		{
			id = "groq",
			label = "Groq",
			baseUrl = "https://api.groq.com/openai/v1",
			authStyle = "bearer",
			keyHint = "gsk_...",
			docs = "https://console.groq.com/keys",
		},
		{
			id = "deepseek",
			label = "DeepSeek",
			baseUrl = "https://api.deepseek.com/v1",
			authStyle = "bearer",
			keyHint = "sk-...",
			docs = "https://platform.deepseek.com/api_keys",
			note = "Reasoning models here stream their chain of thought as reasoning_content, which the transcript shows separately.",
		},
		{
			id = "together",
			label = "Together AI",
			baseUrl = "https://api.together.xyz/v1",
			authStyle = "bearer",
			docs = "https://api.together.ai/settings/api-keys",
		},
		{
			id = "mistral",
			label = "Mistral",
			baseUrl = "https://api.mistral.ai/v1",
			authStyle = "bearer",
			docs = "https://console.mistral.ai/api-keys",
		},
		{
			id = "xai",
			label = "xAI",
			baseUrl = "https://api.x.ai/v1",
			authStyle = "bearer",
			keyHint = "xai-...",
			docs = "https://console.x.ai",
		},
		{
			id = "fireworks",
			label = "Fireworks",
			baseUrl = "https://api.fireworks.ai/inference/v1",
			authStyle = "bearer",
			docs = "https://fireworks.ai/api-keys",
		},
		{
			id = "cerebras",
			label = "Cerebras",
			baseUrl = "https://api.cerebras.ai/v1",
			authStyle = "bearer",
			docs = "https://cloud.cerebras.ai",
		},
		{
			id = "azure",
			label = "Azure OpenAI",
			baseUrl = "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT",
			authStyle = "api-key",
			docs = "https://learn.microsoft.com/azure/ai-services/openai/",
			query = { ["api-version"] = "2024-10-21" },
			note = "The base URL must include the deployment path. Azure takes the model from the deployment, so the model field is not sent.",
		},
		{
			id = "ollama",
			label = "Ollama (local)",
			baseUrl = "http://127.0.0.1:11434/v1",
			authStyle = "none",
			requires = "executor",
			note = "Loopback is unreachable from a vanilla client; this needs an executor HTTP function. Fetching models lists whatever you have pulled.",
		},
		{
			id = "lmstudio",
			label = "LM Studio (local)",
			baseUrl = "http://127.0.0.1:1234/v1",
			authStyle = "none",
			requires = "executor",
			note = "Start the LM Studio server first, then fetch models.",
		},
		{
			id = "vllm",
			label = "vLLM / self-hosted",
			baseUrl = "http://127.0.0.1:8000/v1",
			authStyle = "bearer",
			requires = "executor",
		},
		{
			id = "custom",
			label = "Custom endpoint",
			baseUrl = "",
			authStyle = "bearer",
			note = "Any OpenAI-compatible /v1/chat/completions endpoint.",
		},
	}

	function M.get(id)
		for _, preset in ipairs(M.presets) do
			if preset.id == id then return preset end
		end
		return nil
	end

	function M.ids()
		local out = {}
		for _, preset in ipairs(M.presets) do out[#out + 1] = preset.id end
		return out
	end

	return M
end
