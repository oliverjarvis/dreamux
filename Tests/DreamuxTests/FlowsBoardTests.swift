import XCTest
@testable import Dreamux

final class FlowsBoardTests: XCTestCase {
    private func lane(
        id: String, kind: FlowKind, status: FlowStatus,
        workspaceID: UUID? = nil, detail: String? = nil, startedAt: Date? = nil
    ) -> Flow {
        Flow(
            id: id, title: id, kind: kind, workspaceID: workspaceID,
            sessionID: nil, detail: detail, startedAt: startedAt,
            nodes: [FlowNode(id: "session", kind: .agent, label: "x", status: status)],
            edges: []
        )
    }

    func testAdhocLaneMatchingPlanWorkspaceIsSuppressedAndBubblesStatus() {
        let wsID = UUID()
        let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
        let session = lane(id: "session-s", kind: .adhoc, status: .waiting, workspaceID: wsID, detail: "needs permission")
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [session])

        let all = board.sections.flatMap(\.lanes)
        XCTAssertEqual(all.map(\.id), ["plan-p"]) // adhoc suppressed
        let planLane = all[0]
        XCTAssertEqual(planLane.effectiveStatus, .waiting)      // bubbled from live session
        XCTAssertEqual(planLane.flow.detail, "needs permission") // detail grafted
        XCTAssertEqual(board.needsYouCount, 1)
        XCTAssertEqual(board.runningCount, 0)
    }

    func testUnmatchedSessionLanesStay() {
        let board = FlowsBoard.compose(
            planLanes: [lane(id: "plan-p", kind: .plan, status: .running, workspaceID: UUID())],
            sessionLanes: [lane(id: "session-s", kind: .adhoc, status: .running)]
        )
        XCTAssertEqual(Set(board.sections.flatMap(\.lanes).map(\.id)), ["plan-p", "session-s"])
        XCTAssertEqual(board.runningCount, 2)
    }

    func testSectionOrderAndMembership() {
        let board = FlowsBoard.compose(
            planLanes: [
                lane(id: "plan-wait", kind: .plan, status: .waiting),
                lane(id: "plan-done", kind: .plan, status: .done),
            ],
            sessionLanes: [
                lane(id: "session-run", kind: .adhoc, status: .running),
                lane(id: "session-idle", kind: .adhoc, status: .queued),
                lane(id: "session-bg", kind: .scheduled, status: .done),
            ]
        )
        XCTAssertEqual(board.sections.map(\.kind), [.needsYou, .running, .queued, .scheduled, .finished])
        XCTAssertEqual(board.sections[0].lanes.map(\.id), ["plan-wait"])
        XCTAssertEqual(board.sections[1].lanes.map(\.id), ["session-run"])
        XCTAssertEqual(board.sections[2].lanes.map(\.id), ["session-idle"])
        XCTAssertEqual(board.sections[3].lanes.map(\.id), ["session-bg"]) // scheduled section regardless of doneness
        XCTAssertEqual(board.sections[4].lanes.map(\.id), ["plan-done"])
    }

    func testEmptySectionsAreOmitted() {
        let board = FlowsBoard.compose(planLanes: [], sessionLanes: [lane(id: "session-r", kind: .adhoc, status: .running)])
        XCTAssertEqual(board.sections.map(\.kind), [.running])
    }

    func testIdleSessionChipAndFreshnessOrderWithinSection() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [
                lane(id: "session-old", kind: .adhoc, status: .queued, startedAt: old),
                lane(id: "session-new", kind: .adhoc, status: .queued, startedAt: new),
            ]
        )
        XCTAssertEqual(board.sections[0].lanes.map(\.id), ["session-new", "session-old"]) // newest first
        XCTAssertEqual(board.sections[0].lanes[0].sessionChip, "idle")
    }

    func testWaitingSessionChipShowsWaiting() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [lane(id: "session-w", kind: .adhoc, status: .waiting)]
        )
        XCTAssertEqual(board.sections[0].lanes[0].sessionChip, "waiting on you")
    }

    func testMultipleAdhocSessionsSameWorkspaceKeepsNonEngineVisible() {
        let wsID = UUID()
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
        let runningOlder = lane(id: "session-run-old", kind: .adhoc, status: .running, workspaceID: wsID, detail: "running detail", startedAt: old)
        let waitingNewer = lane(id: "session-wait-new", kind: .adhoc, status: .waiting, workspaceID: wsID, detail: "waiting detail", startedAt: new)

        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [runningOlder, waitingNewer])

        let all = board.sections.flatMap(\.lanes)
        XCTAssertEqual(Set(all.map(\.id)), ["plan-p", "session-run-old"]) // waiting is engine (higher priority), running stays visible

        // Plan lane should have bubbled the waiting status and its detail
        let planLane = all.first { $0.id == "plan-p" }!
        XCTAssertEqual(planLane.effectiveStatus, .waiting)
        XCTAssertEqual(planLane.flow.detail, "waiting detail")

        // Running session stays visible as its own lane
        let runningLane = all.first { $0.id == "session-run-old" }!
        XCTAssertEqual(runningLane.effectiveStatus, .running)
        XCTAssertEqual(runningLane.sessionChip, "claude busy")

        XCTAssertEqual(board.needsYouCount, 1) // plan lane is waiting
        XCTAssertEqual(board.runningCount, 1) // session-run-old is running
    }

    func testEngineSelectionByPrecedence() {
        let wsID = UUID()
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let plan = lane(id: "plan-p", kind: .plan, status: .done, workspaceID: wsID)
        let runningNewer = lane(id: "session-run-new", kind: .adhoc, status: .running, workspaceID: wsID, detail: "newer", startedAt: new)
        let runningOlder = lane(id: "session-run-old", kind: .adhoc, status: .running, workspaceID: wsID, detail: "older", startedAt: old)

        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [runningOlder, runningNewer])

        let all = board.sections.flatMap(\.lanes)
        XCTAssertEqual(Set(all.map(\.id)), ["plan-p", "session-run-old"]) // newer is engine, older stays visible

        // Plan lane should have bubbled the newer session's detail
        let planLane = all.first { $0.id == "plan-p" }!
        XCTAssertEqual(planLane.effectiveStatus, .running)
        XCTAssertEqual(planLane.flow.detail, "newer")

        XCTAssertEqual(board.runningCount, 2)
    }

    func testFailedLaneCountsAsNeedsYou() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [lane(id: "session-f", kind: .adhoc, status: .failed)]
        )

        let failedLane = board.sections.flatMap(\.lanes)[0]
        XCTAssertEqual(failedLane.effectiveStatus, .failed)
        XCTAssertEqual(failedLane.sessionChip, "failed")
        XCTAssertEqual(board.sections.map(\.kind), [.needsYou])
        XCTAssertEqual(board.needsYouCount, 1)
    }

    func testWaitingScheduledLaneSectionsUnderNeedsYou() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [lane(id: "session-bg", kind: .scheduled, status: .waiting)]
        )
        XCTAssertEqual(board.sections.map(\.kind), [.needsYou])
        XCTAssertEqual(board.needsYouCount, 1)
    }

    func testFailedEngineBubblesOntoPlanLane() {
        let wsID = UUID()
        let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
        let engine = lane(id: "session-s", kind: .adhoc, status: .failed, workspaceID: wsID, detail: "test suite crashed")
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [engine])
        let planLane = board.sections.flatMap(\.lanes).first { $0.id == "plan-p" }!
        XCTAssertEqual(planLane.effectiveStatus, .failed)
        XCTAssertEqual(planLane.flow.detail, "test suite crashed")
        XCTAssertEqual(board.needsYouCount, 1)
    }
}
