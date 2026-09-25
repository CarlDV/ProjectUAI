# Project UAI — contract

A universal Roblox AI agent client. Universal means: no game, no gateway and no
host script is assumed. It runs standalone under an executor, embedded in a host
script, or in any context that can call `loadstring`.

Everything below is a contract. Modules are written against it, `test/check.lua`
enforces the mechanical parts, and `test/run.lua` exercises the rest headlessly
under LuaJIT.

## 1. Authoring rules

Luau is written in a dialect that LuaJIT can also parse, so the whole project can
be checked and executed offline. `test/check.lua` fails the build on a violation.

| Rule | Why |
| --- | --- |
| No type annotations, no `->`, no `::` | LuaJIT cannot parse them |
| No backtick string interpolation | same; use `string.format` |
| No `continue`, no `goto` | keeps control flow trivially transpilable |
| No `//`, no digit separators, no binary literals | Lua 5.1 lexer |
| Compound assignment (`+=`, `..=`) only as a standalone one-line statement | makes the rewrite to `a = a + (b)` exact |
| Tabs for indentation, no trailing whitespace | matches the reference tree |
| Every module is exactly `return function(env) ... end` | one uniform loader |
| No module reads a global the allowlist does not name | catches typos offline |
| `--!globals name1 name2` extends the allowlist for one file | for the bootstrap only |

## 2. Loader and `env`

A module is a factory. `env.require(id)` loads it once and memoises the result.
`id` is the path under `src/` without the extension: `env.require("ui/theme")`.

```lua
return function(env)
    local theme = env.require("ui/theme")
    local M = {}
    return M
end
```

`env` is built once by `src/boot.lua`:

| Field | Meaning |
| --- | --- |
| `env.require(id)` | memoised module loader |
| `env.services` | memoising service proxy — `env.services.CollectionService` |
| `env.hs` `env.uis` `env.tween` `env.run` `env.guisvc` `env.players` | the six hot services |
| `env.plr` | `Players.LocalPlayer` |
| `env.caps` | capability report from `runtime/caps` |
| `env.caps.fn` | resolved executor functions (`request`, `writefile`, `loadstring`, ...) or nil |
| `env.context` | table the host passed in; `{}` when standalone |
| `env.info` | `{ name, version, folder, uaVersion }` |
| `env.root` | the `ScreenGui` every surface parents into |

Cycles are a load error, not a hang. `runtime/*` must not require anything above
it; `ui/*` must not require `agent/*` except through `agent/session`.

## 3. Transport and identity

`net/http` is the only module that performs a request.

* Executor `request` is preferred because it can set `User-Agent`. `HttpService:RequestAsync`
  silently drops that header, so on a vanilla client the Claude Code identity
  cannot be sent — `caps.uaSupported` is false and the UI says so rather than
  pretending.
* Every outbound inference call is stamped by `net/ua`: `User-Agent: claude-cli/<v> (external, cli)`,
  `x-app: cli`, and the `X-Stainless-*` companion set. The stamp happens inside
  `net/http`, so no caller can accidentally skip it.
* No Roblox transport can read a body incrementally. `stream: true` is still
  used: the whole SSE body arrives at once and `net/sse` replays it into deltas,
  which is what makes reasoning text and index-keyed `tool_calls` fragments
  usable. `net/ws` upgrades to real token streaming when the executor exposes
  `WebSocket.connect` and the gateway speaks it.
* Retries: 408/409/429/5xx and transport errors, exponential backoff with
  jitter, `Retry-After` honoured, capped attempts, then the next provider in the
  fallback chain.
* Native request deadlines, cancellation, malformed streams and response-limit
  errors are terminal. A long unanswered transport failure cannot trigger a
  smaller-request retry, key/provider fallback or a second dispatch after a socket
  send with an unknown outcome. Explicit API refusals can still teach a reply
  ceiling in `record.maxTokensCap = { model, tokens }`; a timeout teaches no cap.
  Both provider adapters protect retry callbacks and enforce these terminal states.
* Both adapters parse context-length refusals separately from output-token limits.
  A named window of at least 8000 tokens is saved under the lowercased model id in
  `agent.forceContext`, only lowering an existing value. Like `record.maxTokensCap`,
  the learned value persists; the context map is also included in configuration
  export. The loop compacts against the refusing model and retries it once before
  continuing the fallback chain. Cancellation and a history with nothing to fold
  do not trigger repeated requests.
* Buffered HTTP applies `agent.executorReplyCeiling` (default 8192). Only an actual
  configured WebSocket path or enabled web relay bypasses this default clamp;
  socket capability alone and ordinary SSE do not. A failed socket's HTTP fallback
  is clamped. The Anthropic adapter currently uses HTTP or the web relay, so an
  unused `wsUrl` does not exempt it. Explicit request token values and token fields
  in provider/request body overrides bypass the default clamp.
* Secrets are redacted in the request log; only the last four characters of a
  key are displayed in diagnostic views, and the Providers panel never renders the
  key itself. Full configuration export is an explicit private transfer: it includes
  complete credentials in clipboard JSON and is clearly labelled. Its import preview
  reports counts and provider names without displaying keys.
* `util.encode` is the only path to `JSONEncode`, and it scrubs on the way through:
  every string is repaired to valid UTF-8, NaN and the infinities become `0`, and a
  function, userdata or thread becomes a marker rather than a raise. This is not
  defensive coding for its own sake. `JSONEncode` refuses a string with one stray
  Latin-1 byte in it and raises `Can't convert to JSON` with no position, because it
  is a C function; a web search's scraped snippet is full of candidates; and the tool
  result is already in the message history by then, so the failure repeats on every
  following turn. `util.truncate` and `util.ellipsis` cut on character boundaries for
  the same reason — both index in bytes and would otherwise bisect an em dash.

## 4. Provider records

