-- Markdown skills, as tools: list, read, write, install from GitHub.
--
-- These are the agent's half of the skills engine. The other half is the
-- environment block, which carries only the index -- names and one-line
-- descriptions -- so the model can tell a playbook exists without paying for
-- its body. When a task matches a description, `skills_read` is the one call
-- that brings the playbook in.
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
				.. "environment block each turn; use this when you want the full set including "
				.. "switched-off ones.",
			parameters = { type = "object", properties = util.emptyObject(), required = {} },
			run = function()
				local list = skills.list()
				if #list == 0 then
					return "No skills installed. Skills are .md files under skills/ -- drop one "
						.. "in by hand, or install one with skills_install."
				end
				local lines = {}
				for _, skill in ipairs(list) do
					local label = skill.name
					if skill.description ~= "" then
						label = label .. " -- " .. util.ellipsis(skill.description, 90)
					end
					if not skill.enabled then
						label = label .. " [off]"
					end
					lines[#lines + 1] = label
				end
				return string.format("%d skill%s:\n%s", #list, #list == 1 and "" or "s",
					H.list(lines, 40))
			end,
		},
		{
			name = "skills_read",
			risk = "read",
			needs = { "fs" },
			description = "Read the full body of a skill -- the playbook itself. Call this when a "
				.. "task matches a skill's description in the environment block; the body is "
				.. "never sent otherwise, which is what keeps the system prompt lean.",
			parameters = {
				type = "object",
				properties = {
					name = { type = "string", description = "The skill's name or filename, e.g. 'Ponytail' or 'ponytail.md'." },
					limit = { type = "integer", description = "Maximum characters of body. Default 12000.", minimum = 200, maximum = 64000 },
				},
				required = { "name" },
			},
			run = function(args)
				local text, err = skills.read(args.name, args.limit)
				if not text then return H.fail(err) end
				return text
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
