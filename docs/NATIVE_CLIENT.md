# Native client features and limits

Current source of truth for the local native improvements to 1.7.0, September 25,
2026. These changes are local and unreleased. Internal APIs are described in
[SPEC.md](../SPEC.md); verification and native-device scenarios are in
[CODE_WORKSPACE_TESTING.md](CODE_WORKSPACE_TESTING.md).

In-game release notes are under **App menu → What's new**, also available from
**About → What's new**. Reload the updated native bundle to see the latest notes.
Revised notes restore the unread marker even when the client version stays the same.

## Explorer

Explorer browses accessible hierarchy, supported properties, typed attributes and
tags. Lazy pages, literal/Lua-pattern search, class/tag/subtree filters, breadcrumbs,
reveal, copy path/ID, bookmarks and picking use stable runtime-scoped object IDs.
Selected IDs, primary, anchor, focus, clicked object, revision, epoch and selection
mode are distinct. Replace/add/remove/clear/range selection reconcile destroyed
objects and external updates. Inspector hierarchy actions validate the displayed
selection and expected parents before writing. A stale Inspector cannot silently
retarget a different object. Field drafts retain conflicts instead of overwriting.

Runtime services own branch/query cursors and merge returned pages. Cancelled or
superseded queries cannot publish completion. The UI shows filter chips, retry/error
states and partial/truncated/unreadable counts. Unknown totals stay unknown.
Visible Select mode and menus provide touch/gamepad alternatives to modifier keys.
Actual navigation, focus and hit targets still require native-device verification.

## Code and source

Documents, revisions, source history, proposals and saved actions are shared by UI
and tools. The native TextBox owns input/IME; escaped syntax overlays supply color,
caret, multiline selection and match highlights. Unchanged shifted lines reuse
syntax spans and widths. Long lines use chunked measurement and horizontal windows.
Syntax checks are coalesced/cancellable. Typing emits small revision events; delayed
autosave, rather than every keystroke, serializes the workspace.
Unvirtualized Markdown blocks above 32,000 bytes and unknown languages use escaped
plain text; the editor/reader keep their bounded syntax windows.

Find offers current/total matches, case sensitivity and whole-word matching.
Offsets are **one-based UTF-8 byte positions with exclusive ends**. Status columns
count Unicode code points. Case folding is ASCII; whole-word boundaries treat
ASCII letters/digits/underscore and non-ASCII bytes as word constituents. There is
no Unicode linguistic case folding, grapheme clustering or UTF-16 coordinate API.
Full-snapshot search finds matches across large-reader page boundaries. Native text
layout can still differ for combining characters, bidi, tabs and host fonts.

Source inspection uses one service for host-readable Source, decompiled text,
captured/generated source and file snapshots; authored documents expose the same
provenance model. Results identify the object/path, epoch, method, status, byte
count, hash, capture time and diagnostics. Empty source is successful. Unsupported
objects, unavailable source/decompiler, decompiler failure, invalid/oversized text,
stale requests and expired snapshots are distinct errors. Content hashes identify
snapshots, not authenticity or trust.

Only explicit requests can decompile. Requests deduplicate by object, method and
generation; refresh/cancellation/runtime changes discard stale results. Visible
editors/readers pin snapshots and release them when hidden or destroyed. Host
Source and decompiled documents remain read-only, including after restoration from
disk. Extract a selection or whole document into a separate editable script before
editing, running, proposing changes or saving an action. Opening/extracting never
runs source. There is no live write-back, server-source guarantee or automatic
execution of decompiled text. Expiry offers refresh/reopen recovery; persisted
read-only text can be extracted without recovering the old runtime handle.
Source refreshes and caller-source requests cannot reclaim navigation after their
view is hidden, replaced or destroyed.

Two verified workspace files protect autosave. Maximum-size editable documents
fit the ordinary write path. Interrupted writes retain drafts and release the save
lock; Retry can repair this runtime's partial write or verify a successful write
whose readback was interrupted. Temporarily unreadable files require Retry.
External changes produce
Conflict. Corrupt supported snapshots are preserved before replacement; unreadable
or future formats remain protected. Source Undo/Redo, revision-guarded proposals
and Game changes are separate histories. States include Saving, Saved, Retry
required, Conflict and Expired source snapshot. Compact layouts use one active
destination, scrolling action strips, visible overflow and scoped shortcuts; safe
areas, keyboard obstruction and reduced motion follow the shared native UI.
Editor and Library deletion require a current confirmation; edits made after that review
invalidate it. A retained run snapshot can dispatch only once, and read-only
protection is rechecked at dispatch.

