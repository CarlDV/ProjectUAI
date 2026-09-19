-- Fewer model round trips for finding, reading and editing workspace source.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local H = env.require("tools/helpers")
	local W = env.require("tools/workspace")

	local function readMany(args, ctx)
		local cap = H.resultBudget()
		if cap < 512 then return H.fail("batch reads need a result budget of at least 512 bytes") end
		local start = args.start_index or 1
		if start > #args.reads then return H.fail("start_index is beyond the reads array") end
		local lines, results, remaining = {}, {}, cap - 192
		-- Repeated slices share a read within this call, never across calls where
		-- source may have changed. Keep the total retained content bounded.
		local cache, cachedBytes = {}, 0
		local nextIndex, succeeded, stopped = start, 0, false
		for index = start, #args.reads do
			if W.stopped(ctx) then stopped = true; break end
			if remaining < 270 then break end
			local request = args.reads[index]
			local budget = math.min(remaining - 12, math.max(256, math.floor(remaining / (#args.reads - index + 1)) - 12))
			local cached = cache[request.path]
			local content, err
			if cached then content, err = cached.content, cached.error
			else
				content, err = W.read(request.path)
				if cachedBytes + #(content or "") <= W.MAX_BYTES then
					cache[request.path] = { content = content, error = err }
					cachedBytes = cachedBytes + #(content or "")
				end
			end
			local slice
			if content and #content > W.MAX_BYTES then
				slice = H.fail("this file exceeds the 2 MB batch limit; use file_read")
			elseif content then
				slice = H.readSlice(request.path, content, request, 1000, budget)
			else
				slice = H.fail(err)
			end
			local ok = slice.ok ~= false
			local text = ok and slice.text or (request.path .. ": " .. util.ellipsis(slice.text, math.max(32, budget - #request.path - 4)))
			text = "[" .. index .. "] " .. text
			if #text + 2 > remaining then break end
			lines[#lines + 1] = text
			remaining = remaining - #text - 2
			results[#results + 1] = { index = index, path = request.path, ok = ok, slice = slice.data, error = not ok and slice.text or nil }
			if ok then succeeded = succeeded + 1 end
			nextIndex = index + 1
			if index % 4 == 0 then task.wait() end
		end
		stopped = stopped or W.stopped(ctx)
		if nextIndex > #args.reads then nextIndex = nil end
		local header = string.format("%d file(s) read; %d failed.%s", succeeded, #results - succeeded, stopped and " Stopped." or "")
		local continuation = nextIndex and ("\nContinue with start_index=" .. nextIndex .. " using the same reads.") or ""
		return { ok = succeeded > 0 and not stopped, text = header .. "\n" .. table.concat(lines, "\n\n") .. continuation,
			data = { results = results, nextIndex = nextIndex, status = stopped and "aborted" or "completed" } }
	end

	local function search(args, ctx)
		if args.query:find("[\r\n%z]") then return H.fail("query must be a single-line literal") end
		local cap = H.resultBudget()
		if cap < 512 then return H.fail("file_search needs a result budget of at least 512 bytes") end
		local files, inventory = W.files(args.path or "", ctx)
		if not files then return H.fail(inventory) end
		local glob = args.glob or "*"
		if glob:find("[/\\]") then return H.fail("glob matches filenames; put the directory in path") end
		local selected = {}
		for _, path in ipairs(files) do
			if W.matches(path:match("[^/]+$") or path, glob) then selected[#selected + 1] = path end
		end
		local firstFile, firstLine = 1, 1
		if args.cursor then
			firstFile = nil
			for index, path in ipairs(selected) do if path == args.cursor.path then firstFile = index; break end end
			if not firstFile then return H.fail("cursor file is no longer in this search; restart with the current path and glob") end
			firstLine = args.cursor.line
		end
		local needle = args.case_sensitive and args.query or args.query:lower()
		local lines, hits, errors = {}, {}, inventory.errors
		local remaining, bytesRead, filesRead, scannedLines, skipped = cap - 320, 0, 0, 0, 0
		local nextCursor, stopped, limited = nil, inventory.reason == "aborted", inventory.reason
		local limit = args.limit or 20
		for fileIndex = firstFile, #selected do
			if stopped or W.stopped(ctx) then stopped = true; break end
			local path = selected[fileIndex]
			if bytesRead >= 8 * 1024 * 1024 then
				nextCursor, limited = { path = path, line = 1 }, "read budget"
				break
			end
			local content, err = fsx.read(path, W.scope)
			-- Hosts expose whole-file reads, not stat/range APIs. Count skipped
			-- data too, so large or binary files cannot bypass the page budget.
			if content then bytesRead = bytesRead + #content end
			if not content then
				errors[#errors + 1] = { path = path, error = util.ellipsis(err, 160) }
			elseif #content > W.MAX_BYTES or content:find("\0", 1, true) then
				skipped = skipped + 1
			else
				if bytesRead > 8 * 1024 * 1024 then
					nextCursor, limited = { path = path, line = 1 }, "read budget"
					break
				end
				filesRead = filesRead + 1
				local at, number = 1, 1
				if fileIndex == firstFile and args.cursor and args.cursor.offset then
					at, number = args.cursor.offset, firstLine
					if at > #content + 1 or (at > 1 and content:byte(at - 1) ~= 10) then
						return H.fail("cursor no longer points to a line boundary; restart this search")
					end
				end
				local walkedLines = 0
				while at <= #content do
					local eligible = fileIndex > firstFile or number >= firstLine
					if eligible and scannedLines >= 50000 then
						nextCursor, limited = { path = path, line = number, offset = at }, "line budget"
						break
					end
					local newline = content:find("\n", at, true)
					local last = newline and newline - 1 or #content
					local line = content:sub(at, last):gsub("\r$", "")
					walkedLines = walkedLines + 1
					if eligible then scannedLines = scannedLines + 1 end
					if walkedLines % 1024 == 0 then
						task.wait()
						if W.stopped(ctx) then stopped = true; break end
					end
					if eligible then
						local haystack = args.case_sensitive and line or line:lower()
						local found = haystack:find(needle, 1, true)
						if found then
							local from = math.max(1, found - 60)
							while from > 1 and line:byte(from) >= 128 and line:byte(from) < 192 do from = from - 1 end
							local excerpt = (from > 1 and "..." or "") .. util.ellipsis(line:sub(from), math.min(240, cap - 400))
							local hit = { path = path, line = number, offset = at + found - 1, excerpt = excerpt }
							local row = string.format("%s:%d (byte %d): %s", path, number, hit.offset, util.encode(excerpt))
							if #row + 1 > remaining then
								if #hits == 0 then return H.fail("a search result exceeds the output budget; increase agent.resultCap") end
								nextCursor = { path = path, line = number, offset = at }
								break
							end
							lines[#lines + 1], hits[#hits + 1] = row, hit
							remaining = remaining - #row - 1
							if #hits >= limit then
								if newline and newline < #content then nextCursor = { path = path, line = number + 1, offset = newline + 1 }
								elseif selected[fileIndex + 1] then nextCursor = { path = selected[fileIndex + 1], line = 1 } end
								break
							end
						end
					end
					at, number = last + (newline and 2 or 1), number + 1
				end
			end
			if nextCursor or stopped or #hits >= limit then break end
			if fileIndex % 8 == 0 then task.wait() end
		end
		stopped = stopped or W.stopped(ctx)
		local summary = string.format("%d matching line(s) in %d file(s) read; %d binary/large file(s) skipped; %d read error(s).",
			#hits, filesRead, skipped, #errors)
		if not inventory.complete and inventory.reason ~= "aborted" then summary = summary .. " Inventory incomplete; narrow path." end
		if stopped then summary = summary .. " Stopped." end
		if limited and limited ~= "aborted" then summary = summary .. " " .. limited .. "." end
		local footer = nextCursor and ("\nContinue with cursor=" .. util.encode(nextCursor) .. ".") or ""
		for index = 1, math.min(2, #errors) do
			local issue = errors[index]
			local row = "Read error: " .. util.ellipsis(issue.path, 100) .. ": " .. util.ellipsis(issue.error, 160)
			if #row + 1 <= remaining then
				lines[#lines + 1] = row
				remaining = remaining - #row - 1
			end
		end
		-- Long path cursors must never be lost to the registry's middle truncation.
		if #summary + #footer > 319 then summary = util.ellipsis(summary, math.max(20, 319 - #footer)) end
		return { ok = not stopped and (filesRead > 0 or #errors == 0), text = summary .. "\n" .. table.concat(lines, "\n") .. footer,
			data = { matches = hits, nextCursor = nextCursor, filesRead = filesRead, scannedLines = scannedLines,
				skipped = skipped, errors = errors, complete = not stopped and not nextCursor and inventory.complete and #errors == 0,
				status = stopped and "aborted" or "completed" } }
	end

	return {
		{
			name = "file_search", risk = "read", needs = { "fs" },
			description = "Find literal text across workspace files in one call. Returns matching lines, byte offsets and a continuation cursor. Searches subfolders; skips binary/files over 2 MB. Bounds directory, file and byte scans.",
			parameters = { type = "object", properties = {
				query = { type = "string", minLength = 1, maxLength = 256, description = "Single-line literal; not a regex." },
				path = { type = "string", description = "Workspace file or directory. Default workspace root." },
				glob = { type = "string", maxLength = 128, description = "Filename glob at any depth, e.g. *.lua. Default *." },
				case_sensitive = { type = "boolean", description = "Default false." },
				limit = { type = "integer", minimum = 1, maximum = 100, description = "Matching lines per page. Default 20." },
				cursor = { type = "object", properties = {
					path = { type = "string", minLength = 1 }, line = { type = "integer", minimum = 1 },
					offset = { type = "integer", minimum = 1, description = "Returned byte offset to resume without rescanning earlier lines." },
				}, required = { "path", "line" } },
			}, required = { "query" } },
			run = search,
		},
		{
			name = "file_read_many", risk = "read", needs = { "fs" },
			description = "Read up to 12 workspace files or saved pastes in one call, sharing the result budget. Each slice includes continuation offsets. Individual failures preserve other results.",
			parameters = { type = "object", properties = {
				reads = { type = "array", minItems = 1, maxItems = 12, items = {
					type = "object", properties = {
						path = { type = "string", minLength = 1, maxLength = 220 },
						offset = { type = "integer", minimum = 1 },
						limit = { type = "integer", minimum = 64, maximum = 16000, description = "Bytes per file, default 1000; bounded by remaining result budget." },
					}, required = { "path" },
				} },
				start_index = { type = "integer", minimum = 1, maximum = 12, description = "Resume at this 1-based request index if the previous page filled." },
			}, required = { "reads" } },
			run = readMany,
		},
		{
			name = "file_edit_many", risk = "write", needs = { "fs" },
			description = "Apply up to 20 exact edits to one workspace file in one write. Edits are evaluated in order. All must validate before writing; refuses stale contents. Empty new_text deletes. File/output limit 2 MB.",
			parameters = { type = "object", properties = {
				path = { type = "string", minLength = 1 },
				edits = { type = "array", minItems = 1, maxItems = 20, items = {
					type = "object", properties = {
						old_text = { type = "string", minLength = 1 },
						new_text = { type = "string" },
						replace_all = { type = "boolean", description = "Default false requires a unique match." },
					}, required = { "old_text", "new_text" },
				} },
			}, required = { "path", "edits" } },
			run = function(args, ctx) return W.edit(args.path, args.edits, ctx) end,
		},
	}
end
