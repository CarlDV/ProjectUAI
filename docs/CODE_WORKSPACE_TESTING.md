# Code workspace: native testing guide

Updated September 25, 2026 for native release 1.8.0. Use synthetic workspaces
and an isolated fixture place; do not touch a user's live Roblox session or private
usage/accounting files. Current features and limits are in
[NATIVE_CLIENT.md](NATIVE_CLIENT.md), with internal contracts in [SPEC.md](../SPEC.md).

## Capability contract

| Surface | Current behavior |
| --- | --- |
| Editor | Native multiline TextBox with visible caret, selection and escaped syntax colors while editing. Enter adds a line; Run is explicit. |
| Workspace files | Expandable folders under UAI, Open, Save and Save as with disk-conflict checks. |
| Source Run | Shared managed Luau engine, requires a compiler, captures output and supports cooperative Stop. |
| Direct remote calls | Shared managed callable operation, no compiler required, exact packed arguments/returns. |
| Filesystem | Two verified Code snapshots; no filesystem means session-only source. Failed saves preserve live drafts. |
| Clipboard | Selectable native text fallback when copying is unavailable. |
| Explorer | Accessible hierarchy and a curated **supported properties** catalog; no hidden-property forcing. |
| Script source | Readable Source or available decompiler, structured provenance, immutable documents and explicit editable extraction. No server-source guarantee. |
| Incoming capture | Event subscriptions. No replacement/interception of function callbacks. |
| Outgoing capture | Explicit namecall or direct backend, owned detached routing probes, reusable forwarding cells. Probes do not invoke the predecessor; host network behavior remains unverified. |
| Intercepted Invoke outcomes | Separate unverified coverage. Original calls are forwarded without claiming observed completion. |
| UAI call outcomes | Observed returns when completed; timeout/Stop after dispatch reports outstanding and never retries. |
| Game Undo | Recorded property/attribute changes with conflict checks. Tags, hierarchy, arbitrary scripts and remote effects are outside coverage. |
| Exports | Verified bounded metadata/capture files and split parts. No full-map saving or unverified saveinstance adapter. |
| Offline import | Inert records. Rebind the current target and expired Instance arguments before separately reviewing replay. |

LuaJIT mocks establish synthetic behavior only. Lune is not Roblox's GUI renderer;
Chromium previews are approximate. Neither proves IME, native selection/touch/
gamepad, executor forwarding, server effects or client performance. Record native
outcomes with actual capabilities and host details, not just an executor brand.

## Editor, history and actions

1. Open Code; create, type, rename, switch, close and reopen scripts from Library.
   Read the just-typed draft with `code_read` before autosave. Identity/source
   survive rotation, navigation and theme/layout rebuild. Closing does not delete.
2. Exercise 2,000 lines, CJK/emoji, tabs, CRLF, quotes, long bracket strings/comments
   and long horizontal lines. Scroll both axes and edit near the bottom. The gutter
   aligns, the caret stays visible, and highlighting never changes raw source.
3. Verify mobile Return/Done never runs. Test Ctrl/Command+Enter, Find advancing/
   wrapping, Go to line, Tab/Shift+Tab, Save version, native Undo while focused and
   shared source Undo/Redo outside input focus. Use the visible menus on controllers.
4. Run a fixture that prints/warns and returns `false, nil, 7, nil`. Output identifies
   its run/document/revision even if source changes during execution. Stop managed
   waits/loops, inspect errors, and navigate while running without implicit cancellation.
5. Save a version, propose a change, compare in compact and wide panes, apply and
   restore. Change source while comparison is open: stale Apply must fail without
   overwriting. Repeated Apply cannot edit twice. Source and game histories stay separate.
6. Create an action with typed required/default/optional inputs; read them via
   `local inputs = ...`. Test false, zero, empty strings, omissions and invalid ranges.
   Original-source edits must not alter its saved snapshot. Updates require explicit
   comparison and current action/source revisions. Opening or updating never runs it.
7. Test no compiler, no clipboard and no filesystem. Inject failed/truncated writes
   in mock storage; verify backup recovery, preserved corrupt/legacy files and
   protection of future/unreadable formats. Changed-build replacement must refuse
   to lose unsaved or active workspace work. Never inject faults in real user files.

## Explorer and supported Undo

Use duplicate-named Parts, nested Models, a LocalScript, RemoteEvent/RemoteFunction
and an externally changing attribute.

1. Browse lazy children, expand/collapse, page large sibling lists and search by
   literal/pattern name, class and tag. Replace a running query. Malformed, expired
   or changed-filter cursors fail; partial/unreadable/capped scans remain visible.
2. Select the second duplicate by ID, rename/move it and retain its identity. Delete
   it and create a replacement at the same path: the old reference must not target it.
