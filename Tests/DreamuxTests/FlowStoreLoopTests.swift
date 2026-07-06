// Tests/DreamuxTests/FlowStoreLoopTests.swift
import Combine
import XCTest
@testable import Dreamux

@MainActor
final class FlowStoreLoopTests: XCTestCase {
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

    private func fail(_ store: FlowStore, _ toolUseID: String, tool: String = "Bash", summary: String? = "swift test something") {
        store.apply(transcript: .toolStarted(toolUseID: toolUseID, tool: tool, summary: summary, at: nil), sessionID: "s1")
        store.apply(transcript: .toolFinished(toolUseID: toolUseID, isError: true, at: nil), sessionID: "s1")
    }

    private func pass(_ store: FlowStore, _ toolUseID: String, tool: String = "Bash", summary: String? = "swift test something") {
        store.apply(transcript: .toolStarted(toolUseID: toolUseID, tool: tool, summary: summary, at: nil), sessionID: "s1")
        store.apply(transcript: .toolFinished(toolUseID: toolUseID, isError: false, at: nil), sessionID: "s1")
    }

    private func loopEdges(_ store: FlowStore) -> [FlowEdge] {
        store.flows[0].edges.filter { $0.kind == .loop }
    }

    func testFailingRepeatCreatesLoopEdge() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...3 { fail(store, "tu\(i)") }

        let edges = loopEdges(store)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.from, "session")
        XCTAssertEqual(edges.first?.to, "session")
        XCTAssertEqual(edges.first?.label, "Bash:swift")
        XCTAssertEqual(edges.first?.iterations, 3)
    }

    func testInterleavedEditsStillDetect() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        pass(store, "e1", tool: "Edit", summary: "file.swift")
        for i in 1...3 { fail(store, "tu\(i)") }

        let edges = loopEdges(store)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.label, "Bash:swift")
        XCTAssertEqual(edges.first?.iterations, 3)
    }

    func testLoopCountGrows() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...4 { fail(store, "tu\(i)") }

        let edges = loopEdges(store)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.iterations, 4)
    }

    func testPassClearsLoop() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...3 { fail(store, "tu\(i)") }
        XCTAssertEqual(loopEdges(store).count, 1)

        pass(store, "tu4")

        XCTAssertEqual(loopEdges(store).count, 0)
    }

    func testAgentResultsExcluded() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))
        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        for _ in 1...3 {
            store.apply(transcript: .toolFinished(toolUseID: "tu1", isError: true, at: Date()), sessionID: "s1")
        }

        XCTAssertEqual(loopEdges(store).count, 0)
    }

    func testScheduledLaneNeverLoops() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry(kind: "bg")])

        for i in 1...3 { fail(store, "tu\(i)") }

        XCTAssertEqual(loopEdges(store).count, 0)
    }

    func testSweepClearsLoopStateAndEdge() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...3 { fail(store, "tu\(i)") }
        XCTAssertEqual(loopEdges(store).count, 1)

        store.apply(event: .sessionStopped(sessionID: "s1", cwd: "/w", at: Date()))
        XCTAssertEqual(loopEdges(store).count, 0)

        // A late completion after sweep must not resurrect the loop from
        // stale ring state: the ring was cleared, so one more failure
        // isn't enough to re-qualify on its own.
        fail(store, "tu4")

        XCTAssertEqual(loopEdges(store).count, 0)
    }

    func testWindowEviction() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...3 { fail(store, "tu\(i)") }
        XCTAssertEqual(loopEdges(store).count, 1)

        for i in 1...12 { pass(store, "ok\(i)", tool: "Edit", summary: "file\(i).swift") }

        XCTAssertEqual(loopEdges(store).count, 0)
    }

    func testReplayReapplicationDoesNotDoubleCount() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...3 { fail(store, "tu\(i)") }
        XCTAssertEqual(loopEdges(store).first?.iterations, 3)

        // A full transcript re-tail (e.g. zoom re-reading from byte 0)
        // re-emits the exact same toolStarted/toolFinished pairs — the
        // ring must recognize the toolUseIDs it already counted and not
        // inflate the iteration count on replay.
        for i in 1...3 { fail(store, "tu\(i)") }

        XCTAssertEqual(loopEdges(store).count, 1)
        XCTAssertEqual(loopEdges(store).first?.iterations, 3)
    }
}
