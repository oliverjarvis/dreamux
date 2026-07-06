// Sources/Dreamux/Views/FlowLaneView.swift
import SwiftUI

/// Shared status glyph vocabulary for the Flows surfaces (lanes, plan-row
/// dots, tile badge). Spec: ● running (amber, pulses), ○ queued (gray),
/// ✓ done (green), ✗ failed (red), ! needs-you (orange).
enum FlowStatusGlyph {
    static func symbol(_ status: FlowStatus) -> String {
        switch status {
        case .running: return "circle.fill"
        case .queued: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .waiting: return "exclamationmark.circle.fill"
        }
    }

    static func color(_ status: FlowStatus) -> Color {
        switch status {
        case .running: return .orange
        case .queued: return .secondary
        case .done: return .green
        case .failed: return .red
        case .waiting: return .orange
        }
    }
}

/// One lane: header row (glyph, title, elapsed, session chip) above a
/// horizontal source→drain pipeline of node chips. Scheduled lanes get
/// a recurrence marker in the header.
struct FlowLaneView: View {
    let lane: FlowsBoard.Lane
    var onJumpToTerminal: ((UUID) -> Void)?
    /// Zoom into this lane's DAG detail view. `nil` (e.g. a future
    /// preview/read-only context) just makes the row inert.
    var onZoom: (() -> Void)?
    /// Gate-card wiring; nil renders no card (previews, read-only hosts).
    var gateActions: FlowGateActions?
    var gateMergeActionable: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A plain tap gesture rather than wrapping header+pipeline in
            // a Button: `pipeline` is itself a horizontal ScrollView, and
            // nesting a scrollable view inside a Button's label risks the
            // button eating short scroll drags as taps. The needs-you
            // chip below is a SIBLING (its own Button, jump to terminal),
            // not nested inside this tap area, so the two actions never
            // both fire for the same tap.
            VStack(alignment: .leading, spacing: 6) {
                header
                pipeline
            }
            .contentShape(Rectangle())
            .onTapGesture { onZoom?() }

            if lane.effectiveStatus == .waiting, let detail = lane.flow.detail {
                needsYouChip(detail)
            }
            if let actions = gateActions, let workspaceID = waitingGateWorkspaceID {
                GateActionCard(
                    workspaceID: workspaceID,
                    mergeActionable: gateMergeActionable,
                    actions: actions)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if lane.flow.kind == .scheduled {
                Image(systemName: "arrow.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            statusGlyph(lane.effectiveStatus, size: 10)
            Text(lane.flow.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let startedAt = lane.flow.startedAt, lane.effectiveStatus == .running || lane.effectiveStatus == .waiting {
                Text(startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let chip = lane.sessionChip {
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let loopEdge = lane.flow.edges.first(where: { $0.kind == .loop }) {
                loopBadge(loopEdge)
            }
        }
    }

    /// A lane carries at most one `.loop` self-edge (see
    /// `FlowStore.reconcileLoopEdge`); its presence is the entire
    /// signal, so unlike `statusGlyph` this never pulses — a pulsing
    /// badge would compete with the iteration count for attention when
    /// the count itself is what's changing.
    private func loopBadge(_ edge: FlowEdge) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text("\(edge.label ?? "loop") ×\(edge.iterations ?? 0)")
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(FlowStatusGlyph.color(.running))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(FlowStatusGlyph.color(.running).opacity(0.12)))
        .help("Loop detected: \(edge.label ?? "") repeated \(edge.iterations ?? 0) times")
    }

    private var pipeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(lane.flow.nodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    nodeChip(node)
                }
            }
        }
    }

    private func nodeChip(_ node: FlowNode) -> some View {
        HStack(spacing: 4) {
            statusGlyph(node.status, size: 7)
            Text(node.label)
                .font(.caption)
                .lineLimit(1)
            if let multiplicity = node.counters.multiplicity, multiplicity > 1 {
                Text("×\(multiplicity)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(FlowStatusGlyph.color(node.status).opacity(node.status == .queued ? 0.06 : 0.12))
        )
        .help("\(node.label) — \(node.status.rawValue)")
    }

    private func needsYouChip(_ detail: String) -> some View {
        Button {
            if let ws = lane.flow.workspaceID { onJumpToTerminal?(ws) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11))
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
            }
            .foregroundStyle(FlowStatusGlyph.color(.waiting))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(FlowStatusGlyph.color(.waiting).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(lane.flow.workspaceID == nil)
        .help("Jump to this workspace's terminal")
    }

    /// Spec: "a gate node in waiting renders expanded". Plan lanes are
    /// the only lanes with a gate node; a workspace is required because
    /// every card action is workspace-scoped (a gate whose feature is
    /// gone has nothing to diff or merge). The board's bubbled
    /// effectiveStatus deliberately plays no part.
    private var waitingGateWorkspaceID: UUID? {
        guard lane.flow.kind == .plan,
              lane.flow.nodes.contains(where: { $0.kind == .gate && $0.status == .waiting })
        else { return nil }
        return lane.flow.workspaceID
    }

    /// Only `.running` pulses; reduce-motion pins full opacity.
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
            .onAppear { pulsing = true }
    }
}
