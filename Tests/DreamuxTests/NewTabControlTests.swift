import XCTest
@testable import Dreamux

/// The pill's menu is data, so its contents and order are pinnable
/// without rendering a view.
final class NewTabControlTests: XCTestCase {
    func testMenuOrderIsTerminalBrowserFile() {
        XCTAssertEqual(NewTabControl.Kind.allCases, [.terminal, .browser, .file])
    }

    func testMenuLabels() {
        XCTAssertEqual(NewTabControl.Kind.terminal.label, "Terminal")
        XCTAssertEqual(NewTabControl.Kind.browser.label, "Browser")
        XCTAssertEqual(NewTabControl.Kind.file.label, "File…")
    }

    func testMenuIcons() {
        XCTAssertEqual(NewTabControl.Kind.terminal.icon, "terminal")
        XCTAssertEqual(NewTabControl.Kind.browser.icon, "globe")
        XCTAssertEqual(NewTabControl.Kind.file.icon, "doc")
    }
}
