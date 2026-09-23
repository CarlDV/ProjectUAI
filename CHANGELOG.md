# Changelog

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
