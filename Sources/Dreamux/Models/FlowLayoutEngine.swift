import Foundation
import CoreGraphics
import SwiftDagre

struct FlowLayout: Equatable {
    let positions: [String: CGPoint]   // node id → CENTER point
    let size: CGSize
    /// Routed waypoints per non-self edge, in the same coordinate space as
    /// `positions` — the view draws a smooth path through them. Self-edges
    /// (loops) are excluded here; the view renders their arc.
    let edgePoints: [EdgeKey: [CGPoint]]

    struct EdgeKey: Hashable {
        let from: String
        let to: String
    }
}

/// Layered (Sugiyama-style) DAG layout for a lane's flow graph, delegated
/// to SwiftDagre — a pure-Swift port of dagre (network-simplex ranking,
/// barycenter crossing reduction, Brandes-Köpf coordinate assignment, and
/// routed edge waypoints). This type owns the mapping to/from our
/// `FlowNode`/`FlowEdge` model and keeps a stable interface (`positions`,
/// `size`, `nodeSize`) so the view and its callers don't know about dagre.
enum FlowLayoutEngine {
    static let nodeSize = CGSize(width: 150, height: 44)
    /// Vertical gap between ranks (dagre `ranksep`).
    static let rankGap: CGFloat = 48
    /// Horizontal gap between siblings in a rank (dagre `nodesep`).
    static let siblingGap: CGFloat = 30
    /// Margin dagre reserves around the whole graph — also the room the
    /// view's self-loop arc bulges into off the session node's edge.
    static let margin: CGFloat = 24

    static func layout(
        nodes: [FlowNode], edges: [FlowEdge],
        nodeSize: CGSize = Self.nodeSize, rankGap: CGFloat = Self.rankGap,
        siblingGap: CGFloat = Self.siblingGap, margin: CGFloat = Self.margin
    ) -> FlowLayout {
        guard !nodes.isEmpty else {
            return FlowLayout(positions: [:], size: .zero, edgePoints: [:])
        }

        let graph = Graph<DagreNodeLabel, DagreEdgeLabel>(
            options: GraphOptions(directed: true))

        let options = LayoutOptions()
        options.rankdir = .topBottom
        options.nodesep = Double(siblingGap)
        options.ranksep = Double(rankGap)
        options.marginx = Double(margin)
        options.marginy = Double(margin)
        graph.setGraph(options)

        // Keep direct references to the label instances — dagre mutates
        // them in place, so we read x/y/points straight off them after.
        var nodeLabels: [String: DagreNodeLabel] = [:]
        for node in nodes {
            let label = DagreNodeLabel(
                width: Double(nodeSize.width), height: Double(nodeSize.height))
            nodeLabels[node.id] = label
            _ = graph.setNode(node.id, label: label)
        }

        // Self-edges (loops) never enter the DAG — dagre lays out acyclic
        // graphs and the view draws the loop as a self-arc. Only wire edges
        // between two distinct, known nodes.
        let nodeIDs = Set(nodes.map(\.id))
        var edgeLabels: [FlowLayout.EdgeKey: DagreEdgeLabel] = [:]
        for edge in edges where edge.from != edge.to
            && nodeIDs.contains(edge.from) && nodeIDs.contains(edge.to) {
            let key = FlowLayout.EdgeKey(from: edge.from, to: edge.to)
            guard edgeLabels[key] == nil else { continue }
            let label = DagreEdgeLabel()
            edgeLabels[key] = label
            _ = try? graph.setEdge(edge.from, edge.to, label: label, name: nil)
        }

        do {
            try SwiftDagreLayout.layout(graph, options: options)
        } catch {
            // Degrade rather than crash — an empty layout renders as
            // stacked nodes at the origin, not a broken window.
            return FlowLayout(positions: [:], size: .zero, edgePoints: [:])
        }

        var positions: [String: CGPoint] = [:]
        for (id, label) in nodeLabels {
            positions[id] = CGPoint(x: label.x, y: label.y)
        }

        var edgePoints: [FlowLayout.EdgeKey: [CGPoint]] = [:]
        for (key, label) in edgeLabels where !label.points.isEmpty {
            edgePoints[key] = label.points.map { CGPoint(x: $0.x, y: $0.y) }
        }

        let size = CGSize(width: options.width, height: options.height)
        return FlowLayout(positions: positions, size: size, edgePoints: edgePoints)
    }
}
