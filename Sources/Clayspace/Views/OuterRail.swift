import SwiftUI
import AppKit

/// Project-level navigation rail on the far left of the project window.
/// Drag the trailing edge to resize; as the rail widens, the section
/// tiles reflow from a single column into a 2- or 3-wide grid.
struct OuterRail: View {
    @Binding var selection: AppSection
    @Binding var width: CGFloat

    static let collapsedWidth: CGFloat = 64
    static let maxWidth: CGFloat = 220
    static let minWidth: CGFloat = 56

    var body: some View {
        ZStack(alignment: .trailing) {
            content
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial)

            ResizeHandle(width: $width)
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(AppSection.allCases) { section in
                    SectionTile(
                        section: section,
                        isActive: section == selection,
                        showsLabel: width >= Self.collapsedWidth + 28
                    )
                    .onTapGesture { selection = section }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
    }

    private var gridColumns: [GridItem] {
        // 1 column up to ~96, 2 columns up to ~160, 3 columns above.
        let count: Int
        if width >= 160 { count = 3 }
        else if width >= 96 { count = 2 }
        else { count = 1 }
        return Array(
            repeating: GridItem(.flexible(minimum: 40, maximum: 80), spacing: 8, alignment: .top),
            count: count
        )
    }
}

// MARK: - Section tile

private struct SectionTile: View {
    let section: AppSection
    let isActive: Bool
    let showsLabel: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(section.tint.opacity(isActive ? 0.95 : (isHovered ? 0.32 : 0.16)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(section.tint.opacity(isActive ? 0 : 0.28), lineWidth: 1)
                    )
                Image(systemName: section.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : section.tint)
            }
            .frame(width: 44, height: 44)

            if showsLabel {
                Text(section.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(section.title)
    }
}

// MARK: - Resize handle

/// 6pt drag strip on the trailing edge. Updates `width` live as the user
/// drags and flips the cursor to the horizontal-resize variant on hover.
///
/// The gesture runs in `.global` coordinate space (and we track the start
/// X ourselves) because as the rail resizes, the handle moves with it —
/// the default `.local` translation feeds back through the rail's frame
/// and produces jittery, oscillating drags.
private struct ResizeHandle: View {
    @Binding var width: CGFloat

    @State private var dragStartX: CGFloat?
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartX == nil {
                            dragStartX = value.startLocation.x
                            dragStartWidth = width
                        }
                        let startX = dragStartX ?? value.startLocation.x
                        let baseWidth = dragStartWidth ?? width
                        let delta = value.location.x - startX
                        let proposed = baseWidth + delta
                        width = min(OuterRail.maxWidth, max(OuterRail.minWidth, proposed))
                    }
                    .onEnded { _ in
                        dragStartX = nil
                        dragStartWidth = nil
                    }
            )
    }
}
