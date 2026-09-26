# Native improvement implementation report — 1.8.0

This report records the September 25 native Roblox/Luau release. Current features
and limits live in [NATIVE_CLIENT.md](NATIVE_CLIENT.md).
Verification evidence is recorded by `tools/test_native.js` under ignored
`refer/native-verification/`; an incomplete report is not a passing result.
The September 25 release is numbered **1.8.0**. Provider behavior is documented in
[provider compatibility](PROVIDER_COMPATIBILITY.md), and native scenarios in
[the testing guide](CODE_WORKSPACE_TESTING.md). Superseded plans and handoff logs
have been removed. The later browser work is documented in the
[bridge guide](../bridge/README.md); historical native results below do not
validate subsequent changes.

The September 25 correction pass also repairs the token context inspector, rejects
source navigation after a view changes, preserves durable transcripts during
progress bursts, restores recent chats, handles interrupted save readback, reports
Explorer's exact display boundary, and guards repeated runs and stale deletion.
The follow-up removes the executor reply ceiling, replaces simulated streaming
with immediate buffered replies and actual socket previews, prompts for progress
between work steps, and centers the horizontal provider Add button.
The final lifecycle review repairs stopped-worker follow-ups, queued cancellation,
duplicate dispatch, the displayed concurrency range and unlimited queue budgets.
The changelog follow-up adds these changes to the in-game What's new notes,
preserves section headings and tracks revised notes independently of the client
version so existing users see the unread marker again.

## Implementation and requirement accounting

| Plan requirements | Implementation / explicit boundary |
| --- | --- |
| Phase 1: common source result, all origins and errors, capabilities | Shared `script_sources`, document provenance and structured tool errors. Empty, unavailable, unsupported, failed, stale, expired, invalid and oversized states stay distinct. |
| Phase 1: generations, epochs, deduplication, retention, pins | Four explicit workers, generation/epoch checks, eight snapshots/8 MiB, TTL and display-owned pins. Host calls cannot necessarily be preempted. |
| Phase 1: read-only source and extraction | Source/decompiled documents persist immutability; Run/proposal/action guards require separate extraction. No automatic execution/write-back. |
| Phase 2: selection identity, stale hierarchy actions | Explicit selected/primary/anchor/focus/click IDs, revision, epoch and mode; Inspector snapshots validate actions. Replace/add/remove/clear/range and destroyed-object reconciliation. |
| Phase 2: canonical search/paging and honest counts | Query IDs/generations, cancellation/disposal cleanup, deduplication, copied result rows and runtime page merging; partial/truncated/errors/filters remain visible. |
| Phase 2: limits and navigation | 20,000 runtime children/scan visits, 4,000 UI rows, 64-level reveal, capability actions, breadcrumbs, copy path/ID, Select mode and touch/gamepad controls. Native focus/hit testing remains host validation. |
| Phase 3: incremental work | Shifted-line syntax reuse, multiline-state invalidation, reused measurements/width counts, pooled/windowed labels, cancellable checks and metadata-only typing events. Full-string splitting remains bounded and linear. |
| Phase 3: UTF-8, selection, caret and search | Shared byte/range utilities, code-point columns, multiline highlights, horizontal reveal, Go to line, current/count/options/match overlays and page-crossing search. No grapheme/Unicode case-fold guarantee. |
| Phase 3: persistence and history | Maximum-size autosave, interrupted-save retry, external conflict checks, monotonic revisions, source Undo/Redo/proposals, corrupt recovery, immutable restoration and expiry recovery. Filesystem atomicity is host-dependent. |
| Phase 3: layouts and input | Compact single destination, short-height handling, safe-area/keyboard integration, active-tab emphasis, shared reduced motion, context-scoped shortcuts and visible overflow. Actual native IME/touch/controller tests remain necessary. |
| Phase 4: targets and truthful hooks | Shared target resolver with explicit primary and subtree semantics; neutral attribution, precise probe wording, retained-wrapper status, permission invalidation and clear failed-reconfiguration status. |
| Phase 4: capture lifecycle and export | Bounded buffers/pins, late completion accounting, Stop invalidation, frozen sequence/content exports and bounded pages, explicit expiry/staleness. |
| Phase 4: separate actions and caller workflow | Incoming diagnostics/caller/metadata; outgoing argument edits/review/script/replay. Caller identity captured first, source resolved/decompiled afterward, likely name/path matches highlighted and provenance exported. No decompile in hooks. |
| Phase 4: portable scripts and UI | Current review before copy/export; exact typed nil arity and path validation. One-shot plans, selected/30-second defaults, visible capture/follow/pause states and stable scrolling. Native outgoing Invoke outcomes remain unverified. |
| Phase 5: cleanup, workers, cancellation and paths | Disposal after errors, bounded signals/logs/session workers, expired-callback suppression, preserved cancellation, cancellable and resumable subagent queues, configured concurrency/budgets, connection cleanup and stronger user-file path validation. |
| Phase 5: resident conversations | Newest 64 saved conversations restore by activity; eviction preserves older disk history. The 64-thread memory target excludes busy/preparing/unsaved/ephemeral conversations, which can exceed it. A hard bound without discarding unsaved data and an archive browser are unsupported. |
| Phase 5: transport and parsing | Bounded HTTP/socket workers and responses, shared terminal deadlines, protected retry callbacks, bounded SSE/tool arguments, safe malformed-stream errors. No resend/fallback after unknown outcome; no timed-out replay retry. |
| Phase 6: tests and build hygiene | Main native mode, all focused suites, improvement/performance regressions, manifest/freshness/icon/catalog checks and official Luau syntax compilation. Synthetic coverage reports replace unsupported line/host coverage claims; strict Roblox type analysis remains unsupported. |
| Phase 7: current documentation | README/SPEC/native CHANGELOG and in-game What's new updated for 1.8.0; native contract/testing/report consolidated. Revised notes restore the unread marker. Superseded plans and handoffs have since been retired. |
| Requested token context repair | Explicit category widths, shared pressure/breakdown, prepared prompt/schema estimates, dispatch-time calibration per provider/endpoint/model, finite limits, over-budget display and coalesced lifecycle-safe updates. |
| Requested reply/progress/provider fixes | Remove the executor ceiling while retaining configured/model limits; immediate buffered replies, bounded real-frame previews, single final rendering, progress guidance and horizontal Add centering. Buffered HTTP and provider-internal reasoning cannot deliver unseen tokens. |