```lua
{
    id = "openai",                       -- stable key
    label = "OpenAI",
    baseUrl = "https://api.openai.com/v1",
    apiKey = "sk-...",
    authStyle = "bearer",                -- bearer | x-api-key | api-key | both | none
    models = { "gpt-4o" },               -- only what the user added or picked
    model = "gpt-4o",                    -- current selection
    headers = { ["HTTP-Referer"] = "" }, -- extra per-provider headers
    params = { temperature = 0.7 },      -- extra body fields
    stream = true,
    enabled = true,
    order = 1,
    claudeUa = true,                     -- send the Claude Code identity
    health = { ok = 0, fail = 0, lastError = "", cooldownUntil = 0 },
}
```

Base URLs are normalised once: a trailing slash is dropped, a missing `/v1` is
added unless the URL already names a path, and a URL that already ends in
`/chat/completions` is used verbatim.

`registry.requiresClaude(record)` recognizes `agentrouter.org` and its subdomains,
including manually entered endpoints. `identityFor` returns `claude` there even
when `record.claudeUa` is false. Inference and model-discovery requests mark this
identity as required, so `net/http` applies its headers despite the global switch
or conflicting custom headers. The provider UI explains the requirement instead
of offering a toggle. The featured preset uses `https://agentrouter.org` with the
Anthropic Messages adapter, producing `https://agentrouter.org/v1/messages`.

**Models are never guessed.** Presets carry no model list. `provider/models`
resolves a provider's models from exactly two sources — ids the user added by
hand (which rank first, and persist on the record) and whatever `GET /v1/models`
reported (cached for ten minutes, not persisted). Nothing is filtered out of the
endpoint's answer, because deciding which of its ids are chat models would be a
guess. An endpoint with no `/models` route is a normal case: the Providers editor
takes a typed id, and saving requires one.

Rolling compaction feeds the previous summary back to the summarizer with newly
removed turns. Failed or disabled summary calls preserve earlier facts and append
a note about dropped messages. The context inspector uses the same pressure and
limit calculation as compaction: estimated messages and summary plus prepared
system/schema overhead. Usage is calibrated against a dispatch-time snapshot and
scoped to provider ID, endpoint and model; changing prompts adjusts the estimate.
Before the first prepared request, totals are labelled partial. Its colored bar
uses the model window when known and the compaction point otherwise; the marker
and legend make that scale explicit. Category labels reserve the remaining row
width, and live refreshes are coalesced and disconnected when the inspector closes.

Native requests no longer apply an executor-specific output ceiling; saved
`agent.executorReplyCeiling` values are ignored. Genuine socket frames produce
transient `assistant:preview` events through `agent/stream`, with coalesced 64 KiB
text/reasoning previews and cancellation. Final text/reasoning replace their
previews and are retained once; buffered HTTP replies render immediately without
simulated typing. The prompt requests brief assistant-content updates between
tool steps. Tokens cannot be displayed before the host/provider delivers them.

Generation settings live in `runtime/config` and are persisted in `UAI/config.json`:

| Setting | Default | Behavior |
| --- | --- | --- |
| `agent.maxTokens` | 128000 | Saved reply limit; model limits and learned per-model caps apply when constructing requests. |
| `agent.contextTokens` | 1000000 | Context budget before compaction. Larger contexts spend more of an executor's request window on upload and prefill. |

## 5. Tool contract

```lua
{
    name = "instance_find",
    group = "instance",
    risk = "read",                 -- read | write | danger
    needs = { "loadstring" },      -- capability keys, checked before dispatch
    description = "...",           -- what the model sees
    parameters = { type = "object", properties = {}, required = {} },
    run = function(args, ctx) return "text" end,
}
```

`ctx` carries `emit(kind, text)` for progress, `aborted()`, `env`, `session`,
`depth` (subagent nesting) and `budget`. A handler returns a string, or a table
`{ text = "...", data = <table> }` when the UI can render something richer. A
handler may yield. Raising an error is caught and reported to the model as a tool
error, not a crash. Returning `{ ok = false, text = "..." }` reports a semantic
failure without raising. Dispatch rechecks disabled groups and the session's tool
filters before execution, including after a pending approval resolves.

The prompt asks for successive batches of normally 1–4 independent calls, waits
for their results, and discourages dozens of calls in one response. Dependent
calls and changes to the same file or runtime state run in successive steps.
This is prompt guidance only; tool-call limits and concurrency are unchanged.

Inputs over 8,000 UTF-8 bytes become verified files in `UAI/pastes/`, with a
2 MiB maximum per file. Preserve the original bytes, including whitespace, and
send only a compact path/size/line-count reference without a source preview.
Short messages stay inline. The native composer separates a large inserted
block from the surrounding editable text; attachment-only sends are valid.
The browser transfers long text through ordered `attachment:upload` commands
before `send`, with conversation ownership, byte offsets and idempotent retries.
Only a verified final write produces a usable reference. Failed saves, missing
files or unavailable file tools leave the draft intact and never send the long
source inline. These are executor workspace files, not provider-specific uploads.
Explicit `files/` and `pastes/` paths resolve before bare-name fallbacks; client
configuration is never a fallback scope. Saved-paste slices return at most 6,000
source bytes with UTF-8-safe continuation offsets, including batch reads.

The prompt directs game-specific work into a per-place folder under `files/`,
named `<place name> (<PlaceId>)` from the environment block with path-reserved
characters (`<>:"|?*` and trailing dots or spaces) removed. Scripts the agent
authors or edits go in that folder's root; decompiled or dumped source goes in
its `dump/` subfolder. This is prompt guidance, not an enforced boundary: the
file tools still resolve any valid path under `files/`, so shared utilities and
cross-game files stay reachable.

