import SwiftUI

/// Pure array-move used by `ReorderDropDelegate` (and unit-tested on its
/// own). Moves the dragged item into the hovered item's slot using
/// SwiftUI's `Array.move(fromOffsets:toOffset:)` semantics.
enum Reorder {
    static func moved<Item: Identifiable>(
        _ items: [Item],
        draggingID: Item.ID,
        overID: Item.ID
    ) -> [Item] {
        guard draggingID != overID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = items.firstIndex(where: { $0.id == overID })
        else { return items }
        var copy = items
        copy.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return copy
    }
}

/// Reusable live drag-reorder delegate — mirrors Bonsplit's
/// `TabDropDelegate`. Attach one per row/tile: as a drag hovers a
/// sibling, the array reorders under an animation ("stuff moves around
/// as you move it"); `onReorder` fires once on drop to persist.
struct ReorderDropDelegate<Item: Identifiable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var dragging: Item?
    var onReorder: () -> Void = {}

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        let reordered = Reorder.moved(items, draggingID: dragging.id, overID: item.id)
        guard !reordered.map(\.id).elementsEqual(items.map(\.id)) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { items = reordered }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onReorder()
        return true
    }
}
