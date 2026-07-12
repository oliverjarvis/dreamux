# Keyboard Shortcuts + ⌘K Command Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘N opens the New Project sheet, ⌘P opens the New Plan sheet, and ⌘K opens an in-window command palette (also reachable from a search bar in the projects rail) that fuzzy-searches projects, workspaces & plans, commands, and file names.

**Architecture:** Shortcuts ride the app's existing `Commands` + `@FocusedBinding` pattern (see `FileExplorerCommands` in `Sources/Dreamux/DreamuxApp.swift:179` — menu key equivalents survive terminal first-responder focus; view-level shortcuts don't). The palette is a `ContentView`-level overlay fed by a new `PaletteModel` (`@MainActor @Observable`) that composes candidates from four closure-based sources and filters them through a new dependency-free `FuzzyMatcher`. E2E coverage adds a `setPalette`/`paletteState` command pair mirroring the `setSidebarMode` park-on-bridge/consume-in-view idiom.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14 floor), SwiftPM, XCTest for unit tests, the existing Python e2e driver (`Scripts/e2e/driver.py`) for the end-to-end scenario.

**Spec:** `docs/superpowers/specs/2026-07-11-shortcuts-command-palette-design.md`

## Global Constraints

- Platform floor is **macOS 14** (`Package.swift`: `platforms: [.macOS(.v14)]`) — `onKeyPress`, `@Observable`, `@Bindable` are all available.
- **No new package dependencies.**
- Unit tests are **XCTest** in `Tests/DreamuxTests` (`@MainActor final class XTests: XCTestCase`). The executable target must never link XCTest.
- UI follows CLAUDE.md: 15pt row labels, 13pt-semibold kern-0.4 uppercase section headers, fixed-width leading glyph frames, hover wash `Color.primary.opacity(0.04)` / selected `0.08` on `RoundedRectangle(cornerRadius: 8)`, outlined-pill controls (`strokeBorder .secondary.opacity(0.3)`, fill `.primary.opacity(0.04)`).
- Menu-driven shortcuts MUST use the `Commands` + focused-value pattern, never `.keyboardShortcut` on toolbar/content buttons (terminal first-responder swallows those).
- Commit style: short `Prefix: summary` subject (match `git log`), staging **only named files** (parallel sessions may be touching the repo).
- The working tree contains a git worktree copy under `.claude/worktrees/` — never edit files there; all paths below are the primary tree.
- Build: `swift build`. Unit tests: `swift test --filter <TestClass>`. Full e2e: `Scripts/e2e/run-e2e.sh` (builds the app bundle, then runs `driver.py`).

---

### Task 1: FuzzyMatcher

**Files:**
- Create: `Sources/Dreamux/Models/FuzzyMatcher.swift`
- Test: `Tests/DreamuxTests/FuzzyMatcherTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `struct FuzzyMatch: Equatable { let score: Int; let matchedOffsets: [Int] }`
  - `enum FuzzyMatcher { static func match(_ query: String, in target: String) -> FuzzyMatch? }`
  - Semantics: `nil` when `query` is not a case-insensitive subsequence of `target`; empty query → `FuzzyMatch(score: 0, matchedOffsets: [])`; `matchedOffsets` are character offsets into `target` for highlight rendering. Higher score = better.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/FuzzyMatcherTests.swift
import XCTest
@testable import Dreamux

final class FuzzyMatcherTests: XCTestCase {
    func testNonSubsequenceReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "main"))
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatcher.match("wsp", in: "workspace"))
    }

    func testQueryLongerThanTargetReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("planning", in: "plan"))
    }

    func testEmptyQueryMatchesWithZeroScore() {
        XCTAssertEqual(FuzzyMatcher.match("", in: "anything"),
                       FuzzyMatch(score: 0, matchedOffsets: []))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.match("READ", in: "readme.md"))
    }

    func testMatchedOffsets() {
        XCTAssertEqual(FuzzyMatcher.match("rm", in: "readme")?.matchedOffsets, [0, 4])
    }

    func testPrefixBeatsMidWord() {
        let prefix = FuzzyMatcher.match("pla", in: "plans.md")!
        let midWord = FuzzyMatcher.match("pla", in: "templates.md")!
        XCTAssertGreaterThan(prefix.score, midWord.score)
    }

    func testBoundaryBeatsScattered() {
        let boundary = FuzzyMatcher.match("np", in: "new plan")!
        let scattered = FuzzyMatcher.match("np", in: "snapshot")!
        XCTAssertGreaterThan(boundary.score, scattered.score)
    }

    func testShorterTargetWinsTie() {
        let short = FuzzyMatcher.match("plan", in: "plan.md")!
        let long = FuzzyMatcher.match("plan", in: "plan-archive-2024.md")!
        XCTAssertGreaterThan(short.score, long.score)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FuzzyMatcherTests 2>&1 | tail -20`
Expected: compile error — `FuzzyMatcher`/`FuzzyMatch` not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/FuzzyMatcher.swift
import Foundation

/// Result of a fuzzy match: a rank score plus the character offsets in
/// the target that matched, so views can bold the hit characters.
struct FuzzyMatch: Equatable {
    /// Higher is better. Comparable only between matches of the SAME query.
    let score: Int
    /// Character offsets into the target string, ascending.
    let matchedOffsets: [Int]
}

