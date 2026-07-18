import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    // MARK: - Tab Bar Background

    static var barBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var barMaterial: Material {
        .bar
    }

    // MARK: - Tab States

    /// The active tab is filled with the content-area color so it reads as
    /// continuous with the pane below it.
    static var activeTabBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    /// A subtle lift layered over the active tab so it clearly reads as
    /// raised/selected against the recessed bar. Adding light shows up on the
    /// dark theme (where darkening the near-black bar barely registers); on a
    /// light theme it's negligible and the bar recess carries the contrast.
    static var activeTabLift: Color {
        Color.white.opacity(0.07)
    }

    /// Hover wash for an inactive squircle button — a soft, theme-aware
    /// lightening that works on both the dark and light bar.
    static var hoveredTabBackground: Color {
        Color(nsColor: .labelColor).opacity(0.08)
    }

    /// The selected tab is the same floating squircle as a hovered one,
    /// just a clearly stronger wash — selection reads by weight, not by a
    /// different shape.
    static var selectedTabBackground: Color {
        Color(nsColor: .labelColor).opacity(0.14)
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    /// A subtle darkening laid over the bar so it reads as a recessed strip
    /// distinct from the (brighter) active tab + content it frames.
    static var barRecess: Color {
        Color.black.opacity(0.14)
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: .labelColor)
    }

    static var inactiveText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: .labelColor).opacity(0.6)
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}
