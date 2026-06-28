# Remove the Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete both "Home" surfaces (the in-window project grid and the standalone `id:"home"` window), folding launch routing and the zero-projects landing into a launch gate plus a minimal `WelcomeView` on the single project `WindowGroup`.

**Architecture:** One `WindowGroup("Project", id: "project", for: UUID.self)` becomes the only scene. At launch it opens with `projectID == nil`; a `LaunchGate` resolves the destination (e2e auto-open → last-opened/first project → set the binding; no projects → `WelcomeView`) by rewriting the same window's binding in place. The redundant in-window Home row, its detail-pane overlay, and `HomeView` itself are removed.

**Tech Stack:** Swift 6 / SwiftUI, SwiftPM (`swift build`, `swift test`), `./Scripts/make-app.sh debug` to assemble the runnable bundle, `Scripts/e2e/run-e2e.sh` for the automation harness.

## Global Constraints

- Platform floor: macOS 14 (`Package.swift`). Swift tools 6.0.
- SwiftUI view-layer tasks are verified by **compile (`swift build`) + manual run**, not unit tests — there is no testable seam inside these views. Only `LaunchDestination` (pure logic) gets a real red/green unit cycle.
- Concurrent-session hygiene: stage only the exact files named in each task's commit (`git add <paths>`), never `git add -A`. The working tree has unrelated pre-existing edits to `WorkspaceSidebar.swift` and others that must not be swept into these commits.
- Preserve the e2e contract: `CLAYSPACE_E2E_AUTOOPEN=<folder name>` must still open that project's window at launch. The driver waits on `project window for <name>`.
- `CreateProjectSheet` init is `CreateProjectSheet(store: ProjectStore, onCreated: (Project) -> Void)` — note `onCreated`, not `onCreate`.

---

### Task 1: Rename `LaunchDestination.home` → `.welcome`

**Files:**
- Modify: `Sources/Clayspace/Models/LaunchDestination.swift:7-18`
- Test: `Tests/ClayspaceTests/LaunchDestinationTests.swift:15-17`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum LaunchDestination { case welcome; case project(UUID) }` and `static func resolve(lastOpenedID: UUID?, projects: [Project]) -> LaunchDestination`, returning `.welcome` for an empty store. Task 3's `LaunchGate` switches over this.

`SidebarItem.home` in `ProjectsRail` is a *different* enum — leave it for Task 4.

- [ ] **Step 1: Update the test to expect `.welcome` (failing)**

In `Tests/ClayspaceTests/LaunchDestinationTests.swift`, rename the method and assertions:

```swift
    func testEmptyStoreLandsOnWelcome() {
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: nil, projects: []), .welcome)
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: UUID(), projects: []), .welcome)
    }
```

- [ ] **Step 2: Run the test, verify it fails to compile**

Run: `swift test --filter LaunchDestinationTests 2>&1 | tail -20`
Expected: build error — `type 'LaunchDestination' has no member 'welcome'`.

- [ ] **Step 3: Rename the enum case**

In `Sources/Clayspace/Models/LaunchDestination.swift`, change the case and its doc comment:

```swift
/// Where a fresh launch should land. `welcome` (the create-your-first-
/// project screen) is shown only when there are no projects to open;
/// otherwise launch jumps straight into a project window — the remembered
/// last-opened project when it still exists, else the first project in
/// store order.
enum LaunchDestination: Equatable {
    case welcome
    case project(UUID)

