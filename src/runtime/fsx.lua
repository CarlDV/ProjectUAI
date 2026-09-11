-- Filesystem facade.
--
-- Executor filesystems are sandboxed to the executor's own workspace folder, so
-- paths here are relative to one app folder and never absolute. `..` is rejected
-- rather than normalised: a model-authored path is untrusted input, and the file
-- tools hand their argument straight to this module.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local log = env.require("runtime/log")

	local M = {}

	M.enabled = caps.fs
	M.root = (env.info and env.info.folder) or "UAI"

	local knownFolders = {}

	function M.sanitise(path)
		local clean = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+", "/")
		if clean == "" then return nil, "empty path" end
		for _, part in ipairs(util.split(clean, "/")) do
			if part == ".." then return nil, "path may not contain '..'" end
			if part == "." then return nil, "path may not contain '.'" end
			if part:find('[<>:"|%?%*]') then return nil, "path contains a reserved character" end
		end
		if #clean > 180 then return nil, "path is too long" end
		return clean
	end

	-- Absolute form used with the executor functions: everything the client owns
	-- lives under one folder so an uninstall is one delete.
	--
	-- `opts.scope` names a subfolder the path is resolved inside -- "files" for the
	-- agent's own workspace, "pastes" for long-message overflow. It exists so the
	-- model-authored files and the client's own state (config.json, sessions/,
	-- stats.json) never share a directory: a folder full of both is the "very messy"
	-- problem, and the fix is a prefix applied in one place rather than remembered by
	-- every caller.
	local SCOPES = { files = true, pastes = true }

	function M.resolve(path, opts)
		opts = opts or {}
		local clean, err = M.sanitise(path)
		if not clean then return nil, err end
		if opts.raw then return clean end
		local base = M.root
		if opts.scope and SCOPES[opts.scope] then base = base .. "/" .. opts.scope end
		return base .. "/" .. clean
	end

	function M.ensure(dir)
		if not M.enabled or not caps.fn.makefolder then return false end
		local clean = M.sanitise(dir)
		if not clean then return false end
		local walk = ""
		for _, part in ipairs(util.split(clean, "/")) do
			walk = (walk == "") and part or (walk .. "/" .. part)
			if not knownFolders[walk] then
				local exists = false
				if caps.fn.isfolder then
					local ok, result = pcall(caps.fn.isfolder, walk)
					exists = ok and result == true
				end
				if not exists then pcall(caps.fn.makefolder, walk) end
				knownFolders[walk] = true
			end
		end
		return true
	end

	-- Every path-taking function accepts `opts` so a scoped caller can stay inside
	-- its folder without recomputing full paths: `M.read("notes.txt", { scope = "files" })`.
	-- The existence checks resolve the same way, or a scoped write would always think
	-- it was overwriting.
	function M.exists(path, opts)
		if not M.enabled or not caps.fn.isfile then return false end
		local full = M.resolve(path, opts)
		if not full then return false end
		local ok, result = pcall(caps.fn.isfile, full)
		return ok and result == true
	end

	function M.isDir(path, opts)
		if not M.enabled or not caps.fn.isfolder then return false end
		local full = M.resolve(path, opts)
		if not full then return false end
		local ok, result = pcall(caps.fn.isfolder, full)
		return ok and result == true
	end

	function M.read(path, opts)
		if not M.enabled then return nil, caps.reason("fs") end
		local full, err = M.resolve(path, opts)
		if not full then return nil, err end
		if not M.exists(path, opts) then return nil, "no such file: " .. full end
		local ok, content = pcall(caps.fn.readfile, full)
		if not ok then return nil, tostring(content) end
		return content
	end

	function M.write(path, content, opts)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path, opts)
		if not full then return false, err end
		M.ensure(full:match("^(.*)/[^/]*$") or M.root)
		local ok, writeErr = pcall(caps.fn.writefile, full, tostring(content))
		if not ok then
			log.warn("fsx", "write failed: " .. full, writeErr)
			return false, tostring(writeErr)
		end
		return true, full
	end

	function M.append(path, content, opts)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path, opts)
		if not full then return false, err end
		M.ensure(full:match("^(.*)/[^/]*$") or M.root)
		if caps.fn.appendfile then
			local ok, appendErr = pcall(caps.fn.appendfile, full, tostring(content))
			if ok then return true, full end
			return false, tostring(appendErr)
		end
		-- Not every host has appendfile; read-modify-write is correct, just worse.
		local existing = M.read(path, opts) or ""
		return M.write(path, existing .. tostring(content), opts)
	end

	function M.delete(path, opts)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path, opts)
		if not full then return false, err end
		if M.isDir(path, opts) then
			if not caps.fn.delfolder then return false, "this host cannot delete folders" end
			local ok, delErr = pcall(caps.fn.delfolder, full)
			return ok, ok and full or tostring(delErr)
		end
		if not caps.fn.delfile then return false, "this host cannot delete files" end
		local ok, delErr = pcall(caps.fn.delfile, full)
		return ok, ok and full or tostring(delErr)
	end

	-- listfiles returns host-shaped paths: some absolute, some backslashed, some
	-- already relative. They are normalised back to app-relative so a caller
	-- never has to care which executor it is on.
	function M.list(path, opts)
		if not M.enabled or not caps.fn.listfiles then return {}, caps.reason("fs") end
		opts = opts or {}
		-- The empty path is the root of whatever is being listed -- the whole app
		-- folder, or the whole scope. sanitise() refuses it because an empty path is
		-- no path at all for every other operation; here it is the one thing that
		-- means "everything".
		local base = M.root
		if opts.scope and SCOPES[opts.scope] then base = base .. "/" .. opts.scope end
		local trimmed = util.trim(tostring(path or ""))
		local full
		if trimmed == "" then
			full = base
		else
			local clean = M.sanitise(trimmed)
			if not clean then return {}, "bad path" end
			full = base .. "/" .. clean
		end
		local scopePrefix = (base ~= M.root) and (base:sub(#M.root + 2) .. "/") or ""
		local ok, entries = pcall(caps.fn.listfiles, full)
		if not ok or type(entries) ~= "table" then return {} end
		local out = {}
		for _, entry in ipairs(entries) do
			local normal = tostring(entry):gsub("\\", "/")
			local relative = normal:match("^.*" .. util.escapePattern(M.root) .. "/(.+)$") or normal
			-- Inside a scope the paths are reported relative to the scope, so a
			-- scoped caller sees "notes/plan.txt" rather than "files/notes/plan.txt"
			-- -- the prefix is the caller's own business and restating it in every
			-- row is noise.
			if scopePrefix ~= "" and util.startsWith(relative, scopePrefix) then
				relative = relative:sub(#scopePrefix + 1)
			end
			out[#out + 1] = {
				path = relative,
				name = relative:match("[^/]+$") or relative,
				isDir = caps.fn.isfolder and select(2, pcall(caps.fn.isfolder, normal)) == true or false,
			}
		end
		table.sort(out, function(a, b) return a.path < b.path end)
		return out
	end

	function M.readJson(path, fallback)
		local content = M.read(path)
		if not content then return fallback end
		local value, err = util.decode(content)
		if value == nil then
			log.warn("fsx", "corrupt json at " .. tostring(path), err)
			return fallback
		end
		return value
	end

	function M.writeJson(path, value)
		local ok, body = pcall(util.encode, value)
		if not ok then return false, tostring(body) end
		return M.write(path, body)
	end

	-- Migration ----------------------------------------------------------------
	--
	-- Before the workspace split, everything the agent wrote landed in the app
	-- folder's root beside the client's own config.json, sessions/ and stats.json.
	-- The tools now resolve inside files/, which made every one of those older files
	-- invisible overnight -- "tidy" and "where did my files go" are the same change
	-- seen from two sides. This moves them into files/ once: anything at the root
	-- that is not the client's own state and not itself a scope folder is relocated
	-- verbatim.
	local CLIENT_STATE = {
		["config.json"] = true,
		["stats.json"] = true,
	}

	function M.migrate(onProgress)
		if not M.enabled then return 0 end
		-- Idempotent: once the root holds only client state and scope folders, the
		-- sweep finds nothing and costs a single listfiles.
		--
		-- Top-level entries only. Some hosts (and the mock) list recursively, so the
		-- root listing can include files already inside files/ -- treating those as
		-- legacy is what moves a file into files/files/ on the second boot, and worse,
		-- what walks the client's own sessions/ transcripts into the workspace.
		local entries = M.list("")
		local moved, skipped = 0, 0
		for _, entry in ipairs(entries) do
			-- Anything nested is somebody else's subdirectory, not a legacy root file.
			if tostring(entry.path or ""):find("/", 1, true) then
				skipped = skipped + 1
			else
				local name = tostring(entry.name or "")
				local isScope = name == "files" or name == "pastes"
				local isState = CLIENT_STATE[name] or name == "sessions" or name == "export"
				if entry.isDir and not isScope and not isState then
					-- A folder the agent made for itself (notes/, builds/). Rewritten
					-- under files/ by full relative path, which keeps nested structure:
					-- executors offer no rename across directories, so a directory copy
					-- is a loop over listfiles.
					local inner = M.list(entry.path)
					for _, file in ipairs(inner) do
						if not file.isDir then
							local body = M.read(file.path)
							if body then
								M.write(file.path, body, { scope = "files" })
								M.delete(file.path)
								moved = moved + 1
								if onProgress then onProgress(moved, file.path) end
							end
						end
					end
					-- The now-empty original. Only removed if empty, which a failed copy
					-- leaves non-empty -- a half-migrated folder must not be lost.
					local remain = 0
					for _, file in ipairs(M.list(entry.path)) do
						if not file.isDir then remain = remain + 1 end
					end
					if remain == 0 then M.delete(entry.path) end
				elseif not entry.isDir and not isState and not isScope then
					local body = M.read(entry.path)
					if body then
						M.write(entry.name, body, { scope = "files" })
						M.delete(entry.path)
						moved = moved + 1
						if onProgress then onProgress(moved, entry.name) end
					end
				else
					skipped = skipped + 1
				end
			end
		end
		if moved > 0 then
			log.info("fsx", string.format("migrated %d file(s) into files/", moved))
		end
		return moved, skipped
	end

	return M
end
