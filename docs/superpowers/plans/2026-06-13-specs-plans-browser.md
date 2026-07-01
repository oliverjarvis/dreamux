# Specs & Plans Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only in-app browser for the superpowers documents (`docs/superpowers/specs/*.md`, `docs/superpowers/plans/*.md`) across every worktree of every repo in a project, reached via a "Specs & Plans" sidebar tile.

**Architecture:** A new `DocStore` model scans worktrees with plain FileManager calls (the worktree directory name is the branch name in the Dreamux bare-repo layout) and dedupes copies of the same file across worktrees. A new `DocsBrowserView` renders a master list + MarkdownUI detail pane, swapped in via a new `SidebarMode.docs` case — the exact pattern `SignalsView` uses. E2E support follows the existing registry/bridge conventions (`listDocs` command, `"docs"` sidebar mode).

**Tech Stack:** Swift 6 / SwiftUI (macOS 14), swift-markdown-ui 2.4.1 (new SPM dependency), XCTest with `TestSandbox`/`GitFixtures` (real git repos, no mocks), Python e2e driver.

**Spec:** `docs/superpowers/specs/2026-06-12-specs-plans-browser-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/Dreamux/Models/DocStore.swift` | Create | `DocKind`/`DocProgress`/`DocEntry` types, parsing helpers, worktree scan + dedupe |
| `Sources/Dreamux/Views/DocsBrowserView.swift` | Create | Master-detail browser UI (list + MarkdownUI rendering) |
| `Tests/DreamuxTests/DocStoreParsingTests.swift` | Create | Pure-parsing unit tests (no filesystem) |
| `Tests/DreamuxTests/DocStoreScanTests.swift` | Create | Scan/dedupe tests over real sandbox repos |
| `Package.swift` | Modify | Add swift-markdown-ui dependency |
| `Sources/Dreamux/Views/ContentView.swift` | Modify | `SidebarMode.docs`, `DocStore` creation, main-pane case, registry call |
| `Sources/Dreamux/Views/WorkspaceSidebar.swift` | Modify | "Specs & Plans" tile, exhaustive-switch update |
| `Sources/Dreamux/E2E/E2ERegistry.swift` | Modify | `docs` handle on `E2EProjectHandles`, `registerRunStores` param |
| `Sources/Dreamux/E2E/E2ECommands.swift` | Modify | `"docs"` mode name + `setSidebarMode` case, `listDocs` command |
| `Scripts/e2e/PROTOCOL.md` | Modify | Document `"docs"` mode and `listDocs` |
| `Scripts/e2e/driver.py` | Modify | `docs-browser` scenario |

