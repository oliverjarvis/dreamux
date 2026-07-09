import XCTest
@testable import Dreamux

final class AppletSchemeHandlerTests: XCTestCase {
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applet-scheme-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! Data("hi".utf8).write(to: root.appendingPathComponent("index.html"))
        try! Data("x".utf8).write(to: root.appendingPathComponent("sub/a.js"))
        // A secret OUTSIDE the root that escapes must never reach.
        try! Data("secret".utf8).write(
            to: root.deletingLastPathComponent().appendingPathComponent("secret-\(root.lastPathComponent).txt"))
        return root
    }

    func testResolvesNormalAndNestedPaths() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc/index.html")!, root: root)?.lastPathComponent,
            "index.html")
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc/sub/a.js")!, root: root)?.lastPathComponent,
            "a.js")
        // Bare host → index.html.
        XCTAssertEqual(
            AppletSchemeHandler.resolvedFileURL(
                for: URL(string: "dreamux-applet://abc")!, root: root)?.lastPathComponent,
            "index.html")
    }

    func testRejectsTraversalAndForeignSchemes() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        for bad in [
            "dreamux-applet://abc/../escape.txt",
            "dreamux-applet://abc/sub/../../escape.txt",
            "dreamux-applet://abc/%2e%2e/escape.txt",
            "https://example.com/x",
        ] {
            XCTAssertNil(AppletSchemeHandler.resolvedFileURL(for: URL(string: bad)!, root: root),
                         "should reject \(bad)")
        }
    }

    func testRejectsSymlinkEscape() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        XCTAssertNil(AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://abc/link.txt")!, root: root))
    }
}
