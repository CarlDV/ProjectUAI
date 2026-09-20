# Changelog

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
