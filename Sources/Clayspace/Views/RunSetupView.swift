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

    /// Lazily-created shell session. We hold one for the lifetime of
    /// the Run page so each click of Detect/Modify drops its prompt
    /// into the same shell — preserving the agent's prior context.
    @State private var terminal: TabSession?

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
        }
    }

    // MARK: - Left column (controls + TOML preview)

    private var controlsColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                portStrategySection
                actionsSection
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
                if runners.runners.contains(where: { runners.status[$0.name]?.isRunning == true }) {
                    Button("Stop All", role: .destructive) { runners.stopAll() }
                        .controlSize(.small)
                } else if !runners.runners.isEmpty {
                    Button("Start All") { runners.startAll() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }

            if runners.runners.isEmpty {
                Text("No runners loaded. Once Claude writes run.toml, refresh to populate this list.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(runners.runners) { runner in
                    RunnerRow(
                        runner: runner,
                        status: runners.status[runner.name] ?? .idle,
                        onStart: { runners.start(runner) },
                        onStop: { runners.stop(runner) }
                    )
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run Setup")
                .font(.title3.weight(.semibold))
            Text("Have Claude figure out how to start and stop each repo, then save it as .clayspace/run.toml.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var portStrategySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should new worktrees run?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(RunPortStrategy.allCases) { strategy in
                StrategyRow(
                    strategy: strategy,
                    isSelected: runConfig.portStrategy == strategy,
                    onTap: { runConfig.portStrategy = strategy }
                )
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: runDetect) {
                Label("Detect Run Config", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(repoStore.repositories.isEmpty)

            if runConfig.portStrategy == .uniquePort {
                Button(action: runModify) {
                    Label("Update Code for Worktree Ports", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(repoStore.repositories.isEmpty)
            }

            if repoStore.repositories.isEmpty {
                Text("Add a repository before running detection.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tomlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("run.toml")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    runConfig.reload()
                    runners.reload(from: runConfig.rawTOML)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reload from disk")

                if runConfig.exists {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([runConfig.configURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
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
                .frame(maxHeight: 280)
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
    }

    // MARK: - Right pane (terminal)

    @ViewBuilder
    private var terminalArea: some View {
        if let terminal {
            TerminalSurfaceView(context: terminal.viewState)
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
        let session = ensureTerminal()
        let prompt = detectPrompt()
        Task {
            // Give the freshly-started shell a beat to draw its prompt
            // before we paste — otherwise the first few chars can land
            // ahead of zsh's initial PS1 and look mangled.
            try? await Task.sleep(nanoseconds: 250_000_000)
            session.send("claude " + shellQuote(prompt) + "\n")
        }
    }

    private func runModify() {
        let session = ensureTerminal()
        let prompt = modifyPrompt()
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            session.send("claude " + shellQuote(prompt) + "\n")
        }
    }

    private func detectPrompt() -> String {
        let strategyClause: String
        switch runConfig.portStrategy {
        case .uniquePort:
            strategyClause = "Plan for multiple worktrees running side-by-side, each on a different port — record the env var name that controls the port in each runner."
        case .replace:
            strategyClause = "Assume only one instance runs at a time on the original port; no env-var override needed."
        }

        return """
        You're helping configure the Clayspace Run page for this project. \
        Inspect every repo under ./repos/* (look at README, package.json, Cargo.toml, Makefile, docker-compose.yml, etc.) \
        and decide how to start and stop each one. \(strategyClause) \
        Write the result to .clayspace/run.toml. Create the directory if needed. \
        Use this exact shape (one [[runners]] entry per repo that can be started):

        [[runners]]
        name = "<repo-name>"
        cwd = "repos/<repo-name>/<default-branch-folder>"
        start = "<shell command to start>"
        stop = "<shell command to stop, e.g. pkill -f ...>"
        port = <integer or omit if not a network service>
        port_env = "<env var name, only if uniquePort strategy>"

        Be concise: don't add commentary, just write the file. \
        When done, print 'run.toml ready' so I know to refresh.
        """
    }

    private func modifyPrompt() -> String {
        return """
        Read .clayspace/run.toml for this project. For each [[runners]] entry that has a port_env, \
        modify the repo's code under repos/<name>/ so the port can be configured via that env var, \
        defaulting to the existing port when unset. Keep the diff minimal — just the change needed \
        to read the env var. Don't restructure files. \
        When done, print 'code updated' so I can rerun detection.
        """
    }

    /// Wrap text in single quotes for safe shell pasting, escaping any
    /// embedded single quotes the standard '\'' way.
    private func shellQuote(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Runner row

private struct RunnerRow: View {
    let runner: ParsedRunner
    let status: RunnerStatus
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
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

            if status.isRunning {
                Button("Stop", role: .destructive, action: onStop)
                    .controlSize(.small)
            } else {
                Button("Start", action: onStart)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
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
        if let port = runner.port { parts.append("port \(port)") }
        if let cwd = runner.cwd, !cwd.isEmpty { parts.append(cwd) }
        switch status {
        case .running(let pid): parts.append("pid \(pid)")
        case .exited(let code) where code != 0: parts.append("exited \(code)")
        case .failed(let msg): parts.append(msg)
        default: break
        }
        return parts.isEmpty ? runner.start : parts.joined(separator: " · ")
    }
}

// MARK: - Strategy row

private struct StrategyRow: View {
    let strategy: RunPortStrategy
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(strategy.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(strategy.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