All builds and tests run from the repo root: `/Users/olliejarvis/Development/clayspace` (or the executing worktree's root). The project is SwiftPM-only — no Xcode project. `swift build` and `swift test` are the only build commands.

---

### Task 1: DocStore types and parsing helpers

**Files:**
- Create: `Sources/Dreamux/Models/DocStore.swift`
- Test: `Tests/DreamuxTests/DocStoreParsingTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/DocStoreParsingTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Pure-parsing coverage for `DocStore`'s static helpers — no
/// filesystem. Scan/dedupe behavior over real worktrees lives in
/// `DocStoreScanTests`.
@MainActor
final class DocStoreParsingTests: XCTestCase {
    // MARK: - parseTitle

    func testParseTitleReturnsFirstH1() {
        let md = "Some preamble\n\n# Real Title\n\n# Second Title\n"
        XCTAssertEqual(DocStore.parseTitle(markdown: md, fallback: "fb"), "Real Title")
    }

    func testParseTitleIgnoresDeeperHeadingsAndFallsBack() {
        let md = "## Subheading only\ntext\n"
        XCTAssertEqual(
            DocStore.parseTitle(markdown: md, fallback: "2026-06-12-foo"),
            "2026-06-12-foo"
        )
    }

    func testParseTitleTrimsIndentationAndWhitespace() {
        let md = "   #  Padded Title  \n"
        XCTAssertEqual(DocStore.parseTitle(markdown: md, fallback: "fb"), "Padded Title")
    }

    // MARK: - parseDatePrefix

    func testParseDatePrefixValid() {
        XCTAssertEqual(
            DocStore.parseDatePrefix(fileName: "2026-06-12-foo-design.md"),
            "2026-06-12"
        )
    }

    func testParseDatePrefixRejectsImpossibleDate() {
        XCTAssertNil(DocStore.parseDatePrefix(fileName: "2026-99-99-foo.md"))
    }

    func testParseDatePrefixRejectsMissingPrefix() {
        XCTAssertNil(DocStore.parseDatePrefix(fileName: "foo-design.md"))
    }

    // MARK: - parseProgress

    func testParseProgressCountsCheckedAndUnchecked() {
        let md = """
        ### Task 1
        - [x] **Step 1: Write the failing test**
        - [X] **Step 2: Run it**
          - [ ] **Step 3: Implement**
        - [ ] **Step 4: Commit**
        - regular bullet, not a checkbox
        """
        XCTAssertEqual(
            DocStore.parseProgress(markdown: md),
            DocProgress(checked: 2, total: 4)
        )
    }

    func testParseProgressNilWithoutCheckboxes() {
        XCTAssertNil(DocStore.parseProgress(markdown: "# Plan\nNo checkboxes here.\n"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DocStoreParsingTests`
Expected: FAIL to compile with `cannot find 'DocStore' in scope`

- [ ] **Step 3: Create DocStore.swift with types and parsing (no scan yet)**

Create `Sources/Dreamux/Models/DocStore.swift`:

```swift
import Foundation
import Observation

/// Which superpowers folder a document came from.
enum DocKind: String, CaseIterable, Hashable, Sendable {
    case spec
    case plan
}

/// Checkbox completion counted from a plan's `- [ ]` / `- [x]` lines.
struct DocProgress: Hashable, Sendable {
    var checked: Int
    var total: Int
}

/// One spec or plan markdown file discovered in a repo worktree.
struct DocEntry: Identifiable, Hashable, Sendable {
    let kind: DocKind
    let repoName: String
    /// Branch whose copy we surfaced — in the Dreamux layout a
    /// worktree directory is named after its branch.
    let branch: String
    /// True when `branch` is the repo's default branch; the UI only
    /// badges the branch when this is false.
    let isDefaultBranch: Bool
    /// Path relative to the worktree root, e.g.
    /// `docs/superpowers/specs/2026-06-12-foo-design.md`.
    let relativePath: String
    let fileURL: URL
    let title: String
    /// Validated `YYYY-MM-DD` filename prefix; nil when missing or not
    /// a real calendar date. ISO ordering makes string compare correct.
    let dateString: String?
    /// Plans only; nil for specs and for plans without checkboxes.
    let progress: DocProgress?

    /// Stable across rescans: one entry per (repo, file).
    var id: String { "\(repoName)|\(relativePath)" }

    var fileName: String { fileURL.lastPathComponent }
}

/// Discovers superpowers spec/plan markdown files across every worktree
/// of every repo in the project. Pure FileManager work — no git calls;
/// the worktree directory name is the branch name in this layout.
@MainActor
@Observable
final class DocStore {
    /// Folder conventions the superpowers skills write into. A future
    /// `.dreamux` override would land here.
    static let folders: [(kind: DocKind, relativePath: String)] = [
        (.spec, "docs/superpowers/specs"),
        (.plan, "docs/superpowers/plans"),
    ]

    private(set) var entries: [DocEntry] = []

    // MARK: - Parsing

    /// First `# ` heading, else the fallback (filename sans extension).
    static func parseTitle(markdown: String, fallback: String) -> String {
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# ") else { continue }
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return fallback
    }

    /// Validated `YYYY-MM-DD` prefix of a superpowers filename; nil when
    /// absent or not a real calendar date (2026-99-99 is a name, not a
    /// date).
    static func parseDatePrefix(fileName: String) -> String? {
        guard let range = fileName.range(
            of: #"^\d{4}-\d{2}-\d{2}-"#,
            options: .regularExpression
        ) else { return nil }
        let prefix = String(fileName[range].dropLast())
        let parts = prefix.split(separator: "-").map { Int($0) ?? 0 }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.calendar = Calendar(identifier: .gregorian)
        guard components.isValidDate else { return nil }
        return prefix
    }

    /// GFM task-list tally. nil when the document has no checkboxes —
    /// the UI hides the progress column rather than showing 0/0.
    static func parseProgress(markdown: String) -> DocProgress? {
        var checked = 0
        var total = 0
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- [ ]") {
                total += 1
            } else if line.lowercased().hasPrefix("- [x]") {
                checked += 1
                total += 1
            }
        }
        return total == 0 ? nil : DocProgress(checked: checked, total: total)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DocStoreParsingTests`
Expected: PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/DocStore.swift Tests/DreamuxTests/DocStoreParsingTests.swift
git commit -m "Add DocStore document parsing (title, date prefix, checkbox tally)" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Worktree scan and dedupe

**Files:**
- Modify: `Sources/Dreamux/Models/DocStore.swift` (add `refresh` between the `entries` property and the `// MARK: - Parsing` section)
- Test: `Tests/DreamuxTests/DocStoreScanTests.swift`

