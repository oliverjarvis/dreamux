import XCTest
@testable import Dreamux

final class SubagentTaskPinTests: XCTestCase {
    private func task(_ title: String, line: Int) -> PlanTask {
        PlanTask(title: title, steps: [PlanStep(title: "s", checked: false)], line: line)
    }

    func testPinsExplicitTaskNumber() {
        let tasks = [task("Task 1: Model", line: 10), task("Task 3: Checklist restyle", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "Implementing Task 3: the restyle", tasks: tasks), 40)
    }
    func testCaseInsensitive() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "working on task 3", tasks: tasks), 40)
    }
    func testDottedNumber() {
        let tasks = [task("Task 0.2: Phase task", line: 22)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "Task 0.2 in progress", tasks: tasks), 22)
    }
    func testPaddingAndSpacingNormalize() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "task  03 running", tasks: tasks), 40)
    }
    func testNoTokenIsNil() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "reviewing the diff", tasks: tasks))
    }
    func testNumberWithNoMatchingTitleIsNil() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "Task 9 here", tasks: tasks))
    }
    func testAmbiguousNumberIsNil() {
        let tasks = [task("Task 3: X", line: 40), task("Task 3: dup", line: 80)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "Task 3", tasks: tasks))
    }
    func testDoesNotMatchSubstringWord() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "subtask 3 stuff", tasks: tasks))
    }
}
