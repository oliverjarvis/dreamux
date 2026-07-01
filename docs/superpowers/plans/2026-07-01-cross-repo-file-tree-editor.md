# Cross-repo File Tree + Monaco Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable right-side file explorer that unifies the active feature's per-repo worktrees into one tree, and opens files as real Monaco editor tabs inside the workspace's Bonsplit layout.

**Architecture:** A pure `FileTreeStore` resolves the active feature's linked-repo worktree paths into a lazy `FileNode` tree, rendered by a native `.inspector` panel. Clicking a file opens a `FileEditorTabSession` — a third Bonsplit tab kind alongside terminals (`TabSession`) and web tabs (`WebTabSession`) — that hosts the vendored Monaco editor in a `WKWebView` served over a custom `app-monaco://` scheme, with ⌘S save back to the worktree file.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, WebKit (`WKWebView` + `WKURLSchemeHandler`), Bonsplit (vendored), Monaco Editor (vendored `min` build), XCTest.

## Global Constraints

- Platform floor: `.macOS(.v14)` — `.inspector`/`.inspectorColumnWidth` are macOS 14 APIs. (Copied from `Package.swift`.)
- Swift tools: `swift-tools-version: 6.0`; tests are XCTest with `@testable import Dreamux`, run via `swift test`.
- Filesystem in tests goes through `TestSandbox` (temp dir, UUID-suffixed) — never real Application Support / Documents.
- Native-controls preference: use SwiftUI `List`/`DisclosureGroup`/`.inspector`, not custom-painted chrome.
- Monaco runs fully offline: assets are vendored and served from the resource bundle — no runtime network fetch, no CDN.
- Monaco version is pinned to **0.52.2** everywhere it's referenced.
- Tab-content dispatch invariant: a Bonsplit `TabID` maps to exactly one of `tabSessions` / `webTabSessions` / `fileTabSessions`.
- Edits target the resolved worktree file (`repos/<repo>/<feature>/…`), never the `features/<feature>/` symlink dir and never `main`.

---

## File Structure

| File | New/Edit | Responsibility |
|------|----------|----------------|
| `Sources/Dreamux/Models/FileNode.swift` | new | Lazy tree node value type. |
| `Sources/Dreamux/Models/FileTreeStore.swift` | new | Resolve per-repo worktree roots + directory children. |
| `Sources/Dreamux/Views/MonacoSchemeHandler.swift` | new | `WKURLSchemeHandler` serving bundled Monaco over `app-monaco://`. |
| `Sources/Dreamux/Resources/Monaco/` | new | Vendored Monaco `min` build + `index.html` + `editor-boot.js`. |
| `Sources/Dreamux/Models/FileEditorTabSession.swift` | new | Monaco-backed editor session: load, dirty, ⌘S save, language/theme. |
| `Sources/Dreamux/Views/FileTreePanel.swift` | new | Native source-list inspector panel + recursive rows. |
| `Sources/Dreamux/Models/WorkspaceSession.swift` | edit | `fileTabSessions` map, `openFileTab`, dispatch + cleanup, accessors. |
| `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` | edit | `TabContentView` third branch → `FileEditorView`. |
| `Sources/Dreamux/Views/ContentView.swift` | edit | `.inspector` + toolbar toggle (⌥⌘E) + open wiring. |
| `Package.swift` | edit | Declare Monaco resources on the `Dreamux` target. |
| `Sources/Dreamux/E2E/E2ERegistry.swift` | edit | `pendingFileTreeVisible` bridge field. |
| `Sources/Dreamux/E2E/E2ECommands.swift` | edit | `openFile` + `setFileTree` commands; `fileTabs` in state. |
| `scripts/e2e/PROTOCOL.md` | edit | Document the two new commands + `fileTabs`. |

---

## Task 1: `FileNode` + `FileTreeStore` (pure tree model)

**Files:**
- Create: `Sources/Dreamux/Models/FileNode.swift`
- Create: `Sources/Dreamux/Models/FileTreeStore.swift`
- Test: `Tests/DreamuxTests/FileTreeStoreTests.swift`

