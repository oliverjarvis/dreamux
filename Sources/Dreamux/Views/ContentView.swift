import SwiftUI

/// The project window's three-column layout, as a single native
/// `NavigationSplitView`:
///
///   • sidebar — the project switcher (`ProjectsRail`),
///   • content — the selected project's Work Items (`WorkspaceSidebar`),
///   • detail  — the terminal / Run / Signals pane for the active feature.
///
/// Everything it renders comes from the window's long-lived
/// `ProjectSession` bundle — this view owns only per-visit UI state
/// (sidebar mode, file-tree visibility, column widths) and is rebuilt
/// from scratch on every project switch while the bundle's terminals,
/// runners, and plan queue keep going.
struct ContentView: View {
    @Bindable var session: ProjectSession
    let projects: ProjectStore
    let onSwitchProject: (UUID?) -> Void

    @State private var sidebarMode: SidebarMode = .workspace
    @State private var showFileTree = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var store: WorkspaceStore { session.store }
    private var repoStore: RepoStore { session.repoStore }
    private var layout: SidebarLayoutStore { session.layout }
    private var runConfig: RunConfigStore { session.runConfig }
    private var signals: SignalStore { session.signals }
    private var runners: RunnerManager { session.runners }
    private var fileTree: FileTreeStore { session.fileTree }
    private var docStore: DocStore { session.docStore }
    private var planRunner: PlanRunCoordinator { session.planRunner }
    private var planQueue: PlanQueueController { session.planQueue }
    private var currentProjectID: UUID { session.project.id }

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
            // sidebar. The Work-Items column reaches the top of the content
            // area; the compact project header sits right of it, above the
            // terminal tabs.
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
                    gateMergeWorkspaceID: $session.pendingGateMergeWorkspaceID,
                    gateCloseWorkspaceID: $session.pendingCloseWorkspaceID,
                    onOpenDoc: openFile,
                    onOpenDocAtLine: { openFile($0, atLine: $1) }
                )
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 380)

                VStack(spacing: 0) {
                    projectHeaderRow
                    mainPane
                }
                // maxHeight keeps the HSplitView vertically greedy in every
                // mode — without a height-flexible child the split collapses
                // under the header row.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The project identity lives in `projectHeaderRow` above the
        // terminal tabs, so the macOS titlebar title is blanked.
        .navigationTitle("")
        // The file-explorer toggle lives in the native titlebar. It has no
        // `.keyboardShortcut` on purpose: a shortcut on a toolbar item isn't
        // dispatched while the Ghostty terminal NSView is first responder
        // (it just rings the bell) — ⌥⌘E lives in `FileExplorerCommands`
        // instead (see the comment on `focusedSceneValue` below).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileTree.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showFileTree ? Color.accentColor : Color.secondary)
                }
                .help("Toggle file explorer (⌥⌘E)")
            }
        }
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
            // e2e only (no-op otherwise): sync the bridge with this
            // window's starting mode. (Store registration and the plan
            // queue's closure wiring live in `ProjectSession`.)
            e2eBridge?.currentSidebarMode = sidebarMode
            consumePendingSidebarModeIfAny()

            // `store.workspaces` is empty until the async `reloadFeatures`
            // (fired from `ProjectWindowContents.onAppear`) completes —
            // reconciling the doc ledger or starting the queue poller
            // before then would see zero known features and prune
            // in-flight plan records / bypass the merge gate. If discovery
            // already finished by the time this view appears (bundle reuse
            // on a project switch-back), `didLoadFeatures` is already true
            // and the `.onChange` below won't fire, so catch that case
            // here.
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

    /// Compact project identity — a small accent-gradient glyph and the
    /// project name — pinned above the terminal tabs, right of the
    /// Work-Items column. Replaces the old full-width hero band.
    private var projectHeaderRow: some View {
        let name = currentProject?.name ?? ""
        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Open a file (clicked in the tree) as a Monaco tab in the active
    /// feature's pane. Flips to the terminal/tab view so the new tab is
    /// visible, mirroring `openBrowserTab`'s behavior. `line` jumps the
    /// editor to a section (sidebar phase/task rows).
    private func openFile(_ url: URL) {
        openFile(url, atLine: nil)
    }

    private func openFile(_ url: URL, atLine line: Int?) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        store.session(for: workspace).openFileTab(at: url, revealingLine: line)
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

