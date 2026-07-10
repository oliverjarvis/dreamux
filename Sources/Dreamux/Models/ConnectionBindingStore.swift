import Foundation
import Observation

/// Per-applet slot→connectionId map: which `Connection` an applet's
/// declared `ConnectionSlot`s are bound to. Persisted under that applet's
/// own data dir (`.dreamux/appdata/<slug>/connections.json`) — bindings are
/// scoped to a single applet, unlike `ConnectionStore`'s app-wide registry.
@MainActor
@Observable
final class ConnectionBindingStore {
    /// `<dataDir>/connections.json`.
    let fileURL: URL

    private(set) var bindings: [String: String] = [:]

    /// Loads the slot→connectionId map already on disk at `dataDir`, if any.
    init(dataDir: URL) {
        fileURL = dataDir.appendingPathComponent("connections.json")
        bindings = Self.load(from: fileURL)
    }

    func connectionID(forSlot slot: String) -> String? {
        bindings[slot]
    }

    func bind(slot: String, toConnectionID id: String) throws {
        var updated = bindings
        updated[slot] = id
        try save(updated)
        bindings = updated
    }

    func unbind(slot: String) throws {
        var updated = bindings
        updated.removeValue(forKey: slot)
        try save(updated)
        bindings = updated
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ bindings: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bindings)
        DreamuxStateDir.ensure(containing: fileURL)
        try data.write(to: fileURL, options: .atomic)
    }
}
