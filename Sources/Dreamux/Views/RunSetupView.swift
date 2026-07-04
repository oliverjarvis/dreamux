import SwiftUI
import GhosttyTerminal

/// Page that replaces the terminal pane when the user picks the "Run"
/// tile in the sidebar. Hosts a single embedded shell where Claude
/// (invoked by the "Detect" / "Modify" buttons) writes a per-project
/// `run.toml` describing how to start and stop each repo's runnable
/// surface.
struct RunSetupView: View {
    let project: Project
    @Bindable var repoStore: RepoStore
    @Bindable var runConfig: RunConfigStore
    @Bindable var runners: RunnerManager
    /// Project-wide signal stream. We read tail lines from it per
    /// runner to power Diagnose-with-Claude when a runner fast-fails.
    @Bindable var signals: SignalStore
    /// When set, the page is scoped to a specific feature's worktree —
    /// runners list is filtered to that feature's repos, and Start
    /// implicitly targets the workspace's branch folder. When nil the
    /// page shows the project-wide view (still reachable via the
    /// running strip's reveal action for runners without a workspace).
    let scope: Workspace?

    /// Lazily-created shell session. We hold one for the lifetime of
    /// the Run page so each click of Detect/Modify drops its prompt
    /// into the same shell — preserving the agent's prior context.
    @State private var terminal: TabSession?
    @State private var showRawTOML: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            controlsColumn
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            terminalArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            runConfig.reload()
            runners.reload(from: runConfig.rawTOML)
            consumePendingIsolationIfAny()
            consumePendingDetectIfAny()
        }
        .onChange(of: runners.pendingIsolation) { _, _ in
            consumePendingIsolationIfAny()
        }
        .onChange(of: e2eBridge?.pendingDetect) { _, _ in
            consumePendingDetectIfAny()
        }
    }

    /// Bridge for this project window — `nil` when the e2e harness is
    /// inactive, so the detect consumption below never fires.
    private var e2eBridge: E2EBridge? {
        E2ERegistry.shared.bridge(forProject: project.id)
    }

    /// The automation server's `detectRunConfig` command can't click
    /// our Detect button, so it raises this flag on the bridge and we
    /// run the same action here — mirroring `pendingIsolation`.
    private func consumePendingDetectIfAny() {
        guard let bridge = e2eBridge, bridge.pendingDetect else { return }
        bridge.pendingDetect = false
        runDetect()
    }

    /// If the user picked "Isolate with Claude" from the sidebar's
    /// shared-port conflict alert, kick off the isolate prompt for
    /// the runner the alert flagged as soon as the Run pane is up.
    private func consumePendingIsolationIfAny() {
        guard let target = runners.pendingIsolation else { return }
        runners.pendingIsolation = nil
        if let runner = runners.runners.first(where: { $0.name == target.name }) {
            runIsolate(runner)
        }
    }

    // MARK: - Left column (controls + TOML preview)

    private var controlsColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                detectAction
                Divider()
                runnersSection
                Divider()
                tomlSection
            }
            .padding(20)
        }
    }

    private var runnersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Runners")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if scopedRunners.contains(where: { runners.status(for: $0, on: displayBranch(for: $0))?.isRunning == true }) {
                    Button("Stop All", role: .destructive) {
                        for runner in scopedRunners {
                            runners.stop(runner, on: displayBranch(for: runner))
                        }
                    }
                    .controlSize(.small)
                } else if !scopedRunners.isEmpty {
                    Button("Start All") {
                        for runner in scopedRunners { startRunner(runner) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

            if scopedRunners.isEmpty {
                Text(emptyRunnersMessage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(scopedRunners) { runner in
                    let branch = displayBranch(for: runner)
                    RunnerRow(
                        runner: runner,
                        status: runners.status(for: runner, on: branch) ?? .idle,
                        assignedPort: runners.assignedPorts[
                            RunnerInstanceKey(runnerName: runner.name, branch: branch)
                        ],
                        currentBranch: branch,
                        availableBranches: runners.availableBranches(for: runner),
                        didFastFail: runners.didFastFail(runner, on: branch),
                        failureTail: failureTail(for: runner, branch: branch),
                        openKind: runners.openKind(for: runner),
                        onStart: { startRunner(runner) },
                        onStop: { runners.stop(runner, on: branch) },
                        onOpen: { preferExternal in
                            runners.openNow(runner, on: branch, preferExternal: preferExternal)
                        },
                        onPickBranch: { runners.setActiveBranch($0, for: runner) },
                        onIsolate: { runIsolate(runner) },
                        onDiagnose: { runDiagnose(runner) }
                    )
                }
            }
        }
    }

    /// Branch the pane treats this runner as anchored to. When scoped
    /// to a workspace that links this runner's repo, that's the
    /// workspace's name; otherwise it's the runner's most-recently-set
    /// active branch (override or default from run.toml).
    private func displayBranch(for runner: ParsedRunner) -> String {
        if let scope,
           let repo = runners.repoName(for: runner),
           scope.linkedRepoIDs.contains(repo) {
            return scope.name
        }
        return runners.currentBranch(for: runner) ?? "(default)"
    }

    /// Runners visible in this Run pane. We try to scope to the
    /// workspace's linked repos first, but fall back to showing every
    /// runner in run.toml when the workspace either declares no linked
    /// repos or none of its links match a runner. Hiding everything
    /// when there's clearly config on disk was confusing.
    private var scopedRunners: [ParsedRunner] {
        guard let scope, !scope.linkedRepoIDs.isEmpty else { return runners.runners }
        let filtered = runners.runners.filter { runner in
            guard let repo = runners.repoName(for: runner) else { return false }
            return scope.linkedRepoIDs.contains(repo)
        }
        return filtered.isEmpty ? runners.runners : filtered
    }

    /// When the user clicks Start in a scoped pane AND this runner's
    /// repo is actually linked to the workspace, point the runner at
    /// that workspace's worktree. Otherwise fall back to the runner's
    /// existing branch — better to launch from `main` than to fail
    /// because the workspace's worktree doesn't exist.
    ///
    /// If the runner can't run side-by-side (no `port_env` set on a
    /// service that has a fixed port), restart so any other-branch
    /// instance gets killed first; otherwise just start a new instance
    /// for this branch.
    private func startRunner(_ runner: ParsedRunner) {
        if let scope,
           let repo = runners.repoName(for: runner),
           scope.linkedRepoIDs.contains(repo) {
            runners.setActiveBranch(scope.name, for: runner)
        }
        if runners.canRunConcurrently(runner) {
            runners.start(runner)
        } else {
            Task { @MainActor in await runners.restart(runner) }
        }
    }

    private var emptyRunnersMessage: String {
        "No runners loaded. Once Claude writes run.toml, refresh to populate this list."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Run")
                    .font(.title3.weight(.semibold))
                if let scope {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(scope.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(scope.tint)
                }
            }
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        if scope != nil {
            return "Start, stop, and configure runners for this feature's worktree."
        }
        return "Have Claude figure out how to start and stop each repo, then save it as .dreamux/run.toml."
    }

    private var detectAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: runDetect) {
                Label(
                    runners.runners.isEmpty ? "Detect Run Config" : "Re-detect Run Config",
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(repoStore.repositories.isEmpty)

            if repoStore.repositories.isEmpty {
                Text("Add a repository before running detection.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if runners.runners.isEmpty {
                Text("Claude will inspect each repo and write .dreamux/run.toml.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tomlSection: some View {
        DisclosureGroup(isExpanded: $showRawTOML) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        runConfig.reload()
                        runners.reload(from: runConfig.rawTOML)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reload from disk")

                    if runConfig.exists {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([runConfig.configURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                }

                if let raw = runConfig.rawTOML {
                    ScrollView {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                } else {
                    Text("No run.toml yet. Click Detect to have Claude generate one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Show run.toml")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Right pane (terminal)

    @ViewBuilder
    private var terminalArea: some View {
        if let terminal {
            HostedTerminalView(session: terminal)
                .onAppear { terminal.startIfNeeded() }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Claude will run here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Click Detect Run Config to start.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func ensureTerminal() -> TabSession {
        if let terminal { return terminal }
        let session = TabSession(cwd: project.rootPath.path)
        session.startIfNeeded()
        terminal = session
        return session
    }

    private func runDetect() {
        sendClaude(detectPrompt())
    }

    private func runIsolate(_ runner: ParsedRunner) {
        sendClaude(isolatePrompt(for: runner))
    }

    /// Hand a fast-failed runner over to Claude. We bundle the start
    /// command, cwd, exit code/duration, and the recent log tail into
    /// one prompt so Claude can decide whether to install missing deps,
    /// fix the start command in run.toml, or surface a real bug.
    private func runDiagnose(_ runner: ParsedRunner) {
        sendClaude(diagnosePrompt(for: runner))
    }

    private func sendClaude(_ prompt: String) {
        ClaudePromptDriver.send(prompt, into: ensureTerminal())
    }

    /// Last ~10 log lines from this runner instance, joined by newlines.
    /// Tries the branch-tagged source name first ("webapp:asdf") since
    /// concurrent instances use suffixed source tags, then falls back
    /// to the bare runner name (single-instance case).
    private func failureTail(for runner: ParsedRunner, branch: String) -> String {
        let tagged = "\(runner.name):\(branch)"
        var entries = signals.recentEntries(forSource: tagged, limit: 10)
        if entries.isEmpty {
            entries = signals.recentEntries(forSource: runner.name, limit: 10)
        }
        return entries.map(\.message).joined(separator: "\n")
    }

    private func detectPrompt() -> String {
        return """
        You're helping configure the Dreamux Run page for this project. \
        Inspect every repo under ./repos/* (look at README, package.json, Cargo.toml, Makefile, docker-compose.yml, etc.) \
        and decide how to start and stop each one. \
        Write the result to .dreamux/run.toml. Create the directory if needed. \
        Use this exact shape (one [[runners]] entry per repo that can be started):

        [[runners]]
        name = "<repo-name>"
        cwd = "repos/<repo-name>/<default-branch-folder>"
        start = "<shell command to start>"
        stop = "<shell command to stop, e.g. pkill -f ...>"
        port = <integer or omit if not a network service>
        port_env = "<env var, ONLY if the app already reads its port from one>"
        open = "<what to open once it's serving, e.g. http://localhost:{port}/ — omit for headless services>"

        port_env matters: Dreamux runs the same app from multiple git worktrees at once \
        by giving each instance its own port through that env var. If the app already \
        honours an env var for its port (e.g. PORT for many Node/Rails apps, or a documented \
        custom one), set port_env to that name — do NOT modify any code. If the port is \
        hardcoded, omit port_env and leave the code alone; the user can opt into rewriting \
        it per-runner from the Run page later. \
        open is fired after the port starts answering; write {port} (literally) where the \
        port belongs and Dreamux substitutes each instance's actual port. A URL opens in \
        the browser; a shell command also works (e.g. to launch a native app). \
        Be concise: don't add commentary, just write the file. \
        When done, print 'run.toml ready' so I know to refresh.
        """
    }

    private func isolatePrompt(for runner: ParsedRunner) -> String {
        return """
        In this project's .dreamux/run.toml, the runner named "\(runner.name)" currently binds a fixed port \
        so only one worktree can run at a time. Change the repo's code under \
        repos/\(runner.name)/ so the port is read from an environment variable (e.g. \
        \(envVarSuggestion(for: runner.name))), defaulting to the existing port when unset. \
        Note: each branch folder under repos/\(runner.name)/ is an independent git checkout (worktree) — \
        apply the same change in every branch folder there (skip .bare), not just the default branch, \
        otherwise already-provisioned worktrees keep running hardcoded-port code and still collide. \
        Keep the diff minimal in each checkout — just the change needed to read the env var. Don't restructure files. \
        Then update the matching [[runners]] entry in .dreamux/run.toml to add: \
        port_env = "<the env var you chose>". \
        When done, print 'isolated \(runner.name)' so I know to refresh.
        """
    }

    private func diagnosePrompt(for runner: ParsedRunner) -> String {
        let branch = displayBranch(for: runner)
        let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
        let status = runners.status(for: runner, on: branch) ?? .idle
        let exitClause: String
        if case .exited(let code) = status {
            let durationText: String
            if let d = runners.lastRunDuration[key] {
                durationText = String(format: " after %.1fs", d)
            } else {
                durationText = ""
            }
            exitClause = "exited with code \(code)\(durationText)"
        } else {
            exitClause = "failed to start"
        }

        let cwd = runner.cwd ?? "(none)"
        let tail = failureTail(for: runner, branch: branch)
        let tailBlock = tail.isEmpty
            ? "(no recent output captured)"
            : tail

        return """
        The runner "\(runner.name)" \(exitClause). \
        Figure out why and fix it — install missing deps, correct the start command in .dreamux/run.toml, \
        whatever is needed. Keep the diff minimal. \
        When you've made a change, print 'diagnosed \(runner.name)' so I can retry.

        cwd: \(cwd)
        start command: \(runner.start)

        Recent output:
        \(tailBlock)
        """
    }

    private func envVarSuggestion(for runnerName: String) -> String {
        let upper = runnerName
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(upper)_PORT"
    }
}

// MARK: - Runner row

private struct RunnerRow: View {
    let runner: ParsedRunner
    let status: RunnerStatus
    /// Port actually injected into this instance via `port_env` — what
    /// the server is really listening on. The static `runner.port` is
    /// only the base: with two worktrees live, both rows would
    /// otherwise claim the same port while serving different ones.
    let assignedPort: Int?
    let currentBranch: String?
    let availableBranches: [String]
    let didFastFail: Bool
    let failureTail: String
    /// What the open button opens — `.url` (in-app browser tab, or
    /// external with option-click), `.command` (shell command, e.g.
    /// launching an Electron app), or nil to hide the button.
    let openKind: RunnerManager.OpenKind?
    let onStart: () -> Void
    let onStop: () -> Void
    /// The bool is "prefer external" — true on option-click.
    let onOpen: (Bool) -> Void
    let onPickBranch: (String?) -> Void
    let onIsolate: () -> Void
    let onDiagnose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(runner.name)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canIsolate {
                    Menu {
                        Button("Isolate on its own port…", action: onIsolate)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 13))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Per-runner actions")
                }

                if status.isRunning, let openKind {
                    Button {
                        onOpen(NSEvent.modifierFlags.contains(.option))
                    } label: {
                        // A URL gets browser iconography; a command
                        // target (Electron app, custom script) gets an
                        // app-launch icon so the button doesn't lie
                        // about what it does.
                        Image(systemName: openKind == .url ? "safari" : "arrow.up.forward.app")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(openKind == .url
                          ? "Open \(runner.name) as a tab in its workspace (⌥-click for external browser)"
                          : "Run \(runner.name)'s open command")
                }

                if status.isRunning {
                    Button("Stop", role: .destructive, action: onStop)
                        .controlSize(.small)
                } else {
                    Button("Start", action: onStart)
                        .controlSize(.small)
                }
            }

            branchPicker

            if didFastFail {
                failureCallout
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(didFastFail
                      ? Color.orange.opacity(0.10)
                      : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(didFastFail ? Color.orange.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    /// Compact inline failure summary shown when a runner exited fast
    /// with a non-zero code. The tail is intentionally truncated; the
    /// full output is still available in Signals.
    private var failureCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("This runner crashed quickly.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onDiagnose) {
                    Label("Diagnose with Claude", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("Send the failure and recent output to Claude in the Run terminal")
            }
            if let lastLine = failureTail
                .split(whereSeparator: { $0.isNewline })
                .reversed()
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(lastLine)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Only offer the "isolate" action when the runner is actually a
    /// network service (has a port) and isn't already env-driven.
    private var canIsolate: Bool {
        runner.port != nil && (runner.portEnv ?? "").isEmpty
    }

    /// Worktree selector. Shows the active branch as a small chip; the
    /// dropdown lists every folder we found under `repos/<name>/`. While
    /// the runner is running we keep the chip visible but disable the
    /// menu — switching mid-flight would silently desync what's on
    /// screen from what's actually executing.
    @ViewBuilder
    private var branchPicker: some View {
        let label = currentBranch ?? "(default)"
        let isDisabled = status.isRunning || availableBranches.isEmpty

        Menu {
            if availableBranches.isEmpty {
                Text("No worktrees found")
            } else {
                ForEach(availableBranches, id: \.self) { branch in
                    Button {
                        onPickBranch(branch)
                    } label: {
                        if branch == currentBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.caption.weight(.medium))
                if !isDisabled {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(status.isRunning ? Color.green : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(status.isRunning ? 0.18 : 0.14))
            )
            .overlay(
                Capsule().strokeBorder(
                    status.isRunning ? Color.green.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .help(
            status.isRunning
                ? "Stop the runner before switching worktrees"
                : "Switch the worktree this runner starts from"
        )
    }

    private var statusColor: Color {
        switch status {
        case .idle: return .secondary
        case .running: return .green
        case .exited(let code): return code == 0 ? .secondary : .orange
        case .failed: return .red
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        // While running, report the port the instance was actually
        // given (per-worktree isolation can shift it off the base).
        // The base port still shows when idle so the user knows what
        // run.toml configures.
        if status.isRunning, let assignedPort {
            parts.append("port \(assignedPort)")
        } else if let port = runner.port {
            parts.append("port \(port)")
        }
        switch status {
        case .running(let pid): parts.append("pid \(pid)")
        case .exited(let code) where code != 0: parts.append("exited \(code)")
        case .failed(let msg): parts.append(msg)
        default: break
        }
        return parts.isEmpty ? runner.start : parts.joined(separator: " · ")
    }
}

