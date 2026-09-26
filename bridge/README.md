# Cowork bridge

Use UAI in your browser while Roblox runs your tools and keeps the conversation.
Run both on the same computer. The bridge needs **Node.js 18 or newer** and has no
production npm dependencies.

## Start in three steps

1. **Download and start.** In Roblox, open **UAI → Cowork → Download bridge files**.
   Open a terminal in your executor's workspace folder—the folder containing
   `UAI`—and run:

   ```powershell
   node UAI/bridge/start.txt
   ```

   From a Git checkout instead, open a terminal in the repository folder and run
   `node bridge/server.js`.
2. **Connect Roblox.** The terminal prints a **Token**, a port (normally `8790`),
   and a browser link. Paste the token into **UAI → Cowork**, match the port,
   and turn **Enabled** on.
3. **Open the browser link.** Choose a provider and model, then send a message.
   Keep Roblox and the terminal open while you work. Press `Ctrl+C` in the
   terminal when you want to stop the bridge.

No `npm install` or manual file renaming is needed. The download uses `.txt`
files because some executors block executable file extensions. Node checks their
sizes and Git blob hashes, restores their original names inside the downloaded
package, and starts the bridge. Downloads use one pinned revision and a new
package folder; the launcher changes only after all downloaded files are saved.

After a restart, open the **new** browser link and paste the **new** token into
Roblox. To use a different port, append `--port 8791` to the start command and
enter that port in Roblox too.

## Working in the browser

- **Chat** follows the active Roblox conversation. Use the sidebar to find or
  start conversations; draft text and code files stay with their conversation.
- **Web runtime** shows responses as they arrive when the provider supports
  streaming. **Game runtime** uses Roblox's provider connection and shows the
  saved reply when it arrives. Switch in **Cowork** while work is idle.
- **Attach text or code** with the paperclip, drag a file onto the composer, or
  paste long text. Large inputs become verified files that the agent can read.
  Limits: 2 MiB per file/input, 16 text files and 8 MiB per draft.
- **Attach pictures** with the image button, paste, or drop. PNG, JPEG and WebP
  are **previews only**: the AI receives one `[PICTURE]` text marker per picture,
  so describe what matters. Limits: 8 pictures, 5 MiB each, 20 MiB held by the
  bridge, 4096 × 4096 and 12 megapixels. Animated images are not supported.
- **Stop** cancels the current turn. Closing or refreshing the browser does not.
  If delivery is unclear, use **Check delivery** before sending again.
- **Settings → Browser appearance** offers system, light, dark, and Match Roblox.
  Exported conversations include picture metadata, not image bytes. A full
  configuration export includes API keys.

Commands can arrive immediately while Roblox's long poll is waiting. The
18-second timeout only renews an idle connection. Game updates are batched about
every 150 ms, live browser text paints about every 60 ms, and command receipts
are checked every 250 ms. These are batching intervals, not an end-to-end latency
guarantee; executor scheduling and the provider's response time also matter.

## If something is stuck

| What you see | What to do |
| --- | --- |
| `node` is not recognized | Install Node.js 18+, close the terminal, and open a new terminal. |
| The start file cannot be found | Open the terminal in the executor workspace containing `UAI`. Download the files again if `UAI/bridge/start.txt` is missing. |
| Download failed | Retry in Cowork. A failed download keeps the existing launcher; HTTP, file read/write, and folder creation are required. |
| Package verification failed | Download again. Do not edit or rename the downloaded `.txt` files. |
| Roblox is waiting to connect | Keep the terminal open. Check the port, paste its latest token, then enable Cowork. Both must run on this computer. |
| The token no longer works | The bridge may have restarted. Use its latest token and browser link. |
| Live responses are unavailable | Choose Web runtime while idle and check that your provider supports SSE. Non-streaming providers still return a complete reply. |
| A picture is expired or unavailable | Attach it again. Pictures expire after 15 minutes of inactivity and disappear when the bridge stops. |
| The bridge is reconnecting | Keep your draft in the tab and restart/reconnect the bridge. Review the conversation if a delivery receipt was lost. |

## Development and tests

`server.js` owns authenticated loopback routes, command receipts and browser SSE.
`inference.js` owns provider requests and bounded preview replay. `picture-store.js`
keeps validated image bytes in memory. `launcher.js` restores executor downloads.
`web/` contains the dependency-free UI, Markdown, previews, pictures, themes and
asynchronous draft storage. Roblox remains authoritative in both runtimes.

All bridge tests live in `tests/`. Shared utilities are in `tests/helpers/` and
synthetic game/image inputs in `tests/fixtures/`. The JPEG/WebP fixtures are real
encoded images; tests generate valid PNG chunks without additional dependencies.

Finish implementation, documentation and test edits before running verification:

```powershell
luajit tools/bundle.lua
node tools/build_site.js
node bridge/tests/run.js
luajit test/web_runtime.lua
luajit test/bridge_install.lua
```

For real browser checks, install Playwright **outside this repository**, including
its Chromium browser. Set `PLAYWRIGHT_MODULE` to that package's absolute directory
if it is not on the normal module path. Optionally set `UAI_SCREENSHOTS` to an
output directory, then run:

```powershell
node bridge/tests/run.js --browser-only
```

The browser suites cover navigation, forms, streaming, picture ownership/replay,
upload cancellation, receipt races, full drafts, themes, drawer focus, token
recovery, CSP, reduced motion, and 320–1440px layouts. Inspect the saved screenshots
as well as checking geometry. These fixtures do not replace a live executor check.

Protocol remains version 2. `/api/hello` advertises optional picture and normalized
stream capabilities. `--legacy` disables pictures and uses compatibility delta
frames. Raw provider response bodies remain separate from browser preview rings;
oversized or truncated responses fail explicitly. The bridge never uploads picture
bytes to a model. It binds to loopback, rotates its bearer token on restart,
checks browser origins and serves local assets under a same-origin CSP.