/// Case-insensitive greedy subsequence matcher shared by every palette
/// provider. Scoring favors prefix matches, matches at word/segment
/// boundaries (space, -, _, /, ., camelCase humps), and consecutive
/// runs; shorter targets win ties.
enum FuzzyMatcher {
    static func match(_ query: String, in target: String) -> FuzzyMatch? {
        if query.isEmpty { return FuzzyMatch(score: 0, matchedOffsets: []) }
        let queryChars = Array(query.lowercased())
        let targetChars = Array(target)
        let lowerTarget = Array(target.lowercased())
        guard queryChars.count <= targetChars.count else { return nil }

        var offsets: [Int] = []
        var score = 0
        var queryIndex = 0
        var previousMatch = -2
        for targetIndex in 0..<lowerTarget.count {
            guard queryIndex < queryChars.count else { break }
            guard lowerTarget[targetIndex] == queryChars[queryIndex] else { continue }
            var charScore = 1
            if targetIndex == previousMatch + 1 { charScore += 4 }
            if targetIndex == 0 {
                charScore += 8
            } else if isBoundary(targetChars[targetIndex - 1], targetChars[targetIndex]) {
                charScore += 6
            }
            score += charScore
            offsets.append(targetIndex)
            previousMatch = targetIndex
            queryIndex += 1
        }
        guard queryIndex == queryChars.count else { return nil }
        // Length penalty: on equal hits, the shorter target ranks higher.
        score -= targetChars.count / 4
        return FuzzyMatch(score: score, matchedOffsets: offsets)
    }

    private static func isBoundary(_ previous: Character, _ current: Character) -> Bool {
        if " -_/.".contains(previous) { return true }
        return previous.isLowercase && current.isUppercase
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FuzzyMatcherTests 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FuzzyMatcher.swift Tests/DreamuxTests/FuzzyMatcherTests.swift
git commit -m "Palette: fuzzy subsequence matcher with boundary/prefix scoring"
```

---

### Task 2: PaletteModel

**Files:**
- Create: `Sources/Dreamux/Models/PaletteModel.swift`
- Test: `Tests/DreamuxTests/PaletteModelTests.swift`

**Interfaces:**
- Consumes: `FuzzyMatcher.match(_:in:) -> FuzzyMatch?`, `FuzzyMatch` (Task 1).
- Produces (all used by Tasks 4 and 6):
  - `struct PaletteCandidate: Identifiable { let id: String; let title: String; let subtitle: String?; let icon: String; let perform: @MainActor () -> Void }`
  - `enum PaletteSectionKind: String, CaseIterable, Identifiable { case projects, workspaces, commands, files }` with `var title: String` ("Projects", "Workspaces & Plans", "Commands", "Files").
  - `struct PaletteSource { let kind: PaletteSectionKind; let cap: Int; let showsOnEmptyQuery: Bool; let candidates: @MainActor () -> [PaletteCandidate] }`
  - `struct PaletteRow: Identifiable { let candidate: PaletteCandidate; let match: FuzzyMatch; var id: String }`
  - `struct PaletteResultSection: Identifiable { let kind: PaletteSectionKind; let rows: [PaletteRow]; var id: String }`
  - `@MainActor @Observable final class PaletteModel`:
    - `init(sources: [PaletteSource])`
    - `var query: String` (setting it rebuilds results)
    - `private(set) var sections: [PaletteResultSection]`
    - `private(set) var selectedRowID: String?`
    - `func refresh()` — re-pulls every source's candidates, rebuilds
    - `var flatRows: [PaletteRow]`, `var selectedRow: PaletteRow?`
    - `func select(_ rowID: String)`, `func moveSelection(by delta: Int)` (clamped)
    - `@discardableResult func executeSelected() -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/PaletteModelTests.swift
import XCTest
@testable import Dreamux

@MainActor
final class PaletteModelTests: XCTestCase {
    private var performed: [String] = []

    override func setUp() {
        performed = []
    }

    private func candidate(_ id: String, _ title: String) -> PaletteCandidate {
        PaletteCandidate(id: id, title: title, subtitle: nil, icon: "doc") {
            self.performed.append(id)
        }
    }

    private func model(
        projects: [PaletteCandidate] = [],
        commands: [PaletteCandidate] = [],
        files: [PaletteCandidate] = []
    ) -> PaletteModel {
        PaletteModel(sources: [
            PaletteSource(kind: .projects, cap: 5, showsOnEmptyQuery: true) { projects },
            PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) { commands },
            PaletteSource(kind: .files, cap: 8, showsOnEmptyQuery: false) { files },
        ])
    }

    func testEmptyQueryShowsOnlyEmptyQuerySectionsInSourceOrder() {
        let m = model(
            projects: [candidate("p1", "clayspace")],
            commands: [candidate("c1", "New Plan…")],
            files: [candidate("f1", "readme.md")]
        )
        m.refresh()
        XCTAssertEqual(m.sections.map(\.kind), [.projects, .commands])
        XCTAssertEqual(m.selectedRowID, "p1")
    }

    func testEmptyQueryRespectsCap() {
        let many = (1...7).map { candidate("p\($0)", "project-\($0)") }
        let m = model(projects: many)
        m.refresh()
        XCTAssertEqual(m.sections[0].rows.count, 5)
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["p1", "p2", "p3", "p4", "p5"])
    }

