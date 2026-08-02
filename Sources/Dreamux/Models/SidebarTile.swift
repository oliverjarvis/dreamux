import SwiftUI

/// A pinned tile in the project sidebar's Arc-style grid. Built-in and
/// enumerable — reorder is persisted by raw value in `sidebar.json`.
enum SidebarTile: String, Codable, CaseIterable, Identifiable {
    case signals
    case browser
    case flows
    case library

    var id: String { rawValue }

    /// Phosphor fill-weight icon. Already resizable — size with `.frame`,
    /// tint via `.renderingMode(.template)` + `foregroundStyle` at the
    /// call site.
    var icon: Image {
        switch self {
        case .signals: return PhosphorIcon.airTrafficControlFill
        case .browser: return PhosphorIcon.globeFill
        case .flows: return PhosphorIcon.graphFill
        case .library: return PhosphorIcon.filesFill
        }
    }

    var tint: Color {
        switch self {
        case .signals: return .purple
        case .browser: return .blue
        case .flows: return .orange
        case .library: return .teal
        }
    }

    var label: String {
        switch self {
        case .signals: return "Signals"
        case .browser: return "Browser"
        case .flows: return "Flows"
        case .library: return "Context & MCPs"
        }
    }
}
