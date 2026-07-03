# Header restructure: titlebar toggle + compact project header

**Date:** 2026-07-03
**Status:** Approved

## Problem

The full-width accent-gradient "hero band" at the top of the detail area
(`ContentView.heroBand`) is too heavy. The user wants:

1. The file-explorer toggle button (currently at the right end of the hero
   band) moved into the window's native titlebar.
2. The project identity (avatar + name) moved to a compact row that sits
   **above the ghostty tabs** and **to the right of the Work-Items sidebar**
   (the column topped by the signals/browser tiles).
3. The hero band itself removed, letting the Work-Items sidebar extend to
   the top of the content area.

## Design

All changes are in `Sources/Dreamux/Views/ContentView.swift`.

### 1. Remove the hero band

Delete the `heroBand` computed property (lines 278–337) and its slot at the
top of the detail `VStack` (line 127).

### 2. Layout reshuffle

The detail column changes from
`VStack(heroBand, HSplitView(WorkspaceSidebar, mainPane))` to:

```swift
detail: {
    HSplitView {
        WorkspaceSidebar(...)          // now reaches the top of the content area
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 380)
        VStack(spacing: 0) {
            projectHeaderRow           // compact: avatar + name
            mainPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- The Work-Items sidebar (pinned tiles, plans, repos) extends to the top.
- The project header row spans only the width right of the sidebar and sits
  above `mainPane` in **all** sidebar modes (workspace / run / signals).
- The `maxHeight: .infinity` frame moves from `mainPane` to the wrapping
  `VStack` so the `HSplitView` stays vertically greedy (the existing comment
  explains the split collapses without a height-flexible child).

### 3. Compact project header row

A quiet `HStack` replacing the hero band's styling:

- 20×20 accent-gradient `RoundedRectangle` avatar with the project's
  first initial (white, heavy rounded, ~11pt).
- Project name at ~13pt semibold rounded, `lineLimit(1)`.
- `Spacer`, horizontal padding ~12, vertical ~8, bottom `Divider`.
- No gradient band background — it blends with the window chrome like the
  tab strip below it.

### 4. Titlebar toolbar item

Attach to the `NavigationSplitView` (same level as `.navigationTitle`):

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button { showFileTree.toggle() } label: {
            Image(systemName: "sidebar.right")
        }
        .help("Toggle file explorer (⌥⌘E)")
    }
}
```

- macOS renders it natively at the trailing end of the titlebar, opposite
  the split view's built-in rail toggle.
- Tint the icon with the accent color while `showFileTree` is true.
- **No `.keyboardShortcut` on the toolbar item.** ⌥⌘E stays in the View
  menu (`FileExplorerCommands`) because toolbar-item shortcuts are not
  dispatched while the Ghostty terminal NSView is first responder (see the
  existing comment at `ContentView.swift:163–170`).
- `.navigationTitle("")` stays — the titlebar shows controls, not a title.

### 5. Comment cleanup

Rewrite the now-stale comments that describe the hero band: the detail-column
note (lines 123–125), the navigation-title note (lines 151–153), and the
`heroBand` doc comment (lines 273–277).

## Explicitly out of scope

- No changes to `WorkspaceSidebar`, `ProjectsRail`, Bonsplit's `TabBarView`,
  the inspector/`FileTreePanel`, or any e2e bridge plumbing.
- The unused legacy `OuterRail`/`AppSection`/`SectionTile` files are left
  alone.

## Error handling

No new state or failure modes: `showFileTree`, `focusedSceneValue`, and the
e2e bridge (`pendingFileTreeVisible`) are untouched, so the View-menu command
and e2e automation keep working unchanged.

## Testing / verification

- Build and launch the app.
- Confirm: titlebar shows the toggle at the trailing end; clicking it opens/
  closes the file-explorer inspector and the icon tints while open; ⌥⌘E
  still works from the View menu; the compact header (avatar + name) sits
  above the ghostty tabs, right of the Work-Items sidebar; the sidebar
  reaches the top; all three sidebar modes keep the header row.
- Capture a screenshot via the project's e2e tooling to verify layout.
