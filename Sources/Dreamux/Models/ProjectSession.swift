import Foundation
import Observation

/// Everything for one open project that must outlive the view layer:
/// terminals (PTYs and their ghostty surfaces), running dev servers, the
/// plan queue, doc watchers, and the stores that own them. Views are
/// cheap projections rebuilt on every project switch; this bundle is
/// created once per (window, project) by `ProjectSessionRegistry` and
/// lives until the window closes — switching projects must never
/// interrupt a shell or a queued plan run.
///
/// All store construction and inter-store wiring lives here (it used to
/// be split between `ProjectWindowContents.init` and `ContentView`,
/// whose per-switch re-init was exactly what killed the terminals).
@MainActor
@Observable
final class ProjectSession {
    let project: Project
    let store: WorkspaceStore
    let repoStore: RepoStore
    let layout: SidebarLayoutStore
    let runConfig: RunConfigStore
    let signals: SignalStore
    let runners: RunnerManager
    let fileTree: FileTreeStore
    let docStore: DocStore
    let planRunner: PlanRunCoordinator
    let planQueue: PlanQueueController
    let nudgeCenter: PlanNudgeCenter

    /// Non-e2e channel for the plan queue's "merge and continue" gate
    /// action: `WorkspaceSidebar` owns the merge sheet's presentation
    /// state, so the queue parks the target workspace id here the same
    /// way `E2EBridge.pendingMergeWorkspaceID` does for the automation
    /// server. Lives on the bundle (not view `@State`) so a gate fired
    /// while the project is in a background window position isn't lost.
    var pendingGateMergeWorkspaceID: UUID?

    /// Non-e2e channel for the plan-row *Close* action: `PlansSpecsSection`
    /// doesn't own the close confirm-alert (it lives on `WorkspaceSidebar`),
    /// so it parks the target workspace id here and the sidebar adopts it —
    /// the close-side twin of `pendingGateMergeWorkspaceID`.
    var pendingCloseWorkspaceID: UUID?

    @ObservationIgnored private var didBootstrap = false

