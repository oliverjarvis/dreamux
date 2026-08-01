import SwiftUI

/// Capsule filter chip with a live count badge. The active chip tints
/// (teal by default); inactive chips sit on a neutral wash and brighten
/// on hover. Counts are "what you'd get by clicking this chip".
struct FilterChip: View {
    let label: String
    let count: Int
    let isActive: Bool
    var tint: Color = .teal
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? tint : Color.secondary)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isActive ? tint : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isActive
                            ? tint.opacity(0.25)
                            : Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive
                    ? tint.opacity(0.18)
                    : Color.primary.opacity(hovered ? 0.09 : 0.06)))
            .overlay(
                Capsule().strokeBorder(
                    isActive ? tint.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel("\(label), \(count) items")
    }
}
