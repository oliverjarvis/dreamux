import XCTest
@testable import Dreamux

final class FlowsCanvasSnapshotTests: XCTestCase {

    // MARK: - Fixtures

    private func planFlow(
        path: String, title: String, nodes: [FlowNode], workspaceID: UUID? = nil
    ) -> Flow {
        Flow(id: "plan-\(path)", title: title, kind: .plan, workspaceID: workspaceID,
             startedAt: Date(timeIntervalSince1970: 1_000), nodes: nodes,
             edges: [FlowEdge(from: nodes[0].id, to: nodes[1].id, kind: .sequence)])
    }

    private func sessionFlow(id: String, status: FlowStatus) -> Flow {
        Flow(id: "session-\(id)", title: id, kind: .adhoc, sessionID: id,
             startedAt: Date(timeIntervalSince1970: 2_000),
             nodes: [FlowNode(id: "src", kind: .source, label: "prompt", status: .done),
                     FlowNode(id: "session", kind: .agent, label: "claude", status: status)],
             edges: [FlowEdge(from: "src", to: "session", kind: .sequence)])
    }

    private func node(_ id: String, _ status: FlowStatus, group: String? = nil) -> FlowNode {
        FlowNode(id: id, kind: .task, label: id, status: status, group: group)
    }

    // MARK: - dependsOn wiring

    func testDependsOnComesFromProjectGraphEdges() {
        let a = planFlow(path: "docs/plans/a.md", title: "A",
                         nodes: [node("t1", .done), node("t2", .done)])
        let b = planFlow(path: "docs/plans/b.md", title: "B",
                         nodes: [node("t1", .queued), node("t2", .queued)])
        let board = FlowsBoard.compose(planLanes: [a, b], sessionLanes: [])
        let graph = ProjectGraph(
            nodes: [FlowNode(id: "plan-docs/plans/a.md", kind: .plan, label: "A", status: .done),
                    FlowNode(id: "plan-docs/plans/b.md", kind: .plan, label: "B", status: .queued)],
            edges: [FlowEdge(from: "plan-docs/plans/a.md",
                             to: "plan-docs/plans/b.md", kind: .dependency)])

        let snapshot = FlowsCanvasSnapshot.make(board: board, projectGraph: graph)
        let laneB = snapshot.lanes.first { $0.id == "plan-docs/plans/b.md" }
        let laneA = snapshot.lanes.first { $0.id == "plan-docs/plans/a.md" }
        XCTAssertEqual(laneB?.dependsOn, ["plan-docs/plans/a.md"])
        XCTAssertEqual(laneA?.dependsOn, [])
        XCTAssertEqual(laneB?.planPath, "docs/plans/b.md")
    }

    func testDependsOnDropsBlockersThatHaveNoLane() {
        // A merged blocker keeps a ProjectGraph node but has no board lane;
        // pointing an edge at a laneless id would strand the dependency.
        let b = planFlow(path: "docs/plans/b.md", title: "B",
                         nodes: [node("t1", .queued), node("t2", .queued)])
        let board = FlowsBoard.compose(planLanes: [b], sessionLanes: [])
        let graph = ProjectGraph(
            nodes: [FlowNode(id: "plan-docs/plans/merged.md", kind: .plan,
                             label: "M", status: .done),
                    FlowNode(id: "plan-docs/plans/b.md", kind: .plan, label: "B", status: .queued)],
            edges: [FlowEdge(from: "plan-docs/plans/merged.md",
                             to: "plan-docs/plans/b.md", kind: .dependency)])

        let snapshot = FlowsCanvasSnapshot.make(board: board, projectGraph: graph)
        XCTAssertEqual(snapshot.lanes.first { $0.id == "plan-docs/plans/b.md" }?.dependsOn, [])
    }

    func testBlockedPropagatesFromProjectGraph() {
        let b = planFlow(path: "docs/plans/b.md", title: "B",
                         nodes: [node("t1", .queued), node("t2", .queued)])
        let board = FlowsBoard.compose(planLanes: [b], sessionLanes: [])
        let graph = ProjectGraph(
            nodes: [FlowNode(id: "plan-docs/plans/a.md", kind: .plan, label: "A", status: .running),
                    FlowNode(id: "plan-docs/plans/b.md", kind: .plan, label: "B", status: .queued)],
            edges: [FlowEdge(from: "plan-docs/plans/a.md",
                             to: "plan-docs/plans/b.md", kind: .dependency)])
        let snapshot = FlowsCanvasSnapshot.make(board: board, projectGraph: graph)
        XCTAssertTrue(snapshot.lanes.first { $0.id == "plan-docs/plans/b.md" }?.blocked == true)
    }

    // MARK: - section, progress, aggregates

