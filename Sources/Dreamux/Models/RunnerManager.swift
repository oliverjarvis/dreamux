import AppKit
import Foundation
import Observation

/// One `[[runners]]` entry parsed from `run.toml`. We use a hand-rolled
/// parser (see `ParsedRunner.parseAll`) so we don't have to add a TOML
/// dependency for the very constrained shape we ourselves write.
struct ParsedRunner: Identifiable, Hashable, Sendable {
    /// Same as `name` — fine to reuse since the TOML format forbids two
    /// runners with the same name.
    var id: String { name }
    var name: String
    var cwd: String?
    var start: String
    var stop: String?
    var port: Int?
    var portEnv: String?
    /// What to surface once the runner is up — `{port}` is replaced
    /// with the instance's effective port (the per-worktree assigned
    /// one when isolated, else `port`). A URL opens in the default
    /// browser/handler; anything else runs as a shell command. Play
    /// triggers it automatically after the port starts answering.
    var open: String?
}

extension ParsedRunner {
    /// Pull `[[runners]]` blocks out of a TOML body. This isn't a real
    /// parser — it understands one shape only:
    ///
    ///   [[runners]]
    ///   name = "frontend"
    ///   cwd = "repos/frontend/main"
    ///   start = "npm run dev"
    ///   stop = "pkill -f 'node.*dev'"
    ///   port = 3000
    ///   port_env = "FRONTEND_PORT"
    ///
    /// Quoted strings keep their contents verbatim (no escape handling
    /// beyond stripping the outer quotes). Lines we don't recognise are
    /// skipped silently — keeps Claude's occasional stray comments from
    /// blowing up the whole load.
    static func parseAll(_ toml: String) -> [ParsedRunner] {
        var results: [ParsedRunner] = []
        var pending: PendingRunner?

        for rawLine in toml.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[runners]]" {
                if let p = pending, let materialised = p.materialise() {
                    results.append(materialised)
                }
                pending = PendingRunner()
                continue
            }
            guard let p = pending,
                  let eq = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if let strippedString = Self.stripQuotes(value) {
                value = strippedString
            }

            switch key {
            case "name": p.name = value
            case "cwd": p.cwd = value
            case "start": p.start = value
            case "stop": p.stop = value
            case "port": p.port = Int(value)
            case "port_env": p.portEnv = value
            case "open": p.open = value
            default: break
            }
        }
        if let p = pending, let materialised = p.materialise() {
            results.append(materialised)
        }
        // Duplicate names would collide on `id` (doubling rows in any
        // ForEach and double-starting on play) — keep each name's last
        // definition, in first-seen order, matching the parser's
        // last-wins behavior for duplicate keys within a block.
        var byName: [String: ParsedRunner] = [:]
        var order: [String] = []
        for runner in results {
            if byName[runner.name] == nil { order.append(runner.name) }
            byName[runner.name] = runner
        }
        return order.compactMap { byName[$0] }
    }

    private static func stripQuotes(_ value: String) -> String? {
        guard value.count >= 2 else { return nil }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return nil
    }
}

private final class PendingRunner {
    var name: String?
    var cwd: String?
    var start: String?
    var stop: String?
    var port: Int?
    var portEnv: String?
    var open: String?

    func materialise() -> ParsedRunner? {
        guard let name, !name.isEmpty,
              let start, !start.isEmpty else { return nil }
        return ParsedRunner(
            name: name,
            cwd: cwd,
            start: start,
            stop: stop,
            port: port,
            portEnv: portEnv,
            open: open
        )
    }
}

// MARK: - Runtime status

