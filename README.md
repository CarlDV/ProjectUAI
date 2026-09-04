# Project UAI

A universal AI agent that runs inside a Roblox client. It works in any game,
against any OpenAI-compatible inference endpoint, and it identifies itself on the
wire as the Claude Code CLI.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/CarlDV/ProjectUAI/main/dist/uai.lua"))()
```

Nothing about a specific game, gateway or host script is assumed. Under an
executor it uses the executor's HTTP function; in a plain client it falls back to
`HttpService` and says which capabilities it lost. Embedded in a host script it
takes a context table and adds that script's own instructions and hooks.

## What it is

**A real agent loop.** Streaming, parallel tool calls, retry with backoff that
honours `Retry-After`, provider fallback, automatic context compaction with a
summary, permission gating, hooks, a task list, persistent memory, subagents,
token and cost accounting, abort, and a request log. Every stage emits an event,
and the interface is a subscriber -- the loop never touches a GUI.

**Any provider.** A provider is a base URL, an auth style, a key and a model.
Presets exist for the common hosts, and "Custom endpoint" takes anything that
speaks `/v1/chat/completions` -- a relay, a self-hosted vLLM, Ollama on
localhost. Model lists are never guessed: they come from `GET /v1/models` or from
you typing one in.

**The Claude Code identity.** Every inference request carries
`User-Agent: claude-cli/<version> (external, cli)`, `x-app: cli` and the
`X-Stainless-*` client-metadata set, applied inside the transport so no call site
can skip it. `HttpService:RequestAsync` refuses to send a custom `User-Agent`, so
on a host with no executor HTTP function the client says the identity did not
reach the wire rather than pretending it did.

**About sixty tools**, all of which work in any game: the instance tree,
properties with type-aware conversion, sandboxed Luau execution, files, HTTP, web
search and page reading, players, your character, raycasts and lighting and the
camera, remotes (discover, fire, watch), on-screen interfaces, diagnostics, place
and account metadata, plus the agent's own task list, memory and subagent
dispatch.

**An interface built from tokens.** No use site writes a colour or a number. The
layout follows the live viewport rather than a boot-time guess: a bottom sheet on
a phone, a full-height dock on a tablet or in portrait, a floating resizable
window on a desktop, a large centred panel on a console. It re-lays-out on
rotation and resize, lifts above the on-screen keyboard, respects
`ReducedMotionEnabled`, and uses 44px hit targets on touch and 28px with a
pointer.

## Layout

```
init.lua              bootstrap: builds env, mounts the app
src/runtime/          util, signal, clock, caps, fsx, log, config
src/net/              ua, http, sse, ws
src/provider/         catalog, registry, openai, models
src/agent/            prompt, context, schema, registry, permissions,
                      hooks, state, usage, loop, session, subagent
src/tools/            13 groups behind one registry
src/ui/               theme, responsive, icons, primitives, controls,
                      overlay, markdown, window, app, chat/*, panels/*
dist/uai.lua          the built single file
```

`SPEC.md` is the contract every module is written against: the loader, the `env`
table, the provider record, the tool handler signature, the event stream, and the
authoring rules.

## Building and testing

Everything runs offline under LuaJIT. There is no Luau interpreter outside
Roblox, so the sources are written in a dialect LuaJIT can also parse -- no type
annotations, no backtick interpolation, no `continue` -- and `test/check.lua`
fails the build on a violation.

```bash
luajit test/check.lua      # lint, parse and link all 59 modules
luajit tools/bundle.lua    # src/ + init.lua -> dist/uai.lua
luajit test/run.lua        # 29 scenarios against the built bundle
```

`test/run.lua` loads `dist/uai.lua` -- the actual artifact -- into a mocked
client: a virtual clock so nothing sleeps, an in-memory filesystem, a programmable
HTTP layer that records every request, and an instance mock that resolves absolute
geometry, type-checks property assignments and reports any unknown property or
enum. The scenarios cover boot, capability degradation, the identity headers on
the wire, model discovery, the tool loop, parallel calls, SSE assembly, retry,
provider fallover, permissions, the repeat breaker, abort, context trimming,
payload shape, argument repair, path traversal, viewport changes, theme changes,
markdown, subagents, persistence, error surfaces, window drag and resize, and
overlay interaction.

```bash
luajit test/run.lua identity      # run one scenario
luajit test/mock/selftest.lua     # check the mocks themselves
```

## First run

The interface opens with a floating orb. There is nothing configured, so the chat
panel says so and points at Providers. Add an endpoint, fetch its models or type
one, and send a message.

Permissions default to **Ask first**: reads run freely, anything that changes the
game waits for you, and the prompt shows the arguments -- which for `run_luau`
means the code. Read only, Auto and Allow everything are the other three modes.

## Embedding

```lua
local uai = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/CarlDV/ProjectUAI/main/dist/uai.lua"))({
    prompt = "You also control the Foo system. Use foo_* tools first.",
    hooks = {
        preTool = function(payload)
            if payload.tool.name == "instance_destroy" then return false end
        end,
    },
})

uai.ask("what is in this place")
uai.show("logs")
```

The returned handle exposes `env`, `app`, `sessions`, `config`, `providers`,
`tools`, `caps` and `log`, so a host script can drive or inspect any part of it.
Running the loader twice toggles the existing instance instead of stacking a
second one.

## Notes on the constraints

No Roblox HTTP API can read a response body incrementally, so `stream: true` does
not deliver tokens as they arrive -- the whole SSE body lands at once and is
replayed through the parser. It is still requested, because the streamed shape is
where providers put reasoning text and per-request usage. `net/ws.lua` does real
token streaming for a gateway that speaks a small WebSocket envelope, when the
executor exposes `WebSocket.connect`.

A Luau loop that never yields cannot be interrupted by anything, including this
client's own timeouts. `run_luau` rewrites the two unconditional freeze forms and
reports honestly when a script outlives its deadline: the thread was abandoned,
not stopped.
