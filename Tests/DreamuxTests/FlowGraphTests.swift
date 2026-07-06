import XCTest
@testable import Dreamux

final class FlowGraphTests: XCTestCase {
    private func node(_ id: String, _ status: FlowStatus) -> FlowNode {
        FlowNode(id: id, kind: .agent, label: id, status: status)
    }

    func testAggregateStatusPrecedence() {
        // waiting > running > failed > queued > done
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .done), node("b", .waiting), node("c", .running)]), .waiting)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .running), node("b", .failed)]), .running)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .failed), node("b", .queued), node("c", .done)]), .failed)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .queued), node("b", .done)]), .queued)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .done)]), .done)
        XCTAssertEqual(Flow.aggregateStatus(of: []), .done)
    }

    func testFlowStatusUsesAggregate() {
        var flow = Flow(id: "f1", title: "t", kind: .adhoc)
        flow.nodes = [node("a", .running)]
        XCTAssertEqual(flow.status, .running)
    }

    func testCodableRoundTrip() throws {
        var flow = Flow(id: "f1", title: "t", kind: .scheduled)
        flow.workspaceID = UUID()
        flow.sessionID = "s-1"
        flow.detail = "permission: npm run e2e"
        flow.nodes = [FlowNode(id: "n1", kind: .gate, label: "gate", status: .waiting)]
        flow.edges = [FlowEdge(from: "src", to: "n1", kind: .sequence, label: "3 findings", iterations: nil)]
        let data = try JSONEncoder().encode(flow)
        let back = try JSONDecoder().decode(Flow.self, from: data)
        XCTAssertEqual(back, flow)
    }
}
