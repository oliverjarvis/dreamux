# Cross-repo file tree + Monaco editor tabs — design

Date: 2026-07-01
Status: Approved (pending spec review)

## Summary

Add a VS-Code-style file explorer and code editor to the project window:

1. A **toggleable file-tree panel on the right side** of the project window,
   built as a native macOS `.inspector`. It presents the files of every repo
   the **active feature** spans as one unified tree — each repo a top-level
   node — so the user browses across all of a feature's repos as if they were
   one workspace, even though each repo's worktree is a separate root on disk.
2. Clicking a file opens it as an **editor tab inside the active workspace's
   Bonsplit layout**, alongside terminals and in-app browser tabs. The editor
   is the **real Monaco engine hosted in a `WKWebView`** (reusing the existing
   WebKit tab infrastructure), with syntax highlighting, ⌘S save to the
   worktree file, and a dirty indicator on the tab.

## Goals

- A native, toggleable right-side panel (`.inspector`) showing a unified,
  lazily-loaded file tree scoped to the active feature's linked repos.
- Each linked repo appears as a top-level node; the tree updates when the
  active feature changes.
- Clicking a file opens a Monaco editor as a Bonsplit tab in the active
  workspace; reopening the same file re-focuses its existing tab.
- Real Monaco editing experience: syntax highlighting (language from
  extension), light/dark theme following the system, find/replace, minimap.
- ⌘S writes the buffer to the worktree file; the tab shows a dirty dot until
  saved.
- Monaco assets are bundled for **offline** use (no network fetch at runtime).

## Non-goals (follow-ups)

- **Project-wide / default-branch browsing.** v1 is scoped to the active
  feature's worktrees only (the "Active feature's worktrees" option). Repos the
  feature doesn't span are not shown, and `main` is never edited directly.
- **External-change reconciliation.** If a file changes on disk (git op,
  another editor) while open, the tab is not auto-reloaded in v1.
- **Editor-tab persistence across relaunch.** Open editor tabs are session-only,
  consistent with today's terminal/web tabs (features are reconstructed from
  worktrees; tabs bootstrap fresh).
- **File-system mutation from the tree** (new file / rename / delete / drag).
  The tree is read + open only in v1.
- **Live FS watching (FSEvents).** The tree refreshes on panel appear, on
  active-feature change, and via a manual refresh affordance — not continuously.
- **Multi-root search / global find**, breadcrumbs, git status decorations in
  the tree.

## Current state (verified)

- **Worktree layout** (`Sources/Dreamux/Shell/FeatureProvisioner.swift`):
  - Per-repo worktree: `‹project›/repos/‹repo›/‹feature›/`, checked out on
    branch `‹feature›`.
  - Aggregation dir: `‹project›/features/‹feature›/‹repo›` → symlink to
    `../../repos/‹repo›/‹feature›`.
  - `Workspace.workingDirectory` for a feature is the `features/‹feature›/`
    aggregation directory.
- **`Workspace`** (`Sources/Dreamux/Models/Workspace.swift`) —
  `id, name, symbol, tint, workingDirectory, linkedRepoIDs`. `linkedRepoIDs`
  are the folder names under `repos/`.
- **`Repository`** (`Sources/Dreamux/Models/Repository.swift`) — `rootURL`,
  `defaultBranch`, `name` (== `rootURL.lastPathComponent`). `RepoStore`
  (`Sources/Dreamux/Models/RepoStore.swift`) owns `repositories: [Repository]`.
- **`WorkspaceSession`** (`Sources/Dreamux/Models/WorkspaceSession.swift`)
  drives a Bonsplit layout. It already keeps **two** parallel session maps
  keyed by `TabID`: `tabSessions: [TabID: TabSession]` (terminals) and
  `webTabSessions: [TabID: WebTabSession]` (in-app browser). `handleDidCreateTab`
  dispatches: a pending `nextTabWebURL` claims the new tab as a web tab,
  otherwise a terminal `TabSession` is created. `openWebTab(url:title:)` sets
  `nextTabWebURL`, dedups by URL, then `controller.createTab(icon: "globe")`.
- **`TabContentView`** (`Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`)
  dispatches terminal-vs-web by session lookup and renders `TerminalSurfaceView`
  or `WebTabView`. `WebTabView` wraps `session.webView` in an
  `NSViewRepresentable` (`WebViewRepresentable`). This is the pattern the file
  editor mirrors.
- **`WebTabSession`** (`Sources/Dreamux/Models/WebTabSession.swift`) — the
  model to mirror for a WKWebView-backed session (`@MainActor @Observable`,
  lazily builds a `WKWebView`, exposes nav state).
