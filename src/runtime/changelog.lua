-- Release notes, as data.
--
-- Every release this client has shipped, from the initial commit forward, in
-- the shape the changelog modal renders: one entry per version, one section
-- per category, one line per change. The list is chronological with the
-- newest first because that is how a "what's new" is read -- the top entry
-- is the one a returning user has not seen.
--
-- Version and note revision track what the user opened, so updates within a
-- version restore the menu's "new" marker. Nothing is fetched remotely --
-- the notes a client can show offline are the notes it shipped with, and a
-- version that has to be downloaded to learn what it contains is a version
-- that cannot say anything on a bad network day.
return function(env)
	local config = env.require("runtime/config")

	local M = {}
	-- New capabilities first, then improvements and fixes.
	local CATEGORY_ORDER = { "added", "improved", "fixed" }
	local ENTRIES = {
		{
			version = "1.9.0",
			revision = "2026-09-26",
			date = "September 26, 2026",
			title = "Cowork browser workspace",
			highlights = "A refreshed browser workspace with verified bridge installation, live responses, picture previews and persistent drafts. Small screens and keyboard controls stay usable during live updates.",
			sections = {
				{ category = "added", label = "Browser workspace", items = {
					"Cowork provides responsive navigation, a step-by-step setup guide and system, light, dark or Match Roblox themes.",
					"Attach PNG, JPEG and WebP previews with upload progress, cancellation, retry and reload recovery. The AI receives text markers only; describe what matters in the image.",
				} },
				{ category = "improved", label = "Installation and conversations", items = {
					"Executor downloads use .txt files. Node verifies a pinned package and restores filenames before starting; a failed download preserves the previous launcher.",
					"Live replies retain stable Markdown blocks and reconcile with the saved response. Provider failures, replay gaps and uncertain delivery have visible recovery controls.",
					"Full text and code drafts persist per conversation, including attachments and edits made while a message is being delivered.",
				} },
				{ category = "fixed", label = "Layout and interaction", items = {
					"Task lists and attached drafts scroll within short screens. Long URLs, model names and dialog titles wrap, and Jump to latest stays above the composer.",
					"Pending answers, remembered permission choices, open tasks and keyboard focus survive updates. Permission requests identify their conversation and selected provider/model controls stay current.",
					"Dialog errors remain visible, expired tokens return focus to connection setup, and keyboard navigation reaches the selected conversation.",
					"Light-theme text and code-button hover states have readable contrast. Save failures use error colors, and high-contrast mode retains input focus and the Stop symbol.",
				} },
			},
		},
		{
			version = "1.8.0",
			revision = "2026-09-25",
			date = "September 25, 2026",
			title = "Chat stability, provider compatibility and native improvements",
			highlights = "Chat history survives busy workers and resizing. Local-server connections, model discovery and gateway streaming are more reliable, with clearer protocol and authentication settings.",
			sections = {
				{ category = "improved", label = "Providers and gateway streaming", items = {
					"Local URLs use HTTP by default and keep their path prefixes and query parameters. Model discovery reports auth failures and cannot reuse another connection's stale model list.",
					"vLLM no longer requires a key by default. Added llama.cpp and SGLang presets, corrected Ollama tool options, preserved object-shaped tool arguments and recognized small local context windows.",
					"Explicit auth choices work for compatible Messages gateways. Learned request repairs and output limits follow the endpoint and model that produced them.",
					"Connection edits discard stale model lists and cancel old fetches while preserving manual model ids. Switching presets applies their identity defaults and clears the previous gateway URL.",
					"Gateway sockets preserve provider paths and headers, accept split or combined SSE events and clean up late connections. HTTP fallback is allowed only before sending, so an uncertain socket outcome cannot duplicate the request.",
					"Socket settings explain UAI's custom gateway protocol. Normal local servers use HTTP; the socket does not implement OpenAI Responses or Realtime and does not remove transport limits.",
				} },
				{ category = "fixed", label = "Chat history and resizing", items = {
					"User messages and assistant replies have their own history budget. Tool activity cannot push them out; worker summaries and call/result pairs remain together.",
					"Maximize keeps the live interface in place. The window draws directly on every device, and refresh/layout changes preserve the reading position.",
					"Long conversations restore in short batches while new events keep arriving. Switching, clearing or closing a view cancels its unfinished replay and releases old rows and timers.",
					"Message options > Refresh conversation redraws messages and live activity without restarting the script. A Markdown failure falls back to readable text.",
					"Older saves recover conversation text still present in saved context. History limits are shown, worker timings and totals survive replay, and search finds dialogue after context compaction.",
				} },
				{ category = "improved", label = "Replies and progress", items = {
					"Removed the 8,192-token executor reply ceiling, including HTTP fallback. Your configured output budget and the model's own limits still apply.",
					"Buffered replies appear immediately instead of using simulated typing. Compatible streams show received text and reasoning as they arrive; buffered HTTP cannot show tokens before the response arrives.",
					"The agent is prompted to send one short progress message at a time between work steps and tool calls, then continue working.",
				} },
				{ category = "fixed", label = "Context and provider controls", items = {
					"Context breakdown labels have room to display. Totals include prepared instructions and tools, distinguish estimates from provider measurements, and refresh correctly when providers or models change.",
					"Add Provider is centered vertically in the horizontal provider strip, including after resizing or changing layouts.",
				} },
				{ category = "improved", label = "Source and decompilation", items = {
					"Source views identify where their text came from. Inspected and decompiled snapshots are read-only; Extract editable copy creates a separate document without running it or writing back to the live script.",
					"Source loading shares requests, supports refresh and reports unavailable, failed or expired snapshots. Switching or closing views prevents old requests from reopening them.",
				} },
				{ category = "fixed", label = "Explorer and editing", items = {
					"Explorer actions use the selection shown in the Inspector and reject stale targets. Search cancels old work, avoids duplicate results and explains partial scans, row limits and deep paths.",
					"Large documents reuse syntax colors and line measurements. Unicode selection, multiline highlights, horizontal caret reveal, Go to line, match counts, case and whole-word search, and searches across source pages are corrected.",
					"Autosave handles maximum-size documents and interrupted writes. Retry required, Conflict and expired-source states preserve drafts, while stale delete confirmations and repeated run requests are rejected.",
				} },
				{ category = "improved", label = "Remote Spy", items = {
					"Capture defaults to a selected remote and 30 seconds. Whole-game, subtree and continuous capture are explicit choices; selected-subtree capture uses the Explorer's primary object.",
					"Inspect a captured caller, open its source or decompile it after capture, and see likely remote call sites. Exported records include source provenance.",
					"Incoming calls offer diagnostics and caller actions. Outgoing calls also offer argument editing, reviewed one-shot replay and portable scripts that must be reviewed before copying or exporting.",
					"Capture shows unknown hook attribution and any forwarding wrappers retained after Stop. Late results count toward storage limits, and exports remain consistent while new calls arrive.",
				} },
				{ category = "fixed", label = "Conversation and subagent reliability", items = {
					"Recent saved chats restore correctly, progress updates preserve the transcript, and unsaved conversations remain available.",
					"Stopped subagents can resume. Queued follow-ups remain cancellable, duplicate dispatch is rejected, configured concurrency is honored, and finished workers clear their Stopping label.",
					"Unlimited subagents no longer inherit a disabled execution budget while waiting. Timed-out requests and remote replays are not automatically sent again when their outcome is unknown.",
				} },
			},
		},
		{
			version = "1.7.0",
			date = "September 24, 2026",
			title = "Code workspace",
			highlights = "Shared Luau documents, a native editor, workspace files, Explorer, Remotes, and recorded changes with guarded review and Undo.",
			sections = {
				{ category = "added", label = "Workspace", items = {
					"Shared Luau documents, native multiline input, syntax colors, line numbers, Find, Go to line, indentation, and Run/Stop with retained output.",
					"Script/action library, typed action inputs, source versions, source Undo/Redo, guarded proposals, and wide or compact source comparisons.",
					"Native Explorer with lazy hierarchy, search, exact object references, multiple selection, supported properties, attributes, tags, hierarchy actions, source opening, world picking, bookmarks, and metadata export.",
					"Native Remotes with explicit scoped capture, pause/stop, bounded argument/result trees, independent filters and traffic rules, reviewed one-shot replay, generated scripts, and offline capture import/export.",
				} },
				{ category = "improved", label = "Coding navigation and review", items = {
					"Browse UAI workspace folders, expand parents, open files, and use Save or Save as. Disk-conflict checks preserve edited drafts.",
					"History and Game changes use searchable timelines and inline reviews, with source diffs, before/after values, and guarded Restore or Undo actions.",
					"Run and Save stay adjacent. Stop appears during a run; document labels and close targets keep room in narrow layouts.",
					"Coding buttons, toolbars, searches and dialog actions have consistent padding. Crowded action strips scroll and reveal keyboard focus; tree rows accommodate larger text and touch targets.",
				} },
				{ category = "improved", label = "Shared behavior", items = {
					"UI and tools share source revisions, instance identities, typed edits and recorded property/attribute Undo. Changing a view never runs source or starts capture.",
					"Two verified Code snapshots protect drafts; damaged files are preserved. Missing filesystem/compiler/clipboard capabilities have explicit fallbacks.",
					"Capture survives navigation and shows a launcher indicator. Stop, unload, reset and authorization revocation clean up owned behavior; expired callbacks cannot restart it.",
					"Capture coverage reports the actual backend, subscribed events and omitted targets. Game Undo covers recorded property and attribute changes with conflict checks.",
				} },
				{ category = "fixed", label = "Editing and live inspection", items = {
					"Syntax colors remain visible while editing, with a visible caret and selection. Switching files restores the document's cursor and selection.",
					"Explorer refreshes preserve the pressed row's identity. Parent clicks expand children and context actions target the clicked object.",
					"Remote Start/Pause/Stop work directly. Incoming discovery covers larger remote collections, quiet filtered calls remain findable, and arriving results preserve replay edits.",
				} },
			},
		},
		{
			version = "1.6.0",
			date = "September 23, 2026",
			title = "File attachments and Project Gravity",
			highlights = "Long inputs become real files with compact references. Control Gravity's engine, parts, settings, shortcuts and plugins. The agent works in small tool batches.",
			sections = {
				{ category = "added", items = {
					"Inputs over 8,000 bytes are saved intact to UAI/pastes/ as verified files, up to 2 MiB. Short messages stay inline; long source is not copied into the prompt.",
					"Browser uploads use separate ordered chunks. Both composers support attachment-only sends and retain drafts after a failed upload or send.",
					"Project Gravity tools inspect shapes and settings, control the engine, target players, adjust formations and control values, and invoke real shape buttons on desktop and mobile.",
					"Gravity Part Control lists held parts with session-scoped IDs, selects and moves groups, assigns pin/manual/shape modes, changes ride and physics overrides, and releases selected or all overrides.",
					"Gravity keybinds, favorites, settings reset, manual Slingshot controls, interface, visual performance, FPS, core color and ignore tags use native handlers. Key conflicts and stale part IDs are refused.",
					"gravity_plugin_read provides the guide, template and real source. gravity_plugin_write saves verified files from source or a saved path, validates setup once, and registers custom shapes with reload cleanup.",
					"gravity_launch downloads and runs the official Project Gravity loader when it is not already connected, reports the live status, and reloads on force. Shape inspection and the plugin guide cover the FrameTracking flag.",
				} },
				{ category = "improved", items = {
					"The prompt asks for successive batches of normally 1–4 independent tool calls. Tool-call limits and concurrency settings are unchanged.",
					"Automatic compaction sizes itself to the model's context window (Compact at, 80% by default), with the Context budget as a hard ceiling, and measures pressure against the prompt tokens the provider actually reports. Compact now, in the composer's message-options menu, folds older turns on demand.",
					"A live context-window counter sits beside the model in the composer, and the agent can review earlier conversations with conversation_list (triage by opening request) and conversation_read (a condensed digest by default, or verbatim with full=true).",
					"Landscape touch layout uses a compact multiline composer, searchable conversation navigation, full-width settings and a bounded attachment strip.",
					"Drafts, attachments, open forms and orientation-specific placement survive rotation. Mobile Enter adds a line; Send submits. Desktop placement stays independent.",
				} },
				{ category = "fixed", items = {
					"A failed file save never falls back to sending the entire long input. Missing attachments or disabled file tools leave the draft available for correction.",
					"Saved-paste reads preserve UTF-8 and continuation offsets, with at most 6,000 source bytes per slice. Searches accept pastes/ paths and explicit scopes cannot be shadowed by workspace names.",
					"Gravity connections follow the current runtime after reload and stop using an unloaded session.",
					"Gravity's companion update adds mobile shape/hotkey parity, restores visual effects and bindings on reset, and refreshes Part Control sliders and toggles after external changes.",
					"Loaded plugin callbacks stay usable after setup and retain explicit task cancellation. Failed plugin writes verify restored source before reporting recovery.",
				} },
			},
		},
		{
			version = "1.5.0",
			date = "September 20, 2026",
			title = "IY controls and executor timeout recovery",
			highlights = "Resolve player selectors, manage aliases and waypoints, and discover command syntax. Buffered requests use a smaller default reply ceiling and remember successful timeout recovery.",
			sections = {
				{ category = "added", items = {
					"iy_players resolves IY selectors to live player names before targeting commands, with a bounded listing and complete structured results.",
					"iy_control manages native events, keybinds, aliases, waypoints, settings and repeat loops. Alias and waypoint inspection supports pagination; waypoint deletion and clearing default to the current place, with all_places=true to clear every place.",
					"gui_scale and logs_webhook settings use IY's native commands, with asynchronous dispatch and saving reported explicitly.",
					"iy_plugin_read and iy_plugin_write support custom plugins with shared globals, multiple commands, aliases, syntax checks, returned-table validation and live reloads.",
				} },
				{ category = "improved", items = {
					"Context-length refusals teach a persistent model window. The current turn compacts and retries once before provider fallback; repeated summaries retain earlier facts even if a later summary request fails.",
					"Message options now includes a colored Context breakdown with system/tools, messages, rolling summary, unused space, and the compaction threshold. Compaction notices show the token reduction.",
					"Delete individual saved facts from Settings > Skills > Memory. AgentRouter is now featured with its signup requirement highlighted and its required Claude Code identity always sent.",
					"The desktop profile control shows your Roblox headshot beside a clearer name and provider hierarchy. Its menu adds a matching identity header, a live provider summary, roomier actions and visible hover and open states, with an initial fallback while avatars load.",
					"iy_cmds includes native argument signatures and short descriptions alongside names, aliases and plugin origins, with a fallback for older IY versions.",
					"Buffered HTTP uses an 8,192-token default reply ceiling through agent.executorReplyCeiling, without changing agent.maxTokens. Configured WebSocket streams, the enabled web relay and explicit token overrides bypass this default; 0 disables it.",
					"Both provider adapters can recover after 20–130 seconds without a response by retrying a smaller reply and reducing reasoning effort when available. A valid completion saves the working ceiling for that provider and model.",
					"The agent favors targeted file_edit and file_edit_many changes to keep replies within executor request windows.",
					"check_luau accepts saved scripts by path, matching run_luau and saved-paste reads. Large scripts use small sequential writes and checks/runs by path to avoid sending source repeatedly.",
					"Main and subagent prompts require reading every enabled skill first in every new or resumed conversation. Skill bodies and inventories paginate, and restricted subagents gain skill reads without mutation tools.",
				} },
				{ category = "fixed", items = {
					"Alias and waypoint edits validate inputs, refresh IY's GUI and clear tables in place. Coordinate waypoints use validated, floored values instead of the buggy upstream command; deletion preserves other places' waypoints.",
					"Failed sockets use the safer ceiling on HTTP fallback. Cancellations and already-minimal requests skip recovery retries; malformed or empty replies do not teach a token cap.",
					"file_write and file_append reject content over 2 MiB per call before writing, preserving existing files.",
					"Interrupted write arguments cannot become partial edits or scripts. Token-limited tool batches run no calls and request smaller complete calls.",
					"Profile headshots resolve and preload with bounded retries and stay renderable while loading. Closing a view discards late results while its native requests finish on live coroutines.",
					"Managed script stopping uses cancellation flags instead of closing native coroutines, removing cancellation paths that can leave Roblox callbacks targeting dead threads. Self-cancellation, finished handles, long delays and later callbacks use the same guards; external engine waits retain an explicit limitation.",
					"Failed turns release their busy state and invalidate old tool contexts. A new main or subagent turn cannot revive a failed or stopped worker.",
					"The minimize/restore launcher preserves the grab offset, waits for a drag threshold and tracks one pointer without opening after a drag. Focus loss and rebuild clean up listeners; keyboard and viewport changes preserve preferred placement.",
					"Task markers and notification content align across text sizes and input modes. Task disclosure choices persist, long plans stay bounded, and skipped tasks do not count as completed.",
					"Notifications show conversation titles and Open chat actions, preserve other unread conversations, fit the viewport and stop the busy pulse when work finishes.",
				} },
			},
		},
		{
			version = "1.4.0",
			date = "September 19, 2026",
			title = "Batch tools and a refreshed public showcase",
			highlights = "Find and inspect together, read several files per call, and apply ordered edits in one write. The public website gains a responsive layout and a searchable catalog of the actual tools.",
			sections = {
				{ category = "added", items = {
					"instance_query combines name, class and tag filters with selected properties and attributes. instance_get_many inspects up to 20 known paths with individual failures.",
					"file_search searches literal text across workspace files and returns line numbers, byte offsets and a continuation cursor.",
					"file_read_many reads up to 12 files or saved pastes within a shared result budget. file_edit_many preflights up to 20 ordered edits before one write.",
				} },
				{ category = "improved", items = {
					"Instance searches walk incrementally and stop when a page fills, with cooperative cancellation and a bounded scan instead of collecting the entire subtree.",
					"Repeated file slices reuse a bounded cache within one batch. Search cursors resume directly at a byte offset without scanning earlier lines again.",
					"The agent is guided toward combined queries, selected fields, batch reads and exact edits to reduce unnecessary tool round trips.",
					"The public showcase has a responsive layout, real tool counts, a searchable tool catalog, copyable starter prompts, and accessible navigation and copy feedback.",
				} },
				{ category = "fixed", items = {
					"Instance names containing dots, brackets, quotes or surrounding whitespace have parsed, round-trippable paths. Character, camera and primary-part references resolve through known instance links.",
					"String property conversion preserves whitespace; scalar numeric conversion refuses nonfinite values. Batch arrays enforce their size limits before execution.",
					"Searches report incomplete inventories and unreadable files. Stopped edit batches report cancellation, stale files are preserved, and unchanged edits avoid writes.",
					"The website catalog is generated from the bundled registry, and a reproducible build keeps the root and docs publishing copies synchronized.",
				} },
			},
		},
		{
			version = "1.3.0",
			date = "September 19, 2026",
			title = "Reliable code execution and clearer tool workflows",
			highlights = "Cancellable Luau execution, syntax checks, exact file edits, resumable source reading, and a more dependable chat interface in Roblox and Cowork.",
			sections = {
				{ category = "added", items = {
					"check_luau validates source with the executor's compiler without running it.",
					"file_edit replaces exact text, rejects ambiguous or stale matches, and supports explicit replace-all and deletion.",
					"file_read and script_source provide contiguous UTF-8 slices with continuation offsets, including long saved pastes.",
				} },
				{ category = "improved", items = {
					"run_luau captures print/warn, readable tables, and multiple return values. Its configurable 1–60 second deadline includes tasks started with task.spawn/defer/delay.",
					"Cooperative loop checkpoints keep ordinary loops responsive; Stop, deadlines, and unload cancel managed execution and report cancellation limits honestly.",
					"Parallel tool results appear as each call finishes. Progress belongs to its own call, and the transcript distinguishes stopped, timed-out, and failed work.",
					"Exact edits display labelled Before and After code listings. Cowork adds multiline code inputs, typed parameter controls, inline validation, and copyable code and output.",
					"Cowork preserves reading position and newer drafts and attachments during sends; compact layouts and accessible control labels work down to 320px.",
				} },
				{ category = "fixed", items = {
					"Compile and runtime errors now fail the tool call. Loop guards and JSON repairs preserve quoted source, and incomplete string arguments are rejected.",
					"Explicitly cancelled Luau tasks stay cancelled after their parent succeeds, even on hosts without working native cancellation. Self-cancellation stops the current task immediately.",
					"Disabled groups and conversation tool restrictions are enforced again before execution, including calls waiting for approval.",
					"Failed and stopped turns return to Ready, including a Stop on the last allowed step. Child tool summaries and tool-only restored conversations remain visible.",
					"Filesystem errors no longer look like successful writes or empty listings; failed append reads preserve the file, and ambiguous Windows path segments are rejected.",
					"Cowork handles IME input and unavailable browser storage, retains empty replacement strings, and attaches asynchronously read files to their original conversation.",
					"Targeted source checks resolve dependencies against the full source tree and reject empty scan targets.",
				} },
			},
		},
		{
			version = "1.2.0",
			date = "September 19, 2026",
			title = "UI repair, Markdown tables, and managed chat loops",
			highlights = "A measured, compact chat interface with Markdown tables, a refined model picker, bounded thinking, and background quizzes and chat automation.",
			sections = {
				{ category = "added", items = {
					"Markdown tables: aligned headers and cells, escaped pipes and inline code, responsive columns, and scrollable wide or long tables without dropping content.",
					"Managed chat tools: quiz_bot hosts and scores quizzes, auto_chat rotates messages, and auto_reply handles keyword responses; chat_loop_status and chat_loop_stop expose progress and cancellation.",
					"Independent chat_bot: AI conversation in Roblox chat with its own memory, configurable personality and player scope, duplicate-safe replies, and shared status/stop controls.",
					"Chat loop status and Stop all controls, with per-conversation cleanup and automatic shutdown on unload.",
					"Prompt starters and per-conversation draft/attachment retention across navigation and UI rebuilds.",
				} },
				{ category = "improved", items = {
					"Compact composer with content-sized model chips, optional multiline input, and secondary controls in one menu. Message copy/reuse/quote action bars have been removed.",
					"Model picker: content-sized provider selector, stable search and model rows, clear selection, optional effort controls, and a single scroll owner on small screens.",
					"Thinking stays collapsed initially, renders readable inline formatting when expanded, and uses a bounded scroll area for long traces.",
					"Provider tabs size to their labels; settings, tool details, logs, subagent rows, and quick chat use more consistent spacing and preserve reading position.",
				} },
				{ category = "fixed", items = {
					"Modal headers and content no longer compete for flex height; footer space follows its visible actions and respects keyboard/safe-area bounds.",
					"Narrow menus, segmented controls, badges, key/value rows, and large-text layouts keep labels and touch targets inside their bounds.",
					"UI teardown releases subscriptions and stale animation callbacks; repeated layout changes no longer accumulate camera listeners or revive closed surfaces.",
					"Chat sending reports missing channels and rejected sends accurately. Loops honor stop, permission changes, channel selection, pacing, and session removal.",
					"Unicode response reveal avoids splitting emoji and CJK characters; structured replies render without repeated table/code layout jumps.",
				} },
			},
		},
		{
			version = "1.1.1",
			date = "September 2026",
			title = "OpenCode Zen workaround, compact composer and response polish",
			highlights = "OpenCode Zen free-tier workaround (big-pickle), 62px compact desktop composer bar, full clipboard config transfer, Claude asterisk brand styling and progressive response reveal.",
			sections = {
				{
					category = "added",
					items = {
						"OpenCode Zen free tier workaround: complete compatibility for free-tier models (including big-pickle) with canonical 30-character session and request IDs, global project scoping, enforced SSE streaming, and standard tool declarations.",
						"Config import and export: full clipboard configuration transfer under Settings -> Import & export, safely preserving and applying provider keys and settings.",
						"Progressive response reveal: smooth typewriter reveal on AI responses with terracotta accent cursor and adaptive reading cadence.",
						"Claude brand asterisk: assistant byline icon updated to the Claude orange asterisk in warm terracotta.",
					},
				},
				{
					category = "improved",
					items = {
						"Desktop composer bar: compact 62px height without permanent bottom rows for a clean, spacious transcript layout.",
						"Transparent icon styling: removed backgrounds behind assistant, thinking, tool, and subagent icons across all conversation message types.",
						"Blockquote styling: markdown quotes rendered as sleek callout cards with warm terracotta left accent border.",
						"Build reload safety: new script executions cleanly replace older idle client instances without duplicate mounting or orphaned threads.",
					},
				},
				{
					category = "fixed",
					items = {
						"OpenCode Zen FreeTierError 403: resolved Console edge restrictions for free models by matching official CLI session formatting and stream requirements.",
						"Headless test harness compatibility: instant DOM reveal in offline harness tests to guarantee synchronous regression assertions.",
					},
				},
			},
		},
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

	-- Named sections keep their headings; other sections use shared category labels.
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
							label = section.label or LABELS[category] or category,
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
				revision = entry.revision,
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
		if config.get("ui.lastSeenVersion", "0.0.0") ~= latest.version then return true end
		return latest.revision ~= nil and config.get("ui.lastSeenChangelog", "") ~= latest.version .. ":" .. latest.revision
	end

	function M.markRead()
		local latest = M.latest()
		if not latest then return false end
		config.set("ui.lastSeenVersion", latest.version)
		config.set("ui.lastSeenChangelog", latest.version .. ":" .. (latest.revision or ""))
		return true
	end

	return M
end