`run_luau` uses a separate managed executor with a default 10-second deadline
(configurable to 1–60 seconds), cooperative loop checkpoints, bounded output, and
capture of multiple returns. Functions scheduled through its task wrappers share
the deadline and complete before the result is delivered. Stop, failure, timeout,
and unload stop managed tasks cooperatively without native `task.cancel`. Pending
Roblox/executor continuations retain live coroutines instead of targeting closed
ones. Managed delays use cancellable wait slices; explicit cancellation accepts
only this execution's task handles, treats finished handles as a no-op, and exits
self-cancelling tasks inside their protected wrapper. Work suspended outside
managed waits may still resume before its next checkpoint, which is disclosed.
Dynamically loaded code, native engine calls, and persistent engine-signal
callbacks are outside this guarantee. Failed turns invalidate their tool contexts;
starting another main or subagent turn cannot revive old workers.

`check_luau` only compiles. Both `check_luau` and `run_luau` accept either inline
`code` or a saved `path`, using the same workspace/paste resolution as `file_read`.
This keeps saved source out of repeated model output. `file_edit` requires an exact
unique match unless replace-all is explicit, permits empty replacement text, and refuses stale file
contents. `file_read` and `script_source` use contiguous UTF-8 slices with 1-based
byte offsets and continuation cursors; each slice fits the registry's result budget.
`file_write` and `file_append` advertise and enforce a 2 MiB content limit per call
before disk access. The prompt and tool descriptions direct edits of existing
large files to `file_edit`/`file_edit_many`; full writes create files or replace
most of their contents. Large new scripts use small sequential writes/appends,
then syntax checks and execution by path. JSON repair preserves the complete outer
object and rejects unclosed strings. Mutating tools also reject missing closers
instead of dropping unfinished edits/options. A token-limited tool batch produces
an error result for every call without executing any, allowing the model to send
smaller complete calls on its next step.

Main and subagent prompts require reading every enabled skill before replying or
performing other work in each new or resumed conversation. The environment supplies
names, filenames and descriptions; `skills_read` supplies the body. Both skill
bodies and `skills_list` paginate through UTF-8-safe byte offsets within the result
budget. Restricted subagent presets include the skills group and explicitly exclude
its write/install/delete tools. Disabled skills remain unreadable; denied or
unavailable reads do not require retries. Changed skills and bodies lost through
compaction must be read again.

The Project Gravity tool group resolves the live `_GRAVITY_CONTEXT` for each
action, falling back to `env.context.gravity`. Desktop and mobile Gravity
launchers pass that context explicitly. Initialization publishes the handle;
teardown clears only its own handle. Reloaded or torn-down contexts cannot be
used for a pending mutation. `gravity_status` is available without a connection;
engine and shape operations use the dynamic `gravity` capability and normal
permissions. Shape catalogs and control metadata come from the live runtime and
paginate; controls use their real keys and stored slider units, including `Div`,
`IntOnly` and the native speed-range extension. Setting batches validate before
mutation, preserve table identities, and invoke the relevant native handlers.

`gravity_parts` lists the authoritative held-part map in claim-ID order, with
filters, continuation offsets and at most 25 records per call. IDs include the
Gravity session ID; stale or cross-session IDs cannot select a new part.
`gravity_part_control` uses the native selection/assignment/ride/physics/release
handlers, requires the guarded Part Control API, and honors the native 512-part
selection ceiling. Shape loads recheck cancellation, session identity and the
entire selected-record snapshot before assignment. Group movement preserves
spacing, using current pin/manual targets or the parts' world positions.
Selection clearing retains overrides; `release_all` includes unselected ride and
physics overrides even without a mode. Per-part overrides are session state.

Engine configuration also covers UI scale, HUD, visual performance, FPS, core RGB
color, ignore tags and Part Control panel defaults. FPS requires native executor
support. Typed batches validate before mutation and restore previous settings
when a native effect fails, reporting an incomplete restoration when necessary.
Part Control defaults are separate from assigning overrides to a selection.
`gravity_keybind` rebinds native core/shape shortcuts after rejecting collisions;
`gravity_favorite` changes the native favorites table and selector. A settings
reset uses Gravity's complete reset hook, including visual restoration, hotkeys,
control refresh and post-startup plugin defaults. `persist=false` avoids requesting
a save for settings, keybindings, favorites, shape selection and reset. Manual
Slingshot launch/charge requires that shape and its manual-control mode.

`gravity_plugin_read` supplies the module guide, template or bounded local/official
source slices. `gravity_plugin_write` accepts source or a saved file path, checks
syntax, verifies the real `GravityShapes/` file, and requires `overwrite=true` for
replacement. Default loading runs setup once under the existing execution deadline,
validates the returned module and controls, cleans up a previous module and
preserves compatible settings. An inactive shape is not selected automatically.
`load=false` saves syntax-checked source without executing it. Replacements check
for file/runtime changes during setup; failed verification restores the previous
file where possible. Released plugin callbacks have no setup deadline but retain
explicit task cancellation; persistent callbacks require plugin-owned cleanup.

Infinite Yield tools read the running engine's environment, for both an ambient
IY and a captured internal load. `iy_cmds` joins the executable command registry
with IY's `CMDs` signature/description list by name or alias, retaining the first
description for a token and limiting descriptions to 120 bytes. Older engines
without `CMDs` retain name/alias/plugin output. Filtering and result limits remain
available.

`iy_players` is a read tool with no extra host capability requirement. It delegates
`selector` to IY's `getPlayer(selector, localPlayer)` and returns `{ names, count }`
alongside text limited to 50 names by default (maximum 200). Empty matches and
unavailable resolvers are explicit. Supported selector syntax follows the live
IY, including `all`, `others`, `me`, `random`, `#<n>`, `%<team>`, `allies`, `enemies`,
`team`, `nonteam`, `friends`, `nonfriends`, `guests`, `bacons`, `age<n>`, `nearest`,
`farthest`, `group<id>`, `alive`, `dead`, `rad<n>`, `cursor`, `npcs`, `+`/`-`, and
comma-separated lists. In the reviewed upstream version, `@name` matches username
prefixes without considering display names.

