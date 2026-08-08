import XCTest
@testable import Dreamux

@MainActor
final class FlowsCanvasSessionTests: XCTestCase {

    /// Records the lazy-tail seam calls without a FlowTailerPool.
    private final class TailSpy {
        var began: [(sessionID: String, cwd: String?)] = []
        var ended: [String] = []
    }

    private func tempConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-session-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("flows-canvas.json")
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func makeSession(
        _ url: URL, _ spy: TailSpy
    ) -> (FlowsCanvasSession, FlowsCanvasLayoutStore) {
        let store = FlowsCanvasLayoutStore(configURL: url)
        let session = FlowsCanvasSession(
            layout: store,
            beginTail: { sessionID, cwd in spy.began.append((sessionID, cwd)) },
            endTail: { sessionID in spy.ended.append(sessionID) }
        )
        return (session, store)
    }

    private func sessionLane(_ id: String, status: FlowStatus, cwd: String? = "/w/\(UUID())") -> Flow {
        Flow(id: "session-\(id)", title: id, kind: .adhoc, sessionID: id, sessionCwd: cwd,
             startedAt: Date(timeIntervalSince1970: 1),
             nodes: [FlowNode(id: "src", kind: .source, label: "prompt", status: .done),
                     FlowNode(id: "session", kind: .agent, label: "claude", status: status)],
             edges: [FlowEdge(from: "src", to: "session", kind: .sequence)])
    }

    private func board(_ flows: [Flow]) -> FlowsBoard {
        FlowsBoard.compose(planLanes: [], sessionLanes: flows)
    }

    private let emptyGraph = ProjectGraph(nodes: [], edges: [])

    // MARK: - Push discipline

