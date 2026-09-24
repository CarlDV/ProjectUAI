# Historical Code editor

`code_panel.lua`, `code_store.lua` and `coding_tools.lua` preserve the old editor.
They are outside `src/` and are not bundled.

The v1.7.0 replacement lives in `src/ui/panels/code.lua`,
`src/ui/code/`, `src/runtime/code_store.lua` and `src/tools/coding.lua`, with shared
Explorer, Remotes, typed values and execution services. Do not move these obsolete
modules back into `src/`; their persistence/execution paths bypass the new revision,
recovery and cancellation contracts.

Use [the current specification](../SPEC.md) for the workspace contract and
[the native testing guide](../docs/CODE_WORKSPACE_TESTING.md) for current workflows
and coverage limits.
