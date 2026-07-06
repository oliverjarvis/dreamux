// Tests/DreamuxTests/FlowStoreTranscriptTests.swift
import Combine
import XCTest
@testable import Dreamux

@MainActor
final class FlowStoreTranscriptTests: XCTestCase {
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

    func testToolStartedSetsSessionLastActivity() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        store.apply(
            transcript: .toolStarted(toolUseID: "tu0", tool: "Bash", summary: "swift build", at: nil),
            sessionID: "s1"
        )

        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "session" }?.lastActivity, "swift build")
    }

    func testMetaJoinEnrichesHookCreatedAgent() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))

        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        let node = store.flows[0].nodes.first { $0.id == "agent-a1" }
        XCTAssertEqual(node?.label, "Explore")
        XCTAssertEqual(node?.lastActivity, "map")
        // Enrichment mutates the existing node in place — it must not
        // reorder or duplicate it out from ahead of the drain.
        XCTAssertEqual(store.flows[0].nodes.map(\.id), ["src", "session", "agent-a1", "drain"])
    }

    func testAgentResultMarksDoneViaJoin() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))
        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        let t = Date(timeIntervalSince1970: 300)
        store.apply(transcript: .toolFinished(toolUseID: "tu1", isError: false, at: t), sessionID: "s1")

        let node = store.flows[0].nodes.first { $0.id == "agent-a1" }
        XCTAssertEqual(node?.status, .done)
        XCTAssertEqual(node?.endedAt, t)
        // The join-based status flip must not reorder or duplicate the
        // node out from ahead of the drain.
        XCTAssertEqual(store.flows[0].nodes.map(\.id), ["src", "session", "agent-a1", "drain"])
    }

    func testAgentErrorMarksFailed() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))
        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        store.apply(transcript: .toolFinished(toolUseID: "tu1", isError: true, at: Date()), sessionID: "s1")

        // Note: the *lane's* aggregate status stays `.running` here (the
        // session node is still busy) — `aggregateStatus` deliberately
        // ranks running activity above a failed node ("activity beats
        // outcomes"). A failed node still outranks queued/done once the
        // session itself finishes, which is what lets FlowsBoard's
        // needsYou treatment of failed lanes (Task 1) pick it up.
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "agent-a1" }?.status, .failed)
    }

    func testNonAgentToolErrorDoesNotFail() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let before = store.flows[0].nodes

        store.apply(transcript: .toolFinished(toolUseID: "unmapped", isError: true, at: Date()), sessionID: "s1")

        XCTAssertEqual(store.flows[0].nodes, before)
    }

    func testFanOutCollapsesOldestDoneAgents() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        for i in 1...8 {
            let t = Date(timeIntervalSince1970: Double(i))
            store.apply(event: .agentStarted(
                sessionID: "s1", agentID: "a\(i)", agentType: "Explore", description: nil, cwd: "/w", at: t
            ))
            store.apply(
                meta: SubagentMeta(agentID: "a\(i)", agentType: "Explore", description: nil, toolUseID: "tu\(i)", spawnDepth: nil),
                sessionID: "s1"
            )
        }

        // Complete the first seven; the eighth stays running and must
        // survive collapse untouched.
        for i in 1...7 {
            store.apply(
                transcript: .toolFinished(toolUseID: "tu\(i)", isError: false, at: Date(timeIntervalSince1970: Double(100 + i))),
                sessionID: "s1"
            )
        }

        let lane = store.flows[0]
        let collapsed = lane.nodes.first { $0.id == "agents-collapsed" }
        XCTAssertNotNil(collapsed)
        XCTAssertEqual(collapsed?.kind, .agent)
        XCTAssertEqual(collapsed?.status, .done)
        // Hand-traced: a1 merges alone (creating the collapsed node),
        // a2 and a3 each merge in one at a time as they complete (the
        // cap re-triggers after every completion until the count drops
        // to 6) — a4..a7 land under the cap and stay individual, a8
        // never completes. Multiplicity is exactly 1+1+1 = 3.
        XCTAssertEqual(collapsed?.counters.multiplicity, 3)

        let agentish = lane.nodes.filter { $0.kind == .agent && $0.id != "session" }
        XCTAssertLessThanOrEqual(agentish.count, 7)

        XCTAssertEqual(lane.nodes.first { $0.id == "agent-a8" }?.status, .running)

        // Full order: a1-a3 collapsed away, a4-a8 (still-running a8
        // included) keep their arrival order, and the collapsed node
        // — inserted once, on a1's merge — sits before the drain.
        XCTAssertEqual(
            lane.nodes.map(\.id),
            ["src", "session", "agent-a4", "agent-a5", "agent-a6", "agent-a7", "agent-a8", "agents-collapsed", "drain"]
        )
    }

    func testSkippedLinesThresholdSetsDetailUnavailable() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])

        store.noteSkippedLines(49, sessionID: "s1")
        XCTAssertEqual(store.flows[0].detailUnavailable, false)

        store.noteSkippedLines(1, sessionID: "s1")
        XCTAssertEqual(store.flows[0].detailUnavailable, true)
    }

    func testTranscriptSpawnAloneCreatesNoNode() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let before = store.flows[0].nodes.count

        store.apply(
            transcript: .agentSpawned(toolUseID: "tuX", agentType: "Explore", description: "desc", at: nil),
            sessionID: "s1"
        )

        XCTAssertEqual(store.flows[0].nodes.count, before)
    }

    func testSessionStoppedClearsJoinMapSoLateToolFinishedIsNoOp() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))
        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        store.apply(event: .sessionStopped(sessionID: "s1", cwd: "/w", at: Date()))
        // completeSessionNodes flips the still-running agent to .done —
        // confirm that first so the later no-op is a genuine no-op,
        // not a status that was already .failed for some other reason.
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "agent-a1" }?.status, .done)

        // A late transcript line for a toolUseID this lane once joined
        // must not resurrect the join: the map was swept on completion.
        store.apply(transcript: .toolFinished(toolUseID: "tu1", isError: true, at: Date()), sessionID: "s1")

        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "agent-a1" }?.status, .done)
    }

    func testVanishedSessionSweepClearsJoinMapSoLateToolFinishedIsNoOp() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: Date()
        ))
        store.apply(
            meta: SubagentMeta(agentID: "a1", agentType: "Explore", description: "map", toolUseID: "tu1", spawnDepth: nil),
            sessionID: "s1"
        )

        store.apply(registry: []) // session vanished from the registry
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "agent-a1" }?.status, .done)

        store.apply(transcript: .toolFinished(toolUseID: "tu1", isError: true, at: Date()), sessionID: "s1")

        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "agent-a1" }?.status, .done)
    }
}
