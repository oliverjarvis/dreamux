// Tests/DreamuxTests/RunLaneGraftTests.swift
import XCTest
@testable import Dreamux

final class RunLaneGraftTests: XCTestCase {
    private func lane(taskLines: [Int]) -> Flow {
        var f = Flow(id: "plan-x", title: "X", kind: .plan)
        f.nodes = [FlowNode(id: "src", kind: .source, label: "plan", status: .done)]
            + taskLines.map { FlowNode(id: "plan-task-\($0)", kind: .task, label: "t", status: .queued) }
            + [FlowNode(id: "drain", kind: .drain, label: "merge", status: .queued)]
        return f
    }
    private func sub(_ id: String, taskLine: Int?) -> LiveSubagent {
        LiveSubagent(id: id, name: "code-reviewer", activity: nil, status: .running, taskLine: taskLine)
    }
    func testPinnedSubagentAddsNodeAndSpawnEdge() {
        let g = RunLaneGraft.graft(lane(taskLines: [5, 9]), subagents: [sub("agent-1", taskLine: 9)], currentTaskLine: 5)
        XCTAssertTrue(g.nodes.contains { $0.id == "agent-1" && $0.kind == .agent })
        XCTAssertTrue(g.edges.contains(FlowEdge(from: "plan-task-9", to: "agent-1", kind: .spawn)))
    }
    func testUnpinnedAttachesToCurrent() {
        let g = RunLaneGraft.graft(lane(taskLines: [5, 9]), subagents: [sub("agent-1", taskLine: nil)], currentTaskLine: 5)
        XCTAssertTrue(g.edges.contains(FlowEdge(from: "plan-task-5", to: "agent-1", kind: .spawn)))
    }
    func testUnpinnedNoCurrentSkipped() {
        let g = RunLaneGraft.graft(lane(taskLines: [5]), subagents: [sub("agent-1", taskLine: nil)], currentTaskLine: nil)
        XCTAssertFalse(g.nodes.contains { $0.id == "agent-1" })
    }
    func testTargetAbsentSkipped() {
        let g = RunLaneGraft.graft(lane(taskLines: [5]), subagents: [sub("agent-1", taskLine: 99)], currentTaskLine: 5)
        XCTAssertFalse(g.nodes.contains { $0.id == "agent-1" })
    }
    func testDuplicateAgentIdSkipped() {
        var l = lane(taskLines: [5]); l.nodes.append(FlowNode(id: "agent-1", kind: .agent, label: "x", status: .running))
        let g = RunLaneGraft.graft(l, subagents: [sub("agent-1", taskLine: 5)], currentTaskLine: 5)
        XCTAssertEqual(g.nodes.filter { $0.id == "agent-1" }.count, 1)
    }
}
