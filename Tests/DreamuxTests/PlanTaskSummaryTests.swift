import XCTest
@testable import Dreamux

final class PlanTaskSummaryTests: XCTestCase {
    private func task(_ title: String, line: Int, checks: [Bool]) -> PlanTask {
        PlanTask(title: title, steps: checks.map { PlanStep(title: "s", checked: $0) }, phase: "P1", line: line)
    }
    func testCleanStripsLeadingTaskN() {
        XCTAssertEqual(PlanTaskTitle.clean("Task 3: collisions"), "collisions")
        XCTAssertEqual(PlanTaskTitle.clean("Ad-hoc thing"), "Ad-hoc thing")
        XCTAssertEqual(PlanTaskTitle.clean(""), "Steps")
    }
    func testSummariesStatusAndCurrent() {
        let tasks = [task("Task 1: a", line: 5, checks: [true, true]),
                     task("Task 2: b", line: 9, checks: [true, false]),
                     task("Task 3: c", line: 14, checks: [false])]
        let s = PlanTaskSummary.summaries(from: tasks)
        XCTAssertEqual(s.map(\.line), [5, 9, 14])
        XCTAssertEqual(s.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(s[0].checkedSteps, 2); XCTAssertEqual(s[0].totalSteps, 2)
        // current = first task with an unchecked step (line 9)
        XCTAssertEqual(s.map(\.isCurrent), [false, true, false])
        XCTAssertEqual(s[0].phase, "P1")
    }
    func testEmptyStepTasksExcluded() {
        let tasks = [PlanTask(title: "Task 1: x", steps: [], phase: nil, line: 1),
                     task("Task 2: y", line: 4, checks: [false])]
        XCTAssertEqual(PlanTaskSummary.summaries(from: tasks).map(\.line), [4])
    }
    func testAllCheckedHasNoCurrent() {
        let s = PlanTaskSummary.summaries(from: [task("Task 1: a", line: 1, checks: [true])])
        XCTAssertEqual(s.map(\.isCurrent), [false])
    }
}
