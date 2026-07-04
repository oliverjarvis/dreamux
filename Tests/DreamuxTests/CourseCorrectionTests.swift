import XCTest
@testable import Dreamux

@MainActor
final class CourseCorrectionTests: XCTestCase {
    private var sandbox: TestSandbox!
    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func doc(_ contents: String, name: String = "2026-07-04-p.md") -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    // A three-phase dotted plan. The first phase still has an unchecked
    // step, so it is the "current" phase for a nil anchor.
    private let threePhase = """
    # Sample Implementation Plan

    ## Phase 0 — Setup

    ### Task 0.1: First
    - [ ] **Step 1: a**

    ### Task 0.2: Second
    - [x] **Step 1: b**

    ## Phase 1 — Core

    ### Task 1.1: Third
    - [ ] **Step 1: c**

    ## Phase 2 — Wrap

    ### Task 2.1: Fourth
    - [ ] **Step 1: d**
    """

    // MARK: - Insertion-point table

    /// A task-line anchor mid-document lands the fix-task at the end of its
    /// own phase's task block, before the next `## ` heading.
    func testAnchorMidPhaseInsertsAtEndOfThatPhase() {
        let d = doc(threePhase)
        // Task 0.1 heading is line 5; its phase (Phase 0) ends its task
        // block at line 9 (`- [x] **Step 1: b**`), so insertion is line 10.
        let ins = CourseCorrection.insertion(
            in: d, contents: threePhase, anchor: .task(line: 5),
            summary: "s", body: "b", date: "2026-07-04")
        XCTAssertEqual(ins.line, 10)
        XCTAssertTrue(ins.text.contains("### Task 0.3: Fix — s"))
    }

    /// An anchor in the last phase lands the fix-task at end of document.
    func testAnchorLastPhaseInsertsAtEndOfDocument() {
        let d = doc(threePhase)
        // Task 2.1 heading is line 18; the doc is 19 lines, so the fix-task
        // appends after the final line → insertion line 20.
        let ins = CourseCorrection.insertion(
            in: d, contents: threePhase, anchor: .task(line: 18),
            summary: "s", body: "b", date: "2026-07-04")
        XCTAssertEqual(ins.line, 20)
        XCTAssertTrue(ins.text.contains("### Task 2.2: Fix — s"))
    }