    func testQueryFiltersAndSurfacesRequiresQuerySections() {
        let m = model(
            projects: [candidate("p1", "clayspace")],
            commands: [candidate("c1", "New Plan…")],
            files: [candidate("f1", "readme.md"), candidate("f2", "main.swift")]
        )
        m.refresh()
        m.query = "read"
        XCTAssertEqual(m.sections.map(\.kind), [.files])
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["f1"])
    }

    func testQueryRanksByScoreWithinSection() {
        let m = model(projects: [
            candidate("scatter", "superplan-archive"),
            candidate("prefix", "plan.md"),
        ])
        m.refresh()
        m.query = "plan"
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["prefix", "scatter"])
    }

    func testQueryRespectsCapAfterRanking() {
        let many = (1...7).map { candidate("p\($0)", "plan-\($0)") }
        let m = model(projects: many)
        m.refresh()
        m.query = "plan"
        XCTAssertEqual(m.sections[0].rows.count, 5)
    }

    func testMoveSelectionClampsAndWalksAcrossSections() {
        let m = model(
            projects: [candidate("p1", "alpha"), candidate("p2", "beta")],
            commands: [candidate("c1", "gamma")]
        )
        m.refresh()
        XCTAssertEqual(m.selectedRowID, "p1")
        m.moveSelection(by: -1)
        XCTAssertEqual(m.selectedRowID, "p1")
        m.moveSelection(by: 1)
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "c1")
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "c1")
    }

    func testSelectionResetsToFirstWhenRowDisappears() {
        let m = model(projects: [candidate("p1", "alpha"), candidate("p2", "beta")])
        m.refresh()
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "p2")
        m.query = "alp"
        XCTAssertEqual(m.selectedRowID, "p1")
    }

    func testExecuteSelectedRunsCandidate() {
        let m = model(projects: [candidate("p1", "alpha")])
        m.refresh()
        XCTAssertTrue(m.executeSelected())
        XCTAssertEqual(performed, ["p1"])
    }

    func testExecuteSelectedReturnsFalseWithNoRows() {
        let m = model(projects: [candidate("p1", "alpha")])
        m.refresh()
        m.query = "zzzz"
        XCTAssertFalse(m.executeSelected())
        XCTAssertTrue(performed.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PaletteModelTests 2>&1 | tail -20`
Expected: compile error — `PaletteModel`/`PaletteCandidate`/`PaletteSource` not found.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/PaletteModel.swift
import Foundation
import Observation

/// One selectable palette row's identity + action. `perform` runs on the
/// main actor when the row is executed (Return or click); the view is
/// responsible for dismissing afterwards.
struct PaletteCandidate: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    /// SF Symbol name for the row's leading glyph.
    let icon: String
    let perform: @MainActor () -> Void
}

/// The palette's result groups, in display order.
enum PaletteSectionKind: String, CaseIterable, Identifiable {
    case projects, workspaces, commands, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .workspaces: "Workspaces & Plans"
        case .commands: "Commands"
        case .files: "Files"
        }
    }
}

/// A section's candidate feed. `candidates` is pulled fresh on every
/// `refresh()` (each palette open) so results reflect the live stores.
/// Sections with `showsOnEmptyQuery == false` (files, workspaces)
/// contribute rows only once the user types.
struct PaletteSource {
    let kind: PaletteSectionKind
    let cap: Int
    let showsOnEmptyQuery: Bool
    let candidates: @MainActor () -> [PaletteCandidate]
}

struct PaletteRow: Identifiable {
    let candidate: PaletteCandidate
    let match: FuzzyMatch
    var id: String { candidate.id }
}

struct PaletteResultSection: Identifiable {
    let kind: PaletteSectionKind
    let rows: [PaletteRow]
    var id: String { kind.id }
}

/// Query + selection + result composition for the ⌘K palette. Pure data —
/// no view dependencies — so it's unit-testable with fake sources.
@MainActor
@Observable
final class PaletteModel {
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
        }
    }
    private(set) var sections: [PaletteResultSection] = []
    private(set) var selectedRowID: String?

    private let sources: [PaletteSource]
    private var snapshot: [PaletteSectionKind: [PaletteCandidate]] = [:]

    init(sources: [PaletteSource]) {
        self.sources = sources
    }

    /// Re-pull every source's candidates — called once per palette open.
    func refresh() {
        snapshot = [:]
        for source in sources {
            snapshot[source.kind] = source.candidates()
        }
        rebuild()
    }

    var flatRows: [PaletteRow] { sections.flatMap(\.rows) }

    var selectedRow: PaletteRow? {
        flatRows.first { $0.id == selectedRowID }
    }

    func select(_ rowID: String) {
        selectedRowID = rowID
    }

    /// Clamped linear movement across all sections' rows.
    func moveSelection(by delta: Int) {
        let flat = flatRows
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.id == selectedRowID } ?? 0
        let next = min(max(current + delta, 0), flat.count - 1)
        selectedRowID = flat[next].id
    }

    /// Runs the selected row's action. Returns false when nothing is
    /// selectable (caller keeps the palette open).
    @discardableResult
    func executeSelected() -> Bool {
        guard let row = selectedRow else { return false }
        row.candidate.perform()
        return true
    }

    private func rebuild() {
        sections = sources.compactMap { source in
            let candidates = snapshot[source.kind] ?? []
            let rows: [PaletteRow]
            if query.isEmpty {
                guard source.showsOnEmptyQuery else { return nil }
                rows = candidates.prefix(source.cap).map {
                    PaletteRow(candidate: $0, match: FuzzyMatch(score: 0, matchedOffsets: []))
                }
            } else {
                // Sort by (score desc, original index) — Swift's sort is
                // not guaranteed stable, so carry the index explicitly.
                rows = candidates.enumerated()
                    .compactMap { index, candidate -> (Int, PaletteRow)? in
                        guard let match = FuzzyMatcher.match(query, in: candidate.title) else {
                            return nil
                        }
                        return (index, PaletteRow(candidate: candidate, match: match))
                    }
                    .sorted { a, b in
                        if a.1.match.score != b.1.match.score {
                            return a.1.match.score > b.1.match.score
                        }
                        return a.0 < b.0
                    }
                    .prefix(source.cap)
                    .map(\.1)
            }
            return rows.isEmpty ? nil : PaletteResultSection(kind: source.kind, rows: rows)
        }
        let flat = flatRows
        if !flat.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = flat.first?.id
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PaletteModelTests 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PaletteModel.swift Tests/DreamuxTests/PaletteModelTests.swift
git commit -m "Palette: PaletteModel result composition, selection, execution"
```

---

### Task 3: ⌘N New Project / ⌘P New Plan menu shortcuts

**Files:**
- Modify: `Sources/Dreamux/DreamuxApp.swift` (ProjectCommands ~line 246, `.commands` block ~line 75)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (collapsedRailStub sheet ~line 517, focused-value publish ~line 296, focused keys ~line 1240)
- Modify: `Sources/Dreamux/Views/WelcomeView.swift`

**Interfaces:**
- Consumes: existing `@State showCreateProject` / `showNewPlan` in ContentView; `CreateProjectSheet(store:onCreated:)`; `NewPlanSheet`.
- Produces: `FocusedValues.createProjectPresented: Binding<Bool>?` and `FocusedValues.newPlanPresented: Binding<Bool>?` — Task 4 follows this exact key pattern for the palette.

- [ ] **Step 1: Add the focused-value keys**

In `Sources/Dreamux/Views/ContentView.swift`, directly below the existing `FileTreeVisibleKey` block (after the `extension FocusedValues { var fileTreeVisible ... }` at the end of the file):

```swift
// MARK: - Menu-shortcut focused values

/// Bindings the File-menu items (⌘N New Project…, ⌘P New Plan…) use to
/// present the focused window's sheets — same bridge as
/// `fileTreeVisible`, so the shortcuts fire even while a terminal is
/// first responder.
private struct CreateProjectPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct NewPlanPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var createProjectPresented: Binding<Bool>? {
        get { self[CreateProjectPresentedKey.self] }
        set { self[CreateProjectPresentedKey.self] = newValue }
    }

    var newPlanPresented: Binding<Bool>? {
        get { self[NewPlanPresentedKey.self] }
        set { self[NewPlanPresentedKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Publish the bindings from ContentView**

In `ContentView.body`, directly after `.focusedSceneValue(\.fileTreeVisible, $showFileTree)` (~line 296):

```swift
.focusedSceneValue(\.createProjectPresented, $showCreateProject)
.focusedSceneValue(\.newPlanPresented, $showNewPlan)
```

- [ ] **Step 3: Move the New Project sheet to the window level**

The `showCreateProject` sheet currently hangs off `collapsedRailStub` (~line 517), which is only in the hierarchy while the rail is collapsed — ⌘N would silently no-op with the rail expanded. Delete this block from `collapsedRailStub`:

```swift
.sheet(isPresented: $showCreateProject) {
    CreateProjectSheet(store: projects) { project in
        onSwitchProject(project.id)
    }
}
```

and add the identical block to the main body's modifier chain, directly after the `.sheet(item: $overviewRunningPlan) { ... }` block (~line 259–276).

- [ ] **Step 4: Add the menu items and remove Print**

(Deliberate refinement of the spec's wiring table: "New Plan…" sits next to "New Project…" in the `.newItem` group — creation verbs belong together at the top of the File menu — while `.printItem` is replaced with *empty* content purely to free ⌘P. The spec's intent, ⌘P → New Plan sheet with Print gone, is unchanged.)

In `Sources/Dreamux/DreamuxApp.swift`, add two focused bindings to `ProjectCommands` (below the existing `@FocusedValue(\.activeStore)` at line 247):

```swift
@FocusedBinding(\.createProjectPresented) private var createProjectPresented: Bool?
@FocusedBinding(\.newPlanPresented) private var newPlanPresented: Bool?
```

At the TOP of its `CommandGroup(replacing: .newItem)` (before the "New Tab" button):

```swift
Button("New Project…") {
    createProjectPresented = true
}
.keyboardShortcut("n", modifiers: [.command])
.disabled(createProjectPresented == nil)

Button("New Plan…") {
    newPlanPresented = true
}
.keyboardShortcut("p", modifiers: [.command])
.disabled(newPlanPresented == nil)

Divider()
```

Add a new Commands struct next to `FileExplorerCommands`:

```swift
/// Removes the default Print/Page Setup items — nothing in Dreamux
/// prints, and freeing ⌘P lets the File menu's "New Plan…" own it.
private struct PrintCommandRemoval: Commands {
    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
    }
}
```

and register it in `DreamuxApp`'s `.commands { }` block:

```swift
.commands {
    ProjectCommands()
    FileExplorerCommands()
    PrintCommandRemoval()
    IntegrationCommands()
    NotificationCommands()
}
```

- [ ] **Step 5: Route the Welcome screen's ⌘N through the same menu item**

The File-menu "New Project…" now claims ⌘N app-wide; WelcomeView's button-level `.keyboardShortcut("n", modifiers: [.command])` would double-register the equivalent. In `Sources/Dreamux/Views/WelcomeView.swift`: delete the `.keyboardShortcut("n", modifiers: [.command])` line from the "Create Project" button, and publish the focused value so the menu item enables on the Welcome screen — add after the existing `.onAppear { store.refresh() }`:

```swift
.focusedSceneValue(\.createProjectPresented, $showCreate)
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 7: Run the existing unit tests (regression)**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/DreamuxApp.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/WelcomeView.swift
git commit -m "Shortcuts: ⌘N New Project, ⌘P New Plan via focused-binding menu items"
```

---

### Task 4: CommandPaletteView + ⌘K wiring

**Files:**
- Create: `Sources/Dreamux/Views/CommandPaletteView.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift`
- Modify: `Sources/Dreamux/DreamuxApp.swift`

**Interfaces:**
- Consumes: `PaletteModel`/`PaletteSource`/`PaletteCandidate`/`PaletteRow` (Task 2); ContentView's existing `openFile(_:)`, `sidebarMode`, `store`, `docStore`, `fileTree`, `repoStore`, `projects`, `onSwitchProject`, `showCreateProject`, `showNewPlan`, `showFileTree`, `overviewRunningPlan`; `panelCard(radius:shadow:fill:)` (ContentView.swift:1213); `FileTreeStore.roots(for:repositories:)` / `.children(of:)`; `WorkspaceStore.activate(_:)` / `.session(for:)` / `.addWorkspace()`; `WorkspaceSession.focusOverview()` / `.createTab()`.
- Produces:
  - `struct CommandPaletteView: View { init(model: PaletteModel, onDismiss: @escaping () -> Void) }`
  - `FocusedValues.palettePresented: Binding<Bool>?`
  - ContentView: `@State showPalette: Bool`, `@State paletteModel: PaletteModel?`, `func paletteSources() -> [PaletteSource]` — Task 5 opens via `showPalette = true`; Task 6 parks the model on the e2e bridge.

- [ ] **Step 1: Create the palette view**

```swift
// Sources/Dreamux/Views/CommandPaletteView.swift
import SwiftUI

/// The ⌘K palette: a centered panel over a scrim, fuzzy-searching
/// projects, workspaces & plans, commands, and file names. Pure
/// presentation — all data and actions arrive through `PaletteModel`;
/// executing any row calls `onDismiss` after the action runs.
struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let onDismiss: () -> Void

    @FocusState private var queryFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .onTapGesture(perform: onDismiss)
                panel
                    .frame(width: 600)
                    .padding(.top, geo.size.height * 0.18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            queryFocused = true
            // The Ghostty terminal holds first responder aggressively; a
            // next-runloop retry wins the race on the first open.
            DispatchQueue.main.async { queryFocused = true }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search projects, plans, files…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                    .onKeyPress(.downArrow) {
                        model.moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.moveSelection(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        if model.executeSelected() { onDismiss() }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.sections.isEmpty {
                Text("No results")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        results
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: model.selectedRowID) { _, rowID in
                        if let rowID { proxy.scrollTo(rowID) }
                    }
                }
            }
        }
        .panelCard(radius: 12)
        .onExitCommand(perform: onDismiss)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.kind.title.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(10)
    }

    private func rowView(_ row: PaletteRow) -> some View {
        let selected = row.id == model.selectedRowID
        return Button {
            model.select(row.id)
            if model.executeSelected() { onDismiss() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.candidate.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(highlightedTitle(row))
                    .font(.system(size: 15))
                    .lineLimit(1)
                if let subtitle = row.candidate.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.select(row.id) }
        }
        .id(row.id)
    }

    /// Bold the characters the fuzzy match hit.
    private func highlightedTitle(_ row: PaletteRow) -> AttributedString {
        var attributed = AttributedString(row.candidate.title)
        let offsets = Set(row.match.matchedOffsets)
        for (offset, index) in attributed.characters.indices.enumerated()
        where offsets.contains(offset) {
            let next = attributed.characters.index(after: index)
            attributed[index..<next].font = .system(size: 15, weight: .bold)
        }
        return attributed
    }
}
```

- [ ] **Step 2: Add the palette focused-value key**

In `ContentView.swift`, in the focused-values section added by Task 3, add:

```swift
private struct PalettePresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
```

and inside the same `extension FocusedValues`:

```swift
var palettePresented: Binding<Bool>? {
    get { self[PalettePresentedKey.self] }
    set { self[PalettePresentedKey.self] = newValue }
}
```

- [ ] **Step 3: Wire state, overlay, and sources into ContentView**

Add two `@State` vars next to `showNewPlan` (~line 45):

```swift
/// ⌘K command palette visibility (also opened by the rail's search bar).
@State private var showPalette = false
/// Rebuilt fresh on every palette open so results reflect live stores.
@State private var paletteModel: PaletteModel?
```

Append to the root `HStack`'s modifier chain (after the last `.onChange` block, ~line 360):

```swift
.focusedSceneValue(\.palettePresented, $showPalette)
.onChange(of: showPalette) { _, visible in
    if visible {
        // The e2e path (Task 6) pre-builds a model with a query; only
        // build one here when this open came from ⌘K or the rail.
        if paletteModel == nil {
            let model = PaletteModel(sources: paletteSources())
            model.refresh()
            paletteModel = model
        }
    } else {
        paletteModel = nil
    }
}
.overlay {
    if showPalette, let paletteModel {
        CommandPaletteView(model: paletteModel, onDismiss: { showPalette = false })
    }
}
```

- [ ] **Step 4: Add the palette sources to ContentView**

Add these three methods to `ContentView` (near `openFile(_:atLine:)`, ~line 1072):

```swift
// MARK: - Command palette sources