enum RunnerStatus: Hashable, Sendable {
    case idle
    case running(pid: Int32)
    case exited(code: Int32)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Identifies a specific running (or recently-run) instance of a runner.
/// A single `[[runners]]` definition can have multiple concurrent
/// instances when it's port-isolated — one per branch worktree.
struct RunnerInstanceKey: Hashable, Sendable {
    let runnerName: String
    let branch: String
}

/// What pressing Play on a workspace should do. Computed by
/// `RunnerManager.startPlan(for:)` so the decision is testable without
/// a live view hierarchy; the sidebar (and the e2e automation server)
/// renders each case — the alert UI itself stays in the view layer.
enum StartPlan: Equatable {
    /// No runners are configured at all — surface the Run pane so the
    /// user can have Claude detect a run config first.
    case openRunPane
    /// Start via `executeStart(_:)`. Play means "run THIS worktree":
    /// runners with flexible ports (port_env, or no port) come up
    /// alongside whatever else is live; fixed-port runners switch —
    /// their instance on another worktree is stopped as part of
    /// starting. `displacing` lists those switches so the caller can
    /// tell the user what happened and offer the "run both" upgrade
    /// (port isolation) instead of blocking the start on a dialog.
    case start(toStart: [ParsedRunner], displacing: [Displacement])
}

/// One fixed-port switch a `StartPlan` will perform: `runner`'s live
/// instance on `fromBranch` stops so the requested worktree can have
/// the port.
struct Displacement: Equatable {
    let runner: ParsedRunner
    let fromBranch: String
}

/// Owns subprocesses spawned from `[[runners]]` entries in `run.toml`.
/// State is keyed per (runner, branch) so the same runner can be alive on
/// several worktrees at once when port_env isolation makes that safe.
@MainActor
@Observable
final class RunnerManager {
    let project: Project
    private let signals: SignalStore

    private(set) var runners: [ParsedRunner] = []
    /// All instance-level state lives in these maps. The "scoped"
    /// queries below filter by branch when callers need a per-worktree
    /// answer.
    private(set) var statusByInstance: [RunnerInstanceKey: RunnerStatus] = [:]
    private var processes: [RunnerInstanceKey: Process] = [:]
    private var stdoutBuffers: [RunnerInstanceKey: String] = [:]
    private var stderrBuffers: [RunnerInstanceKey: String] = [:]
    private var lastStartedAt: [RunnerInstanceKey: Date] = [:]
    private(set) var lastRunDuration: [RunnerInstanceKey: TimeInterval] = [:]
    /// Port we assigned to a given instance via its `port_env`. Tracked
    /// so the next instance picks the next free offset and so the row
    /// UI can later surface "running on port 5174" if we want it.
    private(set) var assignedPorts: [RunnerInstanceKey: Int] = [:]
    /// In-flight wait-until-listening tasks for runners with an `open`
    /// target. Cancelled when the instance exits or is stopped so a
    /// crashed server never pops a dead browser tab.
    private var openTasks: [RunnerInstanceKey: Task<Void, Never>] = [:]
    /// Every open target this manager fired, in order — the e2e state
    /// dump asserts on it, and it makes "did the browser open and to
    /// where" debuggable after the fact.
    private(set) var openedTargets: [String] = []
    /// Test/e2e hook: when set, replaces actually opening the target
    /// (NSWorkspace / shell). `openedTargets` records either way.
    var openOverride: ((String) -> Void)?
    /// In-app routing for URL targets, wired up by the project window:
    /// given (url, branch, title), open it as a browser tab inside the
    /// branch's workspace and return true — or return false to fall
    /// back to the external browser (e.g. no workspace matches the
    /// branch). Shell-command targets never come through here.
    var openURLInApp: ((URL, String, String) -> Bool)?

    /// Heuristic threshold: anything dying in under three seconds with a
    /// non-zero exit looks broken rather than "user stopped it" or "long
    /// service finished its work."
    private let fastFailThreshold: TimeInterval = 3.0

    /// Status for a runner on a specific branch. `nil` when no instance
    /// has ever been started there.
    func status(for runner: ParsedRunner, on branch: String) -> RunnerStatus? {
        statusByInstance[RunnerInstanceKey(runnerName: runner.name, branch: branch)]
    }

    /// True when the named instance exited non-zero within the
    /// fast-fail window. Drives the "Diagnose with Claude" affordance.
    func didFastFail(_ runner: ParsedRunner, on branch: String) -> Bool {
        let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
        guard case .exited(let code) = statusByInstance[key] ?? .idle,
              code != 0 else { return false }
        guard let duration = lastRunDuration[key] else { return false }
        return duration < fastFailThreshold
    }

    /// True when a runner is safe to run side-by-side with another
    /// instance of itself: either it has no port at all, or it has a
    /// `port_env` so we can hand each instance a unique port.
    func canRunConcurrently(_ runner: ParsedRunner) -> Bool {
        if runner.port == nil { return true }
        return !(runner.portEnv ?? "").isEmpty
    }

    /// Per-runner branch-folder override. `nil` (i.e. key missing) means
    /// "use whatever was originally in run.toml's cwd". Switching while a
    /// runner is running just records the choice; it takes effect on the
    /// next Start.
    private(set) var activeBranches: [String: String] = [:]

