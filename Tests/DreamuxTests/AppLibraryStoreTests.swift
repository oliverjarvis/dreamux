import XCTest
@testable import Dreamux

@MainActor
final class AppLibraryStoreTests: XCTestCase {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-library-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreateScaffoldsDiscoverableApplet() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryStore(root: root)
        let applet = try store.createApplet(name: "Expo Status", description: "d", icon: "shippingbox")
        XCTAssertEqual(applet.slug, "expo-status")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("expo-status/index.html").path))
        // A second store over the same root discovers it by scan.
        XCTAssertEqual(AppLibraryStore(root: root).applets.map(\.slug), ["expo-status"])
        // Same name again → suffixed slug.
        XCTAssertEqual(try store.createApplet(name: "Expo Status", description: "d", icon: "s").slug,
                       "expo-status-2")
    }

    func testRefreshSkipsInvalidFolders() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        XCTAssertEqual(AppLibraryStore(root: root).applets, [])
    }

    func testDeleteRemovesFolder() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryStore(root: root)
        let applet = try store.createApplet(name: "Kanban", description: "d", icon: "s")
        try store.delete(applet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: applet.folderURL.path))
        XCTAssertEqual(store.applets, [])
    }

    func testCreateUniquesSlugAgainstLiveDiskState() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLibraryStore(root: root)
        // A folder appears out-of-band (another store instance, or a
        // manifest-less directory) after this store's last refresh. We do
        // NOT refresh the store manually — createApplet must handle it.
        let squatter = root.appendingPathComponent("kanban", isDirectory: true)
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)
        let applet = try store.createApplet(name: "Kanban", description: "d", icon: "s")
        XCTAssertEqual(applet.slug, "kanban-2")
        // The squatting folder is untouched — nothing was written into it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: squatter.path), [])
    }

    func testAppsFolderIsReservedProjectName() {
        XCTAssertTrue(ProjectStore.isReservedProjectFolderName("Apps"))
        XCTAssertFalse(ProjectStore.isReservedProjectFolderName("apps-thing"))
        XCTAssertFalse(ProjectStore.isReservedProjectFolderName("MyProject"))
    }
}