`iy_control` retains write permission for its combined inspect/edit surface.
Inspection sections are `all`, `events`, `keybinds`, `settings`, `aliases`, and
`waypoints`. Alias and waypoint sections expose 1-based indexes, `items`, `total`,
and `nextOffset`; malformed entries are labeled and still advance pagination.
Waypoint inspection includes coordinates, the place ID and the all-place count
when available.

The existing event/keybind actions and `stop_loops` are joined by:

- `alias_add`, `alias_remove`, `alias_clear`: validate command names and aliases,
  update both `aliases` and `customAlias`, refresh the native editor, and request
  IY's save. Adds use the first command token and reject unknown commands, duplicate
  aliases, native command collisions, whitespace and IY command delimiters.
- `waypoint_add`, `waypoint_remove`, `waypoint_clear`: validate names and finite
  coordinates, floor explicit or current-root coordinates, and update `WayPoints`
  plus `AllWaypoints`. Removal is case-insensitive and scoped to the current place,
  including legacy entries without a place ID. Clear defaults to the current place;
  `all_places=true` explicitly clears all saved places. Tables are cleared in place
  so native GUI references remain live. The buggy upstream coordinate command is
  not used.
- `configure` additionally accepts `gui_scale` (0.4–2) and `logs_webhook` (HTTP(S)
  URL or empty to disable). These use `guiscale` and `chatlogswebhook`, report
  asynchronous dispatch, and require saving because the native commands save
  themselves. `persist=false` remains available for direct native edits; mode
  changes alone continue to work without loading IY.

Batch tools use the existing `instance` and `fs` groups and the same permission
and capability checks as individual operations. Array schemas enforce `minItems`
and `maxItems` before dispatch; oversized arrays are rejected before visiting
their members.

- `instance_query` combines name/class/tag filters with up to 12 selected
  properties and 12 attributes. `instance_get_many` accepts up to 20 known paths
  with per-path failures. Fields are compact and bounded; bulk projections
  direct Source reads to `script_source`.
- `instance_find` and `instance_query` walk children incrementally, without
  allocating a whole descendant list. Scans stop as soon as a page fills, yield
  cooperatively, and inspect at most 20,000 nodes. Query offsets refer to the
  current traversal order; restart if the tree changes. An incomplete scan must
  never be presented as proof of absence.
- `file_search` searches single-line literals in the files scope or an explicit
  `pastes/` path, supporting
  filename globs and a case-sensitive option. Its inventory caps are 128
  directories, 1,000 files, and 6,000 entries. It skips binary files and files
  over 2 MB and scans at most 8 MB and 50,000 new lines per page. The read budget
  counts skipped data and is checked between whole-file reads: hosts expose no
  portable stat/range API, so the final read can exceed it. Returned cursors
  include a path, line, and (where available) direct byte offset. Continue with
  the same search; restart after source changes. Read errors and incomplete
  inventories appear in both text and structured results.
- `file_read_many` accepts up to 12 files or saved pastes, each up to 2 MB. It
  shares the configured output budget, retains individual failures, and returns
  per-slice offsets plus a request index if the batch fills the page. Repeated
  slices reuse at most 2 MB of cached content within that call only.
- `file_edit_many` accepts 1–20 ordered exact edits to one workspace file. Each
  edit sees the previous edit's proposed result. Every match and size check must
  pass before rereading the original to check staleness and performing one write.
  An unchanged result performs no write. Original and resulting files are
  bounded to 2 MB. Cancellation before the write returns an aborted status.

Instance paths are parsed, never executed. Dotted paths continue to work;
JSON-quoted bracket segments preserve exact names, including punctuation and
surrounding whitespace. Known `Character`, `CurrentCamera`, and `PrimaryPart`
links can resolve when no named child exists. String property coercion preserves
whitespace, and scalar numeric coercion rejects nonfinite values.

## 6. Event stream

`agent/loop` never touches the interface. It emits into `agent/session`, which
fans out to subscribers. Every payload also carries `kind` and `at` (epoch ms),
stamped by `session.emit`.

| kind | payload |
| --- | --- |
| `user` | `{ text }` |
| `status` | `{ text }` |
| `turn:start` / `turn:end` | `{ turns, unlimited }` / `{ text }` |
| `request:start` | `{ provider, providerId, model, attempt, messages, stream }` |
| `request:retry` | `{ provider, attempt, attempts, status, wait, reason }` |
| `request:done` | `{ provider, model, ms, streamed, via }` or `{ provider, model, ms, error }` |
| `provider:switch` | `{ from, to, reason }` |
| `assistant:text` | `{ text, final }` |
| `assistant:reasoning` | `{ text }` |
| `tool:call` | `{ id, name, group, risk, arguments }` (arguments is the raw JSON string) |
| `tool:progress` | `{ id, name, text }` — scoped to its originating call |
| `tool:result` / `tool:error` | the dispatch result: `{ id, name, ok, text, ms, risk, group, args, error, full, truncated, data }` |
| `permission:ask` | `{ id, name, group, risk, description, args, resolve }` |
| `usage` | `{ session, turn }` — the two counter tables from `agent/usage` |
| `compact` | `{ summary, before, after }` |
| `subagent:start` | `{ id, call, label, task, preset, turns, budget, unlimited, depth, followUp }` |
| `subagent:status` / `subagent:text` | `{ id, call, label, text, bad? }` |
| `subagent:tool` / `subagent:tool:done` | `{ id, callId, name, risk, arguments, index }` / `{ …, ok, ms, summary }` |
| `subagent:done` | `{ id, ms, ok, aborted, messages, turns, resumable, text }` |
| `cleared` | `{}` |
| `error` | `{ message, fatal }` |
| `abort` | `{}` |

