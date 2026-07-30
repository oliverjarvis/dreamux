import XCTest
@testable import Dreamux

/// Pins the two pure halves of the project scan — `scanProjectFolders`
/// (blocking I/O, runs off the main actor in production) and `reconciled`
/// (the merge). Launch must never block on `~/Documents`, so `refresh()`
/// composes these asynchronously; the units are pinned here exactly like
/// `BundleIdentity`'s, with no `ProjectStore` instance (whose init touches
/// real user directories).
final class ProjectStoreScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func mkdir(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true)
    }

    // MARK: - scanProjectFolders

    func testScanFindsOnlyRealProjectFolders() throws {
        try mkdir("beta")
        try mkdir("alpha")
        try mkdir("Apps")          // reserved: Applet Studio's library
        try mkdir(".hidden")
        try "x".write(to: root.appendingPathComponent("stray.txt"),
                      atomically: true, encoding: .utf8)

        let scanned = ProjectStore.scanProjectFolders(root: root)
        XCTAssertEqual(Set(scanned.map { $0.url.lastPathComponent }), ["alpha", "beta"])
        for folder in scanned {
            XCTAssertNotNil(folder.createdAt, "creation date should be captured by the scan")
        }
    }

    func testScanOfMissingRootIsEmpty() {
        let gone = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(ProjectStore.scanProjectFolders(root: gone).count, 0)
    }

    // MARK: - reconciled

    private func scanned(_ name: String, createdAt: Date? = nil) -> ProjectStore.ScannedProjectFolder {
        ProjectStore.ScannedProjectFolder(
            url: root.appendingPathComponent(name, isDirectory: true).standardizedFileURL,
            createdAt: createdAt)
    }

    private func project(_ name: String, symbol: String? = nil, tintHex: String? = nil) -> Project {
        Project(name: name,
                rootPath: root.appendingPathComponent(name, isDirectory: true).standardizedFileURL,
                symbol: symbol,
                tintHex: tintHex)
    }

    func testReconcilePreservesIdentityAndCustomization() {
        let existing = project("alpha", symbol: "leaf", tintHex: "#112233")
        let result = ProjectStore.reconciled(current: [existing], scanned: [scanned("alpha")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, existing.id)
        XCTAssertEqual(result[0].symbol, "leaf")
        XCTAssertEqual(result[0].tintHex, "#112233")
    }

    func testReconcileDropsVanishedAndAddsDiscovered() {
        let kept = project("kept")
        let gone = project("gone")
        let created = Date(timeIntervalSince1970: 1_000_000)
        let result = ProjectStore.reconciled(
            current: [kept, gone],
            scanned: [scanned("kept"), scanned("new", createdAt: created)])
        XCTAssertEqual(result.map { $0.name }, ["kept", "new"])
        XCTAssertEqual(result[0].id, kept.id)
        XCTAssertEqual(result[1].createdAt, created)
    }

    func testReconcileFollowsOnDiskRenameKeepingIdentity() {
        // A stored project whose name diverged from its folder (same path):
        // the name follows the disk, identity/icon/tint stay.
        let stale = Project(
            name: "old-name",
            rootPath: root.appendingPathComponent("alpha", isDirectory: true).standardizedFileURL,
            symbol: "leaf")
        let result = ProjectStore.reconciled(current: [stale], scanned: [scanned("alpha")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, stale.id)
        XCTAssertEqual(result[0].name, "alpha")
        XCTAssertEqual(result[0].symbol, "leaf")
    }

    func testReconcileSortsLikeFinder() {
        let result = ProjectStore.reconciled(
            current: [],
            scanned: [scanned("project 10"), scanned("project 2"), scanned("Alpha")])
        XCTAssertEqual(result.map { $0.name }, ["Alpha", "project 2", "project 10"])
    }
}
