import SwiftUI

/// Shared top-level sidebar section header (Applets, Workspaces, Context,
/// Repositories). Mirrors the pinned tile rows' geometry — 10pt inset,
/// Phosphor icon in a 22pt column, 11pt gap — so headers and rows share
/// one glyph column. When `isExpanded` is provided the whole row toggles
/// it and a caret sits at the far trailing edge; `trailing` slots an
/// accessory (e.g. the Repositories working indicator) before the caret.
/// Children of an expanded sidebar section — indented past a vertical
/// hierarchy line dropping from the header's icon column, so the
/// parent→child structure stays legible when several sections are open.
struct SidebarSectionChildren<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(.leading, 22)
        .overlay(alignment: .leading) {
            // Same hairline as the tiles/sections separator, centered
            // under the header's 22pt icon column (10pt inset + 11).
            Color.primary.opacity(0.08)
                .frame(width: 1)
                .padding(.leading, 20)
                .padding(.vertical, 2)
        }
    }
}

struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    let icon: Image
    var count: Int? = nil
    var isExpanded: Binding<Bool>? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String, icon: Image, count: Int? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.isExpanded = isExpanded
        self.trailing = trailing
    }

    @State private var isHovered = false

    var body: some View {
        if let isExpanded {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                row
            }
            .buttonStyle(.plain)
            // Same wash as the pinned tile rows — a clickable header must
            // light up like its row neighbours.
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .padding(.horizontal, 4)
                }
            }
            .onHover { isHovered = $0 }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 11) {
            icon
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 22)
                .foregroundStyle(.primary)
            Text(title)
                // Identical to the pinned tile rows — sections read by
                // position, icon, and caret, not by a different type style.
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing()
            if let isExpanded {
                PhosphorIcon.caretRightFill
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
            }
        }
        .padding(.horizontal, 10)
        // Same row metrics as the pinned tile rows so the hover pill
        // reads identically.
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
