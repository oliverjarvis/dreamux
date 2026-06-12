# Specs & Plans Browser

**Date:** 2026-06-12
**Status:** Approved

## Problem

The superpowers plugin writes design specs to
`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` and implementation
plans to `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` inside each
repo (this repo itself follows the convention). Plans carry a rigid,
parseable structure: `### Task N:` sections with `- [ ]` checkbox
steps. Today Clayspace has no way to see these documents — reading a
spec means finding the right worktree in Finder and opening an editor.

This is phase 1 of a three-phase superpowers integration:

1. **Specs & plans browser** (this spec) — discover, navigate, and read
   the documents in-app.
2. **Implementation queue** — an order artifact that walks plans,
   provisioning a feature worktree per plan.
3. **Progress & gates** — checkbox/hook-driven progress, test-between-
   phases, merge gate before the queue advances.

## Decision

Add a read-only Specs & Plans browser as a sidebar-driven main-pane
swap, following the Signals precedent: a "Specs & Plans" tile in
`WorkspaceSidebar` selects a new `SidebarMode.docs`, and the main pane
shows a master-detail browser. Discovery scans every worktree of every
repo in the project. Rendering uses the MarkdownUI SPM package.

Approaches considered:

- **UI placement A — new `AppSection.docs` in the OuterRail:** the enum
  was built for future sections, but adding a second section resurrects
  a whole rail of chrome for one pane, and hides the feature list while
  reading docs.
- **UI placement B — `SidebarMode.docs` (chosen):** follows the exact
  pattern Signals established for project-level panes; features stay
  visible in the sidebar, which phase 3 needs for progress badges.
- **Rendering A — MarkdownUI dependency (chosen):** native SwiftUI,
  GitHub-flavored markdown including task-list checkboxes (the plan
  format), code blocks, and tables; follows dark mode for free.
- **Rendering B — WKWebView + vendored marked.js:** avoids the SPM
  dependency (Clayspace is deliberately dependency-lean) but costs HTML
  theming, JS bundling, and a heavier view for a text pane.
- **Rendering C — `AttributedString(markdown:)`:** no dependency but no
  task lists, tables, or heading hierarchy — too weak for plan files.

## Design

### 1. Discovery — `DocStore` (`Models/DocStore.swift`)

- Scans every worktree of every repo in the project for
  `docs/superpowers/specs/*.md` and `docs/superpowers/plans/*.md`. The
  two relative paths are constants in `DocStore` — superpowers' own
  skills declare them as defaults, and a future `.clayspace` override
  can land in one place.
- Produces `DocEntry` values:
  - `kind` — `.spec` or `.plan`, from the containing folder
  - `repoName` and `branch` — from the worktree scanned
  - `title` — first `#` heading, falling back to the filename
  - `date` — parsed from the `YYYY-MM-DD-` filename prefix, `nil` if
    the prefix is malformed
  - `fileURL` — absolute path of the chosen copy
  - `progress` — for plans, `(checked, total)` counted from
    `- [ ]` / `- [x]` lines; `nil` for specs
- **Multi-worktree dedupe:** a doc written on a feature branch exists
  only in that feature's worktree until merge, then also in the default
  branch's worktree. Entries are deduped by (repo, relative path); when
  copies differ, the most recently modified copy wins and the entry
  carries that worktree's branch. UI badges the branch only when it is
  not the repo's default branch.
- Refresh runs on demand (pane appearance and a manual refresh button).
  No file watching in v1.

### 2. UI — `DocsBrowserView` (`Views/DocsBrowserView.swift`)

- Master-detail. Left column: docs grouped under **Specs** and
  **Plans** headers, newest first (by filename date, undated last).
  Each row shows title, date, repo badge, branch badge when off-main,
  and `checked/total` progress for plans.
- Right side: the selected document rendered with MarkdownUI, plus
  toolbar buttons "Open in Editor" (`NSWorkspace.open`) and "Reveal in
  Finder". Read-only — editing stays in the user's editor.
- Empty state when no docs exist: a short explanation of the
  superpowers folder convention.

### 3. Wiring

- `SidebarMode` gains `.docs`; `FeaturesDetail.mainPane` gains the
  case; `WorkspaceSidebar` gets a "Specs & Plans" tile next to the
  Signals tile, driving `sidebarMode = .docs`.
- `DocStore` is created in `FeaturesDetail.init` alongside
  `SignalStore`/`RunnerManager` and registered with `E2ERegistry` like
  the run stores.
- Dependency: `swift-markdown-ui` added to `Package.swift`.

### 4. Out of scope (phases 2–3)

The implementation-order artifact, queue execution, worktree
auto-provisioning, live progress, and merge gates.

## Error handling

- Missing `docs/superpowers/` folders are normal — repos without docs
  simply contribute no entries.
- Unreadable files are skipped during scan; selection of a file deleted
  since the scan shows an inline "file no longer exists" message and a
  refresh clears it.
- Malformed filename dates render without a date and sort last.

## Testing

- Unit tests for `DocStore` against `TestSandbox`-style fixture repos:
  title/date parsing, checkbox counting, kind detection, multi-worktree
  dedupe (feature-only doc, merged doc identical in both, diverged
  copies prefer newest mtime), missing folders, malformed names.
- E2E: a `listDocs` command returning the scanned entries, and the
  existing `pendingSidebarMode` bridge drives the pane swap so a
  scenario can open the browser and assert on the state dump.
