import XCTest
@testable import Dreamux

/// The rail's compact-card current-step label: reuses `PlanPhases`'
/// grouping/current-group rule and the "first task with an unchecked
/// step" rule to name what's in flight right now.
final class PlanCurrentStepTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    func testPhasedPlanLabelsCurrentPhaseAndTask() {
        let plan = doc("2026-07-05-phased.md", """
        # Phased Plan
        ## Phase 1 — Core mechanic
        ### Task 1.9: Warm-up
        - [x] **Step 1: one**
        ### Task 1.10: The real thing
        - [ ] **Step 1: one**
        ## Phase 2 — Polish
        ### Task 2.1: Later
        - [ ] **Step 1: one**
        """)
        // Pinned format: "Phase <n> · Task <n[.n]>".
        XCTAssertEqual(PlanCurrentStep.label(for: plan), "Phase 1 · Task 1.10")
    }

    func testUnphasedPlanLabelsTaskOnly() {
        let plan = doc("2026-07-05-unphased.md", """
        # Unphased Plan
        ### Task 1: Warm-up
        - [x] **Step 1: one**
        ### Task 3: The real thing
        - [ ] **Step 1: one**
        """)
        XCTAssertEqual(PlanCurrentStep.label(for: plan), "Task 3")
    }

    func testFullyCheckedPlanHasNoCurrentStep() {
        let plan = doc("2026-07-05-done.md", """
        # Done Plan
        ### Task 1: Warm-up
        - [x] **Step 1: one**
        """)
        XCTAssertNil(PlanCurrentStep.label(for: plan))
    }

    func testPlanWithNoTasksHasNoCurrentStep() {
        let plan = doc("2026-07-05-empty.md", """
        # Empty Plan
        Just prose, no tasks.
        """)
        XCTAssertNil(PlanCurrentStep.label(for: plan))
    }
}
