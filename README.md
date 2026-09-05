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
summary, permission gating, hooks, a task list, persistent memory, subagents that
run several at a time, token and cost accounting, abort, and a request log. Every
stage emits an event, and the interface is a subscriber -- the loop never touches a
GUI.

A turn stops after twenty-four tool rounds by default, which is there to catch a
runaway rather than to end the work; **Unlimited tool calls** in Settings removes
that ceiling and the fifteen-minute turn deadline with it, leaving the repeat
breaker, each tool's own timeout and Stop as what bounds a turn. Subagents keep
their own step and time budgets either way.

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

**An interface built from tokens.** No use site writes a colour or a number. One
warm neutral ramp and one accent, surfaces separated by two steps of lightness and
a hairline rather than by shadows, a cream fill for the single loud action per view,
and the accent kept for meaning -- inline code, a running turn, a risk level. Type
comes from `FontFace` where the client has it, so a family yields a real
regular/medium/semibold axis instead of whichever weights the legacy `Enum.Font`
happened to pair it with; the families on offer are probed against the engine rather
than declared, so the list is shorter on an older client instead of containing dead
entries. A reply is the page rather than a bubble on it: the agent's prose sits flat
on the canvas, tool rows and reasoning are lines of text rather than cards, reasoning
sits behind a rule as an aside, and only the user's own turn takes a fill -- marked
with an accent rule so it cannot be mistaken for the composer below it. The contrast
of every pair the interface puts together is computed in the test suite, so a retune
cannot quietly make something unreadable.

**Every listing the model produced, in the transcript.** A tool call that carries
code -- the Luau it is about to execute, the body it is about to write to a file, the
property map it is about to apply -- draws it under the row as numbered, horizontally
scrolled, copyable monospace, outside the fold and on by default. Long blocks fold
with a control that opens them rather than a sentence saying how much was hidden. The
remaining arguments and the result sit behind the row's own caret, and a failure opens
its own. Subagents forward their calls whole, so work delegated to a child is as
readable as work done in the main conversation.

A sidebar holds the conversations, grouped by the place each happened in, with
search across their transcripts and two arrows that walk where you have been. It
collapses from the header and comes back the same way, and a conversation reopened
after a restart shows what was said in it rather than a greeting -- the transcript is
written to disk alongside the model's own context, which is the half that used to
travel alone. An
empty conversation opens on the activity card: conversations, messages, tokens,
active days, streaks, the busiest hour, the model that did the most work, and six
months of daily activity as a grid. Every figure on it is counted from what this
client observed and kept -- there is no sample data anywhere in the interface, and
a number with nothing behind it is rendered as a zero and says why.

**Providers are a list and a detail pane**, not a card grid and a modal form. The
detail names the endpoint a request will actually go to, the model-list route, the
wire protocol, whether a socket is configured (and therefore whether a long reply can
arrive at all), the health counters, the last observed latency, how long a benched
provider has left, and the extra headers, body fields and query parameters the record
sends. The API key is never rendered: it is set through a prompt and shown as its last
four characters.

The layout follows the live viewport rather than a boot-time guess: a bottom sheet
on a phone, a full-height dock on a tablet or in portrait, a floating resizable
window on a desktop, a large centred panel on a console. It re-lays-out on rotation
and resize, lifts above the on-screen keyboard, respects `ReducedMotionEnabled`, and
uses 44px hit targets on touch and 28px with a pointer.

## Layout

```
init.lua              bootstrap: builds env, mounts the app
src/runtime/          util, signal, clock, caps, place, fsx, log, config, dispose
src/net/              ua, http, sse, ws, bridge
src/provider/         catalog, registry, openai, anthropic, chat, models, traits
src/agent/            prompt, context, schema, registry, permissions,
                      hooks, state, usage, stats, loop, session, subagent
src/tools/            13 groups behind one registry
src/ui/               theme, responsive, icons, primitives, controls,
                      overlay, markdown, window, sidebar, app,
                      settingsrows, settingspanes, chat/*, panels/*
bridge/               the optional web chat: node server plus its page
dist/uai.lua          the built single file
```

`SPEC.md` is the contract every module is written against: the loader, the `env`
table, the provider record, the tool handler signature, the event stream, what is
counted and where it is persisted, and the authoring rules.

