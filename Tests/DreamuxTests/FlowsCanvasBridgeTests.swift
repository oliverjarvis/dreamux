import XCTest
@testable import Dreamux

final class FlowsCanvasBridgeTests: XCTestCase {

    private func body(_ method: String, _ params: [String: Any]? = nil,
                      id: Int = 1) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "method": method]
        if let params { dict["params"] = params }
        return dict
    }

    // MARK: - Well-formed

    func testParsesReady() {
        XCTAssertEqual(FlowsCanvasBridge.parse(body("ready")), .ready)
    }

    func testParsesSelectNodeWithAndWithoutNodeID() {
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("selectNode", ["laneID": "plan-a.md", "nodeID": "task-3"])),
            .selectNode(laneID: "plan-a.md", nodeID: "task-3"))
        // Absent nodeID means the lane box itself is selected.
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("selectNode", ["laneID": "plan-a.md"])),
            .selectNode(laneID: "plan-a.md", nodeID: nil))
        // Explicit JSON null arrives as NSNull, and must read the same way.
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("selectNode", ["laneID": "plan-a.md", "nodeID": NSNull()])),
            .selectNode(laneID: "plan-a.md", nodeID: nil))
    }

    func testParsesSetLaneExpanded() {
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("setLaneExpanded", ["laneID": "plan-a.md", "expanded": true])),
            .setLaneExpanded(laneID: "plan-a.md", expanded: true))
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("setLaneExpanded", ["laneID": "plan-a.md", "expanded": false])),
            .setLaneExpanded(laneID: "plan-a.md", expanded: false))
    }

    func testParsesSaveNodePositionsForALaneAndForLaneBoxes() {
        let positions: [[String: Any]] = [["id": "task-1", "x": 10.5, "y": -3.0],
                                          ["id": "task-2", "x": 0, "y": 44]]
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("saveNodePositions",
                                         ["laneID": "plan-a.md", "positions": positions])),
            .saveNodePositions(laneID: "plan-a.md", positions: [
                .init(id: "task-1", x: 10.5, y: -3.0),
                .init(id: "task-2", x: 0, y: 44),
            ]))
        // Absent laneID means these are lane-box positions.
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("saveNodePositions", ["positions": positions])),
            .saveNodePositions(laneID: nil, positions: [
                .init(id: "task-1", x: 10.5, y: -3.0),
                .init(id: "task-2", x: 0, y: 44),
            ]))
    }

    func testParsesSaveViewportAndJSError() {
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("saveViewport", ["x": 1, "y": 2, "zoom": 0.75])),
            .saveViewport(.init(x: 1, y: 2, zoom: 0.75)))
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("jsError", ["message": "boom (bundle.js:12)"])),
            .jsError(message: "boom (bundle.js:12)"))
    }

    // MARK: - Malformed

    func testRejectsNonDictionaryAndMissingMethod() {
        XCTAssertNil(FlowsCanvasBridge.parse("not a dict"))
        XCTAssertNil(FlowsCanvasBridge.parse(42))
        XCTAssertNil(FlowsCanvasBridge.parse(["id": 1] as [String: Any]))
        XCTAssertNil(FlowsCanvasBridge.parse(["id": 1, "method": 7] as [String: Any]))
    }

    func testRejectsUnknownMethod() {
        XCTAssertNil(FlowsCanvasBridge.parse(body("fs.read", ["path": "/etc/passwd"])))
        XCTAssertNil(FlowsCanvasBridge.parse(body("")))
    }

    func testRejectsMissingOrWrongTypedParams() {
        XCTAssertNil(FlowsCanvasBridge.parse(body("selectNode")))
        XCTAssertNil(FlowsCanvasBridge.parse(body("selectNode", ["laneID": 3])))
        XCTAssertNil(FlowsCanvasBridge.parse(body("setLaneExpanded", ["laneID": "a"])))
        XCTAssertNil(FlowsCanvasBridge.parse(body("setLaneExpanded",
                                                  ["laneID": "a", "expanded": "yes"])))
        XCTAssertNil(FlowsCanvasBridge.parse(body("saveViewport", ["x": 1, "y": 2])))
        XCTAssertNil(FlowsCanvasBridge.parse(body("jsError", [:])))
    }

    func testRejectsInvalidPositionPayloads() {
        // Missing y.
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveNodePositions", ["positions": [["id": "a", "x": 1]]])))
        // Non-string id.
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveNodePositions", ["positions": [["id": 1, "x": 1, "y": 2]]])))
        // Not an array.
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveNodePositions", ["positions": "nope"])))
        // Non-finite coordinates would poison a saved layout file forever.
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveNodePositions", ["positions": [["id": "a", "x": Double.nan, "y": 0]]])))
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveNodePositions", ["positions": [["id": "a", "x": Double.infinity, "y": 0]]])))
        XCTAssertNil(FlowsCanvasBridge.parse(body(
            "saveViewport", ["x": 0, "y": 0, "zoom": Double.nan])))
    }

    func testEmptyPositionsArrayIsValid() {
        // Dragging every node back and then pruning can legitimately empty
        // a lane's map — that is a save, not a malformed message.
        XCTAssertEqual(
            FlowsCanvasBridge.parse(body("saveNodePositions",
                                         ["laneID": "plan-a.md", "positions": [[String: Any]]()])),
            .saveNodePositions(laneID: "plan-a.md", positions: []))
    }

    func testKnownMethodsIsExactlyTheSixDocumentedOnes() {
        XCTAssertEqual(FlowsCanvasBridge.knownMethods, [
            "ready", "selectNode", "setLaneExpanded",
            "saveNodePositions", "saveViewport", "jsError",
        ])
    }
}
