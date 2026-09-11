-- Release notes, as data.
--
-- Every release this client has shipped, from the initial commit forward, in
-- the shape the changelog modal renders: one entry per version, one section
-- per category, one line per change. The list is chronological with the
-- newest first because that is how a "what's new" is read -- the top entry
-- is the one a returning user has not seen.
--
-- `lastSeenVersion` is the read marker: the app menu offers the changelog
-- with a "new" marker while the running version is newer than the last one
-- seen, and opening the modal marks it read. Nothing is fetched remotely --
-- the notes a client can show offline are the notes it shipped with, and a
-- version that has to be downloaded to learn what it contains is a version
-- that cannot say anything on a bad network day.
return function(env)
	local config = env.require("runtime/config")

	local M = {}

	-- The order of categories within a release: new capabilities first, then
	-- improvements, then fixes -- the order a reader cares about them.
	local CATEGORY_ORDER = { "added", "improved", "fixed" }

	local ENTRIES = {
		{
			version = "1.1.0",
			date = "September 2026",
			title = "Infinite Yield, key pools and skills",
			highlights = "Infinite Yield as an internal command engine with a hidden mode, "
				.. "multi-key rotation for providers, the community plugin store, and "
				.. "markdown skills the agent reads on demand.",
			sections = {
				{
					category = "added",
					items = {
						"Infinite Yield engine: the agent runs any IY command (fly, noclip, esp, tp, "
						.. "600+ more) through iy_cmd, with the command list searchable via iy_cmds.",
						"Hidden mode: IY loads with its interface parked -- every command and loop "
						.. "alive, nothing on screen. With GUI mode loads it untouched.",
						"CaptureService guard: screenshots no longer pop a hidden IY back on screen.",
						"Multi-key pools: paste several API keys, one per line, and a rate-limited "
						.. "key is benched and the next one tried with no delay -- 429s stop costing turns.",
						"Community plugin store: the agent searches iyplugins.pages.dev (560+ "
						.. "plugins), installs and loads one on request -- 'install dexrecontinued'.",
						"Markdown skills: .md playbooks under skills/ with Claude Code frontmatter. "
						.. "The prompt carries names and descriptions only; the body is fetched by a "
						.. "tool call when a task matches.",
						"Skills from GitHub: owner/repo or a URL installs a playbook into skills/.",
						"Changelog: What's New, from the app menu and About.",
					},
				},
				{
					category = "improved",
					items = {
						"Lazy IY loading: nothing is fetched at boot; the first iy_cmd call brings "
						.. "the engine up.",
						"System prompt awareness: the model is told each turn whether IY is loaded "
						.. "and how, and which skills exist.",
						"Ambient detection: an IY the user started themselves is latched onto and "
						.. "left alone -- its GUI, its settings.",
						"The settings toggle for IY applies to a loaded engine immediately.",
						"Key pool state is per-session, not persisted -- a stale index cannot "
						.. "start a rotation from the wrong key.",
					},
				},
				{
					category = "fixed",
					items = {
						"Ambient fallbacks for prefix and PARENT on executors without setfenv.",
						"File workspace split: agent files under files/, pastes under pastes/, "
						.. "with a first-run migration that shows its progress.",
						"Paste overflow: a long pasted message lands in a file and is referenced, "
						.. "not dropped.",
					},
				},
			},
		},
		{
			version = "1.0.9",
			date = "September 2026",
			title = "Asking, standing instructions and the workspace",
			highlights = "ask_user, custom instructions, the file workspace split, and prompt hardening.",
			sections = {
				{
					category = "added",
					items = {
						"ask_user: the agent can ask the person a question and wait, with a "
						.. "panel behind it that answers the running turn.",
						"Custom instructions: standing instructions appended to the system prompt "
						.. "after the built-in rules, so they win on conflict. Subagents inherit them.",
						"Copy system prompt: the assembled prompt, as the next request will carry it.",
					},
				},
				{
					category = "improved",
					items = {
						"Prompt hardening: quoting rules, anti-fabrication wording, and a style "
						.. "contract that prizes short answers.",
						"Ask sweeps: a question left unanswered is collected rather than parked "
						.. "forever.",
					},
				},
				{
					category = "fixed",
					items = {
						"Prompt-injection hardening around pasted content.",
					},
				},
			},
		},
		{
			version = "1.0.8",
			date = "September 2026",
			title = "The executor wall and provider polish",
			highlights = "Request timeouts, the smaller-ask retry at the executor wall, and provider setup with links.",
			sections = {
				{
					category = "added",
					items = {
						"Request timeout setting, defaulting to a day -- the one deadline nothing "
						.. "else can rescue, high enough for a reasoning model that thinks before "
						.. "its first byte.",
						"Smaller-ask retry: a request that dies at the executor's 60s transport "
						.. "wall is retried once with less thinking and half the reply ceiling, "
						.. "so the model finishes inside the wall instead of at it.",
					},
				},
				{
					category = "improved",
					items = {
						"Adding an inference provider links out to where each vendor issues keys.",
						"Notifications when minimized: a finished or failed turn toasts even with "
						.. "the window closed, alongside the launcher badge.",
						"OpenRouter attribution headers on the requests that go there.",
					},
				},
				{
					category = "fixed",
					items = {
						"Adding an inference provider on mobile.",
						"Randomly vanishing modals: the dismiss layer sits behind an Active card.",
						"Modal scroll stutter: stable top/bottom layout instead of UIFlexItem.",
					},
				},
			},
		},
		{
			version = "1.0.7",
			date = "September 2026",
			title = "Web bridge and the landing page",
			highlights = "The local web bridge revamp, OpenRouter app attribution, and a public face.",
			sections = {
				{
					category = "added",
					items = {
						"Landing page and showcase assets.",
						"OpenRouter app attribution: rankings and stats credit ProjectUAI.",
					},
				},
				{
					category = "improved",
					items = {
						"Bridge UI revamp and popup placement fixes; the login gate restored.",
						"Bridge token regenerated on every server start, so a stale one in config "
						.. "grants nothing.",
					},
				},
			},
		},
		{
			version = "1.0.6",
			date = "September 2026",
			title = "Chat, input and mobile",
			highlights = "In-game chat tools, virtual input, and a mobile panel that can actually be moved.",
			sections = {
				{
					category = "added",
					items = {
						"In-game chat tools: the agent reads recent chat and sends as the local player.",
						"Virtual input: key presses and mouse actions from a tool call.",
					},
				},
				{
					category = "fixed",
					items = {
						"Mobile panel dragging, resizing and the hamburger menu.",
						"Adding an inference provider on mobile.",
						"CanvasGroup blur in the transcript.",
					},
				},
			},
		},
		{
			version = "1.0.5",
			date = "September 2026",
			title = "Delegation that finishes",
			highlights = "Unbounded subagents, follow-up questions, and the model picker.",
			sections = {
				{
					category = "added",
					items = {
						"Unlimited subagents: a delegated job can run with no step limit, "
						.. "bounded still by Stop and its own timeouts.",
						"Subagent follow-ups: a dispatched agent keeps what it found and answers "
						.. "another question in the same conversation.",
						"Model picker in the header.",
					},
				},
				{
					category = "improved",
					items = {
						"Tool-call rows are grouped under one card; code blocks get air.",
						"Subagent reports are kept and shown, not summarised away.",
					},
				},
			},
		},
		{
			version = "1.0.4",
			date = "September 2026",
			title = "The interface revamp",
			highlights = "The modern interface: sidebar, panels, icons, and the responsive layouts.",
			sections = {
				{
					category = "added",
					items = {
						"Sidebar navigation and the panel system behind it.",
						"Icon set, drawn rather than assembled from emoji.",
						"Window and panel layouts that follow the viewport: window, panel, sheet.",
					},
				},
				{
					category = "fixed",
					items = {
						"Mobile support: touch targets, dragging, and the layout switch.",
						"Modal overlap with the menu.",
					},
				},
			},
		},
		{
			version = "1.0.3",
			date = "September 2026",
			title = "Open, embeddable, licensed",
			highlights = "MIT license, a working unload, and the Gemini provider.",
			sections = {
				{
					category = "added",
					items = {
						"MIT license.",
						"Working unload: every timer, input handler and thread is drained, config "
						.. "saved, interface removed. No half-loaded clients left behind.",
						"Gemini as a provider.",
					},
				},
				{
					category = "improved",
					items = {
						"Subagent visibility: work in progress is shown, reports are kept.",
					},
				},
				{
					category = "fixed",
					items = {
						"Deadline retry: a request that timed out is no longer re-sent to the "
						.. "same wall -- the sequence ends and says why.",
					},
				},
			},
		},
		{
			version = "1.0.2",
			date = "September 2026",
			title = "The Messages API and quick chat",
			highlights = "The Anthropic Messages API as a second protocol, quick chat, and type modernisation.",
			sections = {
				{
					category = "added",
					items = {
						"Anthropic Messages API: a record picks its wire protocol; tool calls are "
						.. "normalised between the two shapes automatically.",
						"Quick chat: a key opens a small composer without the full window.",
					},
				},
				{
					category = "improved",
					items = {
						"Retry on transient failures with a backoff curve; the type was "
						.. "modernised and the dropdown unburied.",
					},
				},
				{
					category = "fixed",
					items = {
						"Menu overlap with other surfaces.",
						"Flex width reserves replaced with real flex, and edges made visible.",
					},
				},
			},
		},
		{
			version = "1.0.1",
			date = "September 2026",
			title = "Making a turn visible",
			highlights = "The transcript shows work as it happens, and the schemas stop guessing.",
			sections = {
				{
					category = "fixed",
					items = {
						"A running turn is visible: tool rows stream in as they execute.",
						"The rebuild thrash that remounted the transcript on every update.",
						"Tool schemas: parameters validate before dispatch, so a malformed call "
						.. "is repaired or reported rather than raising.",
						"Collapsed labels and the header rule that ate the title bar.",
					},
				},
			},
		},
		{
			version = "1.0.0",
			date = "September 2026",
			title = "Initial release",
			highlights = "The universal AI agent copilot for Roblox executors: no game, no gateway, no host assumed.",
			sections = {
				{
					category = "added",
					items = {
						"The agent loop: a turn that plans, calls tools and reports, with token "
						.. "budgets and compaction.",
						"Subagents: fresh-context dispatch, parallel execution, and reports "
						.. "collected by the parent.",
						"The permission engine: read, write and danger risks, per-tool rules, "
						.. "and an interactive prompt that can be remembered.",
						"Native tool groups: instance tree, properties, remotes, virtual input, "
						.. "screen and aiming, world, chat, memory, files, HTTP and web search.",
						"Providers: OpenAI-compatible chat completions, with presets for a dozen "
						.. "endpoints and manual configuration for any other.",
						"Sessions: saved, resumable, searchable, grouped by place.",
						"The bridge: a local Node.js server relaying the conversation to a "
						.. "browser companion, with SSE and a token handshake.",
						"The loader: one loadstring, one file, no dependencies.",
					},
				},
			},
		},
	}

	-- Labels are derived once rather than written per section, so a new
	-- category cannot appear with the wrong label half the time.
	local LABELS = { added = "New", improved = "Improved", fixed = "Fixed" }

	-- Newest first, as shipped above. Sorted rather than trusted so an edit in
	-- the middle cannot silently reorder the modal.
	M.ENTRIES = ENTRIES

	function M.all()
		local out = {}
		for _, entry in ipairs(ENTRIES) do
			local sections = {}
			for _, category in ipairs(CATEGORY_ORDER) do
				for _, section in ipairs(entry.sections or {}) do
					if section.category == category then
						sections[#sections + 1] = {
							category = category,
							label = LABELS[category] or category,
							items = section.items or {},
						}
					end
				end
			end
			-- A category not in the order list keeps its place, labelled as written.
			for _, section in ipairs(entry.sections or {}) do
				local known = false
				for _, category in ipairs(CATEGORY_ORDER) do
					if section.category == category then known = true end
				end
				if not known then
					sections[#sections + 1] = {
						category = section.category,
						label = section.label or LABELS[section.category] or section.category,
						items = section.items or {},
					}
				end
			end
			out[#out + 1] = {
				version = entry.version,
				date = entry.date,
				title = entry.title,
				highlights = entry.highlights,
				sections = sections,
			}
		end
		table.sort(out, function(a, b) return a.version > b.version end)
		return out
	end

	function M.latest()
		return M.all()[1]
	end

	function M.isUnread()
		local latest = M.latest()
		if not latest then return false end
		return config.get("ui.lastSeenVersion", "0.0.0") ~= latest.version
	end

	function M.markRead()
		local latest = M.latest()
		if not latest then return false end
		config.set("ui.lastSeenVersion", latest.version)
		return true
	end

	return M
end
