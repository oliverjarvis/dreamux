import Combine
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
    let flows: FlowStore

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

    /// Auto-run launches that failed, keyed by plan relative path — the
    /// visible record of an unattended launch going wrong (name collision
    /// with an existing feature, no repositories, …). The fired-once mark
    /// deliberately sticks on failure (no retry-spam loop), so without
    /// this the plan would just sit `ready` with no explanation. Cleared
    /// only by a later successful auto-run of the same path; manual Run
    /// always works regardless.
    var autoRunFailures: [String: String] = [:]

    /// App-context hook for surfacing an auto-run failure outside the
    /// sidebar (a user notification). Wired by `ProjectWindowContents`
    /// — NOT in `init` — because `UNUserNotificationCenter` cannot be
    /// touched from SPM test processes. `(planTitle, message)`.
    @ObservationIgnored var onAutoRunFailure: ((String, String) -> Void)?

    @ObservationIgnored private var didBootstrap = false

    /// Bus-subscriber path (external emits surfacing live in this
    /// project's Signals page). Held so it isn't torn down the moment
    /// `wireSignalPersistence` returns.
    @ObservationIgnored private var busSubscription: AnyCancellable?

    /// Flows spine: live signal feed into `flows`. Held for the same
    /// reason as `busSubscription`; no explicit teardown exists for
    /// either (this bundle has no `deinit`) — both cancel via ARC when
    /// the bundle is released, and `ClaudeRegistryPoller` additionally
    /// cancels its own polling `Task` in its own `deinit`.
    @ObservationIgnored private var flowBusSubscription: AnyCancellable?
    @ObservationIgnored private var registryPoller: ClaudeRegistryPoller?
    /// Hot-set + zoom transcript tailing for `flows`. Held for the same
    /// ARC-teardown reason as `registryPoller`; `startPolling`'s
    /// `onSnapshot` reconciles it on every poll.
    @ObservationIgnored private var flowTailerPool: FlowTailerPool?

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
                store.featureNames.contains(name)
            }
        }
        planQueue.featureNameForPlan = { [weak docStore] path in
            docStore?.ledger.recordForPlan(path)?.featureName
        }
        planQueue.isFeatureQuiescent = { [weak store] feature in
            guard let store,
                  let workspace = store.featureWorkspace(named: feature)
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
        // Queue backstop (Task 3): commit whatever the agent left
        // uncommitted at each task boundary and at the review gate, so a
        // forgotten commit never silently drops work. `tick()` only
        // reports which task titles are now fully-checked — the git work
        // (and the `autoCommitEnabled` check, re-read per event so a
        // mid-plan toggle flip takes effect immediately) lives entirely
        // here in the wiring, never inside the queue.
        planQueue.completedTaskTitlesForPlan = { [weak docStore] path in
            guard let docStore,
                  let plan = docStore.plans.first(where: { docStore.relativePath(of: $0) == path })
            else { return nil }
            return plan.tasks
                .filter { !$0.title.isEmpty && !$0.steps.isEmpty && $0.steps.allSatisfy(\.checked) }
                .map(\.title)
        }
        planQueue.onTaskCompleted = { [weak docStore, weak store, weak repoStore] path, title in
            Self.backstopCommit(
                message: "\(title) (auto)", planPath: path,
                docStore: docStore, workspaceStore: store, repoStore: repoStore)
        }
        planQueue.onPlanReachedReview = { [weak docStore, weak store, weak repoStore] path in
            Self.backstopCommit(
                message: "Plan review checkpoint (auto)", planPath: path,
                docStore: docStore, workspaceStore: store, repoStore: repoStore)
        }

        let nudgeCenter = PlanNudgeCenter()

        // Flows spine: cwd→workspace lookup goes through `store` (weakly
        // captured — the store outlives this closure for the bundle's
        // whole life, but the closure must not be what keeps it alive).
        let projectRoot = project.rootPath
        let flows = FlowStore(workspaceForCwd: { [weak store] cwd in
            guard let store else { return nil }
            return FlowWiring.workspaceID(
                forCwd: cwd, workspaces: store.workspaces, projectRoot: projectRoot
            )
        })

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
        self.flows = flows

        // Needs `self` for the gate channel, so it's wired after the
        // stored properties. Weak: the queue is owned by this bundle and
        // must not retain it back through its own closure.
        planQueue.requestMerge = { [weak self] featureName in
            guard let self,
                  let workspace = self.store.featureWorkspace(named: featureName)
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
                self.store.featureNames.contains(name)
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
                    self.store.featureNames.contains(name)
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

        wireSignalPersistence()
    }

    /// The auto-commit backstop (Task 3): commit whatever the agent left
    /// uncommitted in each of the plan's feature repo worktrees. Fire
    /// and forget — a failed or skipped commit is logged and never
    /// blocks the queue. Re-reads `WorkflowSettings.autoCommitEnabled`
    /// on every call (not once at wiring time) so a toggle flipped
    /// mid-plan takes effect on the very next event. Resolution mirrors
    /// `featureNameForPlan` above: ledger record → feature name →
    /// workspace by name → its linked repos → each repo's worktree for
    /// that branch.
    ///
    /// This runs concurrently with the agent's own `git commit`, and the
    /// following races are ACCEPTED rather than designed away:
    /// (a) the backstop may front-run the agent's commit — its "(auto)"
    /// message wins and the agent's subsequent `git commit` becomes a
    /// no-op ("nothing to commit"); `PlanPrompts` tells the agent to
    /// continue past that rather than stop. (b) a `git add -A` here,
    /// firing within the queue's ~3s poll window, may scoop files the
    /// agent already started editing for its NEXT task — accepted,
    /// nothing is lost, attribution is merely coarse (those edits ride
    /// along in this commit instead of the next one). (c) a concurrent
    /// backstop commit and agent commit can collide on git's
    /// `index.lock`; the loser's `git` invocation fails, is NSLog'd here,
    /// and the queue continues undisturbed. (d) when several tasks flip
    /// fully-checked within one poll tick, the first event's commit
    /// sweeps every leftover, so later same-tick events find a clean
    /// tree and simply skip (see `hasUncommittedChanges` guard below).
    private static func backstopCommit(
        message: String, planPath: String,
        docStore: DocStore?, workspaceStore: WorkspaceStore?, repoStore: RepoStore?
    ) {
        guard WorkflowSettings.autoCommitEnabled else { return }
        guard let docStore, let workspaceStore, let repoStore,
              let feature = docStore.ledger.recordForPlan(planPath)?.featureName,
              let workspace = workspaceStore.featureWorkspace(named: feature)
        else { return }
        let repos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        guard !repos.isEmpty else { return }
        Task { @MainActor in
            for repo in repos {
                guard let worktree = await GitOperations.worktreeURL(
                    forBranch: feature, in: repo.rootURL)
                else { continue }
                guard await GitOperations.hasUncommittedChanges(in: worktree) else { continue }
                do {
                    try await GitOperations.commitAll(message: message, in: worktree)
                } catch {
                    NSLog("auto-commit backstop failed in %@: %@",
                          worktree.path, String(describing: error))
                }
            }
        }
    }

    /// Bridge this project's in-memory signal ring to the app-global
    /// persistent bus. Order matters: hydrate FIRST (appendExternal —
    /// no forwarding), only then install `forward`, so history is never
    /// re-persisted on launch.
    ///
    /// Skipped entirely under XCTest: merely touching `SignalBus.shared`
    /// lazily opens the real `signals.db` under Application Support and
    /// binds the real `/tmp/dreamux-emit-*.sock` — fine for the running
    /// app (there's one process), fatal for a test suite that constructs
    /// many `ProjectSession`s and must stay hermetic. `NSClassFromString`
    /// sees the XCTest framework loaded in-process only when a test host
    /// (`swift test` / Xcode's test runner) launched us.
    private func wireSignalPersistence() {
        guard NSClassFromString("XCTestCase") == nil else { return }

        let projectDir = project.rootPath.path
        let bus = SignalBus.shared
        let uiStore = signals
        let flows = self.flows

        // 1. Hydrate the ring with recent history for this project.
        if let disk = bus.store {
            Task { @MainActor in
                let rows = (try? await disk.query(
                    kind: SignalKind.terminalLine, source: nil,
                    projectDir: projectDir, since: nil, limit: 500)) ?? []
                for row in rows.reversed() {  // query is newest-first; ring wants oldest-first
                    guard case .object(let obj) = row.payload,
                          case .string(let text)? = obj["text"] else { continue }
                    uiStore.appendExternal(source: row.source, line: text, at: row.ts)
                }
                self.installSignalForwarding(projectDir: projectDir, bus: bus)
            }
        } else {
            installSignalForwarding(projectDir: projectDir, bus: bus)
        }

        // Shared by the forwarding filter below and the flow wiring in
        // step 4: doubles as the workspace matcher *and* a project-root
        // fallback so a session running at the project root itself (no
        // workspace match) still counts.
        let isInProject: (String) -> Bool = { [weak self] cwd in
            guard let self else { return false }
            if FlowWiring.workspaceID(
                forCwd: cwd, workspaces: self.store.workspaces, projectRoot: self.project.rootPath
            ) != nil { return true }
            let root = self.project.rootPath.path
            return cwd == root || cwd.hasPrefix(root + "/")
        }

        // 2. Surface external emits (MCP signals_emit) in this project's
        //    Signals page, live. App-origin signals are skipped — they
        //    already went through the UI store on their way in. Flow
        //    signals qualify by cwd (via `isInProject`) instead of
        //    `project_dir`, since flow events tag the session's cwd —
        //    that's what lets flow lanes surface in SignalsView too.
        busSubscription = bus.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak uiStore] signal in
                guard signal.tags["origin"] != "app" else { return }
                let matchesProject = signal.tags["project_dir"] == projectDir
                    || (SignalKind.flowKinds.contains(signal.kind)
                        && (signal.tags["cwd"].map(isInProject) ?? false))
                guard matchesProject else { return }
                uiStore?.appendExternal(
                    source: signal.source,
                    line: Self.externalLine(for: signal),
                    at: signal.ts)
            }

        // 3. Health transitions → service.health envelopes.
        runners.statusChanged = { runnerName, branch, previous, new in
            bus.emit(Signal(
                source: "services.\(runnerName)",
                kind: SignalKind.serviceHealth,
                severity: Self.healthSeverity(for: new),
                tags: [
                    "origin": "app",
                    "project_dir": projectDir,
                    "service": runnerName,
                    "branch": branch,
                ],
                payload: .object([
                    "previous": .string(previous.map(Self.statusWord) ?? "none"),
                    "current": .string(Self.statusWord(new)),
                ])))
        }

        // 4. Flows spine: live flow signals → adapter → store, launch
        // replay from history, and a registry poll for session liveness.
        // The filter runs pre-hop, on `bus.publisher`'s own private
        // queue, so it must be `SignalKind.isFlowSignal` passed by
        // function reference rather than a closure literal — a closure
        // formed here would inherit this method's MainActor isolation
        // and trap when Combine invokes it synchronously on that queue
        // (this exact shape is what trapped in Group 2). `.receive(on:)`
        // follows the filter so the sink below, which touches `flows`,
        // runs on main.
        flowBusSubscription = bus.publisher
            .filter(SignalKind.isFlowSignal)   // nonisolated fn ref — safe on the bus queue
            .receive(on: DispatchQueue.main)
            .sink { [weak flows] signal in
                guard let event = ClaudeFlowAdapter.event(from: signal),
                      let cwd = event.cwd, isInProject(cwd) else { return }
                flows?.apply(event: event)
            }

        if let sqlite = bus.store {
            Task { @MainActor [weak flows] in
                let events = await FlowReplayLoader.events(store: sqlite)
                guard let flows else { return }
                for event in events where event.cwd.map(isInProject) == true {
                    flows.apply(event: event)
                }
            }
        }

        let home = ClaudeHome.root()

        // 5. Hot-set tailer pool: transcript/meta/agent-activity events
        // route straight into the adapter then the store, same shape as
        // the wiring sketch's callbacks — no separate subscription
        // layer needed since the pool already hops to `@MainActor`
        // before invoking any of these.
        let pool = FlowTailerPool(
            home: home,
            onTranscriptLines: { [weak flows] sessionID, lines in
                let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: lines)
                for event in events { flows?.apply(transcript: event, sessionID: sessionID) }
                if skipped > 0 { flows?.noteSkippedLines(skipped, sessionID: sessionID) }
            },
            onAgentLines: { [weak flows] sessionID, agentID, lines in
                if let activity = ClaudeFlowAdapter.lastActivity(fromAgentLines: lines) {
                    flows?.apply(agentActivity: activity, agentID: agentID, sessionID: sessionID)
                }
            },
            onMeta: { [weak flows] sessionID, meta in
                flows?.apply(meta: meta, sessionID: sessionID)
            }
        )
        flowTailerPool = pool

        let poller = ClaudeRegistryPoller(
            // Built fresh per poll rather than captured: `home: URL` is
            // Sendable, but `ClaudeSessionRegistryReader` itself isn't
            // (its `isAlive` closure isn't `@Sendable`), so capturing an
            // instance would fail the poller's `@Sendable` `read` closure.
            read: { ClaudeSessionRegistryReader(home: home).entries() },
            onSnapshot: { [weak flows, weak pool] entries in
                let projectEntries = entries.filter { isInProject($0.cwd) }
                flows?.apply(registry: projectEntries)
                pool?.reconcile(hot: projectEntries.filter {
                    $0.flowStatus == .running || $0.flowStatus == .waiting
                })
            }
        )
        registryPoller = poller
        poller.startPolling()
    }

    private func installSignalForwarding(projectDir: String, bus: SignalBus) {
        signals.forward = { entry, stream in
            var tags = [
                "origin": "app",
                "project_dir": projectDir,
                "service": entry.source,
                "level": entry.level.rawValue,
            ]
            if let stream { tags["stream"] = stream }
            bus.emit(Signal(
                source: entry.source,
                kind: SignalKind.terminalLine,
                ts: entry.timestamp,
                severity: entry.level == .error ? .warning : .info,
                tags: tags,
                payload: .terminalLine(entry.message, stream: stream ?? "combined")))
        }
    }

    /// Render an external signal as one log line for the UI ring.
    private static func externalLine(for signal: Signal) -> String {
        if case .object(let obj) = signal.payload,
           case .string(let text)? = obj["text"] {
            return "[\(signal.kind)] \(text)"
        }
        let payload: String
        if let data = try? JSONEncoder().encode(signal.payload),
           let s = String(data: data, encoding: .utf8) {
            payload = s
        } else {
            payload = ""
        }
        return "[\(signal.kind)] \(payload)"
    }

    private static func healthSeverity(for status: RunnerStatus) -> SignalSeverityLevel {
        switch status {
        case .running: return .success
        case .failed: return .critical
        case .exited(let code): return code == 0 ? .info : .warning
        case .idle: return .info
        }
    }

    private static func statusWord(_ status: RunnerStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .failed: return "failed"
        case .exited(let code): return "exited(\(code))"
        }
    }

    /// Park a course-correction nudge for a running plan and attempt
    /// immediate delivery — the way `PlansSpecsSection` reaches the nudge
    /// center without importing this bundle (a narrow closure threaded
    /// through `WorkspaceSidebar`). The sheet has already written the
    /// fix-task and confirmed the plan is running; this only wires the
    /// priority-worded nudge in. The gate rail (park at a merge gate) and
    /// the quiescence discipline live in the center's delivery path, not
    /// here. No ledger record → no live agent to type into → a no-op.
    /// The e2e `courseCorrect` command mirrors this block inline over the
    /// registered center (E2ECommands) — keep the two in lockstep.
    func enqueueCourseCorrectionNudge(
        plan: PlanDoc, summary: String, priority: CorrectionPriority
    ) {
        let path = docStore.relativePath(of: plan)
        guard let feature = docStore.ledger.recordForPlan(path)?.featureName else { return }
        nudgeCenter.enqueue(
            planPath: path,
            featureName: feature,
            prompt: PlanPrompts.courseCorrection(
                taskTitle: summary, priority: priority, planRelativePath: path),
            createdAt: Date())
        nudgeCenter.deliverPending()
    }

    /// The live plan-execution agent terminal for a plan path, via the
    /// ledger's feature name and that feature's workspace session — the
    /// tab the nudge center probes for quiescence and types into.
    private func agentTab(forPlan planPath: String) -> TabSession? {
        guard let feature = docStore.ledger.recordForPlan(planPath)?.featureName,
              let workspace = store.featureWorkspace(named: feature)
        else { return nil }
        return store.session(for: workspace).agentTabSession()
    }

    /// Launch a plan under the auto-run toggle: the same worktree+terminal
    /// path the queue's `runPlan` closure and the Run Plan sheet use, with the
    /// filename-derived branch and every linked repo. A launch failure
    /// leaves the plan `.ready` (the enacted record already stuck, so it
    /// won't retry) — but never silently: the error lands in
    /// `autoRunFailures` (rendered as a row caption) and fires
    /// `onAutoRunFailure` (a user notification in app context), because
    /// auto-run is by nature unattended.
    private func autoRunPlan(_ doc: PlanDoc) {
        let path = docStore.relativePath(of: doc)
        Task {
            do {
                try await planRunner.runPlan(
                    doc,
                    branchName: PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent),
                    repoNames: repoStore.repositories.map(\.name))
                autoRunFailures[path] = nil
            } catch {
                let message = error.localizedDescription
                autoRunFailures[path] = message
                onAutoRunFailure?(doc.title, message)
            }
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
            planQueue: planQueue,
            nudgeCenter: nudgeCenter
        )
        E2ERegistry.shared.registerFlowStore(projectID: project.id, flows: flows)
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
