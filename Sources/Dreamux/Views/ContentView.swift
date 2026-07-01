import SwiftUI

/// The project window's three-column layout, as a single native
/// `NavigationSplitView`:
///
///   • sidebar — the project switcher (`ProjectsRail`),
///   • content — the selected project's Work Items (`WorkspaceSidebar`),
///   • detail  — the terminal / Run / Signals pane for the active feature.
///
/// The run-layer stores (`runConfig`/`signals`/`runners`) and `sidebarMode`
/// live here because both the content and detail columns need them — they
/// used to sit in a private `FeaturesDetail` wrapper, but a NavigationSplit-
/// View has to own all three columns in one place.
struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let layout: SidebarLayoutStore
    let projects: ProjectStore
    let currentProjectID: UUID
    let onSwitchProject: (UUID?) -> Void

    @State private var sidebarMode: SidebarMode = .workspace
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var runConfig: RunConfigStore
    @State private var signals: SignalStore
    @State private var runners: RunnerManager

    init(
        store: WorkspaceStore,
        repoStore: RepoStore,
        layout: SidebarLayoutStore,
        projects: ProjectStore,
        currentProjectID: UUID,
        onSwitchProject: @escaping (UUID?) -> Void
    ) {
        self.store = store
        self.repoStore = repoStore
        self.layout = layout
        self.projects = projects
        self.currentProjectID = currentProjectID
        self.onSwitchProject = onSwitchProject

        let runConfig = RunConfigStore(project: repoStore.project)
        let signals = SignalStore()
        let runners = RunnerManager(project: repoStore.project, signals: signals)
        runners.reload(from: runConfig.rawTOML)
        // URL opens land as a browser tab inside the worktree's own
        // workspace — the running app lives next to the terminals working
        // on it. No matching workspace (e.g. the runner is on the default
        // branch) falls back to the external browser.
        runners.openURLInApp = { [weak store] url, branch, title in
            guard let store,
                  let workspace = store.workspaces.first(where: { $0.name == branch })
            else { return false }
            store.session(for: workspace).openWebTab(url: url, title: title)
            return true
        }
        if E2EMode.isActive {
            // Don't open EXTERNAL browsers / run open commands during
            // automated runs — `openedTargets` still records every fire and
            // the e2e state dump asserts on it. In-app web tabs are
            // in-process and stay enabled so scenarios can assert them.
            runners.openOverride = { _ in }
        }
        _runConfig = State(initialValue: runConfig)
        _signals = State(initialValue: signals)
        _runners = State(initialValue: runners)
    }

    private var currentProject: Project? { projects.project(id: currentProjectID) }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectsRail(
                projects: projects,
                currentProjectID: currentProjectID,
                onSelect: onSwitchProject
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } content: {
            WorkspaceSidebar(
                store: store,
                repoStore: repoStore,
                runners: runners,
                layout: layout,
                sidebarMode: $sidebarMode
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 380)
        } detail: {
            mainPane
        }
        .navigationTitle(currentProject?.name ?? "")
        .navigationSubtitle(currentProject?.rootPath.path ?? "")
        .onAppear {
            // e2e only (no-op otherwise): hand the run-layer stores to the
            // automation server and sync the bridge with this window's
            // starting mode.
            E2ERegistry.shared.registerRunStores(
                projectID: repoStore.project.id,
                runners: runners,
                runConfig: runConfig,
                signals: signals
            )
            e2eBridge?.currentSidebarMode = sidebarMode
            consumePendingSidebarModeIfAny()
        }
        .onChange(of: e2eBridge?.pendingSidebarMode) { _, _ in
            consumePendingSidebarModeIfAny()
        }
        .onChange(of: sidebarMode) { _, newValue in
            e2eBridge?.currentSidebarMode = newValue
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch sidebarMode {
        case .workspace:
            WorkspaceTerminalContainer(store: store)
        case .run(let workspaceID):
            RunSetupView(
                project: repoStore.project,
                repoStore: repoStore,
                runConfig: runConfig,
                runners: runners,
                signals: signals,
                scope: store.workspaces.first(where: { $0.id == workspaceID })
            )
        case .signals:
            SignalsView(signals: signals, runners: runners)
        }
    }

    /// Bridge for this project window. `nil` whenever the e2e harness is
    /// inactive, which turns the consumption below into a no-op.
    private var e2eBridge: E2EBridge? {
        E2ERegistry.shared.bridge(forProject: repoStore.project.id)
    }

    /// The automation server can't reach this view's `@State`, so it parks
    /// the requested pane on the bridge and we adopt it here — same
    /// consume-and-clear pattern as `runners.pendingIsolation`.
    private func consumePendingSidebarModeIfAny() {
        guard let bridge = e2eBridge, let mode = bridge.pendingSidebarMode else { return }
        bridge.pendingSidebarMode = nil
        sidebarMode = mode
    }
}

/// Detail-pane swap inside a project window. `.workspace` shows the
/// terminal pane for the active feature; `.run` shows the Run page scoped
/// to a specific workspace (its play button was clicked); `.signals`
/// shows the project-wide log stream.
enum SidebarMode: Hashable {
    case workspace
    case run(workspaceID: UUID)
    case signals
}
