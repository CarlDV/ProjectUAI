# Changelog

## 1.8.0 — September 25, 2026

Chat stability, provider compatibility, and native client improvements.

Available in game under **App menu → What's new**, also reachable from
**About → What's new**. Reload the updated native bundle to see the bundled notes.

- Correct provider URLs for loopback/LAN hosts, IPv6, custom prefixes and query
  strings. Scope discovered model lists and learned request repairs to their
  connection; preserve manual models after discovery/auth failures.
- Default vLLM to optional auth, add llama.cpp/SGLang presets, avoid unsupported
  Ollama tool defaults, preserve object-shaped tool arguments and recognize small
  local context/output limits. Honor bearer auth for Messages gateways.
- Apply local identity/auth defaults when choosing a preset inside Add Provider.
  Connection edits discard fetched model choices and cancel obsolete discovery
  without losing manual ids. Switching presets clears the previous gateway URL.
- Preserve full paths and identity/auth headers in gateway sockets, accept split
  and combined SSE events, clean up late connections, and allow HTTP fallback only
  before dispatch. Document the custom gateway contract and remove obsolete
  transport-ceiling claims. See [provider compatibility](docs/PROVIDER_COMPATIBILITY.md)
  and [the investigation log](CHANGES-2026-09-25-provider-compatibility.md).
- Preserve dialogue during long tool/subagent runs with independent history
  budgets. Keep call/result pairs and worker summaries together, save the same
  retained history, disclose history limits, and recover surviving dialogue from
  older context-only or activity-only saves.
- Draw the window directly on every device and maximize it without rebuilding
  the interface. Preserve reading position across refreshes and layout changes.
- Replay long conversations in bounded slices while queuing incoming events;
  cancel stale replay on switch, clear and destruction. Release expired GUI rows,
  nested code rows, timers and replay buffers as history rolls over.
- Add **Message options → Refresh conversation** for recovery during live work.
  Fall back to readable source when Markdown rendering fails, preserve original
  worker timings/counts, and search retained dialogue after model compaction.
- Track this work and its validation in
  [CHANGES-2026-09-25-chat-stability.md](CHANGES-2026-09-25-chat-stability.md).
- Include these changes in the in-game notes and restore the unread marker when
  notes change within the same client version.
- Remove the 8,192-token executor reply ceiling from both provider adapters,
  including native HTTP fallback. Keep configured output budgets and model limits.
  Render buffered replies immediately, forward real socket previews, and request
  concise progress messages between work steps. Center Add in the horizontal
  provider list, including after resizing.
- Repair the token context breakdown's category widths and shared accounting.
  Estimate prepared system/schema overhead, calibrate against dispatched history,
  invalidate measurements after provider/endpoint/model changes, and coalesce
  live refreshes with cleanup on close.
- Unify source/decompile provenance, explicit errors, deduplicated bounded requests,
  refresh generations, display pinning and expiry. Inspected Source and decompiled
  documents are read-only; editable extraction is explicit and never runs source.
- Guard Explorer hierarchy actions with the displayed selection identity/revision;
  distinguish primary, focus, anchor and clicked objects. Cancel stale queries,
  retain canonical pages and show runtime/display limits and incomplete counts.
- Reuse shifted syntax and line measurements, bound long-line drawing, share UTF-8
  coordinates, show multiline selection and search matches, and recover source
  expiry. Improve compact layouts, scoped shortcuts, autosave retry and conflicts.
- Use one Remote Spy target resolver, selected-target/30-second defaults, neutral
  hook attribution and explicit retained-wrapper status. Require portable-script
  review, open caller source outside hooks, and export frozen capture/source
  provenance. Account for late pinned completions and revoke agent capture promptly.
- Bound native workers, logs, callbacks and response parsing. Clean up after errors
  and preserve cancellation. Native timeout/unknown-outcome requests are terminal;
  this supersedes the historical smaller-request timeout retry described below.
- Keep transient progress out of retained transcripts, restore the newest saved
  conversations, and preserve unsaved threads beyond the memory retention target.
  Reject repeated run dispatch and stale Library removal confirmations.
