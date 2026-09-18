-- Install a consistent GitHub tree into the executor's UAI/bridge directory.
return function(env)
	local util = env.require("runtime/util")
	local caps = env.require("runtime/caps")
	local fsx = env.require("runtime/fsx")
	local http = env.require("net/http")
	local M = { busy = false }
	local API = "https://api.github.com/repos/CarlDV/ProjectUAI/"
	local RAW = "https://raw.githubusercontent.com/CarlDV/ProjectUAI/"
	function M.download(progress)
		if M.busy then return false, "Bridge download is already running." end
		if not fsx.enabled or not caps.fn.makefolder or not caps.fn.isfile then
			return false, "This executor needs file writing, reading, and folder creation to download the bridge."
		end
		if not caps.has("http") then return false, "This executor has no HTTP transport." end
		M.busy = true
		local function report(text) if progress then pcall(progress, text) end end
		local ok, result = pcall(function()
			report("Finding bridge files…")
			local response, err = http.send({ url = API .. "commits/main", method = "GET", timeout = 15, attempts = 2,
				identity = "none", headers = { Accept = "application/vnd.github+json", ["User-Agent"] = "ProjectUAI" }, tag = "bridge download" })
			if not response or not response.ok then error(err or ("GitHub returned " .. tostring(response and response.status)), 0) end
			local commit = util.decode(response.body)
			local revision = type(commit) == "table" and commit.sha
			local treeId = type(commit) == "table" and util.get(commit, "commit.tree.sha")
			if type(revision) ~= "string" or not revision:match("^%x+$") or type(treeId) ~= "string" or not treeId:match("^%x+$") then
				error("GitHub returned an invalid revision.", 0)
			end
			response, err = http.send({ url = API .. "git/trees/" .. treeId .. "?recursive=1", method = "GET", timeout = 15, attempts = 2,
				identity = "none", headers = { Accept = "application/vnd.github+json", ["User-Agent"] = "ProjectUAI" }, tag = "bridge download" })
			if not response or not response.ok then error(err or ("GitHub returned " .. tostring(response and response.status)), 0) end
			local tree = util.decode(response.body)
			if type(tree) ~= "table" or type(tree.tree) ~= "table" or not tostring(tree.sha or ""):match("^%x+$") then error("GitHub returned an invalid file list.", 0) end
			if tree.truncated then error("GitHub file list was truncated; download was not started.", 0) end
			local files, total, server = {}, 0, false
			for _, entry in ipairs(tree.tree) do
				local path = tostring(entry.path or "")
				if path:sub(1, 7) == "bridge/" and entry.type == "blob" then
					local clean = fsx.sanitise(path)
					if clean ~= path or entry.mode == "120000" then error("Invalid bridge file path.", 0) end
					total = total + (tonumber(entry.size) or 0)
					if total > 20 * 1024 * 1024 or #files >= 200 then error("Bridge download exceeds the installation limit.", 0) end
					files[#files + 1] = { path = path, size = entry.size }
					if path == "bridge/server.js" then server = true end
				end
			end
			if not server then error("No bridge/server.js found on GitHub.", 0) end
			-- Fetch everything before changing the installed version. Pin the commit SHA
			-- so a push halfway through the download cannot mix incompatible files.
			for index, file in ipairs(files) do
				report(string.format("Downloading %d/%d · %s", index, #files, file.path))
				local response2, why = http.send({ url = RAW .. revision .. "/" .. file.path, method = "GET",
					timeout = 15, attempts = 2, identity = "none", tag = "bridge download" })
				if not response2 or not response2.ok then error("Could not download " .. file.path .. ": " .. tostring(why or (response2 and response2.status)), 0) end
				file.body = response2.body
				if type(file.body) ~= "string" or (file.size and #file.body ~= file.size) then error("Incomplete download: " .. file.path, 0) end
			end
			for index, file in ipairs(files) do
				report(string.format("Saving %d/%d · %s", index, #files, file.path))
				local full = fsx.resolve(file.path)
				if not fsx.ensure(full:match("^(.*)/[^/]+$")) then error("Could not create the bridge folder.", 0) end
				local wrote, why = fsx.write(file.path, file.body)
				if not wrote or fsx.read(file.path) ~= file.body then error("Could not verify " .. file.path .. ": " .. tostring(why), 0) end
			end
			return string.format("Saved %d files to %s/bridge. In your executor workspace, run: node %s/bridge/server.js", #files, fsx.root, fsx.root)
		end)
		M.busy = false
		if not ok then return false, tostring(result) end
		return true, result
	end
	return M
end