Parallel tool results are emitted as each call finishes. The batch still returns
results in the original call order for model context. A progress event without an
ID is rendered only when one call is open, so legacy emitters cannot overwrite the
status of unrelated parallel work. Failed and stopped turns restore Ready status.

The task list does not travel on this stream: `agent/state` owns it and publishes
`todosChanged(items, session)`, because the list outlives a turn and a panel opened
later has to be able to read it rather than replay it. The list itself lives on the
session (`session.todos`), so `setTodos`, `todoCounts`, `todoBlock` and `todoList`
all take the session they are about and the subscriber filters on the second
argument. A client-wide list is not an option: two conversations can run at once,
and one plan for both means a running turn resumes against somebody else's steps.

`agent/session.anyEvent` fires `(session, payload)` for every event of every
session. A surface that must answer a conversation nobody is looking at subscribes
there rather than to `session.events`; `ui/panels/permission` is the case that
requires it, since a prompt raised by a background conversation has to reach the
screen or its own deadline denies every call behind it. Subscribers must skip
`session.headless` -- a subagent's prompts are forwarded onto its parent's stream,
so the child's own copy is a duplicate.

Pending permission requests are per-session too. `permissions.request` records the
asking session on the entry, `denyAll(reason, session)` sweeps only that
conversation's prompts, and `pendingCount(session)` counts them. `denyAll()` with
no session still clears everything, which is what an unload wants.

Every dispatch is registered in `agent/subagent`: `records` (running first, finished
history capped at 24), the `changed` signal, `list`, `running`, `resumable`, `get`,
`find(reference)`, `stop(id)`, `stopAll` and `clearHistory`. A record carries `id,
label, task, preset, depth, parentId, parentTitle, startedAt, status, calls,
finishedCalls, tools, currentTool, statusText, ms, messages, runs, unlimited, report`,
the `parent` session currently waiting on it and the `callId` inside that session, and
the child `session` that `stop` sets `abortFlag` on. `status` is one of `queued`,
`running`, `done`, `stopped`, `failed`. A stop is noticed between steps, not on the
instant -- Luau cannot kill a thread.

A dispatch is a conversation, not a single question. `dispatch_agent` creates the
child and returns its id in the report; `agent_followup` runs the same session again
against the context it already has, which is what `followUp(id, task)` does and what
`runs` counts. `parent` and `callId` live on the record rather than in a closure
because the turn asking a follow-up is a different tool call, possibly in a different
conversation, and the live card has to appear under the row the user is looking at
now. Only the newest `RESUMABLE` (6) finished records keep their `session`; past that
the record keeps its report and the context behind it is released, so `followUp`
refuses with a reason rather than resuming something that is no longer there.

`agent.subagentUnlimited` lifts a child's step limit and wall-clock budget and makes
the dispatching tool call wait as long as the child takes. It is separate from
`agent.unlimitedTurns`, which the loop applies only to a session with no step budget
of its own: the dispatcher passes its decision down as `session.unlimited`, so a
delegated child is lifted only when that has been asked for in those words. What
still bounds a child either way: the repeat breaker, each tool's own timeout, the
provider retry cap, the depth and concurrency ceilings, and Stop.

Each session mirrors the stream into a bounded `session.log` (400 events), and the
transcript is a pure function of that log — `view.attach` replays it, which is what
makes a rebuild on a mode or token change lossless. A subset of the kinds is also
written to `sessions/<id>.json` and replayed on restore: `user`, `assistant:text`,
`assistant:reasoning`, `tool:call`, `tool:result`, `tool:error`, the five
`subagent:*` kinds, `request:retry`, `provider:switch`, `compact`, `error`, `abort`.
The rest are deliberately excluded, and for two different reasons: `status`,
`request:*`, `tool:progress`, `usage` and `turn:*` are meaningless once the turn
they describe is over, and `permission:ask` carries the closure that answers it, so
encoding it would fail the whole write. A call whose result is not in the restored
log stops spinning and says the result was not kept, rather than inventing an
outcome or spinning forever.

## 6a. What is counted, and where

`agent/stats` is the only place a figure the interface displays as a statistic
comes from. It observes the stream through the `onEvent` hook and the
`usage.recorded` signal, buckets everything by local day and local hour, and
persists to `stats.json`.

* A number is recorded or it is absent. Nothing is modelled, sampled or
  interpolated, and no surface may compute a headline figure of its own.
* Tokens are counted from the first request this store ever sees. There is no
  history to recover -- `agent/usage` has always been in-memory -- and an
  estimate would be a figure with no measurement behind it.
* Messages and conversations *are* recovered once, on the first run, from the
  real timestamps in the transcripts already on disk.
* A subagent's requests and tokens count toward the conversation that dispatched
  it; its messages do not, because nobody typed or read them.
* Buckets are local, via `runtime/clock`: `dayKey`, `hourOf`, `dayNumber`. The
  conversion is arithmetic on the epoch plus this host's UTC offset, probed once
  from `DateTime`, because Roblox's pattern formatter is the only calendar API
  and its pattern support differs between client versions.

Persisted files, all under one folder (`env.info.folder`, default `UAI/`):

| file | written by | holds |
| --- | --- | --- |
| `config.json` | `runtime/config` | every setting, the provider list, permission rules, memory |
| `sessions/<id>.json` | `agent/session` | one conversation: context, transcript, title, place and timestamps; newest 64 restored, older disk history retained |
| `stats.json` | `agent/stats` | per-day and per-model counters; days capped at 400 |
| `export/*.json` | the Import & export pane | a shareable copy of the settings, with keys reduced to four characters |

## 7. Design tokens

