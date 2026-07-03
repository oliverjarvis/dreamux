# Plans & Specs Sidebar + Single-Plan Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project-level `docs/` home whose specs and plans render in a collapsible Plans & Specs sidebar section with derived status, and a Run Plan flow that provisions a feature worktree and drives `claude` against the plan.

**Architecture:** Pure parsing (`PlanDoc`) and status derivation (`PlanStatusResolver`) feed an `@MainActor @Observable` `DocStore` that scans `<project>/docs/` and watches it for live checkbox progress. A `PlanRunCoordinator` composes the existing `FeatureProvisioner` + a new shared `ClaudePromptDriver` (extracted from `RunSetupView.sendClaude`) to execute plans; a run ledger at `.dreamux/plan-runs.json` makes plan↔feature links survive relaunch. The sidebar section sits above Features in `WorkspaceSidebar`; docs open through the existing file-tab path (rendered markdown from the universal-file-viewers plan).

**Tech Stack:** Swift 6 / SwiftUI, DispatchSource file watchers, existing git/worktree plumbing (`FeatureProvisioner`, `GitOperations`), `claude` CLI in PTY (`TabSession`), XCTest with `TestSandbox`/`GitFixtures`.

**Spec:** `docs/superpowers/specs/2026-07-02-plans-specs-orchestration-design.md` — read it before starting. Queue + merge gates are NOT in this plan (see `2026-07-02-plan-queue-gates.md`).

**Prerequisite:** the universal-file-viewers plan (`2026-07-02-universal-file-viewers.md`) must be implemented first — clicking a doc opens a rendered-markdown file tab.

## Global Constraints

- macOS 14 floor, Swift 6 strict concurrency; stores are `@MainActor @Observable`.
- No new package dependencies.
- Detection is by document **shape**, never by a superpowers-specific path: a plan is a markdown file whose first H1 ends with `Implementation Plan` OR that contains a `### Task N:` heading with `- [ ]`/`- [x]` steps; a spec is a file named `*-design.md` OR one referenced by a plan's `**Spec:**` line.
- The docs home is `<project>/docs/` with `specs/` and `plans/` as default (not required) subfolders. Never scan repos for docs in this plan.
- No status metadata is ever written into docs — status is derived from files + ledger + workspace existence.
- Naming: avoid `startPlan`/`StartPlan` — `RunnerManager.startPlan(for:)` already means "runner start plan". Use `runPlan`/`PlanRun*`.
- E2E stays inert without `DREAMUX_E2E_SOCKET`; keep `scripts/e2e/PROTOCOL.md` in lockstep.
- `swift build` and `swift test` pass at the end of every task; commit per task, staging only named files.

---

### Task 1: `PlanDoc` — parse one markdown doc

**Files:**
- Create: `Sources/Dreamux/Models/PlanDoc.swift`
- Test: `Tests/DreamuxTests/PlanDocTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `struct PlanDoc: Identifiable, Equatable` with `id: URL` (== `fileURL`), `fileURL: URL`, `kind: Kind` (`enum Kind: String { case plan, spec, doc }`), `title: String`, `date: String?`, `goal: String?`, `specReference: String?`, `checkedSteps: Int`, `totalSteps: Int`.
  - `static func parse(fileURL: URL, contents: String) -> PlanDoc`
  - `static func branchName(forFileName:) -> String` — filename stem minus `YYYY-MM-DD-` prefix and `-design` suffix.

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/PlanDocTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class PlanDocTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    func testPlanByH1Marker() {
        let d = doc("2026-07-02-widgets.md", """
        # Widgets Implementation Plan

        **Goal:** Build widgets.

        **Spec:** docs/specs/2026-07-02-widgets-design.md — read it first.
        """)
        XCTAssertEqual(d.kind, .plan)
        XCTAssertEqual(d.title, "Widgets Implementation Plan")
        XCTAssertEqual(d.date, "2026-07-02")
        XCTAssertEqual(d.goal, "Build widgets.")
        XCTAssertEqual(d.specReference, "docs/specs/2026-07-02-widgets-design.md")
    }

    func testPlanByTaskAndCheckboxShape() {
        let d = doc("notes.md", """
        # Some work

        ### Task 1: Do it
        - [x] **Step 1: a**
        - [ ] **Step 2: b**

        ### Task 2: More
        - [ ] **Step 1: c**
        """)
        XCTAssertEqual(d.kind, .plan)
        XCTAssertEqual(d.checkedSteps, 1)
        XCTAssertEqual(d.totalSteps, 3)
        XCTAssertNil(d.date)
    }

    func testSpecByFilenameSuffix() {
        let d = doc("2026-07-02-widgets-design.md", "# Widgets\n\nSome design.")
        XCTAssertEqual(d.kind, .spec)
        XCTAssertEqual(d.title, "Widgets")
    }

    func testCheckboxesAloneAreJustADoc() {
        let d = doc("todo.md", "# Todo\n- [ ] milk\n- [x] eggs\n")
        XCTAssertEqual(d.kind, .doc)
        XCTAssertEqual(d.totalSteps, 2)
    }

    func testTitleFallsBackToFilenameWithoutDatePrefix() {
        let d = doc("2026-01-01-no-heading.md", "no heading here")
        XCTAssertEqual(d.title, "no-heading")
    }

    func testSpecReferenceStripsBackticksAndTrailingProse() {
        let d = doc("p.md", """
        # X Implementation Plan
        **Spec:** `docs/specs/x-design.md` — read it before starting.
        """)
        XCTAssertEqual(d.specReference, "docs/specs/x-design.md")
    }

    func testBranchNameDerivation() {
        XCTAssertEqual(PlanDoc.branchName(forFileName: "2026-07-02-universal-file-viewers.md"),
                       "universal-file-viewers")
        XCTAssertEqual(PlanDoc.branchName(forFileName: "widgets-design.md"), "widgets")
        XCTAssertEqual(PlanDoc.branchName(forFileName: "plain.md"), "plain")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlanDocTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'PlanDoc' in scope`.

- [x] **Step 3: Implement**

Create `Sources/Dreamux/Models/PlanDoc.swift`:

```swift
import Foundation

/// One markdown document under the project docs home, classified by
/// SHAPE (never by path): superpowers-style plans and specs are
/// recognized wherever they sit, and anything else stays a plain doc.
struct PlanDoc: Identifiable, Equatable {
    enum Kind: String, Sendable { case plan, spec, doc }

    var id: URL { fileURL }
    let fileURL: URL
    let kind: Kind
    /// First `# ` heading, else the filename stem without date prefix.
    let title: String
    /// `YYYY-MM-DD` filename prefix when present.
    let date: String?
    /// The plan header's `**Goal:**` line, when present.
    let goal: String?
    /// The raw path from the plan header's `**Spec:**` line (backticks
    /// and trailing prose stripped), unresolved.
    let specReference: String?
    let checkedSteps: Int
    let totalSteps: Int

    static func parse(fileURL: URL, contents: String) -> PlanDoc {
        let lines = contents.components(separatedBy: .newlines)

        var firstH1: String?
        var goal: String?
        var specReference: String?
        var hasTaskHeading = false
        var checked = 0, total = 0

        for line in lines {
            if firstH1 == nil, line.hasPrefix("# ") {
                firstH1 = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if goal == nil, let value = headerValue(line, field: "Goal") {
                goal = value
            }
            if specReference == nil, let value = headerValue(line, field: "Spec") {
                specReference = stripDecoration(value)
            }
            if line.range(of: #"^###\s+Task\s+\d+:"#, options: .regularExpression) != nil {
                hasTaskHeading = true
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ]") { total += 1 }
            else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                total += 1; checked += 1
            }
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let date = datePrefix(of: stem)
        let kind: Kind
        if firstH1?.hasSuffix("Implementation Plan") == true || (hasTaskHeading && total > 0) {
            kind = .plan
        } else if stem.hasSuffix("-design") {
            kind = .spec
        } else {
            kind = .doc
        }

        return PlanDoc(
            fileURL: fileURL,
            kind: kind,
            title: firstH1 ?? stripDatePrefix(from: stem),
            date: date,
            goal: goal,
            specReference: specReference,
            checkedSteps: checked,
            totalSteps: total
        )
    }

    /// `2026-07-02-universal-file-viewers.md` → `universal-file-viewers`;
    /// a `-design` suffix is dropped too so a spec derives the same
    /// branch as its plan.
    static func branchName(forFileName name: String) -> String {
        var stem = (name as NSString).deletingPathExtension
        stem = stripDatePrefix(from: stem)
        if stem.hasSuffix("-design") { stem = String(stem.dropLast("-design".count)) }
        return stem
    }

    // MARK: - Helpers

    /// `**Field:** value` → `value` (nil when the line isn't that field).
    private static func headerValue(_ line: String, field: String) -> String? {
        let prefix = "**\(field):**"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Strip surrounding backticks and any ` — trailing prose`.
    private static func stripDecoration(_ value: String) -> String {
        var v = value
        if let dash = v.range(of: " — ") { v = String(v[..<dash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        return v
    }

    private static func datePrefix(of stem: String) -> String? {
        guard let range = stem.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression)
        else { return nil }
        return String(stem[range].dropLast())
    }

    private static func stripDatePrefix(from stem: String) -> String {
        guard let range = stem.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression)
        else { return stem }
        return String(stem[range.upperBound...])
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlanDocTests 2>&1 | tail -5`
Expected: PASS (7 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanDoc.swift Tests/DreamuxTests/PlanDocTests.swift
git commit -m "Add PlanDoc shape-based markdown doc parser"
```

---

### Task 2: `PlanStatusResolver` — derived plan status

**Files:**
- Create: `Sources/Dreamux/Models/PlanStatus.swift`
- Test: `Tests/DreamuxTests/PlanStatusTests.swift`

**Interfaces:**
- Consumes: Task 1's counts.
- Produces:
  - `enum PlanStatus: String { case specOnly, ready, inProgress, running, awaitingReview, merged }` with `var glyph: String` (SF Symbol) and `var label: String`.
  - `enum PlanStatusResolver { static func status(checked: Int, total: Int, hasRun: Bool, featureExists: Bool) -> PlanStatus }` — for plan docs. (`.specOnly` is assigned by `DocStore` to unpaired specs, not by the resolver.)

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/PlanStatusTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class PlanStatusTests: XCTestCase {
    func testNeverRunIsReady() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 10, hasRun: false, featureExists: false), .ready)
        // A stale feature worktree without a recorded run stays ready —
        // the run ledger is the authority on "this plan was executed".
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: false, featureExists: true), .ready)
    }

    func testRunWithLiveFeatureIsRunning() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: true, featureExists: true), .running)
    }

    func testRunWithoutFeatureAndUncheckedIsInProgress() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: true, featureExists: false), .inProgress)
    }

    func testAllCheckedWithFeatureAwaitsReview() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 10, total: 10, hasRun: true, featureExists: true), .awaitingReview)
    }

    func testAllCheckedFeatureGoneIsMerged() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 10, total: 10, hasRun: true, featureExists: false), .merged)
    }

    func testZeroStepPlanNeverCompletes() {
        // Degenerate plan without checkboxes: can run, never auto-merges.
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 0, hasRun: true, featureExists: true), .running)
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 0, hasRun: true, featureExists: false), .inProgress)
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlanStatusTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'PlanStatusResolver' in scope`.

- [x] **Step 3: Implement**

Create `Sources/Dreamux/Models/PlanStatus.swift`:

```swift
import Foundation