- Reset stopped subagents for follow-up, keep queued follow-ups cancellable and
  reject duplicate dispatch. Honor the displayed concurrency range and prevent
  unlimited workers from inheriting the disabled finite queue budget.
- Add a fail-fast native verification command, performance contracts, actual Luau
  syntax compilation, deterministic module manifests and generated-output checks.
  Current features/limits: [native contract](docs/NATIVE_CLIENT.md). The bundle,
  generated site and in-game notes identify this release as **1.8.0**.

## Workspace organization — September 24, 2026

- Guide the agent to organise game work under `files/<place name> (<PlaceId>)/`, with authored and edited scripts in the game folder root and decompiled or dumped source in its `dump/` subfolder. Reserved path characters in the place name are dropped so the folder stays valid.
- Keep the per-game layout a default rather than a boundary: the file tools still reach shared utilities, other places' folders, cross-game notes, and `pastes/`, so the agent reads and writes outside the current game's folder whenever the work calls for it or the user names a path.

## 1.7.0 — September 24, 2026

- Rebuild the Coding tab around shared Luau documents, native multiline editing, line numbers, Find/Go to line, indentation, explicit Run/Stop, retained output, a script/action library, and typed action inputs.
- Add a workspace file browser rooted at `UAI`, with expandable folders, file opening, Save/Save as, and disk-conflict checks that preserve edited drafts.
- Keep syntax highlighting visible while editing, show the caret and selection, and restore each document's cursor position. Keep Run and Save adjacent, with Stop shown while a run is active.
- Stabilize Explorer selection and expansion during live refreshes, keep context actions attached to the clicked object, and retain horizontal scrolling for deep trees.
- Make remote capture available directly from Start/Pause/Stop, expand incoming event discovery, and preserve filtered calls and edited replay drafts as results arrive.
- Replace History and Game changes with searchable timelines and inline reviews, including before/after values and conflict-aware Restore/Undo actions.
- Add consistent inner padding and outer spacing to Coding buttons, toolbars, document tabs, search controls, and dialog actions. Crowded toolbars scroll, focused actions stay reachable, and tree rows allow room for larger text and touch targets.
- Verify Coding layouts at 320, 390, 620, and 960 px with pointer/touch input, comfortable/compact density, and enlarged text. Native game testing remains separate from these source and geometry checks.
- Add verified Code persistence with two snapshots, preserved legacy/damaged data, explicit save status, revision checks and changed-build protection. Closing a view retains its document; navigation and rebuild retain drafts.
- Add native Explorer with lazy hierarchy, cancellable search, stable object IDs, desktop/touch multiple selection, typed supported properties/attributes/tags, guarded hierarchy actions, source opening, bookmarks, world picker and metadata export. Recorded property/attribute changes support conflict-aware Undo.
- Add native Remotes with explicit capture scopes/lifetimes, incoming events, host-dependent outgoing capture, pause/stop, bounded typed values, view/admission filters, traffic rules, reviewed one-shot replay, generated scripts, offline import and verified split exports. Capture state remains visible on the minimized launcher.
- Converge instance/script/remote tools on shared services, preserve native-call arity, reject stale references/revisions, and paginate source/capture/result details. Direct calls work without a compiler; timed-out calls report outstanding status and are never retried automatically.
- Add lifecycle cleanup and agent-authorization revocation without changing model tool limits or concurrency. No third-party Dex/SimpleSpy window is downloaded or launched.
- Document native client workflows and capability limits, including source access, capture backends, and the scope of Game changes Undo.

## Context and provider improvements — September 23, 2026

- Learn model context windows from provider refusals, persist them in `agent.forceContext`, and compact then retry the same turn once before provider fallback.
- Merge previous rolling summaries with newer history, preserving earlier facts if a summary request fails.
- Add **Message options → Context breakdown** with distinct colors for system prompt and tools, messages, rolling summary, and unused space, plus the model window and compaction point.
- Show before/after token estimates in compaction notices and align their status dots with the text.
- Add a delete button for each saved memory while retaining **Forget everything** and live list updates.
- Feature AgentRouter with its registration requirement highlighted, the Anthropic Messages protocol, and its required Claude Code identity enforced for requests and model discovery.

