# Skip Home at Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch lands directly in the last-used project window; the projects rail gains "New Project" and "Move to Trash" so Home demotes to a zero-project onboarding screen.

**Architecture:** A pure `LaunchDestination.resolve` helper decides where launch lands; `HomeView.task` performs a one-shot redirect using it (generalizing the existing e2e auto-open pattern, since the macOS 14 target rules out `.defaultLaunchBehavior`). The `CreateProjectSheet` flow is extracted out of `HomeView` into a self-contained shared component so `ProjectsRail` can present it too, and the rail's AppKit context menu gains a delete action with the confirmation alert owned by the rail.

**Tech Stack:** SwiftUI (macOS 14 target), AppKit (rail rows), XCTest, SwiftPM. Build with `swift build`, test with `swift test`, e2e via `./Scripts/e2e/run-e2e.sh`.

**Spec:** `docs/superpowers/specs/2026-06-12-skip-home-launch-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/Clayspace/Models/LaunchDestination.swift` | Create | Pure launch-target resolution + UserDefaults-backed last-opened memory |
| `Tests/ClayspaceTests/LaunchDestinationTests.swift` | Create | Unit tests for resolution + persistence round-trip |
| `Sources/Clayspace/Views/CreateProjectFlow.swift` | Create | Self-contained New Project sheet (form + create + repo bootstrap), shared by Home and rail |
| `Sources/Clayspace/Views/ProjectWindow.swift` | Modify | Record last-opened project ID on appear |
| `Sources/Clayspace/Views/HomeView.swift` | Modify | One-shot launch redirect; slim down to consume shared sheet |
| `Sources/Clayspace/Views/ProjectsRail.swift` | Modify | "＋ New Project" row; "Move to Trash…" context menu + confirmation |

Existing code conventions to follow: XCTest (not swift-testing), `@MainActor @Observable` stores, file-scope private views, comments explain *why* not *what*.

---

### Task 1: LaunchDestination helper (TDD)

**Files:**
- Create: `Sources/Clayspace/Models/LaunchDestination.swift`
- Test: `Tests/ClayspaceTests/LaunchDestinationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClayspaceTests/LaunchDestinationTests.swift`:

```swift
import XCTest
@testable import Clayspace

/// Covers the pure launch-target resolution (`LaunchDestination.resolve`)
/// and the UserDefaults round-trip behind it (`LastOpenedProject`). The
/// persistence tests use a throwaway suite so they never touch the
/// user's real defaults.
final class LaunchDestinationTests: XCTestCase {
    private func project(_ name: String) -> Project {
        Project(name: name, rootPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - resolve

    func testEmptyStoreLandsOnHome() {
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: nil, projects: []), .home)
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: UUID(), projects: []), .home)
    }

    func testRememberedProjectWins() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: projects[1].id, projects: projects),
            .project(projects[1].id)
        )
    }

    func testStaleRememberedIDFallsBackToFirstProject() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: UUID(), projects: projects),
            .project(projects[0].id)
        )
    }

    func testNoRememberedIDFallsBackToFirstProject() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: nil, projects: projects),
            .project(projects[0].id)
        )
    }

    // MARK: - persistence

    private static let suiteName = "LaunchDestinationTests"

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?
            .removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testRecordAndLoadRoundTrip() throws {
        let defaults = try freshDefaults()
        let id = UUID()
        LastOpenedProject.record(id, in: defaults)
        XCTAssertEqual(LastOpenedProject.load(from: defaults), id)
    }

    func testLoadReturnsNilWhenUnsetOrGarbage() throws {
        let defaults = try freshDefaults()
        XCTAssertNil(LastOpenedProject.load(from: defaults))
        defaults.set("not-a-uuid", forKey: LastOpenedProject.defaultsKey)
        XCTAssertNil(LastOpenedProject.load(from: defaults))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LaunchDestinationTests`
Expected: compile FAILURE — `cannot find 'LaunchDestination' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Clayspace/Models/LaunchDestination.swift`:

```swift
import Foundation

/// Where a fresh launch should land. Home is shown only when there are
/// no projects to open; otherwise launch jumps straight into a project
/// window — the remembered last-opened project when it still exists,
/// else the first project in store order.
enum LaunchDestination: Equatable {
    case home
    case project(UUID)

    static func resolve(lastOpenedID: UUID?, projects: [Project]) -> LaunchDestination {
        guard !projects.isEmpty else { return .home }
        if let lastOpenedID, projects.contains(where: { $0.id == lastOpenedID }) {
            return .project(lastOpenedID)
        }
        return .project(projects[0].id)
    }
}

/// UserDefaults-backed memory of the project the user last had open.
/// Recording is a no-op under the e2e harness: sandboxed runs share the
/// process's real defaults domain, and the launch redirect is
/// suppressed there anyway.
enum LastOpenedProject {
    static let defaultsKey = "lastOpenedProjectID"

    static func record(_ id: UUID, in defaults: UserDefaults = .standard) {
        guard !E2EMode.isActive else { return }
        defaults.set(id.uuidString, forKey: defaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LaunchDestinationTests`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Models/LaunchDestination.swift Tests/ClayspaceTests/LaunchDestinationTests.swift
git commit -m "Add launch-destination resolution and last-opened persistence"
```

---

### Task 2: Record the last-opened project

**Files:**
- Modify: `Sources/Clayspace/Views/ProjectWindow.swift:62-77` (the `onAppear` in `ProjectWindowContents`)

`ProjectWindowContents.onAppear` runs on every path a project window appears or switches through (open from Home, rail switch — the `.id(project.id)` re-init re-fires it — and tear-off windows). Last writer wins, which is exactly the "most recently in front of the user" semantics we want.

- [ ] **Step 1: Add the recording call**

In `Sources/Clayspace/Views/ProjectWindow.swift`, at the top of the existing `.onAppear` block:

```swift
.onAppear {
    // Remember where the user was so the next launch can land
    // here instead of the Home grid.
    LastOpenedProject.record(project.id)
    // e2e only (no-op otherwise): expose this window's live
    // stores to the automation server, keyed by project id.
    E2ERegistry.shared.registerWindowStores(
```

(Only the two new lines + comment are added; everything else in the block stays.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Clayspace/Views/ProjectWindow.swift
git commit -m "Record last-opened project when a project window appears"
```

---

### Task 3: One-shot launch redirect in HomeView

**Files:**
- Modify: `Sources/Clayspace/Views/HomeView.swift:28-38` (the `.task`), plus new statics on `HomeView`

- [ ] **Step 1: Replace the `.task` block**

In `Sources/Clayspace/Views/HomeView.swift`, replace the existing `.task { ... }` (currently the e2e auto-open) with:

```swift
.task {
    // e2e harness convenience: jump straight into the named
    // project's window so drivers don't have to script the
    // project grid. No-op when the name doesn't match a
    // discovered project.
    if let name = E2EMode.autoOpenProjectName {
        store.refresh()
        if let project = store.projects.first(where: { $0.name == name }) {
            openProject(project.id)
        }
        return
    }
    // Normal launches skip the grid: the first Home presentation
    // per process redirects into the last-opened project (or the
    // first one) so the user lands in a workspace, not a menu.
    // Later presentations (⇧⌘0, the rail's Home row) show Home
    // normally. E2E runs keep the grid scriptable unless the
    // auto-open env var asked otherwise.
    guard !E2EMode.isActive, HomeView.consumeLaunchRedirect() else { return }
    store.refresh()
    if case .project(let id) = LaunchDestination.resolve(
        lastOpenedID: LastOpenedProject.load(),
        projects: store.projects
    ) {
        openProject(id)
    }
}
```

- [ ] **Step 2: Add the one-shot flag**

Add inside `struct HomeView`, next to the other private members:

```swift
/// One-shot per process: true exactly once, for the launch
/// presentation of Home. Static because the view struct is
/// recreated on every render and the window can be reopened.
@MainActor private static var didAttemptLaunchRedirect = false

@MainActor private static func consumeLaunchRedirect() -> Bool {
    if didAttemptLaunchRedirect { return false }
    didAttemptLaunchRedirect = true
    return true
}
```

- [ ] **Step 3: Build and run unit tests**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests PASS

- [ ] **Step 4: Manual smoke check**

Run: `./Scripts/make-app.sh debug && open ./Clayspace.app`
Expected: app opens directly into a project window (one of the existing projects), no Home grid. ⇧⌘0 then shows Home and it *stays* (no bounce-back).

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Views/HomeView.swift
git commit -m "Redirect launch from Home into the last-opened project"
```

---

### Task 4: Extract a self-contained CreateProjectSheet

**Files:**
- Create: `Sources/Clayspace/Views/CreateProjectFlow.swift`
- Modify: `Sources/Clayspace/Views/HomeView.swift` (remove moved code; slim sheet presentation)

The sheet currently takes seven bindings because `HomeView` owns the async create. Restructure it to own its form state and the create + repo-bootstrap flow internally, exposing only `store` and `onCreated`. `AddRepoIntent` already lives in `Views/AddRepoSheet.swift` (same module — no import changes).

- [ ] **Step 1: Create the shared component**

Create `Sources/Clayspace/Views/CreateProjectFlow.swift`. The form body, helper computed properties, and `chooseImportFolder` move verbatim from `HomeView.swift`; the diffs are: bindings become `@State`, `onCancel` becomes `dismiss()`, `onCreate` becomes the internal `createProject()`, and `isCreating` is unified with `isWorking`.

```swift
import SwiftUI

/// Repo bootstrap choice offered when creating a project.
enum CreateRepoMode: String, CaseIterable, Identifiable {
    case none = "Skip"
    case initialize = "Initialize"
    case clone = "Clone"
    case importExisting = "Import"
    var id: String { rawValue }
}

/// Self-contained "New Project" sheet shared by Home and the projects
/// rail. Owns the form state and the create + repo-bootstrap flow so
/// both entry points behave identically; callers provide the store and
/// react to `onCreated` (the sheet dismisses itself first).
struct CreateProjectSheet: View {
    let store: ProjectStore
    let onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var repoMode: CreateRepoMode = .none
    @State private var repoURL = ""
    @State private var repoName = ""
    @State private var importPath: URL?
    @State private var error: String?
    @State private var isWorking = false
    @State private var didTouchRepoName = false

    @FocusState private var focused: Field?

    enum Field { case name, repoURL, repoName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.headline)
            Text("A folder will be created under ~/Documents/Clayspace.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Project name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. mobile-app", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name)
                    .disabled(isWorking)
                    .onSubmit(submitIfReady)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Repository (optional)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Repository", selection: $repoMode) {
                    ForEach(CreateRepoMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isWorking)

                if repoMode == .clone {
                    TextField("git@github.com:owner/repo.git", text: $repoURL)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .repoURL)
                        .disabled(isWorking)
                        .onChange(of: repoURL) { _, newURL in
                            if !didTouchRepoName {
                                let derived = GitOperations.deriveName(from: newURL)
                                if !derived.isEmpty { repoName = derived }
                            }
                        }
                }

                if repoMode == .importExisting {
                    HStack(spacing: 8) {
                        Text(importPath?.path ?? "Choose source folder…")
                            .font(.callout)
                            .foregroundStyle(importPath == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseImportFolder)
                            .disabled(isWorking)
                    }
                }

                if repoMode != .none {
                    TextField(
                        repoNamePlaceholder,
                        text: $repoName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .repoName)
                    .disabled(isWorking)
                    .onChange(of: repoName) { _, _ in didTouchRepoName = true }
                }

                Text("All repos use a bare-with-worktrees layout: .bare/ for git data plus a worktree for the default branch under repos/<name>/. Import keeps the source folder untouched (we git clone --bare from it).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(workingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isWorking ? "Creating…" : "Create", action: submitIfReady)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = .name }
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedRepoURL: String {
        repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch repoMode {
        case .none, .initialize:
            return true
        case .clone:
            return !trimmedRepoURL.isEmpty
        case .importExisting:
            return importPath != nil
        }
    }

    private var workingLabel: String {
        switch repoMode {
        case .clone: return "Cloning repository…"
        case .initialize: return "Initializing repository…"
        case .importExisting: return "Importing repository…"
        case .none: return "Creating project…"
        }
    }

    private var repoNamePlaceholder: String {
        switch repoMode {
        case .clone: return "Folder name (auto-detected)"
        case .initialize: return "Folder name (defaults to project name)"
        case .importExisting: return "Folder name (defaults to source folder)"
        case .none: return "Folder name"
        }
    }

    // MARK: - Actions

    private func submitIfReady() {
        guard canSubmit else { return }
        createProject()
    }

    private func createProject() {
        guard !isWorking else { return }
        let projectName = trimmedName
        let repoIntent = pendingRepoIntent(forProjectName: projectName)
        isWorking = true
        error = nil

        Task {
            do {
                let project = try store.createProject(name: projectName)

                // Run the optional repo bootstrap before handing the
                // project back so its window appears with the repo
                // already in place (avoids a "Repositories: empty"
                // flash).
                if let repoIntent {
                    try await runRepoIntent(repoIntent, in: project)
                }

                isWorking = false
                dismiss()
                onCreated(project)
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func pendingRepoIntent(forProjectName projectName: String) -> AddRepoIntent? {
        switch repoMode {
        case .none:
            return nil
        case .initialize:
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .initialize(name: trimmed.isEmpty ? projectName : trimmed)
        case .clone:
            let url = trimmedRepoURL
            guard !url.isEmpty else { return nil }
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? GitOperations.deriveName(from: url) : trimmed
            return .clone(url: url, name: name)
        case .importExisting:
            guard let path = importPath else { return nil }
            let trimmed = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? GitOperations.deriveName(from: path.lastPathComponent) : trimmed
            return .importLocal(path: path, name: name)
        }
    }

    private func runRepoIntent(_ intent: AddRepoIntent, in project: Project) async throws {
        switch intent {
        case .clone(let url, let name):
            _ = try await GitOperations.cloneBare(url: url, into: project.rootPath, name: name)
        case .initialize(let name):
            _ = try await GitOperations.initBare(into: project.rootPath, name: name)
        case .importLocal(let path, let name):
            // Same engine — `git clone --bare` from a local path treats
            // it as a URL, mirroring the source's history into our .bare/.
            _ = try await GitOperations.cloneBare(url: path.path, into: project.rootPath, name: name)
        }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the existing local repository to import."
        if panel.runModal() == .OK, let url = panel.url {
            importPath = url
            if !didTouchRepoName {
                let derived = GitOperations.deriveName(from: url.lastPathComponent)
                if !derived.isEmpty { repoName = derived }
            }
        }
    }
}
```

- [ ] **Step 2: Slim down HomeView**

In `Sources/Clayspace/Views/HomeView.swift`:

1. Delete the form-state properties (keep `showCreate`, `pendingDelete`, `deleteError`):

```swift
// DELETE these lines:
@State private var newProjectName = ""
@State private var newProjectRepoMode: CreateRepoMode = .none
@State private var newProjectRepoURL = ""
@State private var newProjectRepoName = ""
@State private var newProjectImportPath: URL?
@State private var createError: String?
@State private var isCreating = false
```

2. Replace the `.sheet(isPresented: $showCreate, onDismiss: resetCreateState) { ... }` block with:

```swift
.sheet(isPresented: $showCreate) {
    CreateProjectSheet(store: store) { project in
        openProject(project.id)
    }
}
```

3. Replace `showCreateSheet()` with:

```swift
private func showCreateSheet() {
    showCreate = true
}
```

4. Delete entirely: `resetCreateState()`, `createProject()`, `pendingRepoIntent(forProjectName:)`, `runRepoIntent(_:in:)`, the file-scope `enum CreateRepoMode`, and the file-scope `private struct CreateProjectSheet` (all moved to `CreateProjectFlow.swift`).

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests PASS

- [ ] **Step 4: Manual smoke check**

Run: `./Scripts/make-app.sh debug && open ./Clayspace.app`, press ⇧⌘0 to show Home, click "New Project".
Expected: sheet looks and behaves exactly as before; creating a project opens its window.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Views/CreateProjectFlow.swift Sources/Clayspace/Views/HomeView.swift
git commit -m "Extract CreateProjectSheet into a self-contained shared component"
```

---

### Task 5: "＋ New Project" row in the projects rail

**Files:**
- Modify: `Sources/Clayspace/Views/ProjectsRail.swift`

- [ ] **Step 1: Add the row and sheet**

In `struct ProjectsRail`, add state:

```swift
@State private var showCreate = false
```

In `body`, after the `ScrollView { ... }` block (so the row stays pinned at the bottom while the list scrolls), add:

```swift
Divider()
    .padding(.horizontal, 10)

NewProjectRailRow { showCreate = true }
    .padding(.horizontal, 6)
    .padding(.vertical, 6)
```

On the outermost `VStack` (after the existing `.onAppear`), add:

```swift
.sheet(isPresented: $showCreate) {
    CreateProjectSheet(store: projects) { project in
        onSelect(project.id)
    }
}
```

- [ ] **Step 2: Add the row view**

Add at file scope in `ProjectsRail.swift`, next to `HomeRailRow`:

```swift
/// "＋ New Project" pinned under the list, styled like HomeRailRow so
/// it reads as part of the rail's navigation rather than chrome.
private struct NewProjectRailRow: View {
    let onClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, height: 16)
                Text("New Project")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Create a new project")
    }
}
```

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests PASS

- [ ] **Step 4: Manual smoke check**

Run: `./Scripts/make-app.sh debug && open ./Clayspace.app`
Expected: rail shows "New Project" pinned at the bottom; clicking it opens the sheet; creating a project switches the current window to it.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Views/ProjectsRail.swift
git commit -m "Add New Project row to the projects rail"
```

---

### Task 6: "Move to Trash…" from the rail

**Files:**
- Modify: `Sources/Clayspace/Views/ProjectsRail.swift`

- [ ] **Step 1: Thread an onDelete callback into the AppKit row**

In `ProjectRow` (the `NSViewRepresentable`), add the property and pass it through both `makeNSView` and `updateNSView`:

```swift
private struct ProjectRow: NSViewRepresentable {
    let project: Project
    let isActive: Bool
    let onClick: () -> Void
    let onOpenInNewWindow: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> ProjectRowView {
        let view = ProjectRowView()
        view.configure(
            project: project,
            isActive: isActive,
            onClick: onClick,
            onOpenInNewWindow: onOpenInNewWindow,
            onDelete: onDelete
        )
        return view
    }

    func updateNSView(_ nsView: ProjectRowView, context: Context) {
        nsView.configure(
            project: project,
            isActive: isActive,
            onClick: onClick,
            onOpenInNewWindow: onOpenInNewWindow,
            onDelete: onDelete
        )
    }
}
```

In `ProjectRowView`, add the stored callback and extend `configure`:

```swift
private var onDelete: (() -> Void)?

func configure(
    project: Project,
    isActive: Bool,
    onClick: @escaping () -> Void,
    onOpenInNewWindow: @escaping () -> Void,
    onDelete: @escaping () -> Void
) {
    let changed = self.project?.id != project.id
        || self.project?.name != project.name
        || self.isActive != isActive
    self.project = project
    self.isActive = isActive
    self.onClick = onClick
    self.onOpenInNewWindow = onOpenInNewWindow
    self.onDelete = onDelete
    toolTip = project.rootPath.path
    if changed { needsDisplay = true }
}
```

In `menu(for:)`, after the existing Finder item, add:

```swift
menu.addItem(.separator())

let deleteItem = NSMenuItem(
    title: "Move to Trash…",
    action: #selector(handleDelete),
    keyEquivalent: ""
)
deleteItem.target = self
menu.addItem(deleteItem)
```

And next to the other `@objc` handlers:

```swift
@objc private func handleDelete() {
    onDelete?()
}
```

- [ ] **Step 2: Own the confirmation in ProjectsRail**

In `struct ProjectsRail`, add:

```swift
@Environment(\.dismissWindow) private var dismissWindow
@State private var pendingDelete: Project?
@State private var deleteError: String?
```

Update the `ForEach` row construction:

```swift
ProjectRow(
    project: project,
    isActive: project.id == currentProjectID,
    onClick: { onSelect(project.id) },
    onOpenInNewWindow: { openInNewWindow(project.id) },
    onDelete: { pendingDelete = project }
)
.frame(height: 34)
```

Add the alerts after the `.sheet` modifier from Task 5 (wording matches Home's exactly):

```swift
.alert(
    "Move \(pendingDelete?.name ?? "project") to Trash?",
    isPresented: Binding(
        get: { pendingDelete != nil },
        set: { if !$0 { pendingDelete = nil } }
    ),
    presenting: pendingDelete
) { project in
    Button("Move to Trash", role: .destructive) {
        deleteProject(project)
    }
    Button("Cancel", role: .cancel) {}
} message: { project in
    Text("The folder at \(project.rootPath.path) will be moved to the Trash. You can recover it from Finder if you change your mind.")
}
.alert(
    "Couldn't delete project",
    isPresented: Binding(
        get: { deleteError != nil },
        set: { if !$0 { deleteError = nil } }
    ),
    presenting: deleteError
) { _ in
    Button("OK", role: .cancel) {}
} message: { error in
    Text(error)
}
```

Add the delete action:

```swift
/// Delete and, when the row was the project this window is showing,
/// move the window somewhere sensible: the first remaining project,
/// or Home when the list just emptied (a project window can't exist
/// without a project). Other windows showing the deleted project
/// fall back to MissingProjectView on their own.
private func deleteProject(_ project: Project) {
    let wasCurrent = project.id == currentProjectID
    do {
        try projects.deleteProject(project)
    } catch {
        deleteError = error.localizedDescription
        return
    }
    guard wasCurrent else { return }
    if let fallback = projects.projects.first {
        onSelect(fallback.id)
    } else {
        openWindow(id: "home")
        dismissWindow(id: "project", value: project.id)
    }
}
```

(`dismissWindow(id:value:)` targets this window because the WindowGroup binding is the source of truth and `onSwitchProject` writes switches back through it, so the bound value always equals `currentProjectID`.)

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests PASS

- [ ] **Step 4: Manual smoke check**

Run: `./Scripts/make-app.sh debug && open ./Clayspace.app`. Create a throwaway project from the rail, then right-click its row → "Move to Trash…".
Expected: confirmation alert appears; confirming removes the row and (if it was the current project) switches the window to another project. The folder lands in the Trash.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clayspace/Views/ProjectsRail.swift
git commit -m "Add Move to Trash to the projects rail context menu"
```

---

### Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Unit tests**

Run: `swift test`
Expected: all tests PASS

- [ ] **Step 2: E2E suite**

Run: `./Scripts/e2e/run-e2e.sh`
Expected: all scenarios pass. The launch redirect is suppressed under `E2EMode`, so existing scenarios that script the home grid must behave exactly as before — a failure here means the redirect is leaking into e2e runs.

- [ ] **Step 3: Manual checklist**

Run: `./Scripts/make-app.sh debug && open ./Clayspace.app` and verify:

1. Launch lands in the last project you had open (no Home grid).
2. Quit, reopen — lands in the same project again.
3. ⇧⌘0 shows Home; it stays up (no bounce-back). Rail's Home row does the same.
4. Rail "New Project" creates and switches to the project; Home's "New Project" still works.
5. Rail right-click → "Move to Trash…" on the *current* project switches the window to another project.
6. Delete all projects: window returns to Home showing the empty state; next launch lands on Home.

- [ ] **Step 4: Commit any stragglers and report**

```bash
git status
```

Expected: clean tree (all work committed in Tasks 1-6). Report results against the checklist.
