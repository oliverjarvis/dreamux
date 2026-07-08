import XCTest
@testable import Dreamux

final class PlanDocTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    /// Parse one of the repo's own git-tracked docs, anchoring on
    /// `#filePath` the way `RepoFixtures` does (tests always run from a
    /// checkout, so the relative walk to the repo root is stable).
    private func repoDoc(_ relativePath: String) throws -> PlanDoc {
        let url = URL(fileURLWithPath: #filePath)   // .../Tests/DreamuxTests/PlanDocTests.swift
            .deletingLastPathComponent()            // .../Tests/DreamuxTests
            .deletingLastPathComponent()            // .../Tests
            .deletingLastPathComponent()            // .../<repo root>
            .appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return PlanDoc.parse(fileURL: url, contents: contents)
    }

    /// `checkedSteps`/`totalSteps` stay authoritative — they must equal
    /// the sums over the parsed per-task steps.
    private func assertCountsMatchSteps(
        _ d: PlanDoc, file: StaticString = #filePath, line: UInt = #line
    ) {
        let checked = d.tasks.reduce(0) { $0 + $1.steps.lazy.filter(\.checked).count }
        let total = d.tasks.reduce(0) { $0 + $1.steps.count }
        XCTAssertEqual(checked, d.checkedSteps, file: file, line: line)
        XCTAssertEqual(total, d.totalSteps, file: file, line: line)
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

    /// A flat-tasks plan writes its tasks at H2 (`## Task N:`) with no phase
    /// level. The parser must still break them into tasks rather than
    /// collapse every checkbox into one untitled "Steps" bucket, and those
    /// tasks are ungrouped (never filed under a preceding generic section).
    func testH2TaskHeadingsParseAsUngroupedTasks() {
        let d = doc("2026-07-04-readme.md", """
        # README Generator — Implementation Plan

        ## Global Constraints

        - **Deterministic:** a bullet, not a checkbox.

        ## Task 1: Scaffold

        - [x] Step one
        - [ ] Step two

        ## Task 2: Data sections

        - [ ] Step three
        """)
        XCTAssertEqual(d.tasks.count, 2)
        XCTAssertEqual(d.tasks[0].title, "Task 1: Scaffold")
        XCTAssertEqual(d.tasks[1].title, "Task 2: Data sections")
        // Ungrouped — not filed under the preceding "Global Constraints".
        XCTAssertNil(d.tasks[0].phase)
        XCTAssertNil(d.tasks[1].phase)
        XCTAssertEqual(d.tasks[0].steps.count, 2)
        XCTAssertEqual(d.tasks[1].steps.count, 1)
        XCTAssertEqual(d.totalSteps, 3)
        XCTAssertEqual(d.checkedSteps, 1)
        assertCountsMatchSteps(d)
    }

    /// `**Spec:**` lines often carry a trailing qualifier; resolving the
    /// whole string as a path silently breaks backlink pairing, so only
    /// the `.md` token survives.
    func testSpecReferenceDropsTrailingQualifiers() {
        let paren = doc("2026-07-02-x.md", """
        # X Plan
        **Spec:** docs/specs/x-design.md (§6 Queue)
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(paren.specReference, "docs/specs/x-design.md")

        let section = doc("2026-07-02-y.md", """
        # Y Plan
        **Spec:** docs/specs/y-design.md (section "Features retirement")
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(section.specReference, "docs/specs/y-design.md")
    }

    // MARK: - `**Runs:**` header parse

    /// `after <path>` carries the blocker's raw relative path; trailing
    /// prose/qualifiers are stripped by the same `.md` token discipline as
    /// `**Spec:**`, so the path token survives.
    func testRunsAfterExtractsPathThroughTrailingProse() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Runs:** after docs/superpowers/plans/2026-07-02-queue.md — blocks on the queue rework
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(d.runsAfter, "docs/superpowers/plans/2026-07-02-queue.md")
    }

    /// A parenthetical qualifier after the path is dropped the same way
    /// `**Spec:**` handles `(§6 Queue)`.
    func testRunsAfterDropsParentheticalQualifier() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Runs:** after docs/plans/queue.md (§6 Queue)
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(d.runsAfter, "docs/plans/queue.md")
    }

    /// A backticked path is unwrapped, mirroring `**Spec:**`.
    func testRunsAfterStripsBackticksAroundPath() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Runs:** after `docs/plans/queue.md`
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(d.runsAfter, "docs/plans/queue.md")
    }

    /// `**Runs:** parallel` is an explicit disposition, not a blocker — nil.
    func testRunsAfterParallelIsNil() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Runs:** parallel
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(d.runsAfter)
    }

    /// No `**Runs:**` header at all → nil (today's plans).
    func testRunsAfterAbsentIsNil() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Spec:** docs/specs/x-design.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(d.runsAfter)
    }

    /// A value that neither leads with `after` nor names a path is
    /// malformed and yields nil, never a crash.
    func testRunsAfterMalformedValuesAreNil() {
        let whenever = doc("2026-07-04-a.md", """
        # A Implementation Plan
        **Runs:** whenever
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(whenever.runsAfter)

        // `after` with no path is not a blocker reference.
        let bare = doc("2026-07-04-b.md", """
        # B Implementation Plan
        **Runs:** after
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(bare.runsAfter)

        // The `after` prefix must be a whole word — `afternoon` is not it.
        let afternoon = doc("2026-07-04-c.md", """
        # C Implementation Plan
        **Runs:** afternoon docs/plans/queue.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(afternoon.runsAfter)
    }

    /// The fence guard that hides heading/checkbox lines must also hide a
    /// `**Runs:**` line inside a code fence — a documented example is not
    /// a live header.
    func testRunsAfterInsideCodeFenceIsIgnored() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan

        ```md
        **Runs:** after docs/plans/queue.md
        ```

        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertNil(d.runsAfter)
    }

    // MARK: - `**Runs:** parallel` disposition (declaresParallel)

    /// `**Runs:** parallel` sets `declaresParallel` (and leaves `runsAfter`
    /// nil) — the explicit header the auto-run toggle keys off, distinct from
    /// no header at all.
    func testDeclaresParallelOnExplicitHeader() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan
        **Runs:** parallel
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertTrue(d.declaresParallel)
        XCTAssertNil(d.runsAfter)
    }

    /// A trailing note after `parallel` is tolerated (same word discipline as
    /// `after`); `parallelism` is NOT the disposition.
    func testDeclaresParallelWordDiscipline() {
        let note = doc("2026-07-04-a.md", """
        # A Implementation Plan
        **Runs:** parallel — own worktree, ready now
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertTrue(note.declaresParallel)

        let ism = doc("2026-07-04-b.md", """
        # B Implementation Plan
        **Runs:** parallelism study
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertFalse(ism.declaresParallel)
    }

    /// An `after` header, an absent header, and a malformed value all leave
    /// `declaresParallel` false — only the explicit `parallel` word sets it.
    func testDeclaresParallelFalseForAfterAbsentAndMalformed() {
        let after = doc("2026-07-04-a.md", """
        # A Implementation Plan
        **Runs:** after docs/plans/queue.md
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertFalse(after.declaresParallel)

        let absent = doc("2026-07-04-b.md", """
        # B Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertFalse(absent.declaresParallel)

        let malformed = doc("2026-07-04-c.md", """
        # C Implementation Plan
        **Runs:** whenever
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertFalse(malformed.declaresParallel)
    }

    /// The fence guard hides a `**Runs:** parallel` line inside a code fence
    /// — a documented example is not a live header (mirrors `runsAfter`).
    func testDeclaresParallelInsideCodeFenceIsIgnored() {
        let d = doc("2026-07-04-x.md", """
        # X Implementation Plan

        ```md
        **Runs:** parallel
        ```

        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertFalse(d.declaresParallel)
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

    // MARK: - Task-level parse

    func testMultiTaskParseWithMixedCheckedStates() {
        let d = doc("2026-07-02-widgets.md", """
        # Widgets Implementation Plan

        ### Task 1: Build the base
        - [x] **Step 1: Write the failing test**
        - [x] **Step 2: Implement**

        ### Task 2: Polish
        - [ ] **Step 1: Refine**
        - [x] **Step 2: Ship**
        - [ ] **Step 3: Celebrate**
        """)
        XCTAssertEqual(d.tasks.count, 2)
        XCTAssertEqual(d.tasks[0].title, "Task 1: Build the base")
        XCTAssertEqual(d.tasks[0].steps, [
            PlanStep(title: "Write the failing test", checked: true),
            PlanStep(title: "Implement", checked: true),
        ])
        XCTAssertEqual(d.tasks[1].title, "Task 2: Polish")
        XCTAssertEqual(d.tasks[1].steps, [
            PlanStep(title: "Refine", checked: false),
            PlanStep(title: "Ship", checked: true),
            PlanStep(title: "Celebrate", checked: false),
        ])
        XCTAssertEqual(d.checkedSteps, 3)
        XCTAssertEqual(d.totalSteps, 5)
        assertCountsMatchSteps(d)
    }

    func testStepDecorationStrippedToReadableTitle() {
        // A short bold label followed by prose keeps the prose; the
        // `**Step k:` numbering and bold markers fall away.
        let d = doc("p.md", """
        # X Implementation Plan
        ### Task 1: T
        - [ ] **Step 1: Model.** In `Foo.swift`, add a struct.
        - [x] plain item without decoration
        """)
        XCTAssertEqual(d.tasks[0].steps, [
            PlanStep(title: "Model. In `Foo.swift`, add a struct.", checked: false),
            PlanStep(title: "plain item without decoration", checked: true),
        ])
    }

    func testStepsBeforeFirstHeadingLandInSyntheticUntitledTask() {
        let d = doc("p.md", """
        # X Implementation Plan
        - [x] **Step 1: preamble task**
        - [ ] loose item

        ### Task 1: Real work
        - [ ] **Step 1: do it**
        """)
        XCTAssertEqual(d.tasks.count, 2)
        XCTAssertEqual(d.tasks[0].title, "")   // synthetic untitled bucket
        XCTAssertEqual(d.tasks[0].steps, [
            PlanStep(title: "preamble task", checked: true),
            PlanStep(title: "loose item", checked: false),
        ])
        XCTAssertEqual(d.tasks[1].title, "Task 1: Real work")
        XCTAssertEqual(d.tasks[1].steps, [PlanStep(title: "do it", checked: false)])
        XCTAssertEqual(d.checkedSteps, 1)
        XCTAssertEqual(d.totalSteps, 3)
        assertCountsMatchSteps(d)
    }

    func testEmDashTaskHeadingOpensTask() {
        let d = doc("p.md", """
        # X Implementation Plan
        ### Task 1 — First
        - [x] **Step 1: a**
        ### Task 2 — Second
        - [ ] b
        """)
        XCTAssertEqual(d.tasks.map(\.title), ["Task 1 — First", "Task 2 — Second"])
        XCTAssertEqual(d.tasks[0].steps, [PlanStep(title: "a", checked: true)])
        XCTAssertEqual(d.tasks[1].steps, [PlanStep(title: "b", checked: false)])
        assertCountsMatchSteps(d)
    }

    func testBareHeadingOpensTaskOnlyAfterFirstTaskHeading() {
        let d = doc("p.md", """
        # X Implementation Plan

        ### Preamble
        - [ ] not a task step — before any Task heading

        ### Task 1: Real
        - [x] **Step 1: a**

        ### Wrap up
        - [ ] final
        """)
        // The `### Preamble` heading precedes the first Task heading, so
        // it does not open a task; its checkbox lands in the synthetic
        // untitled bucket. `### Wrap up` follows a Task heading, so it does.
        XCTAssertEqual(d.tasks.map(\.title), ["", "Task 1: Real", "Wrap up"])
        XCTAssertEqual(d.tasks[0].steps,
                       [PlanStep(title: "not a task step — before any Task heading", checked: false)])
        XCTAssertEqual(d.tasks[1].steps, [PlanStep(title: "a", checked: true)])
        XCTAssertEqual(d.tasks[2].steps, [PlanStep(title: "final", checked: false)])
        assertCountsMatchSteps(d)
    }

    func testNestedIndentedCheckboxesAppendToOpenTask() {
        let d = doc("p.md", """
        # X Implementation Plan
        ### Task 1: Nested
        - [x] **Step 1: parent**
            - [ ] child a
            - [x] child b
        """)
        XCTAssertEqual(d.tasks.count, 1)
        XCTAssertEqual(d.tasks[0].steps, [
            PlanStep(title: "parent", checked: true),
            PlanStep(title: "child a", checked: false),
            PlanStep(title: "child b", checked: true),
        ])
        XCTAssertEqual(d.checkedSteps, 2)
        XCTAssertEqual(d.totalSteps, 3)
        assertCountsMatchSteps(d)
    }

    func testNoTaskPlanHasEmptyTasksButRightCounts() {
        let d = doc("2026-07-02-empty.md", """
        # Empty Implementation Plan

        **Goal:** Nothing checkable yet.

        Just prose — no task headings and no checkboxes.
        """)
        XCTAssertTrue(d.tasks.isEmpty)
        XCTAssertEqual(d.checkedSteps, 0)
        XCTAssertEqual(d.totalSteps, 0)
        assertCountsMatchSteps(d)
    }

    func testRepoUniversalFileViewersPlanParsesTasks() throws {
        let d = try repoDoc("docs/superpowers/plans/2026-07-02-universal-file-viewers.md")
        XCTAssertEqual(d.kind, .plan)
        XCTAssertGreaterThan(d.tasks.count, 3)
        // Every parsed step belongs to some task; the counters agree.
        assertCountsMatchSteps(d)
        XCTAssertGreaterThan(d.totalSteps, 0)
    }

    /// The single-file phased shape claude produces in the wild: `## Phase
    /// N — …` sections with dotted `### Task N.M:` headings. Dotted
    /// numbering must open tasks (integer-only matching dumped all 211
    /// steps of a real plan into the untitled bucket), and each task must
    /// record its section.
    func testSingleFilePhasedPlanParsesDottedTasksAndPhases() {
        let d = doc("2026-07-04-snip.md", """
        # Snip Implementation Plan

        ## Global Constraints

        No checkboxes here.

        ## Phase 0 — Scaffold (Milestone 1)

        ### Task 0.1: Project scaffold
        - [x] **Step 1: init**
        - [ ] **Step 2: tooling**

        ### Task 0.2: Vector math
        - [ ] **Step 1: segments**

        ## Phase 1 — Core mechanic (Milestone 2)

        ### Task 1.1: Event bus
        - [ ] **Step 1: types**
        """)
        XCTAssertEqual(d.kind, .plan)
        XCTAssertEqual(d.tasks.map(\.title),
                       ["Task 0.1: Project scaffold", "Task 0.2: Vector math", "Task 1.1: Event bus"])
        XCTAssertEqual(d.tasks.map(\.phase),
                       ["Phase 0 — Scaffold (Milestone 1)",
                        "Phase 0 — Scaffold (Milestone 1)",
                        "Phase 1 — Core mechanic (Milestone 2)"])
        XCTAssertEqual(d.checkedSteps, 1)
        XCTAssertEqual(d.totalSteps, 4)
        assertCountsMatchSteps(d)
    }

    /// Plans are fence-heavy (a real one carries 181 ``` blocks) and
    /// fenced examples routinely contain heading- and checkbox-shaped
    /// lines — none of them may count or open phases/tasks.
    func testFencedCodeBlocksAreInvisibleToTheParser() {
        let d = doc("2026-07-04-fenced.md", """
        # Fenced Implementation Plan

        ## Phase 0 — Real

        ### Task 0.1: real work
        - [ ] **Step 1: real step**

        ```md
        ## Phase 99 — phantom
        ### Task 99.1: phantom
        - [ ] phantom step
        - [x] phantom step
        ```

        - [x] **Step 2: also real, after the fence**
        """)
        XCTAssertEqual(d.tasks.map(\.title), ["Task 0.1: real work"])
        XCTAssertEqual(d.tasks.map(\.phase), ["Phase 0 — Real"])
        XCTAssertEqual(d.totalSteps, 2)
        XCTAssertEqual(d.checkedSteps, 1)
        assertCountsMatchSteps(d)
    }

    func testUnsectionedPlanTasksCarryNilPhase() {
        let d = doc("2026-07-02-flat.md", """
        # Flat Implementation Plan
        ### Task 1: a
        - [ ] **Step 1: t**
        """)
        XCTAssertEqual(d.tasks.map(\.phase), [nil])
    }

    /// Heading lines are the jump-to-section targets — 1-based, pointing
    /// at the `### Task` and `## Phase` lines respectively.
    func testTasksRecordHeadingAndPhaseLines() {
        let d = doc("2026-07-04-lines.md", """
        # Lines Implementation Plan

        ## Phase 0 — Real

        ### Task 0.1: first
        - [ ] **Step 1: a**

        ### Task 0.2: second
        - [ ] **Step 1: b**
        """)
        XCTAssertEqual(d.tasks.map(\.line), [5, 8])
        XCTAssertEqual(d.tasks.map(\.phaseLine), [3, 3])
    }
}