Background for the tests: `GitFixtures.makeBareLayoutRepo(in:name:files:)` builds the Dreamux `repos/<name>/{.bare, main}` layout and commits `files` (relative paths, intermediate dirs created) in the `main` worktree, returning a `Repository`. `GitOperations.addWorktree(in: repo.rootURL, branch:)` adds a worktree directory named after the branch, checked out from the default branch's tip — so its files start byte-identical to main's.

- [ ] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/DocStoreScanTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Scan/dedupe behavior over real bare-layout repos in a per-test
/// `TestSandbox` — real worktrees, no mocks, mirroring
/// FeatureProvisionerTests.
@MainActor
final class DocStoreScanTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUp() async throws {
        // Keep fixture commits working on machines with no global git
        // identity (same env trick as FeatureProvisionerTests).
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    func testScanFindsSpecsAndPlansWithMetadata() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha",
            files: [
                "docs/superpowers/specs/2026-06-12-foo-design.md": "# Foo Design\n\nBody.\n",
                "docs/superpowers/plans/2026-06-12-foo.md":
                    "# Foo Plan\n\n- [x] **Step 1**\n- [ ] **Step 2**\n- [ ] **Step 3**\n",
            ]
        )

        let store = DocStore()
        store.refresh(repositories: [repo])

        XCTAssertEqual(store.entries.count, 2)
        let spec = try XCTUnwrap(store.entries.first { $0.kind == .spec })
        XCTAssertEqual(spec.title, "Foo Design")
        XCTAssertEqual(spec.dateString, "2026-06-12")
        XCTAssertEqual(spec.branch, "main")
        XCTAssertTrue(spec.isDefaultBranch)
        XCTAssertNil(spec.progress)

        let plan = try XCTUnwrap(store.entries.first { $0.kind == .plan })
        XCTAssertEqual(plan.title, "Foo Plan")
        XCTAssertEqual(plan.progress, DocProgress(checked: 1, total: 3))
        XCTAssertEqual(plan.relativePath, "docs/superpowers/plans/2026-06-12-foo.md")
    }

    func testRepoWithoutDocsFoldersYieldsNoEntries() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["readme.txt": "hi\n"]
        )
        let store = DocStore()
        store.refresh(repositories: [repo])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testFeatureOnlyDocCarriesFeatureBranch() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["readme.txt": "hi\n"]
        )
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-x")
        let worktree = repo.rootURL.appendingPathComponent("feature-x", isDirectory: true)
        try write(
            "# Feature Spec\n",
            to: worktree.appendingPathComponent(
                "docs/superpowers/specs/2026-06-13-feature-design.md"
            )
        )

        let store = DocStore()
        store.refresh(repositories: [repo])

        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(entry.branch, "feature-x")
        XCTAssertFalse(entry.isDefaultBranch)
    }

    func testIdenticalCopiesPreferDefaultBranch() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha",
            files: ["docs/superpowers/specs/2026-06-12-foo-design.md": "# Foo Design\n"]
        )
        // The new worktree checks out main's tip, so its copy is
        // byte-identical (and its mtime — the checkout time — is newer;
        // content equality must trump recency here).
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-x")

        let store = DocStore()
        store.refresh(repositories: [repo])

        XCTAssertEqual(store.entries.count, 1)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.branch, "main")
        XCTAssertTrue(entry.isDefaultBranch)
    }

    func testDivergedCopiesPreferNewestModification() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha",
            files: ["docs/superpowers/plans/2026-06-12-foo.md":
                        "# Foo Plan\n- [ ] **Step 1**\n"]
        )
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-x")
        let mainCopy = repo.rootURL
            .appendingPathComponent("main/docs/superpowers/plans/2026-06-12-foo.md")
        let featureCopy = repo.rootURL
            .appendingPathComponent("feature-x/docs/superpowers/plans/2026-06-12-foo.md")
        try write("# Foo Plan\n- [x] **Step 1**\n", to: featureCopy)
        // Pin mtimes so the comparison can't ride on write timing.
        try setModificationDate(Date(timeIntervalSince1970: 1_000_000), at: mainCopy)
        try setModificationDate(Date(timeIntervalSince1970: 2_000_000), at: featureCopy)

        let store = DocStore()
        store.refresh(repositories: [repo])

        XCTAssertEqual(store.entries.count, 1)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.branch, "feature-x")
        XCTAssertEqual(entry.progress, DocProgress(checked: 1, total: 1))
    }

    func testSortsNewestDateFirstUndatedLast() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha",
            files: [
                "docs/superpowers/specs/2026-06-10-old-design.md": "# Old\n",
                "docs/superpowers/specs/2026-06-12-new-design.md": "# New\n",
                "docs/superpowers/specs/undated-design.md": "# Undated\n",
            ]
        )
        let store = DocStore()
        store.refresh(repositories: [repo])
        XCTAssertEqual(store.entries.map(\.title), ["New", "Old", "Undated"])
    }

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url.path
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DocStoreScanTests`
Expected: FAIL to compile with `value of type 'DocStore' has no member 'refresh'`

- [ ] **Step 3: Add `refresh` to DocStore**

In `Sources/Dreamux/Models/DocStore.swift`, insert between `private(set) var entries: [DocEntry] = []` and `// MARK: - Parsing`:

```swift
    /// Rescan the given repos. One entry per (repo, relative path):
    /// identical copies prefer the default branch (so merged docs don't
    /// wear a stale feature badge), diverged copies prefer the most
    /// recently modified.
    func refresh(repositories: [Repository]) {
        struct Candidate {
            let entry: DocEntry
            let content: String
            let modifiedAt: Date
        }
        var best: [String: Candidate] = [:]
        let fm = FileManager.default

        for repo in repositories {
            for worktreeURL in repo.worktrees {
                let branch = worktreeURL.lastPathComponent
                for (kind, folder) in Self.folders {
                    let dir = worktreeURL.appendingPathComponent(folder, isDirectory: true)
                    let files = (try? fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    for fileURL in files where fileURL.pathExtension == "md" {
                        // Unreadable files are simply skipped — same
                        // posture as the repo scan elsewhere.
                        guard let content = try? String(contentsOf: fileURL, encoding: .utf8)
                        else { continue }
                        let fileName = fileURL.lastPathComponent
                        let entry = DocEntry(
                            kind: kind,
                            repoName: repo.name,
                            branch: branch,
                            isDefaultBranch: branch == repo.defaultBranch,
                            relativePath: "\(folder)/\(fileName)",
                            fileURL: fileURL,
                            title: Self.parseTitle(
                                markdown: content,
                                fallback: fileURL.deletingPathExtension().lastPathComponent
                            ),
                            dateString: Self.parseDatePrefix(fileName: fileName),
                            progress: kind == .plan ? Self.parseProgress(markdown: content) : nil
                        )
                        let modifiedAt = (try? fileURL.resourceValues(
                            forKeys: [.contentModificationDateKey]
                        ).contentModificationDate) ?? .distantPast
                        let candidate = Candidate(
                            entry: entry, content: content, modifiedAt: modifiedAt
                        )

                        guard let existing = best[entry.id] else {
                            best[entry.id] = candidate
                            continue
                        }
                        let replace: Bool
                        if existing.content == content {
                            replace = entry.isDefaultBranch && !existing.entry.isDefaultBranch
                        } else {
                            replace = modifiedAt > existing.modifiedAt
                        }
                        if replace { best[entry.id] = candidate }
                    }
                }
            }
        }

        entries = best.values.map(\.entry).sorted { a, b in
            switch (a.dateString, b.dateString) {
            case let (l?, r?) where l != r:
                return l > r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                if a.fileName != b.fileName { return a.fileName < b.fileName }
                return a.repoName < b.repoName
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DocStoreScanTests`
Expected: PASS, 6 tests

Run: `swift test --filter DocStoreParsingTests`
Expected: still PASS, 8 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/DocStore.swift Tests/DreamuxTests/DocStoreScanTests.swift
git commit -m "Scan worktrees for superpowers docs with cross-worktree dedupe" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: MarkdownUI dependency

**Files:**
- Modify: `Package.swift:10-27`

- [ ] **Step 1: Add the package and product**

