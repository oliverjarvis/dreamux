import SwiftUI

/// The tab bar's new-tab control: a two-segment outlined pill in the shape
/// `CLAUDE.md` documents for header controls (cornerRadius 8, hairline
/// `.secondary.opacity(0.3)` border, faint `.primary.opacity(0.04)` fill,
/// a 1pt divider between segments, `chevron.down` on the segment that
/// opens a menu).
///
/// It lives in Bonsplit's fixed trailing cluster, not after the last tab:
/// the tab strip scrolls (there are fade overlays for exactly that), and a
/// `＋` that scrolls out of reach is worse than one a few points to the
/// right.
struct NewTabControl: View {
    /// What the `⌄` menu can open. `＋` is `.terminal` by definition.
    enum Kind: CaseIterable {
        case terminal, browser, file

        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .browser: return "Browser"
            case .file: return "File…"
            }
        }

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .browser: return "globe"
            case .file: return "doc"
            }
        }
    }

    let onNew: (Kind) -> Void

    @State private var plusHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onNew(.terminal)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 20)
                    .background(Color.primary.opacity(plusHovered ? 0.08 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.15)) { plusHovered = hovering }
            }
            .help("New terminal tab (⌘T)")

            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 14)

            Menu {
                ForEach(Kind.allCases, id: \.self) { kind in
                    Button {
                        onNew(kind)
                    } label: {
                        Label(kind.label, systemImage: kind.icon)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab…")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.trailing, 6)
    }
}
