import XCTest
@testable import Dreamux

@MainActor
final class ProjectAppletStoreTests: XCTestCase {
    private var projectDir: URL!
    private var libraryRoot: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-applets-\(UUID().uuidString)", isDirectory: true)
        projectDir = base.appendingPathComponent("proj", isDirectory: true)
        libraryRoot = base.appendingPathComponent("library", isDirectory: true)
        try! FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent())
        super.tearDown()
    }
    private func makeStore() -> ProjectAppletStore {
        ProjectAppletStore(appsDir: projectDir.appendingPathComponent("apps"),
                           stateDir: projectDir.appendingPathComponent(".dreamux"))
    }

    func testAdoptCopiesWithNewIdentityAndOrigin() throws {
        let library = AppLibraryStore(root: libraryRoot)
        let canon = try library.createApplet(name: "Kanban", description: "d", icon: "s")
        let store = makeStore()
        let adopted = try store.adopt(canon)
        XCTAssertNotEqual(adopted.id, canon.id)                       // its own identity
        XCTAssertEqual(adopted.manifest.origin?.id, canon.id)          // lineage
        XCTAssertEqual(adopted.manifest.origin?.hash, AppletContentHash.hash(of: canon.folderURL))
        XCTAssertTrue(adopted.isAdopted)
        XCTAssertTrue(adopted.folderURL.path.hasSuffix("apps/kanban"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: adopted.folderURL.appendingPathComponent("index.html").path))
        // Adopting again → suffixed slug, both discoverable.
        XCTAssertEqual(try store.adopt(canon).slug, "kanban-2")
        XCTAssertEqual(store.applets.count, 2)
    }

    func testCreateLocalHasNoOrigin() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        XCTAssertNil(applet.manifest.origin)
        XCTAssertEqual(store.applets.map(\.slug), ["sink"])
    }

    func testRemoveDeletesFolderAndData() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        let data = store.dataDir(for: applet)
        try Data("{}".utf8).write(to: data.appendingPathComponent("kv.json"))
        try store.remove(applet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: applet.folderURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
        XCTAssertEqual(store.applets, [])
    }

    func testPublishStampsOriginAndLandsInLibrary() throws {
        let library = AppLibraryStore(root: libraryRoot)
        let store = makeStore()
        let local = try store.createLocal(name: "Sink", description: "d", icon: "s")
        let published = try store.publish(local, to: library)
        XCTAssertEqual(library.applets.map(\.slug), ["sink"])
        XCTAssertNotEqual(published.id, local.id)
        // The project copy now records its lineage.
        let refreshed = try XCTUnwrap(store.applets.first)
        XCTAssertEqual(refreshed.manifest.origin?.id, published.id)
    }

    func testDataDirIsUnderDreamuxAppdata() throws {
        let store = makeStore()
        let applet = try store.createLocal(name: "Sink", description: "d", icon: "s")
        XCTAssertTrue(store.dataDir(for: applet).path.hasSuffix(".dreamux/appdata/sink"))
    }

    func testBrokenFolderSurfacesAsInvalidNotCrash() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(
            at: store.appsDir.appendingPathComponent("broken"), withIntermediateDirectories: true)
        store.refresh()
        XCTAssertEqual(store.applets, [])
        XCTAssertEqual(store.invalidFolders, ["broken"])
    }
}