    /// A runner the sidebar's "Isolate with Claude" alert wants the
    /// Run pane to kick the isolate flow on the moment it appears. The
    /// pane consumes (and clears) this when it loads so the user
    /// doesn't have to manually navigate and click Isolate.
    var pendingIsolation: ParsedRunner?

    /// Fires on every distinct status transition (same-value writes are
    /// swallowed) — the project session turns these into service.health
    /// signals. nil keeps tests and headless managers silent.
    var statusChanged: ((_ runnerName: String, _ branch: String, _ previous: RunnerStatus?, _ new: RunnerStatus) -> Void)?

    /// Single write path for `statusByInstance` so transitions can't
    /// slip past the hook. Same value → no event (health must not spam).
    private func setStatus(_ status: RunnerStatus, for key: RunnerInstanceKey) {
        let previous = statusByInstance[key]
        guard previous != status else { return }
        statusByInstance[key] = status
        statusChanged?(key.runnerName, key.branch, previous, status)
    }

    init(project: Project, signals: SignalStore) {
        self.project = project
        self.signals = signals
        QuitGuard.shared.register(self)
    }

    func reload(from toml: String?) {
        guard let toml else {
            runners = []
            return
        }
        runners = ParsedRunner.parseAll(toml)
        // Drop status for runners that no longer exist (runner removed
        // from run.toml). Per-branch entries for surviving runners stay.
        let names = Set(runners.map(\.name))
        statusByInstance = statusByInstance.filter { names.contains($0.key.runnerName) }
    }

    /// Wrap a start command so terminating the spawned shell reliably
    /// kills the command's entire process tree.
    ///
    /// Foundation's `Process` spawns the `/bin/sh -lc` child into its
    /// own process group and `terminate()` signals that group (verified
    /// empirically on macOS 15) — so straightforward trees die without
    /// help. The wrapper makes that guarantee explicit rather than
    /// relying on undocumented behavior, and covers the cases group
    /// inheritance alone doesn't: commands that put themselves in a new
    /// group (anything calling `setpgid`/job control of its own) stay
    /// reachable through the shell's forwarding trap.
    ///
    /// `set -m` runs the background brace-group in its own process
    /// group (pgid == `$!`); the TERM/INT trap forwards the signal to
    /// that whole group. The newline before `}` keeps a trailing
    /// `# comment` in the user's command from swallowing the brace.
    /// The shell exits with the job's status (143 after a forwarded
    /// SIGTERM), so the termination handler and fast-fail detection see
    /// the same shape as a direct kill.
    static func processGroupWrapper(_ command: String) -> String {
        """
        set -m; { \(command)
        } & DREAMUX_PID=$!; trap 'kill -TERM -$DREAMUX_PID 2>/dev/null' TERM INT; wait $DREAMUX_PID
        """
    }

