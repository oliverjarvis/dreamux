import Foundation
import Observation
import Bonsplit

/// A workspace's tab/split layout, driven by Bonsplit. Each tab in the
/// Bonsplit controller is paired with a `TabSession` (PTY + Ghostty surface)
/// that lives as long as the tab does — including across workspace switches.
@MainActor
@Observable
final class WorkspaceSession {
    let workspace: Workspace
    let controller: BonsplitController

    private var tabSessions: [TabID: TabSession] = [:]
    private var titleObservers: [TabID: TitleObserver] = [:]

    init(workspace: Workspace) {
        self.workspace = workspace

        // `keepAllAlive` is non-negotiable for terminals: a hidden tab whose
        // SwiftUI view is torn down also detaches the Ghostty surface, and
        // any output the shell produces while detached is dropped (see
        // `InMemoryTerminalSession.receive` — it short-circuits when no
        // surface is bound). Keep every tab's surface live so `top`, log
        // tails, and long-running builds keep updating in the background.
        let configuration = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current
        )
        self.controller = BonsplitController(configuration: configuration)
        self.controller.delegate = self

        // Bonsplit boots with one empty pane; seed it with a terminal.
        controller.createTab(title: "shell", icon: "terminal.fill")
    }

    func tabSession(for tabId: TabID) -> TabSession? {
        tabSessions[tabId]
    }

    // MARK: - Commands

    func createTab() {
        controller.createTab(title: "shell", icon: "terminal.fill")
    }

    func splitFocused(_ orientation: SplitOrientation) {
        controller.splitPane(orientation: orientation)
    }

    func closeFocusedTab() {
        guard let pane = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: pane) else { return }
        controller.closeTab(tab.id)
    }

    func selectTab(at index: Int) {
        guard let pane = controller.focusedPaneId else { return }
        let tabs = controller.tabs(inPane: pane)
        guard tabs.indices.contains(index) else { return }
        controller.selectTab(tabs[index].id)
    }

    func navigateFocus(_ direction: NavigationDirection) {
        controller.navigateFocus(direction: direction)
    }

    func stop() {
        for session in tabSessions.values { session.stop() }
        tabSessions.removeAll()
        titleObservers.removeAll()
    }

    // MARK: - Delegate handling (called from main actor)

    private func handleDidCreateTab(_ tab: Tab) {
        guard tabSessions[tab.id] == nil else { return }
        let session = TabSession(cwd: workspace.workingDirectory)
        tabSessions[tab.id] = session
        titleObservers[tab.id] = TitleObserver(
            tabId: tab.id,
            tabSession: session,
            controller: controller
        )
    }

    private func handleDidCloseTab(_ tabId: TabID) {
        tabSessions[tabId]?.stop()
        tabSessions.removeValue(forKey: tabId)
        titleObservers.removeValue(forKey: tabId)
    }

    private func handleDidSplitPane(newPane: PaneID) {
        controller.createTab(title: "shell", icon: "terminal.fill", inPane: newPane)
    }
}

// MARK: - Bonsplit delegate

/// Bonsplit's delegate is non-isolated; bridge to our `@MainActor` state via
/// `MainActor.assumeIsolated`, which is sound because `BonsplitController`
/// is itself `@MainActor` and always calls us from the main actor.
extension WorkspaceSession: BonsplitDelegate {
    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didCreateTab tab: Tab,
                                 inPane pane: PaneID) {
        MainActor.assumeIsolated { self.handleDidCreateTab(tab) }
    }

    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didCloseTab tabId: TabID,
                                 fromPane pane: PaneID) {
        MainActor.assumeIsolated { self.handleDidCloseTab(tabId) }
    }

    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didSplitPane originalPane: PaneID,
                                 newPane: PaneID,
                                 orientation: SplitOrientation) {
        MainActor.assumeIsolated { self.handleDidSplitPane(newPane: newPane) }
    }
}

// MARK: - Title observer

/// Re-arms `withObservationTracking` so OSC-set terminal titles flow back
/// into the Bonsplit controller and update the tab chip's label.
@MainActor
private final class TitleObserver {
    private let tabId: TabID
    private weak var tabSession: TabSession?
    private weak var controller: BonsplitController?

    init(tabId: TabID, tabSession: TabSession, controller: BonsplitController) {
        self.tabId = tabId
        self.tabSession = tabSession
        self.controller = controller
        arm()
    }

    private func arm() {
        guard let tabSession else { return }
        withObservationTracking {
            _ = tabSession.viewState.title
        } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        guard let tabSession, let controller else { return }
        controller.updateTab(tabId, title: tabSession.title)
        arm()
    }
}
