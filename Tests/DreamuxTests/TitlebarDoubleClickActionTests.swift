import XCTest
@testable import Dreamux

final class TitlebarDoubleClickActionTests: XCTestCase {
    func testMinimizeMapsToMinimize() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Minimize"), .minimize)
    }

    func testNoneMapsToNone() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "None"), TitlebarDoubleClickAction.none)
    }

    func testNilDefaultsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: nil), .zoom)
    }

    func testMaximizeMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Maximize"), .zoom)
    }

    func testFillMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "Fill"), .zoom)
    }

    func testUnrecognizedValueMapsToZoom() {
        XCTAssertEqual(TitlebarDoubleClickAction.from(defaultsValue: "garbage-42"), .zoom)
    }
}
