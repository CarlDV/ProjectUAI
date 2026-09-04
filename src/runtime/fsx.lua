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
	function M.resolve(path, opts)
		opts = opts or {}
		local clean, err = M.sanitise(path)
		if not clean then return nil, err end
		if opts.raw then return clean end
		return M.root .. "/" .. clean
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

	function M.exists(path)
		if not M.enabled or not caps.fn.isfile then return false end
		local full = M.resolve(path)
		if not full then return false end
		local ok, result = pcall(caps.fn.isfile, full)
		return ok and result == true
	end

	function M.isDir(path)
		if not M.enabled or not caps.fn.isfolder then return false end
		local full = M.resolve(path)
		if not full then return false end
		local ok, result = pcall(caps.fn.isfolder, full)
		return ok and result == true
	end

	function M.read(path)
		if not M.enabled then return nil, caps.reason("fs") end
		local full, err = M.resolve(path)
		if not full then return nil, err end
		if not M.exists(path) then return nil, "no such file: " .. full end
		local ok, content = pcall(caps.fn.readfile, full)
		if not ok then return nil, tostring(content) end
		return content
	end

	function M.write(path, content)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path)
		if not full then return false, err end
		M.ensure(full:match("^(.*)/[^/]*$") or M.root)
		local ok, writeErr = pcall(caps.fn.writefile, full, tostring(content))
		if not ok then
			log.warn("fsx", "write failed: " .. full, writeErr)
			return false, tostring(writeErr)
		end
		return true, full
	end

	function M.append(path, content)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path)
		if not full then return false, err end
		M.ensure(full:match("^(.*)/[^/]*$") or M.root)
		if caps.fn.appendfile then
			local ok, appendErr = pcall(caps.fn.appendfile, full, tostring(content))
			if ok then return true, full end
			return false, tostring(appendErr)
		end
		-- Not every host has appendfile; read-modify-write is correct, just worse.
		local existing = M.read(path) or ""
		return M.write(path, existing .. tostring(content))
	end

	function M.delete(path)
		if not M.enabled then return false, caps.reason("fs") end
		local full, err = M.resolve(path)
		if not full then return false, err end
		if M.isDir(path) then
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
	function M.list(path)
		if not M.enabled or not caps.fn.listfiles then return {}, caps.reason("fs") end
		local full = M.resolve(path or "")
		if not full then return {}, "bad path" end
		local ok, entries = pcall(caps.fn.listfiles, full)
		if not ok or type(entries) ~= "table" then return {} end
		local out = {}
		for _, entry in ipairs(entries) do
			local normal = tostring(entry):gsub("\\", "/")
			local relative = normal:match("^.*" .. util.escapePattern(M.root) .. "/(.+)$") or normal
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

	return M
end
