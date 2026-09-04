-- Persisted settings.
--
-- One file, one shape, defaults merged under whatever was saved -- so adding a
-- setting in a later version does not invalidate an existing install, and a
-- half-written file falls back to defaults rather than bricking the client.
-- Writes are debounced because the interface calls set() from slider drags.
return function(env)
	local util = env.require("runtime/util")
	local fsx = env.require("runtime/fsx")
	local clock = env.require("runtime/clock")
	local signal = env.require("runtime/signal")
	local log = env.require("runtime/log")

	local FILE = "config.json"

	local DEFAULTS = {
		version = 1,
		ui = {
			density = "comfortable",
			accent = "aurora",
			reduceMotion = "auto",
			layout = "auto",
			panel = "chat",
			fontScale = 1,
			showReasoning = true,
			showToolDetail = false,
			-- The key that opens quick chat, stored as an Enum.KeyCode name because
			-- that is what the capture in Settings produces and what survives a
			-- keyboard layout the character would not.
			quickKey = "Semicolon",
			showUsage = true,
			window = { width = 0, height = 0, x = 0, y = 0, maximised = false, placed = false },
			launcher = { x = 0, y = 0, placed = false },
		},
		agent = {
			maxTurns = 24,
			toolConcurrency = 4,
			toolTimeout = 25,
			contextTokens = 24000,
			keepTurns = 14,
			compaction = true,
			stream = true,
			temperature = 0.4,
			-- Reasoning depth: sent as `reasoning_effort` on chat completions and as
			-- `output_config.effort` on the Messages API. "high" is what the API itself
			-- uses when the field is absent, so this default changes nothing until it is
			-- moved, and "off" sends no field at all. Clamped per model, because the
			-- scales differ by generation -- "xhigh" did not exist before Opus 4.7.
			effort = "high",
			maxTokens = 4096,
			-- Characters, not tokens, and it is the last word on how much of a tool
			-- result reaches the model. Eight thousand rather than four so that the
			-- tools' own defaults -- a six thousand character file read, a five thousand
			-- character response body -- arrive whole instead of being cut in half by a
			-- limit set somewhere the caller cannot see.
			resultCap = 8000,
			repeatLimit = 3,
			subagentDepth = 2,
			subagentTurns = 14,
			-- Seconds one subagent may run for. The tool that dispatches it derives its
			-- own timeout from this, so the two cannot drift apart -- when they did, the
			-- generic 25s tool timeout fired first and every finished report was thrown
			-- away by a caller that had already given up.
			subagentBudget = 240,
			retries = 5,
			fallback = true,
		},
		permissions = {
			mode = "ask",
			remember = true,
			rules = {},
		},
		providers = {
			active = "",
			list = {},
		},
		identity = {
			claudeUa = true,
			version = "2.0.14",
			extraHeaders = {},
		},
		memory = {
			enabled = true,
			entries = {},
		},
		logs = {
			mirror = false,
			level = "info",
		},
	}

	local M = {
		defaults = DEFAULTS,
		data = util.deepCopy(DEFAULTS),
		changed = signal.new("config"),
		loaded = false,
		dirty = false,
	}

	local flush

	function M.load()
		local stored = fsx.readJson(FILE, nil)
		if type(stored) == "table" then
			M.data = util.merge(DEFAULTS, stored)
		else
			M.data = util.deepCopy(DEFAULTS)
		end
		M.loaded = true
		M.changed:fire(nil, M.data)
		return M.data
	end

	function M.saveNow()
		if not fsx.enabled then
			M.dirty = false
			return false, "no filesystem"
		end
		local ok, err = fsx.writeJson(FILE, M.data)
		M.dirty = not ok
		if not ok then log.warn("config", "could not persist settings", err) end
		return ok, err
	end

	flush = clock.debounce(function()
		M.saveNow()
	end, 0.75)

	function M.save()
		M.dirty = true
		flush()
	end

	function M.get(path, fallback)
		local value = util.get(M.data, path)
		if value == nil then
			local default = util.get(DEFAULTS, path)
			if default ~= nil then return util.deepCopy(default) end
			return fallback
		end
		return value
	end

	-- Fires with the path so a subscriber can react to one setting rather than
	-- rebuilding on every keystroke of an unrelated field.
	function M.set(path, value, opts)
		opts = opts or {}
		util.set(M.data, path, value)
		if not opts.quiet then M.changed:fire(path, value) end
		if not opts.transient then M.save() end
		return value
	end

	function M.toggle(path)
		local value = M.get(path) ~= true
		M.set(path, value)
		return value
	end

	function M.reset(section)
		if section then
			util.set(M.data, section, util.deepCopy(util.get(DEFAULTS, section)))
		else
			M.data = util.deepCopy(DEFAULTS)
		end
		M.changed:fire(section, nil)
		M.save()
	end

	return M
end
