import SwiftUI

/// A pinned tile in the project sidebar's Arc-style grid. Built-in and
/// enumerable — reorder is persisted by raw value in `sidebar.json`.
enum SidebarTile: String, Codable, CaseIterable, Identifiable {
    case signals
    case browser
    case library

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .signals: return "waveform.path.ecg"
        case .browser: return "globe"
        case .library: return "puzzlepiece.extension"
        }
    }

    var tint: Color {
        switch self {
        case .signals: return .purple
        case .browser: return .blue
        case .library: return .teal
        }
    }

    var label: String {
        switch self {
        case .signals: return "Signals"
        case .browser: return "Browser"
        case .library: return "Skills & MCPs"
        }
    }
}
