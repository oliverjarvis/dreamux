import XCTest
@testable import Dreamux

/// The sidebar's phase-grouping decision for a plan's task expansion:
/// group only when at least two distinct named sections carry tasks,
/// keep document order, and point the default-open at the current
/// phase.
final class PlanPhasesTests: XCTestCase {
    private func task(_ title: String, phase: String?, done: Bool = false) -> PlanTask {
        PlanTask(title: title,
                 steps: [PlanStep(title: "s", checked: done)],
                 phase: phase)
    }

    func testGroupsConsecutiveTasksByPhaseInDocumentOrder() {
        let groups = PlanPhases.groups([
            task("0.1", phase: "Phase 0"),
            task("0.2", phase: "Phase 0"),
            task("1.1", phase: "Phase 1"),
        ])
        XCTAssertEqual(groups.map(\.phase), ["Phase 0", "Phase 1"])
        XCTAssertEqual(groups[0].tasks.map(\.title), ["0.1", "0.2"])
        XCTAssertEqual(groups[1].tasks.map(\.title), ["1.1"])
    }

    func testShouldGroupNeedsTwoDistinctNamedPhases() {
        XCTAssertTrue(PlanPhases.shouldGroup([
            task("a", phase: "Phase 0"), task("b", phase: "Phase 1"),
        ]))
        // One generic H2 over everything — render flat, as before.
        XCTAssertFalse(PlanPhases.shouldGroup([
            task("a", phase: "Tasks"), task("b", phase: "Tasks"),
        ]))
        // No sections at all — flat.
        XCTAssertFalse(PlanPhases.shouldGroup([
            task("a", phase: nil), task("b", phase: nil),
        ]))
    }

    func testGroupRollupsAndCurrentGroup() {
        let groups = PlanPhases.groups([
            task("0.1", phase: "Phase 0", done: true),
            task("0.2", phase: "Phase 0", done: true),
            task("1.1", phase: "Phase 1", done: false),
        ])
        XCTAssertEqual(groups[0].checkedSteps, 2)
        XCTAssertEqual(groups[0].totalSteps, 2)
        XCTAssertEqual(groups[1].checkedSteps, 0)
        // Current = first group holding an unchecked step.
        XCTAssertEqual(PlanPhases.currentGroupIndex(groups), 1)
    }

    func testCurrentGroupNilWhenEverythingChecked() {
        let groups = PlanPhases.groups([task("a", phase: "P0", done: true)])
        XCTAssertNil(PlanPhases.currentGroupIndex(groups))
    }
}
