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
        .accessibilityValue(tab.isDirty ? "Modified" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            // The active tab is a top-rounded squircle whose flat bottom sits
            // flush against the content. Filled with the content-area color
            // and drawn opaquely to the bar's bottom edge, it covers the
            // bar's baseline so tab + content read as one continuous surface.
            UnevenRoundedRectangle(
                topLeadingRadius: TabBarMetrics.activeCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: TabBarMetrics.activeCornerRadius,
                style: .continuous
            )
            .fill(TabBarColors.activeTabBackground)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: TabBarMetrics.activeCornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: TabBarMetrics.activeCornerRadius,
                    style: .continuous
                )
                .fill(TabBarColors.activeTabLift)
            )
        } else {
            // Inactive tabs are floating squircle buttons: transparent until
            // hovered, then a soft wash. No separators, no accent line.
            RoundedRectangle(cornerRadius: TabBarMetrics.inactiveCornerRadius, style: .continuous)
                .fill(isHovered ? TabBarColors.hoveredTabBackground : Color.clear)
                .padding(.vertical, TabBarMetrics.inactiveVerticalInset)
                .padding(.horizontal, TabBarMetrics.inactiveHorizontalInset)
        }
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