    /// A nil anchor resolves to the phase holding the current task — the
    /// first task with an unchecked step.
    func testNilAnchorResolvesToCurrentPhase() {
        // Phase 0 fully checked here, so the first unchecked step is in
        // Phase 1 (Task 1.1) — the current phase.
        let contents = """
        # Sample Implementation Plan

        ## Phase 0 — Setup

        ### Task 0.1: First
        - [x] **Step 1: a**

        ## Phase 1 — Core

        ### Task 1.1: Third
        - [ ] **Step 1: c**

        ## Phase 2 — Wrap

        ### Task 2.1: Fourth
        - [ ] **Step 1: d**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .currentPhase,
            summary: "s", body: "b", date: "2026-07-04")
        // Phase 1's block ends at line 11 (`- [ ] **Step 1: c**`); the next
        // `## ` is line 13, so insertion is line 12.
        XCTAssertEqual(ins.line, 12)
        XCTAssertTrue(ins.text.contains("### Task 1.2: Fix — s"))
    }

    /// An unsectioned plan has no `## ` headings: the fix-task appends at
    /// end of document.
    func testUnsectionedPlanInsertsAtEndOfDocument() {
        let contents = """
        # Flat Implementation Plan

        ### Task 1: a
        - [ ] **Step 1: t**

        ### Task 2: b
        - [ ] **Step 1: u**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .task(line: 3),
            summary: "s", body: "b", date: "2026-07-04")
        XCTAssertEqual(ins.line, 8)   // 7 lines → append at line 8
        XCTAssertTrue(ins.text.contains("### Task 3: Fix — s"))
    }

    /// A phase-name anchor resolves to that phase's task block.
    func testPhaseNameAnchorInsertsInNamedPhase() {
        let d = doc(threePhase)
        let ins = CourseCorrection.insertion(
            in: d, contents: threePhase, anchor: .phase(name: "Phase 1 — Core"),
            summary: "s", body: "b", date: "2026-07-04")
        // Phase 1's block ends at line 14 (`- [ ] **Step 1: c**`); the next
        // `## ` is line 16, so insertion is line 15.
        XCTAssertEqual(ins.line, 15)
        XCTAssertTrue(ins.text.contains("### Task 1.2: Fix — s"))
    }

    // MARK: - Numbering

    /// Dotted numbering increments the minor within the anchor phase:
    /// `Task 1.9` → `Task 1.10` (not `Task 1.1` or `Task 2`).
    func testDottedNumberingIncrementsMinor() {
        let contents = """
        # P Implementation Plan

        ## Phase 1 — X

        ### Task 1.9: nine
        - [ ] **Step 1: a**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .phase(name: "Phase 1 — X"),
            summary: "s", body: "b", date: "2026-07-04")
        XCTAssertTrue(ins.text.contains("### Task 1.10: Fix — s"),
                      "expected Task 1.10, got:\n\(ins.text)")
    }

    /// Integer numbering takes max+1 across the plan: after `Task 7` comes
    /// `Task 8: Fix`.
    func testIntegerNumberingTakesMaxPlusOne() {
        let contents = """
        # P Implementation Plan

        ### Task 7: seven
        - [ ] **Step 1: a**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .task(line: 3),
            summary: "s", body: "b", date: "2026-07-04")
        XCTAssertTrue(ins.text.contains("### Task 8: Fix — s"),
                      "expected Task 8, got:\n\(ins.text)")
    }

    /// Multi-line body text collapses to a single step title.
    func testMultiLineBodyCollapsesToOneStep() {
        let contents = """
        # P Implementation Plan

        ### Task 1: a
        - [ ] **Step 1: t**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .task(line: 3),
            summary: "s", body: "the rope\n  drops   the candy\nbut isn't severed",
            date: "2026-07-04")
        XCTAssertTrue(
            ins.text.contains("- [ ] **Step 1: the rope drops the candy but isn't severed**"),
            "body not collapsed:\n\(ins.text)")
    }

    // MARK: - Round-trip against the parser

    /// Apply to a real file, re-parse, and confirm the fix-task is a real
    /// task under the right phase, the counts grew by one, and the title
    /// carries the course-correction suffix.
    func testApplyRoundTripsThroughParser() throws {
        let url = sandbox.root.appendingPathComponent("2026-07-04-p.md")
        try threePhase.write(to: url, atomically: true, encoding: .utf8)
        let before = PlanDoc.parse(fileURL: url, contents: threePhase)

        try CourseCorrection.apply(
            to: url, anchor: .task(line: 5),
            summary: "rope not severed", body: "the candy drops but the rope stays whole",
            date: "2026-07-04")

        let after = PlanDoc.parse(
            fileURL: url, contents: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(after.tasks.count, before.tasks.count + 1)
        XCTAssertEqual(after.totalSteps, before.totalSteps + 1)
        let fix = try XCTUnwrap(after.tasks.first { $0.title.contains("Fix — rope not severed") })
        XCTAssertEqual(fix.title,
                       "Task 0.3: Fix — rope not severed *(course correction, 2026-07-04)*")
        XCTAssertEqual(fix.phase, "Phase 0 — Setup")
        XCTAssertEqual(fix.steps,
                       [PlanStep(title: "the candy drops but the rope stays whole", checked: false)])
    }

    // MARK: - Fence safety

    /// A phase whose task block ends with a fenced code example must not
    /// receive the insertion inside the fence: the insertion line is
    /// computed from fence-aware parsed positions, so the phantom
    /// headings inside the fence are invisible.
    func testInsertionNeverLandsInsideAFence() throws {
        let contents = """
        # Fenced Implementation Plan

        ## Phase 0 — Real

        ### Task 0.1: real
        - [ ] **Step 1: a**

        ```md
        ## Phase 99 — phantom
        ### Task 99.1: phantom
        - [ ] phantom
        ```

        ## Phase 1 — Next

        ### Task 1.1: b
        - [ ] **Step 1: c**
        """
        let d = doc(contents)
        let ins = CourseCorrection.insertion(
            in: d, contents: contents, anchor: .task(line: 5),
            summary: "s", body: "b", date: "2026-07-04")
        // The fence spans lines 8–12; insertion must be at line 13, just
        // after the closing ``` and before `## Phase 1`.
        XCTAssertEqual(ins.line, 13)
        XCTAssertTrue(ins.text.contains("### Task 0.2: Fix — s"))

        // Prove it on disk: apply, re-parse, and confirm the phantom task
        // inside the fence still isn't counted and the fix-task is real
        // under Phase 0.
        let url = sandbox.root.appendingPathComponent("2026-07-04-fenced.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let before = PlanDoc.parse(fileURL: url, contents: contents)
        try CourseCorrection.apply(
            to: url, anchor: .task(line: 5), summary: "s", body: "b", date: "2026-07-04")
        let after = PlanDoc.parse(
            fileURL: url, contents: try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(after.totalSteps, before.totalSteps + 1)
        XCTAssertFalse(after.tasks.contains { $0.title.contains("phantom") },
                       "fence was breached — phantom task became real")
        let fix = try XCTUnwrap(after.tasks.first { $0.title.contains("Fix — s") })
        XCTAssertEqual(fix.phase, "Phase 0 — Real")
    }
}