## File-by-file changes

Paths below are relative to the repository root. Related unchanged native modules
continue to provide their existing contracts; listed tests also exercise them.

| File | Change |
| --- | --- |
| `src/runtime/script_sources.lua` | Shared source provenance/errors, capabilities, bounded generation-aware requests, cache/pins/expiry and authored-document metadata. |
| `src/runtime/code_text.lua` | Shared UTF-8 byte ranges, code-point columns, pages and search. |
| `src/runtime/code_lexer.lua` | Incremental shifted-line reuse, multiline state and rich-text windows. |
| `src/runtime/code_limits.lua` | Explicit workspace and source-service budgets. |
| `src/runtime/code_store.lua` | Read-only guards, provenance, metadata events, search pagination, autosave/conflict/recovery behavior. |
| `src/runtime/explorer.lua` | Explicit selection, stale validation, canonical pages/queries, deduplication, cancellation and counts. |
| `src/runtime/instance_edits.lua` | Inspector-bound hierarchy targets and validated selection arrays. |
| `src/runtime/instance_refs.lua` | Protected identity reads and stale/native lifecycle handling. |
| `src/runtime/instance_scan.lua` | Cooperative traversal deduplication, cancellation and partial states. |
| `src/runtime/remote_targets.lua` | Canonical exact/primary/selection/subtree target resolution. |
| `src/runtime/remote_capture.lua` | Scoped capture, revocation, caller identity and explicit reconfiguration failures. |
| `src/runtime/remote_hooks.lua` | Neutral attribution, truthful probe/wrapper state and safe diagnostics. |
| `src/runtime/remote_store.lua` | Record capabilities, late ring/pin accounting, caller provenance and frozen exports. |
| `src/runtime/native_exports.lua` | Verified capture exports frozen before paging/writes. |
| `src/runtime/values.lua` | Portable typed Luau values with exact packed argument arity. |
| `src/runtime/fsx.lua` | Native path hardening and bounded persistence options. |
| `src/runtime/dispose.lua` | Bounded cleanup that continues after errors. |
| `src/runtime/signal.lua` | Bounded recursive dispatch, listener compaction and cleared callback release. |
| `src/agent/context.lua` | Shared breakdown, prepared overhead, dispatch-time/provider-scoped calibration and finite limits. |
| `src/agent/stream.lua` | Bounded, coalesced real-frame previews with UTF-8 boundaries, truncation and cancellation. |
| `src/agent/prompt.lua` | Brief assistant-content progress updates between work steps. |
| `src/runtime/config.lua` | Remove the executor-specific reply-ceiling default and persist the in-game changelog revision read marker. |
| `src/runtime/changelog.lua` | Updated native notes, preserved section headings and unread tracking for revisions within one client version. |
| `src/ui/changelog.lua` | Wrap named section headings within narrow in-game changelog cards. |
| `src/agent/session.lua` | Durable bounded logs and turn boundaries, recent-thread restoration, safe retention target, bounded workers, stale contexts and revocation. |
| `src/agent/loop.lua` | Prepared accounting before compaction, dispatch snapshots, reply model attribution, terminal transports and worker lifecycle. |
| `src/agent/subagent.lua` | Preserved cancellation, resumable/cancellable follow-ups, duplicate queue protection, configured concurrency/budgets, parent-specific cleanup and child listener release. |
| `src/net/http.lua` | Worker/body/deadline limits, callback protection and no unknown-outcome retry. |
| `src/net/sse.lua` | Bounded frames/chunks/arguments and explicit malformed-stream failures. |
| `src/net/ws.lua` | Bounded connections, terminal failures and cleanup of all socket callbacks. |
| `src/provider/openai.lua` | No terminal socket/HTTP fallback or adaptive timeout retry; protected callbacks. |
| `src/provider/anthropic.lua` | Matching terminal retry contract and bounded protected stream parsing. |
| `src/provider/traits.lua` | Reject invalid/nonfinite context-window overrides. |
| `src/tools/script.lua` | Source workflow through the shared service. |
| `src/tools/script_native.lua` | Unambiguous selectors and structured source errors. |
| `src/tools/source_documents.lua` | Read-only opening/extraction and captured caller name/path search/navigation. |
| `src/tools/explorer.lua` | Shared source/extraction tools and structured failures. |
| `src/tools/coding.lua` | Provenance/read-only metadata and search options/counts. |
| `src/tools/code_runner.lua` | Immutable-source guards at preparation/dispatch, one-shot snapshots and bounded run/output lifecycle. |
| `src/tools/remote_capture.lua` | Canonical capture targets and control/revocation wiring. |
| `src/tools/remote_replay.lua` | Reviewed portable source, expiring bindings and caller workflow. |
| `src/ui/code/editor.lua` | Incremental rendering, caret/selection/search, navigation, source pins and read-only editing. |
| `src/ui/code/metrics.lua` | Reusable UTF-8 line measurements and horizontal windows. |
| `src/ui/code/syntax.lua` | Shared native preview syntax, caret/selection overlays and listener cleanup. |
| `src/ui/code/explorer.lua` | Explicit selection/Inspector actions, limits, navigation and source capabilities. |
| `src/ui/code/large_source.lua` | Full-snapshot search, bounded pages/history, extraction and expiry recovery. |
| `src/ui/code/remotes.lua` | Target/capture states, incoming/outgoing actions, caller source and portable-script review. |
| `src/ui/code/output.lua` | Highlighted output with original copy text. |
| `src/ui/code/list.lua` | Shared code presentation in lists. |
| `src/ui/code/diff_view.lua` | Shared syntax presentation in comparisons. |
| `src/ui/code/library.lua` | Exact-entry deletion confirmation and stale-revision rejection. |
| `src/ui/code/preview.lua` | Shared preview syntax, caret and bounded rendering. |
| `src/ui/chat/composer.lua` | Active-provider pressure for the context indicator. |
| `src/ui/chat/context.lua` | Visible category labels, shared accounting, honest estimates/model limits and refresh/cleanup. |
| `src/ui/chat/view.lua` | Immediate buffered replies, real previews, final reconciliation, reopen and cleanup. |
| `src/ui/chat/message.lua` | Reused live-text label, replaceable reasoning and final model attribution; render final Markdown once. |
| `src/ui/panels/providers.lua` | Center the Add control in horizontal mode on creation and reflow. |
| `src/ui/panels/code.lua` | Read-only/expiry/storage states, extraction, compact layouts, scoped shortcuts, refresh cancellation and current deletion confirmation. |
| `src/ui/primitives.lua` | Shared code-field highlighting integration. |
| `src/ui/markdown.lua` | Shared syntax for code blocks. |
| `src/ui/overlay.lua` | Highlighted native code previews. |
| `test/native_improvements.lua` | Source, selection, Unicode, persistence, caller/capture, replay and lifecycle regressions, including stopped/queued subagents and configured limits. |
| `test/native_performance.lua` | Lexer/measurement reuse, metadata events, row/line/page bounds and retention contracts. |
| `test/coding_tab.lua` | Explicit selected-target default and deliberate broad capture coverage. |
| `test/context_compaction.lua` | Prepared overhead, category sums, dispatch snapshots, provider/endpoint changes and invalid counts. |
| `test/chat_regressions.lua` | Initial estimates, widths, refresh/cleanup, immediate replies, live/final reconciliation and persisted model attribution. |
| `test/native_workspace.lua` | Canonical selection/target and caller-source expectations. |
| `test/execution_tools.lua` | Native execution and terminal cancellation expectations. |
| `test/mock/instance.lua` | Native mock properties and lifecycle needed by the UI regressions. |
| `test/build_reload.lua` | Build manifest identity/order alongside existing reload regressions. |
| `test/run.lua` | Native-only scenario selection, terminal timeout expectations, output budgets, response-model attribution and persistent changelog revision/read behavior. |
| `test/check.lua` | Native-only direct source checks with import inventory retained. |
| `tools/native_scope.lua` | Explicit native validation scope. |
| `tools/test_native.js` | Ordered fail-fast verification, stage logs and behavioral coverage summaries. |
| `tools/bundle.lua` | Deterministic normalized manifest/module hashes and read-only freshness. |
| `tools/pack_icons.lua` | Read-only generated-icon freshness. |
| `tools/build_site.js` | Bundle-only freshness entry point and consistent `LUAJIT` override. |
| `dist/uai.lua`, `dist/uai.manifest.json` | Regenerated distribution and deterministic content manifest. |
| `index.html`, `docs/index.html` | Generated native tool descriptions/catalog mirrors when changed by the build. |
| `README.md`, `SPEC.md`, `CHANGELOG.md` | Current native behavior, limits, verification and numbered 1.8.0 release notes. |
| `docs/NATIVE_CLIENT.md` | Current feature/limitation reference. |
| `docs/CODE_WORKSPACE_TESTING.md` | Exact native command, prerequisites, suite coverage and host scenarios. |
| `docs/NATIVE_COMPLETION.md` | This implementation/file/requirements report. |

