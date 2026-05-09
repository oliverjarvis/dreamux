import Foundation
import Observation
import Bonsplit

/// A workspace's tab/split layout, driven by Bonsplit. Each tab in the
/// Bonsplit controller is paired with a `TabSession` (PTY + Ghostty surface)
/// that lives as long as the tab does — including across workspace switches.
@MainActor
@Observable
final class WorkspaceSession {
    var workspace: Workspace
    let controller: BonsplitController

    private var tabSessions: [TabID: TabSession] = [:]
    private var titleObservers: [TabID: TitleObserver] = [:]
    private var didBootstrap = false

    /// True when this workspace is the one currently visible in its window.
    /// The store flips this on selection changes; while false, bell events
    /// always mark tabs unread (the user can't see them yet). While true,
    /// bell events on the *active* tab don't mark unread (the user can
    /// already see them).
    var isVisible: Bool = false

    /// Most recent agent-emitted notification body, surfaced under the
    /// workspace's name in the Work Items rail. Cleared when the user
    /// switches into this workspace (re-entering "reads" the message).
    var lastActivityMessage: String? = nil

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

        // Bootstrap is deferred to `bootstrapIfNeeded()` (called from
        // BonsplitView's `onAppear`). Creating the first tab synchronously
        // in init worked for user-triggered workspaces but broke the three
        // workspaces seeded in `WorkspaceStore.init()` — those run during
        // the very first `ContentView` render, before the NSWindow has
        // finished forming, and the resulting Ghostty surface ends up in
        // a state where keyboard shortcuts, drag-drop, and splits never
        // engage. Deferring to onAppear lets every workspace bootstrap
        // under the same post-mount conditions.
    }

    /// Idempotent — call from BonsplitView's `onAppear`.
    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        controller.createTab(title: "shell", icon: "terminal.fill")
    }

    func tabSession(for tabId: TabID) -> TabSession? {
        tabSessions[tabId]
    }

    // MARK: - Commands

    func createTab() {
        controller.createTab(title: "shell", icon: "terminal.fill")
        TerminalFocus.focusVisibleTerminal()
    }

    func splitFocused(_ orientation: SplitOrientation) {
        controller.splitPane(orientation: orientation)
        TerminalFocus.focusVisibleTerminal()
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
        let session = TabSession(
            cwd: workspace.workingDirectory,
            onActivity: { [weak self, tabId = tab.id] message in
                Task { @MainActor in
                    self?.handleActivity(tabId: tabId, message: message)
                }
            }
        )
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

    private func handleDidSelectTab(_ tab: Tab) {
        // The tab the user just clicked into is now visible; clear its
        // attention badge. Other tabs in this workspace, and other
        // workspaces, keep theirs.
        if isVisible {
            tabSessions[tab.id]?.hasUnread = false
            // Bonsplit's select doesn't touch AppKit's responder chain —
            // wire focus to the new tab's terminal so keystrokes land
            // without the user having to click in.
            TerminalFocus.focusVisibleTerminal()
        }
    }

    // MARK: - Activity / unread

    var anyTabHasUnread: Bool {
        tabSessions.values.contains { $0.hasUnread }
    }

    /// Called by the store when this workspace becomes the visible one.
    /// Clears the badge on the active tab so re-entering a workspace
    /// dismisses the indicator naturally, and focuses the active
    /// terminal so the user can start typing immediately.
    func didBecomeVisible() {
        isVisible = true
        clearActiveTabUnread()
        // Re-entering the workspace counts as "reading" the most recent
        // notification, so wipe the rail subtitle too.
        lastActivityMessage = nil
        TerminalFocus.focusVisibleTerminal()
    }

    func didResignVisible() {
        isVisible = false
    }

    private func clearActiveTabUnread() {
        guard let pane = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: pane) else { return }
        tabSessions[tab.id]?.hasUnread = false
    }

    fileprivate func handleActivity(tabId: TabID, message: String?) {
        guard let tab = tabSessions[tabId] else { return }

        let activePaneTab = controller.focusedPaneId.flatMap { controller.selectedTab(inPane: $0) }
        let isVisibleAndActive = isVisible && activePaneTab?.id == tabId
        if !isVisibleAndActive {
            tab.hasUnread = true
        }

        // Bare BEL (`\a`) is rung by zsh, tab-completion, error tones, and
        // most CLI agents during normal operation — it's a useless signal
        // for "the agent wants me". Only fire a macOS banner when the
        // agent has *explicitly* sent a notification via an OSC sequence
        // (OSC 9 or OSC 777 ; notify) which carries a real message.
        // BELs without a payload still light the workspace badge above
        // so the user has a quiet visual indicator.
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Always store the most recent message so the rail row reflects
        // it — even if the user is currently looking at this workspace.
        // The subtitle is informational ("here's what the agent just
        // said"), so suppressing it when focused-and-active hid the
        // signal in the place the user is most likely to look.
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        lastActivityMessage = trimmed

        NotificationManager.shared.notifyActivity(
            workspaceName: workspace.name,
            tabId: tab.id,
            tabTitle: tab.title,
            message: trimmed
        )
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

    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didSelectTab tab: Tab,
                                 inPane pane: PaneID) {
        MainActor.assumeIsolated { self.handleDidSelectTab(tab) }
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
