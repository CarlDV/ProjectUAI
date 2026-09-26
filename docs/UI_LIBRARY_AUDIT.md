# UI library implementation review

Manual review preceded automated tests for this implementation. The same order
applies to fixes: inspect the change, rebuild and inspect affected artifacts,
then rerun verification.

Reviewed scope:

- All ten `ui-lib/src` factories, loader, release metadata, and both examples.
- Public API documentation, repository agent instructions, main/subagent prompt
  integration, and the read-only paginated `ui_library_docs` tool.
- Build scripts, regression cases, snapshot export, and the preview renderer.
- Generated standalone module wrappers, metadata, entry point and SHA manifest;
  embedded guide and its Lua string boundaries; main client bundle and manifest;
  generated website catalog changes.

The review addressed false/nil values, constructor failure cleanup, theme binding
ownership, callbacks that destroy controls, task and input cleanup, touch gesture
ownership, key capture cancellation, resizing, text scaling, and keyboard bounds.
Live numeric input preserves decimal drafts and caret position. Color Apply
reads pending fields before committing. Configuration validates before mutation
and releases held actions only after restoring all values. Notifications fit
the available viewport and truncate text on UTF-8 boundaries.

Visual review identified narrow large-text labels and unnecessary picker
scrolling. The follow-up changes stack constrained rows, give titles more
horizontal space, use the available height on phones by default, account for
dropdown spacing, and fit the color field around the remaining controls.
These changes and their regression cases were manually reviewed before reruns.
The final branding uses `Project UAI | UI LIB.` without a leading separator.
The header logo and its layout logic were removed; titles use the available space.

The main client bundle changes only its agent prompt, GUI tool module, and the
new embedded guide, plus generated build metadata. Existing `src/ui` application
code is unchanged. The website changes are the generated tool entry and counts.

Verification completed on 2026-09-26 after the final footer and logo corrections:

- `node tools/test_native.js` passed all 49 stages, including 35 focused suites.
  The main suite passed 129 scenarios and 1,877 checks. The UI library passed
  104 checks, and its agent integration passed 18 checks.
- The native static checker parsed 175 files and 174 modules with zero failures
  or warnings. The official Luau compiler accepted the client, standalone library,
  library sources, and examples. Build freshness, catalog freshness, mock harness,
  performance contracts, and build-script syntax checks passed.
- Generated 39 approximate Chromium previews at 1280x800, 390x844, 844x390,
  and 320x568. Manual visual inspection covered representative controls,
  dropdowns, color pickers, dialogs, notifications, minimized windows, light
  theme, large text, and keyboard layouts. Final branding previews were
  regenerated and inspected after removing the logo and leading separator.

The verified standalone release is v1.0.0, 115,316 bytes, with SHA-256
`aa864c03fc78e305b4ab72fef9f0ce14b565dadf5ec1e2231c778c5663f7b1cf`.
Local evidence is in `refer/native-verification/results.json` and
`refer/ui-library-review/`; those generated review files are gitignored.

Behavioral mocks and Chromium previews cannot establish native Roblox text
rendering, device keyboard behavior, or actual gamepad focus behavior.
Those remain in-client validation requirements.
