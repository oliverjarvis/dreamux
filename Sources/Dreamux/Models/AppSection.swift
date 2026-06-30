import Foundation
import SwiftUI

/// Top-level sections of a project window. Each entry shows up as a tile
/// in the outer rail and selects what's rendered in the detail area.
/// `features` is permanent — it hosts the workspace siderail, tabs, and
/// terminals. New sections can be added later by extending this enum.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case features

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "Features"
        }
    }

    var symbol: String {
        switch self {
        case .features: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .features: return .accentColor
        }
    }
}
