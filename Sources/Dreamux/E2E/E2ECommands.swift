import AppKit
import Foundation

/// Executes one automation command on the main actor and returns the
/// JSON reply bytes (without the trailing newline — `E2EServer` adds
/// it). The request/response contract is documented exhaustively in
/// `Scripts/e2e/PROTOCOL.md`; keep the two in lockstep.
///
/// Every command goes through the same stores and code paths the real
/// UI uses (registry handles, `RunnerManager.startPlan`, `MergeFlow`,
/// `FeatureProvisioner`, `GitOperations`) so an e2e run exercises the
/// app's behavior, not a parallel implementation of it.
@MainActor
enum E2ECommands {
    /// User-facing failure that becomes `{"ok":false,"error":...}`.
    /// Thrown liberally by the parameter/store helpers so each command
    /// body reads as the happy path.
    private struct CommandError: Error {
        let message: String
    }

    static func handle(line: String) async -> (data: Data, isQuit: Bool) {
        var isQuit = false
        let payload: [String: Any]
        do {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let request = object as? [String: Any],
                let cmd = request["cmd"] as? String
            else {
                throw CommandError(message: "request must be a JSON object with a \"cmd\" string")
            }
            if cmd == "quit" { isQuit = true }
            payload = try await run(cmd: cmd, request: request)
        } catch let error as CommandError {
            payload = ["ok": false, "error": error.message]
        } catch {
            payload = ["ok": false, "error": error.localizedDescription]
        }
        return (encode(payload), isQuit)
    }