No use site writes a raw colour or number. `ui/theme` exposes `theme.color.*`,
`theme.text.*` (role -> size/font/lineHeight/height), `theme.space.*`,
`theme.size.*`, `theme.radius.*`, `theme.stroke.*`, `theme.opacity.*`,
`theme.scale.*`, `theme.motion.*`, `theme.z.*`. `ui/responsive` reports the active
breakpoint and layout mode from the live viewport, so a window that opens on a
phone and is then rotated re-lays-out rather than keeping whatever was true at
boot; it holds no metrics of its own.

The palette is one warm neutral ramp of twelve steps plus one accent. Surfaces are
separated by two or three steps of lightness and a hairline, never by a shadow or a
heavy fill; the code surface sits *below* the canvas rather than above it -- except
under the light code palette, which inverts that pair deliberately and separates the
block from the page with its own border instead. The accent is reserved for meaning
-- inline code, a running turn, a risk level -- and the single loud control per view
is `color.solid`, a cream fill with dark text, which is deliberately not the accent.
`test/run.lua` computes WCAG contrast over every pair the interface actually puts
together, for every accent and every code palette, and fails the build under 4.5:1
for text, so a token cannot be retuned into something unreadable.

Four token groups are settings rather than constants, and each has to change what
is on screen or it is decoration:

| setting | token | effect |
| --- | --- | --- |
| `ui.interfaceFont` | every non-mono `theme.text.*.font` and `.face` | the family the interface is set in |
| `ui.codeFont` | `theme.text.mono`, `theme.text.monoSmall`, `theme.codeFontEnumName` | the family code is set in, fenced and inline |
| `ui.codeTheme` | `color.codeSurface`, `codeBar`, `codeText`, `codeGutter`, `codeAdd*`, `codeRemove*` | a light or dark code palette, in the transcript as well as the preview |
| `ui.transcriptWidth` | `size.reading` | how wide the transcript and composer columns grow |

Type resolves in two layers. `theme.text.<role>.font` is an `Enum.Font` and always
takes; `.face` is a `FontFace` carrying the family plus an independent weight, and
`P.text` layers it over the enum only when the client produced one -- so `strong` is a
real SemiBold where the modern type stack exists and degrades to the family's legacy
medium where it does not. The family list is *discovered*: each candidate is read back
off the engine with `Font.fromEnum` and dropped when the member is absent, so a name
this client cannot load can never be offered. A hardcoded `rbxasset://fonts/families`
path has the opposite failure mode -- it constructs fine and renders nothing.

A clickable row uses `P.rowButton`: the button *is* the row and the layout goes
inside it. A transparent full-size button dropped in beside a row's contents does
not layer over them -- a `UIListLayout` gives it a slot of its own and pushes them
past the row's edge, where they are still drawn because nothing clips them.

The window root is a `CanvasGroup`, which brings one rule with it: **it is never drawn
at anything other than 1:1.** The group renders every child into an offscreen texture
and then draws that texture, so any scale or fractional offset resamples it and the
whole interface -- every glyph in it -- goes soft at once, with nothing on screen to
explain why. Two consequences, both asserted in `test/run.lua`:

* No `UIScale` on the group. The 0.98-to-1 entrance blurred the window for the length
  of the animation and left it blurry permanently if the tween was interrupted by a
  hide, a rebuild or a second open. `GroupTransparency` is the entrance instead, which
  is the one thing a CanvasGroup composites for free.
* A centred dimension keeps the space around it even. With a 0.5 anchor, an odd
  difference between the viewport and the window puts the left edge on a half pixel, so
  `handle.centred` nudges the size by one pixel -- in the layout and in the resize grip.
  Nobody can see the pixel; everybody can see the blur.

Entrance scales on plain frames (the modal card, the settings dialog, quick chat) are
allowed -- a `UIScale` there re-lays-out rather than resampling -- but each one snaps to
exactly 1 on `Completed`, because an interrupted tween otherwise leaves the surface
laid out at 98% of its own metrics for as long as it is open.

The window shell itself is a `CanvasGroup` only on pointer layouts. On touch devices the
engine caps CanvasGroup texture resolution, and a window covering most of a phone screen
is over the cap -- the texture is drawn resampled and every glyph goes soft, while the
small Frame-based modals beside it stay sharp. On `touch`, `sheet` and `panel` the shell
is a plain `Frame` with no group fade; it loses a tenth of a second of fade and stays
legible.

Breakpoints: `xs < 520`, `sm < 900`, `md < 1280`, `lg < 1700`, `xl`. Layout modes:
`sheet` (xs), `panel` (sm, touch-only input, and any portrait orientation), `window` (md+), plus `tv`
when `GuiService:IsTenFootInterface()`. Minimum touch target is 44px on a touch
device, 28px with a pointer, 48px on a console. Navigation is reachable in every
mode: the sidebar in `window`, the app menu in the header everywhere else.

Mobile chrome trims padding rather than touch targets: at default density its
header is 48px and its collapsed composer is 56px. The welcome view uses compact
prompt rows and omits the large decorative mark and subtitle. Desktop chrome and
spacing retain their existing dimensions. Mobile resize lives in the header so
its touch target cannot cover Send; a separate expand action restores the previous
size and position. In short keyboard space, multiline input uses one compact row
without changing the draft or its multiline editing mode.

Landscape is the primary touch layout. Ordinary typing stays in the compact
composer, and explicit expansion provides more draft space. Mobile Enter inserts
a newline; only Send submits. Attachments occupy one horizontal scroll row, with
management available from Message options when keyboard space hides their preview.
Rotation relays out existing mobile views without replacing their text fields,
selections or live forms. Mobile navigation pins conversation search above a
scrollable history, opens conversations directly, and separates history actions
from opening. Short keyboard layouts return footer space to the results. Settings
use a category picker with the full width available to the active form. The mobile
launcher is visible only while the main window is minimized.

