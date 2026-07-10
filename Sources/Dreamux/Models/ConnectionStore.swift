import Foundation
import Observation

/// Global CRUD over `Connection`s: non-secret metadata (`connections.json`)
/// plus the secret token, which never touches the metadata file — it's
/// written/read through a `SecretStore` (Keychain in production, an
/// in-memory/file fake in tests).
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []

    @ObservationIgnored private let secretStore: SecretStore
    @ObservationIgnored private let metadataURL: URL

    /// App-wide instance: metadata at `stateRootURL()/connections.json`,
    /// secrets via `SecretStoreFactory.makeDefault()`.
    static let shared = ConnectionStore()

    /// App default.
    convenience init() {
        self.init(
            secretStore: SecretStoreFactory.makeDefault(),
            metadataURL: ProjectStore.stateRootURL().appendingPathComponent("connections.json")
        )
    }

    /// Test/e2e seam.
    init(secretStore: SecretStore, metadataURL: URL) {
        self.secretStore = secretStore
        self.metadataURL = metadataURL
        self.connections = Self.load(from: metadataURL)
    }

    func connection(id: String) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Reads the SecretStore (never the metadata file — the token never
    /// lives there).
    func token(for id: String) -> String? {
        secretStore.get(id)
    }

    /// Create + persist a connection. `preferredID` is slugified and
    /// uniqued against the existing ids so the result is always a SAFE
    /// (`AppletSlug.isSafe`) id — every connection id flows through
    /// `slugify`, so it can key both the SecretStore account and the
    /// metadata without a separate validation step.
    ///
    /// The token is written to the SecretStore BEFORE the metadata is
    /// persisted. If the metadata write throws, the just-written secret is
    /// rolled back (best-effort `try?`) so a failed `add` never leaves an
    /// orphaned Keychain item behind.
    @discardableResult
    func add(
        label: String, kind: AuthKind, hosts: [String], token: String,
        source: Connection.Source, preferredID: String
    ) throws -> Connection {
        let id = AppletSlug.unique(AppletSlug.slugify(preferredID), existing: Set(connections.map(\.id)))
        let connection = Connection(id: id, label: label, kind: kind, hosts: hosts, source: source, createdAt: Date())

        try secretStore.set(token, for: id)
        var updated = connections
        updated.append(connection)
        do {
            try save(updated)
        } catch {
            try? secretStore.delete(id)
            throw error
        }
        connections = updated
        return connection
    }

    /// Metadata only (label/hosts/kind) — never touches the secret.
    func update(_ connection: Connection) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connections
        updated[index] = connection
        try save(updated)
        connections = updated
    }

    func setToken(_ token: String, for id: String) throws {
        try secretStore.set(token, for: id)
    }

    /// Removes the secret then the metadata.
    func delete(id: String) throws {
        try secretStore.delete(id)
        var updated = connections
        updated.removeAll { $0.id == id }
        try save(updated)
        connections = updated
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [Connection] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Connection].self, from: data)) ?? []
    }

    /// Pretty-printed, sorted-keys, ISO-8601, atomic — matches
    /// `AppLibraryStore`/`AppletManifest`'s on-disk JSON discipline.
    private func save(_ connections: [Connection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(connections)
        DreamuxStateDir.ensure(containing: metadataURL)
        try data.write(to: metadataURL, options: .atomic)
    }
}
