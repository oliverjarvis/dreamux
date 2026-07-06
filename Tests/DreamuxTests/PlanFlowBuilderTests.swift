// Tests/DreamuxTests/PlanFlowBuilderTests.swift
import XCTest
@testable import Dreamux

final class PlanFlowBuilderTests: XCTestCase {
    private func input(
        path: String = "plans/auth.md", title: String = "Auth refresh",
        status: PlanStatus = .running,
        phases: [PlanPhaseSummary] = [
            PlanPhaseSummary(title: "Plan", checkedSteps: 4, totalSteps: 4),
            PlanPhaseSummary(title: "Implement", checkedSteps: 1, totalSteps: 6),
            PlanPhaseSummary(title: "Test", checkedSteps: 0, totalSteps: 3),
        ],
        ordinal: Int? = nil, isCurrent: Bool = false, queueState: PlanQueueState? = nil,
        workspaceID: UUID? = nil, startedAt: Date? = Date(timeIntervalSince1970: 100)
    ) -> PlanLaneInput {
        PlanLaneInput(
            planPath: path, title: title, status: status, phases: phases,
            queueOrdinal: ordinal, isCurrentQueuePlan: isCurrent, queueState: queueState,
            workspaceID: workspaceID, startedAt: startedAt
        )
    }

    func testRunningPlanLaneShape() {
        let wsID = UUID()
        let lanes = PlanFlowBuilder.lanes(from: [input(workspaceID: wsID)])
        XCTAssertEqual(lanes.count, 1)
        let lane = lanes[0]
        XCTAssertEqual(lane.id, "plan-plans/auth.md")
        XCTAssertEqual(lane.kind, .plan)
        XCTAssertEqual(lane.title, "Auth refresh")
        XCTAssertEqual(lane.workspaceID, wsID)
        XCTAssertEqual(lane.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "phase-0", "phase-1", "phase-2", "drain"])
        XCTAssertEqual(lane.nodes[0].status, .done)      // src
        XCTAssertEqual(lane.nodes[1].status, .done)      // 4/4
        XCTAssertEqual(lane.nodes[2].status, .running)   // 1/6, plan running
        XCTAssertEqual(lane.nodes[2].label, "Implement")
        XCTAssertEqual(lane.nodes[3].status, .queued)    // 0/3
        XCTAssertEqual(lane.nodes[4].status, .queued)    // drain pending
        // Sequential edges src→p0→p1→p2→drain
        XCTAssertEqual(lane.edges.count, 4)
        XCTAssertTrue(lane.edges.allSatisfy { $0.kind == .sequence })
        XCTAssertEqual(lane.status, .running)
    }

    func testPartialPhaseIsQueuedWhenPlanNotRunning() {
        // A half-checked phase only reads running while the plan itself runs.
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .inProgress)])
        XCTAssertEqual(lanes[0].nodes[2].status, .queued)
    }

    func testGateNodeAppearsAtGateAndReadsWaiting() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .awaitingReview, isCurrent: true, queueState: .atGate),
        ])
        let lane = lanes[0]
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "phase-0", "phase-1", "phase-2", "gate", "drain"])
        XCTAssertEqual(lane.nodes.first { $0.id == "gate" }?.status, .waiting)
        XCTAssertEqual(lane.nodes.first { $0.id == "gate" }?.kind, .gate)
        XCTAssertEqual(lane.status, .waiting)
    }

    func testAttentionAlsoReadsWaiting() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .running, isCurrent: true, queueState: .attention),
        ])
        XCTAssertEqual(lanes[0].nodes.first { $0.id == "gate" }?.status, .waiting)
    }

    func testAwaitingReviewWithoutQueueShowsWaitingGate() {
        // A plan can reach review outside the queue; the gate still needs the human.
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .awaitingReview)])
        XCTAssertEqual(lanes[0].nodes.first { $0.id == "gate" }?.status, .waiting)
    }

    func testMergedPlanIsAllDone() {
        let phases = [PlanPhaseSummary(title: "All", checkedSteps: 5, totalSteps: 5)]
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .merged, phases: phases)])
        let lane = lanes[0]
        XCTAssertNil(lane.nodes.first { $0.id == "gate" })
        XCTAssertEqual(lane.nodes.first { $0.id == "drain" }?.status, .done)
        XCTAssertEqual(lane.status, .done)
    }

    func testQueuedPlanShowsOrdinalDetailAndQueuedNodes() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .ready, phases: [PlanPhaseSummary(title: "All", checkedSteps: 0, totalSteps: 5)], ordinal: 2, startedAt: nil),
        ])
        let lane = lanes[0]
        XCTAssertEqual(lane.detail, "queued #2")
        XCTAssertEqual(lane.status, .queued)
        XCTAssertEqual(lane.nodes.first { $0.id == "src" }?.status, .queued) // not started yet
    }

    func testNoPhasesYieldsSingleTasksPhase() {
        let lanes = PlanFlowBuilder.lanes(from: [input(phases: [])])
        XCTAssertEqual(lanes[0].nodes.map(\.id), ["src", "phase-0", "drain"])
        XCTAssertEqual(lanes[0].nodes[1].label, "tasks")
    }

    func testSpecOnlyPlansAreSkipped() {
        XCTAssertTrue(PlanFlowBuilder.lanes(from: [input(status: .specOnly)]).isEmpty)
    }
}