    init(project: Project) {
        self.project = project

        let layout = SidebarLayoutStore(project: project)
        let store = WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        store.layout = layout
        let repoStore = RepoStore(project: project)

        let runConfig = RunConfigStore(project: project)
        let signals = SignalStore()
        let runners = RunnerManager(project: project, signals: signals)
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

        let fileTree = FileTreeStore()
        let docStore = DocStore(project: project)
        let planRunner = PlanRunCoordinator(
            project: project,
            workspaceStore: store,
            repoStore: repoStore,
            docStore: docStore
        )

        let planQueue = PlanQueueController(project: project)
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
            // in the last 5 s.
            return store.session(for: workspace).allShellsQuiescent(for: 5)
        }
        planQueue.runPlan = { [weak docStore, weak planRunner, weak repoStore] path in
            guard let docStore, let planRunner, let repoStore else {
                throw PlanRunError.notAPlan
            }
            docStore.refresh()
            guard let doc = docStore.docs.first(
                where: { docStore.relativePath(of: $0) == path }) else {
                throw PlanRunError.notAPlan
            }
            try await planRunner.runPlan(
                doc,
                branchName: PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent),
                repoNames: repoStore.repositories.map(\.name)
            )
        }

        let nudgeCenter = PlanNudgeCenter()

        self.store = store
        self.repoStore = repoStore
        self.layout = layout
        self.runConfig = runConfig
        self.signals = signals
        self.runners = runners
        self.fileTree = fileTree
        self.docStore = docStore
        self.planRunner = planRunner
        self.planQueue = planQueue
        self.nudgeCenter = nudgeCenter

        // Needs `self` for the gate channel, so it's wired after the
        // stored properties. Weak: the queue is owned by this bundle and
        // must not retain it back through its own closure.
        planQueue.requestMerge = { [weak self] featureName in
            guard let self,
                  let workspace = self.store.workspaces.first(where: { $0.name == featureName })
            else { return }
            // The merge sheet is owned by WorkspaceSidebar; reuse the
            // same pending channel the e2e openMergeSheet command uses.
            E2ERegistry.shared.bridge(forProject: self.project.id)?
                .pendingMergeWorkspaceID = workspace.id
            // When e2e is inactive the bridge is nil — park on the
            // bundle-local channel the sidebar also observes.
            self.pendingGateMergeWorkspaceID = workspace.id
        }

        // Live nudges (Phase 2): the center parks a one-line prompt for a
        // running plan and delivers it into that feature's agent tab under
        // the same quiescence + echo discipline every programmatic send
        // obeys. Every terminal-touching effect is a closure resolved here;
        // the center itself stays PTY-free (and unit-testable).
        nudgeCenter.status = { [weak self] path in
            guard let self else { return nil }
            // Fold the queue's merge gate into `awaitingReview` so the gate
            // rail holds even after a course correction adds an unchecked
            // step (which would otherwise flip the derived status back to
            // `running` and let a nudge slip past the gate).
            if self.planQueue.state == .atGate, self.planQueue.currentPlanPath == path {
                return .awaitingReview
            }
            guard let doc = self.docStore.docs.first(
                where: { self.docStore.relativePath(of: $0) == path }) else { return nil }
            return self.docStore.status(for: doc) { name in
                self.store.workspaces.contains { $0.name == name }
            }
        }
        nudgeCenter.isQuiescent = { [weak self] path in
            self?.agentTab(forPlan: path)?.isShellQuiescent(for: 0.4) ?? false
        }
        nudgeCenter.send = { [weak self] path, prompt in
            guard let tab = self?.agentTab(forPlan: path) else { return }
            ClaudePromptDriver.type(prompt, into: tab)
        }
        // Retry parked nudges on the queue's existing poll cadence — an
        // additive hook, no state-machine change.
        planQueue.onPoll = { [weak self] in self?.nudgeCenter.deliverPending() }

        // Intake enactment: every docs rescan (1) auto-enqueues any freshly
        // discovered `**Runs:** after <blocker>` plan behind its blocker, and
        // (2) auto-runs an explicit `**Runs:** parallel` plan when the
        // per-project toggle is on — both edge-triggered so each fires at
        // most once. Weak self breaks the docStore → closure → bundle cycle;
        // wired here (not with the other stores) because it captures self.
        docStore.onRefresh = { [weak self] in
            guard let self else { return }
            let statusOf: (PlanDoc) -> PlanStatus = { doc in
                self.docStore.status(for: doc) { name in
                    self.store.workspaces.contains { $0.name == name }
                }
            }
            IntakeEnactment.enact(
                docs: self.docStore.docs,
                queue: self.planQueue,
                relativePath: { self.docStore.relativePath(of: $0) },
                resolveReference: { self.docStore.resolvedURL(forReference: $0) },
                status: statusOf)
            IntakeEnactment.enactAutoRun(
                docs: self.docStore.docs,
                toggleOn: self.layout.autoRunParallel,
                relativePath: { self.docStore.relativePath(of: $0) },
                status: statusOf,
                hasAutoRun: { self.planQueue.hasAutoRun($0) },
                markAutoRun: { self.planQueue.markAutoRun($0) },
                launch: { self.autoRunPlan($0) })
            // Detect intake-integrate appends to running plans and park a
            // re-read nudge, then try to deliver any parked nudge now that
            // the scan is fresh (the refresh-side retry the spec calls for,
            // alongside the queue poll tick).
            self.nudgeCenter.noteRefresh(
                docs: self.docStore.docs,
                relativePath: { self.docStore.relativePath(of: $0) },
                status: statusOf,
                featureName: { self.docStore.ledger.recordForPlan($0)?.featureName },
                now: Date.init)
            self.nudgeCenter.deliverPending()
        }
    }

    /// The live plan-execution agent terminal for a plan path, via the
    /// ledger's feature name and that feature's workspace session — the
    /// tab the nudge center probes for quiescence and types into.
    private func agentTab(forPlan planPath: String) -> TabSession? {
        guard let feature = docStore.ledger.recordForPlan(planPath)?.featureName,
              let workspace = store.workspaces.first(where: { $0.name == feature })
        else { return nil }
        return store.session(for: workspace).agentTabSession()
    }

    /// Launch a plan under the auto-run toggle: the same worktree+terminal
    /// path the queue's `runPlan` closure and the Run Plan sheet use, with the
    /// filename-derived branch and every linked repo. Fire-and-forget — a
    /// launch failure leaves the plan `.ready` (the enacted record already
    /// stuck, so it won't retry) and the user can Run it by hand.
    private func autoRunPlan(_ doc: PlanDoc) {
        Task {
            try? await planRunner.runPlan(
                doc,
                branchName: PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent),
                repoNames: repoStore.repositories.map(\.name))
        }
    }

    /// One-time startup work: reconstruct the feature list from the
    /// worktrees on disk so the project comes back to the same set of
    /// work items it was closed with. Idempotent — later window appears
    /// (project switch-backs) must not reload over live workspaces and
    /// their running terminals. Callers refresh `repoStore` first.
    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        Task {
            await store.reloadFeatures(in: project, repoStore: repoStore)
        }
    }

    /// Expose this project's live stores to the automation server
    /// (no-op outside e2e). Idempotent; re-registering on every window
    /// appear also marks this project as the harness's active window.
    func registerWithE2E() {
        E2ERegistry.shared.registerWindowStores(
            projectID: project.id,
            workspaceStore: store,
            repoStore: repoStore
        )
        E2ERegistry.shared.registerRunStores(
            projectID: project.id,
            runners: runners,
            runConfig: runConfig,
            signals: signals
        )
        E2ERegistry.shared.registerDocStores(
            projectID: project.id,
            docStore: docStore,
            planRunner: planRunner,
            planQueue: planQueue
        )
    }
}

/// Window-scoped cache of `ProjectSession` bundles, keyed by project id.
/// Owned as `@State` by `ProjectWindow`: it survives project switches
/// (that's the whole point) and dies with the window, taking every
/// bundle's PTYs and runners with it. Plain class on purpose — creating
/// a bundle lazily during body evaluation must not invalidate the view.
@MainActor
final class ProjectSessionRegistry {
    private var sessions: [UUID: ProjectSession] = [:]

    func session(for project: Project) -> ProjectSession {
        if let existing = sessions[project.id] { return existing }
        let fresh = ProjectSession(project: project)
        sessions[project.id] = fresh
        return fresh
    }
}
