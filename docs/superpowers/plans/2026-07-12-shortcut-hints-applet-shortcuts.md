# Shortcut Hints + Applet Shortcut Pair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Advertise shortcuts on every add-row (⌘N/⌘P/⌘L/⇧⌘L hints), make the rail search bar visually distinct, and add the applet creation pair — ⌘L (project applet) and ⌘⇧L (global applet via a retitled "Applet Studio" rail section).

**Architecture:** ⌘L copies the proven ⌘N/⌘P shape (menu item → focused binding → ContentView sheet). ⌘⇧L needs no focused value: it parks a consume-and-clear intent on a new `AppStudioIntents` singleton and opens the App Studio window, which consumes it and presents its existing NewAppSheet — one creation path, builder-agent kickoff untouched. Hints are trailing 12pt-medium secondary `Text`, the search bar's existing ⌘K pattern.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14 floor), SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-12-shortcut-hints-applet-shortcuts-design.md`

## Global Constraints

- macOS 14 floor; no new package dependencies; XCTest in `Tests/DreamuxTests`; executable target never links XCTest.
- Shortcut letter is **L**: ⌘L project applet, ⌘⇧L global applet. Hint text renders in macOS menu glyph order: `⌘N`, `⌘P`, `⌘L`, `⇧⌘L`.
- Hint style everywhere: `Text("<hint>").font(.system(size: 12, weight: .medium))`, inheriting the row's `.secondary` foreground, pushed right by the row's existing `Spacer`.
- Menu shortcuts use the `Commands` + focused-binding pattern (never `.keyboardShortcut` on content buttons); ⌘⇧L is the exception by design — it uses `@Environment(\.openWindow)` inside the Commands struct and is never disabled.
- **Plan-level deviation from the spec (approved rationale):** the spec's separate `AppletCommands` struct cannot interleave into `ProjectCommands`' `CommandGroup(replacing: .newItem)`; "New Global Applet…" therefore lives inside `ProjectCommands`, right after "New Applet…". Spec placement intent (menu order) wins over spec wiring prose.
- **Second plan-level deviation:** the spec's "restyle the New Project row to the shared add-row shape" is overridden — rail rows are native `List(.sidebar)` rows, and a custom 28pt-frame row would break icon-column alignment with the project rows; the row keeps its `Label` and gains only the HStack-wrapped trailing hint (matches the project's native-controls preference).
- Rail rows are native `List(.sidebar)` rows — keep `Label` for leading icon/text so the icon column stays aligned; hints wrap the Label in an HStack rather than rebuilding the row.
- Commit style `Prefix: summary`; stage ONLY named files; never touch `.claude/worktrees/`.
- Build: `swift build`. Tests: `swift test --filter <Class>` / full `swift test`. E2E: `Scripts/e2e/run-e2e.sh`.
- Line anchors are approximate (main @ 6421425) — match on quoted code, not numbers.

---

### Task 1: AppStudioIntents + studio-side consumption

**Files:**
- Create: `Sources/Dreamux/Models/AppStudioIntents.swift`
- Modify: `Sources/Dreamux/Views/Applets/AppStudioView.swift` (`.onAppear` ~line 33, modifier chain around it)
- Test: `Tests/DreamuxTests/AppStudioIntentsTests.swift`

**Interfaces:**
- Consumes: `AppStudioView`'s existing `@State private var showNewApp` and its `.sheet(isPresented: $showNewApp)` (unchanged).
- Produces: `@MainActor @Observable final class AppStudioIntents` with `static let shared`, `var pendingNewApplet: Bool`, and `func consumePendingNewApplet() -> Bool` — Tasks 3 and 4 set `AppStudioIntents.shared.pendingNewApplet = true` before `openWindow(id: "app-studio")`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/AppStudioIntentsTests.swift
import XCTest
@testable import Dreamux

