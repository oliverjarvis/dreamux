import XCTest
import GhosttyKit
@testable import Dreamux

/// The libghostty version tripwire. Bump `libghostty-spm` and these fail
/// with the specific key or the new default value in the message.
///
/// `ghostty_init` is mandatory — `ghostty_config_new` segfaults without
/// it — and calling it more than once per process is safe, which is why
/// `setUp` calls it unconditionally even though `TerminalController`
/// may already have.
final class GhosttyConfigAcceptanceTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        _ = ghostty_init(0, nil)
    }

    override func tearDown() {
        sandbox.destroy()
        sandbox = nil
        super.tearDown()
    }

    /// Write `text` to a temp `.conf`, load it the way
    /// `TerminalController.prepareConfig` does, and return every
    /// diagnostic ghostty produced.
    private func diagnostics(loading text: String) throws -> [String] {
        let url = sandbox.root.appendingPathComponent("\(UUID().uuidString).conf")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(ghostty_config_new(), "ghostty_config_new returned nil")
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, url.path)
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        return (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }

    /// Ghostty's live default for a color key, or nil when it has none.
    private func defaultColor(_ key: String) -> String? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var color = ghostty_config_color_s()
        let found = key.withCString { pointer in
            ghostty_config_get(config, &color, pointer, UInt(strlen(pointer)))
        }
        guard found else { return nil }
        return String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    /// Ghostty's live default ANSI palette, indices 0…15.
    private func defaultPalette() -> [String] {
        guard let config = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var palette = ghostty_config_palette_s()
        let key = "palette"
        let found = key.withCString { pointer in
            ghostty_config_get(config, &palette, pointer, UInt(strlen(pointer)))
        }
        guard found else { return [] }
        // `colors` imports as a 256-element Swift tuple; Mirror walks it
        // in declaration order.
        let colors = Mirror(reflecting: palette.colors)
            .children
            .compactMap { $0.value as? ghostty_config_color_s }
        return colors.prefix(16).map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) }
    }

    // MARK: - 1. the whole rendered config loads clean

    func testFullRenderedConfigLoadsWithoutDiagnostics() throws {
        var spec = TerminalThemeSpec.seed
        // Force every optional key to be emitted, so this covers the
        // complete surface rather than just the seed's subset.
        spec.dark.cursorColor = "#F5E0DC"
        spec.dark.cursorText = "#1E1E2E"
        spec.dark.selectionBackground = "#414559"
        spec.dark.selectionForeground = "#CDD6F4"
        spec.dark.boldColor = "#FFFFFF"
        spec.fontFamily = "Menlo"
        spec.fontSize = 13.5
        spec.cursorStyle = .underline
        spec.cursorBlink = false

        let lines = TerminalThemeRenderer.lines(for: spec, variant: .dark, opacity: 0.85)
        let issues = try diagnostics(loading: TerminalThemeRenderer.text(lines))
        XCTAssertEqual(issues, [], "libghostty rejected the rendered theme config")
    }

    func testAppInvariantLinesLoadWithoutDiagnostics() throws {
        let text = TerminalThemeRenderer.text(TerminalThemeCompiler.invariantLines())
        let issues = try diagnostics(loading: text)
        XCTAssertEqual(issues, [], "libghostty rejected the app invariants")
    }

    // MARK: - 2. each key individually, so a failure names the culprit

    func testEachEmittedKeyLoadsCleanOnItsOwn() throws {
        var spec = TerminalThemeSpec.seed
        spec.dark.cursorColor = "#F5E0DC"
        spec.dark.cursorText = "#1E1E2E"
        spec.dark.selectionBackground = "#414559"
        spec.dark.selectionForeground = "#CDD6F4"
        spec.dark.boldColor = "#FFFFFF"
        spec.fontFamily = "Menlo"

        let lines = TerminalThemeRenderer.lines(for: spec, variant: .dark, opacity: 0.85)
            + TerminalThemeCompiler.invariantLines()
        for line in lines {
            let issues = try diagnostics(loading: "\(line.key) = \(line.value)")
            XCTAssertEqual(
                issues, [],
                "libghostty rejected `\(line.key) = \(line.value)` — update TerminalConfigKey"
            )
        }
    }

    // MARK: - 3. the seed still matches ghostty's live defaults

    func testSeedBackgroundAndForegroundMatchGhosttyDefaults() {
        XCTAssertEqual(
            defaultColor("background"), TerminalColorSpec.seed.background,
            "ghostty's default background moved — update TerminalColorSpec.seed"
        )
        XCTAssertEqual(
            defaultColor("foreground"), TerminalColorSpec.seed.foreground,
            "ghostty's default foreground moved — update TerminalColorSpec.seed"
        )
    }

    func testSeedPaletteMatchesGhosttyDefaults() {
        XCTAssertEqual(
            defaultPalette(), TerminalColorSpec.seedPalette,
            "ghostty's default palette moved — update TerminalColorSpec.seedPalette"
        )
    }

    func testOptionalColorsStillHaveNoGhosttyDefault() {
        // The seed leaves these Automatic precisely BECAUSE ghostty has
        // no default to seed from. If a version bump gives them one,
        // this fails and the seed should start carrying it.
        for key in ["cursor-color", "cursor-text", "selection-background",
                    "selection-foreground", "bold-color"] {
            XCTAssertNil(
                defaultColor(key),
                "ghostty now has a default for \(key) — revisit the Automatic seeding"
            )
        }
    }

    // MARK: - the failure mode the degrade ladder defends against

    func testOneBadKeyPoisonsTheWholeConfig() throws {
        let issues = try diagnostics(loading: """
        background = #282C34
        not-a-real-key = 1
        """)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(
            issues[0].contains("not-a-real-key"),
            "expected the key named in the diagnostic, got: \(issues[0])"
        )
    }

    func testBadValueAlsoProducesADiagnostic() throws {
        let issues = try diagnostics(loading: "background = notacolor")
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].contains("background"))
    }
}
