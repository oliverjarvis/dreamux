import Foundation
import Observation

/// Per-project Flows canvas arrangement — saved node/lane positions,
/// which lanes are expanded, and the viewport — persisted to
/// `‹project›/.dreamux/flows-canvas.json` next to `sidebar.json`. Mirrors
/// `SidebarLayoutStore`'s JSON-atomic-write pattern.
///
/// Loading never reconciles against a board: ids absent from the current
/// board are IGNORED, not deleted, because a lane reappears when its plan
/// is rediscovered. Pruning happens the next time the canvas saves that
/// lane's positions (`setNodePositions` replaces the lane's whole map).
@MainActor
@Observable
final class FlowsCanvasLayoutStore {

    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    struct Viewport: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var zoom: Double
    }

    struct Payload: Codable, Equatable, Sendable {
        var lanePositions: [String: Point] = [:]
        /// laneID → (nodeID → parent-relative position).
        var nodePositions: [String: [String: Point]] = [:]
        /// LRU order, most-recently-expanded LAST.
        var expandedLaneIDs: [String] = []
        var viewport: Viewport?
    }

    /// Each expanded lane holds a lazy transcript tailer; three keeps file
    /// descriptors bounded and the canvas legible.
    static let expansionCap = 3

    private(set) var payload: Payload

    @ObservationIgnored private let configURL: URL

    init(configURL: URL) {
        self.configURL = configURL
        var loaded = Self.load(from: configURL) ?? Payload()
        loaded.expandedLaneIDs = Self.capped(loaded.expandedLaneIDs)
        payload = loaded
    }

    convenience init(project: Project) {
        self.init(configURL: project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("flows-canvas.json"))
    }

    // MARK: - Mutations

    /// Replaces the whole lane-box map; ids the canvas no longer draws are
    /// pruned by omission.
    func setLanePositions(_ positions: [String: Point]) {
        guard positions != payload.lanePositions else { return }
        payload.lanePositions = positions
        save()
    }

    /// Replaces one lane's node map. Ids that vanished from the lane are
    /// pruned here — this is the only place stale node ids are dropped.
    func setNodePositions(_ laneID: String, _ positions: [String: Point]) {
        guard positions != payload.nodePositions[laneID] else { return }
        payload.nodePositions[laneID] = positions
        save()
    }

    /// Truncated to `expansionCap`, dropping the OLDEST (front) entries.
    func setExpanded(_ ids: [String]) {
        let capped = Self.capped(ids)
        guard capped != payload.expandedLaneIDs else { return }
        payload.expandedLaneIDs = capped
        save()
    }

    func setViewport(_ viewport: Viewport) {
        guard viewport != payload.viewport else { return }
        payload.viewport = viewport
        save()
    }

    /// `tidyUp` for one lane: discard its saved positions so auto-layout
    /// takes over again.
    func clearLane(_ laneID: String) {
        guard payload.lanePositions[laneID] != nil || payload.nodePositions[laneID] != nil
        else { return }
        payload.lanePositions[laneID] = nil
        payload.nodePositions[laneID] = nil
        save()
    }

    /// `tidyUp` for the whole board. Expansion and viewport survive — tidy
    /// is about arrangement, not about closing lanes or moving the camera.
    func clearAll() {
        guard !payload.lanePositions.isEmpty || !payload.nodePositions.isEmpty else { return }
        payload.lanePositions = [:]
        payload.nodePositions = [:]
        save()
    }

    /// The `restoreLayout` payload, sent once after `ready`.
    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Persistence

    private static func capped(_ ids: [String]) -> [String] {
        ids.count <= expansionCap ? ids : Array(ids.suffix(expansionCap))
    }

    /// A corrupt or unreadable file is treated as absent; the board opens
    /// with auto-layout and rewrites the file on the next save.
    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        DreamuxStateDir.ensure(containing: configURL)
        try? data.write(to: configURL, options: .atomic)
    }
}
