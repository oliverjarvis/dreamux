# File Tree Power-Ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The file tree gets a real context menu (Open, Reveal in Finder, Copy Path / Relative Path, New File/Folder, Rename, Move to Trash, Open in Terminal for folders), rows drag as genuine file URLs, and dropping files onto a terminal types their shell-escaped paths.

**Architecture:** A small testable `FileTreeOperations` enum owns the file-system verbs (create/rename/trash) and the two string helpers (shell escaping, repo-relative paths). `FileTreeRow` grows a context menu + `.onDrag`, reporting actions up through one `(FileTreeAction, FileNode) -> Void` closure; `FileTreePanel` owns the rename/create sheets and bumps its existing `reloadToken` after mutations. `WorkspaceSession` gains a focused-terminal accessor so "Open in Terminal" types `cd` into the visible tab; `HostedTerminalView` gains `.onDrop(of: [.fileURL])` that sends escaped paths to its own session.

**Tech Stack:** Swift/SwiftPM, SwiftUI (`.contextMenu`, `.onDrag`, `.onDrop`), FileManager (`trashItem` — recoverable), NSPasteboard, XCTest.

## Global Constraints

- Platform floor `macOS(.v14)`; no new dependencies.
- Move to Trash is recoverable (`FileManager.trashItem`), no confirmation dialog (spec decision); rename/new-file/new-folder use small sheets, errors surface inline in the sheet.
- Drop/`Open in Terminal` text uses single-quote shell escaping (`'` → `'\''`), one trailing space after each path (Terminal.app muscle memory), `cd` lines end with `\n`.
- Copy Relative Path is relative to the row's repo worktree root (the `isRepoRoot` ancestor), falling back to the absolute path if the node somehow isn't under its root.
- After any mutation the tree refreshes via the existing `reloadToken` bump (known cost: `DisclosureGroup` expansion resets — accepted, pre-existing refresh behavior).
- Typography: menu items are system-standard; no `.caption2` anywhere new.
- Tests: XCTest in `Tests/DreamuxTests/`, temp-dir sandboxes, house-style *why* doc comments. Full `swift test` green before each task's final commit.
- Git: stage only named files (`Scripts/` is capital-S); plain-sentence commits ending `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Delivery branch `file-tree-powerups`; merge only after user approval (Task 5).

**Existing code this plan builds on (verified against current sources):**
- `Sources/Dreamux/Views/FileTreePanel.swift` — `FileTreePanel` (`store`, `repoStore`, `tree`, `onOpenFile`, `@State reloadToken`, 33pt header with refresh); private `FileTreeRow` (directories = lazy `DisclosureGroup` expanded when `isRepoRoot`; files = plain Button → `onOpenFile(node.url)`).
- `Sources/Dreamux/Models/FileTreeStore.swift` — `FileNode { url, name, isDirectory, isRepoRoot }` (url symlink-resolved for roots), `roots(for:repositories:)`, `children(of:)` (dirs-first case-insensitive sort, hides `.git`/`.bare`).
- `Sources/Dreamux/Views/HostedTerminalView.swift` — SwiftUI wrapper over the session-owned `TerminalView`; body is `HostedTerminalRepresentable(session:)` + colorScheme adoption. `TabSession.send(_ text: String)` writes to the PTY (Models/TabSession.swift:158).
- `Sources/Dreamux/Models/WorkspaceSession.swift` — `controller.focusedPaneId` / `controller.selectedTab(inPane:)` pattern (see `closeFocusedTab`, line ~143); `tabSessions: [TabID: TabSession]` private map; terminal tabs are exactly the ids present in `tabSessions`.
- `Sources/Dreamux/Views/ContentView.swift:159` — the single `FileTreePanel(` construction site (inside the card's third column); ContentView has `store` (WorkspaceStore) in scope there.

---

### Task 1: FileTreeOperations — verbs and string helpers

**Files:**
- Create: `Sources/Dreamux/Models/FileTreeOperations.swift`
- Test: `Tests/DreamuxTests/FileTreeOperationsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 2–4 rely on these exact names):
  - `enum FileTreeOperations` with:
    - `static func shellEscaped(_ path: String) -> String` — single-quote wrap, embedded `'` → `'\''`
    - `static func relativePath(of url: URL, under root: URL) -> String` — standardized-path prefix strip; absolute path when not under root
    - `static func createFile(named name: String, in directory: URL) throws -> URL` — empty file; throws `FileTreeOperationError.alreadyExists(String)` when the name is taken, `.invalidName(String)` for empty/`/`-containing names
    - `static func createFolder(named name: String, in directory: URL) throws -> URL` — same error contract
    - `static func rename(_ url: URL, to newName: String) throws -> URL` — same-directory move, same error contract
    - `static func trash(_ url: URL) throws` — `FileManager.trashItem`
  - `enum FileTreeOperationError: LocalizedError, Equatable` with `alreadyExists(String)` / `invalidName(String)` and human `errorDescription`s.

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git worktree add .claude/worktrees/file-tree-powerups -b file-tree-powerups
cd .claude/worktrees/file-tree-powerups
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/DreamuxTests/FileTreeOperationsTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// The file tree's mutating verbs and its two string helpers. Paths
/// with spaces and quotes are the whole point of shell escaping —
/// those are the cases agents' repos actually contain.
final class FileTreeOperationsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetree-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - shellEscaped

    /// Plain, space-containing, and quote-containing paths — the
    /// single-quote escape must produce something a POSIX shell
    /// round-trips byte-for-byte.
    func testShellEscaping() {
        XCTAssertEqual(FileTreeOperations.shellEscaped("/a/b.txt"), "'/a/b.txt'")
        XCTAssertEqual(FileTreeOperations.shellEscaped("/a dir/b.txt"), "'/a dir/b.txt'")
        XCTAssertEqual(
            FileTreeOperations.shellEscaped("/it's here/x"),
            "'/it'\\''s here/x'")
    }

    // MARK: - relativePath

    func testRelativePathUnderRootAndOutside() {
        let root = URL(fileURLWithPath: "/repo/web/main")
        let nested = URL(fileURLWithPath: "/repo/web/main/src/app.ts")
        XCTAssertEqual(FileTreeOperations.relativePath(of: nested, under: root), "src/app.ts")
        let outside = URL(fileURLWithPath: "/elsewhere/x.txt")
        XCTAssertEqual(
            FileTreeOperations.relativePath(of: outside, under: root),
            "/elsewhere/x.txt",
            "not under root → absolute fallback, never a wrong relative guess")
    }

    // MARK: - create / rename / trash

    func testCreateFileAndFolderWithCollisionAndValidation() throws {
        let file = try FileTreeOperations.createFile(named: "notes.md", in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "notes.md", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .alreadyExists("notes.md"))
        }
        let folder = try FileTreeOperations.createFolder(named: "sub", in: dir)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir)
        XCTAssertTrue(isDir.boolValue)
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "a/b", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .invalidName("a/b"))
        }
        XCTAssertThrowsError(try FileTreeOperations.createFile(named: "", in: dir)) {
            XCTAssertEqual($0 as? FileTreeOperationError, .invalidName(""))
        }
    }

    func testRenameMovesWithinDirectoryAndGuards() throws {
        let file = try FileTreeOperations.createFile(named: "old.txt", in: dir)
        let renamed = try FileTreeOperations.rename(file, to: "new.txt")
        XCTAssertEqual(renamed.lastPathComponent, "new.txt")
        XCTAssertEqual(renamed.deletingLastPathComponent().path, file.deletingLastPathComponent().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        _ = try FileTreeOperations.createFile(named: "taken.txt", in: dir)
        XCTAssertThrowsError(try FileTreeOperations.rename(renamed, to: "taken.txt")) {
            XCTAssertEqual($0 as? FileTreeOperationError, .alreadyExists("taken.txt"))
        }
    }

    /// trashItem is recoverable-by-design; the test only asserts the
    /// file left its original location (the Trash's location is the
    /// OS's business).
    func testTrashRemovesFromOriginalLocation() throws {
        let file = try FileTreeOperations.createFile(named: "bye.txt", in: dir)
        try FileTreeOperations.trash(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter FileTreeOperationsTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'FileTreeOperations' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/Dreamux/Models/FileTreeOperations.swift`:

```swift
import Foundation

/// Errors the file tree's mutating verbs surface in the rename/create
/// sheets. Equatable so tests can pin exact cases.
enum FileTreeOperationError: LocalizedError, Equatable {
    case alreadyExists(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "\"\(name)\" already exists here."
        case .invalidName(let name):
            return name.isEmpty
                ? "Name can't be empty."
                : "\"\(name)\" isn't a valid file name."
        }
    }
}

/// The file tree's file-system verbs and shell/path helpers — kept off
/// the views so the behavior that can corrupt a worktree is unit-tested
/// against real temp directories.
enum FileTreeOperations {

    /// POSIX single-quote escaping: wrap in ', turn embedded ' into
    /// '\'' (close, escaped quote, reopen). Round-trips any byte
    /// sequence except NUL through /bin/sh unchanged.
    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Path of `url` relative to `root` (no leading slash), or the
    /// absolute path when `url` isn't under `root` — a wrong relative
    /// path pasted into a terminal is worse than a long absolute one.
    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count))
    }

    @discardableResult
    static func createFile(named name: String, in directory: URL) throws -> URL {
        let target = try validatedTarget(named: name, in: directory)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        return target
    }

    @discardableResult
    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let target = try validatedTarget(named: name, in: directory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let target = try validatedTarget(
            named: newName, in: url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Recoverable delete — the file lands in the user's Trash. No
    /// confirmation dialog by design; undo is the Trash itself.
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func validatedTarget(named name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileTreeOperationError.invalidName(name)
        }
        let target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw FileTreeOperationError.alreadyExists(name)
        }
        return target
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FileTreeOperationsTests 2>&1 | tail -5`
Expected: `Test Suite 'FileTreeOperationsTests' passed` — 5 tests.

- [ ] **Step 6: Full suite, commit**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/FileTreeOperations.swift Tests/DreamuxTests/FileTreeOperationsTests.swift
git commit -m "File-tree verbs: create, rename, trash, escape, relative paths

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: WorkspaceSession — focused-terminal accessor

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift` (near `closeFocusedTab`, ~line 143)

**Interfaces:**
- Consumes: existing `controller.focusedPaneId`, `controller.selectedTab(inPane:)`, private `tabSessions`.
- Produces (Tasks 3 relies on): `WorkspaceSession.sendToFocusedTerminal(_ text: String) -> Bool` — types into the focused pane's selected tab IF it is a terminal tab; false otherwise (caller decides how to surface).

- [ ] **Step 1: Implement**

Add next to `closeFocusedTab` (mirroring its focused-pane resolution):

```swift
    /// Type `text` into the focused pane's selected tab, if that tab
    /// is a terminal (file/web/diff tabs can't receive keystrokes this
    /// way). Returns false when there is no focused terminal — callers
    /// surface that however fits their context.
    @discardableResult
    func sendToFocusedTerminal(_ text: String) -> Bool {
        guard let pane = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: pane),
              let terminal = tabSessions[tab.id] else { return false }
        terminal.send(text)
        return true
    }
```

- [ ] **Step 2: Build + full suite**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.
(No new unit test: the three guards are the existing `closeFocusedTab` pattern and Bonsplit's focused-pane state isn't headless-testable here; behavior is exercised in Task 5's live verification.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Models/WorkspaceSession.swift
git commit -m "WorkspaceSession can type into the focused terminal tab

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Context menu, sheets, and drag on the file tree

**Files:**
- Modify: `Sources/Dreamux/Views/FileTreePanel.swift` (the whole row/panel surface)
- Modify: `Sources/Dreamux/Views/ContentView.swift:159` (`FileTreePanel(` construction — one new argument)

**Interfaces:**
- Consumes: `FileTreeOperations`/`FileTreeOperationError` (Task 1), `WorkspaceSession.sendToFocusedTerminal` (Task 2), existing `FileNode`, `reloadToken`.
- Produces: `FileTreePanel` gains `let onSendToTerminal: (String) -> Bool`; internal `enum FileTreeAction` (not consumed elsewhere).

- [ ] **Step 1: Rewrite FileTreePanel.swift's row/action layer**

Replace the contents of `Sources/Dreamux/Views/FileTreePanel.swift` below the `header`/`emptyState` (keep those and the panel struct shell intact) with the action-aware version. The full new file body:

```swift
import SwiftUI

/// The right-side file explorer — the card's third column. Presents
/// the active feature's linked-repo worktrees as one tree — each repo a
/// top-level node — opens files as Monaco tabs, and carries the
/// standard file-manager verbs (context menu), drag-out, and
/// open-in-terminal.
struct FileTreePanel: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    /// Types text into the focused terminal tab; false = no terminal
    /// focused (we beep). Wired to WorkspaceSession.sendToFocusedTerminal.
    let onSendToTerminal: (String) -> Bool

    /// Bumped by the refresh button and after any mutation to force a
    /// fresh disk read of the (uncached) tree.
    @State private var reloadToken = UUID()
    /// The rename sheet's subject.
    @State private var renaming: FileNode?
    /// The create sheet's target directory and kind.
    @State private var creating: CreateTarget?

    private var roots: [FileNode] {
        tree.roots(for: store.activeWorkspace, repositories: repoStore.repositories)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if roots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(roots) { root in
                        FileTreeRow(
                            node: root,
                            rootURL: root.url,
                            tree: tree,
                            onOpenFile: onOpenFile,
                            onAction: { handle($0, on: $1, rootURL: root.url) })
                    }
                }
                .listStyle(.sidebar)
                // No material of its own — the tree lives inside the
                // card and shares its fill/transparency.
                .scrollContentBackground(.hidden)
                .id(reloadToken)
            }
        }
        .sheet(item: $renaming) { node in
            NameSheet(
                title: "Rename \"\(node.name)\"",
                confirmLabel: "Rename",
                initialName: node.name
            ) { newName in
                try FileTreeOperations.rename(node.url, to: newName)
            } onDone: {
                reloadToken = UUID()
            }
        }
        .sheet(item: $creating) { target in
            NameSheet(
                title: target.isDirectory
                    ? "New folder in \(target.directory.lastPathComponent)"
                    : "New file in \(target.directory.lastPathComponent)",
                confirmLabel: "Create",
                initialName: ""
            ) { name in
                if target.isDirectory {
                    try FileTreeOperations.createFolder(named: name, in: target.directory)
                } else {
                    let url = try FileTreeOperations.createFile(named: name, in: target.directory)
                    onOpenFile(url)
                }
            } onDone: {
                reloadToken = UUID()
            }
        }
    }

    private func handle(_ action: FileTreeAction, on node: FileNode, rootURL: URL) {
        switch action {
        case .open:
            onOpenFile(node.url)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        case .copyPath:
            copyToPasteboard(node.url.path)
        case .copyRelativePath:
            copyToPasteboard(FileTreeOperations.relativePath(of: node.url, under: rootURL))
        case .newFile:
            creating = CreateTarget(directory: containerDirectory(for: node), isDirectory: false)
        case .newFolder:
            creating = CreateTarget(directory: containerDirectory(for: node), isDirectory: true)
        case .rename:
            renaming = node
        case .trash:
            do {
                try FileTreeOperations.trash(node.url)
                reloadToken = UUID()
            } catch {
                NSSound.beep()
            }
        case .openInTerminal:
            let line = "cd \(FileTreeOperations.shellEscaped(node.url.path))\n"
            if !onSendToTerminal(line) { NSSound.beep() }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// New File/Folder on a folder creates inside it; on a file row it
    /// creates a sibling (the file's parent directory).
    private func containerDirectory(for node: FileNode) -> URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Compact — the card's context header above already names the
    /// worktree/commit this tree belongs to; this strip just labels the
    /// column and hosts refresh.
    private var header: some View {
        HStack {
            Text("Files")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer()
            Button { reloadToken = UUID() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        // Bonsplit's TabBarMetrics.barHeight — the FILES strip sits next
        // to the tab bar and their bottom hairlines must align.
        .frame(height: 33)
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(store.activeWorkspace == nil
             ? "No feature selected."
             : "This feature spans no repositories.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }
}

/// The verbs a row can ask the panel to perform. The panel owns the
/// sheets/pasteboard/terminal plumbing; rows just name the action.
enum FileTreeAction {
    case open, revealInFinder, copyPath, copyRelativePath
    case newFile, newFolder, rename, trash, openInTerminal
}

/// Sheet target for New File / New Folder.
private struct CreateTarget: Identifiable {
    let directory: URL
    let isDirectory: Bool
    var id: String { "\(directory.path)|\(isDirectory)" }
}

/// One row in the tree. Directories are lazy `DisclosureGroup`s (children
/// read from disk only while expanded); files are buttons that open an
/// editor tab. Repo roots default to expanded. Every row drags as its
/// file URL and carries the file-manager context menu.
private struct FileTreeRow: View {
    let node: FileNode
    /// The repo worktree root this row lives under (Copy Relative Path's
    /// base). Repo roots pass their own url down.
    let rootURL: URL
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    let onAction: (FileTreeAction, FileNode) -> Void
    @State private var expanded: Bool

    init(
        node: FileNode,
        rootURL: URL,
        tree: FileTreeStore,
        onOpenFile: @escaping (URL) -> Void,
        onAction: @escaping (FileTreeAction, FileNode) -> Void
    ) {
        self.node = node
        self.rootURL = rootURL
        self.tree = tree
        self.onOpenFile = onOpenFile
        self.onAction = onAction
        _expanded = State(initialValue: node.isRepoRoot)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(tree.children(of: node)) { child in
                        FileTreeRow(
                            node: child,
                            rootURL: rootURL,
                            tree: tree,
                            onOpenFile: onOpenFile,
                            onAction: onAction)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.isRepoRoot ? "shippingbox.fill" : "folder.fill")
                    .font(.callout)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider() }
                    .contextMenu { menu }
            }
        } else {
            Button { onOpenFile(node.url) } label: {
                Label(node.name, systemImage: "doc.text")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag { NSItemProvider(contentsOf: node.url) ?? NSItemProvider() }
            .contextMenu { menu }
        }
    }

    /// Files: Open · Reveal · Copy paths · New (sibling) · Rename ·
    /// Trash. Folders: the same minus Open, New targets the folder
    /// itself, plus Open in Terminal. Repo roots can't be renamed or
    /// trashed — they're worktrees, not tree content.
    @ViewBuilder
    private var menu: some View {
        if !node.isDirectory {
            Button("Open") { onAction(.open, node) }
            Divider()
        }
        Button("Reveal in Finder") { onAction(.revealInFinder, node) }
        Button("Copy Path") { onAction(.copyPath, node) }
        Button("Copy Relative Path") { onAction(.copyRelativePath, node) }
        Divider()
        Button("New File…") { onAction(.newFile, node) }
        Button("New Folder…") { onAction(.newFolder, node) }
        if node.isDirectory {
            Button("Open in Terminal") { onAction(.openInTerminal, node) }
        }
        if !node.isRepoRoot {
            Divider()
            Button("Rename…") { onAction(.rename, node) }
            Button("Move to Trash", role: .destructive) { onAction(.trash, node) }
        }
    }
}

/// Shared one-field sheet for Rename / New File / New Folder. Runs the
/// throwing operation on Confirm; a FileTreeOperationError renders
/// inline and keeps the sheet open for correction.
private struct NameSheet: View {
    let title: String
    let confirmLabel: String
    let initialName: String
    let perform: (String) throws -> Void
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { name = initialName }
    }

    private func confirm() {
        do {
            try perform(name)
            dismiss()
            onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
```

Note: `FileNode` must be `Identifiable` already (it's used in `ForEach`); `renaming`'s `.sheet(item:)` needs `FileNode: Identifiable` — confirm it is (FileTreeStore.swift / FileNode definition); if its `id` isn't stable/Identifiable-conformant for sheets, wrap in a tiny `Identifiable` box the way `CreateTarget` is.

- [ ] **Step 2: Wire the new argument in ContentView**

At `ContentView.swift:159`'s `FileTreePanel(` call, add after `onOpenFile`:

```swift
                                    onSendToTerminal: { text in
                                        guard let workspace = store.activeWorkspace else { return false }
                                        return store.session(for: workspace).sendToFocusedTerminal(text)
                                    },
```

(match the call's existing argument order/trailing-closure style — read the site first).

- [ ] **Step 3: Build + full suite**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/FileTreePanel.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "File tree gets its context menu, name sheets, and drag-out

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Terminal accepts file drops

**Files:**
- Modify: `Sources/Dreamux/Views/HostedTerminalView.swift`

**Interfaces:**
- Consumes: `FileTreeOperations.shellEscaped` (Task 1), `TabSession.send` (existing).
- Produces: drop behavior only.

- [ ] **Step 1: Implement**

In `HostedTerminalView.body`, after the `.onChange` modifier, add:

```swift
            // Dropping files types their shell-escaped paths into THIS
            // terminal (the drop target picks the tab — no "active tab"
            // guessing). Trailing space per path matches Terminal.app.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let text = FileTreeOperations.shellEscaped(url.path) + " "
                        Task { @MainActor in
                            session.send(text)
                        }
                    }
                }
                return !providers.isEmpty
            }
```

Add `import UniformTypeIdentifiers` at the top of the file (`.fileURL` is `UTType.fileURL`). Note `loadObject(ofClass: URL.self)` requires the provider to carry a file URL — the tree's `NSItemProvider(contentsOf:)` and Finder drags both do.

- [ ] **Step 2: Build + full suite**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/HostedTerminalView.swift
git commit -m "Terminals accept file drops as shell-escaped paths

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Verification + merge gate

**Files:** none (verification + git only)

- [ ] **Step 1: Build + relaunch from the worktree**

```bash
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open ./Dreamux.app --args -ApplePersistenceIgnoreState YES
sleep 4
```

- [ ] **Step 2: Live verification** (controller/user-driven; automation optional)

- Right-click a file: Open / Reveal in Finder / Copy Path / Copy Relative Path / Rename… / Move to Trash all present; repo root rows lack Rename/Trash.
- Right-click a folder: adds New File… / New Folder… / Open in Terminal.
- Copy Relative Path → pasteboard has the repo-relative path (`pbpaste` to check).
- New File → sheet, name collision shows the inline error; created file opens in Monaco and appears after refresh.
- Rename + Move to Trash work; trashed file is in the Trash (recoverable).
- Open in Terminal on a folder types `cd '<path>'` into the focused terminal; with a file tab focused it beeps instead.
- Drag a file from the tree into the terminal → escaped path + trailing space appears; drag into Finder copies the file reference; drop a file from Finder onto the terminal → same escaped path.
- Screenshot the context menu for the record if capture is available.

- [ ] **Step 3: Present results to the user and wait for merge approval.** Do not merge without it.

- [ ] **Step 4: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git status --short && git log --oneline -1
git merge --ff-only file-tree-powerups || git merge --no-edit file-tree-powerups
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
git push origin main
git worktree remove .claude/worktrees/file-tree-powerups
git branch -d file-tree-powerups
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

Expected: ff merge (re-verify SHAs — main may move from parallel sessions), suite green on main, push accepted, canonical app relaunched from main.
