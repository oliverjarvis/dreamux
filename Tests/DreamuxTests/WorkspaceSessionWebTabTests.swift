import XCTest
@testable import Dreamux

/// Web tabs spawn no shell, so these run on the main actor without a PTY.
@MainActor
final class WorkspaceSessionWebTabTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    private func makeSession() -> WorkspaceSession {
        WorkspaceSession(workspace: Workspace(name: "f", workingDirectory: sandbox.root.path))
    }

    /// Dedup exists so a runner's repeated `open` re-focuses its preview
    /// rather than stacking copies — unchanged for real URLs.
    func testRealURLsDedup() {
        let session = makeSession()
        let url = URL(string: "http://localhost:3000")!
        session.openWebTab(url: url, title: "preview")
        session.openWebTab(url: url, title: "preview")
        XCTAssertEqual(session.webTabURLs.count, 1)
    }

    /// Without the exemption a second ⌘⇧B would re-select the first blank
    /// tab (they share the `about:blank` key). Each blank tab is its own.
    func testBlankTabsDoNotDedup() {
        let session = makeSession()
        session.openBlankWebTab()
        session.openBlankWebTab()
        XCTAssertEqual(session.webTabURLs.count, 2)
        XCTAssertEqual(Set(session.webTabURLs.map(\.absoluteString)), ["about:blank"])
    }

    /// A blank tab and a real URL coexist; the real one still dedups.
    func testBlankTabDoesNotAbsorbRealURLs() {
        let session = makeSession()
        session.openBlankWebTab()
        let url = URL(string: "https://github.com")!
        session.openWebTab(url: url, title: "github.com")
        session.openWebTab(url: url, title: "github.com")
        XCTAssertEqual(session.webTabURLs.count, 2)
    }
}