private func paletteSources() -> [PaletteSource] {
    [
        PaletteSource(kind: .projects, cap: 5, showsOnEmptyQuery: true) {
            projects.projects.map { project in
                PaletteCandidate(
                    id: "project-\(project.id)",
                    title: project.name,
                    subtitle: project.id == currentProjectID ? "Current project" : "Switch project",
                    icon: "folder"
                ) {
                    if project.id != currentProjectID { onSwitchProject(project.id) }
                }
            }
        },
        PaletteSource(kind: .workspaces, cap: 5, showsOnEmptyQuery: false) {
            let workspaceItems = store.workspaces.map { workspace in
                PaletteCandidate(
                    id: "workspace-\(workspace.id)",
                    title: workspace.name,
                    subtitle: "Workspace",
                    icon: workspace.isMain ? "house" : "square.stack.3d.up"
                ) {
                    sidebarMode = .workspace
                    store.activate(workspace.id)
                    store.session(for: workspace).focusOverview()
                }
            }
            let docItems = docStore.docs.filter { $0.kind != .doc }.map { doc in
                PaletteCandidate(
                    id: "doc-\(doc.fileURL.path)",
                    title: doc.title,
                    subtitle: doc.kind == .plan ? "Plan" : "Spec",
                    icon: "doc.text"
                ) {
                    openFile(doc.fileURL)
                }
            }
            return workspaceItems + docItems
        },
        PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) {
            paletteCommandCandidates()
        },
        PaletteSource(kind: .files, cap: 8, showsOnEmptyQuery: false) {
            paletteFileCandidates()
        },
    ]
}

