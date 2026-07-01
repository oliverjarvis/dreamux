# Arc-style project sidebar — design

Date: 2026-07-01
Status: Approved (pending spec review)

## Summary

Restyle the project window's content column (`WorkspaceSidebar`) to adopt Arc's
sidebar language:

1. **Signals** moves out of its pinned card into a **2-column grid of pinned
   square tiles** at the top of the sidebar, drag-reorderable. A new **Web
   Browser** tile joins it.
2. **Features** get restyled to look like Arc's flat vertical tabs, drag-
   reorderable, with **"Add Feature"** moved above the list (Arc's "+ New Tab"
   slot).
3. The **Web Browser** tile opens an in-app web tab at a hardcoded homepage
   (`https://www.google.com`). The web tab's existing header becomes a real
   **browser bar** — editable address field, back/forward, reload — so the user
   can navigate anywhere.
4. Grid-tile order and feature order **persist per project** to
   `‹project›/.dreamux/sidebar.json`.

## Goals

- Pinned 2-column grid of tiles (Signals + Web Browser), live drag-reorder.
- Features rendered as flat Arc-style tabs, live drag-reorder, "Add Feature"
  above the list.
- A usable in-app browser tab: editable address bar (URL or Google search),
  address reflects the live page, back/forward/reload.
- Order (tiles + features) persists across relaunch.

## Non-goals (follow-ups)

- The top-of-sidebar address bar from the mockup (the "reddit.com" bar) — the
  address bar lives inside each web tab instead.
- A settings UI for the browser homepage — hardcoded to `google.com` for now.
- Persisting per-feature symbol/tint/name (they still reset on relaunch, as
  today).
- Restyling the Repositories section, an Arc "Clear" action, or a collapsible
  Features header.

## Current state (verified)

- `WorkspaceStore.workspaces: [Workspace]` — plain ordered array, no order field,
  not persisted. `reloadFeatures(in:repoStore:)`
  (`Sources/Dreamux/Models/WorkspaceStore.swift`) discovers features from disk,
  sorts them **alphabetically**, and builds a `Workspace` per feature using a
  deterministic UUID (`stableUUID(forFeature:)`). Orphan workspaces (no linked
  repos) are appended last.
- `Workspace` — `id, name, symbol, tint, workingDirectory, linkedRepoIDs`.
- `SidebarMode` (`Sources/Dreamux/Views/ContentView.swift`) — `.workspace`,
  `.run(workspaceID:)`, `.signals`.
- `ContentView` — 3-column `NavigationSplitView`; `WorkspaceSidebar` in the
  content column; `mainPane` detail switches on `sidebarMode`. It also wires
  `runners.openURLInApp` → `store.session(for:).openWebTab(url:title:)`.
- `ProjectWindow.onAppear` calls `store.reloadFeatures(in:repoStore:)`.
- Web tabs already exist: `WorkspaceSession.openWebTab(url:title:)` sets
  `nextTabWebURL` and creates a Bonsplit tab (globe icon); `WebTabSession`
  (`Sources/Dreamux/Models/WebTabSession.swift`) lazily builds a `WKWebView` and
  loads its `let url`. `TabContentView` in `WorkspaceTerminalContainer.swift`
  dispatches terminal-vs-web by session lookup. `WebTabView` (same file) renders
  a header with **static** URL text + reload + open-externally.
- Persistence patterns to mirror: `ProjectStore` writes
  `~/Library/Application Support/Dreamux/projects.json`; `RunConfig` writes
  `‹project›/.dreamux/run.toml`. JSON is written atomically with `JSONEncoder`
  (`.prettyPrinted, .sortedKeys`).
- Existing in-repo drag-reorder: Bonsplit's `TabBarView` uses
  `.onDrag { NSItemProvider(object: … as NSString) }` + `.onDrop(of: [.text],
  delegate: TabDropDelegate)` (`vendor/bonsplit/Sources/Bonsplit/Internal/Views/
  TabBarView.swift`). We mirror this pattern.

## Design

### Sidebar structure (top → bottom)

