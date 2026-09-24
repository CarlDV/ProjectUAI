-- Shared machinery for the tool groups: path resolution, value conversion in both
-- directions, and the formatting conventions every tool result follows.
--
-- Two rules drive the design. Model output is untrusted text, so a path or a
-- property value is parsed rather than trusted. And a tool result is read by a
-- model, not a person, so it is dense, labelled, and bounded -- a wall of
-- unlabelled values costs tokens and teaches nothing.
return function(env)
	local util = env.require("runtime/util")

	local H = {}

	-- Paths ------------------------------------------------------------------

	local paths = env.require("runtime/instance_paths")
	H.resolve, H.pathOf, H.ROOT_NAMES = paths.resolve, paths.pathOf, paths.ROOT_NAMES

	local legacy = env.require("runtime/legacy_values")
	H.show, H.coerce = legacy.show, legacy.coerce

	-- Formatting -------------------------------------------------------------

	function H.describe(instance)
		if not instance then return "nil" end
		local extra = {}
		local ok = pcall(function()
			if instance:IsA("BasePart") then
				extra[#extra + 1] = "at " .. H.show(instance.Position)
			elseif instance:IsA("GuiObject") then
				extra[#extra + 1] = "size " .. H.show(instance.Size)
			elseif instance:IsA("Humanoid") then
				extra[#extra + 1] = string.format("health %s/%s", H.show(instance.Health), H.show(instance.MaxHealth))
			end
		end)
		local childCount = 0
		pcall(function() childCount = #instance:GetChildren() end)
		if childCount > 0 then extra[#extra + 1] = util.pluralise(childCount, "child") end
		return string.format("%s [%s]%s", instance.Name, instance.ClassName,
			(ok and #extra > 0) and (" " .. table.concat(extra, ", ")) or "")
	end

	-- Numbered list with an explicit note when it was cut short, so a model can
	-- tell "that is everything" from "there is more".
	function H.list(items, limit, render)
		local lines = {}
		local shown = math.min(#items, limit or #items)
		for index = 1, shown do
			lines[#lines + 1] = string.format("%d. %s", index, render and render(items[index], index) or tostring(items[index]))
		end
		if #items > shown then
			lines[#lines + 1] = string.format("... %d more (narrow the query to see them)", #items - shown)
		end
		if #lines == 0 then return "(none)" end
		return table.concat(lines, "\n")
	end

	function H.keyValues(pairsList)
		local lines = {}
		for _, entry in ipairs(pairsList) do
			lines[#lines + 1] = entry[1] .. ": " .. tostring(entry[2])
		end
		return table.concat(lines, "\n")
	end

	function H.limit(value, fallback, ceiling)
		local number = tonumber(value) or fallback
		return math.floor(util.clamp(number, 1, ceiling or 200))
	end

	-- A contiguous, resumable slice. Leave room for its cursor inside the registry's
	-- result budget so a second truncation cannot silently remove the middle.
	function H.resultBudget()
		return tonumber(env.require("runtime/config").get("agent.resultCap", 4000)) or 4000
	end

	function H.readSlice(name, content, args, defaultLimit, budget)
		args = args or {}
		local cap = math.min(H.resultBudget(), budget or math.huge)
		if cap < 256 then return H.fail("increase the tool result budget to at least 256 bytes before reading files") end
		local offset = math.max(1, math.floor(tonumber(args.offset) or 1))
		if offset > #content + 1 then return H.fail("offset is past the end; this source has " .. #content .. " bytes") end
		while offset > 1 do
			local byte = content:byte(offset)
			if not byte or byte < 128 or byte >= 192 then break end
			offset = offset - 1
		end
		local label = util.ellipsis(name, 100)
		local limit = math.max(4, math.min(tonumber(args.limit) or defaultLimit or 6000, cap - 220))
		local last = math.min(#content, offset + math.floor(limit) - 1)
		while last >= offset and last < #content do
			local byte = content:byte(last + 1)
			if byte < 128 or byte >= 192 then break end
			last = last - 1
		end
		local nextOffset = last < #content and last + 1 or nil
		local header = string.format("%s (bytes %d-%d of %d%s):\n", label, offset, last, #content,
			nextOffset and ("; continue with offset=" .. nextOffset) or "; end of file")
		if #content == 0 then header = label .. " (empty, 0 bytes):\n" end
		return { text = header .. content:sub(offset, last), data = {
			offset = offset, nextOffset = nextOffset, totalBytes = #content, eof = nextOffset == nil,
		} }
	end

	-- A tool that could not do what was asked returns this rather than a bare
	-- string, so the registry can mark the call as failed and the transcript can
	-- colour it. The model sees the same sentence either way.
	function H.fail(message)
		return { ok = false, text = "Failed: " .. tostring(message) }
	end

	-- A tool that changed something says what it changed and where, because the
	-- next turn often needs the path again.
	function H.changed(what, where, detail)
		return string.format("%s on %s%s", what, where, detail and (" -> " .. detail) or "")
	end

	return H
end
