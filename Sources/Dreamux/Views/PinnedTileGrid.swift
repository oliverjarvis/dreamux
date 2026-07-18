// Sources/Dreamux/Views/PinnedTileGrid.swift
import SwiftUI
import UniformTypeIdentifiers

/// Arc-style pinned tiles at the top of the project sidebar: a 2-column
/// grid of square icon buttons, drag-reorderable. Currently holds
/// Signals + Web Browser; grows to a full 2×2+ as more tiles are pinned.
struct PinnedTileGrid: View {
    @Binding var tiles: [SidebarTile]
    let isSelected: (SidebarTile) -> Bool
    let isEnabled: (SidebarTile) -> Bool
    let onTap: (SidebarTile) -> Void
    let onReorder: () -> Void

    @State private var dragging: SidebarTile?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tiles) { tile in
                tileButton(tile)
                    .opacity(dragging == tile ? 0.4 : 1)
                    .onDrag {
                        dragging = tile
                        return NSItemProvider(object: tile.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(
                        item: tile,
                        items: $tiles,
                        dragging: $dragging,
                        onReorder: onReorder
                    ))
            }
        }
    }

    private func tileButton(_ tile: SidebarTile) -> some View {
        let selected = isSelected(tile)
        let enabled = isEnabled(tile)
        return Button {
            onTap(tile)
        } label: {
            VStack {
                tile.icon
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(tile.tint)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tile.tint.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? tile.tint.opacity(0.5) : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(tile.label)
    }
}
