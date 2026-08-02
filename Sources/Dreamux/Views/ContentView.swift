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

    @Environment(\.openWindow) private var openWindow
    @State private var sidebarMode: SidebarMode = .workspace
    @State private var showFileTree = false
    /// Flows pane zoom state: the lane id currently drilled into, or
    /// `nil` for the overview. Lifted here (not `FlowsOverviewView`
    /// `@State`) so the e2e `zoomFlow` command can drive it the same
    /// way `pendingSidebarMode` drives `sidebarMode`.
    @State private var flowsZoomLaneID: String?
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
    /// New Project sheet — fired from the collapsed rail stub's tile and
    /// from the File menu's ⌘N (`ProjectCommands`, via the
    /// `createProjectPresented` focused binding).
    @State private var showCreateProject = false
    /// New Plan sheet fired from a plain workspace's Overview (Mode B's
    /// "Plan something here") — a second trigger for the same
    /// `NewPlanSheet` `WorkspaceSidebar`'s `+` opens, independent local
    /// state like `showCreateProject`/`ProjectsRail.showCreate`.
    @State private var showNewPlan = false
    /// New-applet sheet fired from ⌘L / the palette — window-level twin of
    /// `WorkspaceSidebar.showNewApp`, same second-trigger pattern as
    /// `showNewPlan`.
    @State private var showNewApplet = false
    /// Failure surface for the ⌘L create/adopt path — ContentView's copy of
    /// `WorkspaceSidebar.addError`.
    @State private var appletActionError: String?
    /// ⌘K command palette visibility (also opened by the rail's search bar).
    @State private var showPalette = false

    // MARK: Bottom prompt composer
    /// Collapsed state persists across launches — reopened via the chip.
    @AppStorage("promptComposerHidden") private var composerHidden = false
    @State private var composerText = ""
    /// Explicit composer target; nil is Auto (active workspace, else main).
    @State private var composerTargetID: UUID?
    /// Rebuilt fresh on every palette open so results reflect live stores.
    @State private var paletteModel: PaletteModel?
    /// Run-the-plan sheet fired from a workspace's Overview (Mode A's lime
    /// pill) — the window-level twin of `WorkspaceSidebar`'s own
    /// `runningPlan`, so the Overview can start/resume a plan the same way
    /// the rail card does.
    @State private var overviewRunningPlan: PlanDoc?
    /// Feedback for a failed Overview checklist action (view-changes with
    /// no commits found, etc.) — this view's own copy of
    /// `WorkspaceSidebar`'s `addError`, since the Overview tab is hosted
    /// outside that view's tree.
    @State private var overviewTaskChangesError: String?
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
    /// Project whose icon/color Customize sheet is open (from the collapsed
    /// rail glyph's context menu).
    @State private var customizingProject: Project?
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

    /// PR lifecycle glue for the Flows board, keyed by workspace id —
    /// `session.prStatus` keys by feature *name* (== branch), so this
    /// re-keys onto `store.workspaces`' ids the way `FlowsBoard.Lane`
    /// needs. Pulled out of `mainPane`'s `.flows` case (rather than
    /// inlined) so a `Dictionary(uniqueKeysWithValues:)` literal doesn't
    /// push that switch's expression over the type checker's budget —
    /// the same reasoning as `mergeSheet(for:)` in `WorkspaceSidebar`.
    private var prStatesByWorkspace: [UUID: PRLaneState] {
        Dictionary(uniqueKeysWithValues: store.workspaces.compactMap { ws in
            session.prStatus.state(for: ws.name).map {
                (ws.id, PRLaneState(lifecycle: $0.lifecycle, url: $0.url))
            }
        })
    }

    /// PR lifecycle lookup keyed by feature *name* directly (no re-key onto
    /// a workspace id) — `prStatesByWorkspace`'s sibling for callers that
    /// only have a feature/branch name in hand, like `WorkspaceOverviewView
    /// .projectRunRow` (keyed on `ProjectRun.featureName`). Threaded into
    /// `overviewDependencies.prState` below.
    private func prState(forFeature name: String) -> PRLaneState? {
        session.prStatus.state(for: name).map { PRLaneState(lifecycle: $0.lifecycle, url: $0.url) }
    }

    /// The window's whole layout tree plus every sheet/alert modifier that
    /// doesn't need to chain with the palette's own state below — split
    /// out of `body` because the combined chain (this stack + the palette
    /// overlay wiring) makes the type checker time out on one expression.
    private var mainStack: some View {
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
                    },
                    onOpenPalette: { showPalette = true }
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
            VStack(spacing: 0) {
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
                        signals: signals,
                        prStatus: session.prStatus,
                        syncStatus: session.syncStatus,
                        layout: layout,
                        sidebarMode: $sidebarMode,
                        docStore: docStore,
                        flows: session.flows,
                        planRunner: planRunner,
                        planQueue: planQueue,
                        gateMergeWorkspaceID: $session.pendingGateMergeWorkspaceID,
                        gateCloseWorkspaceID: $session.pendingCloseWorkspaceID,
                        emphasizePublishWorkspaceID: $session.emphasizePublishWorkspaceID,
                        onOpenDoc: openFile,
                        onOpenDocAtLine: { openFile($0, atLine: $1) },
                        onCourseCorrectionNudge: { plan, summary, priority in
                            session.enqueueCourseCorrectionNudge(
                                plan: plan, summary: summary, priority: priority)
                        },
                        autoRunFailure: { session.autoRunFailures[$0] },
                        onOpenProjectGraph: { sidebarMode = .flows; flowsZoomLaneID = nil },
                        applets: session.applets,
                        appLibrary: session.appLibrary,
                        appletSessionProvider: { session.appletSession(for: $0) },
                        closeAppletSession: { session.closeAppletSession(id: $0) },
                        configContent: { workspace in AnyView(configCard(for: workspace)) }
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
                                    onOpenTerminal: { url in
                                        guard let workspace = store.activeWorkspace else { return }
                                        sidebarMode = .workspace
                                        store.session(for: workspace).openTab(
                                            at: url.path,
                                            title: url.lastPathComponent,
                                            icon: "terminal")
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

            // The prompt composer spans the card's full width at its
            // bottom — reachable from every page of the project.
            composerInset
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
        .sheet(item: $customizingProject) { project in
            CustomizeProjectSheet(
                projectName: project.name,
                selectedSymbol: project.symbol,
                selectedTintHex: project.tintHex,
                onPickSymbol: { projects.setSymbol($0, for: project.id) },
                onPickTintHex: { projects.setTintHex($0, for: project.id) },
                onDismiss: { customizingProject = nil }
            )
        }
        .sheet(isPresented: $showNewPlan) {
            NewPlanSheet(
                project: session.project,
                autoRunParallel: Binding(
                    get: { layout.autoRunParallel },
                    set: { layout.autoRunParallel = $0 }
                ),
                onSubmit: { idea in
                    showNewPlan = false
                    openOverviewPlanningSession { digest in
                        PlanPrompts.brainstormKickoff(idea: idea, intakeDigest: digest)
                    }
                },
                onCancel: { showNewPlan = false }
            )
        }
        .sheet(item: $overviewRunningPlan) { plan in
            // Mirrors WorkspaceSidebar's own run-plan sheet, lifted to the
            // window so the Overview's lime pill starts/resumes a plan the
            // same way the rail card does.
            let record = docStore.ledger.recordForPlan(docStore.relativePath(of: plan))
            RunPlanSheet(
                plan: plan,
                initialBranch: record?.featureName
                    ?? PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent),
                availableRepos: repoStore.repositories,
                isResume: record != nil,
                onSubmit: { branch, repoIDs in
                    overviewRunningPlan = nil
                    runPlanFromOverview(plan, branch: branch, repoIDs: repoIDs)
                },
                onCancel: { overviewRunningPlan = nil }
            )
        }
        .sheet(isPresented: $showCreateProject) {
            CreateProjectSheet(store: projects) { project in
                onSwitchProject(project.id)
            }
        }
        // Refresh the library BEFORE the sheet builds so its Adopt list is
        // current (the sidebar's row does the same refresh inline).
        .onChange(of: showNewApplet) { _, presented in
            if presented { session.appLibrary.refresh() }
        }
        .sheet(isPresented: $showNewApplet) {
            NewAppSheet(
                library: session.appLibrary.applets,
                onCreate: { name, description in
                    showNewApplet = false
                    createProjectApplet(name: name, description: description)
                },
                onAdopt: { applet in
                    showNewApplet = false
                    adoptProjectApplet(applet)
                },
                onCancel: { showNewApplet = false }
            )
        }
        .alert(
            "Couldn't add applet",
            isPresented: Binding(
                get: { appletActionError != nil },
                set: { if !$0 { appletActionError = nil } }
            ),
            presenting: appletActionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
        .alert(
            "Couldn't apply change",
            isPresented: Binding(
                get: { overviewTaskChangesError != nil },
                set: { if !$0 { overviewTaskChangesError = nil } }
            ),
            presenting: overviewTaskChangesError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    var body: some View {
        // The file explorer is toggled from the View menu (⌥⌘E, see
        // `FileExplorerCommands`) rather than a toolbar-item shortcut: a
        // `.keyboardShortcut` on a toolbar item isn't dispatched when the
        // Ghostty terminal NSView is first responder (it just rings the
        // bell). Publishing the binding here lets the menu command reach
        // this window's state via `@FocusedBinding`, the same way
        // `ProjectCommands` reaches the active store.
        mainStack
        .focusedSceneValue(\.fileTreeVisible, $showFileTree)
        .focusedSceneValue(\.createProjectPresented, $showCreateProject)
        .focusedSceneValue(\.newPlanPresented, $showNewPlan)
        .focusedSceneValue(\.newAppletPresented, $showNewApplet)
        .onAppear {
            // e2e only (no-op otherwise): sync the bridge with this
            // window's starting mode. (Store registration and the plan
            // queue's closure wiring live in `ProjectSession`.)
            e2eBridge?.currentSidebarMode = sidebarMode
            consumePendingSidebarModeIfAny()
            consumePendingPaletteIfAny()

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
                    existingFeatureNames: store.featureNames)
                planQueue.startPolling()
            }
        }
        .onChange(of: store.didLoadFeatures) { _, loaded in
            guard loaded else { return }
            docStore.refresh()
            docStore.reconcileLedger(
                existingFeatureNames: store.featureNames)
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
            // Leaving the Flows pane resets any zoom: a predictable
            // return-to-overview next visit, and it avoids paying for a
            // full transcript replay (the zoom lazy-tail seam) on every
            // pane round-trip rather than only while actually zoomed in.
            if newValue != .flows { flowsZoomLaneID = nil }
        }
        .onChange(of: e2eBridge?.pendingFileTreeVisible) { _, _ in
            if let bridge = e2eBridge, let visible = bridge.pendingFileTreeVisible {
                bridge.pendingFileTreeVisible = nil
                showFileTree = visible
            }
        }
        .onChange(of: e2eBridge?.pendingFlowsZoomLaneID) { _, _ in
            consumePendingFlowsZoomIfAny()
        }
        .onChange(of: e2eBridge?.pendingPalette) { _, _ in
            consumePendingPaletteIfAny()
        }
        .focusedSceneValue(\.palettePresented, $showPalette)
        .onChange(of: showPalette) { _, visible in
            if visible {
                // The e2e path (Task 6) pre-builds a model with a query; only
                // build one here when this open came from ⌘K or the rail.
                if paletteModel == nil {
                    let model = PaletteModel(sources: paletteSources())
                    model.refresh()
                    paletteModel = model
                }
                e2eBridge?.paletteModel = paletteModel
            } else {
                paletteModel = nil
                e2eBridge?.paletteModel = nil
            }
        }
        .overlay { paletteOverlay }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if showPalette, let paletteModel {
            CommandPaletteView(model: paletteModel, onDismiss: { showPalette = false })
        }
    }

    /// The window-bottom prompt bar (or its collapsed reopen chip) —
    /// extracted from the body chain so the type checker stays fast.
    @ViewBuilder
    private var composerInset: some View {
        Group {
            if composerHidden {
                PromptComposerReopenChip {
                    withAnimation(Self.composerSpring) { composerHidden = false }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                PromptComposer(
                    text: $composerText,
                    targetID: $composerTargetID,
                    workspaces: store.workspaces,
                    onSend: { sendComposerPrompt() },
                    onHide: {
                        withAnimation(Self.composerSpring) { composerHidden = true }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // One springy collapse/expand: the bar slides toward the card's
        // bottom edge while the pane above relaxes into the space. The
        // toggles run in a `withAnimation(composerSpring)` transaction so
        // the surrounding layout animates with the transition.
        .animation(Self.composerSpring, value: composerHidden)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }

    private static let composerSpring: Animation = .snappy(duration: 0.28, extraBounce: 0.12)

    /// Send the composer's prompt to its target workspace's claude tab.
    /// Auto (no explicit target) resolves to the active workspace when
    /// one is showing, else `main`, else the first workspace. A fresh
    /// tab launches claude seeded with the prompt; an existing one gets
    /// the text typed into its live REPL.
    private func sendComposerPrompt() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let explicit = composerTargetID.flatMap { id in
            store.workspaces.first { $0.id == id }
        }
        let auto = (sidebarMode == .workspace ? store.activeWorkspace : nil)
            ?? store.workspaces.first(where: \.isMain)
            ?? store.workspaces.first
        guard let workspace = explicit ?? auto else { return }
        composerText = ""
        store.activate(workspace.id)
        sidebarMode = .workspace
        let session = store.session(for: workspace)
        let cwd = workspace.workingDirectory ?? repoStore.project.rootPath.path
        guard let (tab, reused) = session.reuseOrOpenComposerTab(at: cwd)
        else { return }
        tab.startIfNeeded()
        if reused {
            ClaudePromptDriver.type(text, into: tab)
        } else {
            ClaudePromptDriver.send(text, into: tab)
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        mainPaneContent
            // Always-mounted consumer for run-config handoffs (e2e
            // detect, the isolate alert) — they must work whether or not
            // the services popover is open.
            .background(RunConfigHandoffConsumer(
                bridge: e2eBridge,
                runners: runners,
                onDetect: {
                    guard let ws = store.activeWorkspace ?? store.workspaces.first else { return }
                    RunConfigActions.detect(project: repoStore.project, session: store.session(for: ws))
                },
                onIsolate: { runner in
                    guard let ws = store.activeWorkspace ?? store.workspaces.first else { return }
                    RunConfigActions.isolate(runner, project: repoStore.project, session: store.session(for: ws))
                }))
    }

    @ViewBuilder
    private var mainPaneContent: some View {
        switch sidebarMode {
        case .workspace:
            WorkspaceTerminalContainer(store: store, overview: overviewDependencies)
        case .signals:
            SignalsView(signals: signals, runners: runners, projectDir: repoStore.project.rootPath.path)
        case .flows:
            FlowsOverviewView(
                flows: session.flows,
                planLaneInputs: planLaneInputs,
                prStatesByWorkspace: prStatesByWorkspace,
                graftSubagents: { lane in
                    // A graft closure keyed by lane id ("plan-<planPath>"). For each
                    // plan with a live workspace, pull its subagents (slice 1) and
                    // the current task line, then graft them onto the lane (Task 3).
                    guard let plan = docStore.plans.first(where: { "plan-\(docStore.relativePath(of: $0))" == lane.id }),
                          let ws = lane.workspaceID else { return lane }
                    let subs = OverviewLiveAgents.subagents(in: session.flows.flows, workspaceID: ws, tasks: plan.tasks)
                    let current = plan.tasks.first { $0.steps.contains { !$0.checked } }?.line
                    return RunLaneGraft.graft(lane, subagents: subs, currentTaskLine: current)
                },
                projectGraph: {
                    ProjectGraphBuilder.build(
                        plans: docStore.plans,
                        relativePath: { docStore.relativePath(of: $0) },
                        resolveBlocker: { ref in
                            let target = docStore.resolvedURL(forReference: ref)
                            return docStore.plans.first { $0.fileURL.standardizedFileURL == target }
                        },
                        statusOf: { docStore.status(for: $0, featureExists: { name in store.featureNames.contains(name) }) })
                },
                zoomedLaneID: $flowsZoomLaneID,
                onJumpToTerminal: { workspaceID in
                    // Same activation shape as WorkspaceSidebar.selectWorkspace:
                    // flip back to the terminal view before activating, so
                    // the switch isn't silent.
                    sidebarMode = .workspace
                    store.activate(workspaceID)
                },
                onOpenTranscript: { sessionID in openTranscript(sessionID: sessionID) },
                onZoomBegin: { sessionID in
                    session.beginFlowsZoom(sessionID: sessionID, cwd: sessionCwd(forSessionID: sessionID))
                },
                onZoomEnd: { sessionID in
                    session.endFlowsZoom(sessionID: sessionID)
                },
                gateActions: flowGateActions
            )
        case .library:
            LibraryView(
                projectRoot: repoStore.project.rootPath,
                projectName: repoStore.project.name,
                docStore: docStore,
                onOpenDoc: openFile)
        case .app(let id):
            // The applet's folder is the source of truth: a removed applet
            // resolves to nil here and shows the missing state; the Applets
            // section auto-heals on its next refresh.
            if let applet = session.applets.applet(id: id) {
                // Key on the applet id so switching from one applet to another
                // rebuilds the host — the preview is an NSViewRepresentable
                // whose updateNSView is a no-op, so without a fresh identity
                // the old session's WKWebView stays parented and only the
                // header updates (the "content doesn't change until I visit a
                // workspace" bug).
                AppletHostView(session: session.appletSession(for: applet))
                    .id(id)
            } else {
                appletMissingState
            }
        }
    }

    /// Shown when `.app(id)` points at an applet that no longer exists (it was
    /// removed while open, or its manifest went invalid).
    private var appletMissingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Applet not found")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("It may have been removed. The Applets list updates when its folder changes.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Brand mark only — the expanded rail's icon + "Dreamux" row
            // loses its text here; same NSApp-sourced icon so it always
            // matches the installed AppIcon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityLabel("Dreamux")
            railToggle
            Button {
                showPalette = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search (⌘K)")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(projects.projects) { project in
                        stubProjectButton(project)
                    }
                    // Applet Studio rides above New Project — same dashed
                    // tile shape, opening the global applet library window.
                    Button {
                        openWindow(id: "app-studio")
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(0.18), style:
                                StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Applet Studio")
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
    }

    private func stubProjectButton(_ project: Project) -> some View {
        let selected = project.id == currentProjectID
        return Button {
            onSwitchProject(project.id)
        } label: {
            ProjectGlyph(name: project.name, size: 34,
                         symbol: project.symbol, tint: project.glyphTint())
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
            Button("Customize Icon…") { customizingProject = project }
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
    ///
    /// Collapsed-rail state: the chrome monitor's top strip (x ≤
    /// WindowChromeInteractions.railStripXBound, top
    /// WindowChromeInteractions.topStripHeight) overlays this row's
    /// leading edge — any interactive control added in that corner
    /// would have its clicks swallowed as window-drag chrome. Keep the
    /// leading ~210pt of this row non-interactive, or narrow the strip.
    private var projectHeaderRow: some View {
        let project = currentProject
        let name = project?.name ?? ""
        return HStack(spacing: 10) {
            ProjectGlyph(name: name, size: 24,
                         symbol: project?.symbol, tint: project?.glyphTint())

            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Shared band height with contextHeaderRow, so the bottom
        // hairline runs continuously across both columns.
        .frame(height: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Thin context strip above the tab bar: the title of the plan behind
    /// the active workspace (ledger record first, filename-derived branch
    /// as fallback), else the workspace's own name for ad-hoc work, else
    /// nothing worth saying (fresh project).
    private var contextHeaderRow: some View {
        HStack(spacing: 8) {
            Text(activeContextTitle ?? " ")
                // Same type as projectHeaderRow's title — the two strips
                // form one band and their titles should read as peers.
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
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
                    showLogs: { runnerName in
                        signals.pendingSourceFocus = runnerName
                        sidebarMode = .signals
                    },
                    configContent: { AnyView(configCard(for: workspace)) },
                    consumesConfigureRequests: true)
            }
            // Git chip: the active workspace's worktree branch, HEAD
            // short-SHA, and working-tree diff totals. Clicking opens
            // the commit-trail popover for this worktree.
            if let git = gitStatus {
                Button {
                    showCommitTrail = true
                } label: {
                    // Same outlined-pill shape as the run control: a content
                    // segment, a hairline divider, then a down chevron for
                    // the commit-trail popover.
                    HStack(spacing: 0) {
                        HStack(spacing: 9) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(git.branch)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(git.shortSHA)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if git.insertions > 0 || git.deletions > 0 {
                                HStack(spacing: 4) {
                                    Text("+\(git.insertions)")
                                        .foregroundStyle(.green)
                                    Text("−\(git.deletions)")
                                        .foregroundStyle(.red)
                                }
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            // Aggregate ↓behind/↑ahead vs origin across the
                            // project's repos — main workspace only (feature
                            // branches answer to the PR flow instead).
                            if store.activeWorkspace?.isMain == true,
                               let sync = session.syncStatus.badgeText {
                                Text(sync)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 26)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1, height: 16)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 26)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Commit trail of the active worktree")
                .popover(isPresented: $showCommitTrail, arrowEdge: .bottom) {
                    if let worktree = gitWorktree, let git = gitStatus {
                        CommitTrailPopover(
                            worktreeURL: worktree,
                            branch: git.branch,
                            defaultBranch: gitDefaultBranch,
                            syncStatus: store.activeWorkspace?.isMain == true
                                ? session.syncStatus : nil,
                            syncRepos: repoStore.repositories,
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(showFileTree ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle file explorer (⌥⌘E)")
        }
        .padding(.horizontal, 16)
        // Same height as projectHeaderRow — the two header strips form
        // one continuous band across the card.
        .frame(height: 52)
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
            focusRunCard(for: workspace)
        case .start(let toStart, _):
            runners.executeStart(toStart)
        }
    }

    /// Route to run configuration: activate the workspace and ask the
    /// context header's run cluster to open its popover on the Configure
    /// tab (run config merged into the services popover, 2026-07-18).
    private func focusRunCard(for workspace: Workspace) {
        store.activate(workspace.id)
        sidebarMode = .workspace
        runners.pendingConfigureWorkspaceID = workspace.id
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

    // MARK: - Flows

    /// Delegates to `PlanLaneAssembler`, the shared, unit-tested home for
    /// this glue (also used by the e2e `flowsState` command). `docStore`,
    /// `planQueue`, and `store` are all `@Observable`, and this is called
    /// from `FlowsOverviewView.board` during its own `body` evaluation, so
    /// these reads register as that view's dependencies — a plan-state
    /// change (checkbox ticked, queue advances, workspace appears)
    /// re-renders the Flows pane on its own, with no reliance on
    /// `FlowStore`'s next publish.
    private func planLaneInputs() -> [PlanLaneInput] {
        PlanLaneAssembler.inputs(docStore: docStore, queue: planQueue, store: store)
    }

    private var flowGateActions: FlowGateActions {
        FlowGateActions(
            openDiff: { workspaceID in openGateDiff(workspaceID: workspaceID) },
            requestMerge: { workspaceID in requestGateMerge(workspaceID: workspaceID) },
            fetchDiffStat: { workspaceID in await gateDiffStat(workspaceID: workspaceID) },
            requestPublish: { workspaceID in requestGatePublish(workspaceID: workspaceID) },
            fetchPublishAvailability: { workspaceID in await gatePublishAvailability(workspaceID: workspaceID) }
        )
    }

    // MARK: - Overview (Mode A)

    /// Everything the active project's workspaces' Overview tabs need,
    /// bundled once per render — see `WorkspaceOverviewDependencies`.
    /// `gateActions` reuses `flowGateActions` verbatim so a merge from the
    /// Overview and a merge from the Flows page can't drift.
    private var overviewDependencies: WorkspaceOverviewDependencies {
        WorkspaceOverviewDependencies(
            docStore: docStore,
            planQueue: planQueue,
            repoStore: repoStore,
            syncStatus: session.syncStatus,
            featureName: { (plan: PlanDoc) -> String? in planFeatureName(for: plan) },
            featureExists: { name in store.featureNames.contains(name) },
            onOpenDoc: openFile,
            onOpenDocAtLine: { openFile($0, atLine: $1) },
            makeRunControls: { overviewRunControls(for: $0) },
            onRunPlan: { plan in overviewRunningPlan = plan },
            hasLiveAgent: { ws in store.hasLivePlanAgent(for: ws.id) },
            gateActions: flowGateActions,
            onNewPlan: { showNewPlan = true },
            onOpenRun: { plan in openRunFromOverview(plan) },
            onViewTaskChanges: { plan, task in viewTaskChangesFromOverview(plan: plan, task: task) },
            onCourseCorrectionNudge: { plan, summary, priority in
                session.enqueueCourseCorrectionNudge(
                    plan: plan, summary: summary, priority: priority)
            },
            flows: session.flows,
            onOpenRunFlow: { ws in
                let lane = session.flows.flows.first { $0.workspaceID == ws && $0.kind == .plan }
                    ?? session.flows.flows.first { $0.workspaceID == ws }   // Mode B fallback
                if let lane {
                    sidebarMode = .flows
                    flowsZoomLaneID = lane.id
                }
            },
            prState: { name in prState(forFeature: name) }
        )
    }

    /// Main's mini-dashboard row action: jump to a run's workspace and
    /// focus its Overview — same activation shape as
    /// `WorkspaceSidebar`'s `onOpenFeature` / Flows' `onJumpToTerminal`,
    /// plus focusing the Overview tab. A plan with no workspace yet
    /// (never run) falls back to opening the doc, mirroring the rail's
    /// not-yet-run click rule (Run provisions the workspace).
    private func openRunFromOverview(_ plan: PlanDoc) {
        let feature = planFeatureName(for: plan)
        if let workspace = store.featureWorkspace(named: feature) {
            sidebarMode = .workspace
            store.activate(workspace.id)
            store.session(for: workspace).focusOverview()
        } else {
            openFile(plan.fileURL)
        }
    }

    /// Run/resume a plan from its Overview — the window-level twin of
    /// `WorkspaceSidebar.executePlan`, driving the same `PlanRunCoordinator`
    /// and then focusing the (materialized) run's Overview.
    private func runPlanFromOverview(_ plan: PlanDoc, branch: String, repoIDs: [String]) {
        Task {
            do {
                let workspace = try await planRunner.runPlan(
                    plan, branchName: branch, repoNames: repoIDs)
                sidebarMode = .workspace
                store.activate(workspace.id)
                store.session(for: workspace).focusOverview()
            } catch {
                overviewTaskChangesError = error.localizedDescription
            }
        }
    }

    /// The feature a plan runs as (ledger record first, else filename-
    /// derived branch) — same resolver `WorkspaceSidebar.featureName(for:)`
    /// uses, rebuilt here since that one is private to the sidebar view.
    private func planFeatureName(for plan: PlanDoc) -> String {
        AdHocWorkspaces.featureName(
            for: plan,
            record: { docStore.ledger.recordForPlan(docStore.relativePath(of: $0)) })
    }

    /// The Overview checklist's "View changes" (hover button + context-menu
    /// item): resolve a task's recorded commits in each of its feature's
    /// repo worktrees and open a diff tab per repo with matches. Mirrors
    /// `WorkspaceSidebar.viewTaskChanges` line-for-line — that copy is
    /// private to the rail's view and the Overview tab is hosted outside
    /// it, so this is the Overview's own trigger onto the same
    /// `TaskDiffResolver`/`GitOperations` primitives. No matches anywhere →
    /// explain via `overviewTaskChangesError` instead of silently doing
    /// nothing.
    private func viewTaskChangesFromOverview(plan: PlanDoc, task: PlanTask) {
        let feature = planFeatureName(for: plan)
        guard let workspace = store.featureWorkspace(named: feature) else {
            overviewTaskChangesError = "No workspace for this plan yet — run the plan first."
            return
        }
        let repos = repoStore.repositories.filter {
            workspace.linkedRepoIDs.contains($0.name)
        }
        // The resolver matches on the heading verbatim (what the agent
        // actually commits); "this task" is display-only, for the rare
        // blank heading.
        let matchTitle = task.title
        let displayTitle = task.title.isEmpty ? "this task" : task.title
        Task { @MainActor in
            var opened = 0
            for repo in repos {
                guard let worktree = await GitOperations.worktreeURL(
                    forBranch: feature, in: repo.rootURL) else { continue }
                let log = await GitOperations.commitLog(
                    in: worktree, baseBranch: repo.defaultBranch)
                guard let range = TaskDiffResolver.range(for: matchTitle, in: log)
                else { continue }
                // range.from is "<oldest>^" — invalid when oldest is the
                // root commit; parentRevision maps that to the empty tree.
                let oldestSHA = String(range.from.dropLast())
                let fromRevision = await GitOperations.parentRevision(
                    of: oldestSHA, in: worktree)
                store.session(for: workspace).openDiffTab(DiffRequest(
                    worktreeURL: worktree,
                    fromRevision: fromRevision,
                    toRevision: range.to,
                    title: repos.count > 1 ? "\(displayTitle) — \(repo.name)" : displayTitle))
                opened += 1
            }
            if opened == 0 {
                overviewTaskChangesError = "No commits recorded for \"\(displayTitle)\" yet. The agent commits when the task's boxes are ticked (auto-commit is \(WorkflowSettings.autoCommitEnabled ? "on" : "OFF — see Settings → Workflow"))."
            }
        }
    }

    /// The Overview's action-row run controls — the same `HeaderRunControls`
    /// pill the context header uses (play/stop + services chevron popover),
    /// so the run.toml services control reads identically everywhere.
    private func overviewRunControls(for workspace: Workspace) -> HeaderRunControls {
        HeaderRunControls(
            workspace: workspace,
            runners: runners,
            start: { startHeaderRunners(for: workspace) },
            stop: { stopHeaderRunners(for: workspace) },
            showLogs: { runnerName in
                signals.pendingSourceFocus = runnerName
                sidebarMode = .signals
            },
            configContent: { AnyView(configCard(for: workspace)) }
        )
    }

    /// The services popover's Configure tab for a workspace — built here
    /// because this view owns the stores.
    private func configCard(for workspace: Workspace) -> some View {
        RunConfigCard(
            project: repoStore.project,
            session: store.session(for: workspace),
            repoStore: repoStore,
            runConfig: runConfig,
            runners: runners,
            signals: signals)
    }

    /// Mode B's "Plan something here" kickoff — the same shared
    /// `PlanningSessionLauncher` the rail's `+` uses, so the two entry
    /// points can't drift.
    private func openOverviewPlanningSession(buildPrompt: @escaping (String?) -> String) {
        PlanningSessionLauncher.open(
            store: store,
            repoStore: repoStore,
            docStore: docStore,
            planQueue: planQueue,
            sidebarMode: $sidebarMode,
            buildPrompt: buildPrompt)
    }

    /// The spec's front door: when this lane IS the queue's current
    /// plan at its gate, go through `mergeAndContinue` (which parks the
    /// e2e bridge channel too); an off-queue review parks the bundle
    /// channel directly. Both paths end at the same WorkspaceSidebar
    /// merge sheet — the branch only decides bookkeeping.
    private func requestGateMerge(workspaceID: UUID) {
        if planQueue.state == .atGate,
           let path = planQueue.currentPlanPath,
           let feature = planQueue.featureNameForPlan(path),
           store.featureWorkspace(named: feature)?.id == workspaceID {
            planQueue.mergeAndContinue()
        } else {
            session.pendingGateMergeWorkspaceID = workspaceID
        }
    }

    /// "Create PR" on the gate card: always routes through the sidebar's
    /// merge sheet (never `mergeAndContinue`, which only ever runs a
    /// local merge) with publish emphasized — `WorkspaceSidebar` reads
    /// and clears `emphasizePublishWorkspaceID` when it adopts the
    /// matching `pendingGateMergeWorkspaceID`.
    private func requestGatePublish(workspaceID: UUID) {
        session.emphasizePublishWorkspaceID = workspaceID
        session.pendingGateMergeWorkspaceID = workspaceID
    }

    /// Gate-card twin of `MergeFlow.initializeStates`' PR pre-check,
    /// collapsed to one verdict across the workspace's linked repos: any
    /// repo with a remote makes the shared `gh` probe worth running: if
    /// none, publish can never apply and we skip straight to `.noRemote`.
    private func gatePublishAvailability(workspaceID: UUID) async -> PublishAvailability {
        guard let ws = store.workspaces.first(where: { $0.id == workspaceID }) else { return .noRemote }
        let repos = repoStore.repositories.filter { ws.linkedRepoIDs.contains($0.name) }
        var anyRemote = false
        for repo in repos where await GitOperations.remoteURL(in: repo.rootURL) != nil { anyRemote = true }
        let gh = anyRemote ? await GhOperations.isAvailable() : false
        return PublishAvailability.decide(anyRemote: anyRemote, ghAvailable: gh)
    }

    /// One "everything this branch changes" diff tab per linked repo —
    /// the commit-trail popover's "Diff vs base" request shape
    /// (merge-base fork point → HEAD), multi-repo like
    /// WorkspaceSidebar.openTaskDiff, activating the workspace so the
    /// tabs are visible.
    private func openGateDiff(workspaceID: UUID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let repos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        Task { @MainActor in
            for repo in repos {
                guard let worktree = await GitOperations.worktreeURL(
                    forBranch: workspace.name, in: repo.rootURL) else { continue }
                let from = await GitOperations.mergeBase(of: repo.defaultBranch, in: worktree)
                    ?? repo.defaultBranch
                sidebarMode = .workspace
                store.activate(workspace.id)
                store.session(for: workspace).openDiffTab(DiffRequest(
                    worktreeURL: worktree,
                    fromRevision: from,
                    toRevision: "HEAD",
                    title: repos.count > 1
                        ? "\(workspace.name) vs \(repo.defaultBranch) — \(repo.name)"
                        : "\(workspace.name) vs \(repo.defaultBranch)"))
            }
        }
    }

    /// Card stat = sum across the workspace's linked repos (a feature
    /// can span several); repos where the branch has no worktree or no
    /// resolvable base contribute nothing. Nil only when NO repo
    /// yielded a stat — the card then omits the line entirely.
    private func gateDiffStat(workspaceID: UUID) async -> GitBranchDiffStat? {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        let repos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        var total: GitBranchDiffStat?
        for repo in repos {
            guard let worktree = await GitOperations.worktreeURL(
                    forBranch: workspace.name, in: repo.rootURL),
                  let stat = await GitOperations.branchDiffStat(
                    vs: repo.defaultBranch, in: worktree)
            else { continue }
            total = GitBranchDiffStat(
                insertions: (total?.insertions ?? 0) + stat.insertions,
                deletions: (total?.deletions ?? 0) + stat.deletions,
                filesChanged: (total?.filesChanged ?? 0) + stat.filesChanged)
        }
        return total
    }

    /// A live session's cwd, from `FlowStore`'s own record of it — the
    /// zoom seam and "open transcript" both need this, and neither is
    /// handed the lane directly (they only get a bare `sessionID`), so
    /// both re-resolve it here rather than threading `Flow` itself
    /// through `FlowsOverviewView`'s closures.
    private func sessionCwd(forSessionID sessionID: String) -> String? {
        session.flows.flows.first(where: { $0.sessionID == sessionID })?.sessionCwd
    }

    /// Open a zoomed lane's session transcript as a Monaco tab — same
    /// `openFile` glue as the file tree, just resolving the path via
    /// `ClaudeHome` instead of a tree click. Falls back to the project
    /// root when the lane's cwd isn't known yet (shouldn't happen once
    /// a session lane is old enough to be zoomable, but degrades to a
    /// plausible path rather than crashing on a force-unwrap).
    private func openTranscript(sessionID: String) {
        let cwd = sessionCwd(forSessionID: sessionID) ?? session.project.rootPath.path
        let url = ClaudeHome.transcriptURL(home: ClaudeHome.root(), cwd: cwd, sessionID: sessionID)
        openFile(url)
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

    /// Mirrors `WorkspaceSidebar.handleCreateApp` for the ⌘L / palette path:
    /// scaffold a local-born applet, spawn its builder agent, open its host.
    private func createProjectApplet(name: String, description: String) {
        do {
            let applet = try session.applets.createLocal(
                name: name, description: description, icon: "shippingbox")
            session.appletSession(for: applet).beginEditing(
                kickoff: AppletScaffold.kickoffPrompt(
                    appletName: name, description: description))
            sidebarMode = .app(applet.id)
        } catch {
            appletActionError = error.localizedDescription
        }
    }

    /// Mirrors `WorkspaceSidebar.handleAdoptApp` (no agent on adopt).
    private func adoptProjectApplet(_ library: Applet) {
        do {
            let adopted = try session.applets.adopt(library)
            sidebarMode = .app(adopted.id)
        } catch {
            appletActionError = error.localizedDescription
        }
    }

    // MARK: - Command palette sources

    private func paletteSources() -> [PaletteSource] {
        [
            PaletteSource(kind: .projects, cap: 5, showsOnEmptyQuery: true) {
                projects.projects.map { project in
                    PaletteCandidate(
                        id: "project-\(project.id)",
                        title: project.name,
                        subtitle: project.id == currentProjectID ? "Current project" : "Switch project",
                        icon: "folder"
                    ) {
                        if project.id != currentProjectID { onSwitchProject(project.id) }
                    }
                }
            },
            PaletteSource(kind: .workspaces, cap: 5, showsOnEmptyQuery: false) {
                let workspaceItems = store.workspaces.map { workspace in
                    PaletteCandidate(
                        id: "workspace-\(workspace.id)",
                        title: workspace.name,
                        subtitle: "Workspace",
                        icon: workspace.isMain ? "house" : "square.stack.3d.up"
                    ) {
                        sidebarMode = .workspace
                        store.activate(workspace.id)
                        store.session(for: workspace).focusOverview()
                    }
                }
                let docItems = docStore.docs.filter { $0.kind != .doc }.map { doc in
                    PaletteCandidate(
                        id: "doc-\(doc.fileURL.path)",
                        title: doc.title,
                        subtitle: doc.kind == .plan ? "Plan" : "Spec",
                        icon: "doc.text"
                    ) {
                        openFile(doc.fileURL)
                    }
                }
                return workspaceItems + docItems
            },
            PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) {
                paletteCommandCandidates()
            },
            PaletteSource(kind: .files, cap: 8, showsOnEmptyQuery: false) {
                paletteFileCandidates()
            },
        ]
    }

    private func paletteCommandCandidates() -> [PaletteCandidate] {
        var commands: [PaletteCandidate] = [
            PaletteCandidate(id: "command-new-project", title: "New Project…",
                             subtitle: nil, icon: "plus") { showCreateProject = true },
            PaletteCandidate(id: "command-new-plan", title: "New Plan…",
                             subtitle: nil, icon: "list.bullet.clipboard") { showNewPlan = true },
            PaletteCandidate(id: "command-new-applet", title: "New Applet…",
                             subtitle: nil, icon: "plus.app") { showNewApplet = true },
            PaletteCandidate(id: "command-new-global-applet", title: "New Global Applet…",
                             subtitle: nil, icon: "shippingbox") {
                AppStudioIntents.shared.pendingNewApplet = true
                openWindow(id: "app-studio")
            },
            PaletteCandidate(id: "command-open-applet-studio", title: "Open Applet Studio",
                             subtitle: nil, icon: "shippingbox") {
                openWindow(id: "app-studio")
            },
            PaletteCandidate(id: "command-new-workspace", title: "New Scratch Workspace",
                             subtitle: nil, icon: "plus.square") { _ = store.addWorkspace() },
            PaletteCandidate(id: "command-new-tab", title: "New Tab",
                             subtitle: nil, icon: "plus.rectangle") { store.activeSession?.createTab() },
            PaletteCandidate(id: "command-toggle-file-explorer", title: "Toggle File Explorer",
                             subtitle: nil, icon: "sidebar.right") { showFileTree.toggle() },
            PaletteCandidate(id: "command-go-signals", title: "Go to Signals",
                             subtitle: nil, icon: "dot.radiowaves.left.and.right") { sidebarMode = .signals },
            PaletteCandidate(id: "command-go-flows", title: "Go to Flows",
                             subtitle: nil, icon: "point.3.connected.trianglepath.dotted") { sidebarMode = .flows },
            PaletteCandidate(id: "command-go-library", title: "Go to Library",
                             subtitle: nil, icon: "books.vertical") { sidebarMode = .library },
        ]
        commands += docStore.plans.map { plan in
            PaletteCandidate(
                id: "command-run-plan-\(plan.fileURL.path)",
                title: "Run Plan: \(plan.title)",
                subtitle: nil,
                icon: "play"
            ) {
                overviewRunningPlan = plan
            }
        }
        return commands
    }

    /// Filename candidates from the active workspace's worktree roots —
    /// breadth-first so shallow files surface first, capped so a giant repo
    /// can't stall the palette, heavy build dirs skipped outright.
    private func paletteFileCandidates() -> [PaletteCandidate] {
        let skipped: Set<String> = ["node_modules", ".build", "dist", ".next", "vendor"]
        let roots = fileTree.roots(for: store.activeWorkspace,
                                   repositories: repoStore.repositories)
        var queue: [(node: FileNode, rootPath: String)] = roots.map { ($0, $0.url.path) }
        var candidates: [PaletteCandidate] = []
        var directoriesWalked = 0
        while !queue.isEmpty, candidates.count < 2000, directoriesWalked < 400 {
            let (node, rootPath) = queue.removeFirst()
            if node.isDirectory {
                guard !skipped.contains(node.name) else { continue }
                directoriesWalked += 1
                queue.append(contentsOf: fileTree.children(of: node).map { ($0, rootPath) })
            } else {
                let relative = String(node.url.path.dropFirst(rootPath.count)
                    .drop(while: { $0 == "/" }))
                candidates.append(PaletteCandidate(
                    id: "file-\(node.url.path)",
                    title: node.name,
                    subtitle: relative,
                    icon: "doc"
                ) {
                    openFile(node.url)
                })
            }
        }
        return candidates
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

    /// Same consume-and-clear shape as `consumePendingSidebarModeIfAny`.
    /// Builds the model here (not in the `.onChange(of: showPalette)`
    /// creation path) so the request's query lands on the fresh model.
    /// Sets `bridge.paletteModel` directly rather than leaning on the
    /// `.onChange(of: showPalette)` open branch to do it: a second
    /// `setPalette` while already open (re-querying) leaves `showPalette`
    /// at `true → true`, which SwiftUI's `.onChange` never fires for, so
    /// the bridge's weak reference would otherwise keep pointing at the
    /// first (stale-query) model forever.
    private func consumePendingPaletteIfAny() {
        guard let bridge = e2eBridge, let request = bridge.pendingPalette else { return }
        bridge.pendingPalette = nil
        if request.visible {
            let model = PaletteModel(sources: paletteSources())
            model.refresh()
            model.query = request.query
            paletteModel = model
            showPalette = true
            bridge.paletteModel = model
        } else {
            showPalette = false
            bridge.paletteModel = nil
        }
    }

    /// Same consume-and-clear shape as `consumePendingSidebarModeIfAny`,
    /// but with an extra wrinkle: `nil` is itself a valid target value
    /// (clear the zoom), so the bridge can't use `nil` as its own
    /// "nothing pending" marker — it uses the empty string as that
    /// sentinel instead (see `E2EBridge.pendingFlowsZoomLaneID`).
    private func consumePendingFlowsZoomIfAny() {
        guard let bridge = e2eBridge, let laneID = bridge.pendingFlowsZoomLaneID else { return }
        bridge.pendingFlowsZoomLaneID = nil
        flowsZoomLaneID = laneID.isEmpty ? nil : laneID
    }
}

/// Detail-pane swap inside a project window. `.workspace` shows the
/// terminal pane for the active feature; `.run` shows the Run page scoped
/// to a specific workspace (its play button was clicked); `.signals`
/// shows the project-wide log stream; `.flows` shows the Flows overview
/// board; `.library` shows the Context & MCPs inventory page; `.app` hosts a
/// project applet's preview (and, in Edit mode, its builder agent).
/// Always-mounted consumer for run-config handoffs — the e2e
/// `detectRunConfig` flag and the isolate alert's pending runner — so
/// they fire regardless of any popover being open.
private struct RunConfigHandoffConsumer: View {
    let bridge: E2EBridge?
    @Bindable var runners: RunnerManager
    let onDetect: () -> Void
    let onIsolate: (ParsedRunner) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: consume)
            .onChange(of: bridge?.pendingDetect) { _, _ in consume() }
            .onChange(of: runners.pendingIsolation) { _, _ in consume() }
    }

    private func consume() {
        if let bridge, bridge.pendingDetect {
            bridge.pendingDetect = false
            onDetect()
        }
        if let runner = runners.pendingIsolation {
            runners.pendingIsolation = nil
            onIsolate(runner)
        }
    }
}

enum SidebarMode: Hashable {
    case workspace
    case signals
    case flows
    case library
    case app(UUID)
}

// MARK: - Project glyph

/// The project's letter badge, tinted deterministically from its name so
/// every project keeps a stable, distinct color — shared by the card's
/// project header and the collapsed rail's switcher buttons.
struct ProjectGlyph: View {
    let name: String
    let size: CGFloat
    /// User-chosen SF Symbol; nil renders the initial-letter glyph.
    var symbol: String? = nil
    /// User-chosen tint; nil falls back to the stable name-derived color.
    var tint: Color? = nil

    static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .green, .red,
    ]

    /// Stable across launches (String.hashValue is per-process seeded), so
    /// a project keeps the same auto-color until the user overrides it.
    static func derivedTint(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let index = abs(sum) % palette.count
        return palette[index]
    }

    private var effectiveTint: Color { tint ?? Self.derivedTint(for: name) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [effectiveTint, effectiveTint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

extension Project {
    /// The glyph's effective tint: the user's pick, else a stable
    /// name-derived color. Shared by the rail (both modes) and the
    /// work-items header so a project reads the same everywhere.
    func glyphTint() -> Color {
        if let tintHex, let color = AppearanceSettings.color(fromHex: tintHex) {
            return color
        }
        return ProjectGlyph.derivedTint(for: name)
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

// MARK: - Menu-shortcut focused values

/// Bindings the File-menu items (⌘N New Project…, ⌘P New Plan…) use to
/// present the focused window's sheets — same bridge as
/// `fileTreeVisible`, so the shortcuts fire even while a terminal is
/// first responder.
private struct CreateProjectPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct NewPlanPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct PalettePresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct NewAppletPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var createProjectPresented: Binding<Bool>? {
        get { self[CreateProjectPresentedKey.self] }
        set { self[CreateProjectPresentedKey.self] = newValue }
    }

    var newPlanPresented: Binding<Bool>? {
        get { self[NewPlanPresentedKey.self] }
        set { self[NewPlanPresentedKey.self] = newValue }
    }

    var palettePresented: Binding<Bool>? {
        get { self[PalettePresentedKey.self] }
        set { self[PalettePresentedKey.self] = newValue }
    }

    var newAppletPresented: Binding<Bool>? {
        get { self[NewAppletPresentedKey.self] }
        set { self[NewAppletPresentedKey.self] = newValue }
    }
}