## Documentation — September 23, 2026

- Expand `CODE_WORKSPACE_PLAN.md` with the native Dex/Explorer and SimpleSpy/Remotes implementation plan: upstream provenance, shared services, UI and AI controls, capture/replay behavior, capability fallbacks, phased delivery, and verification. These integrations remain planned; the released 1.6.0 client is unchanged.

## 1.6.0 — September 23, 2026

- Save inputs over 8,000 bytes intact as verified files in `UAI/pastes/`, up to 2 MiB each. Send a compact file reference instead of copying the source into the conversation. Short inputs remain inline.
- Upload long browser inputs and code attachments separately in ordered chunks. Native and browser composers support attachment-only sends, preserve surrounding instructions, and keep drafts when saving or sending fails.
- Read saved pastes in UTF-8-safe slices of at most 6,000 source bytes, including batch reads. `file_search` accepts explicit `pastes/` paths; explicit file scopes cannot be shadowed by similarly named workspace files.
- Add Project Gravity integration: inspect the live shape catalog and settings, start/stop/pause, target players, configure formations and controls, and invoke real shape buttons through Gravity's native handlers.
- Complete Gravity controls with paginated held-part inspection and session-scoped IDs; native selection, pin/manual/shape assignments, group movement, rideability, physics overrides, and release actions. Stale IDs, changed selections during shape loading, invalid batches, and unsupported runtimes are rejected before mutation.
- Add native core/shape keybinding edits with conflict checks, favorites, manual Slingshot launch/charge, and a complete settings reset. Expose interface, FPS, visual performance, core color, ignore tags, and Part Control panel defaults with live effects and refreshed controls on desktop and mobile.
- Add `gravity_plugin_read` for the module guide, working template, and local/official source. `gravity_plugin_write` accepts saved source paths, verifies files, validates setup once, and registers or reloads custom shapes with cleanup. Desktop and mobile Gravity launchers pass their live context; the integration follows reloads and unloads.
- Add `gravity_launch` to download and run the official Project Gravity loader from UAI when it is not already present, report the live status, and reload it on `force`. Shape inspection and the plugin guide now cover the `FrameTracking` flag.
- Keep loaded plugin callbacks usable after setup while respecting explicit task cancellation. Verify restored source after a failed plugin write before reporting recovery.
- Guide the main agent and subagents toward successive batches of normally 1–4 independent tool calls, instead of emitting dozens at once. Tool-call limits and concurrency settings are unchanged.
- Size automatic compaction to the model: when a model's context window is known, older turns are summarised starting at `agent.contextFraction` (80% by default) of it, with `agent.contextTokens` as a hard ceiling. Context pressure is calibrated against each provider's reported prompt-token count, so the system prompt and tool schemas are counted rather than estimated. A **Compact now** action in the composer's message-options menu folds older turns on demand, and the **Summarise old turns** switch now gates only the paid summary while the conversation is still trimmed to fit.
- Show a live context-window counter beside the model in the composer -- the share of the budget the next request will spend. Give the agent a proper way to review earlier conversations: `conversation_list` triages threads with their opening request, `conversation_read` returns a condensed digest by default (or the verbatim transcript with `full=true`), and `conversation_search` now returns each thread's id so it can be opened.

- Replace the temporary mobile dragging fix with a landscape-focused touch layout: compact multiline input, searchable conversation navigation, wider action sheets, and full-width settings forms.
- Preserve drafts, selections, open forms, and separate landscape/portrait placement through rotation. Keep the keyboard clear of input and focused form fields, and restore the launcher when minimized.
- Keep attachments in a bounded horizontal strip and retain access to them from Message options when keyboard space is tight. Mobile Enter adds a line; Send submits.
- Keep desktop styling, layout, and saved placement independent of the mobile changes.

## 1.5.0 — September 20, 2026

### Added

