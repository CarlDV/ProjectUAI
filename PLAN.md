# Native Client Improvement Plan

## Current implementation status

The implementation below is accounted for in
[docs/NATIVE_COMPLETION.md](docs/NATIVE_COMPLETION.md). Current supported behavior
and explicit limitations are in [docs/NATIVE_CLIENT.md](docs/NATIVE_CLIENT.md).
All source, tests, build tooling and documentation are prepared before the final
verification phase. [completions.md](completions.md) records the current outcome;
`node tools/test_native.js` writes stage evidence to
`refer/native-verification/results.json`. An incomplete run is not completion.
The work remains local and uncommitted.

## Scope

This plan covers the native Roblox/Luau client only.

The Node.js bridge, browser bridge UI, bridge authentication, bridge transport, bridge inference, bridge security, bridge tests, and bridge-related documentation are explicitly out of scope. Do not inspect, edit, test, refactor, or recommend changes to any bridge file.

Primary focus areas:

- Explorer
- Code workspace and editor
- Remote Spy
- Native runtime lifecycle and safety
- Decompile/source integration
- Native tests and build validation
- Native documentation and release hygiene

## Non-negotiable workflow

The implementation must be completed in this order:

1. Edit all intended source, UI, runtime, tool, test, build, and documentation files first.
2. Do not run tests during the implementation phase.
3. Do not stop after each phase to validate behavior.
4. After all edits are complete, begin the verification phase.
5. Testing is the final implementation step.
6. If testing reveals defects, return to implementation, make the required edits, then restart the complete verification sequence.
7. Do not commit changes.

“Testing is last” means no test, lint, typecheck, build, browser, bridge, or validation command is run until every planned code and documentation edit is complete.

## Phase 1: Source and decompile architecture

### Files to inspect and edit

- `src/runtime/script_sources.lua`
- `src/tools/script.lua`
- `src/tools/source_documents.lua`
- `src/tools/script_native.lua`
- `src/runtime/caps.lua`
- `src/tools/source_documents.lua`
- `src/ui/code/explorer.lua`
- `src/ui/code/remotes.lua`
- `src/ui/code/large_source.lua`
- `src/ui/panels/code.lua`
- Related native test files, but do not run them yet

### Required changes

Create one shared structured source/decompile result model covering:

- authored source;
- host-readable source;
- decompiled source;
- captured source;
- file snapshots;
- empty source;
- unavailable source;
- unsupported object;
- decompiler unavailable;
- decompiler failure;
- expired snapshot;
- stale request;
- oversized source.

Use a structure equivalent to:

```lua
{
    id = "source-...",
    instanceId = "...",
    instancePath = "...",
    runtimeEpoch = 1,
    method = "source" | "decompiled" | "captured" | "file",
    status = "available" | "pending" | "empty" | "unavailable" | "error" | "expired",
    bytes = 12345,
    readOnly = true,
    liveBinding = false,
    writeBack = false,
    capturedAt = 123,
    sourceHash = "...",
    diagnostics = "...",
}
```

Implement:

- per-instance capability detection;
- direct Source and decompile fallback through one shared service;
- explicit provenance;
- request generations;
- runtime epoch validation;
- stale-result discard;
- in-flight request deduplication;
- bounded completed-source cache;
- snapshot pinning while displayed;
- explicit snapshot expiry;
- safe diagnostics;
- consistent empty-source behavior;
- consistent unavailable/error behavior;
- read-only decompiled documents;
- extraction into separate editable documents.

Never decompile from render, signal, remote hook, property-change, or event-dispatch paths.

Never execute decompiled source automatically.

## Phase 2: Explorer implementation

### Files to inspect and edit

- `src/runtime/explorer.lua`
- `src/tools/explorer.lua`
- `src/ui/code/explorer.lua`
- `src/runtime/instance_refs.lua`
- `src/runtime/instance_paths.lua`
- `src/runtime/instance_scan.lua`
- `src/runtime/instance_fields.lua`
- `src/runtime/instance_edits.lua`
- `src/runtime/native_exports.lua`

### Required changes

Make selection state explicit:

- selected IDs;
- primary ID;
- anchor ID;
- focus ID;
- selection revision;
- runtime epoch;
- selection mode.

Ensure hierarchy actions use the exact selection identity and revision displayed by the Inspector. Reject stale or ambiguous destructive actions.

Separate:

- clicked object;
- focused object;
- primary object;
- all selected objects.

Improve selection behavior for:

- replace;
- add;
- remove;
- clear;
- primary removal;
- range selection;
- external selection changes;
- destroyed instances;
- stale UI snapshots.

Improve search behavior with:

- query IDs/generations;
- stale callback rejection;
- result deduplication;
- cancellation cleanup;
- visible partial/truncated states;
- literal versus Lua-pattern mode;
- active filter chips;
- explicit error and retry states;
- honest total/returned/omitted/unreadable counts.

