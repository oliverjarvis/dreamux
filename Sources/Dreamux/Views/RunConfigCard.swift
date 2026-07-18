import SwiftUI
import AppKit

/// The services popover's Configure tab — run configuration merged into
/// the header's run cluster (2026-07-18; formerly a full Run page, then
/// an Overview card). Detect / Isolate / Diagnose delegate to
/// `RunConfigActions`, which types prompts into the workspace's
/// dedicated "run config" terminal tab so the agent keeps its context
/// across clicks.
struct RunConfigCard: View {
    let project: Project
    @Bindable var session: WorkspaceSession
    @Bindable var repoStore: RepoStore
    @Bindable var runConfig: RunConfigStore
    @Bindable var runners: RunnerManager
    /// Project-wide signal stream — tail lines per runner power
    /// Diagnose-with-Claude when a runner fast-fails.
    @Bindable var signals: SignalStore

    @State private var showRawTOML: Bool = false

    /// The workspace this card configures runners for. Always present —
    /// the card lives on a workspace's Overview.
    private var scope: Workspace { session.workspace }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            detectAction
            runnersSection
            tomlSection
        }
        .padding(14)
        .onAppear {
            runConfig.reload()
            runners.reload(from: runConfig.rawTOML)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Run")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(scope.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(scope.tint)
            }
            Text("Start, stop, and configure runners for this workspace's worktree.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            .disabled(repoStore.repositories.isEmpty)

            if repoStore.repositories.isEmpty {
                Text("Add a repository before running detection.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if runners.runners.isEmpty {
                Text("Claude will inspect each repo and write .dreamux/run.toml in a run config tab.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text("No runners loaded. Once Claude writes run.toml, refresh to populate this list.")
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

    // MARK: - Scoping helpers

    /// Branch the card treats this runner as anchored to: the workspace's
    /// name when its repo is linked, else the runner's active branch.
    private func displayBranch(for runner: ParsedRunner) -> String {
        RunConfigActions.displayBranch(for: runner, runners: runners, scope: scope)
    }

    /// Runners visible in this card. Scope to the workspace's linked
    /// repos first, but fall back to every runner in run.toml when the
    /// workspace declares no links or none match — hiding everything
    /// when there's clearly config on disk was confusing.
    private var scopedRunners: [ParsedRunner] {
        guard !scope.linkedRepoIDs.isEmpty else { return runners.runners }
        let filtered = runners.runners.filter { runner in
            guard let repo = runners.repoName(for: runner) else { return false }
            return scope.linkedRepoIDs.contains(repo)
        }
        return filtered.isEmpty ? runners.runners : filtered
    }

    /// Start with worktree pinning when the runner's repo is linked to
    /// this workspace (shared fixed-port switch semantics); plain start
    /// otherwise — better to launch from `main` than fail because this
    /// workspace's worktree doesn't exist.
    private func startRunner(_ runner: ParsedRunner) {
        if let repo = runners.repoName(for: runner),
           scope.linkedRepoIDs.contains(repo) {
            Task { @MainActor in await runners.startPinned(runner, to: scope.name) }
            return
        }
        if runners.canRunConcurrently(runner) {
            runners.start(runner)
        } else {
            Task { @MainActor in await runners.restart(runner) }
        }
    }

    // MARK: - Claude actions (see RunConfigActions)

    private func runDetect() {
        RunConfigActions.detect(project: project, session: session)
    }

    private func runIsolate(_ runner: ParsedRunner) {
        RunConfigActions.isolate(runner, project: project, session: session)
    }

    private func runDiagnose(_ runner: ParsedRunner) {
        RunConfigActions.diagnose(
            runner, project: project, session: session,
            runners: runners, signals: signals, scope: scope)
    }

    private func failureTail(for runner: ParsedRunner, branch: String) -> String {
        RunConfigActions.failureTail(for: runner, branch: branch, signals: signals)
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
                .help("Send the failure and recent output to Claude in the run config tab")
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
