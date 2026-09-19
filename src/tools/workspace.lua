-- Shared workspace reads and edit preparation. No access to client state files.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local clock = env.require("runtime/clock")
	local H = env.require("tools/helpers")
	local M = { scope = { scope = "files" }, MAX_BYTES = 2 * 1024 * 1024 }

	function M.stopped(ctx)
		return ctx and ctx.aborted and ctx.aborted() or false
	end

	local function aborted(message)
		local result = H.fail(message)
		result.data = { status = "aborted" }
		return result
	end

	function M.read(path)
		local content, err = fsx.read(path, M.scope)
		if content ~= nil or fsx.exists(path, M.scope) then return content, err end
		local paste = tostring(path):gsub("\\", "/")
		local prefix = fsx.root .. "/pastes/"
		if util.startsWith(paste, prefix) then paste = paste:sub(#prefix + 1)
		elseif util.startsWith(paste, "pastes/") then paste = paste:sub(8) end
		return fsx.read(paste, { scope = "pastes" })
	end

	-- Greedy glob matching avoids Lua pattern backtracking on inputs such as
	-- *a*a*a*a*. A question mark consumes a complete UTF-8 character.
	function M.matches(name, glob)
		name, glob = name:lower(), glob:lower()
		local at, pattern, star, retry = 1, 1, nil, nil
		local function advance(index)
			index = index + 1
			while index <= #name and name:byte(index) >= 128 and name:byte(index) < 192 do index = index + 1 end
			return index
		end
		while at <= #name do
			local char = glob:sub(pattern, pattern)
			if char == "?" then at, pattern = advance(at), pattern + 1
			elseif char ~= "" and char ~= "*" and char == name:sub(at, at) then at, pattern = at + 1, pattern + 1
			elseif char == "*" then star, retry, pattern = pattern, at, pattern + 1
			elseif star then retry = advance(retry); at, pattern = retry, star + 1
			else return false end
		end
		while glob:sub(pattern, pattern) == "*" do pattern = pattern + 1 end
		return pattern > #glob
	end

	function M.files(root, ctx)
		root = util.trim(root):gsub("\\", "/"):gsub("/+$", "")
		if root ~= "" then
			local clean, err = fsx.sanitise(root)
			if not clean then return nil, err end
			root = clean
		end
		if root ~= "" and fsx.exists(root, M.scope) then return { root }, { errors = {}, complete = true } end
		local paths, seenFiles, seenDirs = {}, {}, {}
		local queue, at = { root }, 1
		local report = { errors = {}, complete = true }
		local inspected = 0
		while at <= #queue do
			if M.stopped(ctx) then report.complete, report.reason = false, "aborted"; break end
			if at > 128 then report.complete, report.reason = false, "directory limit"; break end
			local dir = queue[at]
			at = at + 1
			seenDirs[dir] = true
			local entries, err = fsx.list(dir, M.scope)
			if err then
				report.complete = false
				report.errors[#report.errors + 1] = { path = dir, error = util.ellipsis(err, 200) }
			end
			for _, entry in ipairs(entries) do
				inspected = inspected + 1
				if inspected > 6000 or #paths >= 1000 then
					report.complete, report.reason = false, "file inventory limit"
					break
				end
				local path = fsx.sanitise(entry.path)
				if path and path ~= dir and dir ~= "" and not path:find("/", 1, true) then path = dir .. "/" .. path end
				local inRoot = path and (root == "" or path == root or util.startsWith(path, root .. "/"))
				if inRoot then
					if entry.isDir or fsx.isDir(path, M.scope) then
						if not seenDirs[path] then
							seenDirs[path] = true
							queue[#queue + 1] = path
						end
					elseif not seenFiles[path] then
						seenFiles[path] = true
						paths[#paths + 1] = path
					end
				end
			end
			if report.reason then break end
			if at % 8 == 0 then task.wait() end
		end
		table.sort(paths)
		return paths, report
	end

	function M.edit(path, edits, ctx)
		if type(edits) ~= "table" or #edits < 1 or #edits > 20 then return H.fail("provide 1-20 edits") end
		if M.stopped(ctx) then return aborted("edit stopped before reading") end
		local original, err = fsx.read(path, M.scope)
		if original == nil then return H.fail(err) end
		if #original > M.MAX_BYTES then return H.fail("file edits support files up to 2 MB") end
		local content, counts, total = original, {}, 0
		local lastYield = clock.ms()
		for index, edit in ipairs(edits) do
			local prefix = "edit " .. index .. ": "
			if type(edit.old_text) ~= "string" or edit.old_text == "" then return H.fail(prefix .. "old_text must not be empty") end
			if type(edit.new_text) ~= "string" then return H.fail(prefix .. "new_text must be a string") end
			local count, at = 0, 1
			while true do
				local first, last = content:find(edit.old_text, at, true)
				if not first then break end
				count, at = count + 1, last + 1
				if edit.replace_all ~= true then
					if content:find(edit.old_text, first + 1, true) then
						return H.fail(prefix .. "old_text matches more than once; include more surrounding text or set replace_all=true")
					end
					break
				end
				if count % 4096 == 0 then
					if clock.since(lastYield) >= 8 or count % 65536 == 0 then
						task.wait()
						lastYield = clock.ms()
					end
					if M.stopped(ctx) then return aborted("edit stopped before writing") end
				end
			end
			if count == 0 then return H.fail(prefix .. "old_text was not found; read the current file before editing") end
			if #content + count * (#edit.new_text - #edit.old_text) > M.MAX_BYTES then
				return H.fail(prefix .. "edited output would exceed 2 MB")
			end
			content = content:gsub(util.escapePattern(edit.old_text), function() return edit.new_text end)
			counts[#counts + 1], total = count, total + count
		end
		if M.stopped(ctx) then return aborted("edit stopped before writing") end
		local current, readErr = fsx.read(path, M.scope)
		if current == nil then return H.fail(readErr) end
		if current ~= original then return H.fail("file changed while preparing the edit; read it again") end
		if M.stopped(ctx) then return aborted("edit stopped before writing") end
		local resolved = fsx.resolve(path, M.scope)
		if content ~= original then
			local ok, result = fsx.write(path, content, M.scope)
			if not ok then return H.fail(result) end
			resolved = result
		end
		return {
			text = string.format("Replaced %d occurrence(s) in %s (%d bytes; %d edit(s), %s).",
				total, resolved, #content, #edits, content == original and "already unchanged" or "one write"),
			data = { edits = #edits, replacements = total, counts = counts, bytes = #content, changed = content ~= original },
		}
	end

	return M
end
