import XCTest
@testable import Dreamux

final class AppletScaffoldTests: XCTestCase {
    func testBundledScaffoldAssetsExist() {
        let root = AppletScaffold.bundledRoot
        for file in ["index.html", "dreamux.js", "preact.mjs", "htm.mjs", "APPLET.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path),
                          "missing scaffold asset \(file)")
        }
    }

    func testWriteScaffoldsFolderWithSubstitutedName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scaffold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = AppletManifest(id: UUID(), name: "Kanban", slug: "kanban",
                                      icon: "rectangle.split.3x1", description: "d",
                                      requiresCapabilities: ["kv"], origin: nil)
        try AppletScaffold.write(to: dir, manifest: manifest)
        XCTAssertEqual(AppletManifest.load(from: dir), manifest)
        let html = try String(contentsOf: dir.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Kanban</title>"))
        XCTAssertFalse(html.contains("{{NAME}}"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dreamux.js").path))
        XCTAssertTrue(AppletScaffold.kickoffPrompt(appletName: "Kanban", description: "a board")
            .contains("a board"))
    }
}
