import XCTest
import SwiftUI
@testable import Dreamux

final class SidebarTileTests: XCTestCase {
    func testCanonicalOrder() {
        XCTAssertEqual(SidebarTile.allCases, [.signals, .browser, .flows, .library])
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(SidebarTile.signals.rawValue, "signals")
        XCTAssertEqual(SidebarTile.browser.rawValue, "browser")
        XCTAssertEqual(SidebarTile.flows.rawValue, "flows")
        XCTAssertEqual(SidebarTile.library.rawValue, "library")
        XCTAssertEqual(SidebarTile.signals.id, "signals")
    }

    func testDisplayMetadata() {
        XCTAssertEqual(SidebarTile.signals.symbol, "waveform.path.ecg")
        XCTAssertEqual(SidebarTile.signals.label, "Signals")
        XCTAssertEqual(SidebarTile.browser.symbol, "globe")
        XCTAssertEqual(SidebarTile.browser.label, "Browser")
        XCTAssertEqual(SidebarTile.flows.symbol, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(SidebarTile.flows.label, "Flows")
        XCTAssertEqual(SidebarTile.library.symbol, "puzzlepiece.extension")
        XCTAssertEqual(SidebarTile.library.label, "Skills & MCPs")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([SidebarTile.browser, .signals, .flows, .library])
        let decoded = try JSONDecoder().decode([SidebarTile].self, from: data)
        XCTAssertEqual(decoded, [.browser, .signals, .flows, .library])
    }
}
