// Sources/Dreamux/Views/FlowDetailView.swift
import SwiftUI

/// Zoomed-in DAG view of one lane: a breadcrumb, a pannable/scrollable
/// canvas laid out by `FlowLayoutEngine` (edges under nodes), and a
/// fixed-width inspector for whatever node is selected. Reached by
/// tapping a lane in `FlowsOverviewView`; `onBack` returns to the
/// overview.
struct FlowDetailView: View {
    let lane: FlowsBoard.Lane
    let onBack: () -> Void
    let onJumpToTerminal: (UUID) -> Void
    let onOpenTranscript: (String) -> Void

    @State private var selectedNodeID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private static let inspectorWidth: CGFloat = 280
    private static let canvasPadding: CGFloat = 20
    /// Self-loop arc radius. `FlowLayoutEngine` reserves a 24pt margin
    /// around the whole canvas, and a self edge only ever attaches to
    /// the "session" node, which is always alone in its rank (its sole
    /// parent is "src", its sole child rank is spawned agents) — so it
    /// never has a same-rank sibling to collide with; 18pt of
    /// rightward protrusion off its trailing edge fits inside that
    /// margin with room to spare.
    private static let loopRadius: CGFloat = 18
    private static let loopArcSteps = 24

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private var layout: FlowLayout {
        FlowLayoutEngine.layout(nodes: lane.flow.nodes, edges: lane.flow.edges)
    }

    private var selectedNode: FlowNode? {
        guard let selectedNodeID else { return nil }
        return lane.flow.nodes.first { $0.id == selectedNodeID }
    }

    private var selfLoopEdges: [FlowEdge] {
        lane.flow.edges.filter { $0.from == $0.to }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                inspector
                    .frame(width: Self.inspectorWidth)
            }
        }
        .onAppear { pulsing = true }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Text("◀")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to Flows")

            Text("flows")
                .foregroundStyle(.secondary)
            Text("/")
                .foregroundStyle(.tertiary)
            Text(lane.flow.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            statusGlyph(lane.effectiveStatus, size: 10)
            Text(lane.effectiveStatus.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            laneElapsed
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var laneElapsed: some View {
        if let started = lane.flow.startedAt {
            if let ended = laneEndedAt {
                Text(Self.elapsedFormatter.string(from: started, to: ended) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(started, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// The lane's drain node only carries a meaningful `endedAt` once
    /// the whole lane has finished — before that, the breadcrumb shows
    /// a live relative clock instead (see `laneElapsed`).
    private var laneEndedAt: Date? {
        guard lane.effectiveStatus == .done else { return nil }
        return lane.flow.nodes.first(where: { $0.id == "drain" })?.endedAt
    }

    // MARK: - Canvas

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in lane.flow.edges {
                        guard let from = layout.positions[edge.from] else { continue }
                        let style = StrokeStyle(
                            lineWidth: 1.5,
                            dash: edge.kind == .loop ? [4, 3] : []
                        )
                        if edge.from == edge.to {
                            // Anchored at the node's trailing edge, not
                            // its center, so the arc bulges out to the
                            // right of the node rather than around it.
                            let anchor = CGPoint(x: from.x + FlowLayoutEngine.nodeSize.width / 2, y: from.y)
                            context.stroke(selfLoopPath(anchor: anchor), with: .color(.secondary.opacity(0.45)), style: style)
                        } else {
                            guard let to = layout.positions[edge.to] else { continue }
                            var path = Path()
                            path.move(to: from)
                            path.addLine(to: to)
                            context.stroke(path, with: .color(.secondary.opacity(0.45)), style: style)
                        }
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)

                ForEach(lane.flow.nodes) { node in
                    nodeView(node)
                        .position(layout.positions[node.id] ?? .zero)
                }

                ForEach(selfLoopEdges, id: \.self) { edge in
                    if let from = layout.positions[edge.from] {
                        Text("↺ ×\(edge.iterations ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .position(
                                x: from.x + FlowLayoutEngine.nodeSize.width / 2,
                                y: from.y + FlowLayoutEngine.nodeSize.height / 2 + 10
                            )
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .padding(Self.canvasPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A ~270° arc around `anchor`, open on the side facing the node
    /// (west) so it reads as a loop departing and returning to the same
    /// point rather than a closed circle drawn on top of it. Built from
    /// explicit points (not `Path.addArc`'s `clockwise` flag) so the
    /// open side is unambiguous regardless of the flipped y-axis.
    private func selfLoopPath(anchor: CGPoint) -> Path {
        var path = Path()
        let startDegrees = -135.0
        let endDegrees = 135.0
        for step in 0...Self.loopArcSteps {
            let degrees = startDegrees + (endDegrees - startDegrees) * Double(step) / Double(Self.loopArcSteps)
            let radians = degrees * .pi / 180
            let point = CGPoint(
                x: anchor.x + Self.loopRadius * cos(radians),
                y: anchor.y + Self.loopRadius * sin(radians)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func nodeView(_ node: FlowNode) -> some View {
        let selected = node.id == selectedNodeID
        return Button {
            selectedNodeID = node.id
        } label: {
            HStack(spacing: 6) {
                statusGlyph(node.status, size: 9)
                Text(node.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let multiplicity = node.counters.multiplicity, multiplicity > 1 {
                    Text("×\(multiplicity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: FlowLayoutEngine.nodeSize.width, height: FlowLayoutEngine.nodeSize.height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlowStatusGlyph.color(node.status).opacity(node.status == .queued ? 0.06 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help("\(node.label) — \(node.status.rawValue)")
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let node = selectedNode {
                nodeInspector(node)
            } else {
                laneSummary
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var laneSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.flow.title)
                .font(.headline)
            if let chip = lane.sessionChip {
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(lane.flow.nodes.count) node\(lane.flow.nodes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func nodeInspector(_ node: FlowNode) -> some View {
        // Only the fixed "session" node (id "session") is the lane's own
        // claude session — every other `.agent`-kind node is a spawned
        // subagent, whose own transcript isn't what "open transcript"
        // resolves (see ContentView.onOpenTranscript).
        let isSessionNode = node.id == "session"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                statusGlyph(node.status, size: 10)
                Text(node.label)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(node.status.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let started = node.startedAt {
                if let ended = node.endedAt {
                    Text(Self.elapsedFormatter.string(from: started, to: ended) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(started, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastActivity = node.lastActivity {
                VStack(alignment: .leading, spacing: 4) {
                    Text("last activity")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(lastActivity)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(4)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Open transcript") {
                    if let sessionID = lane.flow.sessionID { onOpenTranscript(sessionID) }
                }
                .disabled(!isSessionNode || lane.flow.sessionID == nil)

                Button("Jump to terminal") {
                    if let workspaceID = lane.flow.workspaceID { onJumpToTerminal(workspaceID) }
                }
                .disabled(lane.flow.workspaceID == nil)
            }
        }
    }

    /// Only `.running` pulses; reduce-motion pins full opacity. Mirrors
    /// `FlowLaneView.statusGlyph` — a single shared `pulsing` flag drives
    /// every glyph in this view, same as one lane row drives all of its
    /// node chips.
    private func statusGlyph(_ status: FlowStatus, size: CGFloat) -> some View {
        Image(systemName: FlowStatusGlyph.symbol(status))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(FlowStatusGlyph.color(status))
            .opacity(status == .running && pulsing && !reduceMotion ? 0.35 : 1.0)
            .animation(
                status == .running && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing
            )
    }
}
