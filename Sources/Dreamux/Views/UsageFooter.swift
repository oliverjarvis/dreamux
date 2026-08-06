import SwiftUI

/// The quota gauge pinned below the sidebar's scroll view, so it stays
/// put while the workspace list scrolls.
///
/// Renders nothing at all — its hairline included — until a reading has
/// arrived, so an install that has never run a subscriber session in a
/// Dreamux tab sees no empty gauge and no zeroed one. Because a reading
/// persists across launches, that is a one-time state in practice.
struct UsageFooter: View {
    @Bindable var store: UsageStore

    @State private var showDetail = false
    @State private var hovered = false

    var body: some View {
        if let snapshot = store.snapshot {
            let display = UsageDisplay.make(snapshot: snapshot, at: store.now)
            VStack(spacing: 0) {
                // The one horizontal rule the sidebar permits, in the
                // same idiom as the one between the pinned tiles and the
                // sections below them.
                Color.primary.opacity(0.08)
                    .frame(height: 1)
                    .padding(.horizontal, 10)

                Button { showDetail = true } label: {
                    HStack(spacing: 14) {
                        if let row = display.fiveHour { gauge(row) }
                        if let row = display.sevenDay { gauge(row) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if hovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .padding(.horizontal, 4)
                    }
                }
                .onHover { hovered = $0 }
                .popover(isPresented: $showDetail, arrowEdge: .top) {
                    detail(display)
                }
                .help("Claude subscription usage")
            }
            .padding(.bottom, 6)
        }
    }

    /// `5h ▓▓▓▓▓▒▒▒▒▒ 41%` as a real bar: label, capsule track with a
    /// tinted fill, figure. The tint shifts as the window fills.
    private func gauge(_ row: UsageDisplay.Row) -> some View {
        HStack(spacing: 6) {
            Text(row.label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint(row.level))
                        .frame(width: max(2, proxy.size.width * row.fraction))
                }
            }
            .frame(width: 54, height: 5)
            Text(row.percentText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func tint(_ level: UsageLevel) -> Color {
        switch level {
        case .calm: return .accentColor
        case .warm: return .orange
        case .hot: return .red
        }
    }

    private func detail(_ display: UsageDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow(title: "Session (5h)", row: display.fiveHour)
            detailRow(title: "Week (7d)", row: display.sevenDay)
            // A separator inside a popover, not a rule under a sidebar
            // section header — CLAUDE.md forbids the latter, not this.
            Divider()
            Text(display.ageText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Toggle("Show in menu bar", isOn: $store.menuBarVisible)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private func detailRow(title: String, row: UsageDisplay.Row?) -> some View {
        if let row {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13))
                Spacer(minLength: 12)
                Text(row.percentText)
                    .font(.system(size: 13).monospacedDigit())
                if let reset = row.resetText {
                    Text("·").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(reset).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
