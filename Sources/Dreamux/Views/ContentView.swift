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
    @State private var showProjectsRail = true

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
        // Cursor-style chrome: ONE thin toolbar spans the whole window
        // (traffic lights inline, both sidebar toggles beside them) and
        // every column — projects rail, work items, content, inspector —
        // starts below it. No NavigationSplitView: its macOS shape is a
        // full-height sidebar that swallows the titlebar, exactly what
        // this layout retires.
        HStack(spacing: 0) {
            if showProjectsRail {
                ProjectsRail(
                    projects: projects,
                    currentProjectID: currentProjectID,
                    onSelect: onSwitchProject
                )
                .frame(width: 210)
            }
            HSplitView {
                VStack(spacing: 0) {
                    // The project identity heads its own column: the rail
                    // picks a project, this column shows that project's
                    // work.
                    projectHeaderRow
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
                        onOpenDocAtLine: { openFile($0, atLine: $1) },
                        onCourseCorrectionNudge: { plan, summary, priority in
                            session.enqueueCourseCorrectionNudge(
                                plan: plan, summary: summary, priority: priority)
                        },
                        autoRunFailure: { session.autoRunFailures[$0] }
                    )
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 380)

                VStack(spacing: 0) {
                    contextHeaderRow
                    mainPane
                }
                // maxHeight keeps the HSplitView vertically greedy in every
                // mode — without a height-flexible child the split collapses
                // under the header row.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // ONE card holding the work-items column AND the content/tabs
            // together (connected, no gutter between them) — genuinely
            // full height: flush with the toolbar above and the window
            // edge below, inset only on the sides.
            .panelCard()
            .padding(.leading, showProjectsRail ? 2 : 8)
            .padding(.trailing, 8)
        }
        // Behind-window vibrancy: the rail sits on real glass (desktop
        // blur), like the reference chrome.
        .background(VisualEffectBackground().ignoresSafeArea())
        // The window title is the thin toolbar itself; no text title.
        .navigationTitle("")
        // Both sidebar toggles live in the toolbar, Cursor-style. Neither
        // carries a `.keyboardShortcut` on purpose: a shortcut on a toolbar
        // item isn't dispatched while the Ghostty terminal NSView is first
        // responder (it just rings the bell) — ⌥⌘E lives in
        // `FileExplorerCommands` instead (see `focusedSceneValue` below).
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showProjectsRail.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(showProjectsRail ? Color.accentColor : Color.secondary)
                }
                .help("Toggle projects sidebar")
            }
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
            .panelCard()
            .padding(8)
            .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
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
    /// project name — heading the Work-Items column (the rail picks the
    /// project; this column is that project's work).
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
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text(name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // Exactly the rail header's height, so the bottom hairline runs
        // continuously across both columns.
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Thin context strip above the tab bar: the title of the plan behind
    /// the active workspace (ledger record first, filename-derived branch
    /// as fallback), else the workspace's own name for ad-hoc work, else
    /// nothing worth saying (fresh project).
    private var contextHeaderRow: some View {
        HStack(spacing: 6) {
            Text(activeContextTitle ?? " ")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var activeContextTitle: String? {
        guard let workspace = store.activeWorkspace else { return nil }
        if let plan = docStore.plans.first(where: { plan in
            let path = docStore.relativePath(of: plan)
            let feature = docStore.ledger.recordForPlan(path)?.featureName
                ?? PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent)
            return feature == workspace.name
        }) {
            return plan.title
        }
        return workspace.name
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

// MARK: - Inset panel chrome

/// Behind-window sidebar vibrancy — the desktop blurs through, which
/// SwiftUI's in-window Materials can't do.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// The floating-panel treatment (Codex/Linear-style): the view becomes
    /// a rounded card on the window's darker backdrop, separated from its
    /// neighbors by gutters instead of hairlines.
    func panelCard() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }
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

