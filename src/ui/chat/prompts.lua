-- Shared starting points for the welcome screen and composer.
return function(env)
	local M = {}
	M.items = {
		{ id = "explore", icon = "search", label = "Explore this game", detail = "Find your bearings in the world.",
			text = "Explore this game. Inspect the workspace and tell me what is here, how it is organised, and what we could do next." },
		{ id = "build", icon = "code", label = "Create something", detail = "Turn an idea into a working script.",
			text = "Help me build a Luau script for this game. First inspect the relevant game context, then ask what I would like to create." },
		{ id = "diagnose", icon = "sliders", label = "Check performance", detail = "Understand FPS, memory, and latency.",
			text = "Check client performance, memory usage, and network latency. Explain the results and suggest practical improvements." },
		{ id = "character", icon = "circleHollow", label = "Inspect my character", detail = "See your character's current state.",
			text = "Inspect my character and explain its position, humanoid state, and any useful attributes or attached scripts." },
	}
	return M
end
