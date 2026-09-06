-- Provider records: creation, validation, persistence, health and fallback order.
--
-- A record is the whole description of one endpoint, so switching provider is a
-- data change rather than a code path. Nothing above this module knows which
-- vendor is in use.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local caps = env.require("runtime/caps")
	local clock = env.require("runtime/clock")
	local log = env.require("runtime/log")
	local signal = env.require("runtime/signal")
	local catalog = env.require("provider/catalog")

	local COOLDOWN_AFTER = 3
	local COOLDOWN_SECONDS = 45

	local M = {
		changed = signal.new("providers"),
	}

	-- Base URL normalisation, done once on save so no request path has to guess.
	--
	--   api.openai.com            -> https://api.openai.com/v1
	--   https://x.dev/            -> https://x.dev/v1
	--   https://x.dev/openai/v1   -> unchanged (it already names a path)
	--   https://x.dev/v1/chat/completions -> unchanged, used verbatim
	function M.normaliseBaseUrl(raw)
		local text = util.trim(raw)
		if text == "" then return "" end
		if not text:find("^https?://") then text = "https://" .. text end
		text = text:gsub("/+$", "")
		local scheme, rest = text:match("^(https?://)(.*)$")
		if not scheme then return text end
		local hostAndPath = rest
		local path = hostAndPath:match("^[^/]+(/.*)$")
		if not path or path == "" then
			return text .. "/v1"
		end
		return text
	end

	function M.isFullEndpoint(url)
		return tostring(url):find("/chat/completions$") ~= nil
	end

	function M.endpoint(record, suffix)
		local base = record.baseUrl or ""
		local url
		if M.isFullEndpoint(base) then
			url = (suffix == "/chat/completions") and base or (base:gsub("/chat/completions$", "") .. suffix)
		else
			url = base .. suffix
		end
		local query = {}
		for key, value in pairs(record.query or {}) do
			query[#query + 1] = util.urlEncode(key) .. "=" .. util.urlEncode(value)
		end
		if #query > 0 then
			url = url .. (url:find("%?") and "&" or "?") .. table.concat(query, "&")
		end
		return url
	end

	function M.authHeaders(record)
		local key = util.trim(record.apiKey)
		local style = record.authStyle or "bearer"
		if key == "" or style == "none" then return {} end
		if style == "x-api-key" then return { ["x-api-key"] = key } end
		if style == "api-key" then return { ["api-key"] = key } end
		if style == "both" then
			return { ["Authorization"] = "Bearer " .. key, ["x-api-key"] = key }
		end
		return { ["Authorization"] = "Bearer " .. key }
	end

	-- A record always has every field, so no consumer needs a nil check.
	function M.blank(presetId)
		local preset = catalog.get(presetId or "custom") or catalog.get("custom")
		return {
			id = "",
			preset = preset.id,
			label = preset.label,
			baseUrl = preset.baseUrl,
			apiKey = "",
			authStyle = preset.authStyle or "bearer",
			-- Which wire protocol the record speaks. Absent means chat completions,
			-- which is what every record saved before the second adapter existed has.
			api = preset.api or "openai",
			models = util.deepCopy(preset.models or {}),
			model = (preset.models or {})[1] or "",
			headers = util.deepCopy(preset.headers or {}),
			params = util.deepCopy(preset.params or {}),
			query = util.deepCopy(preset.query or {}),
			stream = true,
			claudeUa = preset.claudeUa ~= nil and preset.claudeUa or true,
			enabled = true,
			order = 0,
			wsUrl = "",
			note = preset.note,
			requires = preset.requires,
			health = { ok = 0, fail = 0, streak = 0, lastError = "", cooldownUntil = 0, lastMs = 0 },
		}
	end

	local function ensureId(wanted)
		local base = util.trim(wanted):lower():gsub("[^%w%-_]", "-"):gsub("%-+", "-"):gsub("^%-", "")
		if base == "" then base = "provider" end
		local taken = {}
		for _, record in ipairs(M.list()) do taken[record.id] = true end
		if not taken[base] then return base end
		for index = 2, 99 do
			local candidate = base .. "-" .. tostring(index)
			if not taken[candidate] then return candidate end
		end
		return base .. "-" .. tostring(clock.ms())
	end

	function M.list()
		local stored = config.get("providers.list", {})
		if type(stored) ~= "table" then return {} end
		local out = {}
		for _, record in ipairs(stored) do
			if type(record) == "table" then out[#out + 1] = record end
		end
		table.sort(out, function(a, b)
			if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
			return tostring(a.id) < tostring(b.id)
		end)
		return out
	end

	function M.get(id)
		for _, record in ipairs(M.list()) do
			if record.id == id then return record end
		end
		return nil
	end

	function M.count()
		return #M.list()
	end

	-- Validation is deliberately about reachability, not taste: a record with a
	-- plausible URL and, where needed, a key is allowed even if the vendor turns
	-- out to reject it. The health counters are what report that.
	function M.validate(record)
		local problems = {}
		if util.trim(record.label) == "" then problems[#problems + 1] = "give the provider a name" end
		local base = M.normaliseBaseUrl(record.baseUrl)
		if base == "" then
			problems[#problems + 1] = "base URL is required"
		elseif not base:find("^https?://[^/]+") then
			problems[#problems + 1] = "base URL does not look like a URL"
		end
		if (record.authStyle or "bearer") ~= "none" and util.trim(record.apiKey) == "" then
			problems[#problems + 1] = "an API key is required for this auth style"
		end
		-- Azure takes the model from the deployment in the URL; everyone else needs
		-- one named, and nothing here will guess it.
		if record.preset ~= "azure" and util.trim(record.model) == "" then
			problems[#problems + 1] = "fetch the model list or add a model id"
		end
		if record.requires == "executor" and caps.http ~= "executor" then
			problems[#problems + 1] = "this endpoint needs an executor HTTP function; this host has none"
		end
		return #problems == 0, problems
	end

	function M.save(record, opts)
		opts = opts or {}
		record.baseUrl = M.normaliseBaseUrl(record.baseUrl)
		local ok, problems = M.validate(record)
		if not ok and not opts.force then return false, problems end

		local list = config.get("providers.list", {})
		if type(list) ~= "table" then list = {} end
		if util.trim(record.id) == "" then
			record.id = ensureId(record.label ~= "" and record.label or record.preset)
			record.order = #list + 1
			list[#list + 1] = record
		else
			local replaced = false
			for index, existing in ipairs(list) do
				if existing.id == record.id then
					list[index] = record
					replaced = true
				end
			end
			if not replaced then
				record.order = #list + 1
				list[#list + 1] = record
			end
		end
		config.set("providers.list", list)
		if util.trim(config.get("providers.active", "")) == "" then
			config.set("providers.active", record.id)
		end
		M.changed:fire("save", record)
		return true, record
	end

	function M.remove(id)
		local list = config.get("providers.list", {})
		local kept = {}
		for _, record in ipairs(list) do
			if record.id ~= id then kept[#kept + 1] = record end
		end
		config.set("providers.list", kept)
		if config.get("providers.active", "") == id then
			config.set("providers.active", kept[1] and kept[1].id or "")
		end
		M.changed:fire("remove", id)
		return true
	end

	function M.setActive(id)
		if not M.get(id) then return false, "unknown provider" end
		config.set("providers.active", id)
		M.changed:fire("active", id)
		return true
	end

	function M.active()
		local wanted = config.get("providers.active", "")
		local record = M.get(wanted)
		if record then return record end
		for _, candidate in ipairs(M.list()) do
			if candidate.enabled ~= false then return candidate end
		end
		return nil
	end

	function M.setModel(id, model)
		local record = M.get(id)
		if not record then return false end
		record.model = model
		if not util.find(record.models or {}, function(item) return item == model end) then
			record.models = record.models or {}
			table.insert(record.models, 1, model)
		end
		M.save(record, { force = true })
		M.changed:fire("model", record)
		return true
	end

	function M.reorder(id, direction)
		local list = M.list()
		for index, record in ipairs(list) do
			if record.id == id then
				local swapWith = list[index + direction]
				if not swapWith then return false end
				local mine, theirs = record.order or index, swapWith.order or (index + direction)
				record.order, swapWith.order = theirs, mine
				config.set("providers.list", list)
				M.changed:fire("order", id)
				return true
			end
		end
		return false
	end

	-- Health -----------------------------------------------------------------

	local function health(record)
		record.health = record.health or { ok = 0, fail = 0, streak = 0, lastError = "", cooldownUntil = 0 }
		return record.health
	end

	function M.markOk(record, ms)
		local state = health(record)
		state.ok = state.ok + 1
		state.streak = 0
		state.lastError = ""
		state.cooldownUntil = 0
		state.lastMs = ms or state.lastMs
		M.changed:fire("health", record)
	end

	-- Consecutive failures put a provider on the bench rather than the first one:
	-- a single 500 from an otherwise healthy endpoint is noise, and demoting on it
	-- would flap the active provider on every hiccup.
	function M.markFail(record, message)
		local state = health(record)
		state.fail = state.fail + 1
		state.streak = state.streak + 1
		state.lastError = util.ellipsis(message or "request failed", 200)
		if state.streak >= COOLDOWN_AFTER then
			state.cooldownUntil = clock.ms() + COOLDOWN_SECONDS * 1000
			log.warn("provider", record.label .. " benched for " .. tostring(COOLDOWN_SECONDS) .. "s", state.lastError)
		end
		M.changed:fire("health", record)
	end

	function M.cooling(record)
		local state = health(record)
		return (state.cooldownUntil or 0) > clock.ms()
	end

	-- Ordered attempt list: the active provider, then every other enabled one that
	-- is not cooling down, then -- if that leaves nothing -- the cooling ones
	-- anyway, because refusing to try at all is worse than trying a bad endpoint.
	function M.chain()
		local out = {}
		local seen = {}
		local activeRecord = M.active()
		if activeRecord and activeRecord.enabled ~= false then
			out[#out + 1] = activeRecord
			seen[activeRecord.id] = true
		end
		if config.get("agent.fallback", true) then
			for _, record in ipairs(M.list()) do
				if not seen[record.id] and record.enabled ~= false and not M.cooling(record) then
					out[#out + 1] = record
					seen[record.id] = true
				end
			end
			if #out == 0 then
				for _, record in ipairs(M.list()) do
					if record.enabled ~= false then out[#out + 1] = record end
				end
			end
		end
		return out
	end

	function M.summary(record)
		if not record then return "no provider configured" end
		local state = health(record)
		local bits = { record.label }
		if record.model ~= "" then bits[#bits + 1] = record.model end
		if M.cooling(record) then bits[#bits + 1] = "cooling down" end
		if state.lastMs and state.lastMs > 0 then bits[#bits + 1] = util.formatDuration(state.lastMs) end
		return table.concat(bits, " | ")
	end

	return M
end