Sheets, panels and desktop windows can all be moved. Default desktop placement
avoids CoreGui's top bar, but dragging and restoring a chosen position use the full
device-safe parent, measured through a transparent frame inside the ScreenGui.
The top-bar inset is not a physical obstruction across that whole parent. Geometry
is recorded on release, separately in `ui.window`, `ui.mobilePanel` and
`ui.mobileSheet`; maximised or keyboard-constrained sizes never overwrite a normal
placement. Keyboard dismissal restores it. Header controls do not initiate drags,
and each gesture continues to follow only the input that began it.

Mobile geometry is keyed by orientation, including tablets whose portrait and
landscape modes are both `panel`. A forced mobile `window` layout still uses mobile
geometry. Keyboard positioning uses the reported top edge when available, and
focused mobile fields are revealed through their scrolling ancestors. Desktop
geometry and pointer layouts retain their existing behavior.

Profile avatars start with a readable initial behind a renderable image. A deferred
worker resolves a ready headshot through `Players:GetUserThumbnailAsync` and calls
`ContentProvider:PreloadAsync`, retrying up to three times. It checks `IsLoaded`
after preloading as well as on property changes. Destroying the avatar invalidates
its results without cancelling a coroutine inside a native thumbnail or preload
request. The request finishes naturally and no longer updates the destroyed view;
failed loads retain the initial without blocking UI construction.

The minimize/restore launcher uses parent-relative offsets and a fixed anchor,
preserving the pointer's grab offset after its 6px drag threshold. Only the
initiating mouse/touch controls a gesture. Dragged, cancelled and ignored inputs
cannot activate the button; focus loss, destruction and rebuild release gesture,
service and layout listeners. Placement is saved on drag release, clamped within
the usable viewport, and restored after temporary keyboard or viewport changes.

The Code workspace is owned by `runtime/code_store` and composed in
`ui/panels/code`. Editor, Files, Explorer, Remotes, Output, History, Library and Game changes
are destinations within Code. Layout follows the available panel rectangle. Native
TextBox editing owns source input, selection and IME; escaped line-state syntax
highlighting, a visible caret, virtual labels and an independent gutter remain
available during editing. Source
remains raw and unwrapped. Enter inserts a newline; Run is explicit.

Documents have stable IDs, monotonic revisions and distinct open-view state. They
are loaded once and shared immediately with tools before delayed disk saves.
Closing a view retains its document. Two verified snapshots in reserved `code/`
store documents, versions, proposals, action snapshots and small preferences.
Legacy files are retained; damaged snapshots are copied to verified recovery files
before replacement. Unreadable or future-format data prevents overwriting. Failed
saves retain live drafts and report status. Build replacement preflight protects
pending Code work. Initial limits are 24 documents, 10 open views, 256,000 UTF-8
bytes per editable source, 12 versions per document within 4 MiB of source history,
24 actions and three proposals per document. The serialized envelope is capped at
12 MiB; an oversized envelope preserves live source and reports a save failure.
Larger inspected source, up to 2 MiB, uses a bounded snapshot reader; opening it
does not create temporary files. Explicit exports retain verified file behavior.

`runtime/script_sources` is the shared source/decompile service. Results carry
instance identity/path, runtime epoch, method/origin, status, byte count, capture
time, content hash, read-only state and diagnostics. Empty source is successful;
unavailable objects, unsupported classes, missing/failed decompilers, expired or
stale requests, invalid text and oversized source have distinct structured errors.
Per-instance capability reads do not decompile. Only explicit requests spawn
decompile workers (maximum four, 15-second waiter deadline), deduplicated by target,
method and generation. Late, cancelled and old-runtime results are discarded.
Completed snapshots retain at most eight items/8 MiB with a five-minute TTL; a
visible source view pins its snapshot and hiding/destroying the view releases it.
Host-readable and decompiled documents remain read-only across persistence and
cannot run, accept proposals or become actions until extracted into a separate
editable document. No inspected source is a live binding or automatic write-back.

Shared UTF-8 utilities use one-based byte offsets, exclusive range ends and code
point status columns, not UTF-16 or grapheme-cluster columns. Search and slicing
preserve code-point boundaries. Case folding is ASCII; whole-word classification
treats letters/digits/underscore and non-ASCII bytes as word constituents, without
Unicode linguistic segmentation. Combining characters are not grapheme-aware. Shifted
unchanged lines reuse syntax spans and measurements; multiline lexical state
invalidates dependent lines. TextBox updates still receive the bounded full string.
Drawing pools at most 160 rows, measures long lines in 2 KiB chunks and clips
horizontal syntax windows. Search offers counts/current match, overlays, case and
whole-word options, with a 10,000-match retention limit. Full-snapshot large-source
search can find matches across 6,000-byte display pages.

Storage exposes Saving, Saved, Retry required, Conflict and expired-source states.
An owned partial write can be retried; external modifications are not overwritten.
Typing publishes revision metadata without copying whole documents into events.

Source history is distinct from native TextBox Undo and Game changes. Restore and
proposal application guard source revisions. Actions retain immutable executable
snapshots; updates guard both action and source revisions. Up to 12 named
string/number/boolean/choice inputs are passed as data in `local inputs = ...`.
`tools/code_runner` calls the existing managed execution engine with one manual
workspace run at a time; agent concurrency is unchanged. Retained output identifies
the run/document/revision. `tools/execution.runOperation` manages native calls
without a compiler and reports still-outstanding dispatched calls after timeout or
Stop, never retrying them or claiming to roll back server effects.

`instance_refs`, `instance_fields`, `instance_schema`, `instance_scan`,
`instance_edits` and `changes` serve Explorer and the instance tools. Epoch-scoped
weak identities survive rename/reparent, with bounded pins and stale detection.
Paths reject duplicate-name ambiguity. Supported properties come from a bundled
curated catalog; actual protected reads/writes remain authoritative. Typed edits
preflight expected values, read back engine values, record observed changes and
conditionally recover partial failures. Undo checks every current recorded value
before writing. Tags and hierarchy operations are outside initial Undo coverage.
Edits report local observations, without a server replication guarantee.