## Conversation context

Requests use the configured output budget and provider/model limits. The old
8,192-token executor ceiling is removed from both adapters and native HTTP
fallback; an old saved `agent.executorReplyCeiling` has no effect. Output-limit
finishes are visible even when all generated text was reasoning. The horizontal
provider list centers its Add control and returns to top alignment in column mode.

Buffered HTTP cannot expose a response before the host returns it. Received replies
render immediately without simulated typing. The agent prompt requests brief
progress messages between work steps; it cannot force a provider to yield text
during its internal reasoning. When the configured native socket transport really
delivers chunks, text and reasoning previews update in place, survive reopening
the transcript, and reconcile to one final message. Previews are bounded to 64 KiB
per text/reasoning channel and coalesce at 100 ms; the full final response replaces
them. Cancelled, failed and completed requests cannot publish late previews.
Reply labels retain the model reported by the provider, including when it differs
from the requested model; missing model metadata falls back to the dispatched model.

The composer and context inspector use the same pressure calculation as automatic
compaction: messages, rolling summary, and system prompt/tool-schema overhead.
Prepared requests supply an initial overhead estimate before a provider reply.
Provider token usage calibrates against the history sent, scoped to provider ID,
endpoint and model. Prompt/schema changes adjust that estimate; switching providers
does not carry over the prior provider's calibration. Before any request is
prepared, totals are explicitly partial. The inspector shows its model/window,
compaction point, unused space and any over-limit amount. Counts remain estimates,
and visible category totals sum to the displayed pressure. Updates coalesce to
100 ms and subscriptions end when the inspector closes or its conversation is
removed.

## Remote Spy

Capture begins only with explicit Start. The UI defaults to selected-remote scope
and 30 seconds; no selection means Start stays idle. Game-wide/selected-subtree
scopes and continuous lifetime are explicit. The shared resolver uses the displayed
Explorer snapshot, with primary as the selected-remote/subtree target. Exact remote
targets remain independent of unrelated selection changes.

Passive incoming events, outgoing hook installation, admission filters, traffic
suppression, local function errors, replay and script generation are distinct
actions. Incoming function callbacks are unsupported. Outgoing attribution is
`hooked_unknown` unless verified. Detached routing probes do not invoke the
predecessor, but network behavior depends on the host. Stop removes owned behavior
and reports an inert forwarding wrapper when one must remain. Permission, group,
session and runtime revocation invalidate agent-owned behavior promptly. Failed
reconfiguration clearly reports that the previous capture was stopped.

Incoming records provide diagnostics, caller inspection/source/Explorer navigation
and metadata export. Outgoing records additionally provide argument editing,
review, generated scripts and one-shot replay. Caller identity is captured with
the record; resolution and decompilation run after capture, outside hooks. Caller
source opens read-only and highlights bounded remote name/path text matches. These
are likely sites, not proof of which call executed. Dynamic aliases may have no
match. Export carries capture and source provenance together.

Portable scripts preserve supported typed values and exact nil arity, use ordinary
Luau path resolution and do not depend on the UAI runtime. Copy/export requires a
current reviewed digest and revalidates target paths. Bound scripts expire with
their runtime bindings. Replay validates target/rules/record revision and consumes
its plan once. A dispatched timeout is outstanding, never retried automatically.
No client action can roll back remote server effects.

Capture states and following/paused views remain visible. Late outcomes update
byte accounting even for pinned records. Stop invalidates pending completion
acceptance. Export freezes record content and sequence boundaries before paging;
later traffic cannot enter the snapshot. Split files receive a completion manifest
only after verified writes. Offline imports are inert and require explicit rebind
and fresh replay review.

## Named resource budgets

