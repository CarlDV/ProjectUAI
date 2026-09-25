-- URL handling shared by provider discovery, HTTP and gateway sockets.
return function(env)
	local util = env.require("runtime/util")
	local M = {}

	function M.isLocalHost(host)
		host = tostring(host or ""):lower():gsub("%.$", "")
		if host == "" then return false end
		if host == "localhost" or host:match("%.localhost$") or host:match("%.local$") then return true end
		local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if a then
			a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
			if a > 255 or b > 255 or c > 255 or d > 255 then return false end
			return a == 0 or a == 10 or a == 127 or (a == 169 and b == 254)
				or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
				or (a == 100 and b >= 64 and b <= 127)
		end
		if host:find(":", 1, true) then
			local mapped = host:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
			if mapped then return M.isLocalHost(mapped) end
			local compact = host:gsub("0", "")
			return compact:match("^:+1?$") ~= nil or host:match("^f[cd]%x%x:") ~= nil
				or host:match("^fe[89ab]%x:") ~= nil
		end
		-- Single-label names normally use the host's local DNS/search domain.
		return not host:find(".", 1, true)
	end

	function M.parse(raw)
		local text = util.trim(raw)
		local scheme, authority, rest = text:match("^([%a][%w+%.%-]*)://([^/%?#]+)(.*)$")
		if not scheme or text:find("%s") then return nil, "URL needs a scheme and a host, with spaces encoded" end
		scheme = scheme:lower()
		if scheme ~= "http" and scheme ~= "https" and scheme ~= "ws" and scheme ~= "wss" then
			return nil, "use an http:// or https:// base URL (ws:// or wss:// for a gateway socket)"
		end
		if authority:find("@", 1, true) then return nil, "put credentials in the auth/header fields, not the URL authority" end
		if authority:sub(-1) == ":" then return nil, "port is missing after the colon" end
		local host, port
		if authority:sub(1, 1) == "[" then
			host, port = authority:match("^%[([%x:%.]+)%]:?(%d*)$")
			if not host or not host:find(":", 1, true) then return nil, "invalid bracketed IPv6 host" end
		else
			host, port = authority:match("^([^:]+):?(%d*)$")
			if not host or not host:match("^[%w%.%-_]+$") then return nil, "invalid host; put IPv6 addresses in brackets" end
		end
		if port ~= "" and (tonumber(port) < 1 or tonumber(port) > 65535) then return nil, "port must be between 1 and 65535" end
		rest = rest:match("^([^#]*)") or ""
		local path, query = rest:match("^([^?]*)%?(.*)$")
		if not path then path = rest end
		return { scheme = scheme, authority = authority, host = host:lower():gsub("%.$", ""), path = path, query = query }
	end

	function M.host(raw)
		local parsed = M.parse(raw)
		return parsed and parsed.host or ""
	end

	local function render(parsed, path, query)
		return parsed.scheme .. "://" .. parsed.authority .. path .. (query and query ~= "" and ("?" .. query) or "")
	end

	function M.normaliseBase(raw)
		local text = util.trim(raw)
		if text == "" then return "" end
		if not text:find("^[%a][%w+%.%-]*://") then
			text = text:gsub("^//", "")
			local authority = text:match("^([^/%?#]+)") or ""
			local host = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
			text = (M.isLocalHost(host) and "http://" or "https://") .. text
		end
		local parsed, err = M.parse(text)
		if not parsed then return text, err end
		if parsed.scheme ~= "http" and parsed.scheme ~= "https" then return text, "base URL must use http:// or https://" end
		local path = parsed.path:gsub("/+$", "")
		if path == "" then path = "/v1" end
		return render(parsed, path, parsed.query)
	end

	function M.isFullEndpoint(raw)
		local parsed = M.parse(raw)
		local path = parsed and parsed.path:gsub("/+$", "") or ""
		return path:match("/chat/completions$") ~= nil or path:match("/messages$") ~= nil
	end

	function M.endpoint(raw, suffix, extra)
		local base = M.normaliseBase(raw)
		local parsed = M.parse(base)
		if not parsed then return base end
		local path = parsed.path:gsub("/+$", ""):gsub("/chat/completions$", ""):gsub("/messages$", ""):gsub("/models$", "")
		local query = {}
		for part in tostring(parsed.query or ""):gmatch("[^&]+") do
			local name = util.urlDecode(part:match("^([^=]*)") or "")
			if not extra or extra[name] == nil then query[#query + 1] = part end
		end
		for _, name in ipairs(util.keys(extra or {}, true)) do
			query[#query + 1] = util.urlEncode(name) .. "=" .. util.urlEncode(extra[name])
		end
		return render(parsed, path .. suffix, table.concat(query, "&"))
	end

	function M.requestTarget(raw)
		local parsed = M.parse(raw)
		if not parsed then return nil end
		return (parsed.path ~= "" and parsed.path or "/") .. (parsed.query and parsed.query ~= "" and ("?" .. parsed.query) or "")
	end

	-- Discovery notes need the route, never query credentials.
	function M.display(raw)
		local parsed = M.parse(raw)
		if not parsed then return "the configured endpoint" end
		return render(parsed, parsed.path, nil)
	end
	return M
end
