import XCTest
@testable import Dreamux

final class PipVisibilityPolicyTests: XCTestCase {

    /// The default: Dreamux is somewhere behind another app and the pips
    /// are doing their job.
    func testVisibleWhenTheWindowIsOpenAndTheAppIsNotHidden() {
        XCTAssertTrue(
            PipVisibilityPolicy.shouldShow(windowMiniaturized: false, appHidden: false))
    }

    func testHiddenWhenTheWindowIsMinimized() {
        XCTAssertFalse(
            PipVisibilityPolicy.shouldShow(windowMiniaturized: true, appHidden: false))
    }

    /// Command-H means "get out of my way", and that has to include the
    /// floating panels.
    func testHiddenWhenTheAppIsHidden() {
        XCTAssertFalse(
            PipVisibilityPolicy.shouldShow(windowMiniaturized: false, appHidden: true))
    }

    func testHiddenWhenBoth() {
        XCTAssertFalse(
            PipVisibilityPolicy.shouldShow(windowMiniaturized: true, appHidden: true))
    }
}
