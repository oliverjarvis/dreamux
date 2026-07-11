import SwiftUI

/// Shared building blocks for the workspace Overview (Mode A + Mode B), so
/// both read as one page: a status pill colored from the FlowStatus
/// vocabulary, the app's Capsule progress bar, an uppercase section label,
/// and the subtle surface-card modifier used in place of Divider rules.

/// A `Capsule` status chip. Color/glyph come from the shared FlowStatus
/// vocabulary (Global Constraint). `pulse` breathes the leading dot for the
/// live "Running" state, suppressed under Reduce Motion.
struct OverviewStatusPill: View {
    let text: String
    let flow: FlowStatus
    var pulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let color = FlowStatusGlyph.color(flow)
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(pulse && !reduceMotion && breathing ? 0.35 : 1)
                .animation(pulse && !reduceMotion
                           ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                           : nil,
                           value: breathing)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.16)))
        .onAppear { if pulse { breathing = true } }
    }
}

/// The app's Capsule progress bar (matches `PlansSpecsSection.planProgressBar`),
/// green when the run is complete and accent while it's in flight.
struct OverviewProgressBar: View {
    let fraction: Double
    let complete: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(complete ? Color.green : Color.accentColor)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 7)
    }
}

/// A 12pt uppercase section label with an optional trailing count.
struct OverviewSectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// The Overview's shared surface card: subtle fill + hairline border,
    /// radius 14 — used in place of `Divider()` rules to group content.
    func overviewSurface(padding: CGFloat = 18, radius: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
