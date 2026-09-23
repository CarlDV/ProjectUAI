# Context and provider verification — September 23, 2026

This change implements all seven feature tasks in `plan-2026-09-23.md`. The
separate free-provider proposal is deferred, as requested.

The inspector uses the plan's Message options fallback: **Context breakdown**
opens a live, colored usage panel without changing composer geometry. Purple is
system prompt and tool schemas, blue is messages, amber is the rolling summary,
and gray is unused space. Counts are estimates, and totals are explicitly partial
until a provider reply has calibrated overhead. A known model window determines
the bar's scale; otherwise the compaction point does.

## Automated verification

All commands below passed. The full application suite finished with **132
scenarios, 1860 checks, zero failures**. The focused suites passed 53 context, 98
configuration-transfer, 309 chat UI, 152 mobile workflow, 100 shared-layout, 56
panel-layout, 34 reasoning-replay, and 22 web-runtime checks. Website validation
passed 5062 static checks. The source checker parsed 119 files with no failures or
warnings, and the 118-module bundle and publishing mirror were rebuilt and verified.

The regressions cover both provider protocols, same-turn recovery, smaller
fallback models, bounded retries, cancellation, histories with nothing removable,
parser ambiguity, the 8000-token learning floor, and preserving previous summaries
after failed or disabled summary calls. AgentRouter tests exercise actual mock
transport headers for completions and model discovery, plus a socket envelope,
with identity switches off and conflicting custom headers.

UI interaction checks cover the inspector on desktop, tablet, portrait and
landscape phones, live category updates, dismissal, individual memory deletion,
external memory updates, and the existing clear-all confirmation. Configuration
transfer retains the context override map.

Run from the repository root:

```text
luajit test/check.lua
luajit tools/bundle.lua
luajit test/run.lua
luajit test/context_compaction.lua
luajit test/config_transfer.lua
luajit test/chat_regressions.lua
luajit test/mobile_workflows.lua
luajit test/shared_ui_layout.lua
luajit test/panel_layout_regressions.lua
luajit test/reasoning_replay.lua
luajit test/web_runtime.lua
node tools/build_site.js
node tools/build_site.js --check
node --check script.js
python test/site_static.py
```

The context preview scene in `test/mobile_snapshots.lua` was exported with LuaJIT
and rendered with `test/render_mobile.js` at six desktop/tablet/phone resolutions.
The desktop and portrait layouts show the full breakdown; landscape retains the
lower details in the scrollable body. These previews approximate Roblox layout
and text measurement. Local images and logs are in the ignored
`refer/context-2026-09-23/` and `refer/verification-2026-09-23/` directories.

## Native client verification

The user reported that the updated build works. The automated checks used the
offline harness; independent native-renderer verification and a real provider
input-token comparison have not been performed. The Windows computer-use plugin
was initialized, but both app discovery and window discovery reported
`Computer Use native pipe is unavailable` (`os error 2`). No native inputs were
sent. To complete these checks with the local bundle:

1. Load the updated `dist/uai.lua` into a test conversation. Temporarily lower the
   current model's context override or the context budget, recording the old value
   so it can be restored.
2. Build several turns until the composer percentage rises and automatic
   compaction emits its before/after notice. Use ordinary messages rather than one
   oversized paste: inputs over 8000 bytes become attachments.
3. Compare the **main** provider request's reported input tokens before and after
   compaction. Exclude the separate summary call, which requests at most 512 output
   tokens. Confirm that the next main request is smaller and still answers the
   latest question.
4. Repeat compaction and verify that an important fact from the first summary
   remains in the second. Open **Message options → Context breakdown** and check
   the category colors, totals, model window, and compaction marker.
5. Inspect the notice dot against single-line and wrapped text on desktop and
   phone. Check landscape scrolling and that Send remains reachable after closing
   the inspector.
6. In **Settings → Skills → Memory**, add two disposable facts, delete one, and
   confirm the other remains. Restore the original context settings afterward.

AgentRouter's live service was not contacted. With an eligible account, fetch its
models or enter the documented recommendation `deepseek-v4-flash`, then test the
native Messages route. The preset and transport behavior are covered offline.
