-- HTTP from inside the agent: fetch a URL, call a JSON API.
--
-- These carry the Claude Code identity like every other request, because that is
-- the client's identity and there is no reason for a tool call to present a
-- different one. The web tools next door are the exception, and they say why.
return function(env)
	local util = env.require("runtime/util")
	local http = env.require("net/http")
	local H = env.require("tools/helpers")

	local BODY_CAP = 5000

	local function headerTable(input)
		local out = {}
		for key, value in pairs(input or {}) do
			if type(key) == "string" and value ~= nil then out[key] = tostring(value) end
		end
		return out
	end

	return {
		{
			name = "http_get",
			risk = "read",
			needs = { "http" },
			description = "GET a URL and return the response body as text.",
			parameters = {
				type = "object",
				properties = {
					url = { type = "string" },
					headers = { type = "object", description = "Extra request headers." },
					limit = { type = "integer", description = "Maximum characters of body. Default 5000.", minimum = 200, maximum = 20000 },
				},
				required = { "url" },
			},
			run = function(args)
				local res, err = http.send({
					url = args.url,
					method = "GET",
					headers = headerTable(args.headers),
					attempts = 2,
					tag = "tool:http_get",
				})
				if not res then return H.fail(err) end
				local text, truncated = util.truncate(res.body, tonumber(args.limit) or BODY_CAP)
				return string.format("%d %s (%d bytes%s)\n%s",
					res.status, res.ok and "OK" or "error", #tostring(res.body),
					truncated and ", trimmed" or "", text)
			end,
		},
		{
			name = "http_request",
			risk = "write",
			needs = { "http" },
			description = "Send an HTTP request with any method and body. Marked as a write because it can change state on the other end.",
			parameters = {
				type = "object",
				properties = {
					url = { type = "string" },
					method = { type = "string", enum = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD" } },
					headers = { type = "object" },
					body = { type = "string", description = "Request body. JSON should be sent as a string." },
					limit = { type = "integer", minimum = 200, maximum = 20000 },
				},
				required = { "url", "method" },
			},
			run = function(args)
				local res, err = http.send({
					url = args.url,
					method = args.method,
					headers = headerTable(args.headers),
					body = args.body,
					attempts = 1,
					tag = "tool:http_request",
				})
				if not res then return H.fail(err) end
				local text, truncated = util.truncate(res.body, tonumber(args.limit) or BODY_CAP)
				return string.format("%s %s -> %d (%d bytes%s)\n%s",
					tostring(args.method):upper(), tostring(args.url), res.status,
					#tostring(res.body), truncated and ", trimmed" or "", text)
			end,
		},
		{
			name = "json_api",
			risk = "read",
			needs = { "http" },
			description = "GET a JSON endpoint and return either the whole document or one field, addressed by a dotted path such as 'data.items.1.name'.",
			parameters = {
				type = "object",
				properties = {
					url = { type = "string" },
					path = { type = "string", description = "Dotted path into the response. Array indexes are 1-based. Omit for the whole document." },
					headers = { type = "object" },
				},
				required = { "url" },
			},
			run = function(args)
				local decoded, err, res = http.json({
					url = args.url,
					method = "GET",
					headers = headerTable(args.headers),
					attempts = 2,
					tag = "tool:json_api",
				})
				if not decoded then
					return H.fail(string.format("%s%s", tostring(err),
						res and (" (status " .. tostring(res.status) .. ")") or ""))
				end

				local target = decoded
				if args.path and util.trim(args.path) ~= "" then
					for _, part in ipairs(util.split(args.path, ".")) do
						if type(target) ~= "table" then
							return H.fail("path '" .. args.path .. "' does not exist in the response")
						end
						target = target[tonumber(part) or part]
					end
					if target == nil then
						return "The path '" .. args.path .. "' is not present in the response."
					end
				end

				if type(target) == "table" then
					local ok, encoded = pcall(util.encode, target)
					if not ok then return H.fail("that value could not be re-encoded") end
					return (util.truncate(encoded, 5000))
				end
				return H.show(target)
			end,
		},
	}
end
