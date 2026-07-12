# Shortcut Hints, Search-Bar Contrast, Applet Shortcut Pair — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm complete)

## Problem

The add-rows (New Project, New workspace, New applet) don't advertise their
keyboard shortcuts the way the rail's search bar advertises ⌘K; the search
bar's fill (`Color.primary.opacity(0.04)`) barely reads against the dark
glass backdrop; applet creation has no shortcuts at all; and the rail's
studio section is titled "Studio" with a row that only opens the window.

## Decisions made during brainstorming

- Applet shortcut letter: **L** (mnemonic "app-L-et"). ⌘L = new applet in
  the current project; ⌘⇧L = new global applet in Applet Studio. ⌘A is
  system select-all, so A was ruled out; L, U, J, G were all free — L won.
- The rail's open-studio row is **replaced** by "+ Add global applet"
  (approved over keeping a separate "Open studio" row); launching the
  studio is covered by the collapsed-rail tile, ⌘⇧L, and a new palette
  command.

## 1. Shortcut hints on the add-rows

Every add-row gets the search bar's hint treatment — a trailing `Text` at
12pt medium, `.foregroundStyle(.secondary)` (the exact style of the ⌘K
hint in `ProjectsRail.swift` ~L100) — pushed to the row's right edge by
the row's existing `Spacer`:

| Row | Location | Hint |
|---|---|---|
| New Project | `ProjectsRail.swift` (~L60) | `⌘N` |
| New workspace | `PlansSpecsSection.newWorkspaceRow` (~L200) | `⌘P` |
| New applet | `AppsSection.newAppRow` (~L146) | `⌘L` |
| Add global applet | new rail row (§4) | `⇧⌘L` |
| New applet (studio) | `AppStudioView.newAppRow` (~L166) | `⇧⌘L` |

The rail's "New Project" row currently uses a plain `Label`; it is
restyled to the shared add-row shape (plus glyph 15pt semibold in a fixed
frame, 15pt label, secondary, hover wash `Color.primary.opacity(0.04)` on
cornerRadius 8) so all add-rows read as one family. Hint text uses the
glyph order macOS menus render: `⇧⌘L` (not `⌘⇧L`).

## 2. Search-bar background

The search button's fill changes from `Color.primary.opacity(0.04)` to
**`Color(nsColor: .windowBackgroundColor).opacity(0.8)`** — the same
surface color `panelCard` gives the content panels — so the field reads
as a raised control clearly distinct from the tinted-glass rail backdrop.
The existing `strokeBorder(Color.secondary.opacity(0.3))` stays.

## 3. ⌘L — New Applet (current project)

- File-menu item **"New Applet…"** directly after "New Plan…" in
  `ProjectCommands`' `.newItem` group, `keyboardShortcut("l", [.command])`,
  wired through a new `newAppletPresented: Binding<Bool>?` focused value —
  the exact pattern ⌘N/⌘P use. Disabled (nil binding) when no project
  window is focused.
- `ContentView` gains `@State showNewApplet` published as that focused
  value, plus its own `NewAppSheet` presentation — precedent: `showNewPlan`
  already has twin triggers in `WorkspaceSidebar` and `ContentView`. The
  sheet is constructed like `WorkspaceSidebar`'s (`library:
  appLibrary.applets` refreshed on present, `onAdopt` supported).
- On create, ContentView mirrors `WorkspaceSidebar.handleCreateApp`
  (~L1125): `session.applets.createLocal(name:description:icon:
  "shippingbox")` → `session.appletSession(for:).beginEditing(kickoff:)` →
  `sidebarMode = .app(applet.id)`. On adopt, mirrors `handleAdoptApp`
  (`session.applets.adopt(_:)`).

## 4. ⌘⇧L — New Global Applet + the rail section

- `Section("Studio")` in `ProjectsRail.swift` becomes
  **`Section("Applet Studio")`**.
- The open-studio row is replaced by a **"Add global applet"** row: plus
  glyph, 15pt secondary label, hover wash, trailing `⇧⌘L` hint,
  `.help("Create an applet in the Applet Studio library (⇧⌘L)")`.
- Behavior — single creation path via a consume-and-clear intent:

  ```swift
  /// Cross-window launch intents for the Applet Studio window. The rail
  /// row / ⇧⌘L menu item park an intent here and open the window;
  /// AppStudioView consumes-and-clears on appear (same idiom as
  /// E2EBridge.pending*). A plain static flag: one window, one intent.
  @MainActor
  @Observable
  final class AppStudioIntents {
      static let shared = AppStudioIntents()
      var pendingNewApplet = false
  }
  ```

  The row/menu action: `AppStudioIntents.shared.pendingNewApplet = true;
  openWindow(id: "app-studio")`. `AppStudioView` consumes it in `.onAppear`
  AND `.onChange(of: AppStudioIntents.shared.pendingNewApplet)` (the window
  may already be open) → `showNewApp = true`. Creation and the
  builder-agent kickoff stay exactly where they are today
  (`AppStudioView.handleCreate`).
- The menu item **"New Global Applet…"** lives in a new `AppletCommands`
  Commands struct using `@Environment(\.openWindow)` — no focused value, so
  **⌘⇧L is enabled from every window**, including App Studio itself and
  the Settings window. Placed in the `.newItem` group after "New Applet…",
  followed by the existing `Divider()`.
- Launcher coverage after removing the open-studio row: the collapsed
  rail's shippingbox tile (unchanged), ⌘⇧L, and the palette command (§5).

## 5. Palette additions

`paletteCommandCandidates()` in `ContentView.swift` gains three entries
(after "New Plan…", before "New Scratch Workspace"):

- "New Applet…" (icon `plus.app`) → `showNewApplet = true`
- "New Global Applet…" (icon `shippingbox`) →
  `AppStudioIntents.shared.pendingNewApplet = true; openWindow(id: "app-studio")`
- "Open Applet Studio" (icon `shippingbox`) → `openWindow(id: "app-studio")`

(`ContentView` already has `@Environment(\.openWindow)`.)

## 6. Testing

- One unit test for `AppStudioIntents` consume-and-clear semantics.
- Build + full unit suite + full e2e suite (regression only; no new
  scenario — the new commands surface in the palette's commands section,
  which `scenario_palette` already exercises structurally).
- Visual verification by relaunching the app: hints visible on all five
  rows, search bar clearly distinct, ⌘L/⌘⇧L round-trips.

## Out of scope

- Rebinding any existing shortcut; changes to `NewAppSheet` itself.
- e2e coverage of cross-window intent (would need multi-window driver
  support).
