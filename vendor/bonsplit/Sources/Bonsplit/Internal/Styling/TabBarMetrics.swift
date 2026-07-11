import Foundation

/// Sizing and spacing constants for the tab bar (following macOS HIG)
enum TabBarMetrics {
    // MARK: - Tab Bar

    static let barHeight: CGFloat = 40
    static let barPadding: CGFloat = 6

    // MARK: - Individual Tabs

    static let tabHeight: CGFloat = 36
    static let tabMinWidth: CGFloat = 140
    static let tabMaxWidth: CGFloat = 220
    static let tabCornerRadius: CGFloat = 0
    static let tabHorizontalPadding: CGFloat = 16
    static let tabSpacing: CGFloat = 3
    static let activeIndicatorHeight: CGFloat = 2

    // Squircle tabs: the active tab is a top-rounded shape that merges into
    // the content below (flat bottom, flush with the pane); inactive tabs are
    // floating squircle buttons inset inside the bar.
    static let activeCornerRadius: CGFloat = 9
    static let inactiveCornerRadius: CGFloat = 8
    static let inactiveVerticalInset: CGFloat = 5
    static let inactiveHorizontalInset: CGFloat = 3

    // MARK: - Tab Content

    static let iconSize: CGFloat = 14
    static let titleFontSize: CGFloat = 12
    static let closeButtonSize: CGFloat = 16
    static let closeIconSize: CGFloat = 9
    static let dirtyIndicatorSize: CGFloat = 8
    static let contentSpacing: CGFloat = 6

    // MARK: - Drop Indicator

    static let dropIndicatorWidth: CGFloat = 2
    static let dropIndicatorHeight: CGFloat = 20

    // MARK: - Split View

    static let minimumPaneWidth: CGFloat = 100
    static let minimumPaneHeight: CGFloat = 100
    static let dividerThickness: CGFloat = 1

    // MARK: - Animations

    static let selectionDuration: Double = 0.15
    static let closeDuration: Double = 0.2
    static let reorderDuration: Double = 0.3
    static let reorderBounce: Double = 0.15
    static let hoverDuration: Double = 0.1

    // MARK: - Split Animations (120fps via CADisplayLink)

    /// Duration for split entry animation (fast and snappy like Hyprland)
    static let splitAnimationDuration: Double = 0.15
}
