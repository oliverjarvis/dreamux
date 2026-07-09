import XCTest
@testable import Dreamux

final class AppletManifestTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("applet-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testManifestRoundTripsAndToleratesUnknownCapabilities() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var manifest = AppletManifest(
            id: UUID(), name: "Expo Status", slug: "expo-status",
            icon: "shippingbox", description: "Tracks EAS deployments.",
            requiresCapabilities: ["shell", "http", "screen-capture"], origin: nil)
        try manifest.write(to: dir)
        let loaded = try XCTUnwrap(AppletManifest.load(from: dir))
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.grantedCapabilities, [.shell, .http])
        XCTAssertEqual(loaded.unknownCapabilities, ["screen-capture"])
        // Origin round-trips too.
        manifest.origin = .init(id: UUID(), hash: "abc", adoptedAt: Date(timeIntervalSince1970: 1000))
        try manifest.write(to: dir)
        XCTAssertEqual(AppletManifest.load(from: dir)?.origin, manifest.origin)
    }

    func testLoadReturnsNilForMissingOrInvalidManifest() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(AppletManifest.load(from: dir))
        try! Data("not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertNil(AppletManifest.load(from: dir))
    }

    func testContentHashIsDeterministicAndSensitive() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("aaa".utf8).write(to: dir.appendingPathComponent("index.html"))
        try Data("bbb".utf8).write(to: dir.appendingPathComponent("app.js"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let h1 = AppletContentHash.hash(of: dir)
        XCTAssertEqual(h1, AppletContentHash.hash(of: dir))          // stable
        XCTAssertEqual(h1.count, 64)                                  // hex sha256
        try Data("changed".utf8).write(to: dir.appendingPathComponent("app.js"))
        XCTAssertNotEqual(h1, AppletContentHash.hash(of: dir))        // content-sensitive
    }

    func testSlugs() {
        XCTAssertEqual(AppletSlug.slugify("Expo Status!"), "expo-status")
        XCTAssertEqual(AppletSlug.slugify("  Kanban -- Board "), "kanban-board")
        XCTAssertEqual(AppletSlug.slugify("???"), "applet")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: []), "kanban")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: ["kanban"]), "kanban-2")
        XCTAssertEqual(AppletSlug.unique("kanban", existing: ["kanban", "kanban-2"]), "kanban-3")
    }
}
