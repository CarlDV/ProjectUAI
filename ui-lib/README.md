# Project UAI UI LIB

An independent, responsive Roblox UI library with Project UAI's visual language.

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
```

- [API and agent guide](../docs/UI_LIBRARY.md)
- [Starter script](examples/starter.lua)
- [All-controls showcase](examples/showcase.lua)
- [Built library](../dist/uai-ui.lua) and [SHA-256 manifest](../dist/uai-ui.manifest.json)

Manually review changes, build with `node tools/build_ui_lib.js`, and inspect the
outputs before checking with `luajit test/ui_library.lua`. Follow the full
verification sequence in the guide after client or documentation changes.
The library owns layout, input, state, cleanup, and the permanent
`Project UAI | UI LIB.` footer. It has no built-in logo. Scripts own application logic.