@MainActor
final class AppStudioIntentsTests: XCTestCase {
    func testConsumeClearsAndReportsOnce() {
        // A fresh instance, not .shared — keeps the singleton clean across tests.
        let intents = AppStudioIntents()
        XCTAssertFalse(intents.consumePendingNewApplet())
        intents.pendingNewApplet = true
        XCTAssertTrue(intents.consumePendingNewApplet())
        XCTAssertFalse(intents.pendingNewApplet)
        XCTAssertFalse(intents.consumePendingNewApplet())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStudioIntentsTests 2>&1 | tail -10`
Expected: compile error — `AppStudioIntents` not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/AppStudioIntents.swift
import Foundation
import Observation

/// Cross-window launch intents for the Applet Studio window. Callers that
/// can't reach the studio's view state (the projects rail's add row, the
/// ⇧⌘L menu item, the ⌘K palette) park an intent here and open the
/// window; AppStudioView consumes-and-clears it — the same idiom as
/// E2EBridge's pending* fields. A singleton is enough: there is exactly
/// one Applet Studio window.
@MainActor
@Observable
final class AppStudioIntents {
    static let shared = AppStudioIntents()
    var pendingNewApplet = false

    /// True exactly once per parked intent — reading clears it.
    func consumePendingNewApplet() -> Bool {
        guard pendingNewApplet else { return false }
        pendingNewApplet = false
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppStudioIntentsTests 2>&1 | tail -5`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 5: Consume the intent in AppStudioView**

In `Sources/Dreamux/Views/Applets/AppStudioView.swift`, the chain currently has `.onAppear { library.refresh() }` (directly above `.sheet(isPresented: $showNewApp)`). Replace that one line with:

```swift
.onAppear {
    library.refresh()
    // A parked ⇧⌘L / rail-row intent from before this window existed.
    if AppStudioIntents.shared.consumePendingNewApplet() { showNewApp = true }
}
// The window may ALREADY be open when the intent is parked — onAppear
// won't re-fire, so also watch the flag.
.onChange(of: AppStudioIntents.shared.pendingNewApplet) { _, pending in
    if pending, AppStudioIntents.shared.consumePendingNewApplet() { showNewApp = true }
}
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Models/AppStudioIntents.swift Sources/Dreamux/Views/Applets/AppStudioView.swift Tests/DreamuxTests/AppStudioIntentsTests.swift
git commit -m "Applets: AppStudioIntents cross-window launch intent + studio consumption"
```

---

### Task 2: ⌘L — New Applet in the current project

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift` (state ~line 50, focused publish ~line 319, sheets ~line 288, handlers near `openFile` ~line 1150, focused keys ~line 1460)
- Modify: `Sources/Dreamux/DreamuxApp.swift` (ProjectCommands ~line 280)

**Interfaces:**
- Consumes: `NewAppSheet(library:onCreate:onAdopt:onCancel:)` (`library: [Applet]`, `onCreate: (String, String) -> Void`); `session.applets.createLocal(name:description:icon:) throws -> Applet`; `session.appletSession(for:) -> AppletSession` (`.beginEditing(kickoff:)`); `session.applets.adopt(_:) throws -> Applet`; `session.appLibrary.refresh()` / `.applets`; `AppletScaffold.kickoffPrompt(appletName:description:)`; `SidebarMode.app(UUID)`.
- Produces: `FocusedValues.newAppletPresented: Binding<Bool>?`; ContentView `@State showNewApplet` — Task 4's palette command sets `showNewApplet = true`.

- [ ] **Step 1: Add state, focused key, and publish**

In `ContentView.swift`, next to `@State private var showNewPlan` add:

```swift
/// New-applet sheet fired from ⌘L / the palette — window-level twin of
/// `WorkspaceSidebar.showNewApp`, same second-trigger pattern as
/// `showNewPlan`.
@State private var showNewApplet = false
/// Failure surface for the ⌘L create/adopt path — ContentView's copy of
/// `WorkspaceSidebar.addError`.
@State private var appletActionError: String?
```

In the focused-values section at the bottom (after `PalettePresentedKey`), add:

```swift
private struct NewAppletPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
```

and inside the existing `extension FocusedValues`:

```swift
var newAppletPresented: Binding<Bool>? {
    get { self[NewAppletPresentedKey.self] }
    set { self[NewAppletPresentedKey.self] = newValue }
}
```

In `body`, directly after `.focusedSceneValue(\.newPlanPresented, $showNewPlan)`:

```swift
.focusedSceneValue(\.newAppletPresented, $showNewApplet)
```

- [ ] **Step 2: Present the sheet and handle create/adopt**

After the `.sheet(isPresented: $showCreateProject) { ... }` block, add:

```swift
// Refresh the library BEFORE the sheet builds so its Adopt list is
// current (the sidebar's row does the same refresh inline).
.onChange(of: showNewApplet) { _, presented in
    if presented { session.appLibrary.refresh() }
}
.sheet(isPresented: $showNewApplet) {
    NewAppSheet(
        library: session.appLibrary.applets,
        onCreate: { name, description in
            showNewApplet = false
            createProjectApplet(name: name, description: description)
        },
        onAdopt: { applet in
            showNewApplet = false
            adoptProjectApplet(applet)
        },
        onCancel: { showNewApplet = false }
    )
}
.alert(
    "Couldn't add applet",
    isPresented: Binding(
        get: { appletActionError != nil },
        set: { if !$0 { appletActionError = nil } }
    ),
    presenting: appletActionError
) { _ in
    Button("OK", role: .cancel) {}
} message: { error in
    Text(error)
}
```

Near `openFile(_:atLine:)`, add the handlers:

```swift
/// Mirrors `WorkspaceSidebar.handleCreateApp` for the ⌘L / palette path:
/// scaffold a local-born applet, spawn its builder agent, open its host.
private func createProjectApplet(name: String, description: String) {
    do {
        let applet = try session.applets.createLocal(
            name: name, description: description, icon: "shippingbox")
        session.appletSession(for: applet).beginEditing(
            kickoff: AppletScaffold.kickoffPrompt(
                appletName: name, description: description))
        sidebarMode = .app(applet.id)
    } catch {
        appletActionError = error.localizedDescription
    }
}

/// Mirrors `WorkspaceSidebar.handleAdoptApp` (no agent on adopt).
private func adoptProjectApplet(_ library: Applet) {
    do {
        let adopted = try session.applets.adopt(library)
        sidebarMode = .app(adopted.id)
    } catch {
        appletActionError = error.localizedDescription
    }
}
```

- [ ] **Step 3: Add the menu item**

In `DreamuxApp.swift` `ProjectCommands`, add the focused binding next to the existing two:

```swift
@FocusedBinding(\.newAppletPresented) private var newAppletPresented: Bool?
```

and after the "New Plan…" button (before the `Divider()`):

```swift
Button("New Applet…") {
    newAppletPresented = true
}
.keyboardShortcut("l", modifiers: [.command])
.disabled(newAppletPresented == nil)
```

- [ ] **Step 4: Build + regression**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/DreamuxApp.swift
git commit -m "Applets: ⌘L New Applet menu item via focused binding + window-level sheet"
```

---

### Task 3: ⌘⇧L — New Global Applet + Applet Studio rail section

**Files:**
- Modify: `Sources/Dreamux/DreamuxApp.swift` (ProjectCommands)
- Modify: `Sources/Dreamux/Views/ProjectsRail.swift` (Studio section ~line 69, New Project row ~line 60)

**Interfaces:**
- Consumes: `AppStudioIntents.shared.pendingNewApplet` (Task 1); `openWindow(id: "app-studio")`.
- Produces: nothing new — Task 4 reuses the same two-line action for the palette.

- [ ] **Step 1: Add the ⌘⇧L menu item**

In `ProjectCommands` (DreamuxApp.swift), add an environment action next to the focused bindings:

```swift
@Environment(\.openWindow) private var openWindow
```

and after the "New Applet…" button (still before the `Divider()`):

```swift
// No focused value on purpose: parking an intent + opening the window
// works from EVERY window (App Studio and Settings included), so the
// item is never disabled.
Button("New Global Applet…") {
    AppStudioIntents.shared.pendingNewApplet = true
    openWindow(id: "app-studio")
}
.keyboardShortcut("l", modifiers: [.command, .shift])
```

- [ ] **Step 2: Retitle the rail section and swap its row**

In `ProjectsRail.swift`, replace the whole `Section("Studio") { ... }` block with:

```swift
Section("Applet Studio") {
    Button {
        AppStudioIntents.shared.pendingNewApplet = true
        openWindow(id: "app-studio")
    } label: {
        HStack {
            Label("Add global applet", systemImage: "plus")
            Spacer(minLength: 0)
            Text("⇧⌘L")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .help("Create an applet in the Applet Studio library (⇧⌘L)")
}
```

(Keep the comment above the section, updating its wording to describe the add-row: the library keeps its own titled section; its row now creates rather than merely opens — launching is covered by ⇧⌘L, the palette, and the collapsed rail's tile.)

- [ ] **Step 3: Hint on the New Project row**

Still in `ProjectsRail.swift`, replace the New Project button's label:

```swift
Button {
    showCreate = true
} label: {
    HStack {
        Label("New Project", systemImage: "plus")
        Spacer(minLength: 0)
        Text("⌘N")
            .font(.system(size: 12, weight: .medium))
    }
    .foregroundStyle(.secondary)
}
.buttonStyle(.plain)
.help("Create a new project (⌘N)")
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3` → `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/DreamuxApp.swift Sources/Dreamux/Views/ProjectsRail.swift
git commit -m "Applets: ⇧⌘L New Global Applet; rail section becomes Applet Studio add-row"
```

---

### Task 4: Foot-row hints, search-bar fill, palette commands

**Files:**
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift` (`newWorkspaceRow` ~line 200)
- Modify: `Sources/Dreamux/Views/Applets/AppsSection.swift` (`newAppRow` ~line 146)
- Modify: `Sources/Dreamux/Views/Applets/AppStudioView.swift` (`newAppRow` ~line 166)
- Modify: `Sources/Dreamux/Views/ProjectsRail.swift` (search button fill ~line 106)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (`paletteCommandCandidates()` ~line 1199)

**Interfaces:**
- Consumes: `showNewApplet` (Task 2), `AppStudioIntents.shared` (Task 1), ContentView's existing `@Environment(\.openWindow)`.
- Produces: nothing downstream.

- [ ] **Step 1: Hints on the three foot rows**

In each of the three rows below, insert the hint `Text` directly after the row's `Spacer(minLength: 0)` (the enclosing HStack already carries `.foregroundStyle(.secondary)`, so the hint inherits it):

`PlansSpecsSection.newWorkspaceRow`:

```swift
Spacer(minLength: 0)
Text("⌘P")
    .font(.system(size: 12, weight: .medium))
```

`AppsSection.newAppRow`:

```swift
Spacer(minLength: 0)
Text("⌘L")
    .font(.system(size: 12, weight: .medium))
```

`AppStudioView.newAppRow`:

```swift
Spacer(minLength: 0)
Text("⇧⌘L")
    .font(.system(size: 12, weight: .medium))
```

- [ ] **Step 2: Search-bar fill**

In `ProjectsRail.swift`, in the search button's `.background`, replace:

```swift
.fill(Color.primary.opacity(0.04))
```

with:

```swift
// Card-surface fill (the panels' color) so the field stands off the
// tinted-glass rail backdrop — primary-0.04 was invisible against it.
.fill(Color(nsColor: .windowBackgroundColor).opacity(0.8))
```

- [ ] **Step 3: Palette commands**

In `ContentView.paletteCommandCandidates()`, insert after the "New Plan…" candidate and before "New Scratch Workspace":

```swift
PaletteCandidate(id: "command-new-applet", title: "New Applet…",
                 subtitle: nil, icon: "plus.app") { showNewApplet = true },
PaletteCandidate(id: "command-new-global-applet", title: "New Global Applet…",
                 subtitle: nil, icon: "shippingbox") {
    AppStudioIntents.shared.pendingNewApplet = true
    openWindow(id: "app-studio")
},
PaletteCandidate(id: "command-open-applet-studio", title: "Open Applet Studio",
                 subtitle: nil, icon: "shippingbox") {
    openWindow(id: "app-studio")
},
```

- [ ] **Step 4: Build + full regression + e2e**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test 2>&1 | tail -3` → 0 failures.
Run: `Scripts/e2e/run-e2e.sh 2>&1 | tail -20` → exit 0, all scenarios PASS (the palette scenario's empty-query commands section now leads with New Project…/New Plan…/New Applet…/New Global Applet…/Open Applet Studio — its assertions are section-presence-based and unaffected). If a scenario UNRELATED to this diff fails, retry once; if it repeats, report DONE_WITH_CONCERNS with the log tail. If the app won't launch because another Dreamux instance is running, STOP and report BLOCKED — never kill a running Dreamux.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/Applets/AppsSection.swift Sources/Dreamux/Views/Applets/AppStudioView.swift Sources/Dreamux/Views/ProjectsRail.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Palette/rail: shortcut hints on add-rows, card-fill search bar, applet palette commands"
```

---

## Verification (after all tasks)

- `swift test` green; `Scripts/e2e/run-e2e.sh` green.
- Manual (relaunched app): hints visible on all five rows; search bar clearly distinct from the backdrop; ⌘L opens the project NewAppSheet (rail expanded or collapsed); ⌘⇧L opens App Studio with its sheet up — including when the studio window is already open and when it's focused; palette "studio" query surfaces the three new commands.
