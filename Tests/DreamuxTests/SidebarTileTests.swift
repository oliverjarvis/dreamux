import XCTest
import SwiftUI
@testable import Dreamux

final class SidebarTileTests: XCTestCase {
    func testCanonicalOrder() {
        XCTAssertEqual(SidebarTile.allCases, [.signals, .browser])
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(SidebarTile.signals.rawValue, "signals")
        XCTAssertEqual(SidebarTile.browser.rawValue, "browser")
        XCTAssertEqual(SidebarTile.signals.id, "signals")
    }

    func testDisplayMetadata() {
        XCTAssertEqual(SidebarTile.signals.symbol, "waveform.path.ecg")
        XCTAssertEqual(SidebarTile.signals.label, "Signals")
        XCTAssertEqual(SidebarTile.browser.symbol, "globe")
        XCTAssertEqual(SidebarTile.browser.label, "Browser")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([SidebarTile.browser, .signals])
        let decoded = try JSONDecoder().decode([SidebarTile].self, from: data)
        XCTAssertEqual(decoded, [.browser, .signals])
    }
}