**Interfaces:**
- Consumes: `Workspace` (`name`, `linkedRepoIDs`), `Repository` (`rootURL`, `name`).
- Produces:
  - `struct FileNode: Identifiable, Hashable { let url: URL; let name: String; let isDirectory: Bool; let isRepoRoot: Bool; var id: URL { url } }`
  - `@MainActor @Observable final class FileTreeStore` with
    `func roots(for workspace: Workspace?, repositories: [Repository]) -> [FileNode]`
    and `func children(of node: FileNode) -> [FileNode]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/FileTreeStoreTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class FileTreeStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    /// Lay down `repos/<repo>/<branch>/` with an optional file inside.
    @discardableResult
    private func makeWorktree(repo: String, branch: String, file: String? = nil) throws -> URL {
        let dir = project.rootPath
            .appendingPathComponent("repos/\(repo)/\(branch)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let file {
            try "x".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func repo(_ name: String) -> Repository {
        Repository(rootURL: project.rootPath.appendingPathComponent("repos/\(name)", isDirectory: true))
    }

    @MainActor
    func testRootsAreLinkedReposWithWorktreesInOrder() throws {
        try makeWorktree(repo: "repoA", branch: "feat")
        try makeWorktree(repo: "repoB", branch: "feat")
        try makeWorktree(repo: "repoC", branch: "feat") // not linked
        let ws = Workspace(name: "feat", linkedRepoIDs: ["repoB", "repoA"])
        let store = FileTreeStore()

        let roots = store.roots(for: ws, repositories: [repo("repoA"), repo("repoB"), repo("repoC")])

        XCTAssertEqual(roots.map(\.name), ["repoB", "repoA"])
        XCTAssertTrue(roots.allSatisfy { $0.isRepoRoot && $0.isDirectory })
    }

    @MainActor
    func testRepoWithoutWorktreeAtBranchIsOmitted() throws {
        try makeWorktree(repo: "repoA", branch: "feat")
        // repoB linked but has no worktree at this branch.
        let ws = Workspace(name: "feat", linkedRepoIDs: ["repoA", "repoB"])
        let store = FileTreeStore()

        let roots = store.roots(for: ws, repositories: [repo("repoA"), repo("repoB")])

        XCTAssertEqual(roots.map(\.name), ["repoA"])
    }

    @MainActor
    func testNilAndOrphanWorkspacesYieldNoRoots() throws {
        let store = FileTreeStore()
        XCTAssertTrue(store.roots(for: nil, repositories: []).isEmpty)
        let orphan = Workspace(name: "scratch", linkedRepoIDs: [])
        XCTAssertTrue(store.roots(for: orphan, repositories: [repo("repoA")]).isEmpty)
    }

    @MainActor
    func testChildrenSortDirsFirstAndHideGitInternals() throws {
        let root = try makeWorktree(repo: "repoA", branch: "feat")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "gitdir: ...".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".bare"), withIntermediateDirectories: true)
        let store = FileTreeStore()
        let node = FileNode(url: root, name: "repoA", isDirectory: true, isRepoRoot: true)

        let names = store.children(of: node).map(\.name)

        XCTAssertEqual(names, ["src", "a.txt", "b.txt"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileTreeStoreTests`
Expected: FAIL — `cannot find 'FileTreeStore' in scope` / `cannot find 'FileNode' in scope`.

- [ ] **Step 3: Write `FileNode`**

Create `Sources/Dreamux/Models/FileNode.swift`:

```swift
import Foundation

/// One node in the cross-repo file tree. Directories expand lazily —
/// `FileTreeStore.children(of:)` enumerates a node's contents on demand
/// so a deep worktree is never walked eagerly.
struct FileNode: Identifiable, Hashable {
    /// Resolved (symlink-free) absolute path on disk. Also the identity
    /// used for tree diffing and editor-tab dedup.
    let url: URL
    /// Display label — the repo name for a root, else the file/dir name.
    let name: String
    let isDirectory: Bool
    /// True for the per-repo top-level nodes (repo-style chrome, opened
    /// by default in the panel).
    let isRepoRoot: Bool

    var id: URL { url }
}
```

- [ ] **Step 4: Write `FileTreeStore`**

Create `Sources/Dreamux/Models/FileTreeStore.swift`:

```swift
import Foundation
import Observation

/// Builds the cross-repo file tree shown in the right-side inspector.
/// Holds no cached tree: `roots` and `children` are recomputed from the
/// live workspace/repository values passed in, so switching the active
/// feature or hitting refresh simply recomputes.
@MainActor
@Observable
final class FileTreeStore {
    /// Directory entries never shown in the tree — git internals.
    private static let hiddenNames: Set<String> = [".git", ".bare"]

    /// Top-level nodes: one per repo the feature spans that has a
    /// worktree checked out at the feature's branch. Repos without such
    /// a worktree, and repos the feature doesn't link, are omitted. A
    /// nil/orphan workspace (no linked repos) yields `[]`.
    func roots(for workspace: Workspace?, repositories: [Repository]) -> [FileNode] {
        guard let workspace else { return [] }
        let byName = Dictionary(repositories.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FileNode] = []
        for repoID in workspace.linkedRepoIDs {
            guard let repo = byName[repoID] else { continue }
            let worktree = repo.rootURL.appendingPathComponent(workspace.name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(FileNode(
                url: worktree.resolvingSymlinksInPath(),
                name: repo.name,
                isDirectory: true,
                isRepoRoot: true
            ))
        }
        return result
    }

    /// Immediate children of a directory node — directories first, then
    /// files, each case-insensitively sorted. `.git`/`.bare` are hidden;
    /// other dotfiles are shown. A file node (or unreadable dir) yields
    /// `[]`.
    func children(of node: FileNode) -> [FileNode] {
        guard node.isDirectory else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        let nodes = entries.compactMap { url -> FileNode? in
            let name = url.lastPathComponent
            guard !Self.hiddenNames.contains(name) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(url: url, name: name, isDirectory: isDir, isRepoRoot: false)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter FileTreeStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/FileNode.swift Sources/Dreamux/Models/FileTreeStore.swift Tests/DreamuxTests/FileTreeStoreTests.swift
git commit -m "Add FileTreeStore resolving cross-repo worktree file tree"
```

---

## Task 2: Vendor Monaco + `MonacoSchemeHandler` + resource bundling

**Files:**
- Create: `Sources/Dreamux/Resources/Monaco/` (vendored `vs/` + `index.html` + `editor-boot.js`)
- Create: `Sources/Dreamux/Views/MonacoSchemeHandler.swift`
- Modify: `Package.swift:22-32` (add `resources:` to the `Dreamux` target)
- Test: `Tests/DreamuxTests/MonacoSchemeHandlerTests.swift`