- **`ContentView`** (`Sources/Dreamux/Views/ContentView.swift`) — the project
  window's 3-column `NavigationSplitView` (rail | Work Items | detail).
  `sidebarMode: SidebarMode` (`.workspace` / `.run(workspaceID:)` / `.signals`)
  is `@State` here; the detail pane switches on it. `.workspace` renders
  `WorkspaceTerminalContainer(store:)`. Sets `navigationTitle` / `.subtitle`
  but has **no** `.toolbar` yet.
- **Platform**: `Package.swift` → `.macOS(.v14)`. `.inspector(isPresented:)` is
  available (macOS 14+). WebKit already linked. SwiftPM resources already used
  (test fixtures); no existing resource bundle on the `Dreamux` executable
  target yet.
- **E2E** (`Sources/Dreamux/E2E/`) — `E2ERegistry.shared` holds per-project
  `WorkspaceStore`/`RepoStore`/run stores; the state dump already reports
  `session.webTabURLs`. Commands park requests on an `E2EBridge` consumed by the
  views (e.g. `pendingSidebarMode`, `pendingMergeWorkspaceID`). We extend this
  same pattern.

## Design

### 1. Right-side panel — native `.inspector`

`NavigationSplitView` maxes at 3 columns, so the tree cannot be a 4th column.
Use SwiftUI's native trailing panel:

- `ContentView` gains `@State private var showFileTree = false`.
- `.inspector(isPresented: $showFileTree) { FileTreePanel(...) }` on the
  `NavigationSplitView`, with `.inspectorColumnWidth(min: 220, ideal: 280,
  max: 480)`.
- Toggle affordance: a `.toolbar { ToolbarItem(placement: .automatic) { ... } }`
  button on `ContentView` using the `sidebar.right` SF Symbol, plus keyboard
  shortcut **⌥⌘E** ("Explorer" — no collision with ⌘T new tab / ⌘⇧T new
  workspace). Default: hidden.

### 2. File-tree model — `FileTreeStore` + `FileNode`

`FileNode` (`Sources/Dreamux/Models/FileNode.swift`) — a lazily-expanding
node:

```
struct FileNode: Identifiable {
    let url: URL              // resolved (symlink-free) path on disk
    let name: String         // display label (lastPathComponent, or repo name for roots)
    let isDirectory: Bool
    let isRepoRoot: Bool      // top-level per-repo node → shows repo-style chrome
}
```

`FileTreeStore` (`Sources/Dreamux/Models/FileTreeStore.swift`) —
`@MainActor @Observable`, pure/testable:

- Input: the active `Workspace` + the project's `[Repository]`.
- `func roots(for workspace: Workspace?, repositories: [Repository]) -> [FileNode]`
  — for each `linkedRepoID`, find its `Repository`, resolve the worktree path
  `repo.rootURL / workspace.name`, and if it exists on disk emit a root
  `FileNode(isRepoRoot: true)` labelled with the repo name. Repos with no
  worktree at that branch, and repos the feature doesn't span, are omitted.
- `func children(of node: FileNode) -> [FileNode]` — `contentsOfDirectory`,
  sorted directories-first then case-insensitive by name, **excluding** `.git`
  and `.bare`. Loaded on demand (on disclosure), never eagerly recursed.
- Ordering of roots follows `workspace.linkedRepoIDs`.

Rationale for resolving real worktree paths (not the `features/‹feature›/`
symlink dir): Monaco save writes must land on the real file, and per-repo
labelling is cleaner. Each root is an independent path, which is exactly what
makes "not necessarily co-located" fall out for free.

### 3. File-tree panel view — `FileTreePanel`

`Sources/Dreamux/Views/FileTreePanel.swift`:

- Native source list: SwiftUI `List` of `DisclosureGroup` rows (lazy children),
  matching the app's native-controls preference.
- Header: the active feature's name + a refresh button.
- Row: SF Symbol (folder / `doc` by extension) + name; directories disclose,
  files are `Button`s that call `onOpenFile(node.url)`.
- Reads `store.activeWorkspace` and `repoStore.repositories` from the
  `FileTreeStore`; recomputes roots when the active feature changes, on
  `.onAppear`, and on manual refresh.
- Empty states: "No feature selected." when `activeWorkspace == nil`;
  "This feature spans no repositories." when it has no linked worktrees.

### 4. Monaco editor tab — `FileEditorTabSession`

A third session type, mirroring `WebTabSession`. In `WorkspaceSession`:

- New map `fileTabSessions: [TabID: FileEditorTabSession]` (a tab id lives in
  exactly one of the three maps).
