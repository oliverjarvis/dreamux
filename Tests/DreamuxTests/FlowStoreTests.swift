// Tests/DreamuxTests/FlowStoreTests.swift
import Combine
import XCTest
@testable import Dreamux

@MainActor
final class FlowStoreTests: XCTestCase {
    private func entry(
        pid: Int32 = 1, session: String = "s1", cwd: String = "/w",
        status: String = "busy", kind: String = "interactive", name: String? = "auth-refresh"
    ) -> ClaudeSessionEntry {
        let json = """
        {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","status":"\(status)",
         "kind":"\(kind)"\(name.map { ",\"name\":\"\($0)\"" } ?? "")}
        """
        return try! JSONDecoder().decode(ClaudeSessionEntry.self, from: Data(json.utf8))
    }

    func testRegistryCreatesSessionLane() {
        let wsID = UUID()
        let store = FlowStore(workspaceForCwd: { $0 == "/w" ? wsID : nil })
        store.apply(registry: [entry()])

        XCTAssertEqual(store.flows.count, 1)
        let lane = store.flows[0]
        XCTAssertEqual(lane.id, "session-s1")
        XCTAssertEqual(lane.title, "auth-refresh")
        XCTAssertEqual(lane.kind, .adhoc)
        XCTAssertEqual(lane.workspaceID, wsID)
        XCTAssertEqual(lane.sessionID, "s1")
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "session", "drain"])
        XCTAssertEqual(lane.nodes[0].status, .done)     // source: the prompt happened
        XCTAssertEqual(lane.nodes[1].status, .running)  // busy
        XCTAssertEqual(lane.nodes[2].status, .queued)   // drain pending
        XCTAssertEqual(lane.edges, [
            FlowEdge(from: "src", to: "session", kind: .sequence),
            FlowEdge(from: "session", to: "drain", kind: .sequence),
        ])
        XCTAssertEqual(store.aggregates, FlowAggregates(runningCount: 1, needsYouCount: 0))
    }

    func testBackgroundSessionIsScheduledLane() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry(kind: "bg", name: nil)])
        XCTAssertEqual(store.flows[0].kind, .scheduled)
        XCTAssertEqual(store.flows[0].title, "s1") // falls back to session id
    }

    func testWaitingDrivesNeedsYou() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry(status: "waiting")])
        XCTAssertEqual(store.flows[0].status, .waiting)
        XCTAssertEqual(store.aggregates.needsYouCount, 1)
    }

    func testVanishedSessionCompletesLane() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(registry: []) // session gone from registry
        let lane = store.flows[0]
        XCTAssertEqual(lane.nodes.first { $0.id == "session" }?.status, .done)
        XCTAssertEqual(lane.nodes.first { $0.id == "drain" }?.status, .done)
        XCTAssertEqual(store.aggregates.runningCount, 0)
    }

    func testAgentEventsAddAndCloseAgentNodes() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let t0 = Date(timeIntervalSince1970: 100)
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: "Explore",
            description: "map repo", cwd: "/w", at: t0
        ))

        var lane = store.flows[0]
        let agent = lane.nodes.first { $0.id == "agent-a1" }
        XCTAssertEqual(agent?.kind, .agent)
        XCTAssertEqual(agent?.status, .running)
        XCTAssertEqual(agent?.label, "Explore")
        XCTAssertEqual(agent?.startedAt, t0)
        XCTAssertTrue(lane.edges.contains(FlowEdge(from: "session", to: "agent-a1", kind: .spawn)))

        let t1 = Date(timeIntervalSince1970: 200)
        store.apply(event: .agentStopped(sessionID: "s1", agentID: "a1", cwd: "/w", at: t1))
        lane = store.flows[0]
        XCTAssertEqual(lane.nodes.first { $0.id == "agent-a1" }?.status, .done)
        XCTAssertEqual(lane.nodes.first { $0.id == "agent-a1" }?.endedAt, t1)
    }

    func testEventBeforeRegistryCreatesLane() {
        // Replay can deliver events before the first registry poll.
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(event: .agentStarted(
            sessionID: "s9", agentID: "a1", agentType: nil,
            description: nil, cwd: "/w", at: Date()
        ))
        XCTAssertEqual(store.flows.map(\.id), ["session-s9"])
        XCTAssertNotNil(store.flows[0].nodes.first { $0.id == "agent-a1" })
    }

    func testTaskEventsAndNotificationAndStop() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let t = Date()
        store.apply(event: .taskCreated(sessionID: "s1", taskID: "7", subject: "Fix bug", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .queued)
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.label, "Fix bug")

        store.apply(event: .taskCompleted(sessionID: "s1", taskID: "7", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .done)

        store.apply(event: .notification(sessionID: "s1", message: "needs permission", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].detail, "needs permission")

        store.apply(event: .sessionStopped(sessionID: "s1", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "session" }?.status, .done)
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "drain" }?.status, .done)
    }

    func testUnknownSessionEventForUnknownAgentStopIsIgnored() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(event: .agentStopped(sessionID: "nope", agentID: "aX", cwd: nil, at: Date()))
        // Creates the lane (session known now) but no phantom agent node.
        XCTAssertNil(store.flows.first?.nodes.first { $0.id == "agent-aX" })
    }

    func testSessionStoppedCompletesQueuedTaskNode() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let t = Date()
        store.apply(event: .taskCreated(sessionID: "s1", taskID: "7", subject: "Fix bug", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .queued)

        store.apply(event: .sessionStopped(sessionID: "s1", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .done)
        XCTAssertEqual(store.flows[0].status, .done)
    }

    func testTaskCreatedWithNilTaskIDIsIgnored() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .taskCreated(sessionID: "s1", taskID: nil, subject: "Fix bug", cwd: "/w", at: Date()))
        XCTAssertNil(store.flows[0].nodes.first { $0.id.hasPrefix("task-") })
    }

    func testSteadyStateEmptySweepEmitsNoChange() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(registry: []) // vanish: transitions session/drain to done, aggregates drop to zero

        var changeCount = 0
        let cancellable = store.objectWillChange.sink { _ in changeCount += 1 }
        store.apply(registry: []) // steady state: already done, aggregates already zero
        XCTAssertEqual(changeCount, 0)
        cancellable.cancel()
    }
}
