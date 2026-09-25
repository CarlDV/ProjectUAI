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
	local urls = env.require("net/url")

	local CACHE_MS = 10 * 60 * 1000

	local M = {
		cache = setmetatable({}, { __mode = "k" }),
		changed = signal.new("models"),
	}

	local pending = setmetatable({}, { __mode = "k" })
	local function keyFor(record)
		return util.trim(record.id) ~= "" and record.id or record
	end
	local function scopeFor(record)
		return util.deepCopy({ baseUrl = registry.normaliseBaseUrl(record.baseUrl), api = record.api or "openai",
			apiKey = record.apiKey, authStyle = record.authStyle, headers = record.headers or {}, query = record.query or {},
			claudeUa = record.claudeUa })
	end
	local function same(a, b)
		if type(a) ~= type(b) then return false end
		if type(a) ~= "table" then return a == b end
		for key, value in pairs(a) do if not same(value, b[key]) then return false end end
		for key in pairs(b) do if a[key] == nil then return false end end
		return true
	end

	function M.cached(recordOrId)
		local record = type(recordOrId) == "table" and recordOrId or registry.get(recordOrId)
		local entry = M.cache[record and keyFor(record) or recordOrId]
		if not entry then return nil end
		if clock.since(entry.at) > CACHE_MS then return nil end
		if record and not same(entry.scope, scopeFor(record)) then return nil end
		return entry.models
	end

	function M.discovered(record)
		return M.cached(record) or {}
	end

	-- A catalog label is not permission to use the model. Zen documents Big
	-- Pickle as free despite its unsuffixed id; only apply that alias on Zen.
	-- Other ids use a distinct "free" token rather than matching "freedom".
	function M.isFree(record, id)
		local name = tostring(id or ""):lower()
		if registry.isOpencode(record) and name == "big-pickle" then return true end
		return name:find("%f[%a]free%f[%A]") ~= nil
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
		for _, id in ipairs(M.cached(record) or {}) do
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
		local problem = registry.protocolProblem(record)
		if problem then return {}, problem end
		if not opts.force then
			local hit = M.cached(record)
			if hit then return hit, "cached" end
		end

		local key, token, scope = keyFor(record), {}, scopeFor(record)
		pending[key] = token
		local snapshot = util.deepCopy(record)
		local url = registry.endpoint(snapshot, "/models")
		local headers = env.require("provider/chat").headers(snapshot)

		local decoded, err, res = http.json({
			url = url,
			method = "GET",
			headers = headers,
			identity = registry.identityFor(snapshot),
			identityRequired = registry.requiresClaude(snapshot),
			attempts = 2,
			timeout = opts.timeout,
			aborted = opts.aborted,
			tag = "models:" .. tostring(record.id or "draft"),
		})

		if pending[key] ~= token or not same(scope, scopeFor(record)) then
			if pending[key] == token then pending[key] = nil end
			return {}, "model discovery was superseded or the connection changed -- fetch again"
		end
		pending[key] = nil
		if not res or not res.ok or type(decoded) ~= "table" or decoded.error ~= nil then
			local note = "could not read the model list"
			if res and res.status == 404 then note = "this endpoint has no /models route -- add a model by hand" end
			if res and res.status == 401 then note = "the API key was rejected" end
			if res and res.status == 403 then note = "the key is not allowed to list models" end
			if res and res.status ~= 401 and res.status ~= 403 and res.status ~= 404 then
				note = note .. ": " .. env.require("provider/chat").errorText(snapshot, res, err)
			end
			log.info("models", tostring(record.label) .. ": " .. note, err)
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
				id = type(id) == "string" and util.trim(id) or ""
				if id ~= "" and not seen[id] then
					seen[id] = true
					found[#found + 1] = id
				end
			end
		end

		table.sort(found)
		M.cache[key] = { at = clock.ms(), models = found, scope = scope }
		M.changed:fire(record.id, found)

		if #found == 0 then
			return {}, "the endpoint returned an empty list -- add a model by hand"
		end
		return found, string.format("%d model%s from %s", #found, #found == 1 and "" or "s", urls.display(url))
	end

	function M.invalidate(providerId)
		if providerId then
			local key = type(providerId) == "table" and keyFor(providerId) or providerId
			M.cache[key], pending[key] = nil, nil
		else
			M.cache = setmetatable({}, { __mode = "k" })
			pending = setmetatable({}, { __mode = "k" })
		end
	end

	return M
end