| Resource | Bound |
| --- | --- |
| Documents / open views | 24 / 10 |
| Editable source / inspected source | 256,000 bytes / 2 MiB |
| Source versions / aggregate history / workspace envelope | 12 per document / 4 MiB / 12 MiB |
| Saved actions / proposals | 24 / 3 per document |
| Source cache / TTL | 8 snapshots, 8 MiB / 5 minutes when unpinned |
| Source workers / waiter deadline / display page | 4 / 15 seconds / 6,000 bytes |
| Editor rows / measurement chunks / search matches | 160 / 2 KiB / 10,000 retained |
| Explorer branches / query snapshots / matches per query | 64 / 8 / 1,000 |
| Branch children / scan visits / displayed rows / reveal depth | 20,000 / 20,000 / 4,000 / 64 |
| Selection / edit batch | 20 objects / 100 operations |
| Capture ring / pending outcomes / incoming subscriptions | 1,000 records within 4 MiB / 128 / 2,048 |
| Capture pins / frozen page | 10 within 1 MiB / 100 records |
| Typed graph / string / depth / values | 32 KiB / 16 KiB / 12 / 1,024 |
| Export part / replay and review lifetime | 2 MiB / 5 minutes |
| Native HTTP workers / body / request wall | 8 / 8 MiB / at most 300 seconds including retries |
| Native socket workers and connections | 4 each |
| Stream frame / chunks / tool calls / arguments | 1 MiB / 10,000 / 64 / 256,000 bytes per call |
| Restored conversations / idle persisted retention target / running workers | 64 / 64 / 8 |
| Subagent running workers / queue ceiling | Configurable 1–12 / 45 seconds |
| Durable transcript / text field | 400 events within 1 MiB / 24,000 bytes |
| Live text/reasoning preview / refresh | 64 KiB each / 100 ms, first chunk immediate |

These bound application work and retention, not engine allocations. GetChildren,
getnilinstances, TextBox updates and executor calls can still allocate or block
inside the host. Uncancellable host work continues to consume worker capacity
until it returns; its abandoned result is ignored. Text splitting remains linear
in the bounded document size. No hard real-time responsiveness is claimed.
The 64-thread memory target evicts only idle, successfully persisted conversations;
busy, preparing, ephemeral and unsaved/no-filesystem threads are preserved and can
exceed it. A hard resident-thread bound without losing unsaved conversations is
unsupported. Restore selects the newest 64 saved conversations by activity, keeps
older files on disk, and scans metadata from the host's full directory listing.
It does not expose an archive browser for those older files.

## Lifecycle and verification limits

Disposal continues after individual errors, disconnects listeners and invalidates
late callbacks. Signals bound recursive dispatch and release cleared callbacks.
Sessions bound durable logs and resident workers. Turn boundaries are retained;
progress/status events cannot evict conversation content. Old/removed-session tool callbacks cannot
publish. Idle Stop invalidates old contexts while allowing fresh manual work;
clearing/removing a conversation cancels only its own child agents and clearing
starts a fresh context. Subagent follow-ups clear old stop state, register as queued
before waiting, reject duplicate dispatch and remain cancellable while queued.
Stopped or failed workers clear their pending Stop label on completion.
The concurrency setting is honored up to its displayed maximum of 12. Unlimited
subagents have no execution budget; their queue still has a 45-second ceiling.
Limited runs also charge queue time against their own budget.
Native HTTP and sockets
enforce deadlines, response limits, protected
retry callbacks and terminal malformed-stream errors. Timeouts/unknown outcomes
cannot trigger adaptive retries or provider fallback. Diagnostic errors are bounded
and redacted; raw decompiler/hook failures are omitted. File paths reject traversal,
control characters, trailing spaces/dots and reserved device names.

Automated evidence comes from synthetic Roblox fixtures, deterministic work/count
contracts and the official Luau compiler. Strict Roblox/executor type analysis is
unsupported without matching type definitions. Native renderer, IME, controller,
screen reader, font measurement, host hook coexistence, permission propagation and
server effects are not proven by these checks. Full-map export, hidden property
forcing, general game Undo and preemption of arbitrary native calls are unsupported.

Before publishing, run the isolated native-device scenarios in the testing guide,
record capabilities/device/input mode and check hook forwarding with an owned test
remote. Any implementation correction requires the complete native sequence again.