    func start(_ runner: ParsedRunner) {
        let branch = currentBranch(for: runner) ?? "(default)"
        let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
        if statusByInstance[key]?.isRunning == true { return }
        let sourceTag = signalSource(runnerName: runner.name, branch: branch)

        // Allocate a unique port if this runner is isolated, or refuse
        // up-front if it's port-fixed and the port is already taken.
        // The bind probe sees the kernel's truth, so this also catches
        // servers Dreamux never started — one running in a terminal
        // tab, another runner configured with the same port, anything.
        var injectedEnv: [String: String] = [:]
        if let envName = runner.portEnv, !envName.isEmpty,
           let basePort = runner.port {
            let port = nextFreePort(basePort: basePort)
            injectedEnv[envName] = String(port)
            assignedPorts[key] = port
        } else if let fixedPort = runner.port, Self.isPortInUse(fixedPort) {
            // Spawning would either crash the server (EADDRINUSE) or —
            // worse — let port-hopping dev servers silently come up
            // somewhere else while the UI claims \(fixedPort). Fail
            // visibly instead and point at the fix.
            setStatus(
                .failed(
                    message: "Port \(fixedPort) is already in use. Stop whatever is using it, or Isolate this runner so each worktree gets its own port."
                ),
                for: key
            )
            signals.append(
                source: sourceTag,
                line: "✗ not started: port \(fixedPort) is already in use"
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", Self.processGroupWrapper(runner.start)]
        process.currentDirectoryURL = resolveCwd(for: runner)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in injectedEnv { env[k] = v }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Capture immutable copies for the async readers — once the
        // process starts these closures run off-actor. (sourceTag was
        // resolved at the top of start, before any state changed.)
        let capturedKey = key
        let signals = self.signals

        stdoutBuffers[key] = ""
        stderrBuffers[key] = ""

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = self.stdoutBuffers[capturedKey] ?? ""
                signals.appendChunk(source: sourceTag, chunk, buffer: &buf, stream: "stdout")
                self.stdoutBuffers[capturedKey] = buf
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buf = self.stderrBuffers[capturedKey] ?? ""
                signals.appendChunk(source: sourceTag, chunk, buffer: &buf, stream: "stderr")
                self.stderrBuffers[capturedKey] = buf
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let startedAt = self.lastStartedAt[capturedKey] {
                    self.lastRunDuration[capturedKey] = Date().timeIntervalSince(startedAt)
                }
                self.setStatus(.exited(code: proc.terminationStatus), for: capturedKey)
                self.processes.removeValue(forKey: capturedKey)
                self.assignedPorts.removeValue(forKey: capturedKey)
                self.openTasks.removeValue(forKey: capturedKey)?.cancel()
                if let tail = self.stdoutBuffers[capturedKey], !tail.isEmpty {
                    signals.append(source: sourceTag, line: tail)
                }
                if let tail = self.stderrBuffers[capturedKey], !tail.isEmpty {
                    signals.append(source: sourceTag, line: tail)
                }
                self.stdoutBuffers[capturedKey] = nil
                self.stderrBuffers[capturedKey] = nil
            }
        }

        do {
            try process.run()
            processes[key] = process
            setStatus(.running(pid: process.processIdentifier), for: key)
            lastStartedAt[key] = Date()
            lastRunDuration[key] = nil
            let portNote = injectedEnv.isEmpty
                ? ""
                : " (" + injectedEnv.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + ")"
            signals.append(source: sourceTag, line: "› starting: \(runner.start)\(portNote)")
            scheduleAutoOpen(for: runner, key: key, sourceTag: sourceTag)
        } catch {
            setStatus(.failed(message: error.localizedDescription), for: key)
            assignedPorts.removeValue(forKey: key)
            signals.append(
                source: sourceTag,
                line: "✗ failed to start: \(error.localizedDescription)"
            )
        }
    }

    /// Stop every live instance of this runner across every branch,
    /// then start fresh on the current branch. Used when the runner
    /// can't run concurrently (no `port_env`) and the user pressed
    /// play on a different worktree.
    ///
    /// We SIGTERM directly rather than running the runner's `stop`
    /// command — typical patterns there are `pkill -f 'turbo dev'`,
    /// which would also kill the replacement we spawn a moment later.
    ///
    /// For a single row's action (the header popover's per-row
    /// Restart), use `restart(_:on:)` instead — this one is only
    /// correct for the fixed-port switch path, where killing every
    /// other branch's instance is the point.
    func restart(_ runner: ParsedRunner) async {
        let liveKeys = processes.keys.filter { $0.runnerName == runner.name }
        for key in liveKeys {
            if let process = processes[key], process.isRunning {
                process.terminate()
            }
        }
        if !liveKeys.isEmpty {
            let deadline = Date().addingTimeInterval(3.0)
            while hasRunningInstance(named: runner.name) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        start(runner)
    }

    /// Restart one branch's instance only — the header popover's
    /// per-row action. Unlike `restart(_:)` (the fixed-port switch
    /// path, which halts every live instance of the runner), this
    /// terminates just `branch`'s process, waits for it to die, then
    /// starts fresh pinned to the same branch. Other worktrees'
    /// instances are untouched.
    func restart(_ runner: ParsedRunner, on branch: String) async {
        let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
        if let process = processes[key], process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3.0)
            while statusByInstance[key]?.isRunning == true && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        setActiveBranch(branch, for: runner)
        start(runner)
    }

    // MARK: - Workspace start planning

    /// Decide what pressing Play on `workspace` does. Play is
    /// worktree-centric — "run this one": flexible-port runners come up
    /// alongside other worktrees' instances; fixed-port runners switch,
    /// displacing their live instance from whichever worktree had it.
    /// The decision never blocks on the user — `displacing` tells the
    /// caller what to announce after the fact.
    ///
    /// Splitting the decision from its execution lets unit tests (and
    /// the e2e automation server) exercise the exact same logic the
    /// sidebar renders. Note this is not a pure function: it records
    /// the workspace's branch as the active branch for every linked
    /// runner, exactly as the sidebar always did, so a later plain
    /// `start(_:)` targets the right worktree.
    func startPlan(for workspace: Workspace) -> StartPlan {
        if runners.isEmpty { return .openRunPane }
        let toStart = runnersToStart(for: workspace)
        return .start(
            toStart: toStart,
            displacing: displacements(among: toStart, excluding: workspace)
        )
    }

