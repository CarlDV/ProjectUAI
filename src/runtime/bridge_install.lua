-- Pin a bridge package and save only .txt files, which executor filesystems allow.
-- Node restores the original extensions when the operator runs bridge/start.txt.
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
			if type(revision) ~= "string" or #revision ~= 40 or not revision:match("^%x+$") or type(treeId) ~= "string" or #treeId ~= 40 or not treeId:match("^%x+$") then
				error("GitHub returned an invalid revision.", 0)
			end
			response, err = http.send({ url = API .. "git/trees/" .. treeId .. "?recursive=1", method = "GET", timeout = 15, attempts = 2,
				identity = "none", headers = { Accept = "application/vnd.github+json", ["User-Agent"] = "ProjectUAI" }, tag = "bridge download" })
			if not response or not response.ok then error(err or ("GitHub returned " .. tostring(response and response.status)), 0) end
			local tree = util.decode(response.body)
			if type(tree) ~= "table" or type(tree.tree) ~= "table" or tree.sha ~= treeId then error("GitHub returned an invalid file list.", 0) end
			if tree.truncated then error("GitHub file list was truncated; download was not started.", 0) end
			local files, total, found = {}, 0, {}
			for _, entry in ipairs(tree.tree) do
				local path = tostring(entry.path or "")
				if path:sub(1, 7) == "bridge/" and entry.type == "blob" then
					local clean = fsx.sanitise(path)
					if clean ~= path or entry.mode == "120000" then error("Invalid bridge file path.", 0) end
					local relative = path:sub(8)
					-- Runtime files only. Tests, plans and development docs do not belong
					-- in the executor installation; web assets retain their subfolders.
					if relative:sub(1, 4) == "web/" or (relative:match("^[^/]+%.js$") and not relative:match("^test%-")) then
						local size = tonumber(entry.size)
						if not size or size < 0 or size ~= math.floor(size) or found[relative] or type(entry.sha) ~= "string" or #entry.sha ~= 40 or not entry.sha:match("^%x+$") then error("Invalid bridge file entry.", 0) end
						total = total + size
						if total > 20 * 1024 * 1024 or #files >= 200 then error("Bridge download exceeds the installation limit.", 0) end
						files[#files + 1] = { path = relative, size = size, sha = entry.sha }
						found[relative] = true
					end
				end
			end
			for _, required in ipairs({ "server.js", "inference.js", "picture-store.js", "launcher.js", "web/index.html" }) do
				if not found[required] then error("The GitHub bridge package is missing " .. required .. ". Try again after updating Project UAI.", 0) end
			end
			table.sort(files, function(a, b) return a.path < b.path end)
			-- Fetch everything before changing the installed version. Pin the commit SHA
			-- so a push halfway through the download cannot mix incompatible files.
			for index, file in ipairs(files) do
				report(string.format("Downloading %d/%d · %s", index, #files, file.path))
				local response2, why = http.send({ url = RAW .. revision .. "/bridge/" .. file.path, method = "GET",
					timeout = 15, attempts = 2, identity = "none", tag = "bridge download" })
				if not response2 or not response2.ok then error("Could not download " .. file.path .. ": " .. tostring(why or (response2 and response2.status)), 0) end
				file.body = response2.body
				if type(file.body) ~= "string" or (file.size and #file.body ~= file.size) then error("Incomplete download: " .. file.path, 0) end
			end
			-- A retry of the same revision gets its own folder as well. A partial
			-- write must not damage the package used by the previous launcher.
			local packageId = revision .. "-" .. env.services.HttpService:GenerateGUID(false)
			local package = "bridge/packages/" .. packageId .. "/"
			local manifest = { revision = revision, files = {} }
			for index, file in ipairs(files) do
				report(string.format("Saving %d/%d · %s", index, #files, file.path))
				local stored = package .. file.path .. ".txt"
				local full = fsx.resolve(stored)
				if not full then error("Bridge package path is too long.", 0) end
				if not fsx.ensure(full:match("^(.*)/[^/]+$")) then error("Could not create the bridge folder.", 0) end
				local wrote, why = fsx.write(stored, file.body)
				if not wrote or fsx.read(stored) ~= file.body then error("Could not save " .. stored .. ": " .. tostring(why), 0) end
				manifest.files[#manifest.files + 1] = { path = file.path, size = file.size, sha = file.sha }
			end
			local launcher = "'use strict';\nrequire('./packages/" .. packageId .. "/launcher.js.txt').launch(" .. util.encode(manifest) .. ");\n"
			local previous = fsx.read("bridge/start.txt")
			local wrote, why = fsx.write("bridge/start.txt", launcher)
			if not wrote or fsx.read("bridge/start.txt") ~= launcher then
				if previous then fsx.write("bridge/start.txt", previous) end
				error("Could not save the bridge launcher: " .. tostring(why) .. ". Download again before starting.", 0)
			end
			return string.format("Ready. Open a terminal in your executor workspace and run: node %s/bridge/start.txt\nThen open the browser link, paste its token below, and turn Enabled on. Keep the terminal and Roblox open.", fsx.root)
		end)
		M.busy = false
		if not ok then return false, tostring(result) end
		return true, result
	end
	return M
end
