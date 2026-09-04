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
  key are ever stored.

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
fans out to subscribers:

| kind | payload |
| --- | --- |
| `status` | `{ text }` |
| `turn:start` / `turn:end` | `{ index }` / `{ index, reason }` |
| `request:start` | `{ provider, model, attempt, messages }` |
| `request:retry` | `{ provider, attempt, status, wait, reason }` |
| `request:done` | `{ provider, model, ms, status }` |
| `provider:switch` | `{ from, to, reason }` |
| `assistant:text` | `{ text, delta }` |
| `assistant:reasoning` | `{ text, delta }` |
| `tool:call` | `{ id, name, args, risk }` |
| `tool:progress` | `{ id, text }` |
| `tool:result` | `{ id, name, text, ms, truncated }` |
| `tool:error` | `{ id, name, message }` |
| `permission:ask` | `{ id, name, args, risk, resolve }` |
| `usage` | `{ prompt, completion, total, cost }` |
| `compact` | `{ removed, summary }` |
| `todo` | `{ items }` |
| `error` | `{ message, fatal }` |
| `abort` | `{}` |

## 7. Design tokens

No use site writes a raw colour or number. `ui/theme` exposes `theme.color.*`,
`theme.text.*` (role -> size/font/lineHeight), `theme.space.*`, `theme.radius.*`,
`theme.motion.*`, `theme.stroke.*`, `theme.z.*`. `ui/responsive` resolves the
active breakpoint from the live viewport and republishes a scaled token set, so a
window that opens on a phone and is then rotated re-lays-out rather than keeping
whatever was true at boot.

Breakpoints: `xs < 480`, `sm < 768`, `md < 1100`, `lg < 1600`, `xl`. Layout modes:
`sheet` (xs), `panel` (sm), `window` (md+), plus `tv` when
`GuiService:IsTenFootInterface()`. Minimum touch target is 44px on a touch
device, 28px with a pointer.

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
