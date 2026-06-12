import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore
    @Bindable var runners: RunnerManager
    @Binding var sidebarMode: SidebarMode

    @State private var showAddFeature = false
    @State private var showAddRepo = false
    @State private var addError: String?
    @State private var isWorking = false
    @State private var pendingClose: Workspace?
    @State private var pendingMerge: Workspace?
    @State private var repositoriesExpanded = false
    @State private var switchNotice: SwitchNotice?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                signalsTile
                featuresSection
                Divider()
                repositoriesSection
            }
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
        .sheet(
            item: $pendingMerge,
            onDismiss: {}
        ) { workspace in
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

    // MARK: - Signals tile

    private var signalsTile: some View {
        modeTile(
            isSelected: sidebarMode == .signals,
            title: "Signals",
            symbol: "waveform.path.ecg",
            tint: .purple,
            hint: "View log streams from running services",
            onTap: { sidebarMode = .signals }
        )
    }

    private func modeTile(
        isSelected: Bool,
        title: String,
        symbol: String,
        tint: Color,
        hint: String,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(isSelected ? 0.95 : 0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(isSelected ? 0 : 0.28), lineWidth: 1)
                        )
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : tint)
                }
                .frame(width: 28, height: 28)

                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
    }

    // MARK: - Features

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

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Work Items / Features")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)

            if let notice = switchNotice {
                switchNoticeBanner(notice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.workspaces.isEmpty, repoStore.repositories.isEmpty {
                Text("Add a repository, then create your first feature.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                ForEach(store.workspaces) { workspace in
                    WorkspaceButton(
                        workspace: workspace,
                        isActive: isWorkspaceActive(workspace),
                        hasUnread: store.hasUnread(for: workspace),
                        lastActivityMessage: store.lastActivityMessage(for: workspace),
                        isRunning: !runners.runningRunners(onBranch: workspace.name).isEmpty,
                        openableRunnerNames: runners.openableRunners(for: workspace).map(\.name),
                        onSelect: {
                            // Picking a Work Item flips back to the
                            // terminal view, otherwise the activation
                            // would happen silently while the Run page
                            // stayed on screen.
                            sidebarMode = .workspace
                            store.activate(workspace.id)
                        },
                        onConfigure: {
                            store.activate(workspace.id)
                            sidebarMode = .run(workspaceID: workspace.id)
                        },
                        onStart: { startRunnersForWorkspace(workspace) },
                        onStopRunning: { stopAllRunning(on: workspace) },
                        onOpen: { runnerName in
                            openServices(for: workspace, runnerName: runnerName)
                        },
                        onClose: { pendingClose = workspace },
                        onRename: { store.setName($0, for: workspace.id) },
                        onPickSymbol: { store.setIcon($0, for: workspace.id) },
                        onPickTint: { store.setTint($0, for: workspace.id) },
                        onMerge: workspace.linkedRepoIDs.isEmpty ? nil : { pendingMerge = workspace }
                    )
                }

                addFeatureRow
            }
        }
    }

    private var addFeatureRow: some View {
        Button {
            showAddFeature = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )
                    .foregroundStyle(.secondary)
                Text(isWorking ? "Adding…" : "Add Feature")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            collapsibleHeader(
                "Repositories",
                isExpanded: $repositoriesExpanded,
                addAction: { showAddRepo = true },
                disabled: isWorking
            )

            if repositoriesExpanded {
                if repoStore.repositories.isEmpty {
                    Text("No repositories in this project yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(repoStore.repositories) { repo in
                        RepoRow(
                            repository: repo,
                            onReveal: {
                                NSWorkspace.shared.activateFileViewerSelecting([repo.rootURL])
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func sectionHeader(
        _ title: String,
        addAction: @escaping () -> Void,
        disabled: Bool,
        disabledHint: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: addAction) {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(disabled ? (disabledHint ?? "Working…") : "Add Repository")
        }
        .padding(.bottom, 2)
    }

    /// Section header with a leading disclosure chevron that toggles the
    /// `isExpanded` binding when clicked. The "Add" button stays on the
    /// trailing edge and is independently clickable — it both expands the
    /// section (so the user can see what they just added) and fires the
    /// add action.
    @ViewBuilder
    private func collapsibleHeader(
        _ title: String,
        isExpanded: Binding<Bool>,
        addAction: @escaping () -> Void,
        disabled: Bool,
        disabledHint: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if !isExpanded.wrappedValue {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.wrappedValue = true
                    }
                }
                addAction()
            } label: {
                Image(systemName: isWorking ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(disabled ? (disabledHint ?? "Working…") : "Add \(title.dropLast())")
        }
        .padding(.bottom, 2)
    }

    // MARK: - Actions

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

// MARK: - Workspace pill

private struct WorkspaceButton: View {
    let workspace: Workspace
    let isActive: Bool
    let hasUnread: Bool
    let lastActivityMessage: String?
    /// At least one runner is currently alive on this workspace's
    /// worktree. Flips the trailing-edge play button into a stop
    /// button (which calls onStopRunning instead of onRun).
    let isRunning: Bool
    /// Non-headless services (open target or port) associated with
    /// this workspace. Non-empty + running → the open button appears
    /// where the gear used to live.
    let openableRunnerNames: [String]
    let onSelect: () -> Void
    let onConfigure: () -> Void
    let onStart: () -> Void
    let onStopRunning: () -> Void
    /// nil = open every non-headless service; a name = just that one
    /// (picked from the open button's press-and-hold menu).
    let onOpen: (String?) -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onPickSymbol: (String) -> Void
    let onPickTint: (Color) -> Void
    var onMerge: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPickerPresented = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                rowContents
            }
            .buttonStyle(.plain)
            .help(workspace.workingDirectory ?? workspace.name)
            .contextMenu {
                Button("Run Settings…", action: onConfigure)
                Button("Customize…") { isPickerPresented = true }
                if !workspace.linkedRepoIDs.isEmpty, let onMerge {
                    Button("Merge…", action: onMerge)
                }
                Divider()
                Button("Close \"\(workspace.name)\"", role: .destructive, action: onClose)
            }
            .sheet(isPresented: $isPickerPresented) {
                CustomizeWorkspaceSheet(
                    initialName: workspace.name,
                    selectedSymbol: workspace.symbol,
                    selectedTint: workspace.tint,
                    onRename: onRename,
                    onPickSymbol: onPickSymbol,
                    onPickTint: onPickTint,
                    onDismiss: { isPickerPresented = false }
                )
            }

            // Trailing-edge run controls. Live outside the row's Button
            // so clicks don't also fire onSelect (which would flip
            // sidebarMode back to .workspace and undo any open Run pane).
            HStack(spacing: 4) {
                if isRunning, !openableRunnerNames.isEmpty {
                    openButton
                }
                playStopButton
            }
            .padding(.trailing, 8)
        }
        // Hover is tracked on the whole ZStack, not the inner row
        // Button: the gear/play controls are overlaid siblings, so a
        // button-scoped tracking region reports an exit the moment the
        // pointer reaches them — and since their opacity is driven by
        // this same flag, the controls flickered at the boundary.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// Open button — lives where the gear used to. Click opens every
    /// non-headless service of this worktree (in-app tabs for URLs);
    /// press-and-hold lists the services to open just one. Only shown
    /// while something is running, since opening a stopped service is
    /// a connection-refused tab.
    private var openButton: some View {
        Menu {
            ForEach(openableRunnerNames, id: \.self) { name in
                Button("Open \(name)") { onOpen(name) }
            }
        } label: {
            Image(systemName: "safari")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.10)))
        } primaryAction: {
            onOpen(nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open \(workspace.name)'s services (hold to pick one)")
        .opacity(isHovered || isRunning ? 1 : 0.45)
    }

    /// Play/stop button → the verb. Starts every runner this workspace
    /// is associated with, then morphs to a stop button to halt them.
    /// Press-and-hold reveals the lower-frequency Run Settings entry
    /// (the pane the old gear button opened — also in the row's
    /// right-click menu).
    private var playStopButton: some View {
        Menu {
            Button("Run Settings…", action: onConfigure)
        } label: {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.green))
        } primaryAction: {
            isRunning ? onStopRunning() : onStart()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isRunning ? "Stop running services on \(workspace.name) (hold for Run Settings)"
                        : "Start \(workspace.name) (hold for Run Settings)")
        .opacity(isHovered || isRunning ? 1 : 0.55)
    }

    private var rowContents: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(workspace.tint.opacity(isActive ? 0.95 : (isHovered ? 0.32 : 0.18)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(workspace.tint.opacity(isActive ? 0 : 0.28), lineWidth: 1)
                    )
                Image(systemName: workspace.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : workspace.tint)
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .offset(x: 3, y: -3)
                    .opacity(hasUnread ? 1 : 0)
                    .animation(.snappy(duration: 0.18), value: hasUnread)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomTrailing) {
                // Live-runner indicator — a green dot in the
                // opposite corner from the unread badge so they
                // never overlap.
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .offset(x: 3, y: 3)
                    .opacity(isRunning ? 1 : 0)
                    .animation(.snappy(duration: 0.18), value: isRunning)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? .primary : .secondary)
                if !workspace.linkedRepoIDs.isEmpty {
                    repoChips
                }
                if let lastActivityMessage, !lastActivityMessage.isEmpty {
                    Text(lastActivityMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Leave room on the trailing edge for the gear + play/stop
            // pair (drawn by the parent ZStack so they sit on top of
            // this row's selectable area).
            Spacer().frame(width: 52)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isActive
                        ? Color.primary.opacity(0.10)
                        : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.primary)
                .frame(width: 3, height: isActive ? 22 : 0)
                .offset(x: -8)
                .animation(.snappy(duration: 0.18), value: isActive)
        }
        .contentShape(Rectangle())
    }

    private var repoChips: some View {
        HStack(spacing: 4) {
            ForEach(workspace.linkedRepoIDs.prefix(3), id: \.self) { repo in
                Text(repo)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
            if workspace.linkedRepoIDs.count > 3 {
                Text("+\(workspace.linkedRepoIDs.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
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

// MARK: - Repo row (passive, in the Repositories footer)

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
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(repository.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(repository.defaultBranch)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
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