In `Package.swift`, change the `dependencies` array to:

```swift
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.0.1777879537"),
        // Vendored at vendor/bonsplit so we can patch dropZoneAtEnd to
        // absorb the trailing run-off (see TabBarView.swift).
        .package(path: "vendor/bonsplit"),
        // Renders the superpowers spec/plan markdown in DocsBrowserView —
        // GFM task lists, tables, and code blocks, native SwiftUI.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
```

and the executable target's `dependencies` to:

```swift
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "DreamuxPTY",
            ],
```

- [ ] **Step 2: Resolve and build**

Run: `swift build`
Expected: `Fetching https://github.com/gonzalezreal/swift-markdown-ui.git` followed by `Build complete!` (network required for the first resolve)

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Add swift-markdown-ui for in-app markdown rendering" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: DocsBrowserView

**Files:**
- Create: `Sources/Dreamux/Views/DocsBrowserView.swift`

No unit test — it's pure SwiftUI layout; behavior is covered by the DocStore tests (Tasks 1–2) and the e2e scenario (Task 7) including a screenshot.

- [ ] **Step 1: Create the view**

Create `Sources/Dreamux/Views/DocsBrowserView.swift`:

```swift
import AppKit
import MarkdownUI
import SwiftUI

/// Read-only browser for the superpowers documents found across the
/// project's repos: design specs (docs/superpowers/specs) and
/// implementation plans (docs/superpowers/plans). Master list on the
/// left, rendered markdown on the right; editing stays in the user's
/// editor.
struct DocsBrowserView: View {
    @Bindable var docs: DocStore
    @Bindable var repoStore: RepoStore

    @State private var selectedID: DocEntry.ID?
    @State private var selectedContent: String?

    private var selectedEntry: DocEntry? {
        docs.entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                docList
                    .frame(width: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { refresh() }
        .onChange(of: selectedID) { _, _ in loadSelection() }
    }

    private func refresh() {
        repoStore.refresh()
        docs.refresh(repositories: repoStore.repositories)
        if selectedEntry == nil { selectedID = docs.entries.first?.id }
        loadSelection()
    }

    /// Snapshot the file at selection time. A nil read with a non-nil
    /// selection is the "file disappeared since the scan" state.
    private func loadSelection() {
        guard let entry = selectedEntry else {
            selectedContent = nil
            return
        }
        selectedContent = try? String(contentsOf: entry.fileURL, encoding: .utf8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Specs & Plans")
                .font(.headline)
            Spacer()
            if let entry = selectedEntry {
                Button {
                    NSWorkspace.shared.open(entry.fileURL)
                } label: {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .help("Open \(entry.fileName) in the default editor")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Show \(entry.fileName) in Finder")
            }
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan the project's repos")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var docList: some View {
        List(selection: $selectedID) {
            section(for: .spec, header: "Specs")
            section(for: .plan, header: "Plans")
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func section(for kind: DocKind, header: String) -> some View {
        let entries = docs.entries.filter { $0.kind == kind }
        if !entries.isEmpty {
            Section(header) {
                ForEach(entries) { entry in
                    DocRow(entry: entry)
                        .tag(entry.id)
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            if let content = selectedContent {
                ScrollView {
                    Markdown(content)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .id(entry.id) // reset scroll position per document
            } else {
                ContentUnavailableView(
                    "File no longer exists",
                    systemImage: "questionmark.folder",
                    description: Text(
                        "\(entry.fileName) was removed since the last scan. Refresh to update the list."
                    )
                )
            }
        } else if docs.entries.isEmpty {
            ContentUnavailableView {
                Label("No specs or plans yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(
                    "Superpowers saves design specs to docs/superpowers/specs and implementation plans to docs/superpowers/plans inside each repo. Documents there appear here automatically."
                )
            }
        } else {
            ContentUnavailableView("Select a document", systemImage: "doc.text")
        }
    }
}

/// One list row: title plus a metadata line (date, repo chip,
/// off-default branch badge, plan checkbox progress).
private struct DocRow: View {
    let entry: DocEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                if let dateString = entry.dateString {
                    Text(dateString)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                chip(entry.repoName, tint: .secondary)
                if !entry.isDefaultBranch {
                    chip(entry.branch, tint: .orange)
                }
                if let progress = entry.progress {
                    Text("\(progress.checked)/\(progress.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            progress.checked == progress.total
                                ? Color.green : Color.secondary
                        )
                        .help("\(progress.checked) of \(progress.total) steps checked off")
                }
            }
        }
        .padding(.vertical, 2)
        .help(entry.fileURL.path)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (the view compiles; nothing references it yet)

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/DocsBrowserView.swift
git commit -m "Add DocsBrowserView master-detail markdown browser" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Wire the docs pane (SidebarMode, tile, registry)

`SidebarMode` is switched exhaustively in three places (`WorkspaceSidebar.isWorkspaceActive`, `FeaturesDetail.mainPane`, `E2ECommands.sidebarModeName`), so the new case and all switch updates must land in one task or the build breaks.

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift:49-57` (SidebarMode), `:65-98` (FeaturesDetail init), `:117-126` (registry call), `:153-170` (mainPane)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift:18-27` (body), `:116-127` (tiles), `:176-183` (isWorkspaceActive)
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift:39-52` (handles), `:92-103` (registerRunStores)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift:195-201` (sidebarModeName), `:302-330` (setSidebarMode)

- [ ] **Step 1: Add the SidebarMode case**

In `Sources/Dreamux/Views/ContentView.swift`, replace the `SidebarMode` enum and its doc comment:

```swift
/// Sidebar-pane swap inside the Features section. `.workspace` shows the
/// terminal pane for the active feature; `.run` shows the Run page scoped
/// to a specific workspace (its play button was clicked); `.signals`
/// shows the project-wide log stream; `.docs` shows the Specs & Plans
/// browser.
enum SidebarMode: Hashable {
    case workspace
    case run(workspaceID: UUID)
    case signals
    case docs
}
```

- [ ] **Step 2: Create the DocStore in FeaturesDetail**

In `FeaturesDetail` (same file), add below `@State private var runners: RunnerManager`:

```swift
    @State private var docs: DocStore
