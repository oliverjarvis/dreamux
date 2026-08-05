import XCTest
import GhosttyTheme
@testable import Dreamux

final class TerminalThemePresetsTests: XCTestCase {

    func testCatalogIsTheFullBundledSet() {
        XCTAssertEqual(TerminalThemePresets.count, 485)
    }

    func testSearchIsCaseInsensitiveAndSubstringBased() {
        let hits = TerminalThemePresets.search("catppuccin")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.name.lowercased().contains("catppuccin") })
    }

    func testEmptySearchReturnsEverything() {
        XCTAssertEqual(TerminalThemePresets.search("").count, TerminalThemePresets.count)
    }

    func testDefinitionsNormalizeToHashPrefixedUppercaseHex() throws {
        let c64 = try XCTUnwrap(GhosttyThemeCatalog.theme(named: "C64"))
        let spec = TerminalThemePresets.colorSpec(from: c64)
        XCTAssertEqual(spec.background, "#40318D")
        XCTAssertEqual(spec.foreground, "#7869C4")
        XCTAssertEqual(spec.cursorColor, "#7869C4")
        XCTAssertEqual(spec.cursorText, "#40318D")
        XCTAssertEqual(spec.selectionBackground, "#7869C4")
        XCTAssertEqual(spec.selectionForeground, "#40318D")
        XCTAssertEqual(spec.palette.count, 16)
        XCTAssertEqual(spec.palette[0], "#090300")
        XCTAssertEqual(spec.palette[15], "#F7F7F7")
    }

    func testMissingOptionalsStayAutomaticAndMissingPaletteSlotsUseTheSeed() {
        let sparse = GhosttyThemeDefinition(
            name: "Sparse",
            background: "101010",
            foreground: "EEEEEE",
            palette: [0: "000000"]
        )
        let spec = TerminalThemePresets.colorSpec(from: sparse)
        XCTAssertEqual(spec.background, "#101010")
        XCTAssertNil(spec.cursorColor)
        XCTAssertNil(spec.boldColor, "no theme in the catalog carries a bold color")
        XCTAssertEqual(spec.palette[0], "#000000")
        XCTAssertEqual(spec.palette[7], TerminalColorSpec.seedPalette[7])
    }

    func testEveryCatalogThemeProducesASanitizedSpec() {
        for definition in TerminalThemePresets.search("") {
            let spec = TerminalThemePresets.colorSpec(from: definition)
            XCTAssertEqual(spec, spec.sanitized(), "\(definition.name) needs sanitizing")
        }
    }
}
