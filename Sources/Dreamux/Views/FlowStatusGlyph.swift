// Sources/Dreamux/Views/FlowStatusGlyph.swift
import SwiftUI

/// The one mapping from `FlowStatus` to its SF Symbol and colour, shared by
/// every surface that shows lane or node status — the sidebar rail, the
/// Overview checklists, the gate card, the project graph, and (pushed as
/// CSS custom properties by `FlowsCanvasTheme`) the Flows canvas. Swift is
/// the source of truth for status colour; the web layer never picks its own.
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
