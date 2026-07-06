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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            pipeline
            if lane.effectiveStatus == .waiting, let detail = lane.flow.detail {
                needsYouChip(detail)
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
        }
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
