-- User-provided text lives in real files, outside the model's conversation.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local clock = env.require("runtime/clock")
	local M = { INLINE_LIMIT = 8000, MAX_BYTES = 2 * 1024 * 1024, READ_BYTES = 6000 }
	local pending = {}
	local SCOPE = { scope = "pastes" }

	local function filename(value)
		local name = tostring(value or "pasted-input.txt"):gsub("\\", "/"):match("[^/]+$") or "pasted-input.txt"
		name = name:gsub('[%z\1-\31\127<>:"|%?%*]', "_"):gsub("[%. ]+$", "")
		if #name == 0 or #name > 80 then name = "pasted-input.txt" end
		return name
	end

	function M.reference(entry)
		return string.format("[Attached file: %s (%d bytes, %d lines)]\nPath: %s\nRead relevant sections with file_read (offset/limit) or find text with file_search. The complete input is in this file.",
			filename(entry.name or entry.label), entry.bytes, entry.lines, entry.path)
	end

	function M.describe(path, content, name)
		local _, breaks = content:gsub("\n", "")
		return { file = true, path = path, name = filename(name or path), label = filename(name or path),
			bytes = #content, lines = #content == 0 and 0 or breaks + 1 }
	end

	function M.save(content, name)
		if type(content) ~= "string" or #content == 0 then return nil, "the attachment is empty" end
		if #content > M.MAX_BYTES then return nil, "attachments support up to 2 MiB; split this input into smaller files" end
		if content:find("\0", 1, true) then return nil, "attach a text or code file; binary files are not supported" end
		if not fsx.enabled then return nil, "file storage is unavailable on this host; long input was kept in your draft" end
		name = filename(name)
		local path
		-- A counter alone repeats after a reload. Check the actual destination too.
		for _ = 1, 100 do
			local candidate = os.date("!%Y%m%d-%H%M%S") .. "-" .. util.uid("input") .. "-" .. name
			if not fsx.exists(candidate, SCOPE) then path = candidate; break end
		end
		if not path then return nil, "could not allocate a new attachment file" end
		local ok, err = fsx.write(path, content, SCOPE)
		if not ok then return nil, "could not save attachment: " .. tostring(err) end
		local saved, readErr = fsx.read(path, SCOPE)
		if saved ~= content then return nil, "could not verify the saved attachment: " .. tostring(readErr or "file contents differ") end
		return M.describe("pastes/" .. path, content, name)
	end

	-- Identify one inserted block without swallowing the question on either side.
	-- TextBox gives a new value, not clipboard data, so compare the two versions.
	function M.inserted(before, after)
		if #after - #before <= M.INLINE_LIMIT then return nil end
		local first, last = 0, 0
		while first < #before and first < #after and before:byte(first + 1) == after:byte(first + 1) do first = first + 1 end
		while first > 0 and after:byte(first + 1) and after:byte(first + 1) >= 128 and after:byte(first + 1) < 192 do first = first - 1 end
		while last < #before - first and last < #after - first and before:byte(#before - last) == after:byte(#after - last) do last = last + 1 end
		while last > 0 and after:byte(#after - last + 1) >= 128 and after:byte(#after - last + 1) < 192 do last = last - 1 end
		local inserted = after:sub(first + 1, #after - last)
		if #inserted <= M.INLINE_LIMIT then return nil end
		return inserted, after:sub(1, first) .. after:sub(#after - last + 1)
	end

	-- Browser uploads travel separately from send, in bounded, ordered chunks.
	-- Only a verified final write produces a file reference. Retries are idempotent.
	function M.upload(owner, args)
		local now, active, retained = clock.ms(), 0, 0
		for id, item in pairs(pending) do
			if now - item.at > 600000 then pending[id] = nil
			else active = active + 1; retained = retained + (item.result and 0 or item.bytes) end
		end
		local id, content, offset = args.uploadId, args.content, args.offset
		if type(id) ~= "string" or #id < 8 or #id > 100 or not id:match("^[%w_-]+$") then return nil, "invalid upload ID" end
		if type(content) ~= "string" or #content > 128 * 1024 then return nil, "upload chunks must be at most 128 KiB" end
		if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 then return nil, "invalid upload offset" end
		local item = pending[id]
		if item and item.owner ~= owner then return nil, "upload belongs to another conversation" end
		if item and item.lastOffset == offset and item.lastContent == content and item.final == (args.final == true) then
			return item.result or { received = item.bytes }
		end
		if item and item.result then return nil, "upload ID already belongs to a completed file" end
		if not item then
			if offset ~= 0 then return nil, "upload expired; start again" end
			if active >= 64 then return nil, "too many uploads; retry after earlier uploads expire" end
			item = { owner = owner, name = filename(args.name), parts = {}, bytes = 0, at = now }
			pending[id] = item
		end
		if offset ~= item.bytes then return nil, "upload offset does not match received bytes" end
		if item.bytes + #content > M.MAX_BYTES or retained + #content > 8 * 1024 * 1024 then return nil, "upload exceeds the file or pending upload budget" end
		item.parts[#item.parts + 1], item.bytes, item.at = content, item.bytes + #content, now
		item.lastOffset, item.lastContent, item.final = offset, content, args.final == true
		if args.final ~= true then return { received = item.bytes } end
		local entry, err = M.save(table.concat(item.parts), item.name)
		if not entry then pending[id] = nil; return nil, err end
		entry.reference = M.reference(entry)
		item.result, item.parts = entry, nil
		return entry
	end

	function M.clearUploads(owner)
		for id, item in pairs(pending) do if owner == nil or item.owner == owner then pending[id] = nil end end
	end

	return M
end
