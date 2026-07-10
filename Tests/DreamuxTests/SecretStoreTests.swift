import XCTest
@testable import Dreamux

final class SecretStoreTests: XCTestCase {
    private func check(_ store: SecretStore) throws {
        XCTAssertNil(store.get("github"))
        try store.set("SEKRET", for: "github")
        XCTAssertEqual(store.get("github"), "SEKRET")
        try store.set("SEKRET2", for: "github")            // overwrite
        XCTAssertEqual(store.get("github"), "SEKRET2")
        try store.delete("github")
        XCTAssertNil(store.get("github"))
        XCTAssertNoThrow(try store.delete("github"))       // delete-absent is a no-op
    }

    func testInMemory() throws { try check(InMemorySecretStore()) }

    func testFileBacked() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try check(FileSecretStore(dir: dir))
        // A second instance over the same dir sees persisted secrets.
        try FileSecretStore(dir: dir).set("X", for: "k")
        XCTAssertEqual(FileSecretStore(dir: dir).get("k"), "X")
    }

    func testFileStoreRejectsUnsafeIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(dir: dir)

        // A traversal id is rejected before any path is derived: set/delete
        // throw (they route through the isSafe guard), get returns nil. None
        // of them touch anything outside `dir`.
        XCTAssertThrowsError(try store.set("x", for: "../evil"))
        XCTAssertNil(store.get("../evil"))
        XCTAssertThrowsError(try store.delete("../evil"))

        // Confirm nothing escaped `dir` — the sibling path a "../evil" id
        // would have written to does not exist.
        let escaped = dir.deletingLastPathComponent().appendingPathComponent("evil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))

        // A normal id still round-trips.
        try store.set("SEKRET", for: "github")
        XCTAssertEqual(store.get("github"), "SEKRET")
    }

    func testFactoryHonorsEnvOverride() {
        let key = "DREAMUX_CONNECTIONS_SECRET_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString)")
        setenv(key, dir.path, 1)
        XCTAssertTrue(SecretStoreFactory.makeDefault() is FileSecretStore)
        unsetenv(key)
        XCTAssertTrue(SecretStoreFactory.makeDefault() is KeychainSecretStore)
    }
}
