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
}
