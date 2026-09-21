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

Running the same bundle again toggles the existing interface. A changed bundle
reloads an idle client after saving its settings and conversations. If work, an
unsent draft, or an isolated conversation would be lost, the current instance stays
open with a notice; finish that work before running the updated loader again.

In **Settings → Import & export → Full configuration**, use **Copy config · includes
API keys** to transfer all saved configuration, including providers, key pools,
custom headers, permissions, preferences, and saved memory. On the other device,
choose **Paste configuration to import**, paste the JSON, select **Review**, then
**Apply**. This private export contains credentials. Conversations, activity history,
workspace files, and skill files are separate from configuration.

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
breaker, each tool's own timeout and Stop as what bounds a turn. A subagent keeps its
own step and time budget under that switch -- it is the one session nobody is
watching -- and **Unlimited subagents** is the separate switch that lifts a child's
too, so a delegated job runs until it answers instead of coming back with "I reached
this session's step limit before finishing".

**Any provider.** A provider is a base URL, an auth style, a key and a model.
Presets exist for the common hosts, and "Custom endpoint" takes anything that
speaks `/v1/chat/completions` -- a relay, a self-hosted vLLM, Ollama on
localhost. Model lists are never guessed: they come from `GET /v1/models` or from
you typing one in.

**The Claude Code identity.** Providers that enable this compatibility identity carry
`User-Agent: claude-cli/<version> (external, cli)`, `x-app: cli` and the
`X-Stainless-*` client-metadata set, applied inside the transport so no call site
can omit it accidentally. OpenCode Zen retains its OpenCode compatibility headers. Its free-tier access is
provider-controlled, so compatibility headers do not guarantee availability.
`HttpService:RequestAsync` refuses to send a custom `User-Agent`, so
on a host with no executor HTTP function the client says the identity did not
reach the wire rather than pretending it did.

**Native tools for any game**: the instance tree,
properties with type-aware conversion, bounded Luau execution, files, HTTP, web
search and page reading, players, your character, raycasts and lighting and the
camera, remotes (discover, fire, watch), on-screen interfaces, diagnostics, place
and account metadata, plus the agent's own task list, memory and subagent
dispatch.

**Batch inspection and file workflows.** Prefer a combined query or batch when
the work is independent; this reduces model round trips and unnecessary local
scanning without changing the inference provider's speed.

| Tool | Use |
| --- | --- |
| `instance_query` | Filter by name, class, and tag while reading selected properties and attributes. Pages stop early and include a traversal offset. |
| `instance_get_many` | Inspect up to 20 known paths with individual errors and a continuation index. |
| `file_search` | Find literal text across workspace files, with filename globs, case selection, line numbers, byte offsets, and a cursor. |
| `file_read_many` | Read up to 12 files or saved pastes with a shared output budget, individual failures, and per-file continuation offsets. |
| `file_edit_many` | Apply up to 20 ordered exact edits to one file after all edits validate, using one write. |

Instance projections accept up to 12 property names and 12 attribute names.
Copy returned instance paths exactly: `Workspace["Map.v2"]["Door[1]"]` refers to
names that contain punctuation. Query pages inspect at most 20,000 nodes; narrow
the root if a scan is incomplete. Traversal offsets describe the live tree, so
restart after it changes.

File searches stay in `UAI/files/`, excluding client configuration and
conversations. They skip binary files and files over 2 MB, bound inventories to
128 directories, 1,000 files, and 6,000 entries, and process at most 8 MB and 50,000
new lines per page. The read budget counts skipped data too and is checked between
whole-file reads; the host must read a file before its size is known.
Follow the returned cursor with the same query and restart
after editing sources. Batch reads support files up to 2 MB and reuse repeated
slices within that call. Edits preflight against the original file, refuse stale
contents, avoid no-op writes, and limit the original and resulting file to 2 MB.
The existing Files and Instance tree permissions and capability checks apply.

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
sits behind a rule as an aside, and sent prompts group their speaker and text inside a quiet bordered surface.
The compact composer stays pinned to the bottom edge, with context details behind
its overflow menu. The model stays inline when space permits; model, permission,
and usage controls are always available from the same menu. The contrast
of every pair the interface puts together is computed in the test suite, so a retune
cannot quietly make something unreadable.

**Markdown tables and compact thinking.** Replies support aligned pipe tables with
formatted cells and horizontal scrolling on narrow screens. Long tables and thinking
traces have bounded scroll areas without dropping their content. Thinking starts
collapsed; consecutive trace updates share a disclosure until a tool separates them.
The model picker keeps search and selection stable, and its provider selector and
the composer's model chip size to their actual labels.

