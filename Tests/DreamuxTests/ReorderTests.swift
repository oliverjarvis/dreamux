import XCTest
@testable import Dreamux

private struct Item: Identifiable, Equatable { let id: String }

final class ReorderTests: XCTestCase {
    private let items = [Item(id: "A"), Item(id: "B"), Item(id: "C")]

    func testMoveFirstOntoLast() {
        let out = Reorder.moved(items, draggingID: "A", overID: "C").map(\.id)
        XCTAssertEqual(out, ["B", "C", "A"])
    }

    func testMoveLastOntoFirst() {
        let out = Reorder.moved(items, draggingID: "C", overID: "A").map(\.id)
        XCTAssertEqual(out, ["C", "A", "B"])
    }

    func testMoveAdjacentSwaps() {
        let out = Reorder.moved(items, draggingID: "A", overID: "B").map(\.id)
        XCTAssertEqual(out, ["B", "A", "C"])
    }

    func testSameItemIsNoOp() {
        XCTAssertEqual(Reorder.moved(items, draggingID: "B", overID: "B"), items)
    }

    func testUnknownIdIsNoOp() {
        XCTAssertEqual(Reorder.moved(items, draggingID: "Z", overID: "A"), items)
    }
}