private func paletteCommandCandidates() -> [PaletteCandidate] {
    var commands: [PaletteCandidate] = [
        PaletteCandidate(id: "command-new-project", title: "New Project…",
                         subtitle: nil, icon: "plus") { showCreateProject = true },
        PaletteCandidate(id: "command-new-plan", title: "New Plan…",
                         subtitle: nil, icon: "list.bullet.clipboard") { showNewPlan = true },
        PaletteCandidate(id: "command-new-workspace", title: "New Scratch Workspace",
                         subtitle: nil, icon: "plus.square") { _ = store.addWorkspace() },
        PaletteCandidate(id: "command-new-tab", title: "New Tab",
                         subtitle: nil, icon: "plus.rectangle") { store.activeSession?.createTab() },
        PaletteCandidate(id: "command-toggle-file-explorer", title: "Toggle File Explorer",
                         subtitle: nil, icon: "sidebar.right") { showFileTree.toggle() },
        PaletteCandidate(id: "command-go-signals", title: "Go to Signals",
                         subtitle: nil, icon: "dot.radiowaves.left.and.right") { sidebarMode = .signals },
        PaletteCandidate(id: "command-go-flows", title: "Go to Flows",
                         subtitle: nil, icon: "point.3.connected.trianglepath.dotted") { sidebarMode = .flows },
        PaletteCandidate(id: "command-go-library", title: "Go to Library",
                         subtitle: nil, icon: "books.vertical") { sidebarMode = .library },
    ]
    commands += docStore.plans.map { plan in
        PaletteCandidate(
            id: "command-run-plan-\(plan.fileURL.path)",
            title: "Run Plan: \(plan.title)",
            subtitle: nil,
            icon: "play"
        ) {
            overviewRunningPlan = plan
        }
    }
    return commands
}

