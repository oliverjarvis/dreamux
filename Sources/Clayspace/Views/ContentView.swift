import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    let projects: ProjectStore
    let currentProjectID: UUID
    let onSwitchProject: (UUID) -> Void

    @State private var section: AppSection = .features
    @State private var railWidth: CGFloat = OuterRail.collapsedWidth

    var body: some View {
        HStack(spacing: 0) {
            ProjectsRail(
                projects: projects,
                currentProjectID: currentProjectID,
                onSelect: onSwitchProject
            )
            .frame(width: ProjectsRail.width)

            Divider()

            // The OuterRail only earns its space when there's more than
            // one section to switch between — until then, the lone
            // Features tile sits next to the projects rail as a vestigial
            // sliver, so we just show the detail directly.
            if AppSection.allCases.count > 1 {
                OuterRail(selection: $section, width: $railWidth)
                    .frame(width: railWidth)

                Divider()
            }

            sectionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch section {
        case .features:
            FeaturesDetail(store: store, repoStore: repoStore)
        }
    }
}

/// Sidebar-pane swap inside the Features section. `.workspace` shows the
/// terminal pane for the active feature; `.run` shows the Run page scoped
/// to a specific workspace (its play button was clicked); `.signals`
/// shows the project-wide log stream.
enum SidebarMode: Hashable {
    case workspace
    case run(workspaceID: UUID)
    case signals
}

/// The previous top-level layout — workspace siderail plus the
/// tabs/terminals pane — now lives behind the "Features" section.
private struct FeaturesDetail: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore

    @State private var sidebarMode: SidebarMode = .workspace
    @State private var runConfig: RunConfigStore
    @State private var signals: SignalStore
    @State private var runners: RunnerManager

    init(store: WorkspaceStore, repoStore: RepoStore) {
        self.store = store
        self.repoStore = repoStore
        let runConfig = RunConfigStore(project: repoStore.project)
        let signals = SignalStore()
        let runners = RunnerManager(project: repoStore.project, signals: signals)
        runners.reload(from: runConfig.rawTOML)
        // URL opens land as a browser tab inside the worktree's own
        // workspace — the running app lives next to the terminals
        // working on it. No matching workspace (e.g. the runner is on
        // the default branch) falls back to the external browser.
        runners.openURLInApp = { [weak store] url, branch, title in
            guard let store,
                  let workspace = store.workspaces.first(where: { $0.name == branch })
            else { return false }
            store.session(for: workspace).openWebTab(url: url, title: title)
            return true
        }
        if E2EMode.isActive {
            // Don't open EXTERNAL browsers / run open commands during
            // automated runs — `openedTargets` still records every fire
            // and the e2e state dump asserts on it. In-app web tabs are
            // in-process and stay enabled so scenarios can assert them.
            runners.openOverride = { _ in }
        }
        _runConfig = State(initialValue: runConfig)
        _signals = State(initialValue: signals)
        _runners = State(initialValue: runners)
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(
                store: store,
                repoStore: repoStore,
                runners: runners,
                sidebarMode: $sidebarMode
            )
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)

            Divider()

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // e2e only (no-op otherwise): hand the run-layer stores to
            // the automation server and sync the bridge with whatever
            // mode this fresh section starts in.
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

    /// Bridge for this project window. `nil` whenever the e2e harness
    /// is inactive, which turns all the consumption above into no-ops.
    private var e2eBridge: E2EBridge? {
        E2ERegistry.shared.bridge(forProject: repoStore.project.id)
    }

    /// The automation server can't reach this view's `@State`, so it
    /// parks the requested pane on the bridge and we adopt it here —
    /// same consume-and-clear pattern as `runners.pendingIsolation`.
    private func consumePendingSidebarModeIfAny() {
        guard let bridge = e2eBridge, let mode = bridge.pendingSidebarMode else { return }
        bridge.pendingSidebarMode = nil
        sidebarMode = mode
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
}
