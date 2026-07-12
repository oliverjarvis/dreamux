// Sources/Dreamux/Views/PRStatusGlyph.swift
import SwiftUI

/// PR-status visual vocabulary — a SIBLING to `FlowStatusGlyph`. Blocking
/// states red, checks amber, approved/merged green, draft/open/closed
/// secondary.
enum PRStatusGlyph {
    static func symbol(_ s: PRLifecycle) -> String {
        switch s {
        case .draft: return "pencil.circle"
        case .open: return "arrow.triangle.pull"
        case .checksRunning: return "clock.arrow.circlepath"
        case .checksFailed: return "xmark.octagon.fill"
        case .changesRequested: return "arrow.uturn.left.circle.fill"
        case .approved: return "checkmark.seal.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }
    static func color(_ s: PRLifecycle) -> Color {
        switch s {
        case .draft, .open, .closed: return .secondary
        case .checksRunning: return .orange
        case .checksFailed, .changesRequested: return .red
        case .approved, .merged: return .green
        }
    }
    static func label(_ s: PRLifecycle) -> String {
        switch s {
        case .draft: return "Draft"
        case .open: return "PR open"
        case .checksRunning: return "Checks running"
        case .checksFailed: return "Checks failed"
        case .changesRequested: return "Changes requested"
        case .approved: return "Approved"
        case .merged: return "Merged"
        case .closed: return "PR closed"
        }
    }
}

/// Pill badge for a lane's PR state; `onOpen` opens the PR url.
struct PRStatusBadge: View {
    let state: PRLaneState
    var onOpen: (() -> Void)? = nil
    var body: some View {
        let pill = HStack(spacing: 4) {
            Image(systemName: PRStatusGlyph.symbol(state.lifecycle))
                .font(.system(size: 10, weight: .semibold))
            Text(PRStatusGlyph.label(state.lifecycle)).font(.caption)
        }
        .foregroundStyle(PRStatusGlyph.color(state.lifecycle))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(PRStatusGlyph.color(state.lifecycle).opacity(0.12)))
        if let onOpen {
            Button(action: onOpen) { pill }.buttonStyle(.plain).help("Open pull request")
        } else {
            pill
        }
    }
}
