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
        XCTAssertEqual(SidebarTile.signals.label, "Signals")
        XCTAssertEqual(SidebarTile.browser.label, "Browser")
        XCTAssertEqual(SidebarTile.flows.label, "Flows")
        XCTAssertEqual(SidebarTile.library.label, "Skills & MCPs")
    }

    /// The bundled Phosphor PDFs must all resolve — a missing resource
    /// falls back to a questionmark glyph, which `load` guards with an
    /// assertion; constructing every icon exercises those loads.
    func testPhosphorIconsResolve() {
        for tile in SidebarTile.allCases {
            _ = tile.icon
        }
        _ = AppSection.features.icon
        _ = PhosphorIcon.appWindowFill
        _ = PhosphorIcon.caretRightFill
        _ = PhosphorIcon.filesFill
        _ = PhosphorIcon.folderFill
        _ = PhosphorIcon.folderOpenFill
        _ = PhosphorIcon.gitBranchFill
        _ = PhosphorIcon.gitForkFill
        _ = PhosphorIcon.packageFill
        _ = PhosphorIcon.plusFill
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode([SidebarTile.browser, .signals, .flows, .library])
        let decoded = try JSONDecoder().decode([SidebarTile].self, from: data)
        XCTAssertEqual(decoded, [.browser, .signals, .flows, .library])
    }
}
