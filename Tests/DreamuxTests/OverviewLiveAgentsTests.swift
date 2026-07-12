import XCTest
@testable import Dreamux

final class OverviewLiveAgentsTests: XCTestCase {
    private let ws = UUID()

    private func lane(_ id: String, workspace: UUID?, nodes: [FlowNode]) -> Flow {
        var f = Flow(id: id, title: id, kind: .adhoc, workspaceID: workspace)
        f.nodes = nodes
        return f
    }
    private func agent(_ id: String, label: String, status: FlowStatus,
                       started: Date? = nil, activity: String? = nil) -> FlowNode {
        FlowNode(id: id, kind: .agent, label: label, status: status,
                 startedAt: started, lastActivity: activity)
    }

    func testExcludesSessionKeepsRunningSubagent() {
        let flows = [lane("l1", workspace: ws, nodes: [
            FlowNode(id: "session", kind: .agent, label: "claude", status: .running),
            agent("agent-1", label: "code-reviewer", status: .running),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["agent-1"])
        XCTAssertEqual(result.first?.name, "code-reviewer")
    }

    func testExcludesCollapsedQueuedDoneFailed() {
        let flows = [lane("l1", workspace: ws, nodes: [
            agent("agent-done", label: "Explore", status: .done),
            agent("agent-queued", label: "Explore", status: .queued),
            agent("agent-failed", label: "Explore", status: .failed),
            FlowNode(id: FlowStore.collapsedAgentNodeID, kind: .agent, label: "agents", status: .running),
            agent("agent-live", label: "Explore", status: .waiting),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["agent-live"])
    }

    func testAggregatesAcrossLanesIgnoresOtherWorkspaces() {
        let other = UUID()
        let flows = [
            lane("l1", workspace: ws, nodes: [agent("a1", label: "x", status: .running, started: Date(timeIntervalSince1970: 10))]),
            lane("l2", workspace: ws, nodes: [agent("a2", label: "y", status: .running, started: Date(timeIntervalSince1970: 20))]),
            lane("l3", workspace: other, nodes: [agent("a3", label: "z", status: .running)]),
        ]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["a1", "a2"])  // stable, oldest first
    }

    func testAppliesPinFromActivity() {
        let tasks = [PlanTask(title: "Task 3: X", steps: [PlanStep(title: "s", checked: false)], line: 42)]
        let flows = [lane("l1", workspace: ws, nodes: [
            agent("a1", label: "general-purpose", status: .running, activity: "Implementing Task 3"),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: tasks)
        XCTAssertEqual(result.first?.taskLine, 42)
        XCTAssertEqual(result.first?.activity, "Implementing Task 3")
    }
}