**Interfaces:**
- Produces:
  - `final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler` with
    `static let scheme = "app-monaco"`, `static var bundledRoot: URL`,
    `static func relativePath(for url: URL) -> String?`,
    `static func mimeType(forPathExtension ext: String) -> String`.
  - `Bundle.module` becomes available on the `Dreamux` target (has resources now).

- [ ] **Step 1: Vendor the Monaco `min` build (offline, one-time)**

Fetch the pinned tarball from the npm registry and copy only the runtime `min/vs` tree:

```bash
cd "$(mktemp -d)"
curl -sSL -o monaco.tgz https://registry.npmjs.org/monaco-editor/-/monaco-editor-0.52.2.tgz
tar xzf monaco.tgz            # extracts into ./package
DEST="$OLDPWD/Sources/Dreamux/Resources/Monaco"
mkdir -p "$DEST"
cp -R package/min/vs "$DEST/vs"
cd "$OLDPWD"
ls Sources/Dreamux/Resources/Monaco/vs/loader.js   # sanity: must exist
```

Expected: `Sources/Dreamux/Resources/Monaco/vs/loader.js` exists (plus `vs/editor/…`, `vs/base/worker/workerMain.js`, `vs/basic-languages/…`, `vs/language/…`).

- [ ] **Step 2: Write the Monaco boot page**

Create `Sources/Dreamux/Resources/Monaco/index.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    html, body, #container { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; }
  </style>
</head>
<body>
  <div id="container"></div>
  <script src="app-monaco://app/vs/loader.js"></script>
  <script src="app-monaco://app/editor-boot.js"></script>
</body>
</html>
```

Create `Sources/Dreamux/Resources/Monaco/editor-boot.js`:

```js
require.config({ paths: { vs: 'app-monaco://app/vs' } });

// Monaco runs language services in web workers. Under a custom scheme the
// worker script can't be fetched cross-origin, so route worker creation
// through a data: URL that importScripts the real worker (standard
// Monaco offline workaround).
self.MonacoEnvironment = {
  getWorkerUrl: function (moduleId, label) {
    var base = 'app-monaco://app/vs';
    var proxy = 'self.MonacoEnvironment = { baseUrl: "' + base + '/" };' +
      'importScripts("' + base + '/base/worker/workerMain.js");';
    return 'data:text/javascript;charset=utf-8,' + encodeURIComponent(proxy);
  }
};

function post(msg) { window.webkit.messageHandlers.bridge.postMessage(msg); }

require(['vs/editor/editor.main'], function () {
  var editor = monaco.editor.create(document.getElementById('container'), {
    value: '',
    language: 'plaintext',
    theme: 'vs',
    automaticLayout: true,
    minimap: { enabled: true }
  });

  editor.onDidChangeModelContent(function () {
    post({ type: 'dirty', value: true });
  });

  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
    post({ type: 'save', text: editor.getValue() });
  });

  // Swift → editor: install a file's contents/language/theme.
  window.__setContents = function (text, language, theme) {
    monaco.editor.setTheme(theme);
    editor.setModel(monaco.editor.createModel(text, language));
    post({ type: 'dirty', value: false });
  };

  post({ type: 'ready' });
});
```

- [ ] **Step 3: Declare the resource bundle**

Modify `Package.swift` — the `Dreamux` executable target. Add a `resources:` argument alongside the existing `exclude:`:

```swift
        .executableTarget(
            name: "Dreamux",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Bonsplit", package: "bonsplit"),
                "DreamuxPTY",
            ],
            path: "Sources/Dreamux",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"],
            resources: [.copy("Resources/Monaco")]
        ),
```

- [ ] **Step 4: Write the failing test**

Create `Tests/DreamuxTests/MonacoSchemeHandlerTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class MonacoSchemeHandlerTests: XCTestCase {
    func testRelativePathStripsHostAndLeadingSlash() {
        XCTAssertEqual(
            MonacoSchemeHandler.relativePath(for: URL(string: "app-monaco://app/vs/loader.js")!),
            "vs/loader.js"
        )
    }

    func testRelativePathDefaultsToIndex() {
        XCTAssertEqual(
            MonacoSchemeHandler.relativePath(for: URL(string: "app-monaco://app")!),
            "index.html"
        )
    }

    func testRelativePathRejectsForeignScheme() {
        XCTAssertNil(MonacoSchemeHandler.relativePath(for: URL(string: "https://example.com/x")!))
    }

    func testMimeTypes() {
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "js"), "text/javascript")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "CSS"), "text/css")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "ttf"), "font/ttf")
        XCTAssertEqual(MonacoSchemeHandler.mimeType(forPathExtension: "xyz"), "application/octet-stream")
    }

    func testVendoredAssetsArePresentInBundle() {
        let root = MonacoSchemeHandler.bundledRoot
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("index.html").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("editor-boot.js").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("vs/loader.js").path))
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `swift test --filter MonacoSchemeHandlerTests`
Expected: FAIL — `cannot find 'MonacoSchemeHandler' in scope`.

- [ ] **Step 6: Write `MonacoSchemeHandler`**

Create `Sources/Dreamux/Views/MonacoSchemeHandler.swift`:

```swift
import Foundation
import WebKit