    func testUpdateStoresSnapshotAndBoard() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, _) = makeSession(url, TailSpy())

        session.update(board: board([sessionLane("a", status: .running)]),
                       projectGraph: emptyGraph)
        XCTAssertEqual(session.snapshot?.lanes.count, 1)
        XCTAssertEqual(session.snapshot?.aggregates.running, 1)
        XCTAssertNotNil(session.board)
    }

    func testRepeatedIdenticalUpdatesDoNotBumpThePushCounter() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, _) = makeSession(url, TailSpy())
        let same = board([sessionLane("a", status: .running, cwd: "/w/a")])

        session.update(board: same, projectGraph: emptyGraph)
        let afterFirst = session.pushCount
        session.update(board: same, projectGraph: emptyGraph)
        session.update(board: same, projectGraph: emptyGraph)

        // `FlowsOverviewView` used to recompose the board on every SwiftUI
        // render pass; forwarding that cadence into a web view is a flood.
        XCTAssertEqual(session.pushCount, afterFirst)
    }

    func testARealChangePushesAgain() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, _) = makeSession(url, TailSpy())

        session.update(board: board([sessionLane("a", status: .running, cwd: "/w/a")]),
                       projectGraph: emptyGraph)
        let afterFirst = session.pushCount
        session.update(board: board([sessionLane("a", status: .waiting, cwd: "/w/a")]),
                       projectGraph: emptyGraph)

        XCTAssertEqual(session.pushCount, afterFirst + 1)
    }

    // MARK: - Expansion cap, LRU, and the lazy tail seam

    func testExpandingBeginsTheLazyTailWithTheLanesCwd() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let spy = TailSpy()
        let (session, _) = makeSession(url, spy)
        session.update(board: board([sessionLane("a", status: .running, cwd: "/w/a")]),
                       projectGraph: emptyGraph)

        session.handle(.setLaneExpanded(laneID: "session-a", expanded: true))

        XCTAssertEqual(session.expandedLaneIDs, ["session-a"])
        XCTAssertEqual(spy.began.count, 1)
        XCTAssertEqual(spy.began.first?.sessionID, "a")
        XCTAssertEqual(spy.began.first?.cwd, "/w/a")
    }

    func testCollapsingReleasesTheTail() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let spy = TailSpy()
        let (session, _) = makeSession(url, spy)
        session.update(board: board([sessionLane("a", status: .running)]), projectGraph: emptyGraph)

        session.handle(.setLaneExpanded(laneID: "session-a", expanded: true))
        session.handle(.setLaneExpanded(laneID: "session-a", expanded: false))

        XCTAssertEqual(session.expandedLaneIDs, [])
        XCTAssertEqual(spy.ended, ["a"])
    }

    func testExpansionIsCappedAtThreeAndLRUCollapseReleasesItsTail() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let spy = TailSpy()
        let (session, _) = makeSession(url, spy)
        session.update(
            board: board(["a", "b", "c", "d"].map { sessionLane($0, status: .running) }),
            projectGraph: emptyGraph)

        for id in ["a", "b", "c", "d"] {
            session.handle(.setLaneExpanded(laneID: "session-\(id)", expanded: true))
        }

        XCTAssertEqual(session.expandedLaneIDs, ["session-b", "session-c", "session-d"])
        // The oldest was LRU-collapsed, and released its tail the same way
        // an explicit collapse would.
        XCTAssertEqual(spy.ended, ["a"])
        XCTAssertEqual(spy.began.map(\.sessionID), ["a", "b", "c", "d"])
    }

    func testExpandingALaneWithNoSessionIDNeverTouchesTheTailSeam() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let spy = TailSpy()
        let (session, _) = makeSession(url, spy)
        let planLane = Flow(id: "plan-docs/plans/p.md", title: "P", kind: .plan,
                            nodes: [FlowNode(id: "t1", kind: .task, label: "t1", status: .queued)])
        session.update(board: FlowsBoard.compose(planLanes: [planLane], sessionLanes: []),
                       projectGraph: emptyGraph)

        session.handle(.setLaneExpanded(laneID: "plan-docs/plans/p.md", expanded: true))

        XCTAssertEqual(session.expandedLaneIDs, ["plan-docs/plans/p.md"])
        XCTAssertTrue(spy.began.isEmpty)
    }

    func testExpansionIsPersisted() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, store) = makeSession(url, TailSpy())
        session.update(board: board([sessionLane("a", status: .running)]), projectGraph: emptyGraph)

        session.handle(.setLaneExpanded(laneID: "session-a", expanded: true))
        XCTAssertEqual(store.payload.expandedLaneIDs, ["session-a"])
        XCTAssertEqual(FlowsCanvasLayoutStore(configURL: url).payload.expandedLaneIDs,
                       ["session-a"])
    }

    // MARK: - Selection

    func testSelectNodeDrivesTheNativeInspector() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, _) = makeSession(url, TailSpy())

        session.handle(.selectNode(laneID: "session-a", nodeID: "session"))
        XCTAssertEqual(session.selection, FlowsCanvasSelection(laneID: "session-a", nodeID: "session"))

        // A lane box selected: nodeID nil means the lane itself.
        session.handle(.selectNode(laneID: "session-a", nodeID: nil))
        XCTAssertEqual(session.selection, FlowsCanvasSelection(laneID: "session-a", nodeID: nil))

        // An empty laneID is the canvas's "nothing selected" report.
        session.handle(.selectNode(laneID: "", nodeID: nil))
        XCTAssertNil(session.selection)
    }

    // MARK: - Position and viewport persistence

    func testSaveNodePositionsWritesPerLaneAndLaneBoxes() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, store) = makeSession(url, TailSpy())

        session.handle(.saveNodePositions(laneID: "session-a", positions: [
            .init(id: "session", x: 4, y: 5),
        ]))
        session.handle(.saveNodePositions(laneID: nil, positions: [
            .init(id: "session-a", x: 100, y: 200),
        ]))

        XCTAssertEqual(store.payload.nodePositions["session-a"]?["session"], .init(x: 4, y: 5))
        XCTAssertEqual(store.payload.lanePositions["session-a"], .init(x: 100, y: 200))
    }

    func testSaveViewportIsPersisted() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, store) = makeSession(url, TailSpy())
        session.handle(.saveViewport(.init(x: 1, y: 2, zoom: 0.5)))
        XCTAssertEqual(store.payload.viewport, .init(x: 1, y: 2, zoom: 0.5))
    }

    // MARK: - Errors and tidy up

    func testJSErrorSurfacesAndReloadClearsIt() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, _) = makeSession(url, TailSpy())

        session.handle(.jsError(message: "boom (bundle.js:1)"))
        XCTAssertEqual(session.lastJSError, "boom (bundle.js:1)")

        session.reload()
        XCTAssertNil(session.lastJSError)
    }

    func testTidyUpClearsOneLaneOrTheWholeBoard() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        let (session, store) = makeSession(url, TailSpy())
        session.handle(.saveNodePositions(laneID: "lane-a", positions: [.init(id: "t", x: 1, y: 1)]))
        session.handle(.saveNodePositions(laneID: "lane-b", positions: [.init(id: "t", x: 2, y: 2)]))
        session.handle(.saveNodePositions(laneID: nil, positions: [
            .init(id: "lane-a", x: 9, y: 9), .init(id: "lane-b", x: 8, y: 8),
        ]))

        session.tidyUp(laneID: "lane-a")
        XCTAssertNil(store.payload.nodePositions["lane-a"])
        XCTAssertNotNil(store.payload.nodePositions["lane-b"])

        session.tidyUp(laneID: nil)
        XCTAssertTrue(store.payload.nodePositions.isEmpty)
        XCTAssertTrue(store.payload.lanePositions.isEmpty)
    }

    // MARK: - Restore

    func testRestoreOnReadyReExpandsSavedLanesAndSubscribesTheirTails() {
        let url = tempConfigURL(); defer { cleanUp(url) }
        // Five saved, truncated to the three-lane cap on load.
        let seeded = FlowsCanvasLayoutStore(configURL: url)
        seeded.setExpanded(["session-a", "session-b", "session-c", "session-d", "session-e"])

        let spy = TailSpy()
        let (session, _) = makeSession(url, spy)
        session.update(
            board: board(["a", "b", "c", "d", "e"].map { sessionLane($0, status: .running) }),
            projectGraph: emptyGraph)

        session.handle(.ready)

        XCTAssertEqual(session.expandedLaneIDs, ["session-c", "session-d", "session-e"])
        XCTAssertEqual(spy.began.map(\.sessionID).sorted(), ["c", "d", "e"])
    }

    func testUnknownMessagesAreNeverConstructedByTheParser() {
        // The session only ever sees parsed messages; malformed input is
        // dropped one layer up. Pinned here so the two stay in lockstep.
        XCTAssertNil(FlowsCanvasBridge.parse(["method": "definitelyNotAMethod"] as [String: Any]))
    }
}
