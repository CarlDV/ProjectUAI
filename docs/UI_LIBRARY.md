# Project UAI UI LIB

A standalone Roblox interface library for script-owned tools. It follows Project
UAI's warm surfaces, cream primary actions, coral accent, and restrained typography.
It does not replace or redesign the agent client's interface.

The source is [ui-lib/](../ui-lib/), the public artifact is
[dist/uai-ui.lua](../dist/uai-ui.lua), and the repository is
[Project-Ptolemy/ProjectUAI](https://github.com/Project-Ptolemy/ProjectUAI).
Every window, minimized launcher, and dialog includes the fixed bottom attribution
`Project UAI | UI LIB.`. There is no option to remove or replace it.
The library uses text titles and includes no logo.

## Quickstart

Load the library once in each standalone script. The returned API is independent
of the Project UAI client. The library makes no further HTTP requests and does not
download fonts, icons, or third-party scripts.

```lua
local UI = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"
))()

local window = UI:CreateWindow({
	Id = "my-session-tools",
	Title = "Session tools",
	Subtitle = "Everything you need for this session",
})
local main = window:Tab({ Title = "Main", Icon = "sliders" })
local actions = main:Section({ Title = "Actions" })
local amount = actions:Slider({
	Id = "amount", Text = "Amount", Min = 1, Max = 20, Step = 1, Default = 5,
})
actions:Button({
	Text = "Process selection", ActionText = "Run", Style = "Primary",
	Callback = function()
		-- Your application logic belongs here.
		print("Process", amount:Get())
		window:Notify({ Title = "Finished", Content = "Selection processed.", Kind = "Success" })
	end,
})
return window
```

Use a stable, script-specific window `Id`. Rerunning a script with that same Id
destroys its previous window and calls its registered cleanup functions, even
when it loads a fresh copy of the library. Different Ids coexist. No unrelated
ScreenGui is deleted.

Agents: read `ui_library_docs` sections `quickstart`, `controls`, and `lifecycle`
before writing a script UI. Use declarative tabs, sections, and controls plus
domain logic. Do not create GUI instances, styles, layout arithmetic, drag
handlers, third-party UI loaders, or replacement attribution in scripts. Extend
the shared library when a missing reusable component is required. Respect an
explicit user request to work on an existing custom interface.

The `main` URL follows compatible updates to the v1 API. For reproducible releases,
replace `main` with the reviewed Git commit SHA in the raw URL. HTTP and loadstring
must be available in the host; surface their errors instead of silently fetching
a different UI library. In Studio, the bundle can be placed in a ModuleScript
and loaded with `require` from a LocalScript.

## Controls

Create controls with `section:ControlName({ ... })`. Common options:

| Option | Meaning |
| --- | --- |
| `Id` | Unique string within the window; required for configuration persistence and `window:Get(id)`. |
| `Text` | Visible label. Use short, concrete wording. |
| `Description` | Supporting text that wraps at the available width. |
| `Default` | Initial value. Construction never invokes a callback. |
| `Callback` | Called on a changed value or button press. Errors produce a notification and do not break other controls. |
| `Disabled` / `Visible` | Initial enabled/visible state. |
| `Persist = false` | Exclude this value from exported configuration; use for transient or sensitive inputs. |

All controls have `Get()`, `Set(value, silent?)`, `Reset(silent?)`,
`SetText(text)`, `SetDescription(text)`, `SetDisabled(boolean)`,
`SetVisible(boolean)`, `OnChanged(callback)`, and `Destroy()`.
`OnChanged` returns an unsubscribe function. Setters return the control.
`Set` invokes value callbacks only when the value changes; `silent = true`
suppresses them. Returned arrays are copies. A disabled control can be updated
programmatically. `Get/Set/Reset/OnChanged` are useful on value controls; use
`Press` for buttons and `SetText/SetDescription` for display-only text.

| Constructor | Options and behavior |
| --- | --- |
| `Button` | `ActionText = "Run"`, `Style = "Primary" / "Danger"` (otherwise secondary), `LoadingText`. `Callback()` runs in an owned task; repeated presses are ignored while it runs. `Press()` returns whether it started; `SetLoading(bool)` controls a loading indicator. |
| `Toggle` | Boolean `Default`; `Callback(enabled)`. Full-size touch target around a compact switch. |
| `Checkbox` | Same boolean API, with a check mark. |
| `Slider` | `Min = 0`, `Max = 100`, `Step = 1`, `Default`, `Suffix`. `Callback(number)` on changes, `OnCommit(number)` once at gesture end. Values are clamped and rounded relative to Min; Max is reachable even when the step does not divide the range. Arrow/D-pad left/right changes one step; Home/End reaches the endpoints. |
| `Input` | String `Default`, `Placeholder`, `MaxLength = 4096` UTF-8 bytes, `MultiLine`, `Lines = 3`, `Live = false`. Commits on focus loss; Live publishes valid edits while preserving the draft/caret until focus loss. `Numeric = true` uses finite numbers and optional `Min/Max`. Invalid drafts show an error while preserving the last valid value. `OnCommit(value)` and `Focus()` are available. |
| `Dropdown` | `Options`, `Default`, `Multi = false`, `Searchable = true`, `Placeholder`. `SetOptions(array, silent?)` replaces choices and retains still-valid selections. `Open()` opens the picker. Empty options show an empty state. |
| `Segmented` | Single selection among 1–8 `Options`. Same selection and `SetOptions` API as Dropdown; wraps into rows at narrow widths. |
| `Keybind` | `Default = Enum.KeyCode.K` (or `"K"`), `Mode = "Press" / "Hold" / "Toggle"`, `ActiveWhenHidden = false`. `Callback(active, key)` handles activation; `OnChanged(key)` handles rebinding. Hold calls true on press and false on release/cancellation; Toggle alternates until canceled. Click to capture, Escape cancels, Backspace/Delete clears. `Set(nil)` unbinds. Window's toggle key is reserved. |
| `ColorPicker` | `Default = Color3.fromRGB(...)`, optional `Alpha = 1` or `ShowAlpha = true`. HSV square, hue bar, hex and RGB inputs, preview, Apply/Cancel. Color components must be within 0–1; alpha is clamped to that range. `Callback(color, alpha)` fires on Apply or a changed Set. `Get()` returns color, alpha; `GetAlpha()` and `SetAlpha(alpha, silent?)` are available. |
| `Label` | A wrapping `Text` and optional `Description`. |
| `Paragraph` | `Text` is the title; `Content` (or Description) is the wrapping body. |
| `Divider` | A small section label and separator. Use `Text = ""` for a plain separator. |
| `Badge` | `Default` or `Value` is a status string. `Kind = "Success" / "Warning" / "Danger" / "Secondary"`. Change the string with `Set`. |
| `Progress` | `Min = 0`, `Max = 100`, `Default` or `Value`. `Set(number)` updates a bounded track and percentage. |

Dropdown/Segmented options are primitive strings, finite numbers, or booleans,
or records such as `{ Label = "Balanced", Value = "balanced", Disabled = false }`.
Values must be unique. Dropdowns support up to 500 choices with literal search.
Single-select `Default` and `Get` use one value (or nil for no selection);
multi-select uses an array. Multi-select changes are immediate; Done closes the
picker. A disabled option is displayed but cannot be selected interactively.

Keybinds work across tabs while the window is open. They ignore processed input,
text editing, and open dialogs. Hiding or destroying a window releases active
Hold/Toggle actions. No initialization or configuration import simulates a key
press. A keybind's `Set` updates the binding, not its active state.

## Layout

`UI:CreateWindow(options)` accepts `Id`, `Title`, `Subtitle`, optional
`Width = 780` / `Height = 580`, `Search = true`, `Theme = "Dark" / "Light"`,
`Accent = Color3`, `TextScale = 1` (0.85–1.5), `ToggleKey = Enum.KeyCode.RightShift`
(false disables it), `DisplayOrder = 80`, `Parent`, and `OnDestroy`.
Supply a PlayerGui/CoreGui-compatible parent only when embedding.
The default parent is gethui, CoreGui, then PlayerGui, with capability detection.
When Height is omitted, narrow touch windows use the available screen height;
an explicit Height retains the requested size within the safe viewport.

The library handles safe insets, viewport/camera replacement, device rotation,
keyboard obstruction, touch targets of at least 44 pixels, mouse dragging,
desktop resizing, wrapped descriptions, independently scrolling tabs, and scroll
reveal for focused fields. It reflows at compact widths rather than shrinking
the interface with UIScale. Navigation becomes a horizontal scrolling tab strip.
On desktop, controls use a 40-pixel target, increasing with text scale.
Rows stack their value below the label when space is tight.

`window:Tab({ Id?, Title, Icon? })` creates a tab. Icons are native vector marks:
`grid`, `sliders`, `code`, `check`, `arrow`, `chevron`, `close`, `minus`.
No uploaded image assets are required. `tab:Select()`, `tab:SetVisible(bool)`,
and `tab:Destroy()` manage it.

`tab:Section({ Title, Description?, Collapsible?, Collapsed? })` creates a
group. Sections support `SetCollapsed(bool)`, `SetVisible(bool)`, and `Destroy()`.
Search filters the active tab's labels, descriptions, and section titles,
reveals matching collapsed sections, and displays a clear empty state.

Window methods: `Show()`, `Hide()`, `Minimize()`, `Toggle()`, `Destroy()`,
`SelectTab(idOrTab)`, `SetTitle(title, subtitle?)`,
`SetTheme("Dark"|"Light", accent?)`, `SetTextScale(number)`, `Get(controlId)`.
Minimize keeps an on-screen restore button. Hide removes that button too.
The top-right close button destroys the window. Each window has independent
theme and state. The footer remains pinned outside scrolling content.

## Lifecycle

Register logic resources with `window:Give(resource)`: an RBXScriptConnection,
Instance, task thread, or cleanup function. It returns an early-release function.
`window:OnDestroy(function)` is an alias for registering cleanup. Resources
are released when the window is closed, its ScreenGui is removed, its Id is
replaced, or `UI:DestroyAll()` is called. Cleanup is idempotent.

```lua
local players = game:GetService("Players")
window:Give(players.PlayerAdded:Connect(function(player)
	window:Notify({ Title = "Player joined", Content = player.DisplayName })
end))
window:OnDestroy(function()
	-- Restore temporary application state and stop any domain-level worker.
end)
```

Use event-driven logic. Do not start an unowned infinite task inside a callback.
When run through UAI's managed `run_luau`, tool-owned tasks have the execution
tool's deadline; use owned event connections for UI logic that should continue
after the initial script returns. Dynamic library loading does not extend that
deadline or undo application side effects. A callback should check its own
domain object's lifetime after yielding.

`UI:GetWindow(id)` returns a live handle, `UI:DestroyAll()` closes only library
windows, and `UI.Version` / `UI.URL` / `UI.Repository` identify the release.
GUI instance handles are exposed as `window.ScreenGui`, `window.Frame`, and
`control.Frame` for inspection and testing. Do not style or reparent these in
consumer scripts; doing so breaks the layout and ownership contract.

## Configuration

Give stateful controls stable Ids. `window:ExportConfig()` returns versioned JSON;
`window:ImportConfig(json, options?)` returns `true, count` or `false, error`.
Imports require the same window Id, validate every known value before changing
any, ignore removed/unknown control Ids, and reject changed control types.
Configuration JSON is limited to 256 KiB. Values marked `Persist = false` are
neither exported nor imported.

Imports are silent by default: they update controls without starting application
actions. `{ Silent = false }` invokes value callbacks after all values have been
restored. Active Hold/Toggle bindings receive a release (`false`) after the
complete state is restored; imports never send an activation (`true`). Release
callbacks may clean up or destroy their window. Read initial control values
explicitly when your application needs them.

`window:SaveConfig("profile-name")` saves under `ProjectUAI/UI/` and returns
`true, path` or `false, error`. `window:LoadConfig("profile-name", options?)`
reads and imports. Names allow 1–48 letters, digits, underscores, and hyphens.
Files are namespaced per window; paths cannot traverse directories.
Missing executor filesystem functions return a clear error; JSON export/import
works with Roblox HttpService and does not require executor storage.
No configuration is read, saved, or applied automatically.

## Recipes

Notifications:

```lua
window:Notify({
	Title = "Saved", Content = "Your preferences are ready.",
	Kind = "Success", Duration = 5,
	Action = { Text = "Open settings", Callback = function() settingsTab:Select() end },
})
```

`Kind` is Info/Success/Warning/Danger. Up to three notifications are retained;
the newest ones that fit are visible. Older notices reappear as space becomes
available or newer ones close. Long text is bounded and truncated.
`Duration = 0` keeps one visible until dismissed; otherwise 0–60 seconds.
The returned handle has `Close()`.

Dialogs:

```lua
window:Confirm({
	Title = "Reset preferences?", Content = "This restores the defaults for this tool.",
	ConfirmText = "Reset", Danger = true,
	Callback = function() amount:Reset() end,
})
window:Dialog({
	Title = "About this tool", Content = "A focused workspace for your current session.",
	Buttons = { { Text = "Done", Style = "Primary" } },
})
```

`Dialog` accepts 1–4 buttons, each with `Text`, optional `Style` and `Callback`.
Choosing a button closes the dialog, then runs the callback in the window's scope.
`Dismissible = false` disables backdrop/Escape dismissal and the close button.
Dialogs return a `Close()` handle and restore previous gamepad selection.
Only one dialog or picker is open per window. Pickers clamp to the safe viewport,
move above their anchor when needed, and use a centered sheet on compact layouts.

Dynamic choices:

```lua
local target = actions:Dropdown({
	Id = "target", Text = "Target", Options = {}, Placeholder = "No players yet",
})
local function refreshPlayers()
	local choices = {}
	for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
		choices[#choices + 1] = { Label = player.DisplayName, Value = player.UserId }
	end
	target:SetOptions(choices)
end
refreshPlayers()
window:Give(game:GetService("Players").PlayerAdded:Connect(refreshPlayers))
window:Give(game:GetService("Players").PlayerRemoving:Connect(function(leaving)
	local choices = {}
	for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
		if player ~= leaving then choices[#choices + 1] = { Label = player.DisplayName, Value = player.UserId } end
	end
	target:SetOptions(choices)
end))
```

Full examples: [starter.lua](../ui-lib/examples/starter.lua) and
[showcase.lua](../ui-lib/examples/showcase.lua). They load the same public bundle
as production scripts and contain no GUI instance construction.

## Development

Library source is separate from `src/ui`, which remains the existing client UI.
Modules in `ui-lib/src` are `return function(env) ... end` factories, using the
repository's Lua 5.1-compatible Luau dialect. Keep visual tokens in `theme.lua`.
Add reusable controls here; consumer scripts should only declare controls and
implement application behavior.

Manually audit every change before automated tests, including the test code.
After reviewing build inputs, generate and inspect the outputs before running
the suites. Review each subsequent fix manually before retesting.

```bash
node tools/build_ui_lib.js
luajit tools/bundle.lua --native
node tools/build_site.js
# Manually inspect the generated bundles, manifests, guide, and catalog here.
node tools/test_native.js
```

The UI build emits `dist/uai-ui.lua`, a SHA-256 manifest, and
`src/runtime/ui_library_docs.lua` generated from this guide. The generated guide
backs the offline `ui_library_docs` tool, so agents can read the exact API without
network access. Never hand-edit generated artifacts. Rebuild the main client
after changing the guide or agent instructions.

The behavioral tests execute the actual distributed library with the repository's
Roblox mock, including mouse/touch ownership, value validation, config round-trips,
callback failures, replay, and cleanup. Native Roblox rendering, OS keyboard
behavior, and actual gamepad focus still require in-client validation.
