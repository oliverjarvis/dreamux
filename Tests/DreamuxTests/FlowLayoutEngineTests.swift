import XCTest
@testable import Dreamux

/// `FlowLayoutEngine` delegates to SwiftDagre, so these assert the
/// structural invariants a layered layout must satisfy — rank ordering,
/// no overlaps, chain alignment, routed edge waypoints — rather than exact
/// pixel coordinates (which are dagre's to choose and may shift between
/// versions).
final class FlowLayoutEngineTests: XCTestCase {
    private let nodeWidth = FlowLayoutEngine.nodeSize.width

    // MARK: Chain src→a→drain — ranks stack top to bottom, aligned in x
    func testChainLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done),
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        let src = layout.positions["src"]!
        let a = layout.positions["a"]!
        let drain = layout.positions["drain"]!

        // Top-to-bottom by rank.
        XCTAssertLessThan(src.y, a.y)
        XCTAssertLessThan(a.y, drain.y)
        // A straight chain aligns vertically.
        XCTAssertEqual(src.x, a.x, accuracy: 0.5)
        XCTAssertEqual(a.x, drain.x, accuracy: 0.5)
        // Positive canvas, and every non-self edge is routed.
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertGreaterThanOrEqual(
            layout.edgePoints[FlowLayout.EdgeKey(from: "src", to: "a")]?.count ?? 0, 2)
        XCTAssertGreaterThanOrEqual(
            layout.edgePoints[FlowLayout.EdgeKey(from: "a", to: "drain")]?.count ?? 0, 2)
    }

    // MARK: Fan-out src→{a,b,c}→drain — a,b,c share a rank, don't overlap
    func testFanOutLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "c", kind: .phase, label: "phase c", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done),
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .spawn),
            FlowEdge(from: "src", to: "b", kind: .spawn),
            FlowEdge(from: "src", to: "c", kind: .spawn),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence),
            FlowEdge(from: "c", to: "drain", kind: .sequence),
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        let src = layout.positions["src"]!
        let a = layout.positions["a"]!
        let b = layout.positions["b"]!
        let c = layout.positions["c"]!
        let drain = layout.positions["drain"]!

        // The three siblings share one rank, between src and drain.
        XCTAssertEqual(a.y, b.y, accuracy: 0.5)
        XCTAssertEqual(b.y, c.y, accuracy: 0.5)
        XCTAssertLessThan(src.y, a.y)
        XCTAssertLessThan(a.y, drain.y)

        // No two siblings overlap horizontally (centers ≥ a node-width apart).
        let xs = [a.x, b.x, c.x].sorted()
        XCTAssertGreaterThanOrEqual(xs[1] - xs[0], nodeWidth)
        XCTAssertGreaterThanOrEqual(xs[2] - xs[1], nodeWidth)
    }

    // MARK: Diamond — the longest path sets the drain's rank
    func testDiamondLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done),
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "b", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence),
            FlowEdge(from: "src", to: "drain", kind: .sequence),  // direct short path
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        let src = layout.positions["src"]!
        let a = layout.positions["a"]!
        let b = layout.positions["b"]!
        let drain = layout.positions["drain"]!

        // src→a→b→drain stacks in order; drain sits below b, not beside src.
        XCTAssertLessThan(src.y, a.y)
        XCTAssertLessThan(a.y, b.y)
        XCTAssertLessThan(b.y, drain.y)
    }

    // MARK: Cycle safety — a back-edge must not hang or crash
    func testCycleSafety() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done),
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "a", to: "src", kind: .loop),  // back-edge
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        XCTAssertEqual(layout.positions.count, 3)
        XCTAssertNotNil(layout.positions["src"])
        XCTAssertNotNil(layout.positions["a"])
        XCTAssertNotNil(layout.positions["drain"])
    }

    // MARK: Self-loop is excluded from the routed edges (the view draws it)
    func testSelfLoopExcludedFromEdgePoints() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "session", kind: .phase, label: "claude", status: .running),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .queued),
        ]
        let edges = [
            FlowEdge(from: "src", to: "session", kind: .sequence),
            FlowEdge(from: "session", to: "session", kind: .loop, iterations: 3),
            FlowEdge(from: "session", to: "drain", kind: .sequence),
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        XCTAssertEqual(layout.positions.count, 3)
        XCTAssertNil(layout.edgePoints[FlowLayout.EdgeKey(from: "session", to: "session")])
        XCTAssertGreaterThanOrEqual(
            layout.edgePoints[FlowLayout.EdgeKey(from: "src", to: "session")]?.count ?? 0, 2)
        XCTAssertGreaterThanOrEqual(
            layout.edgePoints[FlowLayout.EdgeKey(from: "session", to: "drain")]?.count ?? 0, 2)
    }

    // MARK: Empty input — zero size, no positions
    func testEmptyLayout() {
        let layout = FlowLayoutEngine.layout(nodes: [], edges: [])
        XCTAssertEqual(layout.positions.count, 0)
        XCTAssertEqual(layout.size, .zero)
        XCTAssertTrue(layout.edgePoints.isEmpty)
    }

    // MARK: Two-column fan-out — positive canvas, no overlap
    func testSizeAndOverlaps() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done),
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .spawn),
            FlowEdge(from: "src", to: "b", kind: .spawn),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence),
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        let a = layout.positions["a"]!
        let b = layout.positions["b"]!
        XCTAssertGreaterThanOrEqual(abs(b.x - a.x), nodeWidth)
    }
}
