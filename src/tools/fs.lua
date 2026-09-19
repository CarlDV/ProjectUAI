-- Files, scoped to the client's own folder.
--
-- Everything lives under one app folder so an uninstall is one delete, and the
-- path parser rejects `..` outright -- a path here arrives from a model, and
-- letting it walk up into the executor's workspace is the kind of thing that only
-- looks harmless until it deletes something.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local H = env.require("tools/helpers")

	local READ_CAP = 6000

	-- The agent's workspace. Everything the file tools touch lives under files/, so
	-- model-authored output never lands beside the client's own config.json, sessions/
	-- or stats.json -- a root with all of both mixed in it is the mess this fixes.
	-- The scope is one option on every fsx call rather than a prefix on every path,
	-- so a model that writes 'notes/plan.txt' gets files/notes/plan.txt without
	-- having to know the prefix exists.
	local SCOPE = { scope = "files" }

	return {
		{
			name = "file_list",
			risk = "read",
			needs = { "fs" },
			description = "List files in your workspace (" .. "files/, inside the agent folder).",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Subfolder, relative to your workspace. Omit for the root of it." },
				},
				required = {},
			},
			run = function(args)
				local entries, err = fsx.list(args.path or "", SCOPE)
				if err then return H.fail(err) end
				if #entries == 0 then
					return "Nothing in " .. (util.trim(args.path) ~= "" and util.trim(args.path) or "your workspace") .. "."
				end
				return string.format("%d entr%s under files/%s:\n%s",
					#entries, #entries == 1 and "y" or "ies", util.trim(args.path or ""),
					H.list(entries, 60, function(entry)
						return entry.path .. (entry.isDir and "/" or "")
					end))
			end,
		},
		{
			name = "file_read",
			risk = "read",
			needs = { "fs" },
			description = "Read a contiguous slice of a workspace file or saved paste. The result includes a continuation offset when more remains.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Path relative to your workspace, e.g. 'notes/plan.txt'. Pasted long messages are under 'pastes/'." },
					-- The ceiling is what a model may ask for, not what it gets: whatever
					-- comes back is still cut to `agent.resultCap`. Twenty thousand was
					-- below every setting of that slider, which made a long file
					-- unreadable in one call even when the budget had room for it.
					limit = { type = "integer", description = "Maximum bytes in this slice. Default 6000; also bounded by the tool result budget.", minimum = 200, maximum = 64000 },
					offset = { type = "integer", minimum = 1, description = "1-based byte offset. Use the continuation offset from the previous result to read the rest." },
				},
				required = { "path" },
			},
			run = function(args)
				-- The tools' own scope first, then pastes: a pasted block is the one file
				-- the user places rather than the agent, so it is reachable by the bare
				-- name the toast showed without the agent having to know where it lives.
				local content, err = fsx.read(args.path, SCOPE)
				if not content and not fsx.exists(args.path, SCOPE) then
					local path = tostring(args.path):gsub("\\", "/")
					local rootPrefix = fsx.root .. "/pastes/"
					if util.startsWith(path, rootPrefix) then path = path:sub(#rootPrefix + 1)
					elseif util.startsWith(path, "pastes/") then path = path:sub(8) end
					content, err = fsx.read(path, { scope = "pastes" })
				end
				if not content then return H.fail(err) end
				return H.readSlice(args.path, content, args, READ_CAP)
			end,
		},
		{
			name = "file_edit",
			risk = "write",
			needs = { "fs" },
			description = "Replace exact text in a workspace file without rewriting the whole file. Read it first. Refuses missing or ambiguous matches unless replace_all is true, and refuses an edit if the file changed while it was being prepared. Files and edited output are limited to 2 MB.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					old_text = { type = "string", minLength = 1, description = "Exact existing text to replace, including whitespace. Must not be empty." },
					new_text = { type = "string", description = "Replacement text; empty deletes the matched text." },
					replace_all = { type = "boolean", description = "Replace all non-overlapping occurrences. Default false requires exactly one match." },
				},
				required = { "path", "old_text", "new_text" },
			},
			run = function(args, ctx)
				if args.old_text == "" then return H.fail("old_text must not be empty") end
				local content, err = fsx.read(args.path, SCOPE)
				if not content then return H.fail(err) end
				local maxBytes = 2 * 1024 * 1024
				if #content > maxBytes then return H.fail("file_edit supports files up to 2 MB") end
				local count, at = 0, 1
				while true do
					local first, last = content:find(args.old_text, at, true)
					if not first then break end
					count, at = count + 1, last + 1
					if args.replace_all ~= true then
						if content:find(args.old_text, first + 1, true) then
							return H.fail("old_text matches more than once; include more surrounding text or set replace_all=true")
						end
						break
					end
					if count % 4096 == 0 then
						task.wait()
						if ctx and ctx.aborted and ctx.aborted() then return H.fail("edit stopped before writing") end
					end
				end
				if count == 0 then return H.fail("old_text was not found; read the current file before editing") end
				if #content + count * (#args.new_text - #args.old_text) > maxBytes then
					return H.fail("edited output would exceed 2 MB")
				end
				local updated = content:gsub(util.escapePattern(args.old_text), function() return args.new_text end)
				if ctx and ctx.aborted and ctx.aborted() then return H.fail("edit stopped before writing") end
				local current, readErr = fsx.read(args.path, SCOPE)
				if current == nil then return H.fail(readErr) end
				if current ~= content then return H.fail("file changed while preparing the edit; read it again") end
				local ok, result = fsx.write(args.path, updated, SCOPE)
				if not ok then return H.fail(result) end
				return string.format("Replaced %d occurrence(s) in %s (%d bytes).", count, result, #updated)
			end,
		},
		{
			name = "file_write",
			risk = "write",
			needs = { "fs" },
			description = "Write a file in your workspace (files/), replacing it if it exists. Parent folders are created.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string" },
				},
				required = { "path", "content" },
			},
			run = function(args)
				local ok, result = fsx.write(args.path, args.content, SCOPE)
				if not ok then return H.fail(result) end
				return string.format("Wrote %d characters to %s", #tostring(args.content), result)
			end,
		},
		{
			name = "file_append",
			risk = "write",
			needs = { "fs" },
			description = "Append to a file in your workspace, creating it if needed.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string" },
				},
				required = { "path", "content" },
			},
			run = function(args)
				local ok, result = fsx.append(args.path, args.content, SCOPE)
				if not ok then return H.fail(result) end
				return string.format("Appended %d characters to %s", #tostring(args.content), result)
			end,
		},
		{
			name = "file_delete",
			risk = "danger",
			needs = { "fs" },
			description = "Delete a file or folder from your workspace. This cannot be undone.",
			parameters = {
				type = "object",
				properties = { path = { type = "string" } },
				required = { "path" },
			},
			run = function(args)
				local ok, result = fsx.delete(args.path, SCOPE)
				if not ok then return H.fail(result) end
				return "Deleted " .. tostring(result)
			end,
		},
	}
end