    func testSectionCarriesTheSectionKindTheLaneWouldHaveLandedIn() {
        let running = sessionFlow(id: "s-run", status: .running)
        let waiting = sessionFlow(id: "s-wait", status: .waiting)
        let board = FlowsBoard.compose(planLanes: [], sessionLanes: [running, waiting])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))

        XCTAssertEqual(snapshot.lanes.first { $0.id == "session-s-run" }?.section, "running")
        XCTAssertEqual(snapshot.lanes.first { $0.id == "session-s-wait" }?.section, "needsYou")
    }

    func testProgressIsDoneOverTotalNodes() {
        let plan = planFlow(path: "docs/plans/p.md", title: "P",
                            nodes: [node("t1", .done), node("t2", .running)])
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))
        XCTAssertEqual(snapshot.lanes.first?.progress.done, 1)
        XCTAssertEqual(snapshot.lanes.first?.progress.total, 2)
    }

    func testAggregatesMirrorTheBoard() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [sessionFlow(id: "a", status: .running),
                           sessionFlow(id: "b", status: .waiting)])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))
        XCTAssertEqual(snapshot.aggregates.running, board.runningCount)
        XCTAssertEqual(snapshot.aggregates.needsYou, board.needsYouCount)
        XCTAssertEqual(snapshot.schemaVersion, 1)
    }

    // MARK: - lane fields

    func testPRStateAndDetailUnavailablePropagate() {
        let ws = UUID()
        var flow = sessionFlow(id: "s", status: .running)
        flow.workspaceID = ws
        flow.detailUnavailable = true
        let board = FlowsBoard.compose(
            planLanes: [], sessionLanes: [flow],
            prStatesByWorkspace: [ws: PRLaneState(lifecycle: .checksFailed,
                                                  url: "https://example.com/pr/1")])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))
        XCTAssertEqual(snapshot.lanes.first?.prState, "checksFailed")
        XCTAssertEqual(snapshot.lanes.first?.detailUnavailable, true)
    }

    func testAdHocSuppressionDoneByComposeSurvivesTheProjection() {
        // An ad-hoc session on a plan's workspace is folded into the plan
        // lane by `compose`; the snapshot must not resurrect it.
        let ws = UUID()
        let plan = planFlow(path: "docs/plans/p.md", title: "P",
                            nodes: [node("t1", .queued), node("t2", .queued)],
                            workspaceID: ws)
        var session = sessionFlow(id: "engine", status: .running)
        session.workspaceID = ws
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [session])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))
        XCTAssertEqual(snapshot.lanes.count, 1)
        XCTAssertEqual(snapshot.lanes.first?.id, "plan-docs/plans/p.md")
        XCTAssertEqual(snapshot.lanes.first?.status, "running")
    }

    func testNodesCarryGroupMultiplicityAndISO8601Dates() {
        var task = FlowNode(id: "t1", kind: .task, label: "Task 1", status: .running,
                            startedAt: Date(timeIntervalSince1970: 0),
                            endedAt: nil,
                            counters: FlowCounters(multiplicity: 3),
                            lastActivity: "Bash: swift test",
                            group: "Phase A")
        task.label = "Task 1"
        let flow = Flow(id: "plan-docs/plans/p.md", title: "P", kind: .plan,
                        nodes: [task, node("t2", .queued)],
                        edges: [FlowEdge(from: "t1", to: "t1", kind: .loop, iterations: 4)])
        let board = FlowsBoard.compose(planLanes: [flow], sessionLanes: [])
        let snapshot = FlowsCanvasSnapshot.make(
            board: board, projectGraph: ProjectGraph(nodes: [], edges: []))
        let wire = snapshot.lanes.first!.nodes.first!
        XCTAssertEqual(wire.group, "Phase A")
        XCTAssertEqual(wire.multiplicity, 3)
        XCTAssertEqual(wire.lastActivity, "Bash: swift test")
        XCTAssertEqual(wire.startedAt, "1970-01-01T00:00:00Z")
        XCTAssertNil(wire.endedAt)
        // Self-loops survive the projection — the canvas draws them itself.
        XCTAssertEqual(snapshot.lanes.first!.edges.first?.kind, "loop")
        XCTAssertEqual(snapshot.lanes.first!.edges.first?.iterations, 4)
    }

    // MARK: - Equatable (gates pushes) and JSON

    func testEqualBoardsProduceEqualSnapshots() {
        let flow = sessionFlow(id: "s", status: .running)
        let graph = ProjectGraph(nodes: [], edges: [])
        let one = FlowsCanvasSnapshot.make(
            board: FlowsBoard.compose(planLanes: [], sessionLanes: [flow]), projectGraph: graph)
        let two = FlowsCanvasSnapshot.make(
            board: FlowsBoard.compose(planLanes: [], sessionLanes: [flow]), projectGraph: graph)
        XCTAssertEqual(one, two)
    }

    func testStatusChangeMakesSnapshotsUnequal() {
        let graph = ProjectGraph(nodes: [], edges: [])
        let running = FlowsCanvasSnapshot.make(
            board: FlowsBoard.compose(
                planLanes: [], sessionLanes: [sessionFlow(id: "s", status: .running)]),
            projectGraph: graph)
        let waiting = FlowsCanvasSnapshot.make(
            board: FlowsBoard.compose(
                planLanes: [], sessionLanes: [sessionFlow(id: "s", status: .waiting)]),
            projectGraph: graph)
        XCTAssertNotEqual(running, waiting)
    }

    func testJSONStringRoundTrips() throws {
        let snapshot = FlowsCanvasSnapshot.make(
            board: FlowsBoard.compose(
                planLanes: [], sessionLanes: [sessionFlow(id: "s", status: .running)]),
            projectGraph: ProjectGraph(nodes: [], edges: []))
        let json = try XCTUnwrap(snapshot.jsonString())
        let decoded = try JSONDecoder().decode(FlowsCanvasSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, snapshot)
    }
}