/// Where a plan sits in its lifecycle. Entirely DERIVED — from checkbox
/// progress in the plan file, the run ledger, and whether the linked
/// feature workspace currently exists. No status is ever written into
/// the doc.
enum PlanStatus: String, Sendable {
    case specOnly        // spec with no paired plan — "needs plan"
    case ready           // plan never run
    case inProgress      // run recorded, feature gone, boxes unchecked
    case running         // run recorded, feature alive
    case awaitingReview  // all boxes checked, feature still open
    case merged          // all boxes checked, feature closed (merge flow tears the worktree down)

    var glyph: String {
        switch self {
        case .specOnly: return "doc.badge.ellipsis"
        case .ready: return "circle.dotted"
        case .inProgress: return "circle.lefthalf.filled"
        case .running: return "play.circle.fill"
        case .awaitingReview: return "checkmark.circle.badge.questionmark"
        case .merged: return "checkmark.seal.fill"
        }
    }

    var label: String {
        switch self {
        case .specOnly: return "needs plan"
        case .ready: return "ready"
        case .inProgress: return "in progress"
        case .running: return "running"
        case .awaitingReview: return "awaiting review"
        case .merged: return "merged"
        }
    }
}

enum PlanStatusResolver {
    /// Status for a PLAN doc. `hasRun` = a ledger record links this plan
    /// to a feature; `featureExists` = that feature is currently in the
    /// sidebar (worktrees on disk).
    static func status(
        checked: Int,
        total: Int,
        hasRun: Bool,
        featureExists: Bool
    ) -> PlanStatus {
        guard hasRun else { return .ready }
        let complete = total > 0 && checked == total
        if complete {
            return featureExists ? .awaitingReview : .merged
        }
        return featureExists ? .running : .inProgress
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlanStatusTests 2>&1 | tail -5`
Expected: PASS (6 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanStatus.swift Tests/DreamuxTests/PlanStatusTests.swift
git commit -m "Add derived PlanStatus resolver"
```

---

### Task 3: `PlanRunLedger` — `.dreamux/plan-runs.json`

**Files:**
- Create: `Sources/Dreamux/Models/PlanRunLedger.swift`
- Test: `Tests/DreamuxTests/PlanRunLedgerTests.swift`

**Interfaces:**
- Consumes: `Project.rootPath`.
- Produces:
  - `struct PlanRunRecord: Codable, Equatable { var planPath: String; var featureName: String; var startedAt: Date }` — `planPath` is relative to the project root (e.g. `docs/plans/2026-07-02-x.md`).
  - `@MainActor @Observable final class PlanRunLedger` with `init(project: Project)`, `private(set) var records: [PlanRunRecord]`, `func record(planPath: String, featureName: String)` (replaces an existing record for the same plan), `func recordForPlan(_ relativePath: String) -> PlanRunRecord?`, `func reconcile(existingFeatureNames: Set<String>, isPlanComplete: (String) -> Bool)` — prunes records whose feature is gone AND whose plan isn't fully checked (feature closed without merging → plan returns to ready; completed-then-closed records are kept so `merged` sticks).

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/PlanRunLedgerTests.swift`:

```swift
import XCTest
@testable import Dreamux

@MainActor
final class PlanRunLedgerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testRecordPersistsAcrossReload() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/a.md", featureName: "a")
        XCTAssertEqual(ledger.recordForPlan("docs/plans/a.md")?.featureName, "a")

        let reloaded = PlanRunLedger(project: project)
        XCTAssertEqual(reloaded.recordForPlan("docs/plans/a.md")?.featureName, "a")
    }

