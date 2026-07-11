# Keyboard Shortcuts + ⌘K Command Palette — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorm complete)

## Problem

⌘N does nothing in a project window (it is only bound on the first-run
Welcome screen), and there is no keyboard-first way to create things or jump
between projects, workspaces, and plans. The app needs a coherent shortcut
scheme and a global ⌘K command palette, also reachable from a search bar in
the projects rail.

## Decisions made during brainstorming

- **⌘P opens the New Plan sheet** (the plan-first flow the sidebar's
  "+ New workspace" row already uses). ⌘⇧T keeps its current scratch-
  workspace behavior. The default Print menu item is replaced — nothing in
  the app prints.
- **⌘K palette indexes all four categories in v1:** projects, workspaces &
  plans, commands, and file search.
- **The palette is an in-window overlay** (Xcode "Open Quickly" style), not
  an NSPanel or a sheet.

## 1. Shortcut map

| Shortcut | Action | Wiring |
|---|---|---|
| ⌘N | New Project… — opens `CreateProjectSheet` | `CommandGroup(replacing: .newItem)` |
| ⌘P | New Plan… — opens `NewPlanSheet` | `CommandGroup(replacing: .printItem)` |
| ⌘K | Toggle command palette | New `PaletteCommands` struct in `DreamuxApp.commands` |

All existing shortcuts are untouched: ⌘T new tab, ⌘⇧T scratch workspace,
⌘⇧⌥T reopen workspace, ⌘D/⌘⇧D splits, ⌘W/⌘⇧W close, ⌘⌥arrows focus
navigation, ⌘1–9 workspaces, ⌘⌥1–9 tabs, ⌥⌘E file explorer, ⌘, settings.

Wiring copies the proven `FileExplorerCommands` pattern
(`DreamuxApp.swift:180`): menu items drive `@FocusedBinding`s that
`ContentView` publishes via `.focusedSceneValue`. This survives terminal
first-responder focus — the reason ⌥⌘E already lives in `.commands`.
`ContentView` publishes three new focused values: `showCreateProject`,
`showNewPlan` (reusing the existing sheet state behind
`ContentView.swift:244` and `:517`), and `paletteVisible`. Scenes that don't
publish them (Settings, App Studio, Welcome) get disabled menu items
automatically; the Welcome screen keeps its own ⌘N binding.

## 2. Palette surface & interaction

A centered panel (~600pt wide, pinned ~20% from the window top) drawn as a
`ContentView`-level `.overlay` above a light scrim. Scrim click or Esc
dismisses; ⌘K toggles.

Layout, following the house style (CLAUDE.md):

- Search field on top: magnifier glyph, 15pt text, placeholder
  "Search projects, plans, files…"; hairline divider below.
- Sectioned results: PROJECTS / WORKSPACES & PLANS / COMMANDS / FILES
  headers at 13pt semibold, kern ~0.4.
- Rows at 15pt with fixed-width 16pt leading glyphs, 6–8pt vertical
  padding, standard hover wash (`Color.primary.opacity(0.04)` hover /
  `0.08` selected on `RoundedRectangle(cornerRadius: 8)`).
- Matched characters render emphasized (bold/primary) using the matcher's
  ranges.

Interaction: ↑↓ moves selection linearly across sections (via `onKeyPress`
on the focused field), ⏎ executes the selection, clicking a row executes
it. Empty query shows the PROJECTS and COMMANDS sections (each under the
normal 5-row cap, commands in their static declaration order); file results
appear only once the user types. Sections cap at 5 rows (files: 8). Executing any
result dismisses the palette and clears the query. ⌘K is ignored while a
sheet is presented — no palette stacked over modals.

## 3. Search bar in the projects rail

In `ProjectsRail`'s top `safeAreaInset` (`ProjectsRail.swift:86`), between
the traffic-light clearance and the "Projects" header: a search-shaped
button in the app's outlined-pill control shape (`RoundedRectangle`
cornerRadius 8, `strokeBorder` `.secondary.opacity(0.3)`, subtle
`.primary.opacity(0.04)` fill) — magnifier glyph, 15pt "Search" label,
trailing `⌘K` hint in `.secondary`. Clicking it opens the palette (same
`paletteVisible` state). The collapsed rail stub
(`ContentView.collapsedRailStub`) gets a plain magnifier glyph button in
the same slot.

## 4. Data & actions

A new `@MainActor @Observable PaletteModel`, owned by `ContentView`,
holds the query + selection and composes results from four providers:

- **Projects** → `ProjectStore.projects`; select = `onSwitchProject(id)`,
  the exact path a rail row click takes.
- **Workspaces & plans** → `session.store.workspaces` (including `main`)
  plus `docStore` docs with `kind == .plan`/`.spec`; select =
  `sidebarMode = .workspace; store.activate(id)` + `focusOverview()`
  (pattern at `WorkspaceSidebar.swift:274–276`), or the sidebar's existing
  open-plan path for docs.
- **Commands** → static action list reusing the same handlers the menus
  call: New Project…, New Plan…, New Scratch Workspace, New Tab, Toggle
  File Explorer, Go to Signals / Flows / Library, Run Plan….
- **Files** → filename fuzzy search over the active workspace's
  `session.fileTree` index; select = the existing file-open path (opens a
  tab). v1 is filename-only — no content search. If the tree isn't loaded,
  the section is empty.

Providers are plain protocol-shaped values injected into `PaletteModel` so
result composition is unit-testable with fakes.

## 5. Fuzzy matcher

A small dependency-free `FuzzyMatcher` utility: case-insensitive
subsequence matching with scoring — consecutive-run bonus, word/segment-
boundary bonus, prefix bonus, shorter-target tiebreak — returning a score
plus matched character ranges for highlighting. Shared by all four
providers.

## 6. Testing

- Unit tests for `FuzzyMatcher`: match/no-match cases and ranking
  (prefix beats scattered, boundary beats mid-word, etc.).
- Unit tests for `PaletteModel` with fake providers: query routing,
  section caps, empty-query composition, arrow-key selection across
  sections.
- One e2e screenshot test riding the existing infra: launch, send ⌘K,
  type a query, capture the palette.

## Out of scope (v1)

- File *content* search.
- Cross-window / global (NSPanel) palette.
- Recents/frecency ranking.
- OuterRail.swift (vestigial, unmounted) — untouched.
