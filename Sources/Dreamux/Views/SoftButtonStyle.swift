import SwiftUI

/// A soft, borderless action-button style that matches the header run/git
/// pills' shape — rounded (radius 8) with comfortable padding and a subtle
/// fill that deepens on press — but with no stroke, unlike those outlined
/// pills. Use for chrome action buttons (Open terminal, View changes, Plan
/// something here, …) so they read as one set without hard borders.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    /// `.buttonStyle(.soft)` — the borderless rounded action pill.
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}
