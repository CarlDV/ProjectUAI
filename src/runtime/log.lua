-- Structured log with a bounded history.
--
-- Two audiences: the developer, who wants the last hundred lines including HTTP
-- detail, and the user, who occasionally needs to see why a provider rejected
-- them. Both read the same ring buffer through the Logs panel, so nothing is
-- printed to the console by default -- an in-game script that spams output is
-- indistinguishable from a broken one.
return function(env)
	local util = env.require("runtime/util")
	local signal = env.require("runtime/signal")

	local LIMIT = 400

	local M = {
		entries = {},
		changed = signal.new("log"),
		mirror = false,
		minLevel = 1,
	}

	local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

	-- An API key must never reach the buffer in full: the panel is screenshot and
	-- pasted into bug reports. Anything key-shaped keeps a four-character tail so
	-- a user can still tell two keys apart.
	local function redact(text)
		text = tostring(text)
		text = text:gsub("(sk%-[%w%-_]*)([%w%-_][%w%-_][%w%-_][%w%-_])", function(_, tail)
			return "sk-..." .. tail
		end)
		text = text:gsub("([Bb]earer%s+)[%w%.%-_]+([%w%.%-_][%w%.%-_][%w%.%-_][%w%.%-_])", "%1...%2")
		text = text:gsub('("api[_%-]?key"%s*:%s*")[^"]*([^"][^"][^"][^"])(")', "%1...%2%3")
		return text
	end
	M.redact = redact

	local function push(level, source, message, detail)
		if (LEVELS[level] or 2) < M.minLevel then return end
		local entry = {
			at = env.require("runtime/clock").ms(),
			stamp = env.require("runtime/clock").stamp(),
			level = level,
			source = tostring(source or "app"),
			message = redact(message),
			detail = detail ~= nil and redact(type(detail) == "table" and util.concatKeys(detail) or tostring(detail)) or nil,
		}
		M.entries[#M.entries + 1] = entry
		if #M.entries > LIMIT then
			-- Drop in blocks rather than one per push: table.remove(1) on a 400
			-- entry list on every log line is a copy each time.
			local kept = {}
			for index = math.floor(LIMIT * 0.25) + 1, #M.entries do kept[#kept + 1] = M.entries[index] end
			M.entries = kept
		end
		if M.mirror then
			local line = string.format("[uai:%s] %s: %s", entry.level, entry.source, entry.message)
			if level == "error" or level == "warn" then warn(line) else print(line) end
		end
		M.changed:fire(entry)
		return entry
	end

	function M.debug(source, message, detail) return push("debug", source, message, detail) end
	function M.info(source, message, detail) return push("info", source, message, detail) end
	function M.warn(source, message, detail) return push("warn", source, message, detail) end
	function M.error(source, message, detail) return push("error", source, message, detail) end

	function M.tail(count)
		local from = math.max(#M.entries - (count or 50) + 1, 1)
		return util.slice(M.entries, from, #M.entries)
	end

	function M.filter(level, text)
		local wanted = LEVELS[level] or 1
		local needle = text and text:lower() or nil
		local out = {}
		for _, entry in ipairs(M.entries) do
			if (LEVELS[entry.level] or 2) >= wanted then
				if not needle
					or entry.message:lower():find(needle, 1, true)
					or entry.source:lower():find(needle, 1, true) then
					out[#out + 1] = entry
				end
			end
		end
		return out
	end

	function M.clear()
		M.entries = {}
		M.changed:fire(nil)
	end

	function M.export()
		local lines = {}
		for _, entry in ipairs(M.entries) do
			lines[#lines + 1] = string.format("%s %-5s %-14s %s%s",
				entry.stamp, entry.level:upper(), entry.source, entry.message,
				entry.detail and ("  " .. entry.detail) or "")
		end
		return table.concat(lines, "\n")
	end

	return M
end