3. Test Ctrl/Command toggles, Shift ranges and visible Select mode for touch/gamepad.
   Selection caps at 20; multiple differing fields say Mixed. Test explicit attribute
   types, nil/absent/empty/unreadable distinctions, full CFrame and enum domains.
4. Open a draft, change its live field, then Apply: report conflict and retain the
   draft/newer value. Apply a fresh batch and Undo after observed readback. A conflict
   anywhere prevents all Undo writes. Inject partial write/readback/recovery failures
   and report unresolved changes honestly.
5. Test create, duplicate, move, detach and delete with overlapping selections,
   cycles, changed parents and destroyed destinations. Keep hierarchy outside Undo.
6. Open script snapshots read-only, extract a separate editable copy, refresh source
   and preserve the editable draft. Empty Source is a successful empty snapshot.
   Test missing/failed decompilers, deduplication, stale completion, expiry and pins.
   Source above 256,000 bytes uses the bounded reader, up to 2 MiB, with search,
   reference-copy and selection extraction. Existing file sources retain their path.
7. Reveal a remote without starting capture or sending traffic. Exercise bookmarks,
   explicit nil-root refresh, world pointer/touch picking and controller aim. Escape/
   Back, mode change, minimize and focus loss release picker bindings/highlight.
8. Export metadata at depths 0 and 2. Verify scope, IDs, omissions, file readback
   and refusal to silently overwrite an existing destination.

## Capture, replay and lifecycle

1. Before Start, importing modules/catalogs and reading state creates zero hooks,
   subscriptions or traffic. Explicitly test UAI-only, incoming, outgoing and
   combined capture. Mandatory unsupported directions fail visibly. Inspect scope,
   backend, monitored/omitted count, owner and duration; UI and tools default to 30
   seconds. No selected remote means default Start remains idle. Select all-game,
   exact selection or primary subtree scope explicitly before widening capture.
2. Capture zero args, one nil, an empty table, `false, nil, "text", nil`, supported
   Roblox types, aliases/cycles, sparse tables, binary data and oversized strings.
   Inspect graph/byte pages. Incomplete/opaque/cyclic/sparse data cannot replay as
   exact. Snapshotting cannot invoke arbitrary table metamethods.
3. Edit a pending call's replay draft and let its outcome arrive: the draft remains.
   Scroll away during a burst; Latest explicitly resumes following. Exercise name,
   direction, method, origin and outcome filters. Admission exclusion never blocks traffic.
4. Prepare a replay, change target/rules/record revision, cancel before dispatch and
   repeat its plan ID. An accepted plan sends once. A dispatched timeout remains
   outstanding; no retry. Bound source expires with its runtime; portable source
   rejects ambiguous paths. Require current review before copying/exporting portable
   source. Incoming calls have diagnostic/caller actions without replay controls.
   Open/decompile a captured caller and check name/path matches and provenance.
   Source generation/opening/import never executes.
5. In the isolated fixture, add/remove exact event blocking and function local-error
   rules. Pause stops recording while rules remain visible; Stop/unload/reset and
   agent authorization revocation disarm them. Unrelated revocation preserves a
   user-owned observation session. Confirm temporary `remote_watch` remains independent.
6. Export a frozen selection and a split capture with completion manifest. Fail a
   part write: no completed export is reported. Import parts offline, explicitly
   rebind current targets/Instance args, and separately review replay.
7. Overfill count/byte/pending/pin/subscription budgets and inspect gaps/counters.
   Navigation/minimize/theme rebuild must not duplicate hooks/listeners/timers.
   The launcher shows REC/PAUSED/RULES. Unload stops behavior and invalidates callbacks.
8. Native forwarding tests must verify predecessor exactly once, receiver identity,
   full nil arity, original error objects, yielding calls, nested calls, observer
   failure and UAI correlation. Test hooks installed before/after UAI, external
   removal, Stop/restart and changed-build replacement. Owned routing probes alone
   do not prove these guarantees; keep unverified coverage labelled until measured.

## Platform and performance matrix

Test wide desktop, a 400px-wide UAI window, phone landscape with keyboard, short
landscape, portrait, tablet, hybrid touch/keyboard and gamepad/console. Repeat with
text-size presets, theme rebuilds, focus in forms and modal Stop. Actions must remain
reachable without hover. Record native caret/selection/IME behavior separately.

Visible capture/property refresh is coalesced to 10 Hz; hidden views suspend costly
rendering. Measure pooled rows, large sibling/deep-tree scans, and hook snapshot
cost. GetChildren/getnilinstances still allocate native arrays; virtualization does
not remove that engine cost. Do not claim native performance from mocks.

Use the named budgets in [NATIVE_CLIENT.md](NATIVE_CLIENT.md). Include maximum-size
autosave, external conflicts, interrupted writes, source/cache eviction, pinned
late outcomes and frozen exports during concurrent capture. Editor columns count
Unicode code points; input offsets and source ranges are UTF-8 bytes with exclusive
ends. Native grapheme/IME behavior needs separate observation.