    func testRecordReplacesSamePlan() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/a.md", featureName: "a")
        ledger.record(planPath: "docs/plans/a.md", featureName: "a-retry")
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.recordForPlan("docs/plans/a.md")?.featureName, "a-retry")
    }

    func testReconcilePrunesAbandonedButKeepsCompleted() {
        let ledger = PlanRunLedger(project: project)
        ledger.record(planPath: "docs/plans/abandoned.md", featureName: "abandoned")
        ledger.record(planPath: "docs/plans/done.md", featureName: "done")
        ledger.record(planPath: "docs/plans/live.md", featureName: "live")

        ledger.reconcile(
            existingFeatureNames: ["live"],
            isPlanComplete: { $0 == "docs/plans/done.md" }
        )

        XCTAssertNil(ledger.recordForPlan("docs/plans/abandoned.md"))
        XCTAssertNotNil(ledger.recordForPlan("docs/plans/done.md"))
        XCTAssertNotNil(ledger.recordForPlan("docs/plans/live.md"))
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlanRunLedgerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'PlanRunLedger' in scope`.

- [x] **Step 3: Implement**

Create `Sources/Dreamux/Models/PlanRunLedger.swift`:

```swift
import Foundation
import Observation

/// One "this plan was executed as this feature" link.
struct PlanRunRecord: Codable, Equatable {
    /// Plan file path relative to the project root.
    var planPath: String
    var featureName: String
    var startedAt: Date
}

/// Plan↔feature links, persisted to `<project>/.dreamux/plan-runs.json`
/// (same JSON-atomic-write pattern as `SidebarLayoutStore`) so plan
/// status survives relaunch. The ledger is the authority on "this plan
/// has been run"; checkbox progress and feature existence supply the
/// rest of the status derivation.
@MainActor
@Observable
final class PlanRunLedger {
    private(set) var records: [PlanRunRecord]
    @ObservationIgnored private let fileURL: URL

    init(project: Project) {
        fileURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("plan-runs.json")
        records = Self.load(from: fileURL)
    }

    func record(planPath: String, featureName: String) {
        records.removeAll { $0.planPath == planPath }
        records.append(PlanRunRecord(
            planPath: planPath, featureName: featureName, startedAt: Date()))
        save()
    }

    func recordForPlan(_ relativePath: String) -> PlanRunRecord? {
        records.first { $0.planPath == relativePath }
    }

    /// Drop records whose feature was closed WITHOUT completing the plan
    /// (the plan goes back to `ready`). Records for completed plans are
    /// kept even after the feature is torn down — that's what makes the
    /// plan read `merged`.
    func reconcile(
        existingFeatureNames: Set<String>,
        isPlanComplete: (String) -> Bool
    ) {
        let before = records
        records.removeAll { record in
            !existingFeatureNames.contains(record.featureName)
                && !isPlanComplete(record.planPath)
        }
        if records != before { save() }
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [PlanRunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PlanRunRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlanRunLedgerTests 2>&1 | tail -5`
Expected: PASS (3 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanRunLedger.swift Tests/DreamuxTests/PlanRunLedgerTests.swift
git commit -m "Add plan-run ledger persisted to .dreamux/plan-runs.json"
```

---

### Task 4: `DocStore` — scan, classify, pair, watch

**Files:**
- Create: `Sources/Dreamux/Models/DocStore.swift`
- Test: `Tests/DreamuxTests/DocStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `@MainActor @Observable final class DocStore`: `init(project: Project)`, `let docsRoot: URL` (`<project>/docs`), `let ledger: PlanRunLedger`, `private(set) var docs: [PlanDoc]`, `func refresh()`, `func startWatching()`, `func stopWatching()`.
  - Views: `var plans: [PlanDoc]`, `var unpairedSpecs: [PlanDoc]`, `var otherDocs: [PlanDoc]`, `func pairedSpec(for plan: PlanDoc) -> PlanDoc?`, `func relativePath(of doc: PlanDoc) -> String`, `func status(for plan: PlanDoc, featureExists: (String) -> Bool) -> PlanStatus`.
  - `static func ensureDocsHome(at projectRoot: URL)` — creates `docs/specs` and `docs/plans`.

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/DocStoreTests.swift`:

```swift
import XCTest
@testable import Dreamux

@MainActor
final class DocStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    private func write(_ relative: String, _ contents: String) throws {
        let url = project.rootPath.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testEnsureDocsHomeCreatesDefaultLayout() {
        DocStore.ensureDocsHome(at: project.rootPath)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/specs").path,
            isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/plans").path,
            isDirectory: &isDir) && isDir.boolValue)
    }

    func testScanClassifiesAndPairs() throws {
        try write("docs/specs/2026-07-02-x-design.md", "# X\n\ndesign")
        try write("docs/plans/2026-07-02-x.md", """
        # X Implementation Plan
        **Spec:** docs/specs/2026-07-02-x-design.md — read it.
        ### Task 1: a
        - [x] **Step 1: t**
        - [ ] **Step 2: u**
        """)
        try write("docs/notes.md", "# Notes\nplain")
        try write("docs/.hidden.md", "# skip me")

        let store = DocStore(project: project)
        store.refresh()

        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.unpairedSpecs.count, 0, "x-design is paired via **Spec:**")
        XCTAssertEqual(store.otherDocs.map(\.title), ["Notes"])

        let plan = store.plans[0]
        XCTAssertEqual(store.pairedSpec(for: plan)?.title, "X")
        XCTAssertEqual(store.relativePath(of: plan), "docs/plans/2026-07-02-x.md")
        XCTAssertEqual(plan.checkedSteps, 1)
        XCTAssertEqual(plan.totalSteps, 2)
    }

    func testSpecReferencedByPlanIsSpecEvenWithoutSuffix() throws {
        try write("docs/x-spec.md", "# X spec\nprose")
        try write("docs/x-plan.md", """
        # X Implementation Plan
        **Spec:** docs/x-spec.md
        """)
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertEqual(store.plans.count, 1)
        XCTAssertEqual(store.pairedSpec(for: store.plans[0])?.title, "X spec")
        XCTAssertTrue(store.otherDocs.isEmpty)
    }

    func testUnpairedSpecSurfacesAsSpecOnly() throws {
        try write("docs/specs/lonely-design.md", "# Lonely\n")
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertEqual(store.unpairedSpecs.map(\.title), ["Lonely"])
        XCTAssertEqual(store.status(for: store.unpairedSpecs[0], featureExists: { _ in false }),
                       .specOnly)
    }

    func testStatusUsesLedgerAndFeatureExistence() throws {
        try write("docs/plans/y.md", """
        # Y Implementation Plan
        ### Task 1: a
        - [x] **Step 1: t**
        """)
        let store = DocStore(project: project)
        store.refresh()
        let plan = store.plans[0]

        XCTAssertEqual(store.status(for: plan, featureExists: { _ in false }), .ready)
        store.ledger.record(planPath: "docs/plans/y.md", featureName: "y")
        XCTAssertEqual(store.status(for: plan, featureExists: { $0 == "y" }), .awaitingReview)
        XCTAssertEqual(store.status(for: plan, featureExists: { _ in false }), .merged)
    }

    func testMissingDocsDirYieldsEmpty() {
        let store = DocStore(project: project)
        store.refresh()
        XCTAssertTrue(store.docs.isEmpty)
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DocStoreTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'DocStore' in scope`.

- [x] **Step 3: Implement**

Create `Sources/Dreamux/Models/DocStore.swift`:

```swift
import Foundation
import Observation

/// Discovers and watches the project-level docs home (`<project>/docs/`),
/// classifying every markdown file by shape via `PlanDoc`. Holds the run
/// ledger so views can derive each plan's status in one place. Watching
/// is kqueue-based (one DispatchSource per directory, rebuilt on every
/// scan) — the docs tree is shallow, and live checkbox ticks from a
/// running claude session land as `.write` events on `docs/plans/`.
@MainActor
@Observable
final class DocStore {
    private(set) var docs: [PlanDoc] = []
    let docsRoot: URL
    let projectRoot: URL
    let ledger: PlanRunLedger

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init(project: Project) {
        projectRoot = project.rootPath
        docsRoot = project.rootPath.appendingPathComponent("docs", isDirectory: true)
        ledger = PlanRunLedger(project: project)
    }

    static func ensureDocsHome(at projectRoot: URL) {
        let docs = projectRoot.appendingPathComponent("docs", isDirectory: true)
        for sub in ["specs", "plans"] {
            try? FileManager.default.createDirectory(
                at: docs.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    // MARK: - Scan

    func refresh() {
        var found: [PlanDoc] = []
        var directories: [URL] = [docsRoot]
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: docsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    directories.append(url)
                } else if url.pathExtension.lowercased() == "md",
                          let contents = try? String(contentsOf: url, encoding: .utf8) {
                    found.append(PlanDoc.parse(fileURL: url, contents: contents))
                }
            }
        }

        // Pairing pass: a file referenced by any plan's **Spec:** line is
        // a spec even without the -design suffix.
        let referencedSpecs = Set(found
            .filter { $0.kind == .plan }
            .compactMap { $0.specReference.map { ref in resolve(ref).standardizedFileURL } })
        docs = found.map { doc in
            if doc.kind == .doc, referencedSpecs.contains(doc.fileURL.standardizedFileURL) {
                return PlanDoc(
                    fileURL: doc.fileURL, kind: .spec, title: doc.title, date: doc.date,
                    goal: doc.goal, specReference: doc.specReference,
                    checkedSteps: doc.checkedSteps, totalSteps: doc.totalSteps)
            }
            return doc
        }
        .sorted { ($0.date ?? "") > ($1.date ?? "") }

        rebuildWatchers(for: directories)
    }

    // MARK: - Views over the scan

    var plans: [PlanDoc] { docs.filter { $0.kind == .plan } }

    var unpairedSpecs: [PlanDoc] {
        let paired = Set(plans.compactMap { pairedSpec(for: $0)?.fileURL })
        return docs.filter { $0.kind == .spec && !paired.contains($0.fileURL) }
    }

    var otherDocs: [PlanDoc] { docs.filter { $0.kind == .doc } }

    /// The plan's spec: **Spec:** back-link first (authoritative), then
    /// the filename convention (plan name + `-design`).
    func pairedSpec(for plan: PlanDoc) -> PlanDoc? {
        if let ref = plan.specReference {
            let target = resolve(ref).standardizedFileURL
            if let match = docs.first(where: { $0.fileURL.standardizedFileURL == target }) {
                return match
            }
        }
        let expected = PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent)
        return docs.first {
            $0.kind == .spec
                && PlanDoc.branchName(forFileName: $0.fileURL.lastPathComponent) == expected
        }
    }

    func relativePath(of doc: PlanDoc) -> String {
        doc.fileURL.path.replacingOccurrences(
            of: projectRoot.standardizedFileURL.path + "/", with: "")
    }

    func status(for doc: PlanDoc, featureExists: (String) -> Bool) -> PlanStatus {
        guard doc.kind == .plan else { return .specOnly }
        let record = ledger.recordForPlan(relativePath(of: doc))
        return PlanStatusResolver.status(
            checked: doc.checkedSteps,
            total: doc.totalSteps,
            hasRun: record != nil,
            featureExists: record.map { featureExists($0.featureName) } ?? false
        )
    }

    /// Prune ledger records for features closed before completing their
    /// plan. Call whenever the feature list changes.
    func reconcileLedger(existingFeatureNames: Set<String>) {
        ledger.reconcile(existingFeatureNames: existingFeatureNames) { planPath in
            guard let doc = docs.first(where: { relativePath(of: $0) == planPath })
            else { return false }
            return doc.totalSteps > 0 && doc.checkedSteps == doc.totalSteps
        }
    }

    // MARK: - Watching

    func startWatching() { refresh() }

    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        debounce?.cancel()
    }

    private func rebuildWatchers(for directories: [URL]) {
        watchers.forEach { $0.cancel() }
        watchers = directories.compactMap { dir in
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func resolve(_ reference: String) -> URL {
        reference.hasPrefix("/")
            ? URL(fileURLWithPath: reference)
            : projectRoot.appendingPathComponent(reference)
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DocStoreTests 2>&1 | tail -5`
Expected: PASS (6 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/DocStore.swift Tests/DreamuxTests/DocStoreTests.swift
git commit -m "Add DocStore: scan, classify, pair, and watch project docs"
```

---

### Task 5: Docs symlink + agent instructions in `FeatureProvisioner`

**Files:**
- Modify: `Sources/Dreamux/Shell/FeatureProvisioner.swift`
- Test: `Tests/DreamuxTests/FeatureProvisionerTests.swift`

**Interfaces:**
- Consumes: Task 4's `DocStore.ensureDocsHome`.
- Produces: every provisioned/rebuilt feature aggregation dir contains a `docs` symlink → `../../docs` (named `project-docs` when a linked repo is itself named `docs`); `DREAMUX.md` documents the docs home and instructs agents to write specs/plans there.

- [x] **Step 1: Write the failing test**

Append to `Tests/DreamuxTests/FeatureProvisionerTests.swift` (reuse its existing sandbox/repo fixtures — it already provisions features against `GitFixtures` repos; follow its local helper names):

```swift
    func testProvisionLinksProjectDocsIntoAggregationDir() async throws {
        // Arrange a repo and provision (mirror the existing provision test setup).
        let repo = try await makeRepo(named: "api")
        let dir = try await FeatureProvisioner.provision(
            featureName: "docs-link", in: project, across: [repo])

        let link = dir.appendingPathComponent("docs")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(dest, "../../docs")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/plans").path,
            isDirectory: &isDir) && isDir.boolValue,
            "provision ensures the docs home exists")

        let readme = try String(
            contentsOf: dir.appendingPathComponent("DREAMUX.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("docs/specs/"))
        XCTAssertTrue(readme.contains("docs/plans/"))
    }

    func testDocsSymlinkRenamedWhenRepoNamedDocs() async throws {
        let repo = try await makeRepo(named: "docs")
        let dir = try await FeatureProvisioner.provision(
            featureName: "collide", in: project, across: [repo])
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("project-docs").path)
        XCTAssertEqual(dest, "../../docs")
        // The repo's own symlink keeps its name.
        let repoDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("docs").path)
        XCTAssertEqual(repoDest, "../../repos/docs/collide")
    }
```

(If `makeRepo(named:)` doesn't exist under that exact name in the test file, use its actual repo-fixture helper — the file already creates repos for provisioning tests.)

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FeatureProvisionerTests 2>&1 | tail -5`
Expected: FAIL — no `docs` symlink, readme assertions fail.

- [x] **Step 3: Implement**

In `Sources/Dreamux/Shell/FeatureProvisioner.swift`:

Add a helper near the top of the enum:

```swift
    /// Name of the project-docs symlink inside a feature dir: `docs`,
    /// unless a linked repo claims that name — then `project-docs`.
    static func docsLinkName(repoNames: [String]) -> String {
        repoNames.contains("docs") ? "project-docs" : "docs"
    }

    /// Link the shared project docs home into the aggregation dir so
    /// every agent session reads and writes the same specs/plans (and
    /// checkbox ticks are visible to the app instantly).
    private static func linkProjectDocs(
        into featureDir: URL,
        project: Project,
        repos: [Repository]
    ) {
        DocStore.ensureDocsHome(at: project.rootPath)
        let linkURL = featureDir.appendingPathComponent(
            docsLinkName(repoNames: repos.map(\.name)))
        let target = "../../docs"
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
           existing == target { return }
        try? FileManager.default.removeItem(at: linkURL)
        try? FileManager.default.createSymbolicLink(
            atPath: linkURL.path, withDestinationPath: target)
    }
```

In `provision(...)`, after the repo loop succeeds and before `writeReadme(...)`, add:

```swift
        linkProjectDocs(into: featureDir, project: project, repos: provisionedRepos)
```

In `ensureFeatureDirectory(...)`, after the repo symlink loop and before `writeReadme(...)`, add:

```swift
        linkProjectDocs(into: featureDir, project: project, repos: repos)
```

In `writeReadme(...)`, extend the body string — after the `## Multi-repo work` paragraph, append this section (inside the same `"""` literal; `\(docsName)` comes from a new local `let docsName = docsLinkName(repoNames: repos.map(\.name))` at the top of the function):

```markdown

## Project docs — specs & plans

`\(docsName)/` here is a symlink to the PROJECT-level docs home shared
by every feature (it is not part of any repo). When you write design
specs or implementation plans (e.g. via brainstorming/writing-plans
skills), save them there instead of any per-repo docs folder:

- specs → `\(docsName)/specs/YYYY-MM-DD-<topic>-design.md`
- plans → `\(docsName)/plans/YYYY-MM-DD-<topic>.md`

Dreamux's sidebar lists these files and tracks plan progress from
their `- [ ]` checkboxes — tick each step's checkbox in the plan file
as you complete it.
```

- [x] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS (existing provisioner tests still green — rollback removes the whole feature dir, so the docs link needs no special rollback).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/FeatureProvisioner.swift Tests/DreamuxTests/FeatureProvisionerTests.swift
git commit -m "Symlink project docs home into feature dirs; document it in DREAMUX.md"
```

---

### Task 6: Extract `ClaudePromptDriver` from RunSetupView

**Files:**
- Create: `Sources/Dreamux/Shell/ClaudePromptDriver.swift`
- Modify: `Sources/Dreamux/Views/RunSetupView.swift`

**Interfaces:**
- Consumes: `TabSession.send(_:)`, `isShellQuiescent(for:)`, `lastShellOutputAt`; `ClaudeCodeIntegration.claudeInvocation`.
- Produces: `@MainActor enum ClaudePromptDriver` with `static func send(_ prompt: String, into session: TabSession)`, `static func claudeCommand(_ argument: String, quoted: Bool) -> String`, `static func shellQuote(_ text: String) -> String`. RunSetupView behavior is unchanged.

- [x] **Step 1: Create the driver by MOVING code**

Create `Sources/Dreamux/Shell/ClaudePromptDriver.swift` and move — verbatim, including their doc comments — these three members out of `RunSetupView` (`Sources/Dreamux/Views/RunSetupView.swift:373-439` and `:546-552`):

- `sendClaude(_ prompt: String)` → becomes `static func send(_ prompt: String, into session: TabSession)`. The body is identical except the first line (`let session = ensureTerminal()`) is deleted — the session now arrives as the parameter — and `claudeCommand`/`shellQuote` references become `Self.`-local calls.
- `claudeCommand(_ argument: String, quoted: Bool = true) -> String` → `static`, unchanged body.
- `shellQuote(_ text: String) -> String` → `static`, unchanged body.

Wrap them in:

```swift
import Foundation

/// Types a `claude "$(cat <promptfile>)"` invocation into a PTY shell,
/// reliably. Extracted from RunSetupView so every claude-driving flow
/// (run detect/isolate/diagnose, plan execution, planning kickoff)
/// shares the one battle-tested delivery loop. See the doc comments on
/// `send` for why prompts go through a file and why delivery is
/// verified by echo rather than timing.
@MainActor
enum ClaudePromptDriver {
    // moved members here
}
```

- [x] **Step 2: Point RunSetupView at the driver**

In `Sources/Dreamux/Views/RunSetupView.swift`, replace the moved members with a thin forwarder so call sites stay small:

```swift
    private func sendClaude(_ prompt: String) {
        ClaudePromptDriver.send(prompt, into: ensureTerminal())
    }
```

`runDetect`/`runIsolate`/`runDiagnose` keep calling `sendClaude(...)` unchanged. Delete the now-unused local `claudeCommand`/`shellQuote` (the prompts themselves don't use them; verify with a search in the file before deleting).

- [x] **Step 3: Build and run the suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass — this is a pure move; `FakeClaudeDetectTests` and runner tests stay green.

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/Shell/ClaudePromptDriver.swift Sources/Dreamux/Views/RunSetupView.swift
git commit -m "Extract shared ClaudePromptDriver from RunSetupView"
```

---

### Task 7: `WorkspaceSession.openAgentTab` — a terminal tab you can drive

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift`
- Test: `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift` (same file hosts session-level tab tests)

**Interfaces:**
- Consumes: existing `nextTabCwdOverride` / `handleDidCreateTab` machinery.
- Produces: `@discardableResult func openAgentTab(at path: String, title: String, icon: String) -> TabSession?` — creates a terminal tab cwd'd at `path` and returns its `TabSession` so callers can `ClaudePromptDriver.send` into it. Also `private(set) var lastCreatedTabID: TabID?`.

- [x] **Step 1: Write the failing test**

Append to `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift`:

```swift
    @MainActor
    func testOpenAgentTabReturnsItsTabSession() {
        let returned = session.openAgentTab(
            at: sandbox.root.path, title: "plan: x", icon: "text.badge.checkmark")
        XCTAssertNotNil(returned)
        XCTAssertEqual(returned?.cwd, sandbox.root.path)
    }
```

(`TabSession` creation does not spawn a PTY — the shell starts on `startIfNeeded()` from the view's `onAppear` — so this is safe in unit tests. If `TabSession` has no public `cwd` property, add `let cwd: String?` stored from its initializer as part of this task and assert on it.)

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkspaceSessionFileTabTests 2>&1 | tail -5`
Expected: FAIL — no member `openAgentTab`.

- [x] **Step 3: Implement**

In `Sources/Dreamux/Models/WorkspaceSession.swift`:

Add near the other `nextTab…` declarations:

```swift
    /// Tab id of the most recently created tab — set by
    /// `handleDidCreateTab` (which Bonsplit calls synchronously inside
    /// `createTab`), so `open…` methods can look up the session they
    /// just caused to exist.
    private(set) var lastCreatedTabID: TabID?
```

In `handleDidCreateTab(_ tab: Tab)`, immediately AFTER the opening `guard … else { return }` (so only genuinely new tabs record it, but all three tab kinds do):

```swift
        lastCreatedTabID = tab.id
```

Add below `openTab(at:title:icon:)`:

```swift
    /// Open a terminal tab cwd'd at `path` and hand back its TabSession
    /// so the caller can type into it (plan execution, planning
    /// kickoffs). Same mechanics as `openTab`, plus the return value.
    @discardableResult
    func openAgentTab(at path: String, title: String, icon: String) -> TabSession? {
        nextTabCwdOverride = path
        controller.createTab(title: title, icon: icon)
        nextTabCwdOverride = nil
        guard let id = lastCreatedTabID else { return nil }
        return tabSessions[id]
    }
```

If `TabSession` doesn't expose its cwd, in `Sources/Dreamux/Models/TabSession.swift` store it: add `let cwd: String?` assigned from the initializer's `cwd` parameter.

- [x] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/WorkspaceSession.swift Sources/Dreamux/Models/TabSession.swift Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift
git commit -m "Add WorkspaceSession.openAgentTab returning the created TabSession"
```

---

### Task 8: `PlanPrompts` + `PlanRunCoordinator`

**Files:**
- Create: `Sources/Dreamux/Shell/PlanPrompts.swift`
- Create: `Sources/Dreamux/Shell/PlanRunCoordinator.swift`
- Test: `Tests/DreamuxTests/PlanPromptsTests.swift`
- Test: `Tests/DreamuxTests/PlanRunCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 3–7 (`DocStore`, `PlanRunLedger`, `FeatureProvisioner`, `ClaudePromptDriver`, `openAgentTab`), `WorkspaceStore.registerFeature`, `PlanDoc.branchName`.
- Produces:
  - `enum PlanPrompts` — `static func runPlan(planRelativePath: String, docsLinkName: String) -> String`, `static func resumePlan(planRelativePath: String, docsLinkName: String) -> String`, `static func brainstormKickoff(idea: String) -> String`, `static func writePlanKickoff(specRelativePath: String) -> String`.
  - `@MainActor final class PlanRunCoordinator` — `init(project: Project, workspaceStore: WorkspaceStore, repoStore: RepoStore, docStore: DocStore)`, `func runPlan(_ doc: PlanDoc, branchName: String, repoNames: [String]) async throws -> Workspace` (provision or resume + ledger + agent tab + prompt), and an injectable `var sendPrompt: (String, TabSession) -> Void` defaulting to `ClaudePromptDriver.send` (tests capture prompts without a PTY).

- [x] **Step 1: Write the failing prompt tests**

Create `Tests/DreamuxTests/PlanPromptsTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class PlanPromptsTests: XCTestCase {
    func testRunPlanPromptNamesTheFileAndCheckboxContract() {
        let p = PlanPrompts.runPlan(
            planRelativePath: "docs/plans/2026-07-02-x.md", docsLinkName: "docs")
        XCTAssertTrue(p.contains("docs/plans/2026-07-02-x.md"))
        XCTAssertTrue(p.contains("- [ ]"))
        XCTAssertTrue(p.contains("- [x]"))
        XCTAssertTrue(p.contains("task-by-task"))
    }

    func testResumePromptMentionsContinuing() {
        let p = PlanPrompts.resumePlan(
            planRelativePath: "docs/plans/x.md", docsLinkName: "project-docs")
        XCTAssertTrue(p.contains("project-docs/plans/x.md")
                      || p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.lowercased().contains("continue"))
    }

    func testBrainstormKickoffCarriesIdeaAndTargets() {
        let p = PlanPrompts.brainstormKickoff(idea: "make widgets fast")
        XCTAssertTrue(p.contains("make widgets fast"))
        XCTAssertTrue(p.contains("docs/specs/"))
        XCTAssertTrue(p.contains("docs/plans/"))
        XCTAssertTrue(p.contains("brainstorming"))
    }

    func testWritePlanKickoffTargetsSpec() {
        let p = PlanPrompts.writePlanKickoff(specRelativePath: "docs/specs/x-design.md")
        XCTAssertTrue(p.contains("docs/specs/x-design.md"))
        XCTAssertTrue(p.contains("writing-plans"))
    }
}
```

- [x] **Step 2: Run to verify failure, then implement `PlanPrompts`**

Run: `swift test --filter PlanPromptsTests 2>&1 | tail -5` — expect `cannot find 'PlanPrompts'`.

Create `Sources/Dreamux/Shell/PlanPrompts.swift`:

```swift
import Foundation

/// The prompts Dreamux types into claude sessions for plan work. Kept
/// as pure functions so tests can pin the contract (file paths named,
/// checkbox-ticking instruction present) without a PTY.
enum PlanPrompts {
    /// Kick off execution of a plan inside a freshly provisioned
    /// feature aggregation directory.
    static func runPlan(planRelativePath: String, docsLinkName: String) -> String {
        """
        You're in a Dreamux feature directory (see DREAMUX.md — each \
        subfolder is a git worktree for one repo; `\(docsLinkName)/` is the \
        shared project docs home).

        Read \(planRelativePath) and implement it task-by-task, \
        following the plan's own execution instructions (the "For agentic \
        workers" header). The contract Dreamux relies on:

        - As you complete each step, edit the plan file itself to tick its \
        checkbox (`- [ ]` → `- [x]`) and save — the app tracks live \
        progress from that file.
        - Commit exactly as the plan's steps direct, inside the relevant \
        repo subfolder.
        - Stop and ask if a step fails rather than improvising around it.

        Begin with Task 1's first unchecked step.
        """
    }

    /// Re-enter a partially executed plan in its existing worktree.
    static func resumePlan(planRelativePath: String, docsLinkName: String) -> String {
        """
        You're back in a Dreamux feature directory (see DREAMUX.md; \
        `\(docsLinkName)/` is the shared project docs home). The plan at \
        \(planRelativePath) is partially done — checked boxes (`- [x]`) are \
        complete, unchecked (`- [ ]`) are not. Verify the last checked \
        step's commit exists, then continue from the first unchecked step, \
        ticking checkboxes in the plan file as you go and committing as \
        the plan directs.
        """
    }

    /// Start a brainstorming dialogue in the project-scope planning tab.
    static func brainstormKickoff(idea: String) -> String {
        """
        You're planning work for this Dreamux project. The folders under \
        ./repos/<repo>/<default-branch>/ are reference checkouts of each \
        repo's default branch — explore them read-only to ground the \
        design; implementation happens later in dedicated worktrees.

        Use your brainstorming skill (superpowers:brainstorming) to turn \
        the idea below into a validated design through dialogue with me. \
        Write the resulting spec to docs/specs/YYYY-MM-DD-<topic>-design.md \
        and, once I approve it, the implementation plan to \
        docs/plans/YYYY-MM-DD-<topic>.md (superpowers:writing-plans). Use \
        those exact folders — they're this project's shared docs home that \
        the app's sidebar reads.

        Idea: \(idea)
        """
    }

    /// Turn an existing spec into a plan.
    static func writePlanKickoff(specRelativePath: String) -> String {
        """
        Read \(specRelativePath) — an approved design spec in this \
        project's shared docs home. Use your writing-plans skill \
        (superpowers:writing-plans) to produce its implementation plan and \
        save it to docs/plans/ named after the spec (spec filename minus \
        `-design`). The repos under ./repos/<repo>/<default-branch>/ are \
        reference checkouts for grounding exact file paths and code.
        """
    }
}
```

Run: `swift test --filter PlanPromptsTests 2>&1 | tail -5` — expect PASS. (Note: `runPlan` interpolates `planRelativePath` as given — callers pass the ledger-style project-relative path, which is also valid inside the feature dir because the `docs` symlink mirrors the layout. The `docsLinkName` parameter exists for the `project-docs` collision case; when it's `project-docs`, callers pass a path already rewritten with that prefix — see the coordinator below.)

- [x] **Step 3: Write the failing coordinator test**

Create `Tests/DreamuxTests/PlanRunCoordinatorTests.swift`:

```swift
import XCTest
@testable import Dreamux

@MainActor
final class PlanRunCoordinatorTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testRunPlanProvisionsRecordsAndSendsPrompt() async throws {
        // Real repo so FeatureProvisioner can add a worktree — reuse the
        // GitFixtures helper the provisioner tests use.
        let repoStore = RepoStore(project: project)
        let repo = try await GitFixtures.makeBareRepoWithWorktree(
            named: "api", in: project, files: ["README.md": "hi"])
        await repoStore.reload()

        try "# X Implementation Plan\n### Task 1: a\n- [ ] **Step 1: t**\n"
            .write(to: {
                let dir = project.rootPath.appendingPathComponent("docs/plans")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("2026-07-02-x.md")
            }(), atomically: true, encoding: .utf8)

        let docStore = DocStore(project: project)
        docStore.refresh()
        let workspaceStore = WorkspaceStore()
        let coordinator = PlanRunCoordinator(
            project: project, workspaceStore: workspaceStore,
            repoStore: repoStore, docStore: docStore)

        var sentPrompt: String?
        coordinator.sendPrompt = { prompt, _ in sentPrompt = prompt }

        let workspace = try await coordinator.runPlan(
            docStore.plans[0], branchName: "x", repoNames: [repo.name])

        XCTAssertEqual(workspace.name, "x")
        XCTAssertEqual(docStore.ledger.recordForPlan("docs/plans/2026-07-02-x.md")?.featureName, "x")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("features/x/api").path))
        XCTAssertEqual(sentPrompt?.contains("docs/plans/2026-07-02-x.md"), true)
        XCTAssertEqual(workspaceStore.activeID, workspace.id)
    }
}
```

(Adapt the two fixture calls — `RepoStore(project:)`/`reload()` and `GitFixtures.makeBareRepoWithWorktree` — to the actual helper names in `Tests/DreamuxTests/Support/GitFixtures.swift` and the provisioner tests; the assertions are the contract.)

- [x] **Step 4: Implement the coordinator**

Create `Sources/Dreamux/Shell/PlanRunCoordinator.swift`:

```swift
import Foundation

enum PlanRunError: LocalizedError {
    case notAPlan
    case noRepositories

    var errorDescription: String? {
        switch self {
        case .notAPlan: return "Only plan documents can be run."
        case .noRepositories: return "Pick at least one repository to run the plan in."
        }
    }
}

/// Executes a plan: provision (or resume) the feature worktrees, record
/// the plan↔feature link, open a terminal tab in the feature, and type
/// the claude invocation. Shared by the sidebar's Run Plan sheet and
/// the e2e `runPlan` command so both paths are the same code.
@MainActor
final class PlanRunCoordinator {
    private let project: Project
    private let workspaceStore: WorkspaceStore
    private let repoStore: RepoStore
    private let docStore: DocStore

    /// Injectable for tests (capture prompts without a PTY).
    var sendPrompt: (String, TabSession) -> Void = { prompt, session in
        ClaudePromptDriver.send(prompt, into: session)
    }

    init(project: Project, workspaceStore: WorkspaceStore,
         repoStore: RepoStore, docStore: DocStore) {
        self.project = project
        self.workspaceStore = workspaceStore
        self.repoStore = repoStore
        self.docStore = docStore
    }

    /// Run (or resume) `doc` as feature `branchName` across `repoNames`.
    @discardableResult
    func runPlan(_ doc: PlanDoc, branchName: String, repoNames: [String]) async throws -> Workspace {
        guard doc.kind == .plan else { throw PlanRunError.notAPlan }
        let repos = repoStore.repositories.filter { repoNames.contains($0.name) }
        guard !repos.isEmpty else { throw PlanRunError.noRepositories }

        let planPath = docStore.relativePath(of: doc)
        let existing = docStore.ledger.recordForPlan(planPath)
        let isResume = existing?.featureName == branchName
            && workspaceStore.workspaces.contains { $0.name == branchName }

        let featureDir: URL
        if isResume {
            featureDir = FeatureProvisioner.featureDirectory(in: project, name: branchName)
        } else {
            featureDir = try await FeatureProvisioner.provision(
                featureName: branchName, in: project, across: repos)
        }

        let workspace = workspaceStore.registerFeature(
            name: branchName,
            featureDirectory: featureDir,
            linkedRepoIDs: repos.map(\.name))
        docStore.ledger.record(planPath: planPath, featureName: branchName)

        let docsLink = FeatureProvisioner.docsLinkName(repoNames: repos.map(\.name))
        // Inside the feature dir the docs home is reachable via the
        // symlink; rewrite the leading "docs/" when the link is renamed.
        let pathInFeature = docsLink == "docs"
            ? planPath
            : planPath.replacingOccurrences(of: "docs/", with: "\(docsLink)/",
                                            options: .anchored)
        let prompt = isResume
            ? PlanPrompts.resumePlan(planRelativePath: pathInFeature, docsLinkName: docsLink)
            : PlanPrompts.runPlan(planRelativePath: pathInFeature, docsLinkName: docsLink)

        let session = workspaceStore.session(for: workspace)
        if let tab = session.openAgentTab(
            at: featureDir.path,
            title: "plan: \(branchName)",
            icon: "text.badge.checkmark") {
            tab.startIfNeeded()
            sendPrompt(prompt, tab)
        }
        return workspace
    }
}
```

- [x] **Step 5: Run the suite**

Run: `swift test --filter "PlanPromptsTests|PlanRunCoordinatorTests" 2>&1 | tail -5`
Expected: PASS. Then `swift test 2>&1 | tail -3` — full suite green.

- [x] **Step 6: Commit**

```bash
git add Sources/Dreamux/Shell/PlanPrompts.swift Sources/Dreamux/Shell/PlanRunCoordinator.swift Tests/DreamuxTests/PlanPromptsTests.swift Tests/DreamuxTests/PlanRunCoordinatorTests.swift
git commit -m "Add PlanPrompts and PlanRunCoordinator (provision + drive claude)"
```

---

### Task 9: Sidebar section, sheets, and window wiring

**Files:**
- Create: `Sources/Dreamux/Views/PlansSpecsSection.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift`
- Modify: `Sources/Dreamux/Models/SidebarLayoutStore.swift`
- Test: `Tests/DreamuxTests/SidebarLayoutStoreTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the Plans & Specs section above Features; `SidebarLayoutStore.plansExpanded: Bool` (persisted); ContentView owns `DocStore` + `PlanRunCoordinator` and passes `openDoc` (file-tab path) into the sidebar.

- [x] **Step 1: Persisted collapse state (failing test first)**

Append to `Tests/DreamuxTests/SidebarLayoutStoreTests.swift`:

```swift
    @MainActor
    func testPlansExpandedPersists() throws {
        let store = SidebarLayoutStore(project: project)
        XCTAssertTrue(store.plansExpanded, "expanded by default")
        store.plansExpanded = false
        let reloaded = SidebarLayoutStore(project: project)
        XCTAssertFalse(reloaded.plansExpanded)
    }
```

Run: `swift test --filter SidebarLayoutStoreTests 2>&1 | tail -5` — expect FAIL (no member).

In `Sources/Dreamux/Models/SidebarLayoutStore.swift`:
- Add to the class: `var plansExpanded: Bool { didSet { if plansExpanded != oldValue { save() } } }`
- In `Payload`: add `var plansExpanded: Bool?` (optional keeps old files decodable).
- In `init`: `plansExpanded = loaded?.plansExpanded ?? true`.
- In `save()`: include `plansExpanded: plansExpanded` in the `Payload(...)` call.

Run the filter again — expect PASS.

- [x] **Step 2: The section view**

Create `Sources/Dreamux/Views/PlansSpecsSection.swift`:

```swift
import SwiftUI

/// Collapsible "Plans & Specs" sidebar section (rendered above the
/// Features list). Plans carry derived status + checkbox progress;
/// unpaired specs surface as "needs plan"; everything else sits behind
/// a Docs disclosure. Rows open in the workspace's editor tabs.
struct PlansSpecsSection: View {
    @Bindable var docStore: DocStore
    @Bindable var layout: SidebarLayoutStore
    let featureExists: (String) -> Bool
    let onOpenDoc: (URL) -> Void
    let onRunPlan: (PlanDoc) -> Void
    let onNewPlan: () -> Void
    let onWritePlan: (PlanDoc) -> Void

    @State private var doneExpanded = false
    @State private var docsExpanded = false
    @State private var hoveredDocURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if layout.plansExpanded {
                if docStore.plans.isEmpty && docStore.unpairedSpecs.isEmpty
                    && docStore.otherDocs.isEmpty {
                    emptyState
                } else {
                    rows
                }
            }
        }
        .onAppear { docStore.startWatching() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { layout.plansExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(layout.plansExpanded ? 90 : 0))
                    Text("Plans & Specs")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { docStore.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rescan docs")

            Button(action: onNewPlan) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New plan… (opens a planning session)")
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        Text("No specs or plans yet. “＋” starts a planning session that writes them to this project's docs/ folder.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var rows: some View {
        let statuses = Dictionary(uniqueKeysWithValues: docStore.plans.map {
            ($0.fileURL, docStore.status(for: $0, featureExists: featureExists))
        })
        let active = docStore.plans.filter { statuses[$0.fileURL] != .merged }
            .sorted { rank(statuses[$0.fileURL]!) < rank(statuses[$1.fileURL]!) }
        let done = docStore.plans.filter { statuses[$0.fileURL] == .merged }

        VStack(spacing: 2) {
            ForEach(active) { plan in
                planRow(plan, status: statuses[plan.fileURL]!)
            }
            ForEach(docStore.unpairedSpecs) { spec in
                specOnlyRow(spec)
            }
            if !done.isEmpty {
                disclosure("Done (\(done.count))", isExpanded: $doneExpanded) {
                    ForEach(done) { plan in planRow(plan, status: .merged) }
                }
            }
            if !docStore.otherDocs.isEmpty {
                disclosure("Docs (\(docStore.otherDocs.count))", isExpanded: $docsExpanded) {
                    ForEach(docStore.otherDocs) { doc in plainDocRow(doc) }
                }
            }
        }
    }

    /// Sidebar ordering: running → awaiting review → ready/in-progress
    /// (already date-sorted by the store) — merged handled separately.
    private func rank(_ status: PlanStatus) -> Int {
        switch status {
        case .running: return 0
        case .awaitingReview: return 1
        case .ready, .inProgress: return 2
        case .specOnly, .merged: return 3
        }
    }

    private func planRow(_ plan: PlanDoc, status: PlanStatus) -> some View {
        docRow(plan, canRun: status == .ready || status == .inProgress) {
            HStack(spacing: 8) {
                Image(systemName: status.glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status == .running ? Color.green : Color.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(status.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if plan.totalSteps > 0 {
                            ProgressView(value: Double(plan.checkedSteps),
                                         total: Double(plan.totalSteps))
                                .controlSize(.mini)
                                .frame(width: 60)
                            Text("\(plan.checkedSteps)/\(plan.totalSteps)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func specOnlyRow(_ spec: PlanDoc) -> some View {
        docRow(spec, canRun: false) {
            HStack(spacing: 8) {
                Image(systemName: PlanStatus.specOnly.glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    Text("needs plan")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hoveredDocURL == spec.fileURL {
                    Button("Write plan") { onWritePlan(spec) }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func plainDocRow(_ doc: PlanDoc) -> some View {
        docRow(doc, canRun: false) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(doc.title)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    /// Row chrome shared by all three row types: click opens the doc,
    /// hover reveals Run for runnable plans, context menu everywhere.
    private func docRow<Body: View>(
        _ doc: PlanDoc,
        canRun: Bool,
        @ViewBuilder body: () -> Body
    ) -> some View {
        ZStack(alignment: .trailing) {
            Button { onOpenDoc(doc.fileURL) } label: {
                body()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if hoveredDocURL == doc.fileURL {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .padding(.horizontal, 4)
                }
            }
            .contextMenu {
                if canRun { Button("Run Plan…") { onRunPlan(doc) } }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
                }
            }

            if canRun, hoveredDocURL == doc.fileURL {
                Button { onRunPlan(doc) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .help("Run this plan (provisions a worktree and starts claude)")
            }
        }
        .onHover { hovering in
            if hovering { hoveredDocURL = doc.fileURL }
            else if hoveredDocURL == doc.fileURL { hoveredDocURL = nil }
        }
    }

    private func disclosure<C: View>(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title).font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue { content() }
        }
    }
}
```

- [x] **Step 3: Run Plan sheet + New Plan sheet**

Append to `Sources/Dreamux/Views/PlansSpecsSection.swift`:

```swift
// MARK: - Run Plan confirm sheet

/// Confirm-and-configure before executing a plan: branch name (prefilled
/// from the plan filename) and repo selection (all linked by default) —
/// AddFeatureSheet's shape, scoped to a plan.
struct RunPlanSheet: View {
    let plan: PlanDoc
    let availableRepos: [Repository]
    let isResume: Bool
    let onSubmit: (_ branchName: String, _ repoIDs: [String]) -> Void
    let onCancel: () -> Void

    @State private var branchName: String
    @State private var selected: Set<String>

    init(plan: PlanDoc, availableRepos: [Repository], isResume: Bool,
         onSubmit: @escaping (_ branchName: String, _ repoIDs: [String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.plan = plan
        self.availableRepos = availableRepos
        self.isResume = isResume
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _branchName = State(initialValue: PlanDoc.branchName(
            forFileName: plan.fileURL.lastPathComponent))
        _selected = State(initialValue: Set(availableRepos.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isResume ? "Resume Plan" : "Run Plan")
                .font(.title3.weight(.semibold))
            Text(plan.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch / feature name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("branch", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResume)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Repositories")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(availableRepos, id: \.name) { repo in
                    Toggle(repo.name, isOn: Binding(
                        get: { selected.contains(repo.name) },
                        set: { on in
                            if on { selected.insert(repo.name) }
                            else { selected.remove(repo.name) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(isResume)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isResume ? "Resume" : "Run") {
                    onSubmit(branchName.trimmingCharacters(in: .whitespaces),
                             Array(selected))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty
                          || selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - New Plan sheet

/// Collects the idea, then the caller opens the planning terminal with
/// a brainstorming kickoff carrying it.
struct NewPlanSheet: View {
    let onSubmit: (_ idea: String) -> Void
    let onCancel: () -> Void

    @State private var idea = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Plan")
                .font(.title3.weight(.semibold))
            Text("Describe the idea. A claude planning session opens in a project terminal, brainstorms it with you, and writes the spec and plan into this project's docs/ folder — they'll appear in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $idea)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Start Planning") {
                    onSubmit(idea.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [x] **Step 4: Wire into ContentView and WorkspaceSidebar**

In `Sources/Dreamux/Views/ContentView.swift`:

- Add state: `@State private var docStore: DocStore` and `@State private var planRunner: PlanRunCoordinator`.
- In `init`, after `_fileTree = State(...)`:

```swift
        let docStore = DocStore(project: repoStore.project)
        docStore.refresh()
        _docStore = State(initialValue: docStore)
        _planRunner = State(initialValue: PlanRunCoordinator(
            project: repoStore.project,
            workspaceStore: store,
            repoStore: repoStore,
            docStore: docStore))
```

- Pass both into `WorkspaceSidebar(...)`: add `docStore: docStore, planRunner: planRunner, onOpenDoc: openFile,` to the call (and matching properties on the sidebar below). Note `openFile` already exists (`ContentView.swift:239`) and handles the no-active-workspace case poorly (bails) — extend it: replace `guard let workspace = store.activeWorkspace else { return }` with

```swift
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
```

- In `.onAppear`, after `registerRunStores(...)`, add `E2ERegistry.shared.registerDocStores(projectID: repoStore.project.id, docStore: docStore, planRunner: planRunner)` (Task 10 adds that method; for THIS task's compilability, add the call in Task 10 instead — skip it here).

In `Sources/Dreamux/Views/WorkspaceSidebar.swift`:

- Add properties after `@Bindable var layout: SidebarLayoutStore`:

```swift
    @Bindable var docStore: DocStore
    let planRunner: PlanRunCoordinator
    let onOpenDoc: (URL) -> Void
```

- Add state: `@State private var runningPlan: PlanDoc?`, `@State private var showNewPlan = false`.
- In `content`, insert BETWEEN `PinnedTileGrid(...)` and the Features `VStack`:

```swift
            PlansSpecsSection(
                docStore: docStore,
                layout: layout,
                featureExists: { name in store.workspaces.contains { $0.name == name } },
                onOpenDoc: onOpenDoc,
                onRunPlan: { runningPlan = $0 },
                onNewPlan: { showNewPlan = true },
                onWritePlan: { spec in
                    openPlanningSession(
                        prompt: PlanPrompts.writePlanKickoff(
                            specRelativePath: docStore.relativePath(of: spec)))
                }
            )
```

- Add the sheets next to the existing `.sheet` modifiers:

```swift
        .sheet(item: $runningPlan) { plan in
            RunPlanSheet(
                plan: plan,
                availableRepos: repoStore.repositories,
                isResume: docStore.status(
                    for: plan,
                    featureExists: { name in store.workspaces.contains { $0.name == name } }
                ) == .running,
                onSubmit: { branch, repoIDs in
                    runningPlan = nil
                    executePlan(plan, branch: branch, repoIDs: repoIDs)
                },
                onCancel: { runningPlan = nil }
            )
        }
        .sheet(isPresented: $showNewPlan) {
            NewPlanSheet(
                onSubmit: { idea in
                    showNewPlan = false
                    openPlanningSession(prompt: PlanPrompts.brainstormKickoff(idea: idea))
                },
                onCancel: { showNewPlan = false }
            )
        }
```

- Add the actions near `handleCreateFeature`:

```swift
    private func executePlan(_ plan: PlanDoc, branch: String, repoIDs: [String]) {
        isWorking = true
        Task {
            do {
                let workspace = try await planRunner.runPlan(
                    plan, branchName: branch, repoNames: repoIDs)
                sidebarMode = .workspace
                store.activate(workspace.id)
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// One planning terminal per project, cwd at the project root where
    /// `repos/<repo>/<default>/` checkouts and `docs/` are visible.
    /// Reuses the existing tab when it's still open (tracked on the
    /// session — see `planningTabID` below); the kickoff prompt is typed
    /// via the shared driver either way.
    private func openPlanningSession(prompt: String) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        let session = store.session(for: workspace)
        DocStore.ensureDocsHome(at: repoStore.project.rootPath)
        if let tab = session.reuseOrOpenPlanningTab(
            at: repoStore.project.rootPath.path) {
            tab.startIfNeeded()
            ClaudePromptDriver.send(prompt, into: tab)
        }
    }
```

This needs a small session-side helper — add to `Sources/Dreamux/Models/WorkspaceSession.swift` (and stage it in this task's commit):

```swift
    /// Tab id of this session's planning terminal, if one was opened.
    /// Cleared when the tab closes (`handleDidCloseTab`).
    private var planningTabID: TabID?

    /// Re-select the live planning tab, or open a fresh one cwd'd at
    /// `path`. One planning terminal per session keeps kickoffs from
    /// stacking tabs.
    func reuseOrOpenPlanningTab(at path: String) -> TabSession? {
        if let id = planningTabID, let existing = tabSessions[id] {
            controller.selectTab(id)
            return existing
        }
        let tab = openAgentTab(at: path, title: "planning", icon: "lightbulb")
        planningTabID = lastCreatedTabID
        return tab
    }
```

and in `handleDidCloseTab(_ tabId:)` add `if planningTabID == tabId { planningTabID = nil }`.

- Make `PlanDoc` `Identifiable` conformance work with `.sheet(item:)` — it already is (Task 1).
- `PlanDoc` needs `Hashable`? `.sheet(item:)` needs `Identifiable` only. Fine.

- [x] **Step 5: Build, test, and walk the flow**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

Launch the app against a scratch project. Verify: the section renders above Features (collapsible, persisted across relaunch); drop a plan file into `<project>/docs/plans/` from Terminal — it appears within ~1s (watcher); clicking it opens the rendered markdown tab; Run Plan shows the sheet with derived branch name; running provisions the feature, opens a `plan: <name>` terminal tab, and types the claude invocation (with the real CLI or `DREAMUX_CLAUDE_BIN` fake); ticking a checkbox in the file on disk updates the row's progress live; “＋” opens the New Plan sheet and kickoff lands in a `planning` tab.

- [x] **Step 6: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Models/SidebarLayoutStore.swift Tests/DreamuxTests/SidebarLayoutStoreTests.swift
git commit -m "Add Plans & Specs sidebar section with run/new-plan flows"
```

---

### Task 10: E2E — `listDocs`, `runPlan`, and the state dump

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift`
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift`
- Modify: `scripts/e2e/PROTOCOL.md`

**Interfaces:**
- Consumes: `DocStore`, `PlanRunCoordinator`.
- Produces: e2e commands `listDocs` and `runPlan {path, branch?, repos?}`; state dump gains `"plans"`; `E2EProjectHandles` gains `weak var docStore: DocStore?` and `weak var planRunner: PlanRunCoordinator?`.

- [x] **Step 1: Registry**

In `Sources/Dreamux/E2E/E2ERegistry.swift`:
- In `E2EProjectHandles`, after `weak var signals: SignalStore?`:

```swift
    weak var docStore: DocStore?
    weak var planRunner: PlanRunCoordinator?
```

- Add to `E2ERegistry`, mirroring `registerRunStores`:

```swift
    /// Called from ContentView.onAppear alongside the run stores.
    func registerDocStores(
        projectID: UUID,
        docStore: DocStore,
        planRunner: PlanRunCoordinator
    ) {
        guard E2EMode.isActive else { return }
        let handles = handles(forProject: projectID)
        handles.docStore = docStore
        handles.planRunner = planRunner
    }
```

In `Sources/Dreamux/Views/ContentView.swift` `.onAppear`, after `registerRunStores(...)`:

```swift
            E2ERegistry.shared.registerDocStores(
                projectID: repoStore.project.id,
                docStore: docStore,
                planRunner: planRunner
            )
```

- [x] **Step 2: Commands**

In `Sources/Dreamux/E2E/E2ECommands.swift`, add the two cases next to `case "openFile":` (follow the file's existing handler style — each case calls a private method with the request dict):

```swift
        case "listDocs":
            return handleListDocs()
        case "runPlan":
            return await handleRunPlan(request)
```

Add the handlers (adapt the surrounding helpers — the file has an established way to fetch `handles` and produce `["ok": true]` payloads; `state` at line ~100 is the template):

```swift
    /// Fresh scan + one entry per doc: enough for scenarios to assert
    /// classification, pairing, status, and live checkbox progress.
    private func handleListDocs() -> [String: Any] {
        guard let handles = activeHandles(),
              let docStore = handles.docStore,
              let workspaceStore = handles.workspaceStore else {
            return ["ok": false, "error": "no doc store registered"]
        }
        docStore.refresh()
        let featureExists: (String) -> Bool = { name in
            workspaceStore.workspaces.contains { $0.name == name }
        }
        let entries = docStore.docs.map { doc -> [String: Any] in
            var entry: [String: Any] = [
                "path": docStore.relativePath(of: doc),
                "kind": doc.kind.rawValue,
                "title": doc.title,
                "checkedSteps": doc.checkedSteps,
                "totalSteps": doc.totalSteps,
            ]
            entry["status"] = docStore.status(for: doc, featureExists: featureExists).rawValue
            if let spec = doc.kind == .plan
                ? docStore.pairedSpec(for: doc).map({ docStore.relativePath(of: $0) })
                : nil {
                entry["spec"] = spec
            }
            return entry
        }
        return ["ok": true, "docs": entries]
    }

    /// Execute a plan headlessly through the same coordinator the
    /// sidebar uses. `branch` defaults to the filename derivation,
    /// `repos` to every repo in the project.
    private func handleRunPlan(_ request: [String: Any]) async -> [String: Any] {
        guard let handles = activeHandles(),
              let docStore = handles.docStore,
              let planRunner = handles.planRunner,
              let repoStore = handles.repoStore else {
            return ["ok": false, "error": "no plan runner registered"]
        }
        guard let path = request["path"] as? String else {
            return ["ok": false, "error": "missing 'path'"]
        }
        docStore.refresh()
        guard let doc = docStore.docs.first(where: { docStore.relativePath(of: $0) == path })
        else { return ["ok": false, "error": "no doc at \(path)"] }

        let branch = (request["branch"] as? String)
            ?? PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent)
        let repos = (request["repos"] as? [String])
            ?? repoStore.repositories.map(\.name)
        do {
            let workspace = try await planRunner.runPlan(
                doc, branchName: branch, repoNames: repos)
            return ["ok": true, "feature": workspace.name]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
```

(If the file has no `activeHandles()` helper, inline the same lookup the `state` handler uses: `E2ERegistry.shared.activeProjectID` → `handlesByProject[id]`.)

Also add plan facts to the `state` dump next to `payload["runners"]`:

```swift
        if let docStore = handles.docStore, let workspaceStore = handles.workspaceStore {
            let featureExists: (String) -> Bool = { name in
                workspaceStore.workspaces.contains { $0.name == name }
            }
            payload["plans"] = docStore.plans.map { plan -> [String: Any] in
                [
                    "path": docStore.relativePath(of: plan),
                    "status": docStore.status(for: plan, featureExists: featureExists).rawValue,
                    "checkedSteps": plan.checkedSteps,
                    "totalSteps": plan.totalSteps,
                ]
            }
        } else {
            payload["plans"] = [Any]()
        }
```

- [x] **Step 3: PROTOCOL.md**

In `scripts/e2e/PROTOCOL.md`, add to the command list (matching the doc's existing per-command format):

```markdown
### `listDocs`

Rescan the project docs home (`<project>/docs/`) and return every
markdown doc: `{"ok": true, "docs": [{"path", "kind": "plan|spec|doc",
"title", "status": "specOnly|ready|inProgress|running|awaitingReview|merged",
"checkedSteps", "totalSteps", "spec"?}]}`. `status` is derived (ledger +
checkboxes + feature existence); only plans have meaningful statuses.

### `runPlan`

`{"cmd": "runPlan", "path": "docs/plans/2026-07-02-x.md", "branch"?:
"x", "repos"?: ["api"]}` — executes the plan through the same
coordinator as the sidebar: provisions the feature worktrees (branch
defaults to the filename minus its date prefix; repos default to all),
records the run ledger entry, opens a `plan: <branch>` terminal tab,
and types the claude invocation (`DREAMUX_CLAUDE_BIN` substitutes the
fake). Replies `{"ok": true, "feature": "<branch>"}`.
```

And document the `state` payload's new `plans` array alongside the `workspaces`/`runners` field docs.

- [x] **Step 4: Build + full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/E2E/E2ERegistry.swift Sources/Dreamux/E2E/E2ECommands.swift Sources/Dreamux/Views/ContentView.swift scripts/e2e/PROTOCOL.md
git commit -m "Expose docs + plan execution to the e2e automation server"
```

---

## Final verification

- `swift build && swift test` — clean.
- Manual walk from Task 9 Step 5 on a scratch project, including a full run of a toy plan with `DREAMUX_CLAUDE_BIN` pointed at `Tests/Fixtures/bin/claude`.
- `git log --oneline` — one commit per task.
