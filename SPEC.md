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
* Secrets are redacted in the request log; only the last four characters of a
  key are ever displayed, and the Providers panel never renders the key itself.
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

**Models are never guessed.** Presets carry no model list. `provider/models`
resolves a provider's models from exactly two sources — ids the user added by
hand (which rank first, and persist on the record) and whatever `GET /v1/models`
reported (cached for ten minutes, not persisted). Nothing is filtered out of the
endpoint's answer, because deciding which of its ids are chat models would be a
guess. An endpoint with no `/models` route is a normal case: the Providers editor
takes a typed id, and saving requires one.

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
error, not a crash.

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
| `tool:progress` | `{ text }` |
| `tool:result` / `tool:error` | the dispatch result: `{ id, name, ok, text, ms, risk, group, args, error, full, truncated, data }` |
| `permission:ask` | `{ id, name, group, risk, description, args, resolve }` |
| `usage` | `{ session, turn }` — the two counter tables from `agent/usage` |
| `compact` | `{ summary, before, after }` |
| `subagent:start` | `{ id, call, label, task, preset, turns, budget, depth }` |
| `subagent:status` / `subagent:text` | `{ id, call, label, text, bad? }` |
| `subagent:tool` / `subagent:tool:done` | `{ id, callId, name, risk, arguments, index }` / `{ …, ok, ms, summary }` |
| `subagent:done` | `{ id, ms, ok, aborted, messages, turns, text }` |
| `cleared` | `{}` |
| `error` | `{ message, fatal }` |
| `abort` | `{}` |

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
history capped at 24), the `changed` signal, `list`, `running`, `get`, `stop(id)`,
`stopAll` and `clearHistory`. A record carries `id, label, task, preset, depth,
parentId, parentTitle, startedAt, status, calls, finishedCalls, tools, currentTool,
statusText, ms, messages, report` and the child `session` that `stop` sets
`abortFlag` on. `status` is one of `queued`, `running`, `done`, `stopped`, `failed`.
A stop is noticed between steps, not on the instant -- Luau cannot kill a thread.

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
| `sessions/<id>.json` | `agent/session` | one conversation: the model's context, the transcript, its title, place and timestamps; capped at 20 |
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

Breakpoints: `xs < 520`, `sm < 900`, `md < 1280`, `lg < 1700`, `xl`. Layout modes:
`sheet` (xs), `panel` (sm, and any portrait orientation), `window` (md+), plus `tv`
when `GuiService:IsTenFootInterface()`. Minimum touch target is 44px on a touch
device, 28px with a pointer, 48px on a console. Navigation is reachable in every
mode: the sidebar in `window`, the app menu in the header everywhere else.

## 8. Build and verification

```
luajit tools/bundle.lua      # src/ -> dist/uai.lua, the single loadable file
luajit test/check.lua        # lint, parse and link every module
luajit test/run.lua          # load dist/uai.lua against the mock client, run scenarios
```

`dist/uai.lua` is what a user runs:

```lua
loadstring(game:HttpGet("<url>/dist/uai.lua"))()
```
