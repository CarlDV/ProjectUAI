-- Collects the tool groups.
--
-- Adding a group is one entry in GROUPS. Each group module returns a flat list of
-- tool definitions; the registry above turns them into a name map and the wire
-- format. A group that fails to load is skipped with a warning rather than taking
-- the client down -- a broken tool should cost one capability, not the session.
local GROUPS = {
	"agentself",
	"instance",
	"script",
	-- Archived: the shared code editor's tool set. The tools themselves live on in
	-- archive/coding_tools.lua, but the editor panel they target is disconnected
	-- while its rendering is reworked, so the agent is not offered tools that write
	-- to a surface the user cannot see. Restore this entry with the panel.
	-- "coding",
	"fs",
	"net",
	"web",
	"players",
	"character",
	"world",
	"remotes",
	"gui",
	"perf",
	"meta",
	"chat",
	"input",
	"templates",
	"screen",
	"iy",
	"skills",
}

return function(env)
	local log = env.require("runtime/log")

	local M = { groups = GROUPS }

	function M.all()
		local out = {}
		for _, group in ipairs(GROUPS) do
			local ok, tools = pcall(env.require, "tools/" .. group)
			if not ok then
				log.error("tools", "group '" .. group .. "' failed to load", tools)
			elseif type(tools) ~= "table" then
				log.warn("tools", "group '" .. group .. "' returned no tools")
			else
				for _, tool in ipairs(tools) do
					tool.group = tool.group or group
					out[#out + 1] = tool
				end
			end
		end
		return out
	end

	return M
end
