import XCTest
import Bonsplit
@testable import Dreamux

@MainActor
final class PipChipMarkerTests: XCTestCase {

    /// A store with one workspace holding one tab, plus that tab's id.
    private func makeStore() -> (WorkspaceStore, UUID, TabID) {
        let store = WorkspaceStore()
        let workspace = store.addWorkspace()
        let session = store.session(for: workspace)
        session.controller.createTab(title: "shell", icon: "terminal.fill")
        let tabID = session.controller.allTabIds.last!
        return (store, workspace.id, tabID)
    }

    func testReadsTheLiveChipIcon() {
        let (store, workspaceID, tabID) = makeStore()
        let marker = PipChipMarker.make(store: store)

        XCTAssertEqual(
            marker.icon(.tab(workspaceID: workspaceID, tabID: tabID)), "terminal.fill")
    }

    func testWritesAndRestoresTheChipIcon() {
        let (store, workspaceID, tabID) = makeStore()
        let marker = PipChipMarker.make(store: store)
        let target = PipTarget.tab(workspaceID: workspaceID, tabID: tabID)
        let controller = store.session(for: store.workspaces[0]).controller

        marker.setIcon(target, PipController.pippedChipIcon)
        XCTAssertEqual(controller.tab(tabID)?.icon, PipController.pippedChipIcon)

        marker.setIcon(target, "terminal.fill")
        XCTAssertEqual(controller.tab(tabID)?.icon, "terminal.fill")
    }

    /// An applet pip has no chip; the marker must shrug rather than trap.
    func testAppletTargetsHaveNoChip() {
        let (store, _, _) = makeStore()
        let marker = PipChipMarker.make(store: store)

        XCTAssertNil(marker.icon(.applet(id: UUID())))
        marker.setIcon(.applet(id: UUID()), "pip.fill")
    }

    /// A workspace that has since been removed resolves to no chip.
    func testUnknownWorkspaceHasNoChip() {
        let (store, _, tabID) = makeStore()
        let marker = PipChipMarker.make(store: store)

        XCTAssertNil(marker.icon(.tab(workspaceID: UUID(), tabID: tabID)))
    }
}
