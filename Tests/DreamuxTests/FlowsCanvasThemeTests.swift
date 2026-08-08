import SwiftUI
import XCTest
@testable import Dreamux

final class FlowsCanvasThemeTests: XCTestCase {

    func testPushesEveryVariableTheStylesheetExpects() {
        let vars = FlowsCanvasTheme.variables(accent: .accentColor, colorScheme: .dark)
        for name in [
            "--flows-surface", "--flows-text", "--flows-text-secondary",
            "--flows-accent", "--flows-border",
            "--flows-status-running", "--flows-status-queued", "--flows-status-waiting",
            "--flows-status-done", "--flows-status-failed",
        ] {
            XCTAssertNotNil(vars[name], "theme is missing \(name)")
        }
    }

    func testEveryNameIsACustomPropertyAndEveryValueIsCSSColour() {
        let vars = FlowsCanvasTheme.variables(accent: .accentColor, colorScheme: .light)
        for (name, value) in vars {
            XCTAssertTrue(name.hasPrefix("--"),
                          "\(name) must be a CSS custom property — applyTheme drops anything else")
            XCTAssertTrue(value.hasPrefix("#") || value.hasPrefix("rgb"),
                          "\(name) = \(value) is not a CSS colour")
            XCTAssertFalse(value.contains(";"), "\(name) value must not be able to escape its rule")
        }
    }

    func testTheFiveStatusColoursMatchFlowStatusGlyph() {
        let vars = FlowsCanvasTheme.variables(accent: .accentColor, colorScheme: .dark)
        let pairs: [(FlowStatus, String)] = [
            (.running, "--flows-status-running"), (.queued, "--flows-status-queued"),
            (.waiting, "--flows-status-waiting"), (.done, "--flows-status-done"),
            (.failed, "--flows-status-failed"),
        ]
        for (status, name) in pairs {
            XCTAssertEqual(vars[name], FlowsCanvasTheme.css(FlowStatusGlyph.color(status)),
                           "\(name) must come from FlowStatusGlyph.color(.\(status.rawValue))")
        }
    }

    func testDarkAndLightSurfacesDiffer() {
        let dark = FlowsCanvasTheme.variables(accent: .accentColor, colorScheme: .dark)
        let light = FlowsCanvasTheme.variables(accent: .accentColor, colorScheme: .light)
        XCTAssertNotEqual(dark["--flows-surface"], light["--flows-surface"])
        XCTAssertNotEqual(dark["--flows-text"], light["--flows-text"])
    }

    func testCSSEmitsSixDigitHexOrRGBA() {
        XCTAssertEqual(FlowsCanvasTheme.css(Color(red: 1, green: 0, blue: 0)), "#ff0000")
        XCTAssertEqual(FlowsCanvasTheme.css(Color(red: 0, green: 0, blue: 0)), "#000000")
    }
}