```

and in `init(store:repoStore:)`, add directly after the `_runners = State(initialValue: runners)` line:

```swift
        _docs = State(initialValue: DocStore())
```

- [ ] **Step 3: Add the mainPane case**

In `FeaturesDetail.mainPane`, add after the `.signals` case:

```swift
        case .docs:
            DocsBrowserView(docs: docs, repoStore: repoStore)
```

- [ ] **Step 4: Register the store with the e2e registry**

In `Sources/Dreamux/E2E/E2ERegistry.swift`, add to `E2EProjectHandles` below `weak var signals: SignalStore?`:

```swift
    weak var docs: DocStore?
```

and change `registerRunStores` to:

```swift
    func registerRunStores(
        projectID: UUID,
        runners: RunnerManager,
        runConfig: RunConfigStore,
        signals: SignalStore,
        docs: DocStore
    ) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.runners = runners
        handles.runConfig = runConfig
        handles.signals = signals
        handles.docs = docs
    }
```

Then in `ContentView.swift`'s `FeaturesDetail.body.onAppear`, update the call:

```swift
            E2ERegistry.shared.registerRunStores(
                projectID: repoStore.project.id,
                runners: runners,
                runConfig: runConfig,
                signals: signals,
                docs: docs
            )
```

- [ ] **Step 5: Update the two switches in E2ECommands**

In `Sources/Dreamux/E2E/E2ECommands.swift`, `sidebarModeName`:

```swift
    private static func sidebarModeName(_ mode: SidebarMode) -> String {
        switch mode {
        case .workspace: return "workspace"
        case .run: return "run"
        case .signals: return "signals"
        case .docs: return "docs"
        }
    }
```

and in `setSidebarMode`, add before the `default:` case:

```swift
        case "docs":
            handles.bridge.pendingSidebarMode = .docs
```

and update the `default:` error message to:

```swift
            throw CommandError(message: "mode must be \"workspace\", \"run\", \"signals\", or \"docs\"")
```

- [ ] **Step 6: Add the sidebar tile**

In `Sources/Dreamux/Views/WorkspaceSidebar.swift`, in `body`'s `VStack`, add `docsTile` directly under `signalsTile`:

```swift
                signalsTile
                docsTile
                featuresSection
```

Add below the `signalsTile` property (inside the `// MARK: - Signals tile` section, which becomes the shared tile section):

```swift
    private var docsTile: some View {
        modeTile(
            isSelected: sidebarMode == .docs,
            title: "Specs & Plans",
            symbol: "doc.text.fill",
            tint: .teal,
            hint: "Browse superpowers design specs and implementation plans",
            onTap: { sidebarMode = .docs }
        )
    }
```

