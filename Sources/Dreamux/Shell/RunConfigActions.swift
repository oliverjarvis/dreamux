import Foundation

/// The claude-driving run-config actions — detect, isolate, diagnose —
/// shared by the services popover's Configure tab and the background
/// handoff consumer (e2e `detectRunConfig`, the isolate alert), so they
/// work whether or not any run-config UI is on screen. Prompts land in
/// the workspace's dedicated "run config" terminal tab
/// (`WorkspaceSession.reuseOrOpenRunConfigTab`), preserving the agent's
/// context across actions.
@MainActor
enum RunConfigActions {
    static func detect(project: Project, session: WorkspaceSession) {
        send(detectPrompt(), project: project, session: session)
    }

    static func isolate(
        _ runner: ParsedRunner, project: Project, session: WorkspaceSession
    ) {
        send(isolatePrompt(for: runner), project: project, session: session)
    }

    /// Hand a fast-failed runner over to Claude: start command, cwd,
    /// exit code/duration, and the recent log tail in one prompt.
    static func diagnose(
        _ runner: ParsedRunner,
        project: Project,
        session: WorkspaceSession,
        runners: RunnerManager,
        signals: SignalStore,
        scope: Workspace
    ) {
        send(
            diagnosePrompt(
                for: runner, runners: runners, signals: signals, scope: scope),
            project: project, session: session)
    }

    /// cwd is the project root: run.toml is project-level and the
    /// prompts reference repos/<name>/ paths.
    private static func send(
        _ prompt: String, project: Project, session: WorkspaceSession
    ) {
        guard let terminal = session.reuseOrOpenRunConfigTab(at: project.rootPath.path)
        else { return }
        terminal.startIfNeeded()
        ClaudePromptDriver.send(prompt, into: terminal)
    }

    /// Branch a runner is anchored to within `scope` — the workspace's
    /// name when its repo is linked, else the runner's active branch.
    static func displayBranch(
        for runner: ParsedRunner, runners: RunnerManager, scope: Workspace
    ) -> String {
        if let repo = runners.repoName(for: runner),
           scope.linkedRepoIDs.contains(repo) {
            return scope.name
        }
        return runners.currentBranch(for: runner) ?? "(default)"
    }

    /// Last ~10 log lines from this runner instance. Branch-tagged
    /// source name first (concurrent instances use suffixed tags), bare
    /// runner name as fallback.
    static func failureTail(
        for runner: ParsedRunner,
        branch: String,
        signals: SignalStore
    ) -> String {
        let tagged = "\(runner.name):\(branch)"
        var entries = signals.recentEntries(forSource: tagged, limit: 10)
        if entries.isEmpty {
            entries = signals.recentEntries(forSource: runner.name, limit: 10)
        }
        return entries.map(\.message).joined(separator: "\n")
    }

    // MARK: - Prompts

    private static func detectPrompt() -> String {
        return """
        You're helping configure the Dreamux Run controls for this project. \
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
        it per-runner later. \
        open is fired after the port starts answering; write {port} (literally) where the \
        port belongs and Dreamux substitutes each instance's actual port. A URL opens in \
        the browser; a shell command also works (e.g. to launch a native app). \
        Be concise: don't add commentary, just write the file. \
        When done, print 'run.toml ready' so I know to refresh.
        """
    }

    private static func isolatePrompt(for runner: ParsedRunner) -> String {
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

    private static func diagnosePrompt(
        for runner: ParsedRunner,
        runners: RunnerManager,
        signals: SignalStore,
        scope: Workspace
    ) -> String {
        let branch = displayBranch(for: runner, runners: runners, scope: scope)
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
        let tail = failureTail(for: runner, branch: branch, signals: signals)
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

    static func envVarSuggestion(for runnerName: String) -> String {
        let upper = runnerName
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(upper)_PORT"
    }
}