## Building and testing

Everything runs offline under LuaJIT. There is no Luau interpreter outside
Roblox, so the sources are written in a dialect LuaJIT can also parse -- no type
annotations, no backtick interpolation, no `continue` -- and `test/check.lua`
fails the build on a violation.

```bash
luajit test/check.lua      # lint, parse and link all 73 modules
luajit tools/bundle.lua    # src/ + init.lua -> dist/uai.lua
luajit test/run.lua        # 71 scenarios against the built bundle
```

`test/run.lua` loads `dist/uai.lua` -- the actual artifact -- into a mocked
client: a virtual clock so nothing sleeps, an in-memory filesystem, a programmable
HTTP layer that records every request, and an instance mock that resolves absolute
geometry, type-checks property assignments and reports any unknown property or
enum. The scenarios cover boot, capability degradation, the identity headers on
the wire, model discovery, the tool loop, parallel calls, SSE assembly, retry,
provider fallover, permissions, the repeat breaker, abort, context trimming,
payload shape, argument repair, path traversal, viewport changes, theme changes,
markdown, subagents and the parallel dispatch of several at once, the unlimited
step budget, persistence, error surfaces, window drag and resize, overlay
interaction, the layout invariants every surface has to hold, and the contrast of
every colour pair the interface puts on screen. They also cover the two failure
modes that are invisible from inside a single turn: that the sidebar's collapse
control actually collapses it and offers a way back, and that no string leaves this
client without being valid UTF-8 -- a scraped snippet with one Latin-1 byte in it
used to poison the message history and kill every following request with a
positionless "Can't convert to JSON".

They also pin the interface to real state, which is the part that is easy to fake:
that the activity card counts only what was recorded and survives a restart, that a
history from before the counters existed is recovered from the transcripts rather
than invented, that the conversation list is the threads the client has, that the
permission chip reads the mode actually in force, that an attached file travels with
the message, that a tool family switched off leaves the wire, that every settings
pane builds, and that search finds a conversation by something said inside it.

```bash
luajit test/run.lua identity      # run one scenario
luajit test/mock/selftest.lua     # check the mocks themselves
```

## First run

The interface opens with a floating orb. There is nothing configured, so the
conversation says so and points at the inference configuration. Add an endpoint,
fetch its models or type one, and send a message.

Permissions default to **Ask first**: reads run freely, anything that changes the
game waits for you, and the prompt shows the arguments -- which for `run_luau`
means the code. Read only, Auto and Allow everything are the other three modes, and
the chip under the composer always names the one in force.

Nothing on disk until then, and only three things after: `config.json`,
`sessions/<id>.json` per conversation, and `stats.json` for the activity counters.
A conversation can be marked isolated from the composer, which keeps it out of the
first two entirely.

## Chatting from a browser

A Roblox client cannot accept a connection, so it cannot be talked to directly. A
small local process sits in between and both sides dial out to it: the browser
holds an SSE stream, the client long-polls for whatever you typed.

```bash
node bridge/server.js
```

It prints a link with a one-time token in the fragment -- open that, then paste the
same token into **Settings -> Web bridge** and turn it on. The browser joins
whichever conversation is already open in-game rather than starting its own, so a
turn begun in one place continues in the other, and permission prompts can be
answered from either side.

Loopback only, token-gated, and Origin-checked. Whoever reaches it drives an agent
that can run code on your machine, so it stays off until you turn it on and the
token is regenerated on every start.

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

## Unloading

The interface can be removed and everything it started stopped:

```lua
getgenv().UAI.destroy()
```

or from Settings, at the bottom: **Unload UAI**. Destroying the ScreenGui on its
own is not enough -- timers keep ticking, input handlers stay bound to
`UserInputService`, and a later config write would rebuild a window that is no
longer on screen -- so anything outliving the instance tree registers a cleanup in
`runtime/dispose` and the unload drains it. A turn in flight is aborted first and
settings are flushed before the tree goes.

## License

MIT. Do whatever you like with it, including commercially and in closed source --
the only condition is that the copyright notice and permission notice travel with
any substantial portion of it. See [LICENSE](LICENSE).