/// Serves the vendored Monaco editor assets to a `WKWebView` over the
/// custom `app-monaco://` scheme. A custom scheme (rather than `file://`)
/// is required so Monaco's language-service web workers load without
/// cross-origin/worker restrictions.
///
/// URL shape: `app-monaco://app/<path>` → `<Monaco resource dir>/<path>`.
final class MonacoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app-monaco"

    /// Root of the bundled Monaco assets (the copied `Resources/Monaco`
    /// directory inside the SwiftPM resource bundle).
    static var bundledRoot: URL {
        Bundle.module.url(forResource: "Monaco", withExtension: nil)!
    }

    private let root: URL

    override convenience init() {
        self.init(root: MonacoSchemeHandler.bundledRoot)
    }

    init(root: URL) {
        self.root = root
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let relative = Self.relativePath(for: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let fileURL = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(forPathExtension: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// `app-monaco://app/vs/loader.js` → `vs/loader.js`. A bare host maps
    /// to `index.html`. Non-`app-monaco` URLs return nil.
    static func relativePath(for url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? "index.html" : path
    }

    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "ttf": return "font/ttf"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter MonacoSchemeHandlerTests`
Expected: PASS (5 tests). If `testVendoredAssetsArePresentInBundle` fails, re-check Step 1 copied `vs/` and Step 3 added `resources:`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/Resources/Monaco Sources/Dreamux/Views/MonacoSchemeHandler.swift Package.swift Tests/DreamuxTests/MonacoSchemeHandlerTests.swift
git commit -m "Vendor Monaco 0.52.2 and serve it over app-monaco:// scheme"
```

---

## Task 3: `FileEditorTabSession`

**Files:**
- Create: `Sources/Dreamux/Models/FileEditorTabSession.swift`
- Test: `Tests/DreamuxTests/FileEditorTabSessionTests.swift`

**Interfaces:**
- Consumes: `MonacoSchemeHandler` (`scheme`, and its `WKURLSchemeHandler` conformance).
- Produces: `@MainActor @Observable final class FileEditorTabSession: Identifiable` with
  `let fileURL: URL`, `var title: String`, `var isDirty: Bool`, `let isSupported: Bool`,
  `var webView: WKWebView` (lazy), and pure statics
  `static func language(forExtension:) -> String`, `static func readText(at:) -> String?`,
  `static func jsString(_:) -> String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/FileEditorTabSessionTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class FileEditorTabSessionTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testLanguageForExtension() {
        XCTAssertEqual(FileEditorTabSession.language(forExtension: "swift"), "swift")
        XCTAssertEqual(FileEditorTabSession.language(forExtension: "TS"), "typescript")
        XCTAssertEqual(FileEditorTabSession.language(forExtension: "md"), "markdown")
        XCTAssertEqual(FileEditorTabSession.language(forExtension: "unknownext"), "plaintext")
    }

    func testReadTextReturnsContentsForSmallUTF8File() throws {
        let url = sandbox.root.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileEditorTabSession.readText(at: url), "let x = 1\n")
    }

    func testReadTextRejectsBinary() throws {
        let url = sandbox.root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        XCTAssertNil(FileEditorTabSession.readText(at: url))
    }

    func testReadTextRejectsOversized() throws {
        let url = sandbox.root.appendingPathComponent("big.txt")
        try Data(count: 3 * 1024 * 1024).write(to: url) // 3 MB > 2 MB cap
        XCTAssertNil(FileEditorTabSession.readText(at: url))
    }

    func testJsStringQuotesAndEscapes() {
        XCTAssertEqual(FileEditorTabSession.jsString("hi"), "\"hi\"")
        // A quote and newline must come back escaped inside the literal.
        let out = FileEditorTabSession.jsString("a\"b\nc")
        XCTAssertTrue(out.hasPrefix("\"") && out.hasSuffix("\""))
        XCTAssertTrue(out.contains("\\\""))
        XCTAssertTrue(out.contains("\\n"))
    }

    @MainActor
    func testSupportedFlagReflectsReadability() throws {
        let text = sandbox.root.appendingPathComponent("ok.swift")
        try "hi".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileEditorTabSession(fileURL: text).isSupported)

        let bin = sandbox.root.appendingPathComponent("x.bin")
        try Data([0xFF, 0xFE]).write(to: bin)
        XCTAssertFalse(FileEditorTabSession(fileURL: bin).isSupported)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileEditorTabSessionTests`
Expected: FAIL — `cannot find 'FileEditorTabSession' in scope`.

- [ ] **Step 3: Write `FileEditorTabSession`**

Create `Sources/Dreamux/Models/FileEditorTabSession.swift`:

```swift
import AppKit
import Foundation
import Observation
import WebKit

/// State behind one Monaco editor tab. Mirrors `WebTabSession`: a lazily
/// built `WKWebView` (here hosting the vendored Monaco editor over the
/// `app-monaco://` scheme) plus dirty tracking and ⌘S save back to the
/// worktree file. A tab id maps to exactly one of the three session
/// kinds (terminal / web / file) in `WorkspaceSession`.
@MainActor
@Observable
final class FileEditorTabSession: Identifiable {
    let id = UUID()
    /// Absolute, symlink-resolved path of the edited file. Dedup key.
    let fileURL: URL
    var title: String
    var isDirty = false
    /// False when the file can't be shown in a text editor (binary or
    /// larger than the cap); the view shows a placeholder instead.
    let isSupported: Bool

    private let contents: String
    private static let maxBytes = 2 * 1024 * 1024

    @ObservationIgnored private var _webView: WKWebView?
    /// One handler serves every editor tab's assets.
    @ObservationIgnored private static let schemeHandler = MonacoSchemeHandler()

    init(fileURL: URL) {
        let resolved = fileURL.resolvingSymlinksInPath()
        self.fileURL = resolved
        self.title = resolved.lastPathComponent
        let loaded = Self.readText(at: resolved)
        self.contents = loaded ?? ""
        self.isSupported = loaded != nil
    }

    var webView: WKWebView {
        if let _webView { return _webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(Self.schemeHandler, forURLScheme: MonacoSchemeHandler.scheme)
        config.userContentController.add(Bridge(owner: self), name: "bridge")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.load(URLRequest(url: URL(string: "\(MonacoSchemeHandler.scheme)://app/index.html")!))
        _webView = view
        return view
    }

    // MARK: - Pure helpers (unit-tested)

    /// Read a file as UTF-8 if it's within the size cap and decodes as
    /// text; nil for binary/oversized files.
    static func readText(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Monaco language id for a file extension.
    static func language(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "jsx": return "typescript"
        case "json": return "json"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "sh", "bash", "zsh": return "shell"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "xml": return "xml"
        default: return "plaintext"
        }
    }

    /// Encode a Swift string as a JS string literal (quotes + escapes) so
    /// it can be interpolated into an `evaluateJavaScript` call.
    static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let json = String(data: data, encoding: .utf8)!   // ["…"]
        return String(json.dropFirst().dropLast())          // strip surrounding [ ]
    }

    static func currentTheme() -> String {
        let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? "vs-dark" : "vs"
    }

    // MARK: - Bridge handling

    private func handleReady() {
        let js = "window.__setContents("
            + "\(Self.jsString(contents)), "
            + "\(Self.jsString(Self.language(forExtension: fileURL.pathExtension))), "
            + "\(Self.jsString(Self.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }

    private func handleSave(text: String) {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            isDirty = false
        } catch {
            NSSound.beep()
        }
    }

    /// Separate NSObject so the session itself needn't inherit NSObject;
    /// holds the owner weakly to avoid a webView→config→controller→handler
    /// retain cycle.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: FileEditorTabSession?
        init(owner: FileEditorTabSession) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            MainActor.assumeIsolated {
                guard let owner else { return }
                switch type {
                case "ready": owner.handleReady()
                case "dirty": owner.isDirty = (body["value"] as? Bool) ?? false
                case "save": owner.handleSave(text: (body["text"] as? String) ?? "")
                default: break
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileEditorTabSessionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FileEditorTabSession.swift Tests/DreamuxTests/FileEditorTabSessionTests.swift
git commit -m "Add FileEditorTabSession hosting Monaco with save + dirty tracking"
```

---

## Task 4: `WorkspaceSession.openFileTab` + dispatch

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift`
- Test: `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift`

**Interfaces:**
- Consumes: `FileEditorTabSession(fileURL:)`, `BonsplitController.createTab`, `.selectTab`.
- Produces on `WorkspaceSession`: `func openFileTab(at fileURL: URL)`,
  `func fileTabSession(for tabId: TabID) -> FileEditorTabSession?`,
  `var openFileTabURLs: [URL]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class WorkspaceSessionFileTabTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    @MainActor
    func testOpenFileTabCreatesSessionAndDedupsByPath() throws {
        let a = sandbox.root.appendingPathComponent("a.swift")
        try "let x = 1".write(to: a, atomically: true, encoding: .utf8)
        let session = WorkspaceSession(
            workspace: Workspace(name: "f", workingDirectory: sandbox.root.path)
        )

        session.openFileTab(at: a)
        XCTAssertEqual(session.openFileTabURLs.map(\.lastPathComponent), ["a.swift"])

        // Reopening the same file re-focuses — no second session.
        session.openFileTab(at: a)
        XCTAssertEqual(session.openFileTabURLs.count, 1)

        // A different file opens a distinct session.
        let b = sandbox.root.appendingPathComponent("b.swift")
        try "let y = 2".write(to: b, atomically: true, encoding: .utf8)
        session.openFileTab(at: b)
        XCTAssertEqual(session.openFileTabURLs.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkspaceSessionFileTabTests`
Expected: FAIL — `value of type 'WorkspaceSession' has no member 'openFileTab'`.

- [ ] **Step 3: Add the file-tab map + override property**

In `Sources/Dreamux/Models/WorkspaceSession.swift`, add next to the existing session maps (after the `webTabSessions` declaration near line 17):

```swift
    /// In-app Monaco editor tabs, keyed by the same Bonsplit tab ids as
    /// the terminals — a tab id appears in exactly one of the three maps.
    private var fileTabSessions: [TabID: FileEditorTabSession] = [:]
    /// Propagates each editor tab's `isDirty` to its Bonsplit tab chip,
    /// so an unsaved file shows the dirty indicator (mirrors how
    /// `titleObservers` propagates terminal titles).
    private var fileDirtyObservers: [TabID: FileTabDirtyObserver] = [:]
```

Add, next to `nextTabWebURL` (near line 206):

```swift
    /// File claimed by the next created tab — the editor analog of
    /// `nextTabWebURL`, read once in `handleDidCreateTab`.
    private var nextTabFileURL: URL?
```

- [ ] **Step 4: Dispatch file tabs in `handleDidCreateTab`**

In `handleDidCreateTab` (near line 123), update the dedup guard to include the third map, and add the file branch **before** the web branch:

```swift
    private func handleDidCreateTab(_ tab: Tab) {
        guard tabSessions[tab.id] == nil,
              webTabSessions[tab.id] == nil,
              fileTabSessions[tab.id] == nil else { return }

        // File tab: the pending file URL (set by openFileTab just before
        // createTab) claims this tab id.
        if let fileURL = nextTabFileURL {
            nextTabFileURL = nil
            let fileSession = FileEditorTabSession(fileURL: fileURL)
            fileTabSessions[tab.id] = fileSession
            fileDirtyObservers[tab.id] = FileTabDirtyObserver(
                tabId: tab.id, session: fileSession, controller: controller
            )
            return
        }

        // Web tab: the pending URL (set by openWebTab just before
        // createTab) claims this tab id instead of spawning a shell.
        if let url = nextTabWebURL {
            nextTabWebURL = nil
            webTabSessions[tab.id] = WebTabSession(url: url)
            return
        }
        // ...existing terminal-session code below stays unchanged...
```

- [ ] **Step 5: Clean up on close + add accessors + open method**

In `handleDidCloseTab` (near line 152) add the file-map removal:

```swift
    private func handleDidCloseTab(_ tabId: TabID) {
        tabSessions[tabId]?.stop()
        tabSessions.removeValue(forKey: tabId)
        webTabSessions.removeValue(forKey: tabId)
        fileTabSessions.removeValue(forKey: tabId)
        fileDirtyObservers.removeValue(forKey: tabId)
        titleObservers.removeValue(forKey: tabId)
    }
```

Add the accessor next to `webTabSession(for:)` (near line 77):

```swift
    func fileTabSession(for tabId: TabID) -> FileEditorTabSession? {
        fileTabSessions[tabId]
    }
```

Add the open method next to `openWebTab` (near line 212), plus the e2e accessor next to `webTabURLs` (near line 82):

```swift
    /// Open (or re-select) a Monaco editor tab for `fileURL`. Dedup is by
    /// resolved absolute path so the same file re-focuses its existing
    /// tab rather than stacking a duplicate (like `openWebTab`).
    func openFileTab(at fileURL: URL) {
        let resolved = fileURL.resolvingSymlinksInPath()
        if let existing = fileTabSessions.first(where: { $0.value.fileURL == resolved }) {
            controller.selectTab(existing.key)
            return
        }
        nextTabFileURL = resolved
        controller.createTab(title: resolved.lastPathComponent, icon: "doc.text")
        nextTabFileURL = nil
    }
```

```swift
    /// Resolved paths of every open editor tab, for the e2e state dump.
    var openFileTabURLs: [URL] {
        fileTabSessions.values.map(\.fileURL)
    }
```

- [ ] **Step 6: Add the dirty-state observer**

At the bottom of `WorkspaceSession.swift`, next to the existing `TitleObserver` (near line 319), add a parallel observer that mirrors a file tab's `isDirty` onto its Bonsplit tab chip:

```swift
/// Re-arms `withObservationTracking` so an editor tab's `isDirty` flows
/// back into the Bonsplit controller and shows the tab's dirty indicator.
@MainActor
private final class FileTabDirtyObserver {
    private let tabId: TabID
    private weak var session: FileEditorTabSession?
    private weak var controller: BonsplitController?

    init(tabId: TabID, session: FileEditorTabSession, controller: BonsplitController) {
        self.tabId = tabId
        self.session = session
        self.controller = controller
        arm()
    }

    private func arm() {
        guard let session else { return }
        withObservationTracking {
            _ = session.isDirty
        } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        guard let session, let controller else { return }
        controller.updateTab(tabId, isDirty: session.isDirty)
        arm()
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter WorkspaceSessionFileTabTests`
Expected: PASS (1 test).

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/Models/WorkspaceSession.swift Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift
git commit -m "Add openFileTab (dedup by path) as a third Bonsplit tab kind"
```

---

## Task 5: `FileEditorView` + `TabContentView` branch

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`

**Interfaces:**
- Consumes: `WorkspaceSession.fileTabSession(for:)`, `FileEditorTabSession` (`webView`, `isSupported`, `title`).
- Produces: file editor tabs render inside the Bonsplit pane.

*No unit test — SwiftUI view wiring. Verified by build + the manual check in Task 7.*

- [ ] **Step 1: Add the third branch in `TabContentView`**

In `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`, update `TabContentView.body` (near line 53) to dispatch file tabs between terminal and web:

```swift
    var body: some View {
        if let tabSession = session.tabSession(for: tabId) {
            TerminalSurfaceView(context: tabSession.viewState)
                .onAppear { tabSession.startIfNeeded() }
        } else if let fileTab = session.fileTabSession(for: tabId) {
            FileEditorView(session: fileTab)
        } else if let webTab = session.webTabSession(for: tabId) {
            WebTabView(session: webTab)
        } else {
            Color.clear
        }
    }
```

- [ ] **Step 2: Add `FileEditorView`**

Add to the same file (near the other private views, e.g. after `WebViewRepresentable` around line 142):

```swift
/// A Monaco editor tab: the session's Monaco-hosting `WKWebView`, or a
/// placeholder when the file is binary/oversized.
private struct FileEditorView: View {
    @Bindable var session: FileEditorTabSession

    var body: some View {
        if session.isSupported {
            FileEditorWebView(webView: session.webView)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Can't display \(session.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("It's binary or larger than 2 MB.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FileEditorWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
```

(`WebKit` is already imported at the top of this file.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Render file editor tabs in the Bonsplit pane"
```

---

## Task 6: `FileTreePanel` view

**Files:**
- Create: `Sources/Dreamux/Views/FileTreePanel.swift`

**Interfaces:**
- Consumes: `WorkspaceStore.activeWorkspace`, `RepoStore.repositories`, `FileTreeStore.roots(...)`/`.children(...)`.
- Produces: `struct FileTreePanel: View` initialised as
  `FileTreePanel(store:, repoStore:, tree:, onOpenFile:)`.

*No unit test — SwiftUI view. Verified by build + the manual check in Task 7.*

- [ ] **Step 1: Write `FileTreePanel`**

Create `Sources/Dreamux/Views/FileTreePanel.swift`:

```swift
import SwiftUI

/// The right-side file explorer (a native `.inspector` panel). Presents
/// the active feature's linked-repo worktrees as one tree — each repo a
/// top-level node — and opens a file as a Monaco editor tab on click.
struct FileTreePanel: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void

    /// Bumped by the refresh button to force a fresh disk read of the
    /// (uncached) tree.
    @State private var reloadToken = UUID()

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
                        FileTreeRow(node: root, tree: tree, onOpenFile: onOpenFile)
                    }
                }
                .listStyle(.sidebar)
                .id(reloadToken)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(store.activeWorkspace?.name ?? "Files")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        .padding(.vertical, 8)
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

/// One row in the tree. Directories are lazy `DisclosureGroup`s (children
/// read from disk only while expanded); files are buttons that open an
/// editor tab. Repo roots default to expanded.
private struct FileTreeRow: View {
    let node: FileNode
    let tree: FileTreeStore
    let onOpenFile: (URL) -> Void
    @State private var expanded: Bool

    init(node: FileNode, tree: FileTreeStore, onOpenFile: @escaping (URL) -> Void) {
        self.node = node
        self.tree = tree
        self.onOpenFile = onOpenFile
        _expanded = State(initialValue: node.isRepoRoot)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    ForEach(tree.children(of: node)) { child in
                        FileTreeRow(node: child, tree: tree, onOpenFile: onOpenFile)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.isRepoRoot ? "shippingbox.fill" : "folder.fill")
                    .font(.callout)
                    .lineLimit(1)
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
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/FileTreePanel.swift
git commit -m "Add FileTreePanel native source-list inspector view"
```

---

## Task 7: Wire the inspector into `ContentView`

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift`

**Interfaces:**
- Consumes: `FileTreeStore`, `FileTreePanel`, `WorkspaceStore.session(for:).openFileTab(at:)`.
- Produces: a toggleable right-side file explorer in the project window.

*No unit test — integration. Verified by build + a manual run.*

- [ ] **Step 1: Add inspector state + tree store**

In `ContentView` add the visibility flag alongside `sidebarMode` (near line 22):

```swift
    @State private var showFileTree = false
```

Declare the tree store next to the other `@State` stores (`runConfig`/`signals`/`runners`, near line 25) **without** an inline default:

```swift
    @State private var fileTree: FileTreeStore
```

And initialize it in `ContentView.init` alongside the other stores (after `_runners = State(...)`, near line 67) — matching the codebase pattern and avoiding a main-actor isolation warning from an inline default:

```swift
        _fileTree = State(initialValue: FileTreeStore())
```

- [ ] **Step 2: Attach `.inspector`, toolbar toggle, and open wiring**

In `body`, add these modifiers to the `NavigationSplitView` (place them right after the existing `.navigationSubtitle(...)` near line 93):

```swift
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showFileTree.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .keyboardShortcut("e", modifiers: [.option, .command])
                .help("Toggle file explorer (⌥⌘E)")
            }
        }
        .inspector(isPresented: $showFileTree) {
            FileTreePanel(
                store: store,
                repoStore: repoStore,
                tree: fileTree,
                onOpenFile: openFile
            )
            .inspectorColumnWidth(min: 220, ideal: 280, max: 480)
        }
```

- [ ] **Step 3: Add the `openFile` helper**

Add to `ContentView` (e.g. after `mainPane`, near line 132):

```swift
    /// Open a file (clicked in the tree) as a Monaco tab in the active
    /// feature's pane. Flips to the terminal/tab view so the new tab is
    /// visible, mirroring `openBrowserTab`'s behavior.
    private func openFile(_ url: URL) {
        guard let workspace = store.activeWorkspace else { return }
        sidebarMode = .workspace
        store.session(for: workspace).openFileTab(at: url)
    }
```

- [ ] **Step 4: Build + assemble the app**

Run: `swift build && ./scripts/make-app.sh debug`
Expected: `Built .../Dreamux.app` (the script copies the `Dreamux_Dreamux.bundle`, so Monaco ships inside the `.app`).

- [ ] **Step 5: Manual verification**

Run: `open ./Dreamux.app`

Then, in a project that has at least one feature spanning one or more repos:
1. Press **⌥⌘E** (or click the `sidebar.right` toolbar button). The right panel opens showing each linked repo as a top-level node.
2. Disclose a repo and click a source file → a `doc.text` editor tab opens next to the terminal, showing the file in Monaco with syntax highlighting.
3. Edit a line — the tab shows a dirty indicator. Press **⌘S**; confirm the file changed on disk (`git status` in that worktree shows it modified).
4. Click the same file again in the tree → it re-focuses the existing tab (no duplicate).
5. Switch the active feature → the tree re-roots to the new feature's repos.

Expected: all five behave as described. If Monaco renders blank, open the tab's Web Inspector (right-click → Inspect Element, enabled via `isInspectable`) and check for `app-monaco://` load failures — usually a missing `vs/` asset from Task 2 Step 1.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift
git commit -m "Add toggleable right-side file explorer inspector (⌥⌘E)"
```

---

## Task 8: E2E command + state surface

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift`
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`
- Modify: `scripts/e2e/PROTOCOL.md`

**Interfaces:**
- Consumes: `E2EBridge`, `WorkspaceStore`, `WorkspaceSession.openFileTab`/`openFileTabURLs`.
- Produces: `openFile` + `setFileTree` commands; `fileTabs` per-workspace in `state`;
  `E2EBridge.pendingFileTreeVisible`.

*No Swift unit test — the Python e2e driver exercises these. Verified by build + protocol doc; a manual `state` round-trip is optional.*

- [ ] **Step 1: Add the bridge field + consume it in ContentView**

In `Sources/Dreamux/E2E/E2ERegistry.swift`, add to `E2EBridge` (after `pendingMergeWorkspaceID`, near line 23):

```swift
    /// Desired visibility of the right-side file explorer, parked by the
    /// `setFileTree` command and consumed by `ContentView`.
    var pendingFileTreeVisible: Bool?
```

In `Sources/Dreamux/Views/ContentView.swift`, consume it — add an `.onChange` next to the existing `sidebarMode` handlers (near line 110):

```swift
        .onChange(of: e2eBridge?.pendingFileTreeVisible) { _, _ in
            if let bridge = e2eBridge, let visible = bridge.pendingFileTreeVisible {
                bridge.pendingFileTreeVisible = nil
                showFileTree = visible
            }
        }
```

- [ ] **Step 2: Add `fileTabs` to the state dump**

In `Sources/Dreamux/E2E/E2ECommands.swift`, in `stateReply()` where each workspace dict is built (near line 130), add a `fileTabs` key beside `webTabs`:

```swift
                    "webTabs": store.session(for: workspace).webTabURLs
                        .map(\.absoluteString),
                    "fileTabs": store.session(for: workspace).openFileTabURLs
                        .map(\.path),
```

- [ ] **Step 3: Add the two commands**

In `E2ECommands.run(cmd:request:)` dispatch (near line 51), add two cases:

```swift
        case "openFile":
            return try openFile(request: request)
        case "setFileTree":
            return try setFileTree(request: request)
```

Add the two handlers (near the other sidebar handlers, e.g. after `setSidebarMode`, near line 330):

```swift
    /// Open a file as a Monaco editor tab in the active (or named)
    /// workspace — the same path the file tree's click uses.
    private static func openFile(request: [String: Any]) throws -> [String: Any] {
        let path = try string("path", in: request)
        guard path.hasPrefix("/") else {
            throw CommandError(message: "\"path\" must be an absolute path")
        }
        let (_, store, _) = try projectStores()
        let workspace: Workspace
        if let name = request["workspace"] as? String {
            workspace = try self.workspace(named: name)
        } else if let active = store.activeWorkspace ?? store.workspaces.first {
            workspace = active
        } else {
            throw CommandError(message: "no workspace to open the file in")
        }
        store.activate(workspace.id)
        store.session(for: workspace).openFileTab(at: URL(fileURLWithPath: path))
        return ["ok": true]
    }

    /// Toggle the right-side file explorer inspector.
    private static func setFileTree(request: [String: Any]) throws -> [String: Any] {
        guard let visible = request["visible"] as? Bool else {
            throw CommandError(message: "missing boolean \"visible\" parameter")
        }
        let (handles, _, _) = try projectStores()
        handles.bridge.pendingFileTreeVisible = visible
        return ["ok": true]
    }
```

- [ ] **Step 4: Document the commands in PROTOCOL.md**

In `scripts/e2e/PROTOCOL.md`, add entries mirroring the existing command docs:

```markdown
### `openFile`
Open a file as a Monaco editor tab in the active (or named) workspace.
Request: `{"cmd":"openFile","path":"/abs/path/to/file","workspace":"<name?>"}`
Response: `{"ok":true}`

### `setFileTree`
Show/hide the right-side file explorer inspector.
Request: `{"cmd":"setFileTree","visible":true}`
Response: `{"ok":true}`

`state` now reports `fileTabs` (absolute paths of open editor tabs) beside
`webTabs` in each `workspaces[]` entry.
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/E2E/E2ERegistry.swift Sources/Dreamux/E2E/E2ECommands.swift scripts/e2e/PROTOCOL.md
git commit -m "Expose file tree + editor tabs to the e2e automation server"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `swift test`
Expected: All tests pass, including `FileTreeStoreTests`, `MonacoSchemeHandlerTests`, `FileEditorTabSessionTests`, `WorkspaceSessionFileTabTests`.

- [ ] **Assemble + smoke-test the app**

Run: `./scripts/make-app.sh debug && open ./Dreamux.app`
Re-run the Task 7 Step 5 manual checklist end-to-end.

---

## Self-review notes (coverage vs. spec)

- Right-side toggleable panel → Task 7 (`.inspector` + ⌥⌘E).
- Feature-scoped unified tree, each repo a root → Task 1 (`FileTreeStore.roots`).
- Open file as Bonsplit tab, dedup by path → Task 4.
- Real Monaco in WKWebView, offline via custom scheme → Tasks 2–3, 5.
- ⌘S save to worktree file → Task 3 (`handleSave`). Dirty dot on the tab chip → Task 4 (`FileTabDirtyObserver` mirrors `session.isDirty` onto the Bonsplit tab via `updateTab(id, isDirty:)`).
- Binary/oversized guard → Task 3 (`readText`) + Task 5 placeholder.
- Empty states, feature-switch re-root → Tasks 6–7.
- Unit + e2e testing → Tasks 1–4 (unit), Task 8 (e2e).
```
