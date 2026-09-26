# Project UAI development

Read SPEC.md before changing the client. Keep its LuaJIT-compatible Luau dialect,
factory module convention, and separation between runtime logic and presentation.

## Script interfaces

Use our **Project UAI UI LIB** for new script-owned interfaces. Read
[docs/UI_LIBRARY.md](docs/UI_LIBRARY.md), especially Quickstart, Controls, and
Lifecycle. Load the published bundle from:

`https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua`

Scripts declare tabs, sections, values, and domain callbacks. They do not build
ScreenGuis, controls, colors, fonts, padding, drag systems, or external UI-library
loaders. Register application connections and cleanup with `window:Give` and
`window:OnDestroy`. Use stable window/control Ids. Keep the fixed bottom
attribution `Project UAI | UI LIB.` in every library window. The library uses
text titles without a logo.

Add missing reusable capabilities under `ui-lib/src` and document the public API;
do not duplicate a component in individual scripts. Explicit requests to modify
an existing custom UI can preserve that interface. The current agent client in
`src/ui` is a separate, established application; this library is not a mandate to
redesign or migrate it.

## Generated artifacts and verification

Manually audit every source, documentation, example, test, and build change
before running automated tests. Build only after reviewing the inputs, inspect
the generated outputs, and then run verification. Manually review each fix
before retesting. This order is an explicit project requirement.

Run `node tools/build_ui_lib.js` after library or guide changes, then
`luajit test/ui_library.lua` and `node tools/build_ui_lib.js --check`.
This generates the standalone bundle, SHA-256 manifest, and the embedded
`ui_library_docs` reference. Do not edit these outputs directly.

After changing client source or its generated guide, rebuild with
`luajit tools/bundle.lua --native` and run the applicable client tests.
Use the existing offline harness for behavior and the official Luau compiler
where available. Mock/Chromium previews approximate layout; they do not verify
native Roblox rendering or host input.
