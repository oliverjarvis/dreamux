import XCTest
@testable import Dreamux

@MainActor
final class AppletConnectionResolverTests: XCTestCase {
    /// A resolver over an in-memory secret store and a throwaway binding
    /// dir, plus the pieces needed to seed/mutate them.
    private func makeResolver() -> (AppletConnectionResolver, ConnectionStore, ConnectionBindingStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConnectionStore(secretStore: InMemorySecretStore(),
                                    metadataURL: dir.appendingPathComponent("connections.json"))
        let bindings = ConnectionBindingStore(dataDir: dir)
        let resolver = AppletConnectionResolver(store: store, bindings: bindings)
        return (resolver, store, bindings, dir)
    }

    private func seedGitHub(_ store: ConnectionStore) throws {
        _ = try store.add(
            label: "GitHub",
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            hosts: ["api.github.com"], token: "SEKRET", source: .manual, preferredID: "github")
    }

    func testBoundSlotStatusAndResolve() throws {
        let (resolver, store, bindings, dir) = makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedGitHub(store)
        try bindings.bind(slot: "github", toConnectionID: "github")

        let status = resolver.status(slot: "github")
        XCTAssertTrue(status.bound)
        XCTAssertEqual(status.label, "GitHub")
        XCTAssertEqual(status.hosts, ["api.github.com"])

        let resolved = try resolver.resolve(slot: "github")
        XCTAssertEqual(resolved.token, "SEKRET")
        XCTAssertEqual(resolved.connection.id, "github")
    }

    func testUnboundSlotStatusFalseAndResolveThrows() {
        let (resolver, _, _, dir) = makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }

        let status = resolver.status(slot: "github")
        XCTAssertFalse(status.bound)
        XCTAssertNil(status.label)
        XCTAssertEqual(status.hosts, [])

        XCTAssertThrowsError(try resolver.resolve(slot: "github")) { error in
            XCTAssertEqual(error as? AppletConnectionResolver.ResolveError, .slotNotBound("github"))
        }
    }

    func testBoundButDeletedConnectionThrowsConnectionMissing() throws {
        let (resolver, store, bindings, dir) = makeResolver()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedGitHub(store)
        try bindings.bind(slot: "github", toConnectionID: "github")
        try store.delete(id: "github")   // dangling binding: slot still points at the deleted id

        // Status treats a dangling binding as unbound (it needs re-binding).
        XCTAssertFalse(resolver.status(slot: "github").bound)
        XCTAssertThrowsError(try resolver.resolve(slot: "github")) { error in
            XCTAssertEqual(error as? AppletConnectionResolver.ResolveError, .connectionMissing("github"))
        }
    }
}
