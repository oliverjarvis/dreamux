import SwiftUI

/// Radius-14 card surface: neutral fill with a hover wash, and a tinted
/// fill + stroke when selected (the pinned-tile selection language).
/// Tracks hover internally so call sites stay one line.
struct CardSurface: ViewModifier {
    var isSelected: Bool
    var tint: Color = .teal

    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private var fill: Color {
        if isSelected { return tint.opacity(0.12) }
        return Color.primary.opacity(hovered ? 0.07 : 0.04)
    }

    private var stroke: Color {
        if isSelected { return tint.opacity(0.5) }
        return Color.primary.opacity(hovered ? 0.12 : 0.06)
    }
}

extension View {
    /// Selected wins over hover; both states animate.
    func cardSurface(isSelected: Bool, tint: Color = .teal) -> some View {
        modifier(CardSurface(isSelected: isSelected, tint: tint))
    }
}
