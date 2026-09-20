-- Markdown skills, as tools: list, read, write, install from GitHub.
--
-- These are the agent's half of the skills engine. The other half is the
-- environment block, which carries only the index -- names and one-line
-- descriptions. The model must use skills_read to fetch every enabled body
-- before replying in each conversation; both the inventory and bodies paginate.
--
-- Reading is risk "read"; writing, deleting and installing are "write", so
-- each passes the permission prompt -- an installed playbook is instructions
-- the model will follow, which is exactly what the prompt exists to gate.
return function(env)
	local util = env.require("runtime/util")
	local H = env.require("tools/helpers")
	local skills = env.require("runtime/skills")

	return {
		{
			name = "skills_list",
			risk = "read",
			needs = { "fs" },
			description = "List the installed markdown skills (playbooks) with their one-line "
				.. "descriptions and whether each is enabled. The same list appears in the "
				.. "environment block each turn; use this to refresh the inventory, including "
				.. "switched-off ones. Follow continuation offsets to see every entry.",
			parameters = { type = "object", properties = {
				offset = { type = "integer", description = "1-based byte offset from a previous page. Default 1.", minimum = 1 },
				limit = { type = "integer", description = "Maximum bytes in this inventory page.", minimum = 200, maximum = 64000 },
			}, required = {} },
			run = function(args)
				local list = skills.list()
				if #list == 0 then
					return "No skills installed. Skills are .md files under skills/ -- drop one "
						.. "in by hand, or install one with skills_install."
				end
				local lines = {}
				for _, skill in ipairs(list) do
					local label = skill.name .. " [" .. skill.file .. "]"
					if skill.description ~= "" then
						label = label .. " -- " .. util.ellipsis(skill.description, 90)
					end
					if not skill.enabled then
						label = label .. " [off]"
					end
					lines[#lines + 1] = label
				end
				return H.readSlice(string.format("%d skill%s", #list, #list == 1 and "" or "s"),
					H.list(lines), args, 6000)
			end,
		},
		{
			name = "skills_read",
			risk = "read",
			needs = { "fs" },
			description = "Read a skill's body. REQUIRED FIRST in every conversation, before replying "
				.. "or other actions: read EVERY enabled skill, including in subagent conversations. "
				.. "Follow continuation offsets until each body is fully read; descriptions are not bodies.",
			parameters = {
				type = "object",
				properties = {
					name = { type = "string", description = "The skill's name or filename, e.g. 'Ponytail' or 'ponytail.md'." },
					offset = { type = "integer", description = "1-based byte offset from a previous page. Default 1.", minimum = 1 },
					limit = { type = "integer", description = "Maximum bytes of body. Default 12000, bounded by the tool result budget.", minimum = 200, maximum = 64000 },
				},
				required = { "name" },
			},
			run = function(args)
				local body, skill = skills.readBody(args.name)
				if body == nil then return H.fail(skill) end
				return H.readSlice(skill.name .. " [" .. skill.file .. "]", body, args, skills.READ_CAP)
			end,
		},
		{
			name = "skills_write",
			risk = "write",
			needs = { "fs" },
			description = "Save a skill: a named playbook with a one-line description and a markdown "
				.. "body. Overwrites an existing skill of the same name. Use it when the user asks "
				.. "to keep a working approach -- 'save that as a skill' -- or when you worked "
				.. "something out that a later session will need again.",
			parameters = {
				type = "object",
				properties = {
					name = { type = "string", description = "Short name, e.g. 'Ponytail'. Becomes the filename." },
					description = { type = "string", description = "One line, written to be matched against a task: what the skill is for." },
					body = { type = "string", description = "The playbook: instructions, rules, code patterns, in markdown." },
				},
				required = { "name", "description", "body" },
			},
			run = function(args)
				local name = util.trim(tostring(args.name or ""))
				if name == "" then return H.fail("no name given") end
				if util.trim(tostring(args.body or "")) == "" then return H.fail("the body is empty") end
				local ok, result = skills.save(name, args.description, args.body)
				if not ok then return H.fail(result) end
				return "Saved skill " .. result
					.. ". It appears in the environment block from the next turn."
			end,
		},
		{
			name = "skills_install",
			risk = "write",
			needs = { "http", "fs" },
			description = "Install a skill from GitHub: give owner/repo (e.g. 'DietrichGebert/ponytail'), "
				.. "a github.com URL, or a raw.githubusercontent.com URL. The .md is fetched, given "
				.. "proper frontmatter if it lacks it, and saved into skills/.",
			parameters = {
				type = "object",
				properties = {
					repo = { type = "string", description = "owner/repo, or a GitHub or raw URL to the .md file." },
					path = { type = "string", description = "Path to the file inside the repo, when it is not the default SKILL.md. Leading slash optional." },
				},
				required = { "repo" },
			},
			run = function(args)
				local path = util.trim(tostring(args.path or ""))
				if path ~= "" and path:sub(1, 1) == "/" then path = path:sub(2) end
				local ok, result = skills.fromGitHub(args.repo, path)
				if not ok then return H.fail(result) end
				return "Installed skill " .. result
					.. ". Read it with skills_read before following it -- it is a "
					.. "stranger's instructions until you have seen what they say."
			end,
		},
		{
			name = "skills_delete",
			risk = "write",
			needs = { "fs" },
			description = "Delete a skill file. Its entry leaves the environment block from the next turn.",
			parameters = {
				type = "object",
				properties = {
					name = { type = "string", description = "The skill's name or filename." },
				},
				required = { "name" },
			},
			run = function(args)
				local ok, result = skills.remove(args.name)
				if not ok then return H.fail(result) end
				return "Deleted " .. result
			end,
		},
	}
end
