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

	return {
		{
			name = "file_list",
			risk = "read",
			needs = { "fs" },
			description = "List files in the agent's folder.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Subfolder, relative to the agent folder. Omit for the root." },
				},
				required = {},
			},
			run = function(args)
				local entries, err = fsx.list(args.path or "")
				if err then return H.fail(err) end
				if #entries == 0 then
					return "Nothing in " .. (util.trim(args.path) ~= "" and util.trim(args.path) or fsx.root) .. "."
				end
				return string.format("%d entr%s under %s/%s:\n%s",
					#entries, #entries == 1 and "y" or "ies", fsx.root, util.trim(args.path or ""),
					H.list(entries, 60, function(entry)
						return entry.path .. (entry.isDir and "/" or "")
					end))
			end,
		},
		{
			name = "file_read",
			risk = "read",
			needs = { "fs" },
			description = "Read a file from the agent's folder.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string", description = "Path relative to the agent folder, e.g. 'notes/plan.txt'." },
					-- The ceiling is what a model may ask for, not what it gets: whatever
					-- comes back is still cut to `agent.resultCap`. Twenty thousand was
					-- below every setting of that slider, which made a long file
					-- unreadable in one call even when the budget had room for it.
					limit = { type = "integer", description = "Maximum characters. Default 6000.", minimum = 200, maximum = 64000 },
				},
				required = { "path" },
			},
			run = function(args)
				local content, err = fsx.read(args.path)
				if not content then return H.fail(err) end
				local text, truncated = util.truncate(content, tonumber(args.limit) or READ_CAP)
				return string.format("%s (%d characters%s):\n%s",
					args.path, #content, truncated and ", trimmed" or "", text)
			end,
		},
		{
			name = "file_write",
			risk = "write",
			needs = { "fs" },
			description = "Write a file in the agent's folder, replacing it if it exists. Parent folders are created.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string" },
				},
				required = { "path", "content" },
			},
			run = function(args)
				local ok, result = fsx.write(args.path, args.content)
				if not ok then return H.fail(result) end
				return string.format("Wrote %d characters to %s", #tostring(args.content), result)
			end,
		},
		{
			name = "file_append",
			risk = "write",
			needs = { "fs" },
			description = "Append to a file in the agent's folder, creating it if needed.",
			parameters = {
				type = "object",
				properties = {
					path = { type = "string" },
					content = { type = "string" },
				},
				required = { "path", "content" },
			},
			run = function(args)
				local ok, result = fsx.append(args.path, args.content)
				if not ok then return H.fail(result) end
				return string.format("Appended %d characters to %s", #tostring(args.content), result)
			end,
		},
		{
			name = "file_delete",
			risk = "danger",
			needs = { "fs" },
			description = "Delete a file or folder from the agent's folder. This cannot be undone.",
			parameters = {
				type = "object",
				properties = { path = { type = "string" } },
				required = { "path" },
			},
			run = function(args)
				local ok, result = fsx.delete(args.path)
				if not ok then return H.fail(result) end
				return "Deleted " .. tostring(result)
			end,
		},
	}
end
