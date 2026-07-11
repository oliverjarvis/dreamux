import XCTest
@testable import Dreamux

final class OverviewModeBStatusTests: XCTestCase {
    func testUnknownWhenNil() {
        XCTAssertNil(OverviewModeBStatus.pill(insertions: nil, deletions: nil))
    }

    func testCleanTree() {
        XCTAssertEqual(OverviewModeBStatus.pill(insertions: 0, deletions: 0),
                       OverviewModeBStatus.Pill(text: "Clean", flow: .done))
    }

    func testInsertionsAreDirty() {
        let p = OverviewModeBStatus.pill(insertions: 12, deletions: 3)
        XCTAssertEqual(p?.text, "Uncommitted changes")
        XCTAssertEqual(p?.flow, .waiting)
    }

    func testDeletionsOnlyAreDirty() {
        let p = OverviewModeBStatus.pill(insertions: 0, deletions: 5)
        XCTAssertEqual(p?.flow, .waiting)
    }
}
