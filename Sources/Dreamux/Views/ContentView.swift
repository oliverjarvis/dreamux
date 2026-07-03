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
    @State private var showFileTree = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var runConfig: RunConfigStore
    @State private var signals: SignalStore
    @State private var runners: RunnerManager
    @State private var fileTree: FileTreeStore
    @State private var docStore: DocStore
    @State private var planRunner: PlanRunCoordinator
    @State private var planQueue: PlanQueueController
    /// Non-e2e channel for the plan queue's "merge and continue" gate
    /// action: `WorkspaceSidebar` owns the merge sheet's presentation
    /// state, so this parks the target workspace id the same way
    /// `E2EBridge.pendingMergeWorkspaceID` does for the automation server.
    @State private var gateMergeWorkspaceID: UUID?

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
        _fileTree = State(initialValue: FileTreeStore())

        let docStore = DocStore(project: repoStore.project)
        _docStore = State(initialValue: docStore)
        _planRunner = State(initialValue: PlanRunCoordinator(
            project: repoStore.project,
            workspaceStore: store,
            repoStore: repoStore,
            docStore: docStore))

        let planQueue = PlanQueueController(project: repoStore.project)
        planQueue.statusForPlan = { [weak docStore, weak store] path in
            guard let docStore, let store else { return nil }
            docStore.refresh()
            guard let doc = docStore.docs.first(where: { docStore.relativePath(of: $0) == path })
            else { return nil }
            return docStore.status(for: doc) { name in
                store.workspaces.contains { $0.name == name }
            }
        }
        planQueue.featureNameForPlan = { [weak docStore] path in
            docStore?.ledger.recordForPlan(path)?.featureName
        }
        planQueue.isFeatureQuiescent = { [weak store] feature in
            guard let store,
                  let workspace = store.workspaces.first(where: { $0.name == feature })
            else { return true }
            // Quiescent = no tab in the feature's session produced output
            // in the last 5 s. (Session-level helper added below.)
            return store.session(for: workspace).allShellsQuiescent(for: 5)
        }
        _planQueue = State(initialValue: planQueue)
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
        } detail: {
            // The project rail stays the native, full-height split-view
            // sidebar. The bold header and the Work-Items/content split sit
            // to its right, so the header begins right of the rail.
            VStack(spacing: 0) {
                heroBand
                HSplitView {
                    WorkspaceSidebar(
                        store: store,
                        repoStore: repoStore,
                        runners: runners,
                        layout: layout,
                        sidebarMode: $sidebarMode,
                        docStore: docStore,
                        planRunner: planRunner,
                        planQueue: planQueue,
                        gateMergeWorkspaceID: $gateMergeWorkspaceID,
                        onOpenDoc: openFile
                    )
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 380)

                    mainPane
                        // maxHeight keeps the HSplitView vertically greedy
                        // in every mode — without a height-flexible child
                        // the split collapses under the hero band.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // The project identity lives in `heroBand` at the top of the detail
        // area (right of the rail), so the macOS titlebar title is blanked.
        .navigationTitle("")
        .inspector(isPresented: $showFileTree) {
            FileTreePanel(
                store: store,
                repoStore: repoStore,
                tree: fileTree,
                onOpenFile: openFile
            )
            .inspectorColumnWidth(min: 220, ideal: 280, max: 480)
        }
        // The file explorer is toggled from the View menu (⌥⌘E, see
        // `FileExplorerCommands`) rather than a toolbar-item shortcut: a
        // `.keyboardShortcut` on a toolbar item isn't dispatched when the
        // Ghostty terminal NSView is first responder (it just rings the
        // bell). Publishing the binding here lets the menu command reach
        // this window's state via `@FocusedBinding`, the same way
        // `ProjectCommands` reaches the active store.
        .focusedSceneValue(\.fileTreeVisible, $showFileTree)
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
            E2ERegistry.shared.registerDocStores(
                projectID: repoStore.project.id,
                docStore: docStore,
                planRunner: planRunner,
                planQueue: planQueue
            )
            e2eBridge?.currentSidebarMode = sidebarMode
            consumePendingSidebarModeIfAny()

            // `runPlan`/`requestMerge` need `docStore`/`planRunner`/the
            // bridge, which aren't available to weak-capture from `init`
            // (self isn't fully formed yet) — `.onAppear` runs once per
            // window and can capture them directly.
            let pendingGateMerge = $gateMergeWorkspaceID
            planQueue.runPlan = { [docStore, planRunner, repoStore] path in
                docStore.refresh()
                guard let doc = docStore.docs.first(
                    where: { docStore.relativePath(of: $0) == path }) else {
                    throw PlanRunError.notAPlan
                }
                try await planRunner.runPlan(
                    doc,
                    branchName: PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent),
                    repoNames: repoStore.repositories.map(\.name))
            }
            planQueue.requestMerge = { [store, repoStore] featureName in
                guard let workspace = store.workspaces.first(where: { $0.name == featureName })
                else { return }
                // The merge sheet is owned by WorkspaceSidebar; reuse the
                // same pending channel the e2e openMergeSheet command uses.
                E2ERegistry.shared.bridge(forProject: repoStore.project.id)?
                    .pendingMergeWorkspaceID = workspace.id
                // When e2e is inactive the bridge is nil — park on the
                // queue-local channel the sidebar also observes.
                pendingGateMerge.wrappedValue = workspace.id
            }

            // `store.workspaces` is empty until the async `reloadFeatures`
            // (fired from `ProjectWindow.onAppear`) completes — reconciling
            // the doc ledger or starting the queue poller before then
            // would see zero known features and prune in-flight plan
            // records / bypass the merge gate. If discovery already
            // finished by the time this view appears (store reuse on a
            // project switch-back), `didLoadFeatures` is already true and
            // the `.onChange` below won't fire, so catch that case here.
            if store.didLoadFeatures {
                docStore.refresh()
                docStore.reconcileLedger(
                    existingFeatureNames: Set(store.workspaces.map(\.name)))
                planQueue.startPolling()
            }
        }
        .onChange(of: store.didLoadFeatures) { _, loaded in
            guard loaded else { return }
            docStore.refresh()
            docStore.reconcileLedger(
                existingFeatureNames: Set(store.workspaces.map(\.name)))
            planQueue.startPolling()
        }
        .onChange(of: e2eBridge?.pendingSidebarMode) { _, _ in
            consumePendingSidebarModeIfAny()
        }
        .onChange(of: sidebarMode) { _, newValue in
            e2eBridge?.currentSidebarMode = newValue
        }
        .onChange(of: e2eBridge?.pendingFileTreeVisible) { _, _ in
            if let bridge = e2eBridge, let visible = bridge.pendingFileTreeVisible {
                bridge.pendingFileTreeVisible = nil
                showFileTree = visible
            }
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

    /// The bold "hero" header pinned full-width to the top of the window:
    /// an accent-tinted gradient carrying a gradient project glyph, the
    /// project name in a heavy rounded face, and the file-explorer toggle
    /// on the right. Replaces the flat titlebar title + Finder-path
    /// subtitle.
    private var heroBand: some View {
        let name = currentProject?.name ?? ""
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .shadow(color: Color.accentColor.opacity(0.4), radius: 5, y: 2)

            Text(name)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .kerning(0.4)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 8)

            Button {
                showFileTree.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(showFileTree ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(showFileTree ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle file explorer (⌥⌘E)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.38), Color.accentColor.opacity(0.14)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                VStack {
                    Spacer()
                    Divider()
                }
            }
        )
    }

    /// Open a file (clicked in the tree) as a Monaco tab in the active
    /// feature's pane. Flips to the terminal/tab view so the new tab is
    /// visible, mirroring `openBrowserTab`'s behavior.
    private func openFile(_ url: URL) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        store.session(for: workspace).openFileTab(at: url)
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

// MARK: - File-explorer focused value

/// Binding to the focused project window's file-explorer visibility. The
/// window publishes it via `.focusedSceneValue(\.fileTreeVisible, …)`, and
/// the View-menu command (`FileExplorerCommands`) toggles it through
/// `@FocusedBinding` — the same focused-value bridge `ProjectCommands`
/// uses to reach the active `WorkspaceStore`.
private struct FileTreeVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var fileTreeVisible: Binding<Bool>? {
        get { self[FileTreeVisibleKey.self] }
        set { self[FileTreeVisibleKey.self] = newValue }
    }
}