Explorer tracks up to 64 branches, searches cooperatively within 20,000 nodes and
returns bounded snapshot cursors. Child enumeration caps at 20,000 children per
branch; UI pages cap at 4,000 rows, and reveal caps at 64 ancestor levels. Counts
separate returned, omitted, filtered and unreadable results and mark unknown totals.
At most eight search snapshots remain; cancelled queries cannot publish shared
state. Runtime services own page merging and query IDs/generations. UI rows are
pooled. Selection is capped at 20
objects and field batches at 100 operations. Drafts survive live updates and view
rebuilds. Create/duplicate/move/detach/delete use exact targets, expected parents and
normalized selections, with the Inspector's epoch, revision, IDs and primary target.
Clicked, focused, primary and selected identities are distinct; selection also has
an anchor and mode. Stale or ambiguous hierarchy actions fail before writing.
Source is a provenance-labelled snapshot, never a live
write-through editor. Nil roots, bookmarks and world picking are explicit. Metadata
export is verified and bounded; no full-map or unverified saveinstance adapter exists.

`runtime/values` supplies packed graphs with exact nil positions, typed Roblox
values, binary encoding and bounded cycle/alias inspection. Unsupported, incomplete,
opaque or cyclic/sparse graphs remain inspectable but cannot replay. `remote_capture`,
`remote_store` and `remote_hooks` own explicit capture sessions independently of GUI.
Imports/schema/state reads install no hooks and send no traffic. Outgoing hooks use
reusable neutral forwarding cells and owned detached routing probes; intercepted
Invoke outcomes have separate unverified coverage. Incoming capture uses events
only, never replaces function callbacks. `hooked_unknown` is the default outgoing
attribution unless verified. Probes do not invoke the predecessor; host network
behavior is not guaranteed. Stop reports whether an inert forwarding wrapper remains.

Capture holds at most 1,000 records within 4 MiB, 128 pending outcomes, 2,048 incoming
subscriptions, 10 pins within an additional 1 MiB, and 32 KiB per typed graph
(16 KiB per string, 256 slots/table nodes, depth 12, 1,024 values). Summaries report
omissions/eviction gaps; details/bytes paginate. View filters, admission filters and
exact-target blocking rules are separate. Pause stops recording; Stop also disarms
rules. Native and tool Start default to 30 seconds; persistence is explicit. The UI
requires a selected remote by default; all-game and subtree capture are explicit.
One target resolver validates the displayed Explorer selection and its primary.
Permission/group/session revocation removes
agent-owned behavior. Capture survives navigation/minimize with a launcher indicator;
unload/reset disarms it. Visible capture/property refresh is coalesced to 10 Hz.

Replay prepares a five-minute immutable plan with target, packed arguments, source
revision, rule revision and digest, then dispatches at most once. Generated bound
source uses expiring runtime bindings; portable snippets resolve explicit paths and
reject ambiguity. Copy/export of portable scripts requires a current source-review
digest. Incoming records expose diagnostics, caller inspection/source and metadata
export; only outgoing records expose replay and editable replay arguments. Caller
identity is captured in hooks, but resolution and source/decompile happen afterward.
Source provenance and bounded name/path text matches accompany exported captures;
these matches suggest call sites without proving them. Opening/importing source
never runs it. Late Invoke completion recalculates both ring and pin byte budgets.
Export freezes records and the maximum sequence before paging, so concurrent
arrivals and completions cannot change the exported snapshot. Reconfiguration
failure explicitly reports that the prior session stopped. Explicit exports use
unique scoped destinations, verified parts and a completion manifest. Imported
captures remain offline until explicit current-target rebinding. Tool summaries and
structured data share a roughly 6,000-byte budget with retained detail pages for
larger operation results.

The Code workspace was introduced in version 1.7.0; these local improvements do not
change its release version. [NATIVE_CLIENT.md](docs/NATIVE_CLIENT.md) is the current
native feature and limitation reference. Native input, touch/gamepad,
executor forwarding/coexistence and performance need the client scenarios in
`docs/CODE_WORKSPACE_TESTING.md`. Historical files in `archive/` are references only.

## 8. Build and verification

For the native improvement plan, finish all edits first, then run
`node tools/test_native.js`. It runs bundle/catalog generation, read-only freshness,
native static checks, the main native suite, every focused native suite,
performance contracts and the official Luau compiler, sequentially and fail-fast.
After any fix, restart the entire sequence. Results and suite summaries are in
`refer/native-verification/results.json`. See the native testing guide for setup
and the final diff/scope/generated-output review. This is behavioral contract
coverage and syntax validation, not strict Roblox type analysis or host validation.

```
luajit tools/bundle.lua --native # src/ -> dist/uai.lua and module manifest
luajit tools/bundle.lua --native --check # read-only deterministic freshness
luajit test/check.lua --native # lint, parse and link native modules
luajit test/code_workspace.lua # shared source/history/actions and UI fixtures
luajit test/native_workspace.lua # identities, typed edits, capture/replay
luajit test/run.lua --native # load dist/uai.lua against the mock client, native scenarios
luajit test/iy_control.lua   # IY selectors, native configuration and plugin contracts
luajit test/tool_workflows.lua # batch tools, pagination, scopes, cancellation
luajit test/attachments.lua    # exact saved inputs, compact payloads, upload recovery
luajit test/gravity.lua        # live adapter and plugin registration contracts
luajit test/execution_tools.lua # managed execution and released callback cancellation
node --test bridge/test-runtime.js
node bridge/test-browser-workflows.js # requires Playwright
node tools/build_site.js      # actual tool catalog and root/docs site copies
node tools/build_site.js --check
python test/site_static.py    # structural checks; no browser or image loading
```

`dist/uai.lua` is what a user runs:

```lua
loadstring(game:HttpGet("<url>/dist/uai.lua"))()
```