    /// Execute a plan's start list. Concurrent-safe runners just get a
    /// new instance; fixed-port runners restart so any other-branch
    /// instance is halted first (the switch `startPlan` promised).
    func executeStart(_ toStart: [ParsedRunner]) {
        Task { @MainActor in
            for runner in toStart {
                if canRunConcurrently(runner) {
                    start(runner)
                } else {
                    await restart(runner)
                }
            }
        }
    }

    /// Start `runner` pinned to `branch`, with the same fixed-port
    /// semantics every start surface shares: concurrent-safe runners
    /// just start; fixed-port runners restart so a live instance on
    /// another worktree is displaced instead of tripping the bind
    /// probe's "port in use" failure.
    func startPinned(_ runner: ParsedRunner, to branch: String) async {
        setActiveBranch(branch, for: runner)
        if canRunConcurrently(runner) {
            start(runner)
        } else {
            await restart(runner)
        }
    }

    /// Runners associated with a workspace: those anchored in one of
    /// its linked repos, or — when the workspace links nothing that has
    /// a runner — every runner in run.toml. Pure (no branch targeting),
    /// so UI affordances can query it on every render.
    func runnersAssociated(with workspace: Workspace) -> [ParsedRunner] {
        let linked = runners.filter { runner in
            guard let repo = repoName(for: runner) else { return false }
            return workspace.linkedRepoIDs.contains(repo)
        }
        return linked.isEmpty ? runners : linked
    }

    /// The workspace's non-headless runners — those with something to
    /// open (an `open` target or a port). Drives the sidebar row's
    /// open button: click opens all of them, press-and-hold picks one.
    func openableRunners(for workspace: Workspace) -> [ParsedRunner] {
        runnersAssociated(with: workspace).filter { canOpen($0) }
    }

    /// Runners the workspace's Play button targets. Linked runners get
    /// their active branch pointed at the workspace's worktree as a
    /// side effect.
    private func runnersToStart(for workspace: Workspace) -> [ParsedRunner] {
        let toStart = runnersAssociated(with: workspace)
        let linkedNames = Set(toStart.compactMap { runner -> String? in
            guard let repo = repoName(for: runner),
                  workspace.linkedRepoIDs.contains(repo) else { return nil }
            return runner.name
        })
        for runner in toStart where linkedNames.contains(runner.name) {
            setActiveBranch(workspace.name, for: runner)
        }
        return toStart
    }

    // MARK: - Open (browser / app)

    /// What kind of thing this runner's open target is — drives the
    /// row button's icon and tooltip (a URL preview is not the same
    /// affordance as launching an Electron app via a shell command).
    enum OpenKind {
        case url
        case command
    }

    /// nil when the row has nothing to offer: no `open` target and no
    /// port to default to `http://localhost:<port>/`.
    func openKind(for runner: ParsedRunner) -> OpenKind? {
        let template = runner.open ?? ""
        if template.isEmpty {
            return runner.port != nil ? .url : nil
        }
        return template.contains("://") ? .url : .command
    }

    /// True when the row can offer a manual "open": either run.toml
    /// declares an `open` target, or the runner has a port we can
    /// default to `http://localhost:<port>/`.
    func canOpen(_ runner: ParsedRunner) -> Bool {
        openKind(for: runner) != nil
    }

    /// Manual open for a (possibly running) instance — the row's open
    /// button. Unlike the automatic path this fires immediately: the
    /// user clicked it, presumably because the server is up.
    /// `preferExternal` (the button's option-click) skips the in-app
    /// tab and goes straight to the default browser.
    func openNow(_ runner: ParsedRunner, on branch: String, preferExternal: Bool = false) {
        let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
        guard let target = resolveOpenTarget(for: runner, key: key) else { return }
        performOpen(target, runner: runner, branch: branch,
                    sourceTag: signalSource(runnerName: runner.name, branch: branch),
                    preferExternal: preferExternal)
    }