**Mobile layout.** A compact header, composer and prompt list leave more room for
chat while keeping 44px touch targets. Drag the title to move the window anywhere
inside the device's safe area, including in portrait. The header's resize grip
adjusts its size; the expand button fills the available screen and restores your
previous placement. Portrait and landscape layouts remember their positions
separately, and the keyboard temporarily lifts the panel without overwriting them.

**Managed in-game chat loops.** Ask for a quiz, rotating announcements, or keyword
replies. `quiz_bot`, `auto_chat`, and `auto_reply` return a background job immediately;
`chat_loop_status` reports progress and quiz scores, and `chat_loop_stop` stops jobs.
Active jobs also have a Stop all control in chat. Loops have configurable intervals,
counts, and durations, and stop when their conversation is cleared or removed, chat
is disabled, or the client unloads.

**Infinite Yield control and plugin authoring.** `iy_control` inspects and changes
IY's native event bindings, keybinds, aliases, waypoints, command prefix, and supported settings. It
supports `OnExecute`, `OnSpawn`, `OnDied`, `OnDamage`, `OnKilled`, `OnJoin`,
`OnLeave`, and `OnChatted`, including player/message/health filters, delays, and
`$1`/`$2` command arguments. Changes refresh IY's editor and request its normal
save; results say when only live session state is available. Inspect first for
current binding indexes. `stop_loops` sends IY's `breakloops` command, which stops
repeat prefixes; event bindings and individual commands' own loops are managed
separately. The adapter follows the upstream
[event editor and plugin loader](https://github.com/EdgeIY/infiniteyield/blob/master/source),
reviewed September 20, 2026.

`iy_cmds` includes argument signatures and short descriptions when the running IY
exposes them. `iy_players` resolves selectors such as `others`, `rad50`, and
`all-me` to live names before a targeting command. It uses IY's own selector
engine, including comma-separated lists and `@name` username-only prefix matching.
Its text is bounded by `limit`; structured results retain the complete name list.

Use `alias_add`, `alias_remove`, or `alias_clear` to manage aliases. An alias
targets a command name, including an existing command alias; arguments are not
stored in it. `waypoint_add` accepts `{x,y,z}` coordinates or uses your character's
current root position, flooring each coordinate to match IY. `waypoint_remove`
and `waypoint_clear` affect the current place; `waypoint_clear` with
`all_places=true` also clears saved waypoints in other places. Inspect
`section="aliases"` or `section="waypoints"` and follow `nextOffset` for more.
Edits preserve the live table references used by IY's GUI and request its save.

`configure` also supports `gui_scale` (0.4–2) and `logs_webhook` (an HTTP(S) URL,
or an empty string to disable). These dispatch IY's own commands asynchronously;
inspect settings to confirm the resulting values. Those commands save through
IY, so they reject `persist=false`; other native edits support session-only changes.

`iy_plugin_read` without a filename returns a multi-command template. Pass a
filename to read an existing plugin, then use `iy_plugin_write` to create or
update it. Source can declare globals or shared locals above `local Plugin`,
and returns the normal IY table with `PluginName`, `PluginDescription`, and
`Commands`. Every command has `ListName`, `Description`, `Aliases`, and
`Function(args, speaker)`. The writer checks syntax before saving, executes setup
once when loading, validates the returned table before replacing commands, and
reports their actual registered names, including IY's collision suffixes.
`load=false` saves without executing; replacing a file requires `overwrite=true`.
Plugin source and commands appear in the tool transcript. Plugin-owned connections
and loops should have their own cleanup command so reloads do not duplicate them.

For example, `iy_control` can bind `speed 40` to your next spawn:

```json
{"action":"event_add","event":"OnSpawn","command":"speed 40","conditions":{"player":"me"},"delay":0.5}
```

Resolve nearby players with `iy_players`:

```json
{"selector":"rad50-me","limit":20}
```

Create an alias or a waypoint with `iy_control`:

```json
{"action":"alias_add","alias":"quick","command":"speed"}
```

```json
{"action":"waypoint_add","name":"Home","position":{"x":100,"y":20,"z":-50}}
```

**Task and notification layout.** Task markers share their text's line box at each
font scale, long plans scroll within a bounded area, and disclosure choices stay
with their conversation. Skipped steps are reported separately from completion.
Notifications have a clear outcome, conversation title, and an **Open chat**
action. Opening a conversation acknowledges its own notifications; other unread
conversations keep their badge. Long notifications scroll, hover/focus pauses
expiry, and the stack fits the available screen and keyboard space.

**Independent in-game chatbot.** `chat_bot` listens to new player messages and
answers with the selected AI provider/model using its own short conversation memory.
Set `instructions` for its personality, `prefix` (default `[AGENT]`), and optionally
`user_ids` to choose players. It returns immediately and appears in the chat-loop
indicator; `chat_loop_status` reports its progress and `chat_loop_stop` stops it.
By default it runs for 600 seconds, sends at most 100 replies, and waits at least
5 seconds between sends. Rapid messages are batched into one response. Incoming
message IDs and short-window repeats are deduplicated, self/system/tagged-bot
messages are ignored, and repeated reply text is suppressed for the entire run.
Only one managed job owns a channel, and manual `chat_send` calls are blocked there
while the chatbot runs. A failed or ambiguous chat send stops the bot without retrying.

**Every listing the model produced, in the transcript.** A tool call that carries
code -- the Luau it is about to execute, the body it is about to write to a file, the
property map it is about to apply -- draws it under the row as numbered, horizontally
scrolled, copyable monospace, outside the fold and on by default. A call's listing
folds at a dozen lines rather than sixty, because a turn produces several of them and
the answer they were working towards has to stay on screen. Long blocks fold with a
control that opens them rather than a sentence saying how much was hidden. The
remaining arguments and the result sit behind the row's own caret, and a failure opens
its own. Subagents forward their calls whole, so work delegated to a child is as
readable as work done in the main conversation.

**A turn's machinery is one block, not a wall.** The calls, the thinking between them
and any retry notice go into a single activity block with tight lines inside it and a
paragraph of air around it -- so a turn that called eight tools reads as one thing
that happened rather than as eight events with the reply lost at the bottom. The
header counts the run and its duration, and a finished run of more than four folds
itself away behind that line; anything still outstanding keeps it open.

**Conversations run at the same time.** Switching conversation does not stop the one
you left: its loop is on its own thread, the sidebar spins on it while it works, the
header says how many are going, and the launcher's dot pulses with the window closed.
Each conversation keeps its own task list, and a permission prompt raised by one that
is not on screen still appears -- named with the conversation that is asking, rather
than timing out three minutes later and reporting to that model that you refused.

**Subagents are managed, not just watched.** The Subagents panel is the register: every
dispatch this session made, running ones first, with the task, which conversation asked,
what it is allowed to touch, the tools it has called, how long it has been going, and a
stop for each one that does not stop the turn that dispatched it. Finished dispatches
stay with their report. The four ceilings -- budget, how many run at once, steps per
subagent, and how deep delegation may go -- are on the same panel, and the last two had
no control anywhere before it.

**A dispatch is a conversation, not one question.** Every report carries the
subagent's id, and `agent_followup` sends that same child another message with
everything it found still in context: carry on where the step limit stopped you, now
check this too, quote that line exactly. The transcript shows the second turn as a
follow-up on the same subagent rather than as a new dispatch, and the newest few
finished dispatches keep their context so there is something to follow up on.

A sidebar holds the conversations, grouped by the place each happened in, with
search across their transcripts and two arrows that walk where you have been. It
collapses from the header and comes back the same way, and a conversation reopened
after a restart shows what was said in it rather than a greeting -- the transcript is
written to disk alongside the model's own context, which is the half that used to
travel alone. An
empty conversation opens with prompt starters and an expandable activity card: conversations, messages, tokens,
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
src/tools/            native tool groups behind one registry
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

The offline suite runs under LuaJIT. The sources use a dialect LuaJIT can also parse -- no type
annotations, no backtick interpolation, no `continue` -- and `test/check.lua`
fails the build on a violation.

```bash
luajit test/check.lua      # lint, parse and link all modules
luajit tools/bundle.lua    # src/ + init.lua -> dist/uai.lua
luajit test/run.lua        # full scenarios against the built bundle
luajit test/chat_regressions.lua
luajit test/config_transfer.lua
luajit test/build_reload.lua
luajit test/audit_regressions.lua
luajit test/execution_tools.lua
luajit test/tool_workflows.lua
luajit test/execution_ui.lua
luajit test/controls_loading.lua
luajit test/controls_interactions.lua
luajit test/markdown_regressions.lua
luajit test/markdown_tables.lua
luajit test/shared_ui_layout.lua
luajit test/mobile_ui.lua
luajit test/panel_layout_regressions.lua
luajit test/model_picker.lua
luajit test/chat_loops.lua
luajit test/chat_bot.lua
luajit test/iy_control.lua
luajit test/todo_notifications.lua
```

`test/run.lua` loads `dist/uai.lua` -- the actual artifact -- into a mocked
client: a virtual clock so nothing sleeps, an in-memory filesystem, a programmable
HTTP layer that records every request, and an instance mock that resolves absolute
geometry, type-checks property assignments and reports any unknown property or
enum. The scenarios cover boot, capability degradation, the identity headers on
the wire, model discovery, the tool loop, parallel calls, SSE assembly, retry,
provider fallover, permissions, the repeat breaker, abort, context trimming,
payload shape, argument repair, path traversal, viewport changes, theme changes,
markdown, subagents and the parallel dispatch of several at once, a subagent
resumed with a follow-up in the context it already had, the unlimited step budget
for a turn and the separate one for a child, persistence, error surfaces, window
drag and resize, overlay interaction, the layout invariants every surface has to
hold, and the contrast of every colour pair the interface puts on screen. They
also cover the two failure
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

Lune can also compile all source modules and the shipped bundle with the real
Luau compiler, then run a scenario file through the same offline harness:

```bash
lune run test/lune_runner.luau test/mobile_ui.lua
lune run test/lune_runner.luau test/shared_ui_layout.lua
```

These checks use mocked Roblox services. They verify code, geometry and
interactions, but do not render native Roblox text or GUI layouts.

## Public showcase website

The public site lives in root `index.html`, `style.css`, and `script.js`. The
`docs/` copies support GitHub Pages configured to publish from that directory.
Edit the root files, then regenerate the marked catalog and release regions:

```bash
luajit tools/bundle.lua
node tools/build_site.js
node tools/build_site.js --check
node --check script.js
python test/site_static.py
```

The site build uses Node and LuaJIT without npm dependencies. It reads the actual
bundled registry through the offline client harness and refuses stale bundles.
The check mode does not write files. Static checks verify HTML structure, local
links, accessibility references, copy targets, catalog coverage, and publishing
parity without opening a browser or loading media.

For manual browser review, check narrow and wide layouts, 200% zoom, keyboard
navigation and Escape, repeated copying and denied clipboard access, search with
no results, clearing filters, and video playback. The catalog and navigation
remain usable without JavaScript; only search and copy controls need it.

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

## Cowork: browser UI and web inference

A Roblox client cannot accept a connection, so it cannot be talked to directly. A
small local process sits in between and both sides dial out to it: the browser
holds an SSE stream, the client long-polls for whatever you typed.

```bash
node bridge/server.js
```

You can also use **Roblox → Cowork → Download bridge files**. It downloads the
entire GitHub `bridge/` folder at one pinned revision into **`UAI/bridge`** inside
your executor's workspace, preserving its subfolders. Open a terminal in that
workspace and run `node UAI/bridge/server.js`. Downloads report progress and
verify saved files; your executor must support HTTP, file I/O, and folder creation.

It prints a link with a one-time token in the fragment. Open it, then paste the
same token into **Roblox → Cowork → Token** and enable the bridge. The browser
uses the Roblox client's warm palette, sidebar, conversation list, compact
composer, prompt starters, and model picker. It follows the active conversation.

Select **Cowork → Web · real streaming** in the browser (or **Inference runtime →
Web** in Roblox) while work is idle. Node now owns provider HTTP connections and
streams OpenAI-compatible or Anthropic SSE responses to the browser as they arrive.
Roblox submits once, then retrieves the result with short authenticated requests;
its executor's 30–60 second request limit no longer bounds model generation.
The provider deadline defaults to 180 seconds and is configurable up to one day.
Provider/proxy disconnects and truncated streams are reported as failures.

The existing Roblox agent loop remains authoritative in both modes. Tools,
permission rules, hooks, context compaction, provider fallback/key rotation,
subagents, memory, skills, accounting, and background chatbots retain their existing
behavior. Roblox must stay connected and running to execute tools and advance a
turn; this is not a standalone Node reimplementation of the agent. Web mode also
routes subagent and chatbot inference through Node, without posting those private
streams into the main transcript.

Browser controls include provider creation/editing/testing, model discovery,
search and effort, conversation switching/renaming/deletion/isolation, attachments,
per-thread drafts, tool schemas and execution, tool-group and permission controls,
pending approvals and `ask_user` answers, subagent stops, chat-loop status/stops,
memory/skill tools, settings, logs, usage, and configuration/transcript export.
Full configuration exports contain API keys; ordinary state updates never include
provider credentials. The bridge holds request credentials only in memory.

Commands carry IDs and stay queued until acknowledged. The client remembers
handled IDs, and inference submissions reuse the same ID after a lost response.
Browser SSE reconnects use event cursors; final replies reconcile with streamed
previews instead of appearing twice. A lost relay job is terminal and is not
silently restarted. Refreshing the browser does not stop a turn; stopping the
bridge/client or a turn cancels its pending provider request. Results are retained
for five minutes, with ID tombstones preventing expired submissions from rerunning.

The game connection uses continuously renewed long-polls: a waiting poll returns
as soon as a command arrives. It does not hammer localhost with empty requests.
Run the bridge on the same computer as the Roblox executor; it binds loopback.
Node 18 or newer is required. There are no production npm dependencies.

```bash
node --test bridge/test-runtime.js
luajit test/web_runtime.lua
luajit test/bridge_install.lua
# Optional browser checks, with Playwright installed:
node bridge/test-browser.js
node bridge/test-browser-workflows.js
```

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

Some executors stop HTTP requests after roughly 30–60 seconds even when given a
longer timeout. To keep replies within that window, buffered HTTP uses
`agent.executorReplyCeiling` (8,192 tokens by default), without changing the saved
`agent.maxTokens` setting. A configured, enabled WebSocket stream and the enabled
web relay bypass this default ceiling; an HTTP fallback from a failed socket is
capped again. Explicit per-request token values and provider body overrides also
bypass the default. Model limits and previously learned caps still apply when
building the request.

Tune it with `getgenv().UAI.config.set("agent.executorReplyCeiling", 16384)`;
use `0` to disable this default clamp. A request that returns nothing after
20–130 seconds can be retried once with a smaller reply and reduced reasoning
effort when available. Only a valid completion saves the working reply ceiling
on that provider record for the current model. Minimal requests and cancelled
requests are not retried this way. Large prompts can still spend the request
window uploading and prefilling; `agent.contextTokens` remains 1,000,000 by
default and can be lowered when short replies also time out.

`check_luau` checks syntax without executing code. Both it and `run_luau` accept
either inline `code` or a saved file `path`. Use `check_luau` with
`{"path":"scripts/build.lua"}` to validate a script you edited, then run it by
the same path. Its source stays on the client instead of being generated and sent again. Saved-paste
references resolve the same way as `file_read`.

`run_luau` captures print/warn, tables, and multiple return values, and inserts
cooperative checkpoints in loop
bodies without changing strings or comments. Its `timeout` argument accepts 1–60
seconds and defaults to 10. It waits for functions started through its
`task.spawn`, `task.defer`, and `task.delay` wrappers; errors, Stop, deadlines, and
unload stop those managed tasks cooperatively. An endless spawned task therefore ends at the
deadline rather than continuing silently after the tool returns.

This is not a security sandbox. Dynamically compiled code, blocking engine calls,
and callbacks registered on engine signals can bypass these controls. Later work
in a persistent engine callback is outside a successfully completed call. UAI leaves
native coroutines alive so pending Roblox/executor callbacks cannot resume a thread
it closed. Managed waits and delayed callbacks check cancellation flags, including
after a successful parent returns; `task.cancel` accepts only this script's task
handles. Work suspended outside managed waits can still resume before its next
checkpoint, and the result reports that uncertainty. Changes already made are not
rolled back.

`file_read` and `script_source` return contiguous slices and a continuation
`offset` when more remains. Offsets count bytes and preserve UTF-8 boundaries.
After reading a workspace file, use `file_edit` with exact `old_text` and `new_text`
to change it. The default requires a unique match; `replace_all=true` replaces all
non-overlapping matches. Empty replacement text deletes the match. The tool refuses
a file that changed while the edit was being prepared.
Prefer `file_edit` or `file_edit_many` for targeted changes to large files.
`file_write` is for new files or replacing most of a file; it and `file_append`
reject content over 2 MiB per call before writing.
Build large new scripts in small sections, waiting for each write before the next
append or edit to that file. Each section must be a complete tool call. Interrupted
write arguments are rejected instead of repairing them into a partial edit. If a
provider reports that its tool batch hit the token limit, none of those calls run;
the model receives results asking it to retry with smaller, complete calls.

See [CHANGELOG.md](CHANGELOG.md) or **What's New** for the latest release notes.

## Skills

The main and subagent prompts require reading every enabled skill before the first
reply or other work in each new or resumed conversation. Skill bodies are read
through `skills_read`; the inventory alone does not count. Long bodies and
`skills_list` results have byte-offset continuations that fit the tool result
budget. Restricted subagents can read skills without gaining skill-writing tools.
Disabled skills are skipped, and unavailable or denied reads are reported once.

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