/// Filename candidates from the active workspace's worktree roots —
/// breadth-first so shallow files surface first, capped so a giant repo
/// can't stall the palette, heavy build dirs skipped outright.
private func paletteFileCandidates() -> [PaletteCandidate] {
    let skipped: Set<String> = ["node_modules", ".build", "dist", ".next", "vendor"]
    let roots = fileTree.roots(for: store.activeWorkspace,
                               repositories: repoStore.repositories)
    var queue: [(node: FileNode, rootPath: String)] = roots.map { ($0, $0.url.path) }
    var candidates: [PaletteCandidate] = []
    var directoriesWalked = 0
    while !queue.isEmpty, candidates.count < 2000, directoriesWalked < 400 {
        let (node, rootPath) = queue.removeFirst()
        if node.isDirectory {
            guard !skipped.contains(node.name) else { continue }
            directoriesWalked += 1
            queue.append(contentsOf: fileTree.children(of: node).map { ($0, rootPath) })
        } else {
            let relative = String(node.url.path.dropFirst(rootPath.count)
                .drop(while: { $0 == "/" }))
            candidates.append(PaletteCandidate(
                id: "file-\(node.url.path)",
                title: node.name,
                subtitle: relative,
                icon: "doc"
            ) {
                openFile(node.url)
            })
        }
    }
    return candidates
}
```

- [ ] **Step 5: Add the ⌘K menu command**

In `DreamuxApp.swift`, add next to `FileExplorerCommands`:

```swift
/// View-menu toggle for the ⌘K command palette. Same `.commands` +
/// `@FocusedBinding` bridge as `FileExplorerCommands` — the shortcut
/// must fire while a terminal is first responder. No palette over
/// modals: a presented sheet keeps ⌘K inert.
private struct PaletteCommands: Commands {
    @FocusedBinding(\.palettePresented) private var palettePresented: Bool?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                if NSApp.keyWindow?.attachedSheet != nil { return }
                palettePresented?.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(palettePresented == nil)
        }
    }
}
```

and register it in `.commands { }` after `FileExplorerCommands()`:

```swift
.commands {
    ProjectCommands()
    FileExplorerCommands()
    PaletteCommands()
    PrintCommandRemoval()
    IntegrationCommands()
    NotificationCommands()
}
```

- [ ] **Step 6: Build and run regression tests**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`
Run: `swift test 2>&1 | tail -5` — expected 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Views/CommandPaletteView.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/DreamuxApp.swift
git commit -m "Palette: ⌘K overlay with project/workspace/command/file sources"
```

---

### Task 5: Search bar in the projects rail

**Files:**
- Modify: `Sources/Dreamux/Views/ProjectsRail.swift` (props ~line 15, safeAreaInset ~line 86)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (ProjectsRail call ~line 118, collapsedRailStub ~line 466)

**Interfaces:**
- Consumes: ContentView's `showPalette` (Task 4).
- Produces: `ProjectsRail.onOpenPalette: () -> Void` (new required prop — update the sole call site in ContentView).

- [ ] **Step 1: Add the search bar to the expanded rail**

In `ProjectsRail`, add a prop after `onToggleRail` (line 20):

```swift
/// Opens the ⌘K command palette (the rail's search bar is a second
/// entry point to the same overlay).
let onOpenPalette: () -> Void
```

In the `.safeAreaInset(edge: .top)` `VStack`, insert between `Color.clear.frame(height: 30)` and the `HStack` with the "Projects" header:

```swift
Button(action: onOpenPalette) {
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .medium))
        Text("Search")
            .font(.system(size: 15))
        Spacer(minLength: 0)
        Text("⌘K")
            .font(.system(size: 12, weight: .medium))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.04))
    )
    .overlay(
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.3))
    )
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.help("Search and quick actions (⌘K)")
.padding(.horizontal, 10)
.padding(.bottom, 8)
```

- [ ] **Step 2: Pass the closure from ContentView**

At the `ProjectsRail(...)` call (~line 118), add after `onSelect: onSwitchProject,`:

```swift
onOpenPalette: { showPalette = true },
```

- [ ] **Step 3: Add the magnifier to the collapsed stub**

In `collapsedRailStub`'s `VStack`, directly after `railToggle`:

```swift
Button {
    showPalette = true
} label: {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 22)
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
.help("Search (⌘K)")
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/ProjectsRail.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Palette: rail search bar + collapsed-stub magnifier entry points"
```

---

### Task 6: E2E — setPalette/paletteState commands + scenario

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift` (E2EBridge, ~line 16)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (case list ~line 50, impl near `setSidebarMode` ~line 488)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (consume plumbing, ~lines 297–365 and ~1097)
- Modify: `Scripts/e2e/driver.py` (new scenario + SCENARIOS registry ~line 1647)
- Modify: `Scripts/e2e/PROTOCOL.md` (document both commands)

