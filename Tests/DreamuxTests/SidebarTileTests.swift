import XCTest
import SwiftUI
@testable import Dreamux

final class SidebarTileTests: XCTestCase {
    func testCanonicalOrder() {
        XCTAssertEqual(SidebarTile.allCases, [.signals, .flows, .library])
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(SidebarTile.signals.rawValue, "signals")
        XCTAssertEqual(SidebarTile.flows.rawValue, "flows")
        XCTAssertEqual(SidebarTile.library.rawValue, "library")
        XCTAssertEqual(SidebarTile.signals.id, "signals")
    }

    /// Every pinned tile is a destination now — the retired `browser`
    /// case was a verb in a list of nouns (spec: Strand 1).
    func testRetiredBrowserRawValueNoLongerDecodes() {
        XCTAssertNil(SidebarTile(rawValue: "browser"))
    }

    func testDisplayMetadata() {
        XCTAssertEqual(SidebarTile.signals.label, "Signals")
        XCTAssertEqual(SidebarTile.flows.label, "Flows")
        XCTAssertEqual(SidebarTile.library.label, "Context & MCPs")
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
        let data = try JSONEncoder().encode([SidebarTile.library, .signals, .flows])
        let decoded = try JSONDecoder().decode([SidebarTile].self, from: data)
        XCTAssertEqual(decoded, [.library, .signals, .flows])
    }
}
