# Cowork UI audit — 1.9.0

September 26, 2026. Reviewed `web/style.css`, `web/index.html`, and the JavaScript
that creates or updates their controls. The baseline was commit `d79c7c7`.

## Findings and corrections

| Priority | Defect and reproduction | Correction |
| --- | --- | --- |
| High | Adding a pending question rebuilt every request card, erasing an unfinished answer, the Remember checkbox, text selection, and keyboard focus. | Keep cards by request ID and update their content without replacing active inputs. |
| High | An expired token during a dialog action showed the connection form behind the still-open modal. | Close the modal and focus the token field during authentication recovery. |
| High | A long task list or a draft with pictures, files, and multiple lines could push Send below the clipped workspace, particularly at 844×390 and 320×480. | Bound task and composer content, allow scrolling, and keep the composer toolbar separate from overflowing attachments. |
| Medium | Jump to latest used a fixed 175px offset, placing it over an expanded textarea or pending controls. | Position it within the transcript's own wrapper. |
| Medium | Long provider endpoints, model names, log URLs, and conversation titles produced horizontal overflow. Narrow model lists also compressed multiline button labels. | Wrap long content and dialog headings; prevent model rows from shrinking below their content height. |
| Medium | Every state update collapsed the expanded task list. | Retain its details element and open state while updating task contents. |
| Medium | Provider, runtime, and permission buttons stopped refreshing while focused. The open model picker kept its old selected model. | Refresh selected states while preserving control focus; defer panel replacement during editing, saving, selection, or an unfinished pointer action. |
| Medium | Save failures appeared in the page toast behind native dialogs. | Use a live status region inside the dialog and scroll its message into view without moving focus. |
| Medium | Free-form answers lacked a question-specific label and did not submit with Enter. Permission requests from other conversations looked local. | Associate answer inputs with their questions, submit through forms, and identify the request's conversation. |
| Medium | Navigation could leave focus on hidden or removed content. Selecting a conversation from another panel did not open Chat. | Focus the destination, open Chat after a successful conversation change, and focus replacement modal content. |
| Medium | Updating a picture or removing an attachment discarded focus from another removal/retry control. | Restore the same attachment control, the adjacent attachment, or the attachment button. |
| Medium | Muted light-theme text had only 3.96:1 contrast on the sidebar. Light code buttons hovered at 2.49:1 against a dark page. | Darken the light muted-text token and use a light-code-specific hover surface. |
| Medium | Forced-colors mode erased the Stop square and the textarea's focus treatment. | Add a system-color Stop border and explicit focus outlines. |
| Low | Failed setting saves retained green success text, and armed Clear retained its original accessible name. | Style status according to its state and expose the confirmation label. |
| Low | The model picker's checkbox stacked above its label; streaming paragraphs lost their normal spacing at the stable/tail boundary. | Set row direction explicitly and limit the last-paragraph rule to direct message children. |

## Coverage

- Source review of the full Bridge stylesheet, static HTML, dynamic markup,
  focus handling, themes, dialogs, pending requests, and attachment controls.
- Static ID, label/reference, local asset, and SVG symbol checks.
- Chromium layouts across all nine workspace views at 320, 390, 768, 1024,
  and 1440 CSS pixels, plus short portrait and landscape viewports.
- Full drafts, the supported 24-task limit, 60-character titles, long provider
  paths, long model lists, live state changes, rejected commands, and expired tokens.
- Light/dark themes, opposite code themes, reduced motion, forced colors,
  keyboard focus, and automated WCAG accessibility checks on representative views.
- Before/after screenshots and geometry checks, including individual controls
  inside panels whose document-level bounds would otherwise appear correct.

`tests/browser-ui-audit.js` retains the focused regressions. It is included in
`node bridge/tests/run.js --browser-only` and uses the same external Playwright
installation as the other browser suites. Screenshot output is optional through
`UAI_SCREENSHOTS`; audit tooling and screenshots are kept outside the repository.

Final verification passed:

| Check | Result |
| --- | --- |
| `node bridge/tests/run.js` | 55 tests passed |
| `node bridge/tests/run.js --browser-only` | All four browser suites passed |
| `luajit test/web_runtime.lua` | 22 checks passed |
| `luajit test/bridge_install.lua` | 70 checks passed |
| `luajit test/run.lua changelog "what's new" boot` | Four scenarios, 247 checks passed |
| `node tools/build_site.js --check` | Version 1.9.0 bundle and generated website synchronized |
| `python test/site_static.py` | 5,974 checks passed |
| Representative axe WCAG scans | No violations on the connection screen, welcome, pending questions, dark chat with light code, and dark settings |
| JavaScript syntax and `git diff --check` | Passed |

These checks use an isolated local bridge and synthetic game state. They do not
establish Safari/Firefox compatibility, native mobile safe-area or keyboard
behavior, or live Roblox executor behavior.

## Release numbering

The Cowork update had been committed under an unnumbered `Unreleased` heading
while the client and generated site still identified 1.8.0. It is now recorded
as **1.9.0 — September 26, 2026**, with matching bootstrap metadata, in-game release
notes, README, client bundle, and generated website. Historical 1.8.0 release
evidence retains its original version and date.