```
┌─────────────────────────────────┐
│  ┌────────────┐ ┌────────────┐   │   pinned grid (2 cols, grows to 2×2+)
│  │  Signals   │ │  Browser   │   │   drag-reorderable
│  │  〜 purple │ │  🌐 blue   │   │
│  └────────────┘ └────────────┘   │
│                                  │
│  FEATURES                        │   section header (Arc "Space")
│  + Add Feature                   │   styled/placed like "+ New Tab"
│  ◉ auth-refactor          ▶      │   flat Arc tab rows, drag-reorderable
│  ◉ billing-fix            ▶      │
│  ◉ search-index           ▶      │
│                                  │
│  ▸ REPOSITORIES                  │   unchanged
└─────────────────────────────────┘
```

### Pinned grid + tiles

- `LazyVGrid`, 2 columns, square tiles (large centered SF Symbol on a soft
  rounded fill, Arc favorites look).
- Tiles are built-ins modeled by `SidebarTile` (`.signals`, `.browser`).
- **Signals** — purple `waveform.path.ecg`; tap sets `sidebarMode = .signals`
  (same action as today's `signalsRow`). Highlighted when
  `sidebarMode == .signals`.
- **Web Browser** — blue `globe`; tap opens a web tab at the homepage in the
  active feature's pane:
  1. `guard let ws = active workspace ?? store.workspaces.first else { return }`
  2. `store.activate(ws.id)`; `sidebarMode = .workspace`
  3. `store.session(for: ws).openWebTab(url: homepage, title: "New Tab")`
  - `homepage = URL(string: "https://www.google.com")!` (constant).
  - **Disabled** (dimmed, tooltip "Add a feature to open a browser tab") when
    `store.workspaces.isEmpty`, since web tabs live inside a feature's pane.
- Tiles drag-reorder live (see Drag-reorder). Order persists.

### Web tab browser bar

Turn `WebTabView`'s header into a working browser bar:

- **Back / Forward** buttons (`chevron.left` / `chevron.right`), disabled per
  `canGoBack` / `canGoForward`.
- **Reload** (existing).
- **Editable address field** — replaces the static URL `Text`. A `TextField`
  seeded from `session.currentURL`. `onSubmit` → `session.navigate(to:)`.
  - When the field is **not focused**, its text mirrors `session.currentURL`
    (so it tracks the live page). When focused, the user edits freely.
- **Open externally** (existing).

`WebTabSession` additions:

- Keep `url` as the immutable **home/identity URL** (still used by
  `openWebTab`'s existing dedup, so runner-opened URLs re-focus their tab).
- Add `var currentURL: URL` (starts at `url`), `var canGoBack: Bool`,
  `var canGoForward: Bool`, kept in sync via a `NSKeyValueObservation` on
  `webView.url` / `webView.canGoBack` / `webView.canGoForward`, established when
  the `WKWebView` is lazily created.
- `func navigate(to input: String)` — loads `Self.resolveNavigation(input)` in
  the web view.
- `func goBack()` / `func goForward()`.
- `static func resolveNavigation(_ input: String) -> URL` (pure, unit-testable):
  - trimmed input with a scheme (`http://`, `https://`) → that URL.
  - looks host-like (no spaces and contains a ".") → prepend `https://`.
  - otherwise → `https://www.google.com/search?q=<percent-encoded input>`.

### Features → Arc tabs

- Drop the bordered card + hairline dividers for the feature list; render flat
  rows, each with its own rounded highlight on hover/selected (matching the
  highlighted row in the mockup).
- Keep the soft tinted badge icon (feature symbol/tint) as the tab's leading
  icon, plus the running-dot, unread dot, and the hover-revealed run/open
  controls on the trailing edge (all existing behavior in `featureRowBody` /
  `runControls`).
- **"+ Add Feature"** moves above the feature rows (where "+ New Tab" sits),
  styled to match a tab row.
- Feature rows drag-reorder live.

### Drag-reorder mechanism

Mirror Bonsplit's `TabDropDelegate`, factored into one reusable delegate:

- `ReorderDropDelegate<Item: Equatable>` conforming to `DropDelegate`, holding
  the dragged `item`, a `Binding<[Item]>` to the array, and a
  `Binding<Item?>` to the currently-dragging item. On `dropEntered`, if a
  different item is being dragged, it moves the dragged item to this item's
  index inside `withAnimation` (live rearrangement). `performDrop` clears the
  dragging item.
- Each tile / row gets `.onDrag { dragging = item; return NSItemProvider(object:
  "<id>" as NSString) }` and `.onDrop(of: [.text], delegate:
  ReorderDropDelegate(...))`.
- **Grid** binds to `layout.tiles`; on drop, persist tile order.
- **Features** bind to `store.workspaces`; on drop, `store.persistFeatureOrder()`
  writes the new order to `sidebar.json` (orphans excluded from the persisted
  name list but still draggable in-session).

### Persistence

New file `‹project›/.dreamux/sidebar.json`, written atomically like
`ProjectStore.save()`:

```json
{
  "tiles": ["signals", "browser"],
  "features": ["auth-refactor", "billing-fix", "search-index"]
}
```

- On launch, `reloadFeatures()` orders the discovered (alphabetical) features by
  the saved `features` list: known names first in saved order, unknown names
  appended (alphabetical), vanished names dropped. Orphans stay last. The
  resulting order is written back so newly-discovered features get recorded.
- Drag-reorder of features/tiles rewrites the file immediately.

## Components

| File | New/Edit | Responsibility |
|------|----------|----------------|
| `Sources/Dreamux/Models/SidebarTile.swift` | new | `enum SidebarTile` (`.signals`, `.browser`) + display metadata (symbol, tint, label). `Codable, CaseIterable, Identifiable`. |
| `Sources/Dreamux/Models/SidebarLayoutStore.swift` | new | `@MainActor @Observable`. Owns `tiles: [SidebarTile]`, `featureOrder: [String]`; loads/saves `‹project›/.dreamux/sidebar.json`. `ordered(_ discovered: [Workspace]) -> [Workspace]` merge logic; `moveTile`, `setFeatureOrder`. Unit-testable. |
| `Sources/Dreamux/Views/PinnedTileGrid.swift` | new | The 2-column reorderable grid view of `SidebarTile`s; tap callbacks; drag-reorder. |
| `Sources/Dreamux/Views/ReorderDropDelegate.swift` | new | Reusable live-reorder `DropDelegate`. |
| `Sources/Dreamux/Views/WorkspaceSidebar.swift` | edit | New top-to-bottom structure; grid replaces `signalsRow` card; Features restyled as flat Arc tabs; "Add Feature" moved above the list; feature rows drag-reorderable. |
| `Sources/Dreamux/Models/WorkspaceStore.swift` | edit | Hold a `layout: SidebarLayoutStore?`; `reloadFeatures` applies saved order via `layout.ordered(...)`; `moveWorkspace`/`persistFeatureOrder`. |
| `Sources/Dreamux/Models/WebTabSession.swift` | edit | `currentURL`, `canGoBack/canGoForward` (KVO), `navigate(to:)`, `goBack/goForward`, `resolveNavigation`. |
| `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` | edit | `WebTabView` header → browser bar (back/forward, reload, editable address field, external). |
| `Sources/Dreamux/Views/ContentView.swift` / `ProjectWindow.swift` | edit | Construct `SidebarLayoutStore(project:)`; inject into `WorkspaceSidebar` + set `store.layout`. |

## Behavior details / edge cases

- **No features present**: Browser tile disabled; Features list shows the
  existing empty-state text; "Add Feature" behaves as today.
- **Signals highlight**: grid tile shows the accent highlight when
  `sidebarMode == .signals`, mirroring the current row's selected state.
- **Web tab dedup**: unchanged — keyed on the tab's home `url`. Clicking the
  Browser tile repeatedly re-focuses the existing `google.com` tab (until the
  user navigates it elsewhere, after which a fresh one opens); acceptable.
- **Address field focus vs. live URL**: field mirrors `currentURL` only while
  unfocused; typing is preserved while focused; submit navigates and resigns
  focus.
- **Orphan workspaces**: excluded from persisted `features` names but still
  drag-reorderable in-session; always rendered after linked features (as today).
- **Drag routing**: the active workspace already forces itself to the top of the
  detail `ZStack`; sidebar drag/drop is independent of that.

## Testing

- **Unit — `SidebarLayoutStore.ordered(...)`**: saved order applied; unknown
  features appended alphabetically; vanished names dropped; `features` rewritten;
  round-trips through a temp project `rootPath`.
- **Unit — `WebTabSession.resolveNavigation(_:)`**: scheme'd URL passes through;
  host-like input gets `https://`; free text becomes a Google search URL
  (percent-encoded).
- **Unit — reorder helper**: array move math (from/to indices) for the delegate.
- **Manual / e2e**: launch app, drag a tile and a feature, relaunch, confirm the
  order persists; open the Browser tile, type an address, use back/forward.
```
