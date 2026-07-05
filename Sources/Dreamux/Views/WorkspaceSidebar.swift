import SwiftUI
import UniformTypeIdentifiers

/// The Work Items column of a project window. Top to bottom: icon+label
/// rows for Signals and Browser, the collapsible Orchestration Files
/// list, the Plans & Specs section (plan-backed work reachable from its
/// plan rows), and the always-visible Repositories card with its Add
/// repository row.
struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    @Bindable var runners: RunnerManager
    @Bindable var layout: SidebarLayoutStore
    @Binding var sidebarMode: SidebarMode
    @Bindable var docStore: DocStore
    let planRunner: PlanRunCoordinator
    let planQueue: PlanQueueController
    /// Non-e2e "merge and continue" gate channel — the plan queue's
    /// `requestMerge` closure parks the target workspace id here when
    /// the e2e bridge is inactive; consumed below exactly like
    /// `consumePendingMergeIfAny()`.
    @Binding var gateMergeWorkspaceID: UUID?
    /// Plan-row *Close* channel — `PlansSpecsSection` parks the target
    /// workspace id here (it doesn't own the confirm alert); consumed below
    /// exactly like `gateMergeWorkspaceID`, driving the `pendingClose` alert.
    @Binding var gateCloseWorkspaceID: UUID?
    let onOpenDoc: (URL) -> Void
    /// Open a doc jumped to a 1-based line (phase/task rows).
    let onOpenDocAtLine: (URL, Int) -> Void
    /// Enqueue a course-correction nudge on the project's `PlanNudgeCenter`
    /// (owned by the `ProjectSession` bundle this view can't see) — forwarded
    /// straight into `PlansSpecsSection`.
    let onCourseCorrectionNudge: (PlanDoc, String, CorrectionPriority) -> Void
    /// Auto-run failure lookup (`ProjectSession.autoRunFailures`) —
    /// forwarded straight into `PlansSpecsSection`.
    let autoRunFailure: (String) -> String?

    /// Collapsed subfolders inside Orchestration Files (absent = open).
    @State private var collapsedFolders: Set<String> = []
    @State private var hoveredTile: SidebarTile?
    @State private var hoveredOrchestrationURL: URL?
    @State private var showAddFeature = false
    @State private var showAddRepo = false
    @State private var addError: String?
    @State private var isWorking = false
    @State private var pendingClose: Workspace?
    @State private var pendingMerge: Workspace?
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
    /// Non-nil when the pinned main row's last activation failed to
    /// materialize a default-branch worktree in one or more repos —
    /// surfaced on the row itself (tooltip + warning tint), never a modal.
    @State private var mainWorktreeIssue: String?

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
            let record = docStore.ledger.recordForPlan(docStore.relativePath(of: plan))
            RunPlanSheet(
                plan: plan,
                initialBranch: record?.featureName
                    ?? PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent),
                availableRepos: repoStore.repositories,
                isResume: record != nil,
                onSubmit: { branch, repoIDs in
                    runningPlan = nil
                    executePlan(plan, branch: branch, repoIDs: repoIDs)
                },
                onCancel: { runningPlan = nil }
            )
        }
        .sheet(isPresented: $showNewPlan) {
            NewPlanSheet(
                autoRunParallel: $layout.autoRunParallel,
                onSubmit: { idea in
                    showNewPlan = false
                    openPlanningSession { digest in
                        PlanPrompts.brainstormKickoff(idea: idea, intakeDigest: digest)
                    }
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
        .onChange(of: gateMergeWorkspaceID) { _, id in
            guard let id, let workspace = store.workspaces.first(where: { $0.id == id })
            else { return }
            gateMergeWorkspaceID = nil
            pendingMerge = workspace
        }
        .onChange(of: gateCloseWorkspaceID) { _, id in
            guard let id, let workspace = store.workspaces.first(where: { $0.id == id })
            else { return }
            gateCloseWorkspaceID = nil
            pendingClose = workspace
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Simple icon+label rows (Raycast/Linear style) — the Arc
            // tile grid was outsized for two entries.
            VStack(spacing: 2) {
                ForEach(layout.tiles) { tile in
                    tileRow(tile)
                }
            }

            filesSection

            PlansSpecsSection(
                docStore: docStore,
                layout: layout,
                featureExists: { name in store.featureNames.contains(name) },
                onOpenDoc: onOpenDoc,
                onOpenDocAtLine: onOpenDocAtLine,
                onRunPlan: { runningPlan = $0 },
                onNewPlan: { showNewPlan = true },
                onWritePlan: { spec in
                    openPlanningSession { digest in
                        PlanPrompts.writePlanKickoff(
                            specRelativePath: docStore.relativePath(of: spec),
                            intakeDigest: digest)
                    }
                },
                queue: planQueue,
                onOpenFeature: { name in
                    guard let workspace = store.featureWorkspace(named: name)
                    else { return }
                    sidebarMode = .workspace
                    store.activate(workspace.id)
                },
                onEnqueue: { doc in planQueue.enqueue(docStore.relativePath(of: doc)) },
                featureName: { featureName(for: $0) },
                hasUnread: { name in
                    guard let workspace = store.featureWorkspace(named: name)
                    else { return false }
                    return store.hasUnread(for: workspace)
                },
                runners: runners,
                workspaceForFeature: { name in
                    store.featureWorkspace(named: name)
                },
                makeRunControls: { runControls(for: $0) },
                gateMergeWorkspaceID: $gateMergeWorkspaceID,
                gateCloseWorkspaceID: $gateCloseWorkspaceID,
                onCourseCorrectionNudge: onCourseCorrectionNudge,
                autoRunFailure: autoRunFailure,
                onViewTaskChanges: { plan, task in
                    viewTaskChanges(plan: plan, task: task)
                },
                mainWorkspaceActive: store.workspaces.first(where: \.isMain).map(isWorkspaceActive) ?? false,
                mainWorktreeIssue: mainWorktreeIssue,
                onOpenMain: { openMainWorkspace() },
                mainBranchDisplayName: repoStore.repositories.first?.defaultBranch ?? "main",
                mainRepoNames: repoStore.repositories.map(\.name),
                mainWorkspace: { store.workspaces.first(where: \.isMain) }
            )

            switchNoticeIfAny

            // The Ad hoc section is retired for now (user call, 2026-07-04)
            // — plan-less scratch workspaces are reachable via ⌘1-9/⌘⇧T
            // only, and Add Feature is dormant with it. `adHocWorkspaces`
            // and its tests stay for when it returns.

            VStack(alignment: .leading, spacing: 6) {
                // Repositories are always visible — the list is short and
                // hiding it made "why can't I run a plan?" undiagnosable.
                repositoriesHeader
                card {
                    repoRows
                    addRepositoryRow
                }
            }
        }
    }

    /// Full-width "＋ Add repository" row at the bottom of the repo card —
    /// the affordance a bare `+` icon was too easy to miss for.
    private var addRepositoryRow: some View {
        Button {
            showAddRepo = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add repository")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Collapsible raw-files view of the orchestration docs, grouped by
    /// their subfolder (plans/, specs/, loose) — Plans & Specs below it
    /// stays the work-centric grouping.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { layout.filesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(layout.filesExpanded ? 90 : 0))
                    Text("Orchestration Files")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if layout.filesExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(orchestrationFolders, id: \.folder) { group in
                        orchestrationFolderRow(group)
                        if !collapsedFolders.contains(group.folder) {
                            ForEach(group.docs) { doc in
                                orchestrationFileRow(doc)
                            }
                        }
                    }
                }
            }
        }
    }

    private func orchestrationFolderRow(
        _ group: (folder: String, docs: [PlanDoc])
    ) -> some View {
        let collapsed = collapsedFolders.contains(group.folder)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if collapsed { collapsedFolders.remove(group.folder) }
                else { collapsedFolders.insert(group.folder) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(group.folder)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(group.docs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func orchestrationFileRow(_ doc: PlanDoc) -> some View {
        Button { onOpenDoc(doc.fileURL) } label: {
            HStack(spacing: 7) {
                Image(systemName: doc.kind == .plan ? "checklist"
                      : (doc.kind == .spec ? "doc.text.magnifyingglass" : "doc.text"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(doc.fileURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if hoveredOrchestrationURL == doc.fileURL {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredOrchestrationURL = doc.fileURL }
            else if hoveredOrchestrationURL == doc.fileURL { hoveredOrchestrationURL = nil }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(doc.fileURL.path, forType: .string)
            }
        }
    }

    /// Orchestration docs grouped by their project-relative subfolder
    /// (`docs/plans`, `docs/specs`, …), folders sorted by name. Files sort
    /// newest-first — the date-prefixed names make alphabetical order
    /// oldest-first, which buries the docs you're actually working on.
    private var orchestrationFolders: [(folder: String, docs: [PlanDoc])] {
        Dictionary(grouping: docStore.docs) { doc in
            let dir = (docStore.relativePath(of: doc) as NSString).deletingLastPathComponent
            return dir.isEmpty ? "." : dir
        }
        .sorted { $0.key < $1.key }
        .map { (folder: $0.key,
                docs: $0.value.sorted {
                    $0.fileURL.lastPathComponent > $1.fileURL.lastPathComponent
                }) }
    }

    /// One icon+label row per pinned destination — monochrome outline
    /// icon, callout label, hover highlight, tinted while selected.
    private func tileRow(_ tile: SidebarTile) -> some View {
        let selected = (tile == .signals && sidebarMode == .signals)
            || (tile == .library && sidebarMode == .library)
        return Button {
            handleTileTap(tile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(width: 20)
                Text(tile.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if selected || hoveredTile == tile {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14)
                                   : Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredTile = tile }
            else if hoveredTile == tile { hoveredTile = nil }
        }
    }

    private static let browserHomepage = URL(string: "https://www.google.com")!

    private func handleTileTap(_ tile: SidebarTile) {
        switch tile {
        case .signals:
            sidebarMode = .signals
        case .browser:
            openBrowserTab()
        case .library:
            sidebarMode = .library
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
                .font(.system(size: 13, weight: .semibold))
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
        return ZStack(alignment: .trailing) {
            Button { selectWorkspace(workspace) } label: { body() }
                .buttonStyle(.plain)
                .help(workspace.workingDirectory ?? workspace.name)
                .contextMenu { featureMenu(for: workspace) }

            runControls(for: workspace)
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

    /// The trailing run-control cluster for a workspace, wired to this view's
    /// actions. Shared with `PlansSpecsSection` (passed as `makeRunControls`)
    /// so plan rows drive runners exactly like feature rows do.
    private func runControls(for workspace: Workspace) -> WorkspaceRunControls {
        WorkspaceRunControls(
            workspace: workspace,
            runners: runners,
            openServices: { openServices(for: workspace, runnerName: $0) },
            start: { startRunnersForWorkspace(workspace) },
            stop: { stopAllRunning(on: workspace) },
            configure: { configure(workspace) }
        )
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

    // MARK: - Plan-backed / ad-hoc partition

    /// The ledger record for a plan, keyed by its project-relative path.
    private func planRecord(_ plan: PlanDoc) -> PlanRunRecord? {
        docStore.ledger.recordForPlan(docStore.relativePath(of: plan))
    }

    /// The feature a plan runs as (ledger name, else filename-derived
    /// branch). Shared by the Plans section's row labels and the ad-hoc
    /// partition so both resolve names identically.
    private func featureName(for plan: PlanDoc) -> String {
        AdHocWorkspaces.featureName(for: plan, record: planRecord)
    }

    /// Workspaces with no plan behind them — reachable only from their own
    /// row. Everything a plan runs as lives under its plan row instead.
    private var adHocWorkspaces: [Workspace] {
        let planBacked = AdHocWorkspaces.planBackedFeatureNames(
            in: docStore.initiatives, record: planRecord)
        return store.workspaces.filter { !planBacked.contains($0.name) && !$0.isMain }
    }

    /// Live drag-reorder scoped to the ad-hoc subset: reads the ad-hoc
    /// workspaces in sidebar order, and on write splices the reordered
    /// subset back into `store.workspaces`, leaving plan-backed rows where
    /// they sit.
    private var adHocWorkspacesBinding: Binding<[Workspace]> {
        Binding(
            get: { adHocWorkspaces },
            set: { reordered in
                let planBacked = AdHocWorkspaces.planBackedFeatureNames(
                    in: docStore.initiatives, record: planRecord)
                var next = reordered.makeIterator()
                store.workspaces = store.workspaces.map { workspace in
                    planBacked.contains(workspace.name) ? workspace : (next.next() ?? workspace)
                }
            }
        )
    }

    @ViewBuilder
    private var switchNoticeIfAny: some View {
        if let notice = switchNotice {
            switchNoticeBanner(notice)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Repositories

    /// Always-visible section label — the repo list is short, and hiding
    /// it made "why can't I run a plan?" undiagnosable. Adding lives in
    /// the full-width `addRepositoryRow` at the bottom of the card.
    private var repositoriesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Repositories")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isWorking {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Working…")
            }
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
        case .library: return false
        }
    }

    /// Activate the reserved main workspace, materializing any missing
    /// default-branch worktrees. Failures land on the row (tooltip +
    /// warning tint), never in a modal — the workspace still activates
    /// so the terminal (project root) keeps working.
    private func openMainWorkspace() {
        let workspace = store.mainWorkspace(
            name: repoStore.repositories.first?.defaultBranch ?? "main",
            workingDirectory: repoStore.project.rootPath.path,
            linkedRepoIDs: repoStore.repositories.map(\.name))
        sidebarMode = .workspace
        store.activate(workspace.id)
        mainWorktreeIssue = nil
        Task { @MainActor in
            var issues: [String] = []
            for repo in repoStore.repositories {
                let existing = await GitOperations.worktreeURL(
                    forBranch: repo.defaultBranch, in: repo.rootURL)
                guard existing == nil else { continue }
                do {
                    try await GitOperations.addWorktree(
                        in: repo.rootURL, branch: repo.defaultBranch)
                } catch {
                    issues.append("\(repo.name): \(error.localizedDescription)")
                }
            }
            if !issues.isEmpty {
                mainWorktreeIssue = "Couldn't check out "
                    + issues.joined(separator: "; ")
            }
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

    /// Resolve the commits recorded for a task (agent + backstop) in each
    /// of the feature's repo worktrees and open a diff tab per repo with
    /// matches. No matches anywhere → explain instead of silently doing
    /// nothing (the task row's "View changes" hover button + context-menu
    /// item both call through here).
    private func viewTaskChanges(plan: PlanDoc, task: PlanTask) {
        let feature = featureName(for: plan)
        guard let workspace = store.featureWorkspace(named: feature)
        else {
            addError = "No workspace for this plan yet — run the plan first."
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
                sidebarMode = .workspace
                store.activate(workspace.id)
                store.session(for: workspace).openDiffTab(DiffRequest(
                    worktreeURL: worktree,
                    fromRevision: fromRevision,
                    toRevision: range.to,
                    title: repos.count > 1 ? "\(displayTitle) — \(repo.name)" : displayTitle))
                opened += 1
            }
            if opened == 0 {
                addError = "No commits recorded for \"\(displayTitle)\" yet. The agent commits when the task's boxes are ticked (auto-commit is \(WorkflowSettings.autoCommitEnabled ? "on" : "OFF — see Settings → Workflow"))."
            }
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
    ///
    /// `buildPrompt` receives the intake digest (nil on a project with no
    /// plans in flight) and returns the kickoff text. The digest is
    /// assembled *after* the `docStore.refresh()` below so it reflects the
    /// freshest inventory at send time; the driver's own quiescence gate
    /// (`ClaudePromptDriver.send`) is left entirely untouched.
    private func openPlanningSession(buildPrompt: @escaping (String?) -> String) {
        let workspace = store.activeWorkspace ?? store.workspaces.first ?? store.addWorkspace()
        store.activate(workspace.id)
        sidebarMode = .workspace
        let session = store.session(for: workspace)
        DocStore.ensureDocsHome(at: repoStore.project.rootPath)
        docStore.refresh()
        MCPInstaller.installIfNeeded(at: repoStore.project.rootPath.path)
        guard let tab = session.reuseOrOpenPlanningTab(
            at: repoStore.project.rootPath.path) else { return }
        tab.startIfNeeded()
        Task {
            let prompt = buildPrompt(await intakeDigest())
            ClaudePromptDriver.send(prompt, into: tab)
        }
    }

    /// Assemble the intake digest for a kickoff prompt, or nil when the
    /// project has no non-merged plans (the prompt then reproduces its
    /// pre-intake form). Reads the live `DocStore` inventory and, for
    /// running plans, worktree territory via `IntakeDigest.build`
    /// (`<repoRoot>/<feature>` per repo, diffed against each repo's
    /// default branch).
    private func intakeDigest() async -> String? {
        let featureExists: (String) -> Bool = { name in
            store.featureNames.contains(name)
        }
        guard docStore.plans.contains(where: {
            docStore.status(for: $0, featureExists: featureExists) != .merged
        }) else { return nil }
        return await IntakeDigest.build(
            docStore: docStore,
            repos: repoStore.repositories,
            queue: planQueue.entries,
            featureExists: featureExists)
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
        guard !workspace.isMain else { return }  // belt-and-braces — no UI offers this
        let project = repoStore.project
        let linkedRepos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        // Stop any runner that's executing on this feature's worktree —
        // its cwd is about to disappear from under it.
        for repo in linkedRepos {
            stopRunnersTiedToFeature(repo: repo, branch: workspace.name)
        }
        store.remove(workspace)
        docStore.reconcileLedger(
            existingFeatureNames: store.featureNames)
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
                    .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 9, weight: .semibold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 16, weight: .semibold))
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
