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

    func testDoubleSlashPathNeverResolvesOutsideRoot() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // "//etc/passwd" must never resolve to the absolute /etc/passwd —
        // nil is fine, and so is any path still inside the resolved root.
        let resolved = AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://x//etc/passwd")!, root: root)
        if let resolved {
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            XCTAssertTrue(resolved.path.hasPrefix(resolvedRoot.path + "/"),
                          "resolved to \(resolved.path), outside \(resolvedRoot.path)")
        }
    }

    func testRejectsSiblingDirectoryPrefixCollision() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // A sibling directory whose name extends the root's ("<root>-evil")
        // must not pass a containment check that forgets the trailing "/".
        let evil = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evil) }
        try Data("secret".utf8).write(to: evil.appendingPathComponent("secret.txt"))

        XCTAssertNil(AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://x/../\(root.lastPathComponent)-evil/secret.txt")!,
            root: root))
        // Trailing-separator property directly: a candidate equal to the
        // root's path plus a "-evil" suffix fails containment.
        XCTAssertNil(AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://x/../\(root.lastPathComponent)-evil")!,
            root: root))
    }

    func testRejectsMixedEncodingTraversal() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(AppletSchemeHandler.resolvedFileURL(
            for: URL(string: "dreamux-applet://x/..%2fescape.txt")!, root: root))
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
