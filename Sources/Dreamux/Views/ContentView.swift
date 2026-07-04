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
    /// Work-items column width, dragged via the custom split handle.
    /// Session-only, like the old HSplitView divider position.
    @State private var workItemsWidth: CGFloat = 250
    @State private var splitDragBaseWidth: CGFloat?

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
        // No top band AT ALL (the reference chrome): the rail runs to the
        // very top of the window with the traffic lights floating over
        // it, and the card's own header row is the card's top edge. The
        // system titlebar is hidden (.hiddenTitleBar); its safe-area
        // machinery kept breaking this layout.
        HStack(spacing: 0) {
            if showProjectsRail {
                ProjectsRail(
                    projects: projects,
                    currentProjectID: currentProjectID,
                    onSelect: onSwitchProject,
                    onToggleRail: {
                        withAnimation(.snappy(duration: 0.18)) { showProjectsRail.toggle() }
                    }
                )
                .frame(width: 210)
            }
            // Custom split, NOT HSplitView: the NSSplitView behind it
            // restores its own pane sizes and OVERFLOWS whatever width
            // SwiftUI proposes (it ate the card's trailing gutter and
            // rounded corners; proven with a red-backdrop probe).
            HStack(spacing: 0) {
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
                .frame(width: workItemsWidth)

                splitHandle

                VStack(spacing: 0) {
                    contextHeaderRow
                    mainPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // ONE card holding the work-items column AND the content/tabs
            // together (connected, no gutter between them) — full height
            // under the chrome bar, flush with the window bottom, inset
            // only on the sides.
            .panelCard()
            .padding(.leading, showProjectsRail ? 6 : 10)
            .padding([.top, .bottom, .trailing], 10)
        }
        // Behind-window vibrancy with a dark scrim: the rail and chrome
        // bar sit on real glass (desktop blur), and the scrim keeps the
        // backdrop reliably darker than the card on any wallpaper — an
        // unscrimmed glass gutter next to a dark card reads as nothing
        // (the "missing" inset the red-backdrop probe disproved).
        .background {
            VisualEffectBackground()
                .overlay(Color.black.opacity(0.28))
                .ignoresSafeArea()
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

    /// The draggable seam between the work-items column and the content
    /// pane — a 1pt hairline with a 9pt invisible grab area, clamped to
    /// the column's old HSplitView bounds (220–380).
    private var splitHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = splitDragBaseWidth ?? workItemsWidth
                                splitDragBaseWidth = base
                                workItemsWidth = min(380, max(220, base + value.translation.width))
                            }
                            .onEnded { _ in splitDragBaseWidth = nil }
                    )
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
            }
    }

    /// Sidebar-left toggle — lives at the trailing edge of the rail's top
    /// zone while the rail shows, and at the leading edge of the card's
    /// project header when it's hidden. No `.keyboardShortcut` on purpose
    /// (not dispatched while the Ghostty NSView is first responder).
    private var railToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { showProjectsRail.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(showProjectsRail ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle projects sidebar")
    }

    /// Compact project identity — a small accent-gradient glyph and the
    /// project name — heading the Work-Items column (the rail picks the
    /// project; this column is that project's work).
    private var projectHeaderRow: some View {
        let name = currentProject?.name ?? ""
        return HStack(spacing: 8) {
            // Rail hidden → this header is the window's top-left: clear
            // the floating traffic lights and host the rail toggle.
            if !showProjectsRail {
                Color.clear.frame(width: 66, height: 1)
                railToggle
            }
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
            // The file-explorer toggle lives in the card's own header,
            // reference-style — there is no window toolbar. ⌥⌘E is the
            // shortcut path (FileExplorerCommands).
            Button {
                showFileTree.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(showFileTree ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle file explorer (⌥⌘E)")
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
        // ignoresSafeAreaEdges: [] keeps the fill inside the card's own
        // bounds (the default .all lets an edge-touching background bleed
        // into safe areas). Stroke + shadow carry the "floating card"
        // read on dark themes, where fill-vs-backdrop contrast alone is
        // too subtle.
        background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 2)
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