**Interfaces:**
- Consumes: `PaletteModel` (Task 2), ContentView's `showPalette`/`paletteModel`/`paletteSources()` (Task 4).
- Produces:
  - `struct E2EPaletteRequest: Equatable { let visible: Bool; let query: String }`
  - `E2EBridge.pendingPalette: E2EPaletteRequest?`, `E2EBridge.paletteModel: PaletteModel?` (weak)
  - Socket commands: `setPalette {visible?: Bool = true, query?: String = ""}` → `{ok: true}`; `paletteState {}` → `{visible: Bool, query: String, sections: [{kind: String, items: [String]}]}` (visible-only fields present when open).

- [ ] **Step 1: Add the bridge fields**

In `E2ERegistry.swift`, inside `E2EBridge` (after `pendingDetect`):

```swift
/// Palette open/close request parked by the `setPalette` command and
/// consumed by `ContentView` — the consume-and-clear idiom above.
/// `query` applies only when `visible` is true.
var pendingPalette: E2EPaletteRequest?

/// The live palette model while the palette is open, for the
/// `paletteState` command. Weak: the window's ContentView owns it.
weak var paletteModel: PaletteModel?
```

and above the `E2EBridge` class:

```swift
/// One `setPalette` request. Equatable so views can `.onChange` on it.
struct E2EPaletteRequest: Equatable {
    let visible: Bool
    let query: String
}
```

- [ ] **Step 2: Add the socket commands**

In `E2ECommands.swift`, add to the `run(cmd:request:)` switch (after `case "setFileTree"`):

```swift
case "setPalette":
    return try setPalette(request: request)
case "paletteState":
    return try paletteState(request: request)
```

and the implementations next to `setSidebarMode`:

```swift
// MARK: - Command palette

/// Open/close the ⌘K palette, optionally pre-filling its query —
/// parked on the bridge and consumed by ContentView, same as
/// `setSidebarMode`.
private static func setPalette(request: [String: Any]) throws -> [String: Any] {
    let visible = request["visible"] as? Bool ?? true
    let query = request["query"] as? String ?? ""
    let (handles, _, _) = try projectStores()
    handles.bridge.pendingPalette = E2EPaletteRequest(visible: visible, query: query)
    return ["ok": true]
}

/// Snapshot of the open palette's results for driver assertions.
private static func paletteState(request: [String: Any]) throws -> [String: Any] {
    let (handles, _, _) = try projectStores()
    guard let model = handles.bridge.paletteModel else {
        return ["visible": false]
    }
    return [
        "visible": true,
        "query": model.query,
        "sections": model.sections.map { section in
            [
                "kind": section.kind.rawValue,
                "items": section.rows.map(\.candidate.title),
            ] as [String: Any]
        },
    ]
}
```

(`projectStores()` returns the same 3-tuple `setSidebarMode` destructures: `(handles, store, _)`.)

- [ ] **Step 3: Consume the pending request in ContentView**

Add next to `consumePendingSidebarModeIfAny()` (~line 1097):

