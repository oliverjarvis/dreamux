import XCTest
@testable import Dreamux

/// Parameter resolution for the e2e `courseCorrect` command is pure over
/// `[PlanDoc]` + a `relativePath` lookup, so it is table-tested directly
/// (mirroring `E2EStateDumpTests`) rather than through the socket server.
/// Cases cover the four failure modes the command promises — unknown
/// plan, ambiguous task, empty text, bad priority — plus the anchor
/// mapping (exact title, unique substring, phase, absent → current phase)
/// and the priority token mapping.
final class CourseCorrectCommandTests: XCTestCase {
    /// Strips the `/proj/` root the same way the live command's
    /// `docStore.relativePath` does.
    private let relativePath: (PlanDoc) -> String = {
        $0.fileURL.path.replacingOccurrences(of: "/proj/", with: "")
    }

    private let planPath = "docs/plans/2026-07-04-widget.md"

    /// A phased plan: two `## Phase` sections, distinct task titles, and a
    /// pair of tasks sharing the substring "Fix" to drive the ambiguity case.
    private func widget() -> PlanDoc {
        PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/\(planPath)"),
            contents: """
            # Widget Implementation Plan

            ## Phase A

            ### Task 1: Model layer
            - [x] **Step 1: A.** done
            - [ ] **Step 2: B.** todo

            ### Task 2: Fix the model cache
            - [ ] **Step 1: c.** todo

            ## Phase B

            ### Task 3: Fix the render loop
            - [ ] **Step 1: d.** todo
            """)
    }

    private func resolve(
        plan: String? = "docs/plans/2026-07-04-widget.md",
        task: String? = nil,
        phase: String? = nil,
        text: String? = "the cache key is wrong",
        priority: String? = "next",
        plans: [PlanDoc]? = nil
    ) throws -> CourseCorrectCommand.Resolved {
        try CourseCorrectCommand.resolve(
            plans: plans ?? [widget()],
            relativePath: relativePath,
            plan: plan, task: task, phase: phase, text: text, priority: priority)
    }

    private func expectError(
        _ needle: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> CourseCorrectCommand.Resolved
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let message = (error as? CourseCorrectCommand.ResolveError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains(needle),
                          "expected error containing \"\(needle)\", got \"\(message)\"",
                          file: file, line: line)
        }
    }

    // MARK: - Plan lookup

    func testUnknownPlanErrors() {
        expectError("no plan at") { try resolve(plan: "docs/plans/nope.md") }
    }

    func testMissingPlanErrors() {
        expectError("plan") { try resolve(plan: nil) }
    }

    // MARK: - Priority mapping

    func testPriorityTokensMapToCases() throws {
        XCTAssertEqual(try resolve(priority: "now").priority, .now)
        XCTAssertEqual(try resolve(priority: "next").priority, .next)
        XCTAssertEqual(try resolve(priority: "queue").priority, .queue)
    }

    func testUnknownPriorityErrors() {
        expectError("priority") { try resolve(priority: "later") }
    }

    func testMissingPriorityErrors() {
        expectError("priority") { try resolve(priority: nil) }
    }

    // MARK: - Text

    func testEmptyTextErrors() {
        expectError("text") { try resolve(text: "") }
    }

    func testWhitespaceOnlyTextErrors() {
        expectError("text") { try resolve(text: "  \n\t ") }
    }

    func testMissingTextErrors() {
        expectError("text") { try resolve(text: nil) }
    }

    func testTextIsReturnedVerbatim() throws {
        let resolved = try resolve(text: "line one\nline two")
        XCTAssertEqual(resolved.text, "line one\nline two")
    }

    // MARK: - Anchor mapping

    func testAbsentTaskAndPhaseResolvesToCurrentPhase() throws {
        XCTAssertEqual(try resolve().anchor, .currentPhase)
    }

    func testExactTitleResolvesToTaskLine() throws {
        // "### Task 1: Model layer" sits on line 5 (1-based).
        let expectedLine = try XCTUnwrap(
            widget().tasks.first { $0.title == "Task 1: Model layer" }?.line)
        XCTAssertEqual(try resolve(task: "Task 1: Model layer").anchor, .task(line: expectedLine))
    }

    func testUniqueSubstringResolvesToTaskLine() throws {
        let expectedLine = try XCTUnwrap(
            widget().tasks.first { $0.title == "Task 1: Model layer" }?.line)
        XCTAssertEqual(try resolve(task: "Model layer").anchor, .task(line: expectedLine))
    }

    func testAmbiguousSubstringErrors() {
        // "Fix" is in both "Task 2: Fix the model cache" and "Task 3: Fix the
        // render loop".
        expectError("ambiguous") { try resolve(task: "Fix") }
    }

    func testUnknownTaskErrors() {
        expectError("no task matching") { try resolve(task: "nonexistent task") }
    }

    func testExactTitleWinsOverSubstringCollision() throws {
        // A query that is BOTH an exact title of one task and a substring of
        // another resolves to the exact match, not an ambiguity error.
        let plan = PlanDoc.parse(
            fileURL: URL(fileURLWithPath: "/proj/\(planPath)"),
            contents: """
            # P

            ### Task 1: Cache
            - [ ] a

            ### Task 2: Cache eviction
            - [ ] b
            """)
        let expectedLine = try XCTUnwrap(plan.tasks.first { $0.title == "Task 1: Cache" }?.line)
        XCTAssertEqual(
            try resolve(task: "Task 1: Cache", plans: [plan]).anchor, .task(line: expectedLine))
    }

    func testPhaseResolvesToPhaseAnchor() throws {
        XCTAssertEqual(try resolve(phase: "Phase B").anchor, .phase(name: "Phase B"))
    }

    func testTaskWinsWhenBothTaskAndPhasePresent() throws {
        let expectedLine = try XCTUnwrap(
            widget().tasks.first { $0.title == "Task 1: Model layer" }?.line)
        XCTAssertEqual(
            try resolve(task: "Model layer", phase: "Phase B").anchor, .task(line: expectedLine))
    }

    func testResolvedDocIsTheMatchedPlan() throws {
        XCTAssertEqual(try resolve().doc, widget())
    }
}
