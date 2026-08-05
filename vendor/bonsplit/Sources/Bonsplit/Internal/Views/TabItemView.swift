import SwiftUI

/// Individual tab view with icon, title, close button, and dirty indicator
struct TabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            // Icon
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: TabBarMetrics.iconSize))
                    .foregroundStyle(isSelected ? TabBarColors.activeText : TabBarColors.inactiveText)
            }

            // Title
            Text(tab.title)
                .font(.system(size: TabBarMetrics.titleFontSize, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? TabBarColors.activeText : TabBarColors.inactiveText)

            // Attention dot: filled when the tab's occupant is blocked on
            // the user, hollow when it merely finished. Sits inside the
            // chip so it survives tab truncation, unlike a trailing badge.
            attentionDot

            Spacer(minLength: 4)

            // Close button or dirty indicator
            closeOrDirtyIndicator
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            maxHeight: .infinity
        )
        .background(tabBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: TabBarMetrics.hoverDuration)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(
            tab.attention == .blocked ? "Needs attention"
                : tab.attention == .done ? "Finished"
                : tab.isDirty ? "Modified" : ""
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var attentionDot: some View {
        switch tab.attention {
        case .blocked:
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        case .done:
            Circle().strokeBorder(TabBarColors.inactiveText, lineWidth: 1)
                .frame(width: 6, height: 6)
        case .working, .none:
            // EmptyView, so a quiet tab reserves no width at all.
            EmptyView()
        }
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        // Every tab is a floating squircle button; selection is the same
        // shape as hover, just a clearly stronger wash. No separators, no
        // accent line, no browser-style attached tab.
        RoundedRectangle(cornerRadius: TabBarMetrics.inactiveCornerRadius, style: .continuous)
            .fill(isSelected ? TabBarColors.selectedTabBackground
                : (isHovered ? TabBarColors.hoveredTabBackground : Color.clear))
            .padding(.vertical, TabBarMetrics.inactiveVerticalInset)
            .padding(.horizontal, TabBarMetrics.inactiveHorizontalInset)
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering)
            if tab.isDirty && !isHovered && !isCloseHovered {
                Circle()
                    .fill(TabBarColors.dirtyIndicator)
                    .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
            }

            // Close button (shown on hover)
            if isHovered || isCloseHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(isCloseHovered ? TabBarColors.activeText : TabBarColors.inactiveText)
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? TabBarColors.hoveredTabBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}
