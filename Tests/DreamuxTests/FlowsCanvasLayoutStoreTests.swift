import XCTest
@testable import Dreamux

@MainActor
final class FlowsCanvasLayoutStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-canvas-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("flows-canvas.json")
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testRoundTripsPositionsExpansionAndViewport() {
        let url = tempURL(); defer { cleanUp(url) }

        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setLanePositions(["plan-docs/plans/x.md": .init(x: 10, y: 20)])
        store.setNodePositions("plan-docs/plans/x.md", ["task-3": .init(x: 1, y: 2)])
        store.setExpanded(["plan-docs/plans/x.md"])
        store.setViewport(.init(x: -5, y: 6, zoom: 0.8))

        let reloaded = FlowsCanvasLayoutStore(configURL: url)
        XCTAssertEqual(reloaded.payload.lanePositions["plan-docs/plans/x.md"],
                       .init(x: 10, y: 20))
        XCTAssertEqual(reloaded.payload.nodePositions["plan-docs/plans/x.md"]?["task-3"],
                       .init(x: 1, y: 2))
        XCTAssertEqual(reloaded.payload.expandedLaneIDs, ["plan-docs/plans/x.md"])
        XCTAssertEqual(reloaded.payload.viewport, .init(x: -5, y: 6, zoom: 0.8))
    }

    func testCreatesStateDirectoryWithGitignore() {
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setViewport(.init(x: 0, y: 0, zoom: 1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let gitignore = url.deletingLastPathComponent().appendingPathComponent(".gitignore")
        XCTAssertEqual(try? String(contentsOf: gitignore, encoding: .utf8), "*\n")
    }

    func testCorruptFileIsTreatedAsAbsentAndRewrittenOnNextSave() throws {
        let url = tempURL(); defer { cleanUp(url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        let store = FlowsCanvasLayoutStore(configURL: url)
        XCTAssertTrue(store.payload.lanePositions.isEmpty)
        XCTAssertTrue(store.payload.expandedLaneIDs.isEmpty)
        XCTAssertNil(store.payload.viewport)

        store.setExpanded(["plan-a.md"])
        let reloaded = FlowsCanvasLayoutStore(configURL: url)
        XCTAssertEqual(reloaded.payload.expandedLaneIDs, ["plan-a.md"])
    }

    func testExpansionIsCappedOnSetAndOnLoad() throws {
        let url = tempURL(); defer { cleanUp(url) }

        let store = FlowsCanvasLayoutStore(configURL: url)
        // LRU order: most-recent LAST. Over the cap, the OLDEST goes.
        store.setExpanded(["a", "b", "c", "d"])
        XCTAssertEqual(store.payload.expandedLaneIDs, ["b", "c", "d"])
        XCTAssertEqual(FlowsCanvasLayoutStore.expansionCap, 3)

        // A file written by an older/hand-edited version is truncated on load.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"lanePositions":{},"nodePositions":{},"expandedLaneIDs":["p","q","r","s","t"]}"#.utf8)
            .write(to: url)
        XCTAssertEqual(FlowsCanvasLayoutStore(configURL: url).payload.expandedLaneIDs,
                       ["r", "s", "t"])
    }

    func testSetNodePositionsReplacesTheLaneMapSoStaleIDsArePruned() {
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setNodePositions("lane", ["task-1": .init(x: 1, y: 1),
                                        "task-2": .init(x: 2, y: 2)])
        // task-2 has since vanished from the lane; the next save prunes it.
        store.setNodePositions("lane", ["task-1": .init(x: 9, y: 9)])

        let reloaded = FlowsCanvasLayoutStore(configURL: url)
        XCTAssertEqual(reloaded.payload.nodePositions["lane"], ["task-1": .init(x: 9, y: 9)])
    }

    func testUnknownLaneIDsAreKeptNotDeletedOnLoad() {
        // A lane can reappear when its plan is rediscovered; the store never
        // reconciles against a board, so nothing is dropped at load time.
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setLanePositions(["gone.md": .init(x: 3, y: 4)])
        XCTAssertEqual(FlowsCanvasLayoutStore(configURL: url).payload.lanePositions["gone.md"],
                       .init(x: 3, y: 4))
    }

    func testClearLaneDropsThatLanesPositionsOnly() {
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setLanePositions(["a": .init(x: 1, y: 1), "b": .init(x: 2, y: 2)])
        store.setNodePositions("a", ["t": .init(x: 5, y: 5)])
        store.setNodePositions("b", ["t": .init(x: 6, y: 6)])

        store.clearLane("a")
        XCTAssertNil(store.payload.lanePositions["a"])
        XCTAssertNil(store.payload.nodePositions["a"])
        XCTAssertEqual(store.payload.lanePositions["b"], .init(x: 2, y: 2))
        XCTAssertEqual(store.payload.nodePositions["b"]?["t"], .init(x: 6, y: 6))
    }

    func testClearAllDropsEveryPositionButKeepsExpansionAndViewport() {
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setLanePositions(["a": .init(x: 1, y: 1)])
        store.setNodePositions("a", ["t": .init(x: 5, y: 5)])
        store.setExpanded(["a"])
        store.setViewport(.init(x: 0, y: 0, zoom: 2))

        store.clearAll()
        XCTAssertTrue(store.payload.lanePositions.isEmpty)
        XCTAssertTrue(store.payload.nodePositions.isEmpty)
        XCTAssertEqual(store.payload.expandedLaneIDs, ["a"])
        XCTAssertEqual(store.payload.viewport, .init(x: 0, y: 0, zoom: 2))
    }

    func testJSONStringIsRestoreLayoutPayload() throws {
        let url = tempURL(); defer { cleanUp(url) }
        let store = FlowsCanvasLayoutStore(configURL: url)
        store.setLanePositions(["a": .init(x: 1, y: 2)])
        let json = try XCTUnwrap(store.jsonString())
        let decoded = try JSONDecoder().decode(
            FlowsCanvasLayoutStore.Payload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, store.payload)
    }
}
