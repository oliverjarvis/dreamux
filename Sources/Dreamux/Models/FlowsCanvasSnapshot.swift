import Foundation

/// The Flows canvas wire model: a flat, `Codable` projection of what
/// `FlowsBoard.compose` already computed, plus dependency edges and
/// blocked-ness from `ProjectGraph`. The ONE place board → JSON happens.
/// Pure — no WebKit, no IO — so the mapping is unit-tested without a web
/// view, and `Equatable` so `FlowsCanvasSession` can gate pushes on a real
/// change rather than forwarding SwiftUI's render cadence into the canvas.
struct FlowsCanvasSnapshot: Codable, Equatable, Sendable {

    struct Aggregates: Codable, Equatable, Sendable {
        var running: Int
        var needsYou: Int
    }

    struct Progress: Codable, Equatable, Sendable {
        var done: Int
        var total: Int
    }

    struct Node: Codable, Equatable, Sendable {
        var id: String
        /// `FlowNodeKind.rawValue`.
        var kind: String
        var label: String
        /// `FlowStatus.rawValue`.
        var status: String
        /// `FlowNode.group` — a phase title; consecutive runs become bands.
        var group: String?
        var multiplicity: Int?
        var lastActivity: String?
        /// ISO 8601. The canvas formats elapsed time itself for live
        /// tickers; the native inspector keeps using DateComponentsFormatter.
        var startedAt: String?
        var endedAt: String?
    }

    struct Edge: Codable, Equatable, Sendable {
        var from: String
        var to: String
        /// `FlowEdgeKind.rawValue`. Self-loops (`from == to`) are included —
        /// the canvas excludes them from dagre and draws its own arc.
        var kind: String
        var iterations: Int?
    }

    struct Lane: Codable, Equatable, Sendable {
        var id: String
        var title: String
        /// `FlowKind.rawValue`.
        var kind: String
        /// `FlowsBoard.Lane.effectiveStatus.rawValue`.
        var status: String
        /// The `FlowsBoard.SectionKind` this lane would have landed in.
        /// It no longer positions anything — it styles (finished lanes
        /// render dimmed, as today's 0.6 opacity does).
        var section: String
        var sessionChip: String?
        var detail: String?
        /// Renders a subdued warning glyph: the detail line can't be trusted.
        var detailUnavailable: Bool
        /// `PRLifecycle.rawValue`, when the lane's workspace has a tracked PR.
        var prState: String?
        /// In `ProjectGraph.blockedIDs` — dashed border, secondary colour.
        var blocked: Bool
        var progress: Progress
        /// The lane id minus the `plan-` prefix, for plan lanes only.
        var planPath: String?
        /// Lane ids this lane runs after. Only blockers that HAVE a lane.
        var dependsOn: [String]
        var nodes: [Node]
        var edges: [Edge]
    }

    var schemaVersion: Int
    var aggregates: Aggregates
    var lanes: [Lane]

    static let currentSchemaVersion = 1

    /// Built per projection rather than held in a `static let`:
    /// `ISO8601DateFormatter` is a non-Sendable reference type, so a shared
    /// static is a Swift 6 concurrency error. `GitOperations` and
    /// `ClaudeFlowAdapter` construct theirs locally for the same reason.
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Project a composed board. Lane order is the board's own section order
    /// (needsYou, running, queued, scheduled, finished) flattened — stable,
    /// so two equal boards always yield an equal snapshot.
    static func make(board: FlowsBoard, projectGraph: ProjectGraph) -> FlowsCanvasSnapshot {
        let iso8601 = makeISO8601Formatter()
        var sectionByLaneID: [String: String] = [:]
        var ordered: [FlowsBoard.Lane] = []
        for section in board.sections {
            for lane in section.lanes {
                sectionByLaneID[lane.id] = section.kind.rawValue
                ordered.append(lane)
            }
        }
        let laneIDs = Set(ordered.map(\.id))
        let blocked = projectGraph.blockedIDs

        // waiter id → blocker ids, restricted to blockers that have a lane.
        var dependsOn: [String: [String]] = [:]
        for edge in projectGraph.edges where laneIDs.contains(edge.to) && laneIDs.contains(edge.from) {
            dependsOn[edge.to, default: []].append(edge.from)
        }

        let lanes = ordered.map { lane -> Lane in
            let flow = lane.flow
            let doneCount = flow.nodes.filter { $0.status == .done }.count
            return Lane(
                id: lane.id,
                title: flow.title,
                kind: flow.kind.rawValue,
                status: lane.effectiveStatus.rawValue,
                section: sectionByLaneID[lane.id] ?? FlowsBoard.SectionKind.queued.rawValue,
                sessionChip: lane.sessionChip,
                detail: flow.detail,
                detailUnavailable: flow.detailUnavailable,
                prState: lane.prState?.lifecycle.rawValue,
                blocked: blocked.contains(lane.id),
                progress: Progress(done: doneCount, total: flow.nodes.count),
                planPath: lane.id.hasPrefix("plan-") ? String(lane.id.dropFirst("plan-".count)) : nil,
                dependsOn: (dependsOn[lane.id] ?? []).sorted(),
                nodes: flow.nodes.map { node in
                    Node(
                        id: node.id,
                        kind: node.kind.rawValue,
                        label: node.label,
                        status: node.status.rawValue,
                        group: node.group,
                        multiplicity: node.counters.multiplicity,
                        lastActivity: node.lastActivity,
                        startedAt: node.startedAt.map { iso8601.string(from: $0) },
                        endedAt: node.endedAt.map { iso8601.string(from: $0) }
                    )
                },
                edges: flow.edges.map { edge in
                    Edge(from: edge.from, to: edge.to,
                         kind: edge.kind.rawValue, iterations: edge.iterations)
                }
            )
        }

        return FlowsCanvasSnapshot(
            schemaVersion: currentSchemaVersion,
            aggregates: Aggregates(running: board.runningCount, needsYou: board.needsYouCount),
            lanes: lanes
        )
    }

    /// JSON for `evaluateJavaScript`. `.sortedKeys` keeps the string stable
    /// across runs, which keeps diffs and e2e assertions readable.
    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