    static func resolve(lastOpenedID: UUID?, projects: [Project]) -> LaunchDestination {
        guard !projects.isEmpty else { return .welcome }
        if let lastOpenedID, projects.contains(where: { $0.id == lastOpenedID }) {
            return .project(lastOpenedID)
        }
        return .project(projects[0].id)
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `swift test --filter LaunchDestinationTests 2>&1 | tail -20`
Expected: all `LaunchDestinationTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Models/LaunchDestination.swift Tests/ClayspaceTests/LaunchDestinationTests.swift
git commit -m "Rename LaunchDestination.home to .welcome"
```

---

### Task 2: Add `WelcomeView`

**Files:**
- Create: `Sources/Clayspace/Views/WelcomeView.swift`

**Interfaces:**
- Consumes: `ProjectStore`, `CreateProjectSheet(store:onCreated:)`.
- Produces: `struct WelcomeView: View { init(store: ProjectStore, onOpenProject: @escaping (UUID) -> Void) }`. Task 3's `LaunchGate` renders it and passes `onOpenProject: { projectID = $0 }`.

This is a leaf view; the verification is that the package still compiles with it present (it is not wired up until Task 3).

- [ ] **Step 1: Create the file**

Create `Sources/Clayspace/Views/WelcomeView.swift`:

```swift
import SwiftUI

/// First-run / zero-projects landing. Shown by `LaunchGate` when the
/// store has no projects to open. It deliberately does *not* list
/// projects (there are none) — it only invites the user to create their
/// first, after which the launch gate routes the window into it.
struct WelcomeView: View {
    let store: ProjectStore
    /// Switch this window to the freshly created project.
    let onOpenProject: (UUID) -> Void

    @State private var showCreate = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No projects yet").font(.headline)
            Text("Create your first project to spin up a fresh workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create Project") { showCreate = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: [.command])
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .onAppear { store.refresh() }
        .sheet(isPresented: $showCreate) {
            CreateProjectSheet(store: store) { project in
                onOpenProject(project.id)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!` (a warning that `WelcomeView` is unused is acceptable — it is wired up in Task 3).

- [ ] **Step 3: Commit**

```bash
git add Sources/Clayspace/Views/WelcomeView.swift
git commit -m "Add WelcomeView for the zero-projects landing"
```

---

### Task 3: Replace the standalone Home window with an in-WindowGroup launch gate

**Files:**
- Modify: `Sources/Clayspace/ClayspaceApp.swift:22-105`

**Interfaces:**
- Consumes: `WelcomeView(store:onOpenProject:)` (Task 2), `LaunchDestination.resolve` / `.welcome` (Task 1), `LastOpenedProject.load()`, `E2EMode.autoOpenProjectName`, `ProjectWindow(project:onSwitchProject:)`.
- Produces: the only scene is now `WindowGroup("Project", id: "project", for: UUID.self)`. `HomeView` is still referenced by `ContentView`/`ProjectsRail`/`ProjectWindow` until Task 4, so it is **not** deleted here.

After this task the `id:"home"` window and ⇧⌘0 are gone; launch routes through `LaunchGate`. The in-window Home row still works (removed in Task 4) — that's expected mid-flight.

- [ ] **Step 1: Rewrite the `body` scene and helpers in `ClayspaceApp.swift`**

Replace the `var body: some Scene { ... }` block (lines 22-47) with a single scene that delegates to `ProjectRootView`:

```swift
    var body: some Scene {
        WindowGroup("Project", id: "project", for: UUID.self) { $projectID in
            ProjectRootView(projectID: $projectID, projects: projects)
        }
        .commands {
            ProjectCommands()
            IntegrationCommands()
            NotificationCommands()
        }
    }
```

- [ ] **Step 2: Add `ProjectRootView` and `LaunchGate`**

Add these to `ClayspaceApp.swift` (e.g. just below the `ClayspaceApp` struct):

```swift
// MARK: - Window root

/// Routes a project window between three states: a live project, the
/// launch gate (no project bound — launch or after the last project was
/// deleted), or the missing-project fallback (the bound project's folder
/// vanished, usually deleted from another window).
private struct ProjectRootView: View {
    @Binding var projectID: UUID?
    let projects: ProjectStore

    var body: some View {
        if let id = projectID {
            if let project = projects.project(id: id) {
                ProjectWindow(
                    project: project,
                    onSwitchProject: { projectID = $0 }
                )
                .environment(projects)
                .frame(minWidth: 720, minHeight: 480)
            } else {
                MissingProjectView(onContinue: { projectID = nil })
                    .frame(minWidth: 480, minHeight: 320)
            }
        } else {
            LaunchGate(projectID: $projectID, projects: projects)
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Decides where a project-less window lands. With projects present it
/// rewrites the window's binding to the right one (routing straight into
/// it); with none it shows `WelcomeView`. This replaces the old Home
/// window's one-shot launch redirect — with no Home to return to,
/// re-resolving a nil window is always correct.
private struct LaunchGate: View {
    @Binding var projectID: UUID?
    let projects: ProjectStore

    var body: some View {
        Group {
            if projects.projects.isEmpty {
                WelcomeView(store: projects, onOpenProject: { projectID = $0 })
            } else {
                Color(NSColor.windowBackgroundColor)
            }
        }
        .onAppear(perform: resolve)
    }

    private func resolve() {
        projects.refresh()
        // e2e convenience: jump straight into the named project's window
        // so drivers don't script project selection. No-op when the name
        // doesn't match a discovered project.
        if let name = E2EMode.autoOpenProjectName,
           let match = projects.projects.first(where: { $0.name == name }) {
            projectID = match.id
            return
        }
        switch LaunchDestination.resolve(
            lastOpenedID: LastOpenedProject.load(),
            projects: projects.projects
        ) {
        case .project(let id):
            projectID = id
        case .welcome:
            break // WelcomeView is already on screen.
        }
    }
}
```

- [ ] **Step 3: Rewrite `MissingProjectView` to clear the binding instead of opening Home**

Replace the existing `MissingProjectView` (lines 64-89) with:

```swift
// MARK: - Missing project fallback

private struct MissingProjectView: View {
    /// Clear this window's project so the launch gate re-resolves
    /// (routing to another project, or Welcome when none remain).
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Project unavailable").font(.headline)
            Text("This project's folder is missing or has been removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Replace `HomeCommands` with `NotificationCommands` (drop "Show Home"/⇧⌘0)**

Replace the `HomeCommands` struct (lines 91-105) with:

```swift
// MARK: - App menu commands

private struct NotificationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Notification Settings…") {
                NotificationManager.shared.openSystemNotificationSettings()
            }
        }
    }
}
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`. (`openWindow(id: "home")` calls still in `ProjectsRail`/`HomeView` compile fine — `openWindow(id:)` takes any string — and are removed in Task 4/5.)

- [ ] **Step 6: Manually verify launch routing**

Run:
```bash
./Scripts/make-app.sh debug && open ./Clayspace.app
```
Expected: the app opens **directly** into a project window (your last-opened project) — no standalone "Clayspace" Home window. Confirm the **⇧⌘0** shortcut no longer opens anything (the menu item is gone). Quit the app afterward.

- [ ] **Step 7: Commit**

```bash
git add Sources/Clayspace/ClayspaceApp.swift
git commit -m "Replace standalone Home window with an in-WindowGroup launch gate"
```

---

### Task 4: Remove the in-window Home and widen project selection to `UUID?`

**Files:**
- Modify: `Sources/Clayspace/Views/ContentView.swift:14-185`
- Modify: `Sources/Clayspace/Views/ProjectsRail.swift:1-189`
- Modify: `Sources/Clayspace/Views/ProjectWindow.swift:11-89`

**Interfaces:**
- Consumes: `onSelect`/`onSwitchProject` widen to `(UUID?) -> Void` so the rail can clear the window after the last project is deleted.
- Produces: `ContentView` no longer references `HomeView`; `ProjectWindow` no longer calls `HomeView.disarmLaunchRedirect()`; `ProjectsRail` has no `Home` row and selects on a plain `UUID?`. After this task **nothing references `HomeView`**.

These three files must change together: the signature widening and the removal of `showingHome` ripple across all three, so a single commit keeps the build green.

- [ ] **Step 1: Simplify `ContentView`**

In `Sources/Clayspace/Views/ContentView.swift`:

a) Widen the stored closure (line 19): `let onSwitchProject: (UUID?) -> Void` and the `init` parameter (line 35): `onSwitchProject: @escaping (UUID?) -> Void`.

b) Delete the `showingHome` state (line 24): remove `@State private var showingHome = false`.

c) In the `ProjectsRail(...)` call (lines 75-80), remove the `showingHome: $showingHome,` argument so it reads:

```swift
            ProjectsRail(
                projects: projects,
                currentProjectID: currentProjectID,
                onSelect: onSwitchProject
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
```

d) Simplify the title/subtitle (lines 93-94):

```swift
        .navigationTitle(currentProject?.name ?? "")
        .navigationSubtitle(currentProject?.rootPath.path ?? "")
```

e) In `.onChange(of: sidebarMode)` (lines 111-117), drop the `showingHome = false` line and its comment, keeping the e2e bridge sync:

```swift
        .onChange(of: sidebarMode) { _, newValue in
            e2eBridge?.currentSidebarMode = newValue
        }
```

f) Delete the entire `.onChange(of: store.activeID) { ... showingHome = false }` modifier (lines 118-121).

g) Replace `detail: { detailColumn }` (line 91) with `detail: { mainPane }`, and delete the whole `detailColumn` computed property (lines 124-150).

- [ ] **Step 2: Simplify `ProjectsRail`**

In `Sources/Clayspace/Views/ProjectsRail.swift`:

a) Delete the `SidebarItem` enum (lines 7-10).

b) Change the stored properties (lines 23-31): remove `@Binding var showingHome: Bool`, widen `let onSelect: (UUID?) -> Void`, and remove `@Environment(\.dismissWindow) private var dismissWindow` (keep `@Environment(\.openWindow)` — `openInNewWindow` still uses it).

c) Replace the `List` (lines 35-64): drop the `Home` label row; tag rows by `project.id`:

```swift
        List(selection: selectionBinding) {
            Section("Projects") {
                ForEach(projects.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .tag(project.id)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(project.rootPath.path)
                        .contextMenu {
                            Button("Open in New Window") {
                                openInNewWindow(project.id)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) {
                                pendingDelete = project
                            }
                        }
                }
            }
        }
```

d) Replace `selectionBinding` (lines 111-126) with a plain `UUID?` binding:

```swift
    /// Bridges the native list selection to the window's current project.
    /// Picking a *different* project routes through `onSelect`, which
    /// rewrites the WindowGroup binding and rebuilds the window.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { currentProjectID },
            set: { newValue in
                if let id = newValue, id != currentProjectID { onSelect(id) }
            }
        )
    }
