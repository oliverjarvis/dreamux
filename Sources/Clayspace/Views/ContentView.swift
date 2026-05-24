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

/// Sidebar-pane swap inside the Features section. The "Run" and "Signals"
/// tiles at the top of the sidebar flip this away from `.workspace`,
/// which replaces the terminal area on the right with the corresponding
/// page.
enum SidebarMode: Hashable {
    case workspace
    case run
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
        _runConfig = State(initialValue: runConfig)
        _signals = State(initialValue: signals)
        _runners = State(initialValue: runners)
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(
                store: store,
                repoStore: repoStore,
                sidebarMode: $sidebarMode
            )
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)

            Divider()

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        switch sidebarMode {
        case .workspace:
            WorkspaceTerminalContainer(store: store)
        case .run:
            RunSetupView(
                project: repoStore.project,
                repoStore: repoStore,
                runConfig: runConfig,
                runners: runners
            )
        case .signals:
            SignalsView(signals: signals, runners: runners)
        }
    }
}
