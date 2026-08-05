import XCTest
@testable import Dreamux

final class TerminalThemeRendererTests: XCTestCase {

    private func render(
        _ spec: TerminalThemeSpec,
        variant: TerminalAppearanceVariant = .dark,
        opacity: Double = 1.0
    ) -> [(key: String, value: String)] {
        TerminalThemeRenderer.lines(for: spec, variant: variant, opacity: opacity)
    }

    private func value(_ key: TerminalConfigKey, in lines: [(key: String, value: String)]) -> String? {
        lines.first { $0.key == key.rawValue }?.value
    }

    func testSeedEmitsExactlyTheExpectedKeySet() {
        let keys = render(.seed).map(\.key)
        // background, foreground, 16 palette lines, font-size,
        // cursor-style, cursor-style-blink. Nothing else: the five
        // optional colors are Automatic, font-family is unset, and
        // opacity is 1.0.
        XCTAssertEqual(keys.filter { $0 == "palette" }.count, 16)
        XCTAssertEqual(
            Set(keys),
            ["background", "foreground", "palette", "font-size",
             "cursor-style", "cursor-style-blink"]
        )
    }

    func testColorsRenderUppercaseHexForTheRequestedVariant() {
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "#101010"
        spec.light.background = "#FAFAFA"
        XCTAssertEqual(value(.background, in: render(spec, variant: .dark)), "#101010")
        XCTAssertEqual(value(.background, in: render(spec, variant: .light)), "#FAFAFA")
    }

    func testOptionalColorsAreOmittedWhenAutomaticAndEmittedWhenSet() {
        XCTAssertNil(value(.cursorColor, in: render(.seed)))
        XCTAssertNil(value(.boldColor, in: render(.seed)))

        var spec = TerminalThemeSpec.seed
        spec.dark.cursorColor = "#F5E0DC"
        spec.dark.cursorText = "#1E1E2E"
        spec.dark.selectionBackground = "#414559"
        spec.dark.selectionForeground = "#CDD6F4"
        spec.dark.boldColor = "#FFFFFF"
        let lines = render(spec)
        XCTAssertEqual(value(.cursorColor, in: lines), "#F5E0DC")
        XCTAssertEqual(value(.cursorText, in: lines), "#1E1E2E")
        XCTAssertEqual(value(.selectionBackground, in: lines), "#414559")
        XCTAssertEqual(value(.selectionForeground, in: lines), "#CDD6F4")
        XCTAssertEqual(value(.boldColor, in: lines), "#FFFFFF")
    }

    func testPaletteRendersSixteenIndexedLinesInOrder() {
        let palette = render(.seed).filter { $0.key == "palette" }.map(\.value)
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette[0], "0=#1D1F21")
        XCTAssertEqual(palette[9], "9=#D54E53")
        XCTAssertEqual(palette[15], "15=#EAEAEA")
    }

    func testFontFamilyIsOmittedWhenNilAndEmittedWhenSet() {
        XCTAssertNil(value(.fontFamily, in: render(.seed)))
        var spec = TerminalThemeSpec.seed
        spec.fontFamily = "SF Mono"
        XCTAssertEqual(value(.fontFamily, in: render(spec)), "SF Mono")
    }

    func testFontSizeDropsATrailingZeroButKeepsHalfPoints() {
        var spec = TerminalThemeSpec.seed
        XCTAssertEqual(value(.fontSize, in: render(spec)), "14")
        spec.fontSize = 13.5
        XCTAssertEqual(value(.fontSize, in: render(spec)), "13.5")
    }

    func testCursorStyleAndBlinkUseGhosttyRawValues() {
        var spec = TerminalThemeSpec.seed
        XCTAssertEqual(value(.cursorStyle, in: render(spec)), "bar")
        XCTAssertEqual(value(.cursorStyleBlink, in: render(spec)), "true")
        spec.cursorStyle = .underline
        spec.cursorBlink = false
        XCTAssertEqual(value(.cursorStyle, in: render(spec)), "underline")
        XCTAssertEqual(value(.cursorStyleBlink, in: render(spec)), "false")
    }

    func testBackgroundOpacityIsOmittedAtOneAndEmittedBelowIt() {
        XCTAssertNil(value(.backgroundOpacity, in: render(.seed, opacity: 1.0)))
        XCTAssertEqual(value(.backgroundOpacity, in: render(.seed, opacity: 0.85)), "0.85")
        XCTAssertEqual(value(.backgroundOpacity, in: render(.seed, opacity: 0.5)), "0.50")
    }

    func testOutOfRangeOpacityIsClamped() {
        XCTAssertNil(value(.backgroundOpacity, in: render(.seed, opacity: 4)))
        XCTAssertEqual(value(.backgroundOpacity, in: render(.seed, opacity: -1)), "0.00")
    }

    func testUnsanitizedInputIsNormalizedBeforeRendering() {
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "1d1f21"
        XCTAssertEqual(value(.background, in: render(spec)), "#1D1F21")
    }

    func testTextJoinsPairsAsGhosttyKeyValueLines() {
        let text = TerminalThemeRenderer.text([
            (key: "background", value: "#101010"),
            (key: "palette", value: "0=#1D1F21"),
        ])
        XCTAssertEqual(text, "background = #101010\npalette = 0=#1D1F21")
    }
}
