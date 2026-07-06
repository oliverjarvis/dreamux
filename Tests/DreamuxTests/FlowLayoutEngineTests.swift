import XCTest
@testable import Dreamux

final class FlowLayoutEngineTests: XCTestCase {
    /// Constants for coordinate derivation.
    /// y(rank) = margin + rank * (nodeSize.height + rankGap) + nodeSize.height/2
    /// where margin = 24, nodeSize.height = 44, rankGap = 56
    /// x centers spread symmetrically around size.width/2

    // MARK: Test 1 — Chain src→a→drain: three ranks, equal x, y increasing
    func testChainLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done)
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "drain", kind: .sequence)
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        // y(rank) = margin + rank * (nodeSize.height + rankGap) + nodeSize.height/2
        // margin = 24, nodeSize.height = 44, rankGap = 56
        // rank 0: y = 24 + 0 * (44 + 56) + 22 = 46
        // rank 1: y = 24 + 1 * (44 + 56) + 22 = 146
        // rank 2: y = 24 + 2 * (44 + 56) + 22 = 246
        let expectedY0 = CGFloat(24 + 0 * (44 + 56) + 22)  // 46
        let expectedY1 = CGFloat(24 + 1 * (44 + 56) + 22)  // 146
        let expectedY2 = CGFloat(24 + 2 * (44 + 56) + 22)  // 246

        let srcPos = layout.positions["src"]!
        let aPos = layout.positions["a"]!
        let drainPos = layout.positions["drain"]!

        // All three should have same x (centered)
        XCTAssertEqual(srcPos.x, aPos.x)
        XCTAssertEqual(aPos.x, drainPos.x)

        // Y should match rank-based formula
        XCTAssertEqual(srcPos.y, expectedY0)
        XCTAssertEqual(aPos.y, expectedY1)
        XCTAssertEqual(drainPos.y, expectedY2)
    }

    // MARK: Test 2 — Fan-out src→{a,b,c}→drain: a,b,c share rank, ordered by id
    func testFanOutLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "c", kind: .phase, label: "phase c", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done)
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .spawn),
            FlowEdge(from: "src", to: "b", kind: .spawn),
            FlowEdge(from: "src", to: "c", kind: .spawn),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence),
            FlowEdge(from: "c", to: "drain", kind: .sequence)
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        // y(rank) formulas
        let expectedY0 = CGFloat(24 + 0 * (44 + 56) + 22)  // 46
        let expectedY1 = CGFloat(24 + 1 * (44 + 56) + 22)  // 146
        let expectedY2 = CGFloat(24 + 2 * (44 + 56) + 22)  // 246

        let srcPos = layout.positions["src"]!
        let aPos = layout.positions["a"]!
        let bPos = layout.positions["b"]!
        let cPos = layout.positions["c"]!
        let drainPos = layout.positions["drain"]!

        // src at rank 0
        XCTAssertEqual(srcPos.y, expectedY0)

        // a, b, c at same rank (rank 1)
        XCTAssertEqual(aPos.y, expectedY1)
        XCTAssertEqual(bPos.y, expectedY1)
        XCTAssertEqual(cPos.y, expectedY1)

        // drain at rank 2
        XCTAssertEqual(drainPos.y, expectedY2)

        // a, b, c should be ordered by id and spread horizontally
        // Check they don't overlap: pairwise distance >= nodeSize.width + siblingGap
        let minDistance: CGFloat = 150 + 18  // nodeSize.width + siblingGap = 168
        XCTAssertGreaterThanOrEqual(abs(bPos.x - aPos.x), minDistance)
        XCTAssertGreaterThanOrEqual(abs(cPos.x - bPos.x), minDistance)
    }

    // MARK: Test 3 — Diamond: longest path determines drain rank
    func testDiamondLayout() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done)
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "b", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence),
            FlowEdge(from: "src", to: "drain", kind: .sequence)  // Direct path
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        // y(rank) formulas
        let expectedY0 = CGFloat(24 + 0 * (44 + 56) + 22)  // 46
        let expectedY1 = CGFloat(24 + 1 * (44 + 56) + 22)  // 146
        let expectedY2 = CGFloat(24 + 2 * (44 + 56) + 22)  // 246
        let expectedY3 = CGFloat(24 + 3 * (44 + 56) + 22)  // 346

        let srcPos = layout.positions["src"]!
        let aPos = layout.positions["a"]!
        let bPos = layout.positions["b"]!
        let drainPos = layout.positions["drain"]!

        // src at rank 0
        XCTAssertEqual(srcPos.y, expectedY0)
        // a at rank 1
        XCTAssertEqual(aPos.y, expectedY1)
        // b at rank 2
        XCTAssertEqual(bPos.y, expectedY2)
        // drain at rank 3 (longest path src→a→b→drain, not the short src→drain)
        XCTAssertEqual(drainPos.y, expectedY3)
    }

    // MARK: Test 4 — Cycle safety: loop edge must not hang
    func testCycleSafety() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done)
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .sequence),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "a", to: "src", kind: .loop)  // Back-edge, should not crash
        ]

        // Should not hang or crash
        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        // All nodes should be positioned
        XCTAssertEqual(layout.positions.count, 3)
        XCTAssertNotNil(layout.positions["src"])
        XCTAssertNotNil(layout.positions["a"])
        XCTAssertNotNil(layout.positions["drain"])
    }

    // MARK: Test 5 — Empty input: zero size, empty positions
    func testEmptyLayout() {
        let layout = FlowLayoutEngine.layout(nodes: [], edges: [])

        XCTAssertEqual(layout.positions.count, 0)
        XCTAssertEqual(layout.size, CGSize(width: 0, height: 0))
    }

    // MARK: Test 6 — Size calculation and no overlaps
    func testSizeAndOverlaps() {
        let nodes = [
            FlowNode(id: "src", kind: .source, label: "source", status: .done),
            FlowNode(id: "a", kind: .phase, label: "phase a", status: .done),
            FlowNode(id: "b", kind: .phase, label: "phase b", status: .done),
            FlowNode(id: "drain", kind: .drain, label: "drain", status: .done)
        ]
        let edges = [
            FlowEdge(from: "src", to: "a", kind: .spawn),
            FlowEdge(from: "src", to: "b", kind: .spawn),
            FlowEdge(from: "a", to: "drain", kind: .sequence),
            FlowEdge(from: "b", to: "drain", kind: .sequence)
        ]

        let layout = FlowLayoutEngine.layout(nodes: nodes, edges: edges)

        // Size should be max extent + one nodeSize margin (nodeSize = 150x44)
        // Height: max y + nodeSize.height/2 + 24 margin
        // Width: calculated based on node positions
        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)

        // Verify no overlaps: pairwise distance >= nodeSize.width + siblingGap for same rank
        let aPos = layout.positions["a"]!
        let bPos = layout.positions["b"]!
        let minDistance: CGFloat = 150 + 18
        XCTAssertGreaterThanOrEqual(abs(bPos.x - aPos.x), minDistance)
    }
}
