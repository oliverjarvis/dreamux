import XCTest
@testable import Dreamux

final class BundledAssetSchemeHandlerTests: XCTestCase {
    private let applet = BundledAssetSchemeHandler.appletScheme
    private let monaco = BundledAssetSchemeHandler.monacoScheme

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-asset-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! Data("hi".utf8).write(to: root.appendingPathComponent("index.html"))
        try! Data("x".utf8).write(to: root.appendingPathComponent("sub/a.js"))
        try! Data("secret".utf8).write(
            to: root.deletingLastPathComponent()
                .appendingPathComponent("secret-\(root.lastPathComponent).txt"))
        return root
    }

    func testResolvesNormalNestedAndBareHostPaths() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            BundledAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "\(applet)://abc/index.html")!, root: root, scheme: applet)?
                .lastPathComponent,
            "index.html")
        XCTAssertEqual(
            BundledAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "\(applet)://abc/sub/a.js")!, root: root, scheme: applet)?
                .lastPathComponent,
            "a.js")
        // Bare host → index.html.
        XCTAssertEqual(
            BundledAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "\(applet)://abc")!, root: root, scheme: applet)?
                .lastPathComponent,
            "index.html")
    }

    func testMonacoRootNowGetsTheSameTraversalGuard() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            BundledAssetSchemeHandler.resolvedFileURL(
                for: URL(string: "\(monaco)://app/vs/loader.js")!, root: root, scheme: monaco)?
                .path,
            root.appendingPathComponent("vs/loader.js")
                .standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNil(BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(monaco)://app/../escape.txt")!, root: root, scheme: monaco))
    }

    func testRejectsTraversalAndForeignSchemes() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        for bad in [
            "\(applet)://abc/../escape.txt",
            "\(applet)://abc/sub/../../escape.txt",
            "\(applet)://abc/%2e%2e/escape.txt",
            "\(applet)://x/..%2fescape.txt",
            "https://example.com/x",
        ] {
            XCTAssertNil(
                BundledAssetSchemeHandler.resolvedFileURL(
                    for: URL(string: bad)!, root: root, scheme: applet),
                "should reject \(bad)")
        }
    }

    func testRejectsAnotherHandlersScheme() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        // A handler bound to the Monaco scheme must not serve an applet URL.
        XCTAssertNil(BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(applet)://abc/index.html")!, root: root, scheme: monaco))
    }

    func testDoubleSlashPathNeverResolvesOutsideRoot() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let resolved = BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(applet)://x//etc/passwd")!, root: root, scheme: applet)
        if let resolved {
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            XCTAssertTrue(resolved.path.hasPrefix(resolvedRoot.path + "/"),
                          "resolved to \(resolved.path), outside \(resolvedRoot.path)")
        }
    }

    func testRejectsSiblingDirectoryPrefixCollision() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let evil = root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + "-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evil) }
        try Data("secret".utf8).write(to: evil.appendingPathComponent("secret.txt"))

        XCTAssertNil(BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(applet)://x/../\(root.lastPathComponent)-evil/secret.txt")!,
            root: root, scheme: applet))
        XCTAssertNil(BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(applet)://x/../\(root.lastPathComponent)-evil")!,
            root: root, scheme: applet))
    }

    func testRejectsSymlinkEscape() throws {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID()).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        XCTAssertNil(BundledAssetSchemeHandler.resolvedFileURL(
            for: URL(string: "\(applet)://abc/link.txt")!, root: root, scheme: applet))
    }

    func testMimeTypes() {
        XCTAssertEqual(BundledAssetSchemeHandler.mimeType(forPathExtension: "js"), "text/javascript")
        XCTAssertEqual(BundledAssetSchemeHandler.mimeType(forPathExtension: "CSS"), "text/css")
        XCTAssertEqual(BundledAssetSchemeHandler.mimeType(forPathExtension: "ttf"), "font/ttf")
        XCTAssertEqual(BundledAssetSchemeHandler.mimeType(forPathExtension: "md"), "text/markdown")
        XCTAssertEqual(BundledAssetSchemeHandler.mimeType(forPathExtension: "xyz"),
                       "application/octet-stream")
    }

    func testBundledRootsExist() {
        for name in ["Monaco", "FlowsCanvas"] {
            let root = BundledAssetSchemeHandler.bundledRoot(named: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                          "missing bundled resource dir \(name)")
        }
    }
}
