import XCTest
@testable import Dreamux

final class PlanStatusFlowTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(PlanStatus.running.flowStatus, .running)
        XCTAssertEqual(PlanStatus.awaitingReview.flowStatus, .waiting)
        XCTAssertEqual(PlanStatus.merged.flowStatus, .done)
        XCTAssertEqual(PlanStatus.inProgress.flowStatus, .queued)
        XCTAssertEqual(PlanStatus.ready.flowStatus, .queued)
        XCTAssertEqual(PlanStatus.specOnly.flowStatus, .queued)
    }
}