## Verification, limitations and follow-ups

The single command is `node tools/test_native.js`; the exact stage order and suite
discovery are documented in the testing guide. Run it only after all edits. A failed
stage stops the sequence and requires implementation fixes followed by a full
restart. Final scope, secret, whitespace, comments and artifact review follow a
successful sequence. The final September 25 run started at
`2026-09-25T12:58:39Z`, completed with exit 0 in approximately 760 seconds, and
produced build `1.8.0-d103d8c75bbe8744`: **44 stages, 33 focused suites, no failures**.
It covered 174 parsed files/173 modules, 129 main scenarios/1,867 checks, provider
compatibility (36 cases/610 assertions), transport (17/512), provider editor
(14/118), chat stability (16/304), 313 chat regression checks, 67 context checks,
42 native improvement cases/154 assertions, and five performance cases/13
assertions. Bundle/catalog freshness, mock self-tests and official Luau compilation
also passed. The machine-readable report was saved under
`refer/native-verification/`. The following runs are older checkpoints.

The complete run started at `2026-09-25T02:54:12.059Z` passed all 40 stages and
29 focused suites in about 604 seconds. Recorded results included 129 main
scenarios/1,843 checks, 40 native improvement cases/142 assertions, 313 chat
regression checks, 67 context checks and five performance cases/13 assertions.
The native static checker covered 171 files/170 modules with no failures or
warnings; bundle/catalog freshness, mock self-test, official Luau 0.739 compilation
and native Node syntax checks also passed.

