return function(env)
	local Window = env.require("window")
	for name, method in pairs(env.require("config")) do Window[name] = method end
	local UI = { Version = env.metadata.version, URL = env.metadata.url, Repository = env.metadata.repository }
	function UI:CreateWindow(options) return Window.new(options) end
	function UI:GetWindow(id) return env.windows[id] end
	function UI:DestroyAll()
		local windows = {}
		for _, window in pairs(env.windows) do windows[#windows + 1] = window end
		for _, window in ipairs(windows) do window:Destroy() end
	end
	return UI
end
