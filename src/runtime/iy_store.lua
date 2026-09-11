-- The Infinite Yield plugin store, as a runtime.
--
-- iyplugins.pages.dev publishes a JSON index of community plugins -- several
-- hundred .iy files with names, authors and download paths. This module turns
-- that index into three operations -- search, install, uninstall -- and the
-- tools in tools/iy expose them to the agent. There is deliberately no store
-- UI: the catalog is browsed in conversation, by asking for what is wanted.
--
-- Install mechanics, matching what IY's own `plugin <name>` command does:
--   1. download the .iy source from the store,
--   2. write it into the executor's workspace ROOT by that name -- IY's
--      addPlugin reads `readfile(name)`, an executor-relative path, so the
--      file cannot live in UAI's own folder,
--   3. call IY's addPlugin(name), which loads the file and registers its
--      commands.
-- Uninstall is deletePlugin(name) plus delfile, in that order: unregister
-- first so nothing holds a reference to code that is about to disappear.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local iy = env.require("runtime/iy")

	local API_URL = "https://iyplugins.pages.dev/data/api.json"
	local SITE = "https://iyplugins.pages.dev/"
	local DOWNLOAD_TIMEOUT = 30
	local CATALOG_STALE_MS = 10 * 60 * 1000

	local M = {
		catalog = nil,
		catalogAt = 0,
		catalogError = nil,
	}

	local function httpGet(url, tag)
		local http = env.require("net/http")
		return http.send({
			url = url,
			method = "GET",
			identity = "browser",
			tag = tag,
			timeout = DOWNLOAD_TIMEOUT * 1000,
			attempts = 2,
		})
	end

	-- The index, fetched at most once every ten minutes. A search tool the
	-- model calls repeatedly in one turn must not re-download half a megabyte
	-- each time; a cache with no expiry would hide new plugins for a session.
	function M.fetchCatalog(force)
		if M.catalog and not force and (clock.ms() - M.catalogAt) < CATALOG_STALE_MS then
			return M.catalog, nil
		end
		local res, err = httpGet(API_URL, "iy-store")
		if not res then
			M.catalogError = err
			return nil, "could not reach the store: " .. tostring(err)
		end
		if res.status ~= 200 then
			M.catalogError = "HTTP " .. res.status
			return nil, "the store answered HTTP " .. res.status
		end
		local decoded, decodeErr = util.decode(res.body)
		if type(decoded) ~= "table" or type(decoded.plugins) ~= "table" then
			return nil, "the store's index is not the shape expected: " .. tostring(decodeErr)
		end
		M.catalog = decoded
		M.catalogAt = clock.ms()
		M.catalogError = nil
		return decoded, nil
	end

	-- The .iy entry of a store record. A submission may carry screenshots and
	-- videos alongside the plugin; `is_plugin` is the store's own flag for
	-- which file is the code.
	local function pluginFile(entry)
		for _, file in ipairs(type(entry.files) == "table" and entry.files or {}) do
			if type(file) == "table" and file.is_plugin ~= false then
				local name = tostring(file.filename or "")
				local url = tostring(file.url or "")
				if name ~= "" and url ~= "" then
					return { name = name, url = url, size = tonumber(file.size) }
				end
			end
		end
		return nil
	end

	-- Every entry that matches a query. Matches the name (strongest), the
	-- author, and the filename; a query that is an id matches exactly.
	function M.search(query, limit)
		local catalog, err = M.fetchCatalog()
		if not catalog then return nil, err end

		local needle = util.trim(tostring(query or "")):lower()
		local out = {}
		for _, entry in ipairs(catalog.plugins) do
			if type(entry) == "table" then
				local name = tostring(entry.name or "")
				local author = tostring(entry.author or "")
				local file = pluginFile(entry)
				local matched = false
				local score = 0
				if needle == "" then
					matched = true
				elseif tostring(entry.id or "") == needle then
					matched, score = true, 4
				elseif name:lower():find(needle, 1, true) then
					matched, score = true, 3
				elseif file and file.name:lower():find(needle, 1, true) then
					matched, score = true, 2
				elseif author:lower():find(needle, 1, true) then
					matched, score = true, 1
				end
				if matched then
					out[#out + 1] = {
						id = tostring(entry.id or ""),
						name = name,
						author = author,
						score = score,
						file = file,
					}
				end
			end
		end
		-- Stronger matches first, then alphabetical, so "dex" finds
		-- "dexrecontinued" ahead of "indexviewer".
		table.sort(out, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			return a.name:lower() < b.name:lower()
		end)
		if limit and limit > 0 then
			while #out > limit do table.remove(out) end
		end
		return out, nil
	end

	-- IY's plugin functions are chunk globals like everything else: present in
	-- the shared table after an ambient load, or in the holder after ours.
	local function iyFunction(name)
		if iy.iy and iy.iy[name] ~= nil then return iy.iy[name] end
		return iy.ambient and iy.ambient(name) or nil
	end

	-- Download, write to the workspace root, register with IY.
	function M.install(plugin)
		local wanted = util.trim(tostring(plugin or ""))
		if wanted == "" then return false, "no plugin named" end

		if not iy.isLoaded() then
			local ok, err = iy.ensure()
			if not ok then return false, err end
		end

		local results, err = M.search(wanted, 5)
		if not results then return false, err end
		if #results == 0 then
			return false, "nothing on the store matches '" .. wanted .. "'"
		end
		local entry = results[1]
		if #results > 1 and not (entry.name:lower() == wanted:lower()
			or entry.id == wanted
			or (entry.file and entry.file.name:lower() == wanted:lower() .. ".iy")) then
			local names = {}
			for index = 1, math.min(#results, 5) do
				names[#names + 1] = results[index].name
			end
			return false, "several plugins match; name one: " .. table.concat(names, ", ")
		end
		if not entry.file then
			return false, "'" .. entry.name .. "' has no .iy file on the store"
		end

		local write = caps.fn.writefile
		local read = caps.fn.readfile
		if not write or not read then
			return false, "this host has no filesystem functions, so a plugin cannot be saved"
		end

		-- Already on disk and registered: a re-install is a no-op, not an error.
		local registered = iyFunction("addPlugin")
		if type(registered) ~= "function" then
			return false, "IY is loaded but its plugin loader is not reachable"
		end
		local fileName = entry.file.name
		local okPresent = false
		local okRead = pcall(function()
			local existing = read(fileName)
			okPresent = type(existing) == "string" and #existing > 0
		end)
		if okRead and okPresent then
			return true, fileName .. " is already installed; load it with plugin " .. fileName:gsub("%.iy$", "")
		end

		local res, dlErr = httpGet(SITE .. entry.file.url, "iy-plugin")
		if not res then return false, "could not download it: " .. tostring(dlErr) end
		if res.status ~= 200 then
			return false, "the download answered HTTP " .. res.status
		end
		local source = tostring(res.body or "")
		if #source == 0 then return false, "the download was empty" end

		-- A size sanity check against the index: a body wildly larger than the
		-- catalogue's number is an error page or a redirect, not a plugin.
		if entry.file.size and #source > entry.file.size * 20 and #source > 50000 then
			log.warn("iy-store", "download was " .. #source .. " bytes, the index said " .. entry.file.size)
		end

		local okWrite = pcall(write, fileName, source)
		if not okWrite then return false, "could not write " .. fileName .. " to the workspace" end

		local okLoad, loadErr = pcall(registered, fileName)
		if not okLoad then
			pcall(function()
				if caps.fn.delfile then caps.fn.delfile(fileName) end
			end)
			return false, "saved, but IY could not load it: " .. tostring(loadErr)
		end

		log.info("iy-store", "installed " .. fileName .. " from the store")
		return true, fileName
	end

	-- Unregister from IY, then remove the file.
	function M.uninstall(plugin)
		local wanted = util.trim(tostring(plugin or "")):lower()
		if wanted == "" then return false, "no plugin named" end
		if wanted:sub(-3) ~= ".iy" then wanted = wanted .. ".iy" end

		local remover = iyFunction("deletePlugin")
		if type(remover) ~= "function" then
			return false, "IY is not loaded, so its plugin registry is not reachable"
		end

		local ok = pcall(remover, wanted)
		if not ok then return false, "IY could not remove " .. wanted end

		if caps.fn.delfile then
			pcall(caps.fn.delfile, wanted)
		end
		return true, wanted
	end

	-- What is on disk and registered right now. The registry side is read
	-- through IY's own PluginsTable when it is visible; otherwise the .iy files
	-- in the workspace root are the honest answer for what could be loaded.
	function M.listInstalled()
		local out = {}
		if iy.isLoaded() then
			local table_ = iyFunction("PluginsTable")
			if type(table_) == "table" then
				for _, name in ipairs(table_) do
					out[#out + 1] = tostring(name)
				end
			end
		end
		if caps.fn.listfiles then
			local ok, files = pcall(caps.fn.listfiles, "")
			if ok and type(files) == "table" then
				local seen = {}
				for _, name in ipairs(out) do seen[name] = true end
				for _, path in ipairs(files) do
					local clean = tostring(path):gsub("^%.?/", "")
					if clean:sub(-3) == ".iy" and not seen[clean] then
						out[#out + 1] = clean
					end
				end
			end
		end
		return out
	end

	return M
end