That run preceded the final subagent review corrections and their two regression
cases. The next restart passed the main suite, then stopped on a new fixture that
selected the older blocking worker from the newest-first register. The fixture now
resolves the queued worker by identity. Final review also clears the pending Stop
label for stopped/failed workers and extends the lifecycle regression. These
source, test and documentation edits require a complete restart.
The latest local `refer/native-verification/results.json` records the restarted
run's actual start time, stages, counts and completion status; the historical
counts above are not evidence for a later revision. The final user handoff reports
that latest result and the subsequent diff/scope/secret/artifact review.

The restart at `2026-09-25T03:22:16.815Z` passed all 40 stages and 29 focused suites
in about 733 seconds, including 42 improvement cases/154 assertions. Its final
90-file scope, secret, whitespace and artifact review was clean. The subsequent
in-game changelog follow-up adds two changed native modules, wrapped section
headings and revision/read-marker coverage; it requires the same full sequence
after all edits. In-game notes are
under App menu → What's new and About → What's new in the rebuilt native bundle.

Remaining risks are host-defined hook behavior, native font/IME/controller layouts,
uncancellable executor work and filesystem writes without atomic rename. Retention
limits may intentionally expire hidden sources/captures. Textual caller matches can
miss aliases or point at an unrelated occurrence. Unsaved/ephemeral conversations
can exceed the resident-thread target; older disk history has no archive browser.
No real user Roblox session,
executor workspace or account data is required for automated verification.

Exact follow-ups before a release:

1. Follow the testing guide in an isolated fixture place on desktop, narrow/short
   layouts, phone keyboard/touch, tablet and controller; record CJK/emoji/IME,
   selection, horizontal caret reveal, source expiry and all visible actions.
2. With owned fixture remotes and declared capabilities, measure predecessor-once,
   nil arity, original errors, yielding/nested calls and hook coexistence before and
   after Stop/restart/unload. Keep unverified capabilities labelled until proven.
3. Exercise file-conflict/recovery only in synthetic or disposable fixture storage.
   If a native check requires a correction, finish edits and rerun the full command.
4. Keep the working tree local for user review; do not commit or publish this work.
