import Foundation
import Observation

/// Per-project sidebar arrangement — the pinned-tile order and the
/// feature (Work Item) order — persisted to `‹project›/.dreamux/
/// sidebar.json` next to `run.toml`. Mirrors the JSON-atomic-write
/// pattern used by `ProjectStore`.
@MainActor
@Observable
final class SidebarLayoutStore {
    var tiles: [SidebarTile]
    private(set) var featureOrder: [String]
    var plansExpanded: Bool {
        didSet { if plansExpanded != oldValue { save() } }
    }

    @ObservationIgnored private let configURL: URL

    init(project: Project) {
        configURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("sidebar.json")
        let loaded = Self.load(from: configURL)
        tiles = Self.reconcile(loaded?.tiles ?? SidebarTile.allCases)
        featureOrder = loaded?.features ?? []
        plansExpanded = loaded?.plansExpanded ?? true
    }

    /// Order discovered features by the saved list: known names first in
    /// saved order, unknown names appended alphabetically. Records the
    /// resulting order so freshly-discovered features stick next launch.
    func ordered(_ discovered: [Workspace]) -> [Workspace] {
        var rank: [String: Int] = [:]
        for (i, name) in featureOrder.enumerated() { rank[name] = i }
        let known = discovered
            .filter { rank[$0.name] != nil }
            .sorted { rank[$0.name]! < rank[$1.name]! }
        let unknown = discovered
            .filter { rank[$0.name] == nil }
            .sorted { $0.name < $1.name }
        let result = known + unknown
        setFeatureOrder(result.map(\.name))
        return result
    }

    func setFeatureOrder(_ names: [String]) {
        guard names != featureOrder else { return }
        featureOrder = names
        save()
    }

    func persistTiles() {
        save()
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var tiles: [SidebarTile]
        var features: [String]
        var plansExpanded: Bool?
    }

    /// Keep saved tile order but guarantee every built-in tile is present
    /// (a tile added in a later app version won't be in an old file).
    private static func reconcile(_ saved: [SidebarTile]) -> [SidebarTile] {
        var result = saved
        for tile in SidebarTile.allCases where !result.contains(tile) {
            result.append(tile)
        }
        return result
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let payload = Payload(tiles: tiles, features: featureOrder, plansExpanded: plansExpanded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: configURL, options: .atomic)
    }
}