In `isWorkspaceActive`, replace the `.signals` case so the switch stays exhaustive:

```swift
        case .signals, .docs: return false
```

- [ ] **Step 7: Build and run the full unit suite**

Run: `swift build`
Expected: `Build complete!`

Run: `swift test`
Expected: PASS — all existing tests plus the 14 DocStore tests

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift \
        Sources/Dreamux/Views/WorkspaceSidebar.swift \
        Sources/Dreamux/E2E/E2ERegistry.swift \
        Sources/Dreamux/E2E/E2ECommands.swift
git commit -m "Wire the Specs & Plans pane behind a new SidebarMode.docs" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `listDocs` e2e command and protocol doc

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift:50-91` (dispatch) and the `// MARK: - Repos & features` area
- Modify: `Scripts/e2e/PROTOCOL.md:206-217` (setSidebarMode section) plus a new section after it

- [ ] **Step 1: Add the command**

In `E2ECommands.swift`, add to the dispatch switch in `run(cmd:request:)`, after the `"setSidebarMode"` case:

```swift
        case "listDocs":
            return try listDocs()
```

Add this method after `setSidebarMode` (it follows the same `projectStores()` access pattern):

```swift
    // MARK: - Docs

    /// Rescan and return the superpowers spec/plan documents the Docs
    /// pane would show — same store, same refresh path as the UI.
    private static func listDocs() throws -> [String: Any] {
        let (handles, _, repoStore) = try projectStores()
        guard let docs = handles.docs else {
            throw CommandError(message: "doc store not registered (is a project window open?)")
        }
        repoStore.refresh()
        docs.refresh(repositories: repoStore.repositories)
        return [
            "ok": true,
            "docs": docs.entries.map { entry -> [String: Any] in
                var dict: [String: Any] = [
                    "kind": entry.kind.rawValue,
                    "repo": entry.repoName,
                    "branch": entry.branch,
                    "isDefaultBranch": entry.isDefaultBranch,
                    "title": entry.title,
                    "relativePath": entry.relativePath,
                    "path": entry.fileURL.path,
                ]
                if let dateString = entry.dateString { dict["date"] = dateString }
                if let progress = entry.progress {
                    dict["progress"] = ["checked": progress.checked, "total": progress.total]
                }
                return dict
            },
        ]
    }
```

- [ ] **Step 2: Update PROTOCOL.md**

In `Scripts/e2e/PROTOCOL.md`, in the `### setSidebarMode` section, change the sentence

> Switch the project window's main pane. `mode` is `"workspace"`,
> `"run"`, or `"signals"`.

to

> Switch the project window's main pane. `mode` is `"workspace"`,
> `"run"`, `"signals"`, or `"docs"`.

Then add a new section directly after the `setSidebarMode` section:

````markdown
### `listDocs`