```

e) In `deleteProject` (lines 152-167), replace the empty-list branch so it clears the window instead of opening Home:

```swift
        guard wasCurrent else { return }
        if let fallback = projects.projects.first {
            onSelect(fallback.id)
        } else {
            // No projects left — clear this window so the launch gate
            // re-resolves to the Welcome screen. A project window can't
            // exist without a project.
            onSelect(nil)
        }
```

- [ ] **Step 3: Simplify `ProjectWindow`**

In `Sources/Clayspace/Views/ProjectWindow.swift`:

a) Widen `onSwitchProject` everywhere it appears in this file (lines 13, 31, 33, 41) from `(UUID) -> Void` to `(UUID?) -> Void` — the `ProjectWindow` property, `ProjectWindowContents` property, and the `init` parameter.

b) In `ProjectWindowContents`'s `.onAppear` (line 67), delete the `HomeView.disarmLaunchRedirect()` line (keep `LastOpenedProject.record(project.id)` directly above it).

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`.

- [ ] **Step 5: Manually verify the sidebar**

Run:
```bash
./Scripts/make-app.sh debug && open ./Clayspace.app
```
Expected: the project sidebar shows **no "Home" row** — only the "Projects" section and the "New Project" bar. Clicking another project still switches the window. Quit afterward.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clayspace/Views/ContentView.swift Sources/Clayspace/Views/ProjectsRail.swift Sources/Clayspace/Views/ProjectWindow.swift
git commit -m "Remove the in-window Home and clear-to-Welcome on last delete"
```

---

### Task 5: Delete `HomeView`, update docs, and verify end-to-end

**Files:**
- Delete: `Sources/Clayspace/Views/HomeView.swift`
- Modify: `Scripts/e2e/PROTOCOL.md` (the `CLAYSPACE_E2E_AUTOOPEN` row)

**Interfaces:**
- Consumes: nothing references `HomeView` after Task 4.
- Produces: `HomeView` and `ProjectCard` no longer exist.

- [ ] **Step 1: Confirm `HomeView` is unreferenced**

Run: `grep -rn "HomeView\|ProjectCard\|showingHome\|disarmLaunchRedirect\|id: \"home\"" Sources --include="*.swift"`
Expected: no matches.

- [ ] **Step 2: Delete the file**

```bash
git rm Sources/Clayspace/Views/HomeView.swift
```

- [ ] **Step 3: Update the e2e protocol doc**

In `Scripts/e2e/PROTOCOL.md`, update the `CLAYSPACE_E2E_AUTOOPEN` description so it no longer references the Home view. Replace the sentence "The Home view looks the name up in the projects root and opens that project's window (dismissing Home), so drivers don't script the project grid." with:

```
The launch gate looks the name up in the projects root and opens that project's window directly, so drivers don't have to script project selection.
```

- [ ] **Step 4: Build and run the full unit suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: `Build complete!` and all tests pass (no `HomeView`-related failures).

- [ ] **Step 5: Manual run (per the `run` skill)**

Run:
```bash
./Scripts/make-app.sh debug && open ./Clayspace.app
```
Expected: app opens directly into a project window; no Home window, no Home sidebar row, ⇧⌘0 does nothing. Quit afterward.

- [ ] **Step 6: Run the e2e harness**

Run: `./Scripts/e2e/run-e2e.sh 2>&1 | tail -30`
Expected: the suite passes — in particular the launch scenario that waits for `project window for <name>` (auto-open still works through the launch gate).

- [ ] **Step 7: Commit**

```bash
git add Sources/Clayspace/Views/HomeView.swift Scripts/e2e/PROTOCOL.md
git commit -m "Delete HomeView and update the e2e auto-open doc"
```

---

## Self-Review

**Spec coverage:**
- In-window Home removal → Task 4 (ContentView overlay + ProjectsRail row). ✓
- Standalone Home window + ⇧⌘0 removal → Task 3 (scene + `NotificationCommands`). ✓
- Launch gate + e2e auto-open → Task 3 (`LaunchGate.resolve`). ✓
- `WelcomeView` zero-projects landing → Task 2, wired in Task 3. ✓
- Delete-last-project fallback → Task 4 (`onSelect(nil)`). ✓
- `MissingProjectView` reroute → Task 3. ✓
- `LaunchDestination.home` → `.welcome` rename + test → Task 1. ✓
- `HomeView` deletion → Task 5. ✓
- PROTOCOL.md doc → Task 5. ✓
- `LastOpenedProject.record` retained → untouched in Task 4 (Step 3b keeps it). ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `onSwitchProject`/`onSelect` are `(UUID?) -> Void` in ContentView, ProjectsRail, and ProjectWindow (Task 4) and consumed by `ProjectRootView`'s `{ projectID = $0 }` (Task 3, type-checks against the `UUID?` binding both before and after the widening). `WelcomeView(store:onOpenProject:)` matches its call site in `LaunchGate`. `MissingProjectView(onContinue:)` matches `ProjectRootView`. `LaunchDestination.welcome` is produced in Task 1 and switched on in Task 3. ✓
