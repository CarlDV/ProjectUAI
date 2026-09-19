# Changelog

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
