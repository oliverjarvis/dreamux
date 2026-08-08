// Sources/Dreamux/Views/ProjectGraphView.swift
import SwiftUI

/// The project's plan-dependency DAG as a compact dot strip in the sidebar
/// rail, laid out by `FlowLayoutEngine` (SwiftDagre). A tap on any node
/// reports its plan id via `onSelectPlan`.
///
/// The full-size shape this used to offer is gone: the Flows pane's
/// dependency arrangement IS that graph now, drawn by React Flow with its
/// own dagre. `FlowLayoutEngine` stays in use, and tested, for this rail —
/// a 16pt-dot strip whose look does not need to match the canvas.
struct ProjectGraphView: View {
    let graph: ProjectGraph
    let onSelectPlan: (String) -> Void

    private var layout: FlowLayout {
        FlowLayoutEngine.layout(nodes: graph.nodes, edges: graph.edges,
                                nodeSize: CGSize(width: 16, height: 16),
                                rankGap: 16, siblingGap: 14, margin: 8)
    }

    var body: some View {
        let l = layout
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for edge in graph.edges {
                    let pts = l.edgePoints[.init(from: edge.from, to: edge.to)]
                        ?? [l.positions[edge.from], l.positions[edge.to]].compactMap { $0 }
                    guard pts.count >= 2 else { continue }
                    var line = Path(); line.move(to: pts.first!); line.addLine(to: pts.last!)
                    ctx.stroke(line, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1.2)
                }
            }
            .frame(width: l.size.width, height: l.size.height)
            ForEach(graph.nodes) { node in
                if let p = l.positions[node.id] {
                    nodeView(node).position(p)
                }
            }
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
    }

    private func nodeView(_ node: FlowNode) -> some View {
        let blocked = graph.blockedIDs.contains(node.id)
        let color = FlowStatusGlyph.color(node.status)
        return Circle()
            .strokeBorder(blocked ? Color.secondary : color,
                          style: StrokeStyle(lineWidth: 1.5, dash: blocked ? [3, 2] : []))
            .background(Circle().fill(
                node.status == .done || node.status == .running ? color : Color.clear))
            .frame(width: 12, height: 12)
            .onTapGesture { onSelectPlan(node.id) }
    }
}
