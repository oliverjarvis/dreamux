import Foundation

struct FlowLayout: Equatable {
    let positions: [String: CGPoint]   // node id → CENTER point
    let size: CGSize
}

enum FlowLayoutEngine {
    static let nodeSize = CGSize(width: 150, height: 44)
    static let rankGap: CGFloat = 56
    static let siblingGap: CGFloat = 18

    /// Top-to-bottom layered layout: rank = longest path from a source
    /// (node with no incoming edges), row order within a rank = average
    /// of parents' column indices (stable tiebreak: node id).
    static func layout(nodes: [FlowNode], edges: [FlowEdge]) -> FlowLayout {
        guard !nodes.isEmpty else {
            return FlowLayout(positions: [:], size: CGSize(width: 0, height: 0))
        }

        // Build adjacency lists
        var outgoing: [String: [String]] = [:]
        var incoming: [String: [String]] = [:]

        for node in nodes {
            outgoing[node.id] = []
            incoming[node.id] = []
        }

        for edge in edges {
            outgoing[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: []].append(edge.from)
        }

        // Compute ranks via memoized longest-path DFS with visiting set for cycle safety
        var ranks: [String: Int] = [:]
        var visiting: Set<String> = []

        func computeRank(_ nodeId: String) -> Int {
            if let rank = ranks[nodeId] {
                return rank
            }

            if visiting.contains(nodeId) {
                // Cycle detected; ignore this back-edge
                return 0
            }

            visiting.insert(nodeId)

            let incomingNodes = incoming[nodeId, default: []]
            let maxParentRank = incomingNodes.map { computeRank($0) }.max() ?? -1
            let rank = maxParentRank + 1

            visiting.remove(nodeId)
            ranks[nodeId] = rank
            return rank
        }

        for node in nodes {
            _ = computeRank(node.id)
        }

        // Group nodes by rank
        var rankGroups: [Int: [String]] = [:]
        for node in nodes {
            let rank = ranks[node.id]!
            rankGroups[rank, default: []].append(node.id)
        }

        // Assign columns: sort each rank by (average parent column, id)
        var columns: [String: Int] = [:]

        for rank in rankGroups.keys.sorted() {
            var nodeIds = rankGroups[rank]!

            // Sort by average parent column, then by node id
            nodeIds.sort { id1, id2 in
                let parents1 = incoming[id1, default: []]
                let parents2 = incoming[id2, default: []]

                let avgCol1: Double
                if parents1.isEmpty {
                    avgCol1 = -1
                } else {
                    let sum = Double(parents1.map { columns[$0] ?? 0 }.reduce(0, +))
                    avgCol1 = sum / Double(parents1.count)
                }

                let avgCol2: Double
                if parents2.isEmpty {
                    avgCol2 = -1
                } else {
                    let sum = Double(parents2.map { columns[$0] ?? 0 }.reduce(0, +))
                    avgCol2 = sum / Double(parents2.count)
                }

                if abs(avgCol1 - avgCol2) > 0.001 {
                    return avgCol1 < avgCol2
                }
                return id1 < id2
            }

            // Assign column indices
            for (index, nodeId) in nodeIds.enumerated() {
                columns[nodeId] = index
            }
        }

        // Calculate positions
        var positions: [String: CGPoint] = [:]
        let margin: CGFloat = 24
        let nodeHeight = nodeSize.height
        let nodeWidth = nodeSize.width

        // Calculate dimensions
        let maxRank = rankGroups.keys.max() ?? 0
        let maxColumn = columns.values.max() ?? 0
        let columnSpacing = nodeWidth + siblingGap

        // Canvas height: top margin + node centers + bottom margin
        // bottommost center y = margin + maxRank * (nodeHeight + rankGap) + nodeHeight/2
        // bottommost node extends nodeHeight/2 below its center
        let canvasHeight = 2 * margin + CGFloat(maxRank) * (nodeHeight + rankGap) + nodeHeight

        // Canvas width: left/right margins + node spans
        // contentWidth spans from leftmost node left edge to rightmost node right edge
        let contentWidth = CGFloat(maxColumn) * columnSpacing + nodeWidth
        let canvasWidth = contentWidth + 2 * margin

        let centerX = canvasWidth / 2

        for (nodeId, column) in columns {
            let rank = ranks[nodeId]!
            let y = margin + CGFloat(rank) * (nodeHeight + rankGap) + nodeHeight / 2

            // Position columns globally centered by widest rank; single-node ranks start at the widest rank's left edge
            let columnCount = maxColumn + 1
            let startX = centerX - (CGFloat(columnCount - 1) * columnSpacing) / 2
            let x = startX + CGFloat(column) * columnSpacing

            positions[nodeId] = CGPoint(x: x, y: y)
        }

        return FlowLayout(positions: positions, size: CGSize(width: canvasWidth, height: canvasHeight))
    }
}
