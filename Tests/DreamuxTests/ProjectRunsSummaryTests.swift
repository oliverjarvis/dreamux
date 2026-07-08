import XCTest
@testable import Dreamux

final class ProjectRunsSummaryTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    func testRunsExcludesMergedAndOrdersRunningFirst() {
        // Declared awaiting-then-running-then-merged in INPUT order, so a
        // passing "running first" assertion has to come from the sort,
        // not from array order.
        let awaiting = doc("2026-07-01-awaiting.md", """
        # Awaiting Plan
        ### Task 1: a
        - [x] **Step 1: one**
        - [x] **Step 2: two**
        """)
        let running = doc("2026-07-02-running.md", """
        # Running Plan
        ### Task 1: a
        - [x] **Step 1: one**
        - [ ] **Step 2: two**
        """)
        let merged = doc("2026-07-03-merged.md", """
        # Merged Plan
        ### Task 1: a
        - [x] **Step 1: one**
        """)
        let plans = [awaiting, running, merged]

        let status: (PlanDoc) -> PlanStatus = { plan in
            if plan == awaiting { return .awaitingReview }
            if plan == running { return .running }
            if plan == merged { return .merged }
            return .ready
        }
        let featureName: (PlanDoc) -> String? = { plan in
            if plan == awaiting { return "feat-awaiting" }
            if plan == running { return "feat-running" }
            if plan == merged { return "feat-merged" }
            return nil
        }
        let relativePath: (PlanDoc) -> String = { "docs/\($0.fileURL.lastPathComponent)" }

        let result = ProjectRunsSummary.runs(
            plans: plans, status: status, featureName: featureName, relativePath: relativePath)

        XCTAssertEqual(result.count, 2, "merged plan must be excluded")
        XCTAssertEqual(result.map(\.title), ["Running Plan", "Awaiting Plan"])
        XCTAssertEqual(result.map(\.status), [.running, .awaitingReview])
        XCTAssertEqual(result[0].id, "docs/2026-07-02-running.md")
        XCTAssertEqual(result[0].featureName, "feat-running")
        XCTAssertEqual(result[0].checked, 1)
        XCTAssertEqual(result[0].total, 2)
        XCTAssertEqual(result[1].id, "docs/2026-07-01-awaiting.md")
        XCTAssertEqual(result[1].featureName, "feat-awaiting")
        XCTAssertEqual(result[1].checked, 2)
        XCTAssertEqual(result[1].total, 2)
    }

    func testEmptyPlansReturnsEmpty() {
        let result = ProjectRunsSummary.runs(
            plans: [], status: { _ in .ready }, featureName: { _ in nil }, relativePath: { _ in "" })
        XCTAssertTrue(result.isEmpty)
    }
}