Make runtime branch/query cursors canonical. Do not leave the UI silently mutating runtime-owned result pages.

Make all limits explicit:

- 20,000-child runtime limits;
- 4,000-row UI limits;
- 64-level reveal limits;
- inaccessible children;
- filtered children;
- partial scans.

Add source/decompile capability badges and actions. Do not expose source actions for non-source objects.

Add:

- breadcrumb navigation;
- reveal path;
- copy path;
- copy instance ID;
- visible select mode;
- touch/gamepad selection affordances;
- clear error/empty/truncated states;
- safe inspector refresh behavior.

## Phase 3: Code workspace and editor

### Files to inspect and edit

- `src/ui/panels/code.lua`
- `src/ui/code/editor.lua`
- `src/ui/code/large_source.lua`
- `src/ui/code/common.lua`
- `src/ui/code/tabs.lua`
- `src/ui/code/history.lua`
- `src/ui/code/output.lua`
- `src/ui/code/files.lua`
- `src/runtime/code_store.lua`
- `src/runtime/code_limits.lua`
- `src/tools/coding.lua`
- `src/tools/source_documents.lua`
- `src/tools/code_runner.lua`

### Required changes

Improve editor performance:

- incremental syntax highlighting;
- stable/reused line measurements;
- incremental width tracking;
- coalesced/cancellable syntax checks;
- bounded large-document work;
- no full-document deep copies on every keystroke;
- responsive handling of large decompiled source.

Create shared UTF-8 conversion utilities for:

- selection;
- search;
- cursor movement;
- status columns;
- source slicing;
- large-source pages;
- extracted ranges.

Define and document whether editor columns use bytes, UTF-16 units, code points, or grapheme clusters.

Fix:

- multiline selection rendering;
- horizontal caret reveal;
- `gotoLine`;
- match count/current match;
- match highlighting;
- case/whole-word search;
- matches spanning source pages;
- source snapshot expiry recovery.

Improve persistence behavior for:

- maximum-size autosave;
- interrupted saves;
- stale revisions;
- external modification;
- undo/redo across typing, tools, and proposals;
- corrupted persistence recovery;
- read-only decompiled documents;
- source snapshot expiration.

Expose explicit states:

- Saving;
- Saved;
- Retry required;
- Conflict;
- Expired source snapshot.

Fix narrow and compact layouts, including:

- single-pane behavior;
- compact-height behavior;
- safe areas;
- keyboard obstruction;
- touch/gamepad discoverability;
- current-tab emphasis;
- reduced motion;
- context-aware shortcuts;
- visible overflow actions.

## Phase 4: Remote Spy

### Files to inspect and edit

- `src/runtime/remote_capture.lua`
- `src/runtime/remote_hooks.lua`
- `src/runtime/remote_store.lua`
- `src/runtime/native_exports.lua`
- `src/tools/remote_capture.lua`
- `src/tools/remote_native.lua`
- `src/tools/remote_replay.lua`
- `src/tools/remote_transport.lua`
- `src/ui/code/remotes.lua`

### Required changes

Implement:

- one canonical Explorer target resolver;
- explicit primary selection target;
- clear selected-subtree semantics;
- neutral `hooked_unknown` attribution unless verified;
- accurate wording that probes do not invoke the predecessor but network behavior is host-dependent;
- explicit retained-forwarding-wrapper status after Stop;
- immediate permission invalidation where possible;
- byte accounting after late InvokeServer completion;
- frozen export sequence boundaries;
- bounded export paging;
- explicit expired/stale states;
- reconfiguration rollback or clear failure messaging.

Separate:

- passive observation;
- hook installation;
- traffic suppression;
- local error injection;
- replay;
- portable script generation.

Incoming records should support:

- copy diagnostic record;
- inspect caller;
- open caller source;
- decompile caller;
- open caller in Explorer;
- export metadata.

Outgoing records should support:

- edit replay arguments;
- review replay;
- open generated script;
- copy/export portable script;
- one-shot replay;
- inspect caller;
- decompile caller.

Require review before copying/exporting generated scripts.

Improve Remote Spy UI with:

- clear empty states;
- active/paused/expired/faulted status;
- visible follow/pause state;
- stable scroll behavior;
- touch-friendly metadata;
- explicit action targets;
- safer default duration;
- safer default scope.

For caller-source integration:

1. Preserve caller identity at capture time.
2. Resolve the caller after capture.
3. Attempt source/decompile outside hooks.
4. Show structured provenance.
5. Search the caller source for the remote name/path.
6. Highlight likely call sites where possible.
7. Export capture and source provenance together.

Never decompile inside interception hooks.

## Phase 5: Native runtime and lifecycle hardening

### Files to inspect and edit

