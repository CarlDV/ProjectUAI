# Project UAI - Custom Icons

Place your custom Lucide icon image files in this directory.

## Image Format & Guidelines
- **Format**: `.png` with transparent background.
- **Color**: Pure white (`#FFFFFF`).
  - *Why white?* Roblox's `ImageLabel.ImageColor3` dynamically tints white pixels to any theme color (e.g., Accent Coral, Muted Grey, Success Green, Danger Red).
- **Recommended Resolution**: `48x48` or `64x64` pixels (Lucide stroke width 2px).
- **Canvas**: Centered with 2-4px padding so edges don't clip when rendered at 14px-18px.

## Required Icon Filenames & Lucide Mappings

| ProjectUAI File Name | Lucide Icon Name | Where It's Used |
| :--- | :--- | :--- |
| `close.png` | `x` | Window close button, tag dismiss |
| `plus.png` | `plus` | New conversation, add provider |
| `minus.png` | `minus` | Window minimize button |
| `windowMaximize.png` | `square` or `maximize-2` | Window maximize button |
| `chevron.png` | `chevron-down` | Dropdowns, collapsible activity blocks |
| `check.png` | `check` | Checkboxes, completed task items |
| `dot.png` | `circle-dot` | Status indicator / active badge |
| `bars.png` | `menu` | Mobile hamburger navigation menu |
| `stop.png` | `square` | Stop active generation button |
| `send.png` | `corner-down-left` or `send` | Composer send button |
| `spark.png` | `sparkles` | Subagents tab, AI trigger button |
| `copy.png` | `copy` | Copy transcript, code block copy button |
| `trash.png` | `trash-2` | Delete conversation |
| `sidebarToggle.png` | `panel-left` | Collapse / expand sidebar |
| `search.png` | `search` | Search conversations and commands |
| `arrowLeft.png` | `arrow-left` | Back button |
| `arrowRight.png` | `arrow-right` | Forward / next button |
| `code.png` | `code-xml` or `code` | Chat tab, code viewer |
| `circleHollow.png` | `circle` | Unselected radio / status circle |
| `enter.png` | `corner-down-left` | Enter key affordance |
| `folder.png` | `folder` | Workspace explorer / file tree |
| `branch.png` | `git-branch` | Git branch selector |
| `worktree.png` | `folder-git-2` or `git-fork` | Tools / worktree panel |
| `terminal.png` | `terminal` | Cowork panel, shell output |
| `document.png` | `file-text` | Place details, logs |
| `gear.png` | `settings` | Settings dialog |
| `sliders.png` | `sliders-horizontal` | Inference providers configuration |
| `globe.png` | `globe` | Web search and network tools |
| `book.png` | `book-open` | Documentation & About build panel |
| `signOut.png` | `log-out` | Unload UAI client button |
| `ellipsis.png` | `more-horizontal` | More options context menu |
