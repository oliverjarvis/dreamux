import SwiftUI

/// A pinned tile in the project sidebar's Arc-style grid. Built-in and
/// enumerable — reorder is persisted by raw value in `sidebar.json`.
///
/// Every case is a *destination* (it flips `sidebarMode`). Opening a
/// browser used to live here too, but it is an action you take from
/// wherever you are, not a place you go — it is now a tab kind (⌘⇧B,
/// the tab bar's ＋ menu, and the ⌘K palette). Retired raw values are
/// dropped by `SidebarLayoutStore`'s lenient decode.
enum SidebarTile: String, Codable, CaseIterable, Identifiable {
    case signals
    case flows
    case library

    var id: String { rawValue }

    /// Phosphor fill-weight icon. Already resizable — size with `.frame`,
    /// tint via `.renderingMode(.template)` + `foregroundStyle` at the
    /// call site.
    var icon: Image {
        switch self {
        case .signals: return PhosphorIcon.airTrafficControlFill
        case .flows: return PhosphorIcon.graphFill
        case .library: return PhosphorIcon.filesFill
        }
    }

    var tint: Color {
        switch self {
        case .signals: return .purple
        case .flows: return .orange
        case .library: return .teal
        }
    }

    var label: String {
        switch self {
        case .signals: return "Signals"
        case .flows: return "Flows"
        case .library: return "Context & MCPs"
        }
    }
}
