import Bonsplit
import Foundation

/// Builds the real `PipController.ChipMarker` — the bridge between the
/// pip registry and Bonsplit's tab chips. Separate from `PipController`
/// so the registry itself never depends on `WorkspaceStore`.
@MainActor
enum PipChipMarker {
    static func make(store: WorkspaceStore) -> PipController.ChipMarker {
        PipController.ChipMarker(
            icon: { target in
                guard case .tab(let workspaceID, let tabID) = target,
                      let controller = controller(forWorkspace: workspaceID, in: store)
                else { return nil }
                return controller.tab(tabID)?.icon
            },
            setIcon: { target, icon in
                guard case .tab(let workspaceID, let tabID) = target,
                      let controller = controller(forWorkspace: workspaceID, in: store)
                else { return }
                // `updateTab`'s icon parameter is `String??`: the outer
                // `.some` means "change it", the inner value is what to.
                // Passing `icon` bare would read as "leave it alone".
                controller.updateTab(tabID, icon: .some(icon))
            }
        )
    }

    private static func controller(
        forWorkspace id: UUID, in store: WorkspaceStore
    ) -> BonsplitController? {
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return nil }
        return store.session(for: workspace).controller
    }
}
