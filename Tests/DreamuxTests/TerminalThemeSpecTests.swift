import XCTest
@testable import Dreamux

final class TerminalThemeSpecTests: XCTestCase {

    // MARK: - the seed

    func testSeedMatchesGhosttyDefaultsAndTodaysTypography() {
        let seed = TerminalThemeSpec.seed
        XCTAssertEqual(seed.dark, seed.light, "both variants seed identically")
        XCTAssertEqual(seed.dark.background, "#282C34")
        XCTAssertEqual(seed.dark.foreground, "#FFFFFF")
        XCTAssertNil(seed.dark.cursorColor, "ghostty has no default; nil = Automatic")
        XCTAssertNil(seed.dark.cursorText)
        XCTAssertNil(seed.dark.selectionBackground)
        XCTAssertNil(seed.dark.selectionForeground)
        XCTAssertNil(seed.dark.boldColor)
        XCTAssertEqual(seed.dark.palette.count, 16)
        XCTAssertEqual(seed.dark.palette.first, "#1D1F21")
        XCTAssertEqual(seed.dark.palette.last, "#EAEAEA")
        // Typography reproduces what TabSession hard-coded before this feature.
        XCTAssertNil(seed.fontFamily)
        XCTAssertEqual(seed.fontSize, 14)
        XCTAssertEqual(seed.cursorStyle, .bar)
        XCTAssertTrue(seed.cursorBlink)
    }

    // MARK: - hex normalization

    func testNormalizedHexAcceptsBothFormsAndRejectsGarbage() {
        XCTAssertEqual(TerminalColorSpec.normalizedHex("1d1f21"), "#1D1F21")
        XCTAssertEqual(TerminalColorSpec.normalizedHex("#1d1f21"), "#1D1F21")
        XCTAssertEqual(TerminalColorSpec.normalizedHex("  #AABBCC "), "#AABBCC")
        XCTAssertNil(TerminalColorSpec.normalizedHex(nil))
        XCTAssertNil(TerminalColorSpec.normalizedHex(""))
        XCTAssertNil(TerminalColorSpec.normalizedHex("#12345"))
        XCTAssertNil(TerminalColorSpec.normalizedHex("#12345G"))
        XCTAssertNil(TerminalColorSpec.normalizedHex("rebeccapurple"))
    }

    // MARK: - decode fallbacks

    func testAbsentGarbageAndPartialJSONAllDecodeToSeed() {
        XCTAssertEqual(TerminalThemeSpec.decode(nil), .seed)
        XCTAssertEqual(TerminalThemeSpec.decode(Data("not json".utf8)), .seed)
        XCTAssertEqual(
            TerminalThemeSpec.decode(Data(#"{"fontSize": 12}"#.utf8)),
            .seed,
            "a spec missing whole variants is never partially applied"
        )
    }

    func testRoundTripIsStable() throws {
        var spec = TerminalThemeSpec.seed
        spec.light.background = "#FFFFFF"
        spec.light.cursorColor = "#007ACC"
        spec.fontFamily = "SF Mono"
        spec.fontSize = 13.5
        spec.cursorStyle = .underline
        spec.cursorBlink = false
        let data = try XCTUnwrap(spec.encoded())
        XCTAssertEqual(TerminalThemeSpec.decode(data), spec)
    }

    // MARK: - sanitization

    func testShortPalettePadsFromSeedAndLongPaletteTruncates() {
        var short = TerminalColorSpec.seed
        short.palette = ["#111111", "#222222"]
        let padded = short.sanitized()
        XCTAssertEqual(padded.palette.count, 16)
        XCTAssertEqual(padded.palette[0], "#111111")
        XCTAssertEqual(padded.palette[1], "#222222")
        XCTAssertEqual(padded.palette[2], TerminalColorSpec.seedPalette[2])

        var long = TerminalColorSpec.seed
        long.palette = Array(repeating: "#333333", count: 20)
        XCTAssertEqual(long.sanitized().palette.count, 16)
    }

    func testSanitizeNormalizesCaseAndDropsUnparseableColors() {
        var spec = TerminalColorSpec.seed
        spec.background = "1d1f21"
        spec.foreground = "banana"
        spec.cursorColor = "not a color"
        spec.selectionBackground = "abcdef"
        spec.palette[3] = "zzzzzz"
        let clean = spec.sanitized()
        XCTAssertEqual(clean.background, "#1D1F21")
        XCTAssertEqual(clean.foreground, TerminalColorSpec.seed.foreground,
                       "an unparseable required color falls back to the seed's")
        XCTAssertNil(clean.cursorColor, "an unparseable optional color becomes Automatic")
        XCTAssertEqual(clean.selectionBackground, "#ABCDEF")
        XCTAssertEqual(clean.palette[3], TerminalColorSpec.seedPalette[3])
    }

    func testFontSizeIsClampedOnSanitize() {
        var small = TerminalThemeSpec.seed
        small.fontSize = 2
        XCTAssertEqual(small.sanitized().fontSize, 8)

        var big = TerminalThemeSpec.seed
        big.fontSize = 400
        XCTAssertEqual(big.sanitized().fontSize, 32)
    }

    func testEmptyFontFamilyBecomesNil() {
        var spec = TerminalThemeSpec.seed
        spec.fontFamily = "   "
        XCTAssertNil(spec.sanitized().fontFamily)
    }

    func testVariantSubscriptReadsAndWrites() {
        var spec = TerminalThemeSpec.seed
        spec[.light].background = "#FFFFFF"
        XCTAssertEqual(spec[.light].background, "#FFFFFF")
        XCTAssertEqual(spec[.dark].background, "#282C34")
    }
}
