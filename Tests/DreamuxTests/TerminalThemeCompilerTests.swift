import XCTest
import GhosttyTerminal
@testable import Dreamux

final class TerminalThemeCompilerTests: XCTestCase {

    // MARK: - advanced-conf line parsing

    func testCustomPairSplitsOnTheFirstEqualsAndTrims() {
        let pair = TerminalThemeCompiler.customPair(from: "  keybind = super+k=text:\\x0c  ")
        XCTAssertEqual(pair?.key, "keybind")
        XCTAssertEqual(pair?.value, "super+k=text:\\x0c")
    }

    func testCustomPairSkipsCommentsBlanksAndMalformedLines() {
        XCTAssertNil(TerminalThemeCompiler.customPair(from: "# a comment"))
        XCTAssertNil(TerminalThemeCompiler.customPair(from: "   "))
        XCTAssertNil(TerminalThemeCompiler.customPair(from: "no equals sign here"))
        XCTAssertNil(TerminalThemeCompiler.customPair(from: "= orphan value"))
    }

    // MARK: - layering

    func testConfigurationHoldsInvariantsThenAdvancedConfInThatOrder() throws {
        let compiled = TerminalThemeCompiler.compile(
            spec: .seed,
            advancedConfLines: ["window-padding-x = 24", "# ignored", "minimum-contrast = 1.1"],
            cardOpacity: 1.0
        )
        let rendered = compiled.configuration.rendered
        let invariantPadding = try XCTUnwrap(rendered.range(of: "window-padding-x = 8"))
        let userPadding = try XCTUnwrap(rendered.range(of: "window-padding-x = 24"))
        XCTAssertLessThan(
            invariantPadding.lowerBound, userPadding.lowerBound,
            "invariants come first so a hand-edit can override the padding"
        )
        XCTAssertTrue(rendered.contains("minimum-contrast = 1.1"))
        XCTAssertFalse(rendered.contains("# ignored"))
        XCTAssertTrue(rendered.contains("keybind = super+t=unbind"))
    }

    func testConfigurationCarriesNoColorsSoSettingsAlwaysWins() {
        let compiled = TerminalThemeCompiler.compile(
            spec: .seed,
            advancedConfLines: ["background = #FF0000"],
            cardOpacity: 1.0
        )
        // The user's line is passed through verbatim…
        XCTAssertTrue(compiled.configuration.rendered.contains("background = #FF0000"))
        // …but the theme layer renders after it, so Settings wins.
        XCTAssertTrue(compiled.theme.dark.rendered.contains("background = #282C34"))
        XCTAssertTrue(compiled.theme.light.rendered.contains("background = #282C34"))
    }

    func testThemeRendersBothVariantsFromTheirOwnColors() {
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "#101010"
        spec.light.background = "#FAFAFA"
        let compiled = TerminalThemeCompiler.compile(
            spec: spec, advancedConfLines: [], cardOpacity: 1.0)
        XCTAssertTrue(compiled.theme.dark.rendered.contains("background = #101010"))
        XCTAssertTrue(compiled.theme.light.rendered.contains("background = #FAFAFA"))
    }

    func testCardOpacityLandsInTheThemeLayerNotTheConfiguration() {
        let compiled = TerminalThemeCompiler.compile(
            spec: .seed, advancedConfLines: [], cardOpacity: 0.7)
        XCTAssertTrue(compiled.theme.dark.rendered.contains("background-opacity = 0.70"))
        XCTAssertTrue(compiled.theme.light.rendered.contains("background-opacity = 0.70"))
        XCTAssertFalse(compiled.configuration.rendered.contains("background-opacity"))
    }

    func testFullOpacityEmitsNoOpacityKey() {
        let compiled = TerminalThemeCompiler.compile(
            spec: .seed, advancedConfLines: [], cardOpacity: 1.0)
        XCTAssertFalse(compiled.theme.dark.rendered.contains("background-opacity"))
    }

    // MARK: - minimal

    func testMinimalKeepsOnlyBackgroundForegroundAndTheInvariants() {
        var spec = TerminalThemeSpec.seed
        spec.dark.background = "#101010"
        let compiled = TerminalThemeCompiler.minimal(spec: spec)
        let dark = compiled.theme.dark.rendered
        XCTAssertEqual(dark, "background = #101010\nforeground = #FFFFFF")
        XCTAssertTrue(compiled.configuration.rendered.contains("keybind = super+t=unbind"),
                      "Cmd+T must keep working even at the last degrade step")
        XCTAssertTrue(compiled.configuration.rendered.contains("window-padding-x = 8"))
    }

    func testMinimalDropsAdvancedConfEntirely() {
        // minimal takes no conf lines at all — the signature is the guarantee.
        let compiled = TerminalThemeCompiler.minimal(spec: .seed)
        XCTAssertFalse(compiled.configuration.rendered.contains("minimum-contrast"))
    }

    // MARK: - equality (the store and TabSession both lean on it)

    func testCompiledThemesAreEquatable() {
        let a = TerminalThemeCompiler.compile(spec: .seed, advancedConfLines: [], cardOpacity: 1)
        let b = TerminalThemeCompiler.compile(spec: .seed, advancedConfLines: [], cardOpacity: 1)
        let c = TerminalThemeCompiler.compile(spec: .seed, advancedConfLines: [], cardOpacity: 0.8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
