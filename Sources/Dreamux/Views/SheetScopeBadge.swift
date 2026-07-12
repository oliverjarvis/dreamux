import SwiftUI

/// Capsule badge at the top of creation sheets naming the scope the new
/// thing lands in — the whole app (New Project) vs. the current project
/// (New Plan). ⌘N and ⌘P open visually similar sheets; this is the
/// at-a-glance differentiator.
struct SheetScopeBadge<Icon: View>: View {
    @ViewBuilder let icon: Icon
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25)))
    }
}
