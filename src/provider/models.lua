-- Model discovery and the record's own model list.
--
-- The endpoint is the only authority on what it serves, so nothing here invents a
-- model id. Two sources, in this order:
--
--   1. what the user added by hand, which always wins because they typed it
--   2. what GET /v1/models reported, cached for the session
--
-- Nothing is filtered out of a provider's answer. A local server that also serves
-- embedding models will list them; hiding entries would mean guessing which ones
-- are chat models, which is the thing this module refuses to do.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local http = env.require("net/http")
	local registry = env.require("provider/registry")
	local signal = env.require("runtime/signal")

	local CACHE_MS = 10 * 60 * 1000

	local M = {
		cache = {},
		changed = signal.new("models"),
	}

	function M.cached(providerId)
		local entry = M.cache[providerId]
		if not entry then return nil end
		if clock.since(entry.at) > CACHE_MS then return nil end
		return entry.models
	end

	function M.discovered(record)
		return M.cached(record.id) or {}
	end

	-- Manual entry. The id is stored on the record, so it survives a restart and is
	-- offered first from then on.
	function M.add(record, id, opts)
		opts = opts or {}
		local clean = util.trim(id)
		if clean == "" then return false, "type a model id" end
		if #clean > 160 then return false, "that does not look like a model id" end
		record.models = record.models or {}
		for _, existing in ipairs(record.models) do
			if existing == clean then
				if opts.select then record.model = clean end
				return false, "already in the list"
			end
		end
		table.insert(record.models, 1, clean)
		if opts.select ~= false then record.model = clean end
		if opts.persist ~= false then registry.save(record, { force = true }) end
		M.changed:fire(record.id, record.models)
		return true, clean
	end

	function M.remove(record, id, opts)
		opts = opts or {}
		local kept = {}
		local removed = false
		for _, existing in ipairs(record.models or {}) do
			if existing == id then
				removed = true
			else
				kept[#kept + 1] = existing
			end
		end
		record.models = kept
		if record.model == id then record.model = kept[1] or "" end
		if removed then
			if opts.persist ~= false then registry.save(record, { force = true }) end
			M.changed:fire(record.id, kept)
		end
		return removed
	end

	-- The merged list, without touching the network.
	function M.list(record)
		local out, seen = {}, {}
		for _, id in ipairs(record.models or {}) do
			if util.trim(id) ~= "" and not seen[id] then
				seen[id] = true
				out[#out + 1] = id
			end
		end
		for _, id in ipairs(M.cached(record.id) or {}) do
			if not seen[id] then
				seen[id] = true
				out[#out + 1] = id
			end
		end
		return out
	end

	-- Yields. Returns the discovered ids and a note describing what happened, which
	-- the panel shows next to the fetch control. A provider with no /models route is
	-- a normal outcome, not an error: the user types the id instead.
	function M.discover(record, opts)
		opts = opts or {}
		if not opts.force then
			local hit = M.cached(record.id)
			if hit then return hit, "cached" end
		end

		local url = registry.endpoint(record, "/models")
		local headers = env.require("provider/chat").headers(record)

		local decoded, err, res = http.json({
			url = url,
			method = "GET",
			headers = headers,
			identity = (record.claudeUa ~= false) and "claude" or "none",
			attempts = 2,
			tag = "models:" .. record.id,
		})

		if not decoded then
			local note = "could not read " .. url
			if res and res.status == 404 then note = "this endpoint has no /models route -- add a model by hand" end
			if res and res.status == 401 then note = "the API key was rejected" end
			if res and res.status == 403 then note = "the key is not allowed to list models" end
			log.info("models", record.label .. ": " .. note, err)
			return {}, note
		end

		-- The documented shape is { data = { { id = ... } } }. Some servers answer
		-- with a bare array, and Ollama answers with { models = { { name = ... } } }.
		local rows = decoded.data or decoded.models or decoded
		local found, seen = {}, {}
		if type(rows) == "table" then
			for _, row in ipairs(rows) do
				local id
				if type(row) == "string" then
					id = row
				elseif type(row) == "table" then
					id = row.id or row.name or row.model
				end
				if type(id) == "string" and util.trim(id) ~= "" and not seen[id] then
					seen[id] = true
					found[#found + 1] = util.trim(id)
				end
			end
		end

		table.sort(found)
		M.cache[record.id] = { at = clock.ms(), models = found }
		M.changed:fire(record.id, found)

		if #found == 0 then
			return {}, "the endpoint returned an empty list -- add a model by hand"
		end
		return found, string.format("%d model%s from %s", #found, #found == 1 and "" or "s", url)
	end

	function M.invalidate(providerId)
		if providerId then
			M.cache[providerId] = nil
		else
			M.cache = {}
		end
	end

	return M
end