- New `nextTabFileURL: URL?` override consumed in `handleDidCreateTab` (checked
  **before** the web/terminal branches).
- `func openFileTab(at fileURL: URL)`:
  1. Resolve to a canonical path. If an existing `FileEditorTabSession` has the
     same resolved path, `controller.selectTab(existing.key)` and return
     (dedup, like `openWebTab`).
  2. Else set `nextTabFileURL`, `controller.createTab(title: fileName,
     icon: "doc.text")`, clear the override.
- `handleDidCloseTab` also removes from `fileTabSessions`.
- `func fileTabSession(for:) -> FileEditorTabSession?` accessor; `openFileTabURLs`
  computed like `webTabURLs` (for the e2e dump).

`FileEditorTabSession` (`Sources/Dreamux/Models/FileEditorTabSession.swift`) —
`@MainActor @Observable`:

- Stored: `let fileURL: URL`, `var title: String`, `var isDirty: Bool`,
  and a lazily-built `WKWebView` configured with:
  - A `WKURLSchemeHandler` for scheme `app-monaco://` that serves the bundled
    Monaco assets from the resource bundle (see §5). Using a custom scheme
    (treated as a secure web origin) rather than `file://` is required so
    Monaco's language-service **web workers** load without CORS/worker
    restrictions.
  - A `WKScriptMessageHandler` (name `bridge`) receiving JSON messages:
    `{type: "ready"}` (Swift responds by pushing file contents + language +
    theme), `{type: "dirty", value: Bool}` (→ `isDirty`), and
    `{type: "save", text: String}` (→ Swift writes to `fileURL`, sets
    `isDirty = false`).
- Load flow: WKWebView loads `app-monaco://app/index.html`, which boots Monaco.
  On `ready`, Swift reads the file off disk and calls
  `editor.setValue(contents)` with the language id derived from the extension
  (`Self.language(forExtension:)`, a pure/testable map) and the theme
  (`vs` / `vs-dark`) from the current appearance.
- Save: ⌘S is handled by Monaco's keybinding → posts `save`; Swift writes
  atomically to `fileURL`. (A menu/command `File ▸ Save` maps to the same JS
  call via `evaluateJavaScript` so the standard ⌘S also works when the webview
  has focus.)
- Binary/oversized guard: before load, if the file is > ~2 MB or fails a UTF-8
  read, the session flags `unsupported` and the view shows a placeholder
  instead of Monaco.

### 5. Monaco asset bundling + custom scheme

- Vendor the Monaco `min` build under `vendor/monaco/` (the `vs/` loader +
  language/basic-languages, a few MB) plus a tiny hand-written
  `vendor/monaco/index.html` + `editor-boot.js` that:
  - configures the AMD loader against `app-monaco://app/vs`,
  - creates the editor filling the page,
  - wires `onDidChangeModelContent` → post `dirty`,
  - adds a ⌘S command → post `save`,
  - exposes `window.__setContents(text, language, theme)` for Swift to call.
- Declare it as a resource on the `Dreamux` target in `Package.swift`
  (`resources: [.copy("...Monaco...")]`; exact path via a `MonacoBundle`
  helper that locates it in `Bundle.module`).
- `MonacoSchemeHandler` (`Sources/Dreamux/Views/MonacoSchemeHandler.swift`) —
  a `WKURLSchemeHandler` mapping `app-monaco://app/<path>` to files in the
  Monaco resource directory, with correct MIME types (`.js`, `.css`, `.ttf`,
  `.html`). One handler instance can be shared across editor tabs.

### 6. Wiring in `TabContentView` + `ContentView`

- `TabContentView` gains a third branch: if `session.fileTabSession(for: tabId)`
  is non-nil → `FileEditorView(session:)` (an `NSViewRepresentable` around the
  session's `WKWebView`, exactly like `WebTabView`'s inner representable, plus
  the unsupported-file placeholder).
- `FileTreePanel.onOpenFile(url)` in `ContentView`:
  1. `guard let ws = store.activeWorkspace else { return }`
  2. `sidebarMode = .workspace` (so the new tab is on screen)
  3. `store.session(for: ws).openFileTab(at: url)`
- `FileTreeStore` is created once in `ContentView.init` (like `runConfig`/
  `signals`) and injected into `FileTreePanel`. It caches no roots — `roots(...)`
  and `children(...)` are computed on demand from the live `store`/`repoStore`
  values the panel passes in, so an active-feature change or refresh simply
  recomputes. The panel owns the tree's disclosure/expansion state.

## Components

