-- Markdown skills: Claude Code / Anthropic-style .md playbooks, on demand.
--
-- A skill is a frontmatter header and a body of instructions. The header is
-- one line of description; the body can be anything from a rule of thumb to a
-- whole playbook of Luau patterns. They live as plain .md files under
-- skills/ in the app folder, so a user can drop one in by hand and an agent
-- can write one with the file functions -- both paths converge here.
--
-- The one rule the engine enforces on itself: NOTHING is injected into the
-- system prompt. The environment block carries a list of names and one-line
-- descriptions only -- a few tokens each -- and the body is fetched by a tool
-- call when a task actually matches its description. A two-hundred-line GUI
-- playbook costs zero context until the day it is needed, and then it costs
-- exactly one tool call.
--
-- Frontmatter is the same shape Claude Code uses, so a repo of existing
-- playbooks is usable without conversion:
--
--   ---
--   name: Ponytail
--   description: Senior developer mindset. Prevents over-engineering.
--   ---
--   [body]
--
-- `name` is optional -- the filename is the fallback. Text before the opening
-- marker is ignored; anything after the closing marker is the body.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local config = env.require("runtime/config")
	local signal = env.require("runtime/signal")

	local READ_CAP = 12000

	local M = {
		changed = signal.new("skills"),
	}

	local DIR = { scope = "skills" }

	-- Frontmatter ------------------------------------------------------------

	-- Pulls the `key: value` pairs out of a leading --- block. Lenient by
	-- design: these files are written by people and by models, and a malformed
	-- header should cost the description, not the whole skill. Returns the
	-- parsed header and the body -- everything after the closing marker, or
	-- the whole text when there is no frontmatter at all.
	local function parseFrontmatter(text)
		local source = tostring(text or ""):gsub("^\u{FEFF}", "")
		local header = {}

		-- The opening marker: a line that is only dashes at the very top.
		local afterOpen = source:match("^%s*%-%-%-%s*\r?\n(.*)$")
		if not afterOpen then return header, source end

		-- The closing marker: the next line that is only dashes.
		local closeStart = afterOpen:find("\n%s*%-%-%-%s*\r?\n")
		if not closeStart then return header, source end

		local block = afterOpen:sub(1, closeStart - 1)
		local closeEnd = afterOpen:find("\n", closeStart + 1) or #afterOpen
		local body = afterOpen:sub(closeEnd + 1)

		for line in block:gmatch("[^\r\n]+") do
			local key, value = line:match("^%s*([%w%-_]+)%s*:%s*(.-)%s*$")
			if key and value ~= "" then header[key:lower()] = value end
		end
		return header, body
	end

	local function safeName(raw)
		local text = util.trim(tostring(raw or "")):gsub("%.md$", "")
		if text == "" then return nil, "no name given" end
		-- The filename becomes a path the model hands back later, so the same
		-- rules as any other file path apply.
		local clean, err = fsx.sanitise(text .. ".md")
		if not clean then return nil, err end
		return clean:gsub("%.md$", "")
	end

	-- Catalogue ---------------------------------------------------------------

	-- Every skill on disk, parsed. Cheap: skills are small and few, and the
	-- settings pane and the listing tool both want the whole set anyway.
	function M.list()
		local out = {}
		if not fsx.enabled then return out end
		local entries = fsx.list("", DIR)
		if type(entries) ~= "table" then return out end
		for _, entry in ipairs(entries) do
			if not entry.isDir and tostring(entry.name):sub(-3):lower() == ".md" then
				local base = tostring(entry.name):sub(1, -4)
				local content, readErr = fsx.read(entry.name, DIR)
				if type(content) == "string" then
					local header = parseFrontmatter(content)
					out[#out + 1] = {
						file = entry.name,
						name = util.trim(header.name or base),
						description = util.trim(header.description or ""),
						enabled = M.isEnabled(entry.name),
						size = #content,
					}
				else
					out[#out + 1] = {
						file = entry.name,
						name = base,
						description = "",
						enabled = M.isEnabled(entry.name),
						size = 0,
						unreadable = tostring(readErr),
					}
				end
			end
		end
		table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
		return out
	end

	function M.find(name)
		local wanted = util.trim(tostring(name or "")):lower()
		if wanted == "" then return nil end
		local byFile = wanted:sub(-3) == ".md" and wanted or (wanted .. ".md")
		local byName = util.trim(tostring(name)):lower()
		for _, skill in ipairs(M.list()) do
			if skill.file:lower() == byFile or skill.name:lower() == byName then return skill end
		end
		return nil
	end

	-- The body, on demand. This is the one call the whole design exists to
	-- make cheap: the listing costs a few tokens per skill, this costs the
	-- skill itself, and only for the skill whose description matched.
	function M.read(name, limit)
		local skill = M.find(name)
		if not skill then return nil, "no skill named '" .. tostring(name) .. "'" end
		if not M.isEnabled(skill.file) then
			return nil, "the '" .. skill.name .. "' skill is switched off in Settings"
		end
		local content, err = fsx.read(skill.file, DIR)
		if not content then return nil, err end
		local _, body = parseFrontmatter(content)
		local text, truncated = util.truncate(body, tonumber(limit) or READ_CAP)
		return string.format("%s (%d characters%s):\n%s",
			skill.name, #body, truncated and ", trimmed" or "", text)
	end

	-- Enabled ------------------------------------------------------------------
	--
	-- On by default, because the file-drop path should not need a second step:
	-- a user who dropped a playbook in wants it available. The switch the
	-- settings pane flips is per file, and disabling is what needs a stored
	-- entry -- an absent entry means enabled.

	function M.isEnabled(file)
		local stored = config.get("skills.disabled", {})
		return type(stored) == "table" and stored[tostring(file)] ~= true
	end

	function M.setEnabled(file, enabled)
		local list = config.get("skills.disabled", {})
		if type(list) ~= "table" then list = {} end
		list = util.copy(list)
		if enabled == false then
			list[tostring(file)] = true
		else
			list[tostring(file)] = nil
		end
		config.set("skills.disabled", list)
		M.changed:fire(tostring(file), enabled ~= false)
	end

	-- Writing -------------------------------------------------------------------

	-- Writes a skill from parts. The frontmatter is rebuilt rather than
	-- trusted so a saved skill always carries a header the catalogue can
	-- parse -- whatever wrote the body, `list` can always describe it.
	function M.save(name, description, body)
		local clean, err = safeName(name)
		if not clean then return false, err end
		local header = "name: " .. clean .. "\n"
		local descriptionText = util.trim(tostring(description or ""))
		if descriptionText ~= "" then
			header = header .. "description: " .. util.ellipsis(descriptionText, 400) .. "\n"
		end
		local file = "---\n" .. header .. "---\n\n" .. tostring(body or "")
		local ok, writeErr = fsx.write(clean .. ".md", file, DIR)
		if not ok then return false, writeErr end
		M.changed:fire(clean .. ".md", true)
		return true, clean .. ".md"
	end

	function M.remove(name)
		local skill = M.find(name)
		if not skill then return false, "no skill named '" .. tostring(name) .. "'" end
		local ok, err = fsx.delete(skill.file, DIR)
		if not ok then return false, err end
		-- Drop its switch too, so a later file of the same name does not
		-- inherit an off state it never earned.
		M.setEnabled(skill.file, true)
		M.changed:fire(skill.file, nil)
		return true, skill.file
	end

	-- GitHub ---------------------------------------------------------------------
	--
	-- "install ponytail from github" resolves to a raw.githubusercontent URL
	-- and lands in skills/ like any local file. Owner/repo, full GitHub URLs
	-- and raw URLs are accepted; a bare name is not, because guessing an owner
	-- would install a stranger's playbook on a hunch. The default filename is
	-- SKILL.md, the convention of Anthropic-style skill repos.
	function M.fromGitHub(ref, path)
		local text = util.trim(tostring(ref or ""))
		if text == "" then return false, "no repository given" end

		local raw, name
		if text:find("^https://") or text:find("^http://") then
			raw = text:gsub("^http://", "https://")
				:gsub("^https://github%.com/([^/]+)/([^/]+)/blob/(.+)$", "https://raw.githubusercontent.com/%1/%2/%3")
			if not raw:find("^https://raw%.githubusercontent%.com/") then
				return false, "give a github.com URL or owner/repo"
			end
			name = text:match("[^/]+$"):gsub("%.md$", "")
		else
			local owner, repo = text:match("^([%w%.%-]+)/([%w%.%-]+)$")
			if not owner then
				return false, "give the repository as owner/repo or a GitHub URL"
			end
			local wanted = util.trim(tostring(path or ""))
			if wanted == "" then wanted = "SKILL.md" end
			raw = string.format("https://raw.githubusercontent.com/%s/%s/main/%s",
				owner, repo, wanted)
			name = repo
		end

		local http = env.require("net/http")
		local res, err = http.send({
			url = raw,
			method = "GET",
			identity = "browser",
			tag = "skills",
			attempts = 2,
		})
		if not res then return false, "could not reach the repository: " .. tostring(err) end
		if not res.ok then
			return false, string.format(
				"the repository answered HTTP %d -- the file may sit on a branch other than main, or at a path other than the one given",
				res.status)
		end
		local content = tostring(res.body or "")
		if util.trim(content) == "" then return false, "the file was empty" end

		local header, body = parseFrontmatter(content)
		local skillName = util.trim(header.name or name or "skill")
		local description = header.description or ("Installed from " .. text)
		-- A file that already had frontmatter keeps its body; one that did not
		-- is saved whole, so nothing is thrown away on a headerless paste.
		local ok, saveErr = M.save(skillName, description, (body ~= "" and body or content))
		if not ok then return false, saveErr end
		return true, skillName
	end

	-- The prompt line --------------------------------------------------------------

	-- Names and one-line descriptions, nothing else. This is the whole cost of
	-- the engine in a turn that uses no skill, and it is what lets the model
	-- know a playbook exists without paying for it.
	function M.indexBlock()
		if not fsx.enabled then return nil end
		local list = M.list()
		local lines = {}
		for _, skill in ipairs(list) do
			if skill.enabled then
				local description = skill.description ~= "" and skill.description or "no description"
				lines[#lines + 1] = "- " .. skill.name .. ": " .. util.ellipsis(description, 100)
			end
		end
		if #lines == 0 then return nil end
		return table.concat(lines, "\n")
	end

	M.READ_CAP = READ_CAP
	M.DIR = DIR

	return M
end
