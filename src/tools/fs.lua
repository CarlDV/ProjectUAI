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
	local W = env.require("tools/workspace")

	local READ_CAP = 6000

	-- The agent's workspace. Everything the file tools touch lives under files/, so
	-- model-authored output never lands beside the client's own config.json, sessions/
	-- or stats.json -- a root with all of both mixed in it is the mess this fixes.
	-- The scope is one option on every fsx call rather than a prefix on every path,
	-- so a model that writes 'notes/plan.txt' gets files/notes/plan.txt without
	-- having to know the prefix exists.
	local SCOPE = { scope = "files" }

	local tools = {
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
				local content, err, resolved = W.read(args.path)
				if not content then return H.fail(err) end
				local budget = resolved and util.startsWith(resolved, "pastes/") and (READ_CAP + 220) or nil
				return H.readSlice(args.path, content, args, READ_CAP, budget)
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
				return W.edit(args.path, { args }, ctx)
			end,
		},
		{
			name = "file_write",
			risk = "write",
			needs = { "fs" },
			description = "Create a workspace file or replace most of its content (up to 2 MiB per call). Parent folders are created. "
				.. "For existing files, prefer file_edit or file_edit_many for targeted changes. Build large new scripts in small sections with sequential file_write then file_append calls.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string", maxLength = W.MAX_BYTES },
				},
				required = { "path", "content" },
			},
			run = function(args)
				if type(args.content) ~= "string" or #args.content > W.MAX_BYTES then return H.fail("content must be a string of at most 2 MiB; use targeted edits for existing files") end
				local ok, result = fsx.write(args.path, args.content, SCOPE)
				if not ok then return H.fail(result) end
				return string.format("Wrote %d characters to %s", #tostring(args.content), result)
			end,
		},
		{
			name = "file_append",
			risk = "write",
			needs = { "fs" },
			description = "Append up to 2 MiB to a workspace file, creating it if needed. Prefer small additions.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string", maxLength = W.MAX_BYTES },
				},
				required = { "path", "content" },
			},
			run = function(args)
				if type(args.content) ~= "string" or #args.content > W.MAX_BYTES then return H.fail("content must be a string of at most 2 MiB") end
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
	for _, tool in ipairs(env.require("tools/fs_bulk")) do tools[#tools + 1] = tool end
	return tools
end