## End-stage checks

Implementation precedes testing, per user instruction. Run from the repository root:

```powershell
node tools/test_native.js
```

Prerequisites: Node.js, LuaJIT and the official Luau compiler. The command uses
`LUAJIT` and `LUAU_COMPILE` when set, then `luajit`/`luau-compile` on PATH; the
compiler may also be placed in `refer/native-tools/luau/`. This workspace prepared
the official Luau 0.739 release there. Missing compiler support fails the sequence;
it is never silently reported as passed. `luau-analyze` without Roblox and executor
type definitions is not a meaningful strict typecheck, so no such result is claimed.

The command performs these stages in order:

1. `luajit tools/bundle.lua --native`, then native tool-catalog/site generation.
2. `node tools/build_site.js --bundle-only --check` (bundle, manifest and embedded
   icons), then `node tools/build_site.js --check` (generated catalog/mirrors).
3. `luajit test/check.lua --native` for native dialect, parsing, imports and globals.
4. `luajit test/run.lua --native` against the assembled bundle.
5. Every focused top-level native `.lua` suite, followed by the mock self-test.
6. `luajit test/native_performance.lua` for deterministic work/retention contracts.
7. `luau-compile --null` for native modules, bootstrap and assembled bundle, then
   Node syntax checks of the native verification/build scripts.

Focused suites run the new/native workspace, execution and cancellation regressions
first, then the remaining suites alphabetically. Discovery excludes fixture/helper
files, the approximate image exporter
and non-native suites. Main native mode excludes non-native scenario names; native
static scope is explicit in `tools/native_scope.lua`. Distribution assembly keeps
existing dependencies unchanged. No browser, live account or Roblox session is used.

Each stage saves a log plus duration, exit status and suite summaries under ignored
`refer/native-verification/`; `results.json` is complete only when every stage passes.
This reports synthetic behavioral coverage, not a line-coverage percentage. The new
`native_improvements.lua` covers source deadlines and view cancellation, identity,
display-limit boundaries, interrupted-save readback, recent-thread restoration,
durable logs, capture, one-shot dispatch and stale removal confirmations. It also
covers stopped-worker resume, cancellable queued follow-ups, duplicate dispatch,
configured subagent concurrency and unlimited versus limited queue budgets.
`context_compaction.lua` checks prepared overhead, dispatch-time calibration and
provider/endpoint changes; `chat_regressions.lua` checks category widths, refresh
coalescing, inspector cleanup, immediate buffered replies, preview/final
reconciliation and retained model attribution. The main suite checks removal of the executor ceiling for both
adapters, including explicit budgets, legacy settings and native HTTP fallback;
non-native assertions in that shared case are skipped in native mode.
The main suite also covers the in-game What's new modal on desktop and phone
layouts, existing-version users receiving revised notes, and read markers surviving
a settings reload.
`native_performance.lua` checks reused work, row
pools and memory budgets.
`chat_stability.lua` checks dialogue retention through heavy activity, replay,
resize/maximize, refresh and cleanup. The provider compatibility and transport
suites cover all 23 presets with synthetic responses; `provider_editor.lua`
checks local preset defaults, manual models and discovery races through real UI
controls. None of these tests requires a hosted model or paid inference.
Existing focused suites cover layouts, shortcuts, replay and execution. Elapsed
fixture times are diagnostic, not native-device performance claims.

For the conversation renderer, keep several chats and workers active in an
isolated fixture while resizing, maximizing, minimizing and reopening the app.
Older dialogue, live previews and drafts should remain visible. Scroll into older
messages, change width/theme/text size, and verify the reading anchor. Exercise
large tables/code, folded worker feeds and **Refresh conversation** during and
after a turn; timings and totals should remain stable without duplicate rows.
GPU rendering, native text measurement, touch and IME still require this host check.

Stop at the first failure, finish the necessary implementation fixes, then rerun
`node tools/test_native.js` from the beginning. After it passes, inspect the complete
scoped diff, whitespace, accidental secrets, generated files and requirement
accounting in [NATIVE_COMPLETION.md](NATIVE_COMPLETION.md). Keep changes uncommitted.

The site generator synchronizes root `index.html`, `style.css`, `script.js` and
their `docs/` mirrors with the bundle. Regenerate; do not hand-edit generated files.
Record native validation with the client version, host capabilities, viewport and
input mode. Automated source and geometry checks do not establish native renderer
or executor coverage.

For native UI verification, resize Providers between its column and horizontal
strip layouts and confirm Add is centered vertically in the strip. With buffered
HTTP, confirm elapsed waiting followed by immediate replies; with a compatible
fixture socket, confirm in-place text/reasoning, Stop, reopen and final-message
deduplication. Do not mistake post-response animation for transport streaming.