Rescan the project's repos for superpowers documents
(`docs/superpowers/specs/*.md` and `docs/superpowers/plans/*.md` in
every worktree) and return what the Specs & Plans pane shows. One
entry per (repo, file): identical copies across worktrees report the
default branch; diverged copies report the most recently modified
worktree's branch. `date` (the validated `YYYY-MM-DD` filename
prefix) and `progress` (the plan's checkbox tally) are omitted when
absent.

```
→ {"cmd":"listDocs"}
← {"ok":true,"docs":[{"kind":"plan","repo":"portenv-server",
   "branch":"main","isDefaultBranch":true,"title":"Widget Plan",
   "relativePath":"docs/superpowers/plans/2026-06-12-widget.md",
   "path":"/…/repos/portenv-server/main/docs/superpowers/plans/2026-06-12-widget.md",
   "date":"2026-06-12","progress":{"checked":1,"total":2}}]}
```
````

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/E2E/E2ECommands.swift Scripts/e2e/PROTOCOL.md
git commit -m "Add listDocs automation command" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: e2e scenario

**Files:**
- Modify: `Scripts/e2e/driver.py` — a `write_file` helper next to the existing path helpers (`worktree`/`feature_dir`), a `scenario_docs_browser` function after `scenario_publish_pr`, and a `SCENARIOS` entry between `publish-pr` and `quit`

The scenario runs late in the suite on purpose: it creates its own feature (`feat-docs`) and leaves an uncommitted file in that worktree, which must not perturb the carefully sequenced merge/conflict scenarios earlier in the list. By this point the app has relaunched at the end of `scenario_publish_pr` and `portenv-server`'s git identity was baked into its shared `.bare` config in `scenario_repos_and_feature`, so plain commits work.

- [ ] **Step 1: Add the helper**

In `Scripts/e2e/driver.py`, next to the existing module-level path helpers (`worktree`/`feature_dir`):

```python
def write_file(path, contents):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(contents)
```

- [ ] **Step 2: Add the scenario**

After `scenario_publish_pr` (before `scenario_quit`):

```python
def scenario_docs_browser(d):
    """Superpowers docs discovery: commit a spec + plan on main, diverge
    the plan in a feature worktree, and verify listDocs dedupe plus the
    docs pane."""
    main_wt = worktree("portenv-server", "main")
    spec_rel = "docs/superpowers/specs/2026-06-12-widget-design.md"
    plan_rel = "docs/superpowers/plans/2026-06-12-widget.md"
    write_file(os.path.join(main_wt, spec_rel), "# Widget Design\n\nBody.\n")
    write_file(os.path.join(main_wt, plan_rel),
               "# Widget Plan\n\n- [ ] **Step 1**\n- [ ] **Step 2**\n")
    git("add", "docs", cwd=main_wt)
    git("commit", "-m", "Add widget docs", cwd=main_wt)

    # feat-docs checks out main's tip, so both docs start as identical
    # copies — dedupe must keep reporting branch=main.
    d.cmd("createFeature", name="feat-docs", repos=["portenv-server"])
    resp = d.cmd("listDocs")
    docs = {e["relativePath"]: e for e in resp["docs"]}
    require(set(docs) == {spec_rel, plan_rel},
            f"unexpected docs: {sorted(docs)}")
    require(docs[spec_rel]["kind"] == "spec", "spec kind wrong")
    require(docs[spec_rel]["title"] == "Widget Design",
            f"spec title wrong: {docs[spec_rel]['title']}")
    require(docs[spec_rel]["date"] == "2026-06-12", "spec date wrong")
    require(docs[spec_rel]["branch"] == "main",
            f"identical copies must prefer main: {docs[spec_rel]['branch']}")
    require(docs[plan_rel]["progress"] == {"checked": 0, "total": 2},
            f"plan progress wrong: {docs[plan_rel].get('progress')}")

    # Diverge the plan on the feature branch (tick a step) — the newer
    # copy must win and carry the feature branch.
    feat_wt = worktree("portenv-server", "feat-docs")
    write_file(os.path.join(feat_wt, plan_rel),
               "# Widget Plan\n\n- [x] **Step 1**\n- [ ] **Step 2**\n")
    resp = d.cmd("listDocs")
    docs = {e["relativePath"]: e for e in resp["docs"]}
    require(docs[plan_rel]["branch"] == "feat-docs",
            f"diverged copy must come from feat-docs: {docs[plan_rel]['branch']}")
    require(docs[plan_rel]["isDefaultBranch"] is False, "isDefaultBranch wrong")
    require(docs[plan_rel]["progress"] == {"checked": 1, "total": 2},
            f"ticked progress wrong: {docs[plan_rel].get('progress')}")
    require(docs[spec_rel]["branch"] == "main",
            "untouched spec must stay on main")

    d.cmd("setSidebarMode", mode="docs")
    state = d.state()
    require(state["sidebarMode"] == "docs",
            f"sidebarMode is {state['sidebarMode']!r}, expected docs")
    d.screenshot("docs-browser")
    d.cmd("setSidebarMode", mode="workspace")
```

- [ ] **Step 3: Register the scenario**

In the `SCENARIOS` list, insert between `publish-pr` and `quit`:

```python
    ("docs-browser", scenario_docs_browser),
```

- [ ] **Step 4: Run the full e2e suite**

Run: `Scripts/e2e/run-e2e.sh`
Expected: every scenario `PASS`, including `docs-browser`; a `docs-browser.png` screenshot lands in the artifacts directory. Inspect the screenshot — the list should show "Widget Design" and "Widget Plan" (the plan row with a `feat-docs` badge and `1/2` progress), the detail pane rendering markdown.

- [ ] **Step 5: Run the unit suite one last time**

Run: `swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Scripts/e2e/driver.py
git commit -m "Add docs-browser e2e scenario" \
           -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