    /// After a successful spawn: wait for the instance's port to start
    /// answering (the server needs time to boot), then open the
    /// runner's `open` target. Aborts silently if the instance exits
    /// first — a fast-failed server shouldn't pop a dead tab. Portless
    /// runners just get a short grace period.
    private func scheduleAutoOpen(
        for runner: ParsedRunner,
        key: RunnerInstanceKey,
        sourceTag: String
    ) {
        guard !(runner.open ?? "").isEmpty,
              let target = resolveOpenTarget(for: runner, key: key) else { return }
        let port = assignedPorts[key] ?? runner.port

        openTasks[key]?.cancel()
        openTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            if let port {
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if Task.isCancelled { return }
                    guard self.statusByInstance[key]?.isRunning == true else { return }
                    if Self.isPortInUse(port) { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard !Task.isCancelled,
                      self.statusByInstance[key]?.isRunning == true,
                      Self.isPortInUse(port) else { return }
            } else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled,
                      self.statusByInstance[key]?.isRunning == true else { return }
            }
            self.openTasks.removeValue(forKey: key)
            self.performOpen(target, runner: runner, branch: key.branch, sourceTag: sourceTag)
        }
    }

    /// Substitute `{port}` with the instance's effective port. nil when
    /// there's nothing sensible to open: no template and no port, or a
    /// `{port}` placeholder with no port to fill it.
    private func resolveOpenTarget(
        for runner: ParsedRunner,
        key: RunnerInstanceKey
    ) -> String? {
        let port = assignedPorts[key] ?? runner.port
        var template = runner.open ?? ""
        if template.isEmpty {
            guard port != nil else { return nil }
            template = "http://localhost:{port}/"
        }
        if template.contains("{port}") {
            guard let port else { return nil }
            return template.replacingOccurrences(of: "{port}", with: String(port))
        }
        return template
    }

