import SwiftUI
import UniformTypeIdentifiers

/// The Work Items column of a project window (the `content` column of the
/// window's NavigationSplitView). Top: an Arc-style `PinnedTileGrid` of
/// pinned tiles (Signals + Web Browser), drag-reorderable. Below: the
/// Features list as flat, drag-reorderable rows led by a soft tinted badge,
/// then the Repositories card.
struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    @Bindable var runners: RunnerManager
    @Bindable var layout: SidebarLayoutStore
    @Binding var sidebarMode: SidebarMode
    @Bindable var docStore: DocStore
    let planRunner: PlanRunCoordinator
    let onOpenDoc: (URL) -> Void

    @State private var showAddFeature = false
    @State private var showAddRepo = false
    @State private var addError: String?
    @State private var isWorking = false
    @State private var pendingClose: Workspace?
    @State private var pendingMerge: Workspace?
    @State private var repositoriesExpanded = false
    @State private var switchNotice: SwitchNotice?
    @State private var runningPlan: PlanDoc?
    @State private var showNewPlan = false
    /// Feature row currently under the pointer — drives hover-reveal of the
    /// run controls without giving every row its own `@State` (so the rows
    /// can stay lightweight builder methods).
    @State private var hoveredWorkspaceID: UUID?
    /// Workspace whose Customize sheet is open. Hoisted to the sidebar (one
    /// sheet, not per-row) like `pendingMerge`/`pendingClose`.
    @State private var customizing: Workspace?
    /// Feature currently being dragged for reorder.
    @State private var draggingWorkspace: Workspace?

    var body: some View {
        ScrollView(showsIndicators: false) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
        }
        .sheet(isPresented: $showAddFeature) {
            AddFeatureSheet(
                projectName: repoStore.project.name,
                availableRepos: repoStore.repositories,
                onSubmit: handleCreateFeature,
                onCancel: { showAddFeature = false }
            )
        }
        .sheet(isPresented: $showAddRepo) {
            AddRepoSheet(
                projectName: repoStore.project.name,
                onSubmit: handleAddRepo,
                onCancel: { showAddRepo = false }
            )
        }
        .sheet(item: $pendingMerge, onDismiss: {}) { workspace in
            MergeFeatureSheet(
                workspace: workspace,
                repos: repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) },
                project: repoStore.project,
                onOpenConflictTab: { url, title in
                    openConflictTab(workspace: workspace, url: url, title: title)
                },
                onRepoCleanedUp: { repo in
                    stopRunnersTiedToFeature(repo: repo, branch: workspace.name)
                },
                onAllCleanedUp: {
                    finalizeFeatureCleanup(workspace)
                },
                onDismiss: { pendingMerge = nil }
            )
        }
        .sheet(item: $customizing) { workspace in
            CustomizeWorkspaceSheet(
                initialName: workspace.name,
                selectedSymbol: workspace.symbol,
                selectedTint: workspace.tint,
                onRename: { store.setName($0, for: workspace.id) },
                onPickSymbol: { store.setIcon($0, for: workspace.id) },
                onPickTint: { store.setTint($0, for: workspace.id) },
                onDismiss: { customizing = nil }
            )
        }
        .sheet(item: $runningPlan) { plan in
            RunPlanSheet(
                plan: plan,
                availableRepos: repoStore.repositories,
                isResume: docStore.status(
                    for: plan,
                    featureExists: { name in store.workspaces.contains { $0.name == name } }
                ) == .running,
                onSubmit: { branch, repoIDs in
                    runningPlan = nil
                    executePlan(plan, branch: branch, repoIDs: repoIDs)
                },
                onCancel: { runningPlan = nil }
            )
        }
        .sheet(isPresented: $showNewPlan) {
            NewPlanSheet(
                onSubmit: { idea in
                    showNewPlan = false
                    openPlanningSession(prompt: PlanPrompts.brainstormKickoff(idea: idea))
                },
                onCancel: { showNewPlan = false }
            )
        }
        .alert(
            "Close \(pendingClose?.name ?? "feature")?",
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            presenting: pendingClose
        ) { workspace in
            Button("Close & Remove Worktrees", role: .destructive) {
                closeFeature(workspace)
            }
            Button("Cancel", role: .cancel) {}
        } message: { workspace in
            Text(workspace.linkedRepoIDs.isEmpty
                 ? "Close this feature and stop its shells."
                 : "This will run `git worktree remove` and `git branch -D \(workspace.name)` in each linked repo, then drop the feature from the sidebar.")
        }
        .alert(
            "Couldn't apply change",
            isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            ),
            presenting: addError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
        .onAppear { consumePendingMergeIfAny() }
        .onChange(of: e2eBridge?.pendingMergeWorkspaceID) { _, _ in
            consumePendingMergeIfAny()
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            PinnedTileGrid(
                tiles: $layout.tiles,
                isSelected: { $0 == .signals && sidebarMode == .signals },
                isEnabled: { _ in true },
                onTap: handleTileTap,
                onReorder: { layout.persistTiles() }
            )

            PlansSpecsSection(
                docStore: docStore,
                layout: layout,
                featureExists: { name in store.workspaces.contains { $0.name == name } },
                onOpenDoc: onOpenDoc,
                onRunPlan: { runningPlan = $0 },
                onNewPlan: { showNewPlan = true },
                onWritePlan: { spec in
                    openPlanningSession(
                        prompt: PlanPrompts.writePlanKickoff(
                            specRelativePath: docStore.relativePath(of: spec)))
                }
            )

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Features")
                switchNoticeIfAny
                addFeatureButton
                if hasNoFeaturesOrRepos {
                    emptyFeaturesText
                } else {
                    VStack(spacing: 2) {
                        ForEach(store.workspaces) { workspace in
                            featureRow(workspace) { featureRowBody(workspace) }
                                .onDrag {
                                    draggingWorkspace = workspace
                                    return NSItemProvider(object: workspace.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: ReorderDropDelegate(
                                    item: workspace,
                                    items: workspacesBinding,
                                    dragging: $draggingWorkspace,
                                    onReorder: { store.persistFeatureOrder() }
                                ))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                repositoriesHeader
                if repositoriesExpanded {
                    card { repoRows }
                }
            }
        }
    }

    private static let browserHomepage = URL(string: "https://www.google.com")!

    private func handleTileTap(_ tile: SidebarTile) {
        switch tile {
        case .signals:
            sidebarMode = .signals
        case .browser:
            openBrowserTab()
        }
    }

    /// Open a browser tab at the hardcoded homepage, switching to it.
    /// `openWebTab` dedups by the tab's home URL, so a workspace keeps a
    /// single browser tab that this re-focuses rather than stacking
    /// duplicates. Web tabs live inside a workspace's Bonsplit pane, so if
    /// there's no workspace yet we spin up a scratch one (same as ⌘⇧T)
    /// rather than leaving the tile inert.
    private func openBrowserTab() {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        store.session(for: workspace).openWebTab(url: Self.browserHomepage, title: "Browser")
    }

    private func featureRowBody(_ workspace: Workspace) -> some View {
        let isActive = isWorkspaceActive(workspace)
        let isRunning = !runners.runningRunners(onBranch: workspace.name).isEmpty
        return HStack(spacing: 10) {
            softBadge(symbol: workspace.symbol, tint: workspace.tint)
                .overlay(alignment: .bottomTrailing) {
                    if isRunning {
                        Circle().fill(Color.green)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                nameLine(workspace, isActive: isActive)
                if let sub = repoSubtitle(for: workspace) {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: 52)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .padding(.horizontal, 4)
            } else if hoveredWorkspaceID == workspace.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
    }

    private func softBadge(symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 26, height: 26)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    // MARK: - Shared row plumbing

    /// Wraps a row body in the selectable button + overlaid run controls.
    /// The controls live *outside* the button (trailing overlay) so tapping
    /// them never also fires row selection — the row body reserves a 52pt
    /// trailing gutter for them.
    private func featureRow<Body: View>(
        _ workspace: Workspace,
        @ViewBuilder body: () -> Body
    ) -> some View {
        let isRunning = !runners.runningRunners(onBranch: workspace.name).isEmpty
        let isHovered = hoveredWorkspaceID == workspace.id
        let openable = runners.openableRunners(for: workspace).map(\.name)
        return ZStack(alignment: .trailing) {
            Button { selectWorkspace(workspace) } label: { body() }
                .buttonStyle(.plain)
                .help(workspace.workingDirectory ?? workspace.name)
                .contextMenu { featureMenu(for: workspace) }

            runControls(for: workspace, isRunning: isRunning, openableNames: openable)
                .opacity(isHovered || isRunning ? 1 : 0)
                .padding(.trailing, 12)
        }
        .onHover { hovering in
            if hovering {
                hoveredWorkspaceID = workspace.id
            } else if hoveredWorkspaceID == workspace.id {
                hoveredWorkspaceID = nil
            }
        }
    }

    private func nameLine(_ workspace: Workspace, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Text(workspace.name)
                .font(.callout.weight(isActive ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
            if store.hasUnread(for: workspace) {
                Circle().fill(Color.red).frame(width: 5, height: 5)
            }
        }
    }

    private func runControls(for workspace: Workspace, isRunning: Bool, openableNames: [String]) -> some View {
        HStack(spacing: 4) {
            if isRunning, !openableNames.isEmpty {
                Menu {
                    ForEach(openableNames, id: \.self) { name in
                        Button("Open \(name)") { openServices(for: workspace, runnerName: name) }
                    }
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                } primaryAction: {
                    openServices(for: workspace, runnerName: nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open \(workspace.name)'s services (hold to pick one)")
            }

            Menu {
                Button("Run Settings…") { configure(workspace) }
            } label: {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.green))
            } primaryAction: {
                isRunning ? stopAllRunning(on: workspace) : startRunnersForWorkspace(workspace)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(isRunning ? "Stop running services on \(workspace.name) (hold for Run Settings)"
                            : "Start \(workspace.name) (hold for Run Settings)")
        }
    }

    @ViewBuilder
    private func featureMenu(for workspace: Workspace) -> some View {
        Button("Run Settings…") { configure(workspace) }
        Button("Customize…") { customizing = workspace }
        if !workspace.linkedRepoIDs.isEmpty {
            Button("Merge…") { pendingMerge = workspace }
        }
        Divider()
        Button("Close \"\(workspace.name)\"", role: .destructive) { pendingClose = workspace }
    }

    /// Picking a Work Item flips back to the terminal view, otherwise the
    /// activation would happen silently while the Run page stayed on screen.
    private func selectWorkspace(_ workspace: Workspace) {
        sidebarMode = .workspace
        store.activate(workspace.id)
    }

    private func configure(_ workspace: Workspace) {
        store.activate(workspace.id)
        sidebarMode = .run(workspaceID: workspace.id)
    }

    private func repoSubtitle(for workspace: Workspace) -> String? {
        let repos = workspace.linkedRepoIDs
        guard !repos.isEmpty else { return nil }
        if repos.count <= 3 { return repos.joined(separator: " · ") }
        return repos.prefix(2).joined(separator: " · ") + " · +\(repos.count - 2)"
    }

    // MARK: - Shared chrome

    private var hasNoFeaturesOrRepos: Bool {
        store.workspaces.isEmpty && repoStore.repositories.isEmpty
    }

    private var workspacesBinding: Binding<[Workspace]> {
        Binding(get: { store.workspaces }, set: { store.workspaces = $0 })
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private var switchNoticeIfAny: some View {
        if let notice = switchNotice {
            switchNoticeBanner(notice)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var emptyFeaturesText: some View {
        Text("Add a repository, then create your first feature.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    private var addFeatureButton: some View {
        Button { showAddFeature = true } label: {
            HStack(spacing: 8) {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.secondary)
                Text(isWorking ? "Adding…" : "Add Feature")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(repoStore.repositories.isEmpty || isWorking)
        .help(repoStore.repositories.isEmpty
              ? "Add a repository before creating features."
              : "New Feature")
    }

    // MARK: - Repositories

    private var repositoriesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { repositoriesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(repositoriesExpanded ? 90 : 0))
                    Text("Repositories")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if !repositoriesExpanded {
                    withAnimation(.snappy(duration: 0.18)) { repositoriesExpanded = true }
                }
                showAddRepo = true
            } label: {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .help(isWorking ? "Working…" : "Add Repository")
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var repoRows: some View {
        if repoStore.repositories.isEmpty {
            Text("No repositories in this project yet.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(repoStore.repositories.enumerated()), id: \.element.id) { index, repo in
                    if index > 0 {
                        Divider().padding(.leading, 42)
                    }
                    RepoRow(
                        repository: repo,
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([repo.rootURL]) }
                    )
                }
            }
        }
    }

    // MARK: - Selection helpers

    /// A workspace row is "active" when the user is either viewing its
    /// terminal pane or its scoped Run page — both should highlight the
    /// row so the user always sees which feature the right-hand pane is
    /// bound to.
    private func isWorkspaceActive(_ workspace: Workspace) -> Bool {
        if workspace.id != store.activeID { return false }
        switch sidebarMode {
        case .workspace: return true
        case .run(let id): return id == workspace.id
        case .signals: return false
        }
    }

    /// Open the workspace's running services — the row's open button.
    /// nil runnerName means "everything that isn't headless" (the
    /// button's click); a specific name comes from its press-and-hold
    /// menu. URL targets land as in-app tabs in this workspace, so
    /// repeated clicks re-select rather than stack.
    private func openServices(for workspace: Workspace, runnerName: String?) {
        let openable = runners.openableRunners(for: workspace)
        let targets = runnerName == nil
            ? openable
            : openable.filter { $0.name == runnerName }
        for runner in targets {
            runners.openNow(runner, on: workspace.name)
        }
    }

    // MARK: - e2e bridge

    /// Bridge for this project window — `nil` when the e2e harness is
    /// inactive, making the merge-sheet consumption above a no-op.
    private var e2eBridge: E2EBridge? {
        E2ERegistry.shared.bridge(forProject: repoStore.project.id)
    }

    /// The automation server's `openMergeSheet` command parks the
    /// target workspace id on the bridge; this view owns the sheet's
    /// presentation state, so it adopts (and clears) the request here —
    /// the `runners.pendingIsolation` pattern again.
    private func consumePendingMergeIfAny() {
        guard let bridge = e2eBridge, let id = bridge.pendingMergeWorkspaceID else { return }
        bridge.pendingMergeWorkspaceID = nil
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
        pendingMerge = workspace
    }

    // MARK: - Actions

    private func executePlan(_ plan: PlanDoc, branch: String, repoIDs: [String]) {
        isWorking = true
        Task {
            do {
                let workspace = try await planRunner.runPlan(
                    plan, branchName: branch, repoNames: repoIDs)
                sidebarMode = .workspace
                store.activate(workspace.id)
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// One planning terminal per project, cwd at the project root where
    /// `repos/<repo>/<default>/` checkouts and `docs/` are visible.
    /// Reuses the existing tab when it's still open (tracked on the
    /// session — see `planningTabID` below); the kickoff prompt is typed
    /// via the shared driver either way.
    private func openPlanningSession(prompt: String) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        let session = store.session(for: workspace)
        DocStore.ensureDocsHome(at: repoStore.project.rootPath)
        if let tab = session.reuseOrOpenPlanningTab(
            at: repoStore.project.rootPath.path) {
            tab.startIfNeeded()
            ClaudePromptDriver.send(prompt, into: tab)
        }
    }

    private func handleCreateFeature(name: String, repoIDs: [String]) {
        showAddFeature = false
        isWorking = true
        let project = repoStore.project
        let selectedRepos = repoStore.repositories.filter { repoIDs.contains($0.name) }
        Task {
            do {
                let dir = try await FeatureProvisioner.provision(
                    featureName: name,
                    in: project,
                    across: selectedRepos
                )
                store.registerFeature(
                    name: name,
                    featureDirectory: dir,
                    linkedRepoIDs: repoIDs
                )
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func handleAddRepo(_ intent: AddRepoIntent) {
        showAddRepo = false
        isWorking = true
        Task {
            do {
                switch intent {
                case .clone(let url, let name):
                    _ = try await repoStore.clone(url: url, name: name)
                case .initialize(let name):
                    _ = try await repoStore.initRepo(name: name)
                case .importLocal(let path, let name):
                    _ = try await repoStore.importLocal(path: path, name: name)
                }
            } catch {
                addError = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func openConflictTab(workspace: Workspace, url: URL, title: String) {
        // Make sure the workspace is active so the new tab is the visible
        // one, then use its session to open a tab cd'd into the conflict.
        store.activate(workspace.id)
        guard let session = store.session(for: workspace) as WorkspaceSession? else { return }
        session.openTab(at: url.path, title: title)
    }

    private func closeFeature(_ workspace: Workspace) {
        let project = repoStore.project
        let linkedRepos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        // Stop any runner that's executing on this feature's worktree —
        // its cwd is about to disappear from under it.
        for repo in linkedRepos {
            stopRunnersTiedToFeature(repo: repo, branch: workspace.name)
        }
        store.remove(workspace)
        guard !linkedRepos.isEmpty else { return }
        Task {
            await FeatureProvisioner.teardown(
                featureName: workspace.name,
                in: project,
                across: linkedRepos
            )
        }
    }

    /// Start every runner this workspace is associated with. The
    /// decision logic lives in `RunnerManager.startPlan(for:)` (shared
    /// with unit tests and the e2e automation server); this view only
    /// renders the outcomes. Play never asks questions: flexible-port
    /// runners come up alongside other worktrees, fixed-port runners
    /// switch. When a switch displaced another worktree's instance, a
    /// transient notice says so and offers the "run both" upgrade
    /// (Claude rewrites the port to be env-driven).
    private func startRunnersForWorkspace(_ workspace: Workspace) {
        switch runners.startPlan(for: workspace) {
        case .openRunPane:
            store.activate(workspace.id)
            sidebarMode = .run(workspaceID: workspace.id)
        case .start(let toStart, let displacing):
            runners.executeStart(toStart)
            if let first = displacing.first {
                showSwitchNotice(
                    workspace: workspace,
                    runner: first.runner,
                    fromBranches: displacing
                        .filter { $0.runner.name == first.runner.name }
                        .map(\.fromBranch)
                )
            }
        }
    }

    /// Surface "switched <runner> off <branches>" with a one-click path
    /// to port isolation. Auto-dismisses; each new switch replaces the
    /// previous notice (only the latest is actionable anyway).
    private func showSwitchNotice(
        workspace: Workspace,
        runner: ParsedRunner,
        fromBranches: [String]
    ) {
        let notice = SwitchNotice(
            workspaceID: workspace.id,
            runnerName: runner.name,
            runner: runner,
            fromBranches: fromBranches
        )
        withAnimation(.snappy(duration: 0.18)) { switchNotice = notice }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            if switchNotice?.id == notice.id {
                withAnimation(.snappy(duration: 0.18)) { switchNotice = nil }
            }
        }
    }

    /// The transient banner itself: which worktree lost the port and
    /// why, plus "Run both" → the isolate flow (Claude makes the port
    /// env-driven so every worktree can run simultaneously from then
    /// on). Informational, never blocking — the switch already
    /// happened.
    private func switchNoticeBanner(_ notice: SwitchNotice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Switched \(notice.runnerName) off \(notice.fromBranches.joined(separator: ", ")) — it has one fixed port.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.18)) { switchNotice = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            Button {
                runners.pendingIsolation = notice.runner
                store.activate(notice.workspaceID)
                sidebarMode = .run(workspaceID: notice.workspaceID)
                withAnimation(.snappy(duration: 0.18)) { switchNotice = nil }
            } label: {
                Label("Run both — give each worktree its own port", systemImage: "wand.and.stars")
                    .font(.caption2.weight(.semibold))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(.orange)
            .help("Claude rewrites \(notice.runnerName) to read its port from an env var; after that, every worktree runs side by side.")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    /// Stop every runner instance currently alive on this workspace's
    /// worktree. Per-instance so concurrent branches keep running.
    private func stopAllRunning(on workspace: Workspace) {
        for runner in runners.runners {
            guard runners.status(for: runner, on: workspace.name)?.isRunning == true
            else { continue }
            runners.stop(runner, on: workspace.name)
        }
    }

    /// Stop and clear any runner whose currently-selected worktree is
    /// the one we're about to remove for `repo`. Matches by both the
    /// runner's repo (derived from its cwd) and the branch we're about
    /// to delete — the only safe overlap.
    private func stopRunnersTiedToFeature(repo: Repository, branch: String) {
        for runner in runners.runners {
            guard runners.repoName(for: runner) == repo.name else { continue }
            if runners.status(for: runner, on: branch)?.isRunning == true {
                runners.stop(runner, on: branch)
            }
            // Clear the override even if the runner wasn't running —
            // otherwise the next Start would point at a deleted folder.
            runners.setActiveBranch(nil, for: runner)
        }
    }

    /// Last-step cleanup once every linked repo has reached
    /// `.cleanedUp` in the merge sheet: drop the workspace from the
    /// sidebar, remove the now-empty `features/<name>/` aggregation
    /// directory, and dismiss the sheet. Deferred to the next runloop
    /// so the sheet's state-update doesn't fight with the dismissal.
    private func finalizeFeatureCleanup(_ workspace: Workspace) {
        let featureDir = FeatureProvisioner.featureDirectory(
            in: repoStore.project,
            name: workspace.name
        )
        DispatchQueue.main.async {
            store.remove(workspace)
            try? FileManager.default.removeItem(at: featureDir)
            pendingMerge = nil
        }
    }
}

// MARK: - Switch notice

/// State behind the transient "switched worktrees" banner. Play on a
/// worktree never blocks on a dialog — a fixed-port runner that was
/// live elsewhere is simply switched over, and this notice tells the
/// user what happened plus offers the upgrade path: Isolate with
/// Claude, so every worktree gets its own port and future plays run
/// side by side instead of switching.
private struct SwitchNotice: Identifiable, Equatable {
    let id = UUID()
    /// Workspace whose Play caused the switch — the isolate flow's Run
    /// pane is scoped to it.
    let workspaceID: UUID
    let runnerName: String
    let runner: ParsedRunner
    /// Worktrees whose instances were stopped to free the port.
    let fromBranches: [String]
}

// MARK: - Repo row (passive, in the Repositories card)

private struct RepoRow: View {
    let repository: Repository
    let onReveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(isHovered ? 0.18 : 0.12))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(repository.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(repository.defaultBranch)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(repository.rootURL.path)
        .contextMenu {
            Button("Show in Finder", action: onReveal)
        }
    }
}

// MARK: - Customize sheet

private struct CustomizeWorkspaceSheet: View {
    let initialName: String
    let selectedSymbol: String
    let selectedTint: Color
    let onRename: (String) -> Void
    let onPickSymbol: (String) -> Void
    let onPickTint: (Color) -> Void
    let onDismiss: () -> Void

    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    private static let symbols: [String] = [
        "terminal.fill", "house.fill", "chevron.left.forwardslash.chevron.right",
        "doc.text.magnifyingglass", "circle.grid.3x3.fill", "square.stack.3d.up.fill",
        "globe", "bolt.fill", "leaf.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "server.rack", "cloud.fill", "cpu.fill",
        "externaldrive.fill", "shippingbox.fill", "graduationcap.fill",
        "briefcase.fill", "paintpalette.fill", "gamecontroller.fill",
        "music.note", "flag.fill", "star.fill", "heart.fill",
    ]

    private static let tints: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo, .gray,
    ]

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Feature")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Feature name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commitName(); onDismiss() }
                    .onChange(of: name) { _, _ in commitName() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button {
                            onPickSymbol(symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(symbol == selectedSymbol ? selectedTint.opacity(0.85) : Color.secondary.opacity(0.12))
                                )
                                .foregroundStyle(symbol == selectedSymbol ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tint")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Self.tints, id: \.self) { tint in
                        Button {
                            onPickTint(tint)
                        } label: {
                            Circle()
                                .fill(tint)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(tint == selectedTint ? 0.9 : 0), lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    commitName()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = initialName
            nameFocused = true
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != initialName else { return }
        onRename(trimmed)
    }
}