- `iy_players` resolves IY selectors to live player names before targeting commands, with bounded text and a complete structured name list.
- `iy_control` manages native IY events, keybinds, aliases, waypoints, settings, and repeat loops. Alias and waypoint inspection includes pagination; waypoint removal and clearing default to the current place, with `all_places=true` for clearing every place.
- IY settings now include `gui_scale` and `logs_webhook`, applied through native commands with asynchronous dispatch and saving reported explicitly.
- Add `iy_plugin_read` and `iy_plugin_write` for custom plugins with shared globals, multiple commands, aliases, syntax checks, returned-table validation, and live reloads.

### Improved

- The desktop profile control shows your Roblox headshot beside a clearer name and provider hierarchy. Its menu adds a matching identity header, a live provider summary, roomier actions, and visible hover and open states, with an initial fallback while avatars load.
- `iy_cmds` shows native argument signatures and short descriptions alongside names, aliases, and plugin origins, retaining compatibility with older IY versions.
- Buffered HTTP uses an 8,192-token default reply ceiling through `agent.executorReplyCeiling`, without changing the saved `agent.maxTokens` setting. Configured WebSocket streams, the enabled web relay, and explicit token overrides bypass this default; set the new option to `0` to disable it.
- Both provider adapters can retry a request that returns nothing after 20–130 seconds with a smaller reply and reduced reasoning effort when available. A valid completion saves the working ceiling for that provider and model so later turns can start smaller.
- File-writing guidance favors targeted `file_edit` and `file_edit_many` changes to keep replies within executor request windows.
- `check_luau` accepts saved scripts by `path`, matching `run_luau` and saved-paste reads. Large-script guidance uses small sequential writes and checks/runs by path to avoid sending source repeatedly.
- Main and subagent prompts require reading every enabled skill first in every new or resumed conversation. Skill bodies and inventories paginate within the result budget; restricted subagents gain read access without skill mutation tools.

### Fixed

- Alias and waypoint edits validate inputs before changing live state, refresh IY's GUI, and clear tables in place. Coordinate waypoints use validated, floored values instead of IY's buggy coordinate command; deletion preserves other places' waypoints.
- Failed WebSocket connections apply the safer ceiling when falling back to HTTP. Cancellations and already-minimal requests skip recovery retries, and malformed or empty replies do not create learned token caps.
- `file_write` and `file_append` reject content over 2 MiB per call before writing, preserving existing files.
- Interrupted write arguments cannot be repaired into partial edits or scripts. Token-limited tool batches run no calls and ask the model for smaller complete requests.
- Profile headshots explicitly resolve and preload with bounded retries. Images remain renderable while loading; closing a view discards late results while native requests finish on live coroutines.
- Managed script stopping uses cancellation flags instead of closing native coroutines, removing UAI cancellation paths that can leave Roblox callbacks trying to resume a dead thread. Self-cancellation, finished handles, long delays, and callbacks after a successful run use the same guarded lifecycle. External engine waits retain an explicit cancellation limitation.
- Failed turns release their busy state and invalidate old tool contexts; starting another main or subagent turn cannot revive failed or stopped workers.
- The minimize/restore launcher preserves the grab offset, waits for a drag threshold, tracks one pointer, and separates dragging from activation. Focus loss and rebuild clean up listeners; temporary viewport and keyboard changes preserve the preferred placement.
- Align task markers and notification content across text sizes and input modes. Preserve task disclosure choices, cap long plans, and exclude skipped tasks from completion progress.
- Add conversation titles and Open chat actions to notifications. Preserve other unread conversations, keep notification stacks within the available viewport, and stop the busy pulse when work finishes.

## 1.4.0 — September 19, 2026

### Added

- `instance_query` combines name, class, and tag filtering with selected property and attribute reads. `instance_get_many` inspects up to 20 known paths, retaining successful results when another path is missing.
- `file_search` searches literal text across workspace files with filename globs, case selection, line numbers, byte offsets, and resumable cursors.
- `file_read_many` reads up to 12 workspace files or saved pastes within one shared output budget. `file_edit_many` preflights up to 20 ordered edits to one file before a single write.
- The public showcase includes copyable starter prompts and a searchable catalog generated from the real bundled tool registry.

### Improved