    /// Fire the resolved target. URLs go in-app first (a browser tab
    /// inside the branch's workspace, via `openURLInApp`), falling back
    /// to the default external handler; anything else runs as a shell
    /// command in the runner's cwd. Always recorded in `openedTargets`;
    /// the override (tests, e2e) replaces only the external/shell side
    /// effect — in-app tabs are in-process and stay observable.
    private func performOpen(
        _ target: String,
        runner: ParsedRunner,
        branch: String,
        sourceTag: String,
        preferExternal: Bool = false
    ) {
        openedTargets.append(target)
        signals.append(source: sourceTag, line: "› opening: \(target)")
        if target.contains("://"), let url = URL(string: target), url.scheme != nil {
            if !preferExternal,
               let openURLInApp,
               openURLInApp(url, branch, runner.name) {
                return
            }
            if let openOverride {
                openOverride(target)
                return
            }
            NSWorkspace.shared.open(url)
        } else {
            if let openOverride {
                openOverride(target)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-lc", target]
            process.currentDirectoryURL = resolveCwd(for: runner)
            process.environment = ProcessInfo.processInfo.environment
            try? process.run()
        }
    }

    /// Every fixed-port switch this start will perform: non-concurrent
    /// runners among `toStart` that currently have a live instance on a
    /// branch other than the workspace's own.
    private func displacements(
        among toStart: [ParsedRunner],
        excluding workspace: Workspace
    ) -> [Displacement] {
        var result: [Displacement] = []
        for runner in toStart {
            guard !canRunConcurrently(runner) else { continue }
            for (key, status) in statusByInstance
            where key.runnerName == runner.name
                && status.isRunning
                && key.branch != workspace.name {
                result.append(Displacement(runner: runner, fromBranch: key.branch))
            }
        }
        return result
    }

    /// Stop a specific instance of a runner. When `branch` is nil we
    /// fall back to the runner's current target branch (the override
    /// or default), matching the single-instance assumption older
    /// callers had.
    func stop(_ runner: ParsedRunner, on branch: String? = nil) {
        let targetBranch = branch ?? currentBranch(for: runner) ?? "(default)"
        let key = RunnerInstanceKey(runnerName: runner.name, branch: targetBranch)
        let sourceTag = signalSource(runnerName: runner.name, branch: targetBranch)

        // The user's `stop` shell command typically uses `pkill -f`
        // patterns that can't distinguish between concurrent instances
        // of the same runner. Only run it when this is the lone live
        // instance to avoid kill-the-wrong-process surprises.
        let liveCount = processes.keys.filter {
            $0.runnerName == runner.name && processes[$0]?.isRunning == true
        }.count
        if liveCount <= 1, let stop = runner.stop, !stop.isEmpty {
            let killer = Process()
            killer.executableURL = URL(fileURLWithPath: "/bin/sh")
            killer.arguments = ["-lc", stop]
            killer.currentDirectoryURL = resolveCwd(for: runner)
            killer.environment = ProcessInfo.processInfo.environment
            do {
                try killer.run()
                signals.append(source: sourceTag, line: "› stopping: \(stop)")
            } catch {
                signals.append(
                    source: sourceTag,
                    line: "✗ stop command failed: \(error.localizedDescription)"
                )
            }
        }

        if let process = processes[key], process.isRunning {
            process.terminate()
        }
    }

    private func hasRunningInstance(named runnerName: String) -> Bool {
        statusByInstance.contains { key, value in
            key.runnerName == runnerName && value.isRunning
        }
    }

    /// Lowest available port at or above `basePort` that is neither
    /// promised to any live instance (of any runner — two runners can
    /// share a base port in run.toml) nor, per a bind probe, actually
    /// in use by anything else on the machine (a server started from a
    /// terminal tab, a leaked process, an unrelated app). Capped at
    /// +100 to avoid silent runaway when everything looks taken.
    private func nextFreePort(basePort: Int) -> Int {
        var used = Set(assignedPorts.values)
        // Fixed-port runners don't appear in assignedPorts — reserve
        // their port while they have any live instance.
        for runner in runners where (runner.portEnv ?? "").isEmpty {
            guard let fixed = runner.port else { continue }
            if statusByInstance.contains(where: {
                $0.key.runnerName == runner.name && $0.value.isRunning
            }) {
                used.insert(fixed)
            }
        }
        for offset in 0..<100 {
            let candidate = basePort + offset
            if !used.contains(candidate), !Self.isPortInUse(candidate) {
                return candidate
            }
        }
        return basePort
    }

    /// True when something is listening on `port` — checked by
    /// connecting to it on loopback, which is also exactly the
    /// "server is ready" signal the auto-open path needs. A connect
    /// probe sees listeners bound to either 127.0.0.1 or the wildcard
    /// (a bind probe with SO_REUSEADDR misses loopback-only servers —
    /// most dev servers — because wildcard-binding next to a specific
    /// address is allowed). Connecting to a closed local port fails
    /// instantly with ECONNREFUSED, so this never blocks; TIME_WAIT
    /// remnants of a stopped server never accept, so they correctly
    /// read as free.
    static func isPortInUse(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connectResult == 0
    }

    /// Tag we attach to signal lines for this instance. When the runner
    /// has only ever had one branch active, we keep the bare runner
    /// name so existing per-source lookups (Diagnose tail, source
    /// chips) work unchanged. Concurrent branches get suffixed.
    private func signalSource(runnerName: String, branch: String) -> String {
        let otherBranches = statusByInstance.keys.filter {
            $0.runnerName == runnerName && $0.branch != branch
        }
        return otherBranches.isEmpty ? runnerName : "\(runnerName):\(branch)"
    }

    private func resolveCwd(for runner: ParsedRunner) -> URL {
        if let branch = activeBranches[runner.name],
           let repoDir = repoDirectory(for: runner) {
            // Preserve any extra path segments after the branch folder
            // (e.g. monorepo subdir like .../webapp/main/yo-honey) when
            // swapping in a different branch.
            var url = repoDir.appendingPathComponent(branch)
            if let sub = parseRunnerPath(runner.cwd ?? "").subPath, !sub.isEmpty {
                url = url.appendingPathComponent(sub)
            }
            return url.standardizedFileURL
        }
        if let cwd = runner.cwd, !cwd.isEmpty {
            let url = URL(fileURLWithPath: cwd, relativeTo: project.rootPath)
            return url.standardizedFileURL
        }
        return project.rootPath
    }

    // MARK: - Branch selection

    /// Branch folder a runner will use the next time it starts. Falls
    /// back to the default branch derived from the original `cwd` in
    /// run.toml when the user hasn't picked anything else.
    func currentBranch(for runner: ParsedRunner) -> String? {
        if let override = activeBranches[runner.name] { return override }
        return defaultBranchFolder(for: runner)
    }

    /// Set the active branch for a runner. Pass `nil` to clear the
    /// override (i.e. return to the default branch from run.toml).
    func setActiveBranch(_ branch: String?, for runner: ParsedRunner) {
        guard let branch, branch != defaultBranchFolder(for: runner) else {
            activeBranches.removeValue(forKey: runner.name)
            return
        }
        activeBranches[runner.name] = branch
    }

    /// List of branch folder names available under `repos/<name>/`.
    /// Default branch is sorted first; everything else is alphabetical.
    /// Hidden folders and the `.bare/` git data dir are excluded.
    func availableBranches(for runner: ParsedRunner) -> [String] {
        guard let repoDir = repoDirectory(for: runner) else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: repoDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var names: [String] = []
        for url in entries {
            let resources = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resources?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if name == ".bare" { continue }
            names.append(name)
        }

        let defaultBranch = defaultBranchFolder(for: runner)
        return names.sorted { a, b in
            if a == defaultBranch { return true }
            if b == defaultBranch { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Branches that have any currently-running runner instance. Drives
    /// the green-dot indicator on workspace rows.
    var runningBranches: Set<String> {
        Set(statusByInstance.compactMap { key, status in
            status.isRunning ? key.branch : nil
        })
    }

    /// Distinct runner names that have a live instance on this branch.
    /// Used by the sidebar to decide whether a workspace row's play
    /// button should appear as stop.
    func runningRunners(onBranch branch: String) -> [String] {
        var names: [String] = []
        for (key, status) in statusByInstance
        where status.isRunning && key.branch == branch {
            if !names.contains(key.runnerName) { names.append(key.runnerName) }
        }
        return names
    }

    /// Repo folder name the runner is anchored in (the directory under
    /// `repos/` that contains the worktree it runs from). Walks the
    /// runner's `cwd` looking for a `repos` segment and returns the
    /// segment immediately after it, so deeper monorepo cwds like
    /// `repos/webapp/main/yo-honey` still resolve to `webapp`.
    func repoName(for runner: ParsedRunner) -> String? {
        parseRunnerPath(runner.cwd ?? "").repo ?? (runner.name.isEmpty ? nil : runner.name)
    }

    /// `<project>/repos/<repo-name>/` — derived from the runner's `cwd`
    /// via `repoName`. Falls back to a name-based path when the cwd
    /// doesn't contain a `repos` segment so older configs still work.
    private func repoDirectory(for runner: ParsedRunner) -> URL? {
        guard let repo = repoName(for: runner), !repo.isEmpty else { return nil }
        return project.rootPath
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .standardizedFileURL
    }

    /// Branch folder a runner is currently anchored to. For
    /// `repos/<repo>/<branch>` this is the trailing segment; for
    /// `repos/<repo>/<branch>/<subdir>` we still return `<branch>` so
    /// switching worktrees picks the right sibling folder.
    private func defaultBranchFolder(for runner: ParsedRunner) -> String? {
        parseRunnerPath(runner.cwd ?? "").branch
    }

    private struct RunnerPath {
        let repo: String?
        let branch: String?
        /// Anything beyond `repos/<repo>/<branch>/` — e.g. the package
        /// subdir in a monorepo. Empty when the cwd stops at the branch.
        let subPath: String?
    }

    /// Parse a runner cwd into `(repo, branch, subPath)`. Anchored on
    /// the `repos` segment so deeper paths still surface the right
    /// repo. Returns all-nil for cwds we can't recognise.
    private func parseRunnerPath(_ cwd: String) -> RunnerPath {
        let components = (cwd as NSString).pathComponents
            .filter { !$0.isEmpty && $0 != "/" && $0 != "." }
        guard let idx = components.firstIndex(of: "repos") else {
            // No `repos` anchor — fall back to the old two-segment
            // shape so legacy configs continue to work.
            if components.count >= 2 {
                return RunnerPath(
                    repo: components[components.count - 2],
                    branch: components.last,
                    subPath: nil
                )
            }
            return RunnerPath(repo: nil, branch: components.last, subPath: nil)
        }
        let repo = idx + 1 < components.count ? components[idx + 1] : nil
        let branch = idx + 2 < components.count ? components[idx + 2] : nil
        let rest: String?
        if idx + 3 < components.count {
            rest = components[(idx + 3)...].joined(separator: "/")
        } else {
            rest = nil
        }
        return RunnerPath(repo: repo, branch: branch, subPath: rest)
    }
}

// MARK: - Quit guard

extension RunnerManager: QuitGuardSource {
    var busyWork: BusyWork {
        BusyWork(runs: statusByInstance.values.filter(\.isRunning).count)
    }
}
