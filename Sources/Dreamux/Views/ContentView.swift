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
    /// Owned by `ProjectWindow` — it must survive the id-keyed subtree
    /// rebuild a project switch triggers, or the collapsed rail snaps
    /// open whenever a stub glyph is clicked.
    @Binding var showProjectsRail: Bool
    /// Work-items column width, dragged via the custom split handle.
    /// Session-only, like the old HSplitView divider position.
    @State private var workItemsWidth: CGFloat = 250
    @State private var splitDragBaseWidth: CGFloat?
    /// File-tree column width (third card column), same drag treatment.
    @State private var fileTreeWidth: CGFloat = 280
    @State private var fileTreeDragBaseWidth: CGFloat?
    /// New Project sheet fired from the collapsed rail stub.
    @State private var showCreateProject = false
    /// The active workspace's git HEAD summary (header chip) — polled.
    @State private var gitStatus: GitHeadStatus?
    /// The worktree the chip's `gitStatus` was resolved against — stashed
    /// alongside it so the commit-trail popover can run git commands
    /// against the exact same checkout without re-resolving it.
    @State private var gitWorktree: URL?
    /// The chosen repo's default branch, for the popover's "diff vs
    /// base" affordance and to scope `commitLog` to this branch's own
    /// commits.
    @State private var gitDefaultBranch: String?
    /// Whether the git chip's commit-trail popover is showing.
    @State private var showCommitTrail = false
    /// Appearance knobs (Settings window) — applied live.
    @AppStorage(AppearanceSettings.cardShadowKey) private var cardShadow = true
    @AppStorage(AppearanceSettings.edgeInsetsKey) private var edgeInsets = true
    @AppStorage(AppearanceSettings.cornerRadiusKey) private var cornerRadius = 16.0
    @AppStorage(AppearanceSettings.backdropTransparencyKey)
    private var backdropTransparency = 0.72
    @AppStorage(AppearanceSettings.backdropTintKey) private var backdropTintHex = ""
    @AppStorage(AppearanceSettings.cardColorKey) private var cardColorHex = ""
    @AppStorage(AppearanceSettings.cardOpacityKey) private var cardOpacity = 1.0

    private var backdropTint: Color {
        AppearanceSettings.color(fromHex: backdropTintHex) ?? .black
    }
    private var cardFill: Color {
        (AppearanceSettings.color(fromHex: cardColorHex)
            ?? Color(nsColor: .windowBackgroundColor))
            .opacity(cardOpacity)
    }

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
            } else {
                // Collapsed stub: a slim glass column keeping the traffic
                // lights and the toggle — plus the projects as glyph
                // buttons (tooltip = full name), a mini switcher.
                collapsedRailStub
                    .frame(width: 76)
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
                    HStack(spacing: 0) {
                        mainPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // The file tree slides in BELOW the context
                        // header (it lists the files of the worktree the
                        // header's git chip describes), masked by the
                        // card's clip. Inside the card — the native
                        // .inspector brought its own material and broke
                        // the trailing corner.
                        if showFileTree {
                            HStack(spacing: 0) {
                                fileTreeHandle
                                FileTreePanel(
                                    store: store,
                                    repoStore: repoStore,
                                    tree: fileTree,
                                    onOpenFile: openFile,
                                    onSendToTerminal: { text in
                                        guard let workspace = store.activeWorkspace else { return false }
                                        return store.session(for: workspace).sendToFocusedTerminal(text)
                                    }
                                )
                                .frame(width: fileTreeWidth)
                            }
                            .transition(.move(edge: .trailing))
                        }
                    }
                    .animation(.snappy(duration: 0.22), value: showFileTree)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // ONE card holding the work-items column AND the content/tabs
            // together (connected, no gutter between them) — full height
            // under the chrome bar, flush with the window bottom, inset
            // only on the sides.
            .panelCard(radius: cornerRadius, shadow: cardShadow, fill: cardFill)
            .padding(.leading, edgeInsets ? 6 : 0)
            .padding([.top, .bottom, .trailing], edgeInsets ? 10 : 0)
        }
        // The hidden titlebar still RESERVES a ~33pt top safe area, which
        // pushed the whole layout (and the card) down as a phantom
        // header band. Claim it explicitly: the layout starts at the
        // window's physical top edge — the rail's 38pt top zone provides
        // the traffic-light clearance instead.
        .ignoresSafeArea(edges: .top)
        // Backdrop per the appearance settings: behind-window glass with
        // the backdrop color layered at (1 - transparency) — 100% is raw
        // desktop blur, 0% is the solid color.
        .background {
            VisualEffectBackground()
                .overlay(backdropTint.opacity(1 - backdropTransparency))
                .ignoresSafeArea()
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
        // Header git chip: re-resolve on workspace changes and keep a
        // slow poll so external commits/edits show up. The chip data is
        // three cheap git calls against the active worktree.
        .task(id: store.activeID) {
            while !Task.isCancelled {
                if let resolved = await resolveGitStatus() {
                    gitStatus = resolved.status
                    gitWorktree = resolved.worktree
                    gitDefaultBranch = resolved.defaultBranch
                } else {
                    gitStatus = nil
                    gitWorktree = nil
                    gitDefaultBranch = nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
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
            SignalsView(signals: signals, runners: runners, projectDir: repoStore.project.rootPath.path)
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

    /// The collapsed rail: traffic lights float over the top, then the
    /// toggle, then one tinted glyph per project (click switches, hover
    /// tooltip carries the full name), and New Project at the bottom.
    private var collapsedRailStub: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 26)
            railToggle
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(projects.projects) { project in
                        stubProjectButton(project)
                    }
                    // New Project rides directly below the last glyph, a
                    // tile in the same shape as the project buttons.
                    Button {
                        showCreateProject = true
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(0.18), style:
                                StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Project")
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showCreateProject) {
            CreateProjectSheet(store: projects) { project in
                onSwitchProject(project.id)
            }
        }
    }

    private func stubProjectButton(_ project: Project) -> some View {
        let selected = project.id == currentProjectID
        return Button {
            onSwitchProject(project.id)
        } label: {
            ProjectGlyph(name: project.name, size: 34)
                .opacity(selected ? 1 : 0.55)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.name)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            }
        }
    }

    /// Drag seam for the file-tree column — mirror of `splitHandle`
    /// (dragging left widens the tree).
    private var fileTreeHandle: some View {
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
                                let base = fileTreeDragBaseWidth ?? fileTreeWidth
                                fileTreeDragBaseWidth = base
                                fileTreeWidth = min(480, max(220, base - value.translation.width))
                            }
                            .onEnded { _ in fileTreeDragBaseWidth = nil }
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
            ProjectGlyph(name: name, size: 20)

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
            // Run cluster: play/stop for the active workspace's
            // services, plus the services popover. Left of the git chip
            // so the header reads context → run state → repo state.
            if let workspace = store.activeWorkspace {
                HeaderRunControls(
                    workspace: workspace,
                    runners: runners,
                    start: { startHeaderRunners(for: workspace) },
                    stop: { stopHeaderRunners(for: workspace) },
                    openRunPane: {
                        sidebarMode = .run(workspaceID: workspace.id)
                    },
                    showLogs: { runnerName in
                        signals.pendingSourceFocus = runnerName
                        sidebarMode = .signals
                    })
            }
            // Git chip: the active workspace's worktree branch, HEAD
            // short-SHA, and working-tree diff totals. Clicking opens
            // the commit-trail popover for this worktree.
            if let git = gitStatus {
                Button {
                    showCommitTrail = true
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(git.branch)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(git.shortSHA)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if git.insertions > 0 || git.deletions > 0 {
                            HStack(spacing: 4) {
                                Text("+\(git.insertions)")
                                    .foregroundStyle(.green)
                                Text("−\(git.deletions)")
                                    .foregroundStyle(.red)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Commit trail of the active worktree")
                .popover(isPresented: $showCommitTrail, arrowEdge: .bottom) {
                    if let worktree = gitWorktree, let git = gitStatus {
                        CommitTrailPopover(
                            worktreeURL: worktree,
                            branch: git.branch,
                            defaultBranch: gitDefaultBranch,
                            openDiff: { request in
                                showCommitTrail = false
                                openDiffTab(request)
                            })
                    }
                }
            }
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
        // Same height as projectHeaderRow — the two header strips form
        // one continuous band across the card.
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The header chip's data: find the active workspace's worktree (its
    /// branch across linked repos, else the first repo's default-branch
    /// checkout for scratch workspaces) and summarize HEAD + diff totals.
    /// Returns the resolved worktree and the *chosen* repo's default
    /// branch alongside the status — the commit-trail popover needs both
    /// to run its own git commands without re-resolving the candidate
    /// repo (which would be wrong for multi-repo projects if it just
    /// grabbed `repositories.first`).
    private func resolveGitStatus() async -> (status: GitHeadStatus, worktree: URL, defaultBranch: String)? {
        guard let workspace = store.activeWorkspace else { return nil }
        let repos = repoStore.repositories
        let candidates = workspace.linkedRepoIDs.isEmpty
            ? repos
            : repos.filter { workspace.linkedRepoIDs.contains($0.name) }
        guard let repo = candidates.first else { return nil }
        var worktree = await GitOperations.worktreeURL(
            forBranch: workspace.name, in: repo.rootURL)
        if worktree == nil {
            worktree = await GitOperations.worktreeURL(
                forBranch: repo.defaultBranch, in: repo.rootURL)
        }
        guard let worktree else { return nil }
        guard let status = await GitOperations.headStatus(in: worktree) else { return nil }
        return (status: status, worktree: worktree, defaultBranch: repo.defaultBranch)
    }

    /// Header play: the same planning the sidebar rows use — `startPlan`
    /// decides, `executeStart` acts. The sidebar's displacement banner
    /// is deliberately not duplicated here; a fixed-port switch still
    /// happens, and the popover's "Other worktrees" group shows the
    /// result.
    private func startHeaderRunners(for workspace: Workspace) {
        switch runners.startPlan(for: workspace) {
        case .openRunPane:
            sidebarMode = .run(workspaceID: workspace.id)
        case .start(let toStart, _):
            runners.executeStart(toStart)
        }
    }

    /// Header stop: every live instance on this workspace's worktree —
    /// mirrors the sidebar's `stopAllRunning(on:)`, per-instance so
    /// other worktrees keep running.
    private func stopHeaderRunners(for workspace: Workspace) {
        for runner in runners.runners
        where runners.status(for: runner, on: workspace.name)?.isRunning == true {
            runners.stop(runner, on: workspace.name)
        }
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

    /// Route a diff request into the active workspace's pane, flipping
    /// to the terminal/tab view so the new tab is visible (same move
    /// as openFile).
    private func openDiffTab(_ request: DiffRequest) {
        guard let workspace = store.activeWorkspace else { return }
        sidebarMode = .workspace
        store.session(for: workspace).openDiffTab(request)
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

// MARK: - Project glyph

/// The project's letter badge, tinted deterministically from its name so
/// every project keeps a stable, distinct color — shared by the card's
/// project header and the collapsed rail's switcher buttons.
struct ProjectGlyph: View {
    let name: String
    let size: CGFloat

    private static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .red,
    ]

    private var tint: Color {
        // Stable across launches (String.hashValue is per-process seeded).
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let index = abs(sum) % Self.palette.count
        return Self.palette[index]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
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
    func panelCard(
        radius: CGFloat = 16, shadow: Bool = true, fill: Color? = nil
    ) -> some View {
        // ignoresSafeAreaEdges: [] keeps the fill inside the card's own
        // bounds (the default .all lets an edge-touching background bleed
        // into safe areas). Stroke + shadow carry the "floating card"
        // read on dark themes, where fill-vs-backdrop contrast alone is
        // too subtle; radius/shadow/fill are Settings appearance knobs.
        background(
            fill ?? Color(nsColor: .windowBackgroundColor),
            ignoresSafeAreaEdges: [])
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 14, y: 2)
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