- Instance searches traverse incrementally, stop when a page fills, and cooperate with Stop. A one-result query in the regression fixture inspects one node in a 3,000-node subtree without calling `GetDescendants`.
- File-search cursors can resume directly at a byte offset. Repeated file slices share a bounded cache within a batch; the cache ends with the call.
- The agent prompt guides combined queries, selected fields, batch reads, exact edits, and continuation handling to reduce unnecessary tool round trips.
- The public website has a new responsive layout, stronger text contrast, keyboard focus styles, a skip link, reduced-motion support, and video that plays on request.
- `node tools/build_site.js` generates the public catalog and release counts and synchronizes the root and `docs/` publishing copies. It refuses a stale Lua bundle; `--check` verifies without writing.

### Fixed

- Parsed, JSON-quoted instance path segments preserve names containing dots, brackets, quotes, control characters, or surrounding whitespace. Known Character, CurrentCamera, and PrimaryPart references resolve as instance links.
- String property coercion preserves whitespace; scalar numeric conversion rejects nonfinite values. Schema validation enforces batch array limits.
- Search results expose unreadable files and incomplete inventories. File searches bound directory, file, and line scans and count skipped files toward their whole-file read budget. Stopped edits report cancellation; stale files are preserved and unchanged edits avoid writes.
- Repeated website copy clicks retain their original labels. Clipboard failures offer text selection and visible feedback. Mobile navigation resets on link clicks, Escape, outside interaction, and viewport changes.
- Public tool names and counts match the shipped registry. The site no longer describes managed execution as a security sandbox or claims a fixed setup time.

## 1.3.0 — September 19, 2026

### Added

- `check_luau` compiles source without executing it.
- `file_edit` performs exact replacements, including empty replacements and explicit replace-all. It refuses missing, ambiguous, overlapping, or stale matches and bounds edited files to 2 MB.
- `file_read` and `script_source` return contiguous slices with byte offsets for reading the remainder. Saved-paste references work with bare, `pastes/`, and `UAI/pastes/` paths.

### Improved

- `run_luau` reports print/warn output, readable tables, cycles, and multiple return values, with bounded UTF-8 output. Loop checkpoints preserve source literals and line numbers.
- Execution deadlines are configurable from 1 to 60 seconds, defaulting to 10. The call waits for functions scheduled through its `task.spawn`, `task.defer`, and `task.delay` wrappers; Stop, deadlines, errors, and unload cancel managed tasks.
- Parallel tool results reach the transcript as each finishes while retaining the original order in model context. Progress updates identify their call.
- Roblox and Cowork show distinct execution states; exact edits have Before/After listings. Cowork includes multiline code fields, typed controls, validation, copyable output, and improved small-screen and keyboard behavior.

### Fixed

- Compile/runtime failures now produce failed tool results. JSON repair only changes syntax outside quoted strings and refuses unfinished string arguments.
- Explicitly canceled Luau tasks stay canceled after their parent succeeds, including on hosts without working native cancellation; self-cancellation stops the current task immediately.
- Dispatch rechecks tool-group and conversation restrictions after approval and skips stopped calls. Failed and stopped turns return to Ready.
- Explicit filesystem refusals and listing failures are reported. Append fallback preserves existing contents when reading fails. Windows path suffixes and control characters cannot bypass scope validation.
- Send acknowledgements preserve newer drafts and attachments, including edits that return to the original text. IME confirmation does not submit; unavailable browser storage does not break chat; asynchronous attachments remain with their original conversation.
- Tool-only restored transcripts stay visible; missing saved results stop displaying “Running.” Child summaries and scoped progress render correctly.
- Targeted Lua checks retain canonical module IDs and resolve imports outside the selected subtree.

### Execution limits

Managed execution is not a security sandbox or a rollback mechanism. Dynamically loaded code, engine calls, and callbacks registered on engine signals are outside its cancellation guarantee. On hosts without usable `task.cancel`, managed waits cooperate with cancellation and the result explains any remaining uncertainty. Successful scripts may still register persistent engine callbacks; their later work is outside the completed tool call.

Earlier release notes remain in `src/runtime/changelog.lua` and the in-app **What's New** view.
