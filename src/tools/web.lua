-- The public web: search, and turn a page into readable text.
--
-- These are the one place a browser User-Agent is sent instead of the client's
-- own. It is not a preference: DuckDuckGo's HTML endpoint and most CDNs answer 403
-- to an unfamiliar agent, so a search tool that presented the CLI identity would
-- simply never work.
return function(env)
	local util = env.require("runtime/util")
	local http = env.require("net/http")
	local H = env.require("tools/helpers")

	local PAGE_CAP = 4000

	-- Sanitised at the end, not only at encode time.
	--
	-- A third-party page can be served as Latin-1, CP1252 or nothing at all, and
	-- Roblox's HTTP client hands back the bytes as they arrived. Scrubbing here as well
	-- as in util.encode is not belt-and-braces: this text is also what the transcript
	-- paints, what the Logs panel keeps and what the bridge uploads, and a raw 0xA0 in
	-- a TextLabel is a visible replacement glyph rather than an error anyone can trace.
	local function toText(html)
		local text = tostring(html)
			:gsub("<!%-%-.-%-%->", " ")
			:gsub("<script.-</script>", " ")
			:gsub("<style.-</style>", " ")
			:gsub("<noscript.-</noscript>", " ")
			:gsub("<svg.-</svg>", " ")
			:gsub("<br%s*/?>", "\n")
			:gsub("</p>", "\n\n")
			:gsub("</h%d>", "\n\n")
			:gsub("</li>", "\n")
			:gsub("<[^>]+>", " ")
		text = util.htmlEntities(text)
		text = text:gsub("[ \t]+", " "):gsub(" ?\n ?", "\n"):gsub("\n\n\n+", "\n\n")
		return (util.sanitise(util.trim(text)))
	end

	return {
		{
			name = "web_search",
			risk = "read",
			needs = { "http" },
			description = "Search the web and return titles, URLs and snippets. Use when the answer depends on something current or outside the game.",
			parameters = {
				type = "object",
				properties = {
					query = { type = "string" },
					limit = { type = "integer", description = "Results to return, 1-10. Default 5.", minimum = 1, maximum = 10 },
				},
				required = { "query" },
			},
			run = function(args)
				local query = util.trim(args.query)
				if query == "" then return "Give a query." end

				local res, err = http.send({
					url = "https://html.duckduckgo.com/html/",
					method = "POST",
					identity = "browser",
					headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
					body = "q=" .. util.urlEncode(query) .. "&b=&kl=us-en",
					attempts = 2,
					tag = "tool:web_search",
				})
				if not res then return H.fail(err) end
				if not res.ok then return H.fail("search returned status " .. tostring(res.status)) end

				local limit = H.limit(args.limit, 5, 10)
				local records = {}
				for href, title in res.body:gmatch('<a[^>]+class="result__a"[^>]*href="([^"]*)"[^>]*>(.-)</a>') do
					if #records >= limit then break end
					-- Results are wrapped in a redirect; the real URL is the uddg param.
					local link = href:match("[?&]uddg=([^&]+)")
					link = link and util.urlDecode(link) or href
					if not link:find("^https://duckduckgo%.com") then
						records[#records + 1] = { title = toText(title), url = link }
					end
				end

				local index = 1
				for snippet in res.body:gmatch('<a[^>]+class="result__snippet"[^>]*>(.-)</a>') do
					if records[index] then
						records[index].snippet = util.ellipsis(toText(snippet), 260)
						index = index + 1
					end
				end

				if #records == 0 then
					return "No results. The search endpoint may be blocking this host; try web_read on a known URL instead."
				end
				local blocks = {}
				for position, record in ipairs(records) do
					blocks[#blocks + 1] = string.format("%d. %s\n   %s\n   %s",
						position, record.title, record.url, record.snippet or "(no snippet)")
				end
				return table.concat(blocks, "\n\n")
			end,
		},
		{
			name = "web_read",
			risk = "read",
			needs = { "http" },
			description = "Fetch a web page and return its readable text, with markup and scripts stripped.",
			parameters = {
				type = "object",
				properties = {
					url = { type = "string" },
					limit = { type = "integer", description = "Maximum characters. Default 4000.", minimum = 200, maximum = 64000 },
				},
				required = { "url" },
			},
			run = function(args)
				local url = util.trim(args.url)
				if not url:find("^https?://") then url = "https://" .. url end

				local res, err = http.send({
					url = url,
					method = "GET",
					identity = "browser",
					attempts = 2,
					tag = "tool:web_read",
				})
				if not res then return H.fail(err) end
				if not res.ok then return H.fail("the page returned status " .. tostring(res.status)) end

				local body = tostring(res.body)
				-- A JSON endpoint reached through this tool should not be run through
				-- an HTML stripper. Still sanitised: a JSON body is only UTF-8 by
				-- convention, and this one came from a stranger.
				local looksJson = util.trim(body):sub(1, 1) == "{" or util.trim(body):sub(1, 1) == "["
				local text = looksJson and (util.sanitise(util.trim(body))) or toText(body)
				if text == "" then return "The page returned no readable text." end

				local title = body:match("<title[^>]*>(.-)</title>")
				local trimmed, truncated = util.truncate(text, tonumber(args.limit) or PAGE_CAP)
				return string.format("%s%s\n\n%s",
					title and (toText(title) .. "\n" .. url) or url,
					truncated and string.format("\n(%d characters, trimmed)", #text) or "",
					trimmed)
			end,
		},
	}
end
