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
    /// In-app browser tabs, keyed by the same Bonsplit tab ids as the
    /// terminals — a tab id appears in exactly one of the three maps.
    private var webTabSessions: [TabID: WebTabSession] = [:]
    /// In-app Monaco editor tabs, keyed by the same Bonsplit tab ids as
    /// the terminals — a tab id appears in exactly one of the three maps.
    private var fileTabSessions: [TabID: FileEditorTabSession] = [:]
    /// Propagates each editor tab's `isDirty` to its Bonsplit tab chip,
    /// so an unsaved file shows the dirty indicator (mirrors how
    /// `titleObservers` propagates terminal titles).
    private var fileDirtyObservers: [TabID: FileTabDirtyObserver] = [:]
    /// Read-only Monaco diff tabs, keyed by the same Bonsplit tab ids as
    /// the other three maps — a tab id appears in exactly one of the
    /// four maps.
    private var diffTabSessions: [TabID: DiffTabSession] = [:]
    private var titleObservers: [TabID: TitleObserver] = [:]
    private var didBootstrap = false

    /// Tab id of the most recently created tab — set by
    /// `handleDidCreateTab` (which Bonsplit calls synchronously inside
    /// `createTab`), so `open…` methods can look up the session they
    /// just caused to exist. Cleared by `openAgentTab` before each
    /// creation so a vetoed/deduped creation reads as nil rather than a
    /// stale id.
    private(set) var lastCreatedTabID: TabID?

    /// Set by `bootstrapIfNeeded()` just before it creates the Overview
    /// tab, so `handleDidCreateTab` can recognize and claim it instead
    /// of spawning it a shell. Read once and cleared there.
    private var nextTabIsOverview = false

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

    /// Tab id of this workspace's pinned Overview tab, set the moment
    /// `bootstrapIfNeeded()` creates it. Nil before bootstrap.
    private(set) var overviewTabId: TabID?

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

    /// Idempotent — call from BonsplitView's `onAppear`. Creates the
    /// pinned Overview tab first (claimed via `nextTabIsOverview`, the
    /// same "claim the next created tab id" pattern `nextTabFileURL`/
    /// `nextTabWebURL`/`nextDiffRequest` use — needed because
    /// `overviewTabId` can't be assigned from `createTab`'s return value:
    /// `didCreateTab` fires *inside* that call, before it returns, and
    /// `handleDidCreateTab` needs to recognize the overview tab right
    /// then to skip spawning it a shell), then the shell tab, then
    /// re-selects the Overview so the workspace opens on its dashboard.
    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        nextTabIsOverview = true
        controller.createTab(title: "Overview", icon: "house.fill")
        controller.createTab(title: "shell", icon: "terminal.fill")
        if let overviewTabId {
            controller.selectTab(overviewTabId)
        }
    }

    /// True when `id` is this workspace's pinned Overview tab.
    func isOverviewTab(_ id: TabID) -> Bool {
        id == overviewTabId
    }

    /// Select the Overview tab, if bootstrap has run.
    func focusOverview() {
        guard let overviewTabId else { return }
        controller.selectTab(overviewTabId)
    }

    func tabSession(for tabId: TabID) -> TabSession? {
        tabSessions[tabId]
    }

    func webTabSession(for tabId: TabID) -> WebTabSession? {
        webTabSessions[tabId]
    }

    func fileTabSession(for tabId: TabID) -> FileEditorTabSession? {
        fileTabSessions[tabId]
    }

    func diffTabSession(for tabId: TabID) -> DiffTabSession? {
        diffTabSessions[tabId]
    }

    /// URLs of every in-app browser tab, for the e2e state dump.
    var webTabURLs: [URL] {
        webTabSessions.values.map(\.url)
    }

    /// Resolved paths of every open editor tab, for the e2e state dump.
    var openFileTabURLs: [URL] {
        fileTabSessions.values.map(\.fileURL)
    }

    /// Per-tab viewer facts for the e2e state dump: path, kind, active
    /// view mode, dirty flag. String-valued so it serializes as-is.
    var fileTabSummaries: [[String: String]] {
        fileTabSessions.values.map { session in
            [
                "path": session.fileURL.path,
                "kind": session.kind.rawValue,
                "mode": session.viewMode.rawValue,
                "dirty": session.isDirty ? "true" : "false",
            ]
        }
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

    private func handleDidCreateTab(_ tab: Tab, inPane pane: PaneID) {
        guard tabSessions[tab.id] == nil,
              webTabSessions[tab.id] == nil,
              fileTabSessions[tab.id] == nil,
              diffTabSessions[tab.id] == nil else { return }

        lastCreatedTabID = tab.id

        // Overview tab: claimed via the pending flag set by
        // `bootstrapIfNeeded()` just before `createTab` — it gets no
        // TabSession (no shell spawned for it; `TabContentView` renders
        // `WorkspaceOverviewView` for it instead).
        if nextTabIsOverview {
            nextTabIsOverview = false
            overviewTabId = tab.id
            return
        }

        // Keep the Overview pinned leftmost: any other tab that ends up
        // at index 0 in the pane that holds it (a drag reorder, or a
        // fresh tab created while nothing is selected) gets bumped
        // behind it. No-op if this pane doesn't contain the Overview.
        if let overviewTabId, controller.tabs(inPane: pane).first?.id != overviewTabId {
            controller.moveTab(overviewTabId, toIndex: 0, inPane: pane)
        }

        // File tab: the pending file URL (set by openFileTab just before
        // createTab) claims this tab id.
        if let fileURL = nextTabFileURL {
            nextTabFileURL = nil
            let fileSession = FileEditorTabSession(fileURL: fileURL)
            fileTabSessions[tab.id] = fileSession
            fileDirtyObservers[tab.id] = FileTabDirtyObserver(
                tabId: tab.id, session: fileSession, controller: controller
            )
            return
        }

        // Blank web tab: no URL, no dedup, address bar focused.
        if nextTabWebIsBlank {
            nextTabWebIsBlank = false
            webTabSessions[tab.id] = WebTabSession()
            return
        }

        // Web tab: the pending URL (set by openWebTab just before
        // createTab) claims this tab id instead of spawning a shell.
        if let url = nextTabWebURL {
            nextTabWebURL = nil
            webTabSessions[tab.id] = WebTabSession(url: url)
            return
        }

        // Diff tab: the pending request (set by openDiffTab just before
        // createTab) claims this tab id.
        if let request = nextDiffRequest {
            nextDiffRequest = nil
            diffTabSessions[tab.id] = DiffTabSession(request: request)
            return
        }

        let cwd = nextTabCwdOverride ?? workspace.workingDirectory
        nextTabCwdOverride = nil
        let session = TabSession(
            cwd: cwd,
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
        webTabSessions.removeValue(forKey: tabId)
        fileTabSessions.removeValue(forKey: tabId)
        fileDirtyObservers.removeValue(forKey: tabId)
        diffTabSessions.removeValue(forKey: tabId)
        titleObservers.removeValue(forKey: tabId)
        if planningTabID == tabId { planningTabID = nil }
        if agentTabID == tabId { agentTabID = nil }
        if runConfigTabID == tabId { runConfigTabID = nil }
        if composerTabID == tabId { composerTabID = nil }
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
            // If no other tab in this workspace still has unread, the
            // rail subtitle has been "read" too — wipe it.
            if !anyTabHasUnread {
                lastActivityMessage = nil
            }
            // Bonsplit's select doesn't touch AppKit's responder chain —
            // wire focus to the new tab's terminal so keystrokes land
            // without the user having to click in. Only for terminal-backed
            // tabs: the Overview (or any other non-terminal tab) has no
            // Ghostty surface to focus, and grabbing one anyway steals focus
            // from whatever terminal was last active elsewhere.
            if tabSession(for: tab.id) != nil {
                TerminalFocus.focusVisibleTerminal()
            }
        }
    }

    /// Files dropped onto the tab bar strip at a specific insertion index
    /// (where the drop's blue indicator was pointing). Directories aren't
    /// openable as file tabs, so they're filtered out; if nothing
    /// survives, do nothing. Opening each survivor in order leaves the
    /// last one selected, since `openFileTab` selects whichever tab it
    /// just created (or reused).
    ///
    /// Each newly-created tab is repositioned to land exactly at the
    /// drop's index -- `createTab` always lands per
    /// `configuration.newTabPosition` (`.current`, i.e. after the
    /// selected tab), not at an arbitrary index, so this needs a
    /// follow-up `moveTab`. Multiple files insert sequentially (first
    /// at `index`, next at `index + 1`, ...). A dropped file that's
    /// already open dedup-selects its existing tab instead of creating
    /// one -- `openFileTab` doesn't fire `didCreateTab` in that case, so
    /// `lastCreatedTabID` (cleared just before the call) stays nil and
    /// that file's position is left alone, as if it were the file that
    /// wasn't "inserted."
    private func handleDidReceiveFileDrops(_ urls: [URL], inPane pane: PaneID, atIndex index: Int) {
        let files = urls.filter { url in
            let resolved = url.resolvingSymlinksInPath()
            let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return !isDirectory
        }
        var insertionIndex = index
        for url in files {
            lastCreatedTabID = nil
            openFileTab(at: url)
            guard let newTabID = lastCreatedTabID else { continue }
            controller.moveTab(newTabID, toIndex: insertionIndex, inPane: pane)
            insertionIndex += 1
        }
    }

    // MARK: - Activity / unread

    var anyTabHasUnread: Bool {
        tabSessions.values.contains { $0.hasUnread }
    }

    /// True when every terminal tab's shell has been silent for at
    /// least `interval` — the queue's cheap "agent finished or stalled"
    /// probe.
    func allShellsQuiescent(for interval: TimeInterval) -> Bool {
        tabSessions.values.allSatisfy { $0.isShellQuiescent(for: interval) }
    }

    /// Terminal tab sessions in this workspace, in no particular order.
    /// e2e viewport readback only.
    var terminalTabSessions: [TabSession] {
        Array(tabSessions.values)
    }

    /// Override for the next tab's cwd. Used by the merge UI to drop a
    /// tab inside a conflicted worktree (which isn't symlinked into
    /// the aggregation directory). Read once and cleared in
    /// `handleDidCreateTab`.
    private var nextTabCwdOverride: String?

    /// Open a new tab whose shell starts in `path` instead of this
    /// workspace's default working directory. Used to drop the user
    /// (and their agent) straight into a conflicted worktree.
    func openTab(at path: String, title: String, icon: String = "exclamationmark.triangle.fill") {
        nextTabCwdOverride = path
        controller.createTab(title: title, icon: icon)
        // The didCreateTab delegate fires synchronously inside
        // createTab and consumes the override; just in case, clear here.
        nextTabCwdOverride = nil
    }

    /// Open a terminal tab cwd'd at `path` and hand back its TabSession
    /// so the caller can type into it (plan execution, planning
    /// kickoffs). Same mechanics as `openTab`, plus the return value.
    @discardableResult
    func openAgentTab(at path: String, title: String, icon: String) -> TabSession? {
        nextTabCwdOverride = path
        lastCreatedTabID = nil
        controller.createTab(title: title, icon: icon)
        nextTabCwdOverride = nil
        guard let id = lastCreatedTabID else { return nil }
        return tabSessions[id]
    }

    /// Tab id of this feature's plan-execution agent terminal — the tab a
    /// plan run typed its kickoff into. Tracked like `planningTabID` so the
    /// nudge center can reach the live agent to type re-read / course-
    /// correction prompts; cleared when the tab closes.
    private var agentTabID: TabID?

    /// Open the plan-execution agent terminal and remember it, so a later
    /// nudge can be typed into this same live agent. Same mechanics as
    /// `openAgentTab`, plus the tracking.
    @discardableResult
    func openPlanAgentTab(at path: String, title: String, icon: String) -> TabSession? {
        let tab = openAgentTab(at: path, title: title, icon: icon)
        agentTabID = lastCreatedTabID
        return tab
    }

    /// This feature's live plan-execution agent terminal, or nil when none
    /// is open (never run, or the tab was closed). The nudge center types
    /// into it.
    func agentTabSession() -> TabSession? {
        guard let id = agentTabID else { return nil }
        return tabSessions[id]
    }

    /// Tab id of this session's planning terminal, if one was opened.
    /// Cleared when the tab closes (`handleDidCloseTab`).
    private var planningTabID: TabID?

    /// Re-select the live planning tab, or open a fresh one cwd'd at
    /// `path`. One planning terminal per session keeps kickoffs from
    /// stacking tabs.
    func reuseOrOpenPlanningTab(at path: String) -> TabSession? {
        if let id = planningTabID, let existing = tabSessions[id] {
            controller.selectTab(id)
            return existing
        }
        let tab = openAgentTab(at: path, title: "planning", icon: "lightbulb")
        planningTabID = lastCreatedTabID
        return tab
    }

    /// Tab id of this workspace's run-config agent terminal — the tab the
    /// Overview Run card's Detect / Isolate / Diagnose type their prompts
    /// into. One per session so repeated clicks land in the same live
    /// agent (preserving its context); cleared when the tab closes.
    private var runConfigTabID: TabID?

    /// Re-select the live run-config terminal, or open a fresh one cwd'd
    /// at `path`. Mirrors `reuseOrOpenPlanningTab`.
    func reuseOrOpenRunConfigTab(at path: String) -> TabSession? {
        if let id = runConfigTabID, let existing = tabSessions[id] {
            controller.selectTab(id)
            return existing
        }
        let tab = openAgentTab(at: path, title: "run config", icon: "wand.and.stars")
        runConfigTabID = lastCreatedTabID
        return tab
    }

    /// Tab id of this workspace's composer-driven claude terminal — the
    /// tab the window's bottom prompt composer sends into. One per
    /// session; cleared when the tab closes.
    private var composerTabID: TabID?

    /// Re-select the live composer claude terminal, or open a fresh one
    /// cwd'd at `path`. `reused` tells the caller whether a claude REPL
    /// is presumed live in it (type into it) or the tab is fresh (launch
    /// claude seeded with the prompt).
    func reuseOrOpenComposerTab(at path: String) -> (tab: TabSession, reused: Bool)? {
        if let id = composerTabID, let existing = tabSessions[id] {
            controller.selectTab(id)
            return (existing, true)
        }
        guard let tab = openAgentTab(at: path, title: "claude", icon: "sparkles") else { return nil }
        composerTabID = lastCreatedTabID
        return (tab, false)
    }

    /// URL claimed by the next created tab — the web analog of
    /// `nextTabCwdOverride`, read once in `handleDidCreateTab`.
    private var nextTabWebURL: URL?

    /// Set by `openBlankWebTab` just before `createTab` so
    /// `handleDidCreateTab` builds a BLANK `WebTabSession` rather than one
    /// bound to a URL — the web analog of `nextTabIsOverview`. Read once
    /// and cleared there.
    private var nextTabWebIsBlank = false

    /// Open (or re-select) an in-app browser tab for `url`. Dedup is by
    /// URL: a runner's play fires its open every start, and the second
    /// play should bring the existing preview forward, not stack
    /// another copy of the same page. Blank tabs are excluded — they all
    /// share the `about:blank` key and each one is deliberately its own.
    func openWebTab(url: URL, title: String) {
        if let existing = webTabSessions.first(where: { !$0.value.isBlank && $0.value.url == url }) {
            controller.selectTab(existing.key)
            return
        }
        nextTabWebURL = url
        controller.createTab(title: title, icon: "globe")
        nextTabWebURL = nil
    }

    /// Open a browser tab with no destination — `about:blank`, nothing
    /// loaded, address bar focused (⌘⇧B, the tab bar's ＋ ▸ Browser). No
    /// dedup: firing it twice is a request for two tabs.
    func openBlankWebTab() {
        nextTabWebIsBlank = true
        controller.createTab(title: "New Tab", icon: "globe")
        nextTabWebIsBlank = false
    }

    /// File claimed by the next created tab — the editor analog of
    /// `nextTabWebURL`, read once in `handleDidCreateTab`.
    private var nextTabFileURL: URL?

    /// Open (or re-select) a Monaco editor tab for `fileURL`. Dedup is by
    /// resolved absolute path so the same file re-focuses its existing
    /// tab rather than stacking a duplicate (like `openWebTab`).
    /// `revealingLine` jumps the editor to that 1-based line — and flips
    /// a multi-mode tab (markdown) to source, since the rendered view
    /// has no scroll anchors.
    func openFileTab(at fileURL: URL, revealingLine: Int? = nil) {
        let resolved = fileURL.resolvingSymlinksInPath()
        if let existing = fileTabSessions.first(where: { $0.value.fileURL == resolved }) {
            controller.selectTab(existing.key)
            if let line = revealingLine {
                existing.value.viewMode = .source
                existing.value.reveal(line: line)
            }
            return
        }
        nextTabFileURL = resolved
        let kind = FileTabKind.kind(forPathExtension: resolved.pathExtension)
        controller.createTab(title: resolved.lastPathComponent, icon: kind.tabIcon)
        nextTabFileURL = nil
        if let line = revealingLine,
           let fresh = fileTabSessions.first(where: { $0.value.fileURL == resolved })?.value {
            fresh.viewMode = .source
            fresh.reveal(line: line)
        }
    }

    /// Request claimed by the next created tab — the diff analog of
    /// `nextTabFileURL`, read once in `handleDidCreateTab`.
    private var nextDiffRequest: DiffRequest?

    /// Open a read-only diff tab for a revision range. No dedup: a
    /// diff is a snapshot of a question ("what changed here?"), and
    /// asking again deserves fresh content.
    func openDiffTab(_ request: DiffRequest) {
        nextDiffRequest = request
        controller.createTab(title: request.title, icon: "plus.forwardslash.minus")
        nextDiffRequest = nil
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

        // Always badge — the user wants the red dot whenever a
        // notification arrives, even if they happen to be on this
        // workspace's active tab. Acknowledgement is explicit: clicking
        // the workspace row, switching tabs, or switching workspaces.
        tab.hasUnread = true

        // Bare BEL (`\a`) is rung by zsh, tab-completion, error tones, and
        // most CLI agents during normal operation — useless as a "the
        // agent wants me" signal. Only fire a macOS banner / subtitle
        // when the agent has *explicitly* sent a notification via OSC 9
        // or OSC 777 ; notify which carries a real message.
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        lastActivityMessage = trimmed

        NotificationManager.shared.notifyActivity(
            workspaceName: workspace.name,
            tabId: tab.id,
            tabTitle: tab.title,
            message: trimmed
        )
    }

    /// Explicit user acknowledgement — clears the badge on the active
    /// tab and wipes the rail subtitle. Called by the store when the
    /// user clicks an already-active workspace row.
    func dismissActivity() {
        clearActiveTabUnread()
        lastActivityMessage = nil
    }
}