- `src/runtime/instance_edits.lua`
- `src/runtime/instance_fields.lua`
- `src/runtime/instance_paths.lua`
- `src/runtime/instance_refs.lua`
- `src/runtime/instance_scan.lua`
- `src/runtime/fsx.lua`
- `src/runtime/code_store.lua`
- `src/runtime/remote_store.lua`
- `src/runtime/remote_capture.lua`
- `src/runtime/remote_hooks.lua`
- `src/runtime/dispose.lua`
- `src/runtime/signal.lua`
- `src/agent/session.lua`
- `src/agent/loop.lua`
- `src/agent/subagent.lua`
- `src/net/http.lua`
- `src/net/sse.lua`
- `src/net/ws.lua`

Implement:

- guaranteed cleanup after errors;
- bounded event logs;
- bounded threads/workers;
- stale-callback suppression;
- explicit worker lifecycle;
- cancellation-state preservation;
- resource disconnect cleanup;
- consistent deadline behavior;
- protection for retry callbacks;
- bounded response parsing;
- consistent malformed-stream errors;
- stronger path validation where applicable;
- secret-safe diagnostics;
- no duplicate execution after timeout;
- no automatic retry of timed-out remote replay.

## Phase 6: Native test and build edits

### Files to inspect and edit

- `test/run.lua`
- `test/coding_tab.lua`
- `test/native_workspace.lua`
- `test/coding_layout.lua`
- `test/execution_tools.lua`
- `test/execution_ui.lua`
- `test/build_reload.lua`
- `test/audit_regressions.lua`
- `test/context_compaction.lua`
- `test/check.lua`
- `tools/bundle.lua`
- `tools/build_site.js`
- `README.md`
- `SPEC.md`
- `CHANGELOG.md`
- Native testing documentation

Add or update tests for:

- Explorer selection and stale writes;
- Explorer search cancellation and deduplication;
- source capability and decompile failures;
- stale decompile completion;
- duplicate decompile requests;
- decompile cache eviction;
- read-only decompiled documents;
- UTF-8 selection and search;
- multiline selection;
- large-source page matches;
- large-document editor performance;
- autosave maximum size;
- undo/redo revision behavior;
- narrow and compact layouts;
- shortcut scoping;
- Remote Spy target consistency;
- caller source/decompile;
- hook provenance;
- late pinned completion;
- concurrent export;
- reconfiguration failure;
- permission revocation;
- incoming/outgoing action capabilities;
- one-shot replay;
- native runtime cleanup and cancellation;
- bounded persistence and source retention.

Improve:

- native bundle freshness checks;
- deterministic build verification;
- strict Luau validation;
- source/module hash manifests;
- generated-output drift detection;
- one native test command;
- coverage reporting;
- clear native test documentation;
- one current source of truth for supported features and limitations.

Do not edit or evaluate bridge files.

## Phase 7: Documentation cleanup

Update only native documentation.

Resolve contradictions between current source and:

- `README.md`;
- `SPEC.md`;
- `CHANGELOG.md`;
- `CODE_WORKSPACE_PLAN.md`;
- continuation documents;
- native testing documentation.

Mark obsolete planning documents as historical or remove them from current contributor guidance.

Document:

- current Explorer features;
- current Code workspace behavior;
- current Remote Spy limitations;
- source/decompile provenance;
- read-only decompiled documents;
- native test commands;
- native build commands;
- supported runtime capabilities;
- known host-dependent limitations.

Do not document bridge behavior.

# Verification phase — final step only

Do not begin this phase until every intended edit above is complete.

## Required verification order

1. Run the native bundle build.
2. Run the bundle freshness/stale-artifact check.
3. Run the native Lua static checker.
4. Run the main native Lua test suite.
5. Run every focused native Lua suite.
6. Run native performance checks.
7. Run any available native lint/typecheck commands.
8. Inspect the complete `git diff`.
9. Confirm no bridge files changed.
10. Confirm no secrets were introduced.
11. Confirm generated files are synchronized.
12. Confirm no unnecessary comments were added.
13. Confirm every planned requirement has either been implemented or explicitly reported as unsupported.

## If verification fails

- Stop testing immediately.
- Return to implementation.
- Fix the failure.
- Do not claim partial verification as complete.
- After any implementation fix, rerun the complete verification sequence from the beginning.

# Completion report

The final report must include:

1. Implementation summary.
2. File-by-file change list.
3. Explorer changes.
4. Code workspace/editor changes.
5. Remote Spy changes.
6. Decompile workflow.
7. Native runtime hardening.
8. Documentation changes.
9. Tests added and executed.
10. Build checks executed.
11. Known limitations.
12. Remaining risks.
13. Exact follow-up recommendations.

Do not claim completion unless all intended edits are complete and the final verification sequence has been run.
