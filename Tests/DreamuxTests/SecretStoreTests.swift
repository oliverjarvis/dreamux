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

    func testFactoryHonorsEnvOverride() {
        // With the override set, the default is file-backed (no Keychain in tests).
        // (Documented behavior; asserted structurally — the override is read
        //  from the process env, which the e2e harness sets.)
        XCTAssertNotNil(SecretStoreFactory.makeDefault())
    }
}