    private static func encode(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"error":"failed to encode response","ok":false}"#.utf8)
    }

    // MARK: - Dispatch

    private static func run(cmd: String, request: [String: Any]) async throws -> [String: Any] {
        switch cmd {
        case "ping":
            return ["ok": true]
        case "state":
            return stateReply()
        case "screenshot":
            return try screenshot(request: request)
        case "addLocalRepo":
            return try await addLocalRepo(request: request)
        case "createFeature":
            return try await createFeature(request: request)
        case "openMainWorkspace":
            return try openMainWorkspace()
        case "setSidebarMode":
            return try setSidebarMode(request: request)
        case "switchProject":
            return try switchProject(request: request)
        case "terminalText":
            return try terminalText(request: request)
        case "sendTerminalText":
            return try sendTerminalText(request: request)
        case "startFeature":
            return try startFeature(request: request, replacing: false)
        case "startFeatureReplacing":
            return try startFeature(request: request, replacing: true)
        case "stopFeature":
            return try stopFeature(request: request)
        case "isolateRunner":
            return try isolateRunner(request: request)
        case "detectRunConfig":
            return try detectRunConfig()
        case "reloadRunConfig":
            return try reloadRunConfig()
        case "mergeFeature":
            return try await mergeFeature(request: request)
        case "publishFeature":
            return try await publishFeature(request: request)
        case "featurePRStatus":
            return try await featurePRStatus(request: request)
        case "openMergeSheet":
            return try openMergeSheet(request: request)
        case "cleanupFeature":
            return try await cleanupFeature(request: request)
        case "openFile":
            return try openFile(request: request)
        case "setFileTree":
            return try setFileTree(request: request)
        case "listDocs":
            return handleListDocs()
        case "runPlan":
            return await handleRunPlan(request)
        case "courseCorrect":
            return try courseCorrect(request: request)
        case "enqueuePlan":
            return handleQueueMutation(request) { $0.enqueue($1) }
        case "startQueue":
            return handleQueueMutation(request) { queue, _ in queue.start() }
        case "stopQueue":
            return handleQueueMutation(request) { queue, _ in queue.stopQueue() }
        case "skipQueueGate":
            return handleQueueMutation(request) { queue, _ in queue.skipCurrent() }
        case "dequeuePlan":
            return handleQueueMutation(request) { $0.remove($1) }
        case "queueState":
            return handleQueueState()
        case "flowsState":
            return try flowsState(request: request)
        case "zoomFlow":
            return try zoomFlow(request: request)
        case "quit":
            return ["ok": true]
        default:
            throw CommandError(message: "unknown command: \(cmd)")
        }
    }

    // MARK: - State

    private static func stateReply() -> [String: Any] {
        let registry = E2ERegistry.shared
        var payload: [String: Any] = ["ok": true]

        payload["projects"] = (registry.projectStore?.projects ?? []).map { project in
            [
                "id": project.id.uuidString,
                "name": project.name,
                "path": project.rootPath.path,
            ]
        }

        guard
            let projectID = registry.activeProjectID,
            let handles = registry.handlesByProject[projectID]
        else {
            payload["activeProject"] = NSNull()
            payload["workspaces"] = [Any]()
            payload["runners"] = [Any]()
            payload["runTomlExists"] = false
            payload["sidebarMode"] = sidebarModeName(.workspace)
            return payload
        }

        if let project = handles.repoStore?.project {
            payload["activeProject"] = [
                "id": project.id.uuidString,
                "name": project.name,
                "path": project.rootPath.path,
            ]
        } else {
            payload["activeProject"] = NSNull()
        }

        if let store = handles.workspaceStore {
            payload["workspaces"] = store.workspaces.map { workspace in
                let session = store.session(for: workspace)
                return [
                    "name": workspace.name,
                    "linkedRepoIDs": workspace.linkedRepoIDs,
                    "isActive": workspace.id == store.activeID,
                    // In-app browser tabs (runner `open` URLs land here)
                    // — scenarios assert each worktree previews its own
                    // port.
                    "webTabs": session.webTabURLs.map(\.absoluteString),
                    "fileTabs": session.fileTabSummaries,
                    // Bonsplit tab bar summary, in tab-bar order — how a
                    // scenario asserts the pinned Overview tab exists and
                    // sits first (Task 7) without a screenshot.
                    "tabs": session.controller.allTabIds.compactMap { id -> [String: Any]? in
                        guard let tab = session.controller.tab(id) else { return nil }
                        return [
                            "title": tab.title,
                            "isOverview": session.isOverviewTab(id),
                        ]
                    },
                ] as [String: Any]
            }
        } else {
            payload["workspaces"] = [Any]()
        }

        if let runners = handles.runners {
            payload["runners"] = runners.runners.map { runner in
                var entry: [String: Any] = [
                    "name": runner.name,
                    "start": runner.start,
                ]
                if let cwd = runner.cwd { entry["cwd"] = cwd }
                if let port = runner.port { entry["port"] = port }
                if let portEnv = runner.portEnv { entry["portEnv"] = portEnv }
                entry["instances"] = runners.statusByInstance
                    .filter { $0.key.runnerName == runner.name }
                    .map { key, status -> [String: Any] in
                        var instance: [String: Any] = ["branch": key.branch]
                        switch status {
                        case .idle:
                            instance["status"] = "idle"
                        case .running(let pid):
                            instance["status"] = "running"
                            instance["pid"] = Int(pid)
                        case .exited(let code):
                            instance["status"] = "exited"
                            instance["exitCode"] = Int(code)
                        case .failed(let message):
                            instance["status"] = "failed"
                            instance["error"] = message
                        }
                        if let port = runners.assignedPorts[key] {
                            instance["assignedPort"] = port
                        }
                        return instance
                    }
                return entry
            }
        } else {
            payload["runners"] = [Any]()
        }

        if let docStore = handles.docStore, let workspaceStore = handles.workspaceStore {
            let featureExists: (String) -> Bool = { name in
                workspaceStore.featureNames.contains(name)
            }
            // Parked live nudges for a plan (Task 4): keyed by the plan's
            // project-relative path in the center, at most one per plan.
            let pendingNudges: (PlanDoc) -> Int = { plan in
                guard let center = handles.nudgeCenter else { return 0 }
                return center.pending[docStore.relativePath(of: plan)] == nil ? 0 : 1
            }
            // The flat `plans` dump stays for compatibility; the
            // `initiatives` grouping is the richer, structured view. Both
            // go through E2EStateDump so their shape is unit-tested.
            payload["plans"] = E2EStateDump.flatPlansPayload(
                docStore.plans,
                relativePath: { docStore.relativePath(of: $0) },
                status: { docStore.status(for: $0, featureExists: featureExists) },
                pendingNudges: pendingNudges
            )
            payload["initiatives"] = E2EStateDump.initiativesPayload(
                docStore.initiatives,
                relativePath: { docStore.relativePath(of: $0) },
                status: { docStore.status(for: $0, featureExists: featureExists) },
                pendingNudges: pendingNudges
            )
        } else {
            payload["plans"] = [Any]()
            payload["initiatives"] = [Any]()
        }

        if let queue = handles.planQueue {
            var queueEntry: [String: Any] = [
                "state": queue.state.rawValue,
                "entries": queue.entries,
            ]
            if let current = queue.currentPlanPath { queueEntry["current"] = current }
            payload["queue"] = queueEntry
        } else {
            payload["queue"] = NSNull()
        }

        payload["runTomlExists"] = handles.runConfig?.exists ?? false
        if let raw = handles.runConfig?.rawTOML {
            payload["runToml"] = raw
        }
        payload["sidebarMode"] = sidebarModeName(handles.bridge.currentSidebarMode)
        // Targets the manager would have opened (browser/app) — the
        // real open is suppressed in e2e mode, so this is the only
        // observable evidence that play surfaced the right URL.
        payload["openedTargets"] = handles.runners?.openedTargets ?? []
        return payload
    }

    private static func sidebarModeName(_ mode: SidebarMode) -> String {
        switch mode {
        case .workspace: return "workspace"
        case .run: return "run"
        case .signals: return "signals"
        case .flows: return "flows"
        case .library: return "library"
        case .app: return "app"
        }
    }

    // MARK: - Screenshot

    /// Renders the project window's content view into a PNG via
    /// `cacheDisplay` — pure in-process AppKit, no Screen Recording
    /// permission. GPU-backed surfaces (the embedded terminals) may
    /// come out blank; the screenshots document UI chrome, not
    /// terminal contents.
    private static func screenshot(request: [String: Any]) throws -> [String: Any] {
        let path = try string("path", in: request)
        guard path.hasPrefix("/") else {
            throw CommandError(message: "\"path\" must be an absolute path")
        }

        NSApp.activate()
        let window = try resolveWindow()
        window.makeKeyAndOrderFront(nil)

        // Sheets are separate child windows — capturing the parent's
        // content view would miss an open merge sheet entirely, and
        // documenting sheets is half the point of `openMergeSheet`.
        let target = window.attachedSheet ?? window
        guard let view = target.contentView else {
            throw CommandError(message: "window has no content view")
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CommandError(message: "couldn't create bitmap for window contents")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CommandError(message: "couldn't encode PNG")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            throw CommandError(message: "couldn't write \(path): \(error.localizedDescription)")
        }
        return [
            "ok": true,
            "path": path,
            "width": rep.pixelsWide,
            "height": rep.pixelsHigh,
        ]
    }

    /// The active project's window (matched by title), else the key
    /// window, else any visible non-panel window.
    private static func resolveWindow() throws -> NSWindow {
        let visible = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        if let projectID = E2ERegistry.shared.activeProjectID,
           let project = E2ERegistry.shared.handlesByProject[projectID]?.repoStore?.project,
           let match = visible.first(where: { $0.title.contains(project.name) }) {
            return match
        }
        if let key = NSApp.keyWindow { return key }
        if let first = visible.first { return first }
        throw CommandError(message: "no visible window to capture")
    }

    // MARK: - Repos & features

    private static func addLocalRepo(request: [String: Any]) async throws -> [String: Any] {
        let path = try string("path", in: request)
        let name = try string("name", in: request)
        let (_, _, repoStore) = try projectStores()
        let repo = try await repoStore.importLocal(
            path: URL(fileURLWithPath: path),
            name: name
        )
        return [
            "ok": true,
            "name": repo.name,
            "defaultBranch": repo.defaultBranch,
            "path": repo.rootURL.path,
        ]
    }

    private static func createFeature(request: [String: Any]) async throws -> [String: Any] {
        let name = try string("name", in: request)
        guard let repoIDs = request["repos"] as? [String], !repoIDs.isEmpty else {
            throw CommandError(message: "missing or empty \"repos\" array")
        }
        let (_, store, repoStore) = try projectStores()
        let selected = repoStore.repositories.filter { repoIDs.contains($0.name) }
        let missing = Set(repoIDs).subtracting(selected.map(\.name))
        guard missing.isEmpty else {
            throw CommandError(message: "unknown repo(s): \(missing.sorted().joined(separator: ", "))")
        }
        // Same code path as the sidebar's Add Feature sheet.
        let dir = try await FeatureProvisioner.provision(
            featureName: name,
            in: repoStore.project,
            across: selected
        )
        store.registerFeature(name: name, featureDirectory: dir, linkedRepoIDs: repoIDs)
        return ["ok": true, "featureDirectory": dir.path]
    }

    /// Materialize (find-or-create) and activate the reserved main
    /// workspace — the same `WorkspaceSidebar.openMainWorkspace()` the
    /// permanent rail row's click runs. Nothing else ever creates this
    /// workspace, so this is the only e2e path to Mode B's "main" Overview
    /// (Task 7): the sidebar has no button a driver can click.
    private static func openMainWorkspace() throws -> [String: Any] {
        let (handles, store, repoStore) = try projectStores()
        let workspace = store.mainWorkspace(
            name: repoStore.repositories.first?.defaultBranch ?? "main",
            workingDirectory: repoStore.project.rootPath.path,
            linkedRepoIDs: repoStore.repositories.map(\.name))
        handles.bridge.pendingSidebarMode = .workspace
        store.activate(workspace.id)
        return ["ok": true, "name": workspace.name]
    }

    // MARK: - Project switching & terminal readback

    /// Flip the project window to another project — the same binding
    /// write clicking it in the rail performs. The switch settles
    /// asynchronously; drivers poll `state` until `activeProject`
    /// matches.
    private static func switchProject(request: [String: Any]) throws -> [String: Any] {
        let name = try string("project", in: request)
        guard let projectStore = E2ERegistry.shared.projectStore else {
            throw CommandError(message: "project store not registered yet")
        }
        guard let project = projectStore.projects.first(where: { $0.name == name }) else {
            throw CommandError(message: "no project named \"\(name)\"")
        }
        guard let switcher = E2ERegistry.shared.projectSwitcher else {
            throw CommandError(message: "no project window registered yet")
        }
        switcher(project.id)
        return ["ok": true, "projectID": project.id.uuidString]
    }

    /// Viewport text of every terminal tab in a workspace — the scenario
    /// probe for "did this shell's contents survive?". The in-process
    /// `screenshot` can't capture GPU-composited terminals; this reads
    /// the grid straight from libghostty instead. Defaults to the active
    /// workspace when `feature` is omitted.
    private static func terminalText(request: [String: Any]) throws -> [String: Any] {
        let (_, store, _) = try projectStores()
        let target: Workspace
        if let name = request["feature"] as? String, !name.isEmpty {
            target = try workspace(named: name)
        } else if let active = store.activeWorkspace {
            target = active
        } else {
            throw CommandError(message: "no active workspace")
        }
        let texts = store.session(for: target).terminalTabSessions
            .compactMap { $0.readViewportText() }
        return ["ok": true, "feature": target.name, "texts": texts]
    }

    /// Type into a workspace's first terminal tab as if the user did;
    /// `submit` appends a carriage return. Fails until the shell has
    /// been quiescent for a beat — a booting zsh flushes its input
    /// queue and would silently eat the send — so drivers retry on
    /// error. Defaults to the active workspace when `feature` is
    /// omitted.
    private static func sendTerminalText(request: [String: Any]) throws -> [String: Any] {
        let text = try string("text", in: request)
        let (_, store, _) = try projectStores()
        let target: Workspace
        if let name = request["feature"] as? String, !name.isEmpty {
            target = try workspace(named: name)
        } else if let active = store.activeWorkspace {
            target = active
        } else {
            throw CommandError(message: "no active workspace")
        }
        guard let tab = store.session(for: target).terminalTabSessions.first else {
            throw CommandError(message: "workspace has no terminal tab")
        }
        guard tab.isShellQuiescent(for: 0.8) else {
            throw CommandError(message: "shell not quiescent yet — retry")
        }
        let submit = request["submit"] as? Bool ?? false
        tab.send(submit ? text + "\r" : text)
        return ["ok": true, "feature": target.name]
    }

    // MARK: - Sidebar & run pane

    private static func setSidebarMode(request: [String: Any]) throws -> [String: Any] {
        let mode = try string("mode", in: request)
        let (handles, store, _) = try projectStores()
        switch mode {
        case "workspace":
            if let name = request["workspace"] as? String {
                let workspace = try workspace(named: name)
                store.activate(workspace.id)
            }
            handles.bridge.pendingSidebarMode = .workspace
        case "signals":
            handles.bridge.pendingSidebarMode = .signals
        case "flows":
            handles.bridge.pendingSidebarMode = .flows
        case "library":
            handles.bridge.pendingSidebarMode = .library
        case "run":
            let workspace: Workspace?
            if let name = request["workspace"] as? String {
                workspace = try self.workspace(named: name)
            } else {
                workspace = store.activeWorkspace ?? store.workspaces.first
            }
            guard let workspace else {
                throw CommandError(message: "no workspace to scope the Run pane to")
            }
            store.activate(workspace.id)
            handles.bridge.pendingSidebarMode = .run(workspaceID: workspace.id)
        default:
            throw CommandError(message: "mode must be \"workspace\", \"run\", \"signals\", \"flows\", or \"library\"")
        }
        return ["ok": true]
    }

    /// Open a file as a Monaco editor tab in the active (or named)
    /// workspace — the same path the file tree's click uses.
    private static func openFile(request: [String: Any]) throws -> [String: Any] {
        let path = try string("path", in: request)
        guard path.hasPrefix("/") else {
            throw CommandError(message: "\"path\" must be an absolute path")
        }
        let (_, store, _) = try projectStores()
        let workspace: Workspace
        if let name = request["workspace"] as? String {
            workspace = try self.workspace(named: name)
        } else if let active = store.activeWorkspace ?? store.workspaces.first {
            workspace = active
        } else {
            throw CommandError(message: "no workspace to open the file in")
        }
        store.activate(workspace.id)
        store.session(for: workspace).openFileTab(at: URL(fileURLWithPath: path))
        return ["ok": true]
    }

    /// Toggle the right-side file explorer inspector.
    private static func setFileTree(request: [String: Any]) throws -> [String: Any] {
        guard let visible = request["visible"] as? Bool else {
            throw CommandError(message: "missing boolean \"visible\" parameter")
        }
        let (handles, _, _) = try projectStores()
        handles.bridge.pendingFileTreeVisible = visible
        return ["ok": true]
    }

    // MARK: - Docs & plans

    /// Fresh scan + one entry per doc: enough for scenarios to assert
    /// classification, pairing, status, and live checkbox progress.
    private static func handleListDocs() -> [String: Any] {
        guard let handles = try? activeHandles(),
              let docStore = handles.docStore,
              let workspaceStore = handles.workspaceStore else {
            return ["ok": false, "error": "no doc store registered"]
        }
        docStore.refresh()
        let featureExists: (String) -> Bool = { name in
            workspaceStore.featureNames.contains(name)
        }
        let entries = docStore.docs.map { doc -> [String: Any] in
            var entry: [String: Any] = [
                "path": docStore.relativePath(of: doc),
                "kind": doc.kind.rawValue,
                "title": doc.title,
                "checkedSteps": doc.checkedSteps,
                "totalSteps": doc.totalSteps,
            ]
            entry["status"] = docStore.status(for: doc, featureExists: featureExists).rawValue
            if let spec = doc.kind == .plan
                ? docStore.pairedSpec(for: doc).map({ docStore.relativePath(of: $0) })
                : nil {
                entry["spec"] = spec
            }
            return entry
        }
        return ["ok": true, "docs": entries]
    }

    /// Execute a plan headlessly through the same coordinator the
    /// sidebar uses. `branch` defaults to the filename derivation,
    /// `repos` to every repo in the project.
    private static func handleRunPlan(_ request: [String: Any]) async -> [String: Any] {
        guard let handles = try? activeHandles(),
              let docStore = handles.docStore,
              let planRunner = handles.planRunner,
              let repoStore = handles.repoStore else {
            return ["ok": false, "error": "no plan runner registered"]
        }
        guard let path = request["path"] as? String else {
            return ["ok": false, "error": "missing 'path'"]
        }
        docStore.refresh()
        guard let doc = docStore.docs.first(where: { docStore.relativePath(of: $0) == path })
        else { return ["ok": false, "error": "no doc at \(path)"] }

        let branch = (request["branch"] as? String)
            ?? PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent)
        let repos = (request["repos"] as? [String])
            ?? repoStore.repositories.map(\.name)
        do {
            let workspace = try await planRunner.runPlan(
                doc, branchName: branch, repoNames: repos)
            return ["ok": true, "feature": workspace.name]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// File a course correction against a plan, driving the SAME submit the
    /// course-correct sheet runs (context menus aren't harness-drivable, so
    /// this is the only way to exercise the flow end to end). It resolves
    /// the plan + anchor + priority through `CourseCorrectCommand` (the pure
    /// resolver the unit tests pin), then writes the tracked fix-task via
    /// `CourseCorrection.apply` and — only for a live plan — parks the
    /// priority-worded nudge on the project's `PlanNudgeCenter`, reusing
    /// `PlanPrompts.courseCorrection` and the center's own delivery path.
    /// No parallel writer or nudge engine: the same functions the sheet
    /// calls, in the same order.
    ///
    /// The nudge is parked only when the plan reads `running` or
    /// `awaitingReview` (the sheet's gate), via the center's own
    /// queue-gate-folding `status` closure; the gate rail and quiescence
    /// discipline then live in `deliverPending`, exactly as in production.
    /// Reply: `{"ok": true, "path": <relative>, "nudged": <bool>}`.
    private static func courseCorrect(request: [String: Any]) throws -> [String: Any] {
        let handles = try activeHandles()
        guard let docStore = handles.docStore else {
            throw CommandError(message: "no doc store registered")
        }
        docStore.refresh()

        let resolved: CourseCorrectCommand.Resolved
        do {
            resolved = try CourseCorrectCommand.resolve(
                plans: docStore.plans,
                relativePath: { docStore.relativePath(of: $0) },
                plan: request["plan"] as? String,
                task: request["task"] as? String,
                phase: request["phase"] as? String,
                text: request["text"] as? String,
                priority: request["priority"] as? String)
        } catch let error as CourseCorrectCommand.ResolveError {
            throw CommandError(message: error.message)
        }

        let summary = CourseCorrection.summaryLine(from: resolved.text)
        try CourseCorrection.apply(
            to: resolved.doc.fileURL, anchor: resolved.anchor,
            summary: summary, body: resolved.text, date: CourseCorrection.markerDate())

        let path = docStore.relativePath(of: resolved.doc)
        var nudged = false
        // Mirrors the sheet's submit path (PlansSpecsSection.submitCorrection
        // + ProjectSession.enqueueCourseCorrectionNudge) over the registered
        // center — the E2E handle deliberately exposes only PlanNudgeCenter,
        // so there is no shared seam to call. Keep the two in lockstep.
        if let center = handles.nudgeCenter,
           let status = center.status(path),
           status == .running || status == .awaitingReview,
           let feature = docStore.ledger.recordForPlan(path)?.featureName {
            center.enqueue(
                planPath: path,
                featureName: feature,
                prompt: PlanPrompts.courseCorrection(
                    taskTitle: summary, priority: resolved.priority, planRelativePath: path),
                createdAt: Date())
            center.deliverPending()
            nudged = true
        }
        return ["ok": true, "path": path, "nudged": nudged]
    }

    /// Shared plumbing for `enqueuePlan`/`startQueue`/`stopQueue`/
    /// `skipQueueGate`/`dequeuePlan`: resolve the registered queue, run the
    /// mutation (with `request["path"]`, or `""` when the command doesn't
    /// take one), and reply. Failures never throw — like
    /// `handleListDocs`/`handleRunPlan`, a missing queue is reported
    /// inline rather than via `CommandError`.
    private static func handleQueueMutation(
        _ request: [String: Any],
        _ mutate: (PlanQueueController, String) -> Void
    ) -> [String: Any] {
        guard let handles = try? activeHandles(), let queue = handles.planQueue else {
            return ["ok": false, "error": "no plan queue registered"]
        }
        mutate(queue, (request["path"] as? String) ?? "")
        return ["ok": true]
    }

    /// Snapshot of the plan queue's state machine. Runs a synchronous
    /// `tick()` first — the queue otherwise only advances off its 3s
    /// poller or a `runPlan` completion, and scenarios need deterministic
    /// transitions (write plan checkboxes → `queueState` → assert
    /// `atGate`) rather than a race against that timer.
    private static func handleQueueState() -> [String: Any] {
        guard let handles = try? activeHandles(), let queue = handles.planQueue else {
            return ["ok": false, "error": "no plan queue registered"]
        }
        queue.tick()   // deterministic: scenarios don't wait for the poller
        var payload: [String: Any] = [
            "ok": true,
            "state": queue.state.rawValue,
            "entries": queue.entries,
        ]
        if let current = queue.currentPlanPath { payload["current"] = current }
        if let error = queue.lastError { payload["lastError"] = error }
        return payload
    }

    /// Snapshot of the Flows pane's session lanes plus, since Task 3,
    /// its plan lanes — both built by `flowLanePayload` from `Flow`
    /// values, session lanes from live `FlowStore.flows` and plan lanes
    /// from `PlanFlowBuilder.lanes(from:)` fed by the same
    /// `PlanLaneAssembler` the Flows pane itself calls, so this can't
    /// drift from what's on screen.
    private static func flowsState(request: [String: Any]) throws -> [String: Any] {
        let (handles, store, _) = try projectStores()
        guard let flows = handles.flows else {
            throw CommandError(message: "flows store not registered")
        }
        let lanes = flows.flows.map(flowLanePayload)
        var planLanes: [[String: Any]] = []
        var boardRunning = flows.aggregates.runningCount
        var boardNeedsYou = flows.aggregates.needsYouCount
        if let docStore = handles.docStore, let queue = handles.planQueue {
            let planFlows = PlanFlowBuilder.lanes(
                from: PlanLaneAssembler.inputs(docStore: docStore, queue: queue, store: store))
            planLanes = planFlows.map(flowLanePayload)
            let board = FlowsBoard.compose(planLanes: planFlows, sessionLanes: flows.flows)
            boardRunning = board.runningCount
            boardNeedsYou = board.needsYouCount
        }
        return [
            "ok": true,
            "lanes": lanes,
            "planLanes": planLanes,
            "running": flows.aggregates.runningCount,
            "needsYou": flows.aggregates.needsYouCount,
            "boardRunning": boardRunning,
            "boardNeedsYou": boardNeedsYou,
        ]
    }

    /// Shared `Flow` → wire-dict shape for `flowsState`'s `lanes` and
    /// `planLanes` arrays. `edges` mirrors `nodes`' omit-if-nil style:
    /// `label`/`iterations` are only present when the edge carries them
    /// (loop edges always do; others never do).
    private static func flowLanePayload(_ flow: Flow) -> [String: Any] {
        var lane: [String: Any] = [
            "id": flow.id, "title": flow.title,
            "kind": flow.kind.rawValue, "status": flow.status.rawValue,
            "nodes": flow.nodes.map { node -> [String: Any] in
                var wire: [String: Any] = ["id": node.id, "label": node.label, "status": node.status.rawValue]
                if let lastActivity = node.lastActivity { wire["lastActivity"] = lastActivity }
                return wire
            },
            "edges": flow.edges.map { edge -> [String: Any] in
                var wire: [String: Any] = ["from": edge.from, "to": edge.to, "kind": edge.kind.rawValue]
                if let label = edge.label { wire["label"] = label }
                if let iterations = edge.iterations { wire["iterations"] = iterations }
                return wire
            },
        ]
        if let detail = flow.detail { lane["detail"] = detail }
        if flow.detailUnavailable { lane["detailUnavailable"] = true }
        if let sessionCwd = flow.sessionCwd { lane["sessionCwd"] = sessionCwd }
        return lane
    }

    /// Zoom the Flows pane into a lane (or clear the zoom with a `null`/
    /// absent `laneID`) — parks the request on the bridge for
    /// `ContentView` to adopt, same consume-and-clear shape as
    /// `setSidebarMode`. See `E2EBridge.pendingFlowsZoomLaneID` for why
    /// "clear" is the empty-string sentinel rather than `nil` itself.
    private static func zoomFlow(request: [String: Any]) throws -> [String: Any] {
        let (handles, _, _) = try projectStores()
        handles.bridge.pendingFlowsZoomLaneID = (request["laneID"] as? String) ?? ""
        return ["ok": true]
    }

    /// Play semantics — worktree-centric, never a question. Flexible
    /// runners start alongside other worktrees' instances; fixed-port
    /// runners switch, and the response's `displaced` array reports
    /// which worktrees lost their instance (what the sidebar's switch
    /// notice renders). `replacing` is accepted for protocol
    /// compatibility but no longer changes behavior.
    private static func startFeature(
        request: [String: Any],
        replacing: Bool
    ) throws -> [String: Any] {
        _ = replacing
        let workspace = try workspace(named: try string("name", in: request))
        let (runners, _, _) = try runStores()
        switch runners.startPlan(for: workspace) {
        case .openRunPane:
            return ["ok": true, "started": false, "reason": "no runners configured"]
        case .start(let toStart, let displacing):
            runners.executeStart(toStart)
            return [
                "ok": true,
                "started": true,
                "runners": toStart.map(\.name),
                "displaced": displacing.map {
                    ["runner": $0.runner.name, "fromBranch": $0.fromBranch]
                },
            ]
        }
    }

    private static func stopFeature(request: [String: Any]) throws -> [String: Any] {
        let workspace = try workspace(named: try string("name", in: request))
        let (runners, _, _) = try runStores()
        var stopped: [String] = []
        // Mirrors the sidebar's stopAllRunning: per-instance, so the
        // same runner stays alive on other branches.
        for runner in runners.runners
        where runners.status(for: runner, on: workspace.name)?.isRunning == true {
            runners.stop(runner, on: workspace.name)
            stopped.append(runner.name)
        }
        return ["ok": true, "stopped": stopped]
    }

    private static func isolateRunner(request: [String: Any]) throws -> [String: Any] {
        let name = try string("name", in: request)
        let (handles, store, _) = try projectStores()
        let (runners, _, _) = try runStores()
        guard let runner = runners.runners.first(where: { $0.name == name }) else {
            throw CommandError(message: "no runner named \"\(name)\" in run.toml")
        }
        // Mirror the conflict alert's "Isolate with Claude" button:
        // park the runner on the manager's existing pendingIsolation
        // channel, then surface the Run pane (scoped to the worktree
        // the runner targets when a matching workspace exists).
        runners.pendingIsolation = runner
        let target = store.workspaces.first { $0.name == runners.currentBranch(for: runner) }
            ?? store.activeWorkspace
            ?? store.workspaces.first
        if let target {
            store.activate(target.id)
            handles.bridge.pendingSidebarMode = .run(workspaceID: target.id)
        } else {
            // No workspaces at all — an unmatched ID gives RunSetupView
            // a nil scope, i.e. the project-wide Run pane.
            handles.bridge.pendingSidebarMode = .run(workspaceID: UUID())
        }
        return ["ok": true]
    }

    private static func detectRunConfig() throws -> [String: Any] {
        let (handles, store, _) = try projectStores()
        handles.bridge.pendingDetect = true
        let target = store.activeWorkspace ?? store.workspaces.first
        handles.bridge.pendingSidebarMode = .run(workspaceID: target?.id ?? UUID())
        return ["ok": true]
    }

    private static func reloadRunConfig() throws -> [String: Any] {
        let (runners, runConfig, _) = try runStores()
        runConfig.reload()
        runners.reload(from: runConfig.rawTOML)
        return [
            "ok": true,
            "runTomlExists": runConfig.exists,
            "runners": runners.runners.map(\.name),
        ]
    }

    // MARK: - Merge, publish & cleanup

    /// Shared setup of the single-repo merge/publish/status commands:
    /// resolve the workspace + repo pair, then build a fresh `MergeFlow`
    /// and run the same pre-check the sheet runs on appear — which also
    /// resumes any existing PR's state from gh, exactly like a sheet
    /// re-open does.
    private static func singleRepoFlow(
        request: [String: Any]
    ) async throws -> (repo: Repository, flow: MergeFlow) {
        let workspace = try workspace(named: try string("name", in: request))
        let repoName = try string("repo", in: request)
        let (_, _, repoStore) = try projectStores()
        guard let repo = repoStore.repositories.first(where: { $0.name == repoName }) else {
            throw CommandError(message: "no repo named \"\(repoName)\" in this project")
        }
        guard workspace.linkedRepoIDs.contains(repo.name) else {
            throw CommandError(message: "feature \"\(workspace.name)\" is not linked to repo \"\(repo.name)\"")
        }
        let flow = MergeFlow(workspace: workspace, repos: [repo], project: repoStore.project)
        await flow.initializeStates()
        return (repo, flow)
    }

    /// Wire name for a `MergeRepoState`, matching PROTOCOL.md's
    /// vocabulary. Associated values (conflict paths, failure messages,
    /// PR URLs) travel in their own response keys, never in the name.
    private static func stateName(_ state: MergeRepoState) -> String {
        switch state {
        case .pending: return "pending"
        case .working: return "working"
        case .upToDate: return "upToDate"
        case .featureDirty: return "featureDirty"
        case .merged: return "merged"
        case .conflicted: return "conflicted"
        case .failed: return "failed"
        case .cleaningUp: return "cleaningUp"
        case .cleanedUp: return "cleanedUp"
        case .pushing: return "pushing"
        case .prOpen: return "prOpen"
        case .prMerged: return "prMerged"
        }
    }

    /// Drives the merge sheet's own orchestration (`MergeFlow`) for a
    /// single repo, headless: the same pre-check the sheet runs on
    /// appear, then its "Commit & Merge" path when the feature worktree
    /// is dirty, or its plain Merge otherwise. Only the sheet's chrome
    /// is skipped — a regression in the flow's sequencing fails this
    /// command, not just the unit suite.
    private static func mergeFeature(request: [String: Any]) async throws -> [String: Any] {
        let (repo, flow) = try await singleRepoFlow(request: request)
        switch flow.state(for: repo) {
        case .cleanedUp:
            // The pre-check maps a missing worktree to "nothing left to
            // do"; for the automation API that's an error, not a no-op.
            throw CommandError(message: "feature worktree missing at \(flow.featureWorktreeURL(for: repo).path)")
        case .featureDirty:
            await flow.commitAndMerge(repo)
        case .pending:
            await flow.runMerge(for: repo)
        default:
            break
        }

        switch flow.state(for: repo) {
        case .upToDate:
            return ["ok": true, "outcome": "alreadyUpToDate", "paths": [String]()]
        case .merged:
            return ["ok": true, "outcome": "merged", "paths": [String]()]
        case .conflicted(let paths):
            return ["ok": true, "outcome": "conflicted", "paths": paths]
        case .featureDirty:
            // commitAndMerge bounced back to dirty — the commit failed
            // and the flow parked the reason in commitErrors.
            throw CommandError(message: flow.commitErrors[repo.name] ?? "commit failed")
        case .failed(let message):
            throw CommandError(message: message)
        case let other:
            throw CommandError(message: "unexpected merge state: \(other)")
        }
    }

    /// Drives the merge sheet's "Create PR" path (`MergeFlow.publish`,
    /// or `commitAndPublish` when the feature worktree is dirty) for a
    /// single repo, headless. Mirrors the sheet exactly: the pre-check's
    /// `publishAvailability` verdict gates the operation the same way it
    /// decides whether the button exists at all, and a PR the pre-check
    /// resumed from gh is reported rather than re-created — re-running
    /// the command is as idempotent as re-clicking the button.
    private static func publishFeature(request: [String: Any]) async throws -> [String: Any] {
        let (repo, flow) = try await singleRepoFlow(request: request)

        // The sheet hides (no remote) or disables (no gh) the button on
        // these verdicts; headless, they're failures the driver must see.
        switch flow.publishAvailability[repo.name] {
        case .noRemote:
            throw CommandError(message: "repo \"\(repo.name)\" has no origin remote to push to")
        case .ghMissing:
            throw CommandError(message: "no gh CLI found (install gh, or point DREAMUX_GH_BIN at one)")
        case .available, nil:
            break
        }

        switch flow.state(for: repo) {
        case .cleanedUp:
            throw CommandError(message: "feature worktree missing at \(flow.featureWorktreeURL(for: repo).path)")
        case .upToDate:
            throw CommandError(message: "nothing to publish: \"\(flow.workspace.name)\" has no commits ahead of \(repo.defaultBranch)")
        case .featureDirty:
            await flow.commitAndPublish(repo)
        case .pending:
            await flow.publish(repo)
        default:
            // .prOpen / .prMerged resumed by the pre-check: nothing to
            // push, fall through and report where the PR already stands.
            break
        }

        switch flow.state(for: repo) {
        case .prOpen(let url):
            return ["ok": true, "state": "prOpen", "url": url]
        case .prMerged(let url):
            return ["ok": true, "state": "prMerged", "url": url]
        case .featureDirty:
            // commitAndPublish bounced back to dirty — the commit failed
            // and the flow parked the reason in commitErrors.
            throw CommandError(message: flow.commitErrors[repo.name] ?? "commit failed")
        case .failed(let message):
            throw CommandError(message: message)
        case let other:
            throw CommandError(message: "unexpected publish state: \(stateName(other))")
        }
    }

    /// Fresh `MergeFlow` + the sheet's on-appear pre-check, reported
    /// verbatim. Because `initializeStates` re-asks gh for the branch's
    /// PR on every call, this is how a driver observes a remote-side PR
    /// merge promptly instead of waiting out the throttled (~10s) poll
    /// loop a sheet would be running. `url` is present only when the
    /// state refers to a PR (`prOpen`/`prMerged`).
    private static func featurePRStatus(request: [String: Any]) async throws -> [String: Any] {
        let (repo, flow) = try await singleRepoFlow(request: request)
        let state = flow.state(for: repo)
        var payload: [String: Any] = ["ok": true, "state": stateName(state)]
        if let url = state.prURL {
            payload["url"] = url
        }
        return payload
    }

    private static func openMergeSheet(request: [String: Any]) throws -> [String: Any] {
        let workspace = try workspace(named: try string("name", in: request))
        let (handles, store, _) = try projectStores()
        store.activate(workspace.id)
        handles.bridge.pendingMergeWorkspaceID = workspace.id
        return ["ok": true]
    }

    /// Drives the merge sheet's own per-repo cleanup
    /// (`MergeFlow.cleanup`) across every linked repo, with the
    /// callbacks wired exactly as `WorkspaceSidebar` wires them: each
    /// cleaned-up repo stops the runners executing on the doomed
    /// worktree and clears their branch overrides, and once every repo
    /// is cleaned up the workspace leaves the sidebar and the
    /// `features/<name>/` aggregation dir is removed.
    private static func cleanupFeature(request: [String: Any]) async throws -> [String: Any] {
        let workspace = try workspace(named: try string("name", in: request))
        let (_, store, repoStore) = try projectStores()
        let project = repoStore.project
        let linkedRepos = repoStore.repositories.filter {
            workspace.linkedRepoIDs.contains($0.name)
        }
        let runners = try? runStores().runners

        // The sidebar's finalize step, minus its runloop hop (there is
        // no sheet dismissal to avoid fighting with here).
        let finalize = {
            store.remove(workspace)
            try? FileManager.default.removeItem(
                at: FeatureProvisioner.featureDirectory(in: project, name: workspace.name)
            )
        }

        let flow = MergeFlow(
            workspace: workspace,
            repos: linkedRepos,
            project: project,
            onRepoCleanedUp: { repo in
                // WorkspaceSidebar.stopRunnersTiedToFeature: stop the
                // instance on the removed worktree, and clear the
                // override even when idle so the next Start doesn't
                // point at a deleted folder.
                guard let runners else { return }
                for runner in runners.runners
                where runners.repoName(for: runner) == repo.name {
                    if runners.status(for: runner, on: workspace.name)?.isRunning == true {
                        runners.stop(runner, on: workspace.name)
                    }
                    runners.setActiveBranch(nil, for: runner)
                }
            },
            onAllCleanedUp: finalize
        )

        // The sheet always runs its pre-check before any row can offer
        // Cleanup; do the same so a PR that merged remotely resumes
        // `.prMerged` (via gh) and `MergeFlow.cleanup` fast-forwards
        // local main from origin before the worktree goes away. Locally
        // merged repos land on `.upToDate`/`.cleanedUp` and clean up
        // exactly as before.
        await flow.initializeStates()

        // "Click Cleanup on every row." The flow is idempotent for
        // repos whose worktree is already gone, and fires
        // onAllCleanedUp after the last one — same as the sheet.
        for repo in linkedRepos {
            await flow.cleanup(repo)
        }

        // A feature with no linked repos never gets a merge sheet (the
        // sidebar hides Merge…), so onAllCleanedUp can't fire; fall
        // back to the finalize step directly so the command still
        // removes the workspace.
        if linkedRepos.isEmpty {
            finalize()
        }
        return ["ok": true]
    }

    // MARK: - Helpers

    private static func string(_ key: String, in request: [String: Any]) throws -> String {
        guard let value = request[key] as? String, !value.isEmpty else {
            throw CommandError(message: "missing or empty \"\(key)\" parameter")
        }
        return value
    }

    private static func activeHandles() throws -> E2EProjectHandles {
        let registry = E2ERegistry.shared
        guard
            let id = registry.activeProjectID ?? registry.handlesByProject.keys.first,
            let handles = registry.handlesByProject[id]
        else {
            throw CommandError(message: "no project window registered yet")
        }
        return handles
    }

    private static func projectStores() throws
    -> (handles: E2EProjectHandles, store: WorkspaceStore, repoStore: RepoStore) {
        let handles = try activeHandles()
        guard let store = handles.workspaceStore, let repoStore = handles.repoStore else {
            throw CommandError(message: "project window stores not registered yet")
        }
        return (handles, store, repoStore)
    }

    private static func runStores() throws
    -> (runners: RunnerManager, runConfig: RunConfigStore, signals: SignalStore) {
        let handles = try activeHandles()
        guard
            let runners = handles.runners,
            let runConfig = handles.runConfig,
            let signals = handles.signals
        else {
            throw CommandError(message: "run stores not registered yet (Features section not on screen)")
        }
        return (runners, runConfig, signals)
    }

    private static func workspace(named name: String) throws -> Workspace {
        let (_, store, _) = try projectStores()
        guard let workspace = store.workspaces.first(where: { $0.name == name }) else {
            throw CommandError(message: "no workspace named \"\(name)\"")
        }
        return workspace
    }
}