```swift
/// Same consume-and-clear shape as `consumePendingSidebarModeIfAny`.
/// Builds the model here (not in the `.onChange(of: showPalette)`
/// creation path) so the request's query lands on the fresh model.
private func consumePendingPaletteIfAny() {
    guard let bridge = e2eBridge, let request = bridge.pendingPalette else { return }
    bridge.pendingPalette = nil
    if request.visible {
        let model = PaletteModel(sources: paletteSources())
        model.refresh()
        model.query = request.query
        paletteModel = model
        showPalette = true
    } else {
        showPalette = false
    }
}
```

Call it from `.onAppear` right after the existing `consumePendingSidebarModeIfAny()` (~line 302), and add an `.onChange` next to the `pendingSidebarMode` one (~line 345):

```swift
.onChange(of: e2eBridge?.pendingPalette) { _, _ in
    consumePendingPaletteIfAny()
}
```

Then park/clear the model on the bridge in the Task 4 `.onChange(of: showPalette)` block — after `paletteModel = model` in the open branch add `e2eBridge?.paletteModel = model` (skipped when a model already exists: also add `e2eBridge?.paletteModel = paletteModel` before the `if paletteModel == nil` guard, simplest is to set it unconditionally at the end of the open branch), and in the close branch add `e2eBridge?.paletteModel = nil`. Final shape:

```swift
.onChange(of: showPalette) { _, visible in
    if visible {
        if paletteModel == nil {
            let model = PaletteModel(sources: paletteSources())
            model.refresh()
            paletteModel = model
        }
        e2eBridge?.paletteModel = paletteModel
    } else {
        paletteModel = nil
        e2eBridge?.paletteModel = nil
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Add the driver scenario**

In `Scripts/e2e/driver.py`, add before `scenario_quit`:

```python
def scenario_palette(d):
    """⌘K palette: opens, reports empty-query sections, fuzzy-filters,
    and closes. Self-contained: launches the app when nothing is
    connected (python3 driver.py palette works standalone)."""
    if d.sock is None:
        d.launch_app()

        def project_window_up():
            state = d.state()
            active = state.get("activeProject")
            return active and active.get("name") == PROJECT_NAME
        d.wait_until(project_window_up, 30.0, f"project window for {PROJECT_NAME}")

    d.cmd("setPalette", visible=True)

    def palette_open():
        return d.cmd("paletteState").get("visible") is True
    d.wait_until(palette_open, 10.0, "palette visible")

    state = d.cmd("paletteState")
    kinds = [s["kind"] for s in state["sections"]]
    require("projects" in kinds, f"projects section missing on empty query: {kinds}")
    require("commands" in kinds, f"commands section missing on empty query: {kinds}")
    require("files" not in kinds, f"files section must wait for a query: {kinds}")
    d.screenshot("palette-empty-query")

    d.cmd("setPalette", visible=True, query="plan")

    def query_applied():
        s = d.cmd("paletteState")
        return s.get("visible") is True and s.get("query") == "plan"
    d.wait_until(query_applied, 10.0, "palette query applied")

    state = d.cmd("paletteState")
    titles = [t for s in state["sections"] for t in s["items"]]
    require(any("plan" in t.lower() for t in titles),
            f"no plan-ish result for query 'plan': {titles}")
    d.screenshot("palette-query-plan")

    d.cmd("setPalette", visible=False)

    def palette_closed():
        return d.cmd("paletteState").get("visible") is False
    d.wait_until(palette_closed, 10.0, "palette closed")
```

Register it in `SCENARIOS` between `("overview", scenario_overview)` and `("applets", scenario_applets)`:

```python
    ("palette", scenario_palette),
```

- [ ] **Step 6: Document the commands in the protocol**

In `Scripts/e2e/PROTOCOL.md`, add entries following the existing command format:

```markdown
### setPalette
Open or close the ⌘K command palette. `{"cmd": "setPalette", "visible": true, "query": "plan"}` — `visible` defaults to true, `query` (optional) pre-fills the search field when opening. Reply: `{"ok": true}`. Parked on the project bridge and consumed by ContentView, like `setSidebarMode`.

### paletteState
Snapshot the open palette. Reply when open: `{"visible": true, "query": "...", "sections": [{"kind": "projects", "items": ["..."]}]}`; when closed: `{"visible": false}`.
```

- [ ] **Step 7: Run the e2e suite**

Run: `Scripts/e2e/run-e2e.sh 2>&1 | tail -20`
Expected: every scenario including `palette` passes (exit 0); screenshots `palette-empty-query.png` / `palette-query-plan.png` land in the artifacts dir. If the full chain is too slow to iterate, `python3 Scripts/e2e/driver.py palette` works standalone (the scenario self-launches) — but the full suite must pass before commit.

- [ ] **Step 8: Run the unit tests (regression)**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 9: Commit**

```bash
git add Sources/Dreamux/E2E/E2ERegistry.swift Sources/Dreamux/E2E/E2ECommands.swift Sources/Dreamux/Views/ContentView.swift Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md
git commit -m "Palette e2e: setPalette/paletteState commands + palette scenario"
```

---

## Verification (after all tasks)

- `swift test` — all unit tests green.
- `Scripts/e2e/run-e2e.sh` — full scenario chain green, palette screenshots present.
- Manual spot-check in the running app (use the project's run/verify skill): ⌘N opens Create Project (rail expanded AND collapsed), ⌘P opens New Plan, ⌘K toggles the palette even while a terminal has focus, Esc/scrim-click dismisses, the rail search bar and collapsed magnifier open it, arrow keys + Return execute a project switch.