// MARK: - Bonsplit delegate

/// Bonsplit's delegate is non-isolated; bridge to our `@MainActor` state via
/// `MainActor.assumeIsolated`, which is sound because `BonsplitController`
/// is itself `@MainActor` and always calls us from the main actor.
extension WorkspaceSession: BonsplitDelegate {
    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 shouldCloseTab tab: Tab,
                                 inPane pane: PaneID) -> Bool {
        MainActor.assumeIsolated { tab.id != self.overviewTabId }
    }

    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didCreateTab tab: Tab,
                                 inPane pane: PaneID) {
        MainActor.assumeIsolated { self.handleDidCreateTab(tab, inPane: pane) }
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

    nonisolated func splitTabBar(_ controller: BonsplitController,
                                 didReceiveFileDrops urls: [URL],
                                 inPane pane: PaneID,
                                 atIndex index: Int) {
        MainActor.assumeIsolated { self.handleDidReceiveFileDrops(urls, inPane: pane, atIndex: index) }
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

// MARK: - File tab dirty observer

/// Re-arms `withObservationTracking` so an editor tab's `isDirty` flows
/// back into the Bonsplit controller and shows the tab's dirty indicator.
@MainActor
private final class FileTabDirtyObserver {
    private let tabId: TabID
    private weak var session: FileEditorTabSession?
    private weak var controller: BonsplitController?

    init(tabId: TabID, session: FileEditorTabSession, controller: BonsplitController) {
        self.tabId = tabId
        self.session = session
        self.controller = controller
        arm()
    }

    private func arm() {
        guard let session else { return }
        withObservationTracking {
            _ = session.isDirty
        } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        guard let session, let controller else { return }
        controller.updateTab(tabId, isDirty: session.isDirty)
        arm()
    }
}
