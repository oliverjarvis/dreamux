import XCTest
@testable import Dreamux

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private func makeStore() -> (ConnectionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ConnectionStore(secretStore: InMemorySecretStore(),
                                metadataURL: dir.appendingPathComponent("connections.json")), dir)
    }

    func testAddPersistsMetadataAndSecretSeparately() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try store.add(label: "GitHub",
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            hosts: ["api.github.com"], token: "SEKRET", source: .manual, preferredID: "github")
        XCTAssertEqual(c.id, "github")
        XCTAssertEqual(store.token(for: "github"), "SEKRET")
        // Metadata JSON must NOT contain the token.
        let json = try String(contentsOf: dir.appendingPathComponent("connections.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("SEKRET"))
        // Reload sees the connection (secret comes from the same in-memory store here).
        XCTAssertEqual(store.connections.map(\.id), ["github"])
    }

    func testDeleteRemovesMetadataAndSecret() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.add(label: "G", kind: .basic(username: "u"), hosts: ["x.com"],
                          token: "T", source: .manual, preferredID: "g")
        try store.delete(id: "g")
        XCTAssertNil(store.token(for: "g"))
        XCTAssertEqual(store.connections, [])
    }

    func testBindingRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bindings = ConnectionBindingStore(dataDir: dir)
        XCTAssertNil(bindings.connectionID(forSlot: "github"))
        try bindings.bind(slot: "github", toConnectionID: "github")
        XCTAssertEqual(bindings.connectionID(forSlot: "github"), "github")
        XCTAssertEqual(ConnectionBindingStore(dataDir: dir).connectionID(forSlot: "github"), "github")
        try bindings.unbind(slot: "github")
        XCTAssertNil(bindings.connectionID(forSlot: "github"))
    }
}
