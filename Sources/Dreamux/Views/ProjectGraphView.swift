// Sources/Dreamux/Views/ProjectGraphView.swift
import SwiftUI

/// Renders a `ProjectGraph` (the project's plan-dependency DAG) laid out by
/// `FlowLayoutEngine` — full-size nodes on the Flows "This project" panel,
/// tiny dots in `compact` mode (Task 6's rail). A tap on any node reports
/// its plan id via `onSelectPlan` so the caller can zoom to that lane.
struct ProjectGraphView: View {
    let graph: ProjectGraph
    let compact: Bool
    let onSelectPlan: (String) -> Void

    private var layout: FlowLayout {
        compact
            ? FlowLayoutEngine.layout(nodes: graph.nodes, edges: graph.edges,
                                      nodeSize: CGSize(width: 16, height: 16),
                                      rankGap: 16, siblingGap: 14, margin: 8)
            : FlowLayoutEngine.layout(nodes: graph.nodes, edges: graph.edges)
    }

    var body: some View {
        let l = layout
        ZStack(alignment: .topLeading) {
            // edges
            Canvas { ctx, _ in
                for edge in graph.edges {
                    let pts = l.edgePoints[.init(from: edge.from, to: edge.to)]
                        ?? [l.positions[edge.from], l.positions[edge.to]].compactMap { $0 }
                    guard pts.count >= 2 else { continue }
                    if compact {
                        var line = Path(); line.move(to: pts.first!); line.addLine(to: pts.last!)
                        ctx.stroke(line, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1.2)
                    } else {
                        ctx.stroke(FlowEdgeGeometry.smoothedPath(pts),
                                   with: .color(Color(nsColor: .separatorColor)), lineWidth: 1.6)
                        if let head = FlowEdgeGeometry.arrowheadPath(into: pts.last!, along: pts) {
                            ctx.fill(head, with: .color(Color(nsColor: .separatorColor)))
                        }
                    }
                }
            }
            .frame(width: l.size.width, height: l.size.height)
            // nodes
            ForEach(graph.nodes) { node in
                if let p = l.positions[node.id] {
                    nodeView(node).position(p)
                }
            }
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func nodeView(_ node: FlowNode) -> some View {
        let blocked = graph.blockedIDs.contains(node.id)
        let color = FlowStatusGlyph.color(node.status)
        if compact {
            Circle()
                .strokeBorder(blocked ? Color.secondary : color, style: StrokeStyle(lineWidth: 1.5, dash: blocked ? [3, 2] : []))
                .background(Circle().fill(node.status == .done || node.status == .running ? color : Color.clear))
                .frame(width: 12, height: 12)
                .onTapGesture { onSelectPlan(node.id) }
        } else {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(node.label).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).foregroundStyle(blocked ? .secondary : .primary)
            }
            .padding(.horizontal, 11).frame(height: FlowLayoutEngine.nodeSize.height)
            .frame(maxWidth: FlowLayoutEngine.nodeSize.width)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(blocked ? Color.secondary.opacity(0.5) : color,
                                      style: StrokeStyle(lineWidth: 1.4, dash: blocked ? [4, 3] : [])))
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelectPlan(node.id) }
        }
    }
}