| File | New/Edit | Responsibility |
|------|----------|----------------|
| `Sources/Dreamux/Models/FileNode.swift` | new | Lazily-expanding tree node (`url`, `name`, `isDirectory`, `isRepoRoot`). |
| `Sources/Dreamux/Models/FileTreeStore.swift` | new | `@MainActor @Observable`. `roots(for:repositories:)` resolves per-repo worktree paths for the active feature; `children(of:)` enumerates dirs (excludes `.git`/`.bare`, dirs-first sort). Pure/testable. |
| `Sources/Dreamux/Views/FileTreePanel.swift` | new | Native `List`/`DisclosureGroup` source list; header + refresh; file rows call `onOpenFile`; empty states. |
| `Sources/Dreamux/Models/FileEditorTabSession.swift` | new | `@MainActor @Observable` WKWebView-backed Monaco session: file load, dirty tracking, ⌘S save, language/theme, binary/oversize guard. `language(forExtension:)` pure. |
| `Sources/Dreamux/Views/MonacoSchemeHandler.swift` | new | `WKURLSchemeHandler` serving bundled Monaco assets over `app-monaco://`. |
| `vendor/monaco/` (+ `index.html`, `editor-boot.js`) | new | Vendored offline Monaco `min` build + boot glue. |
| `Sources/Dreamux/Models/WorkspaceSession.swift` | edit | Add `fileTabSessions` map + `nextTabFileURL`; `openFileTab(at:)` (dedup by resolved path); dispatch in `handleDidCreateTab` before web/terminal; cleanup in `handleDidCloseTab`; `fileTabSession(for:)`, `openFileTabURLs`. |
| `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` | edit | `TabContentView` third branch → `FileEditorView`. |
| `Sources/Dreamux/Views/ContentView.swift` | edit | `showFileTree` state + `.inspector` + toolbar toggle (⌥⌘E); build/inject `FileTreeStore`; `onOpenFile` wiring. |
| `Package.swift` | edit | Declare Monaco resources on the `Dreamux` target. |
| `Sources/Dreamux/E2E/*` | edit | Commands to toggle the inspector and open a file tab; expose `openFileTabURLs` in the state dump. |

## Behavior details / edge cases

- **No active feature / no linked worktrees**: panel shows the empty state;
  `onOpenFile` is unreachable (no rows). Toolbar toggle still works.
- **Feature switch while a file tab is open**: existing editor tabs stay open
  (they belong to their workspace's session, which persists); the tree re-roots
  to the newly-active feature. Opening the same relative file in a different
  feature opens a distinct tab (different absolute worktree path).
- **Dedup**: keyed on the resolved absolute file path, so the same file re-opens
  to its existing tab; two different repos' same-named files are distinct tabs.
- **Dirty + close**: closing a dirty editor tab discards unsaved changes in v1
  (no confirm dialog) — called out as a known v1 limitation, consistent with
  closing a terminal mid-command.
- **Save target**: writes go to the resolved worktree file (real path), never
  through the `features/‹feature›/` symlink dir, and never to `main`.
- **Theme**: initial theme from `NSApp.effectiveAppearance`; a later system
  appearance flip is not re-pushed in v1 (reopen to re-theme) — noted non-goal.
- **Symlinks/loops**: `children(of:)` does not follow directory symlinks into
  other roots; each repo root is enumerated independently.

## Testing

- **Unit — `FileTreeStore.roots(for:repositories:)`**: given a workspace with
  `linkedRepoIDs` and a temp project laying down `repos/‹repo›/‹feature›/`
  worktrees, emits one root per existing worktree in `linkedRepoIDs` order;
  omits repos without a worktree at that branch and repos not linked; returns
  `[]` for a `nil`/orphan workspace.
- **Unit — `FileTreeStore.children(of:)`**: dirs sorted before files, case-
  insensitive; `.git` and `.bare` excluded; other dotfiles included.
- **Unit — `FileEditorTabSession.language(forExtension:)`**: representative
  extensions map to Monaco language ids; unknown → `plaintext`.
- **Unit — `WorkspaceSession.openFileTab` dedup**: opening the same resolved
  path twice selects the existing tab (no second `fileTabSession`); different
  paths create distinct sessions. (Mirrors any existing `openWebTab` coverage.)
- **Manual / e2e**: launch with a multi-repo feature; toggle the panel (⌥⌘E),
  confirm each linked repo appears as a root; open a file from each repo,
  confirm two editor tabs open next to the terminal; edit + ⌘S, confirm the
  worktree file changed on disk; re-open the same file, confirm it re-focuses.
  Extend the e2e state dump with `openFileTabURLs` and capture a screenshot of
  the panel + editor tab.
