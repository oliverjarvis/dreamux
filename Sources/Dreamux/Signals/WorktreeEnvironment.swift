import Foundation

/// Report of one reconcile pass — mirrors `SkillLinkReport`: what we
/// wrote, and what we left alone because something that isn't ours was
/// already sitting there.
struct WorktreeEnvironmentReport: Equatable, Sendable {
    var equipped: [String] = []
    var skipped: [String] = []
}

/// Equips every git worktree in a project with what a shell started
/// there needs, so descending into a worktree (see
/// `WorkspaceWorktrees.shellHome`) is never a downgrade from standing at
/// the project root. Per worktree:
///
///   `.mcp.json`                   → the dreamux-signals bridge, scoped
///                                   to the PROJECT root
///   `project-docs/`               → relative link to `<project>/docs`
///   `.claude/settings.local.json` → a SessionStart hook that tells an
///                                   agent where it is
///
/// Every worktree, not only the default branch: a shell in a feature
/// worktree asks the same question and deserves the same answer. Plan
/// runs are unaffected — they start in `features/<name>/`, which already
/// has its own `docs` symlink and `.mcp.json`.
///
/// Git noise is suppressed with a managed block in each repo's shared
/// `.bare/info/exclude` — local-only, so no tracked file ever changes.
/// A repo directory without `.bare` is skipped wholesale (the rule
/// `SkillLinker` follows: with no shared `info/exclude` to absorb the
/// noise, writing there would create churn in someone else's
/// repository), and any artifact whose name is already taken is left
/// alone and reported.
///
/// `@MainActor` to match `FeatureProvisioner`, which calls it, and
/// because `DocStore.ensureDocsHome` is main-actor isolated.
@MainActor
enum WorktreeEnvironment {
    static let excludeBlockStart = "# >>> dreamux worktree env (managed) >>>"
    static let excludeBlockEnd = "# <<< dreamux worktree env (managed) <<<"

    /// Rides along in the hook's command string as an inert shell
    /// comment, so a later pass can find and replace exactly its own
    /// SessionStart entry and leave anyone else's alone.
    static let hookSentinel = "dreamux-worktree-orientation"

    /// Never plain `docs`: inside a real repository that name means the
    /// repository's OWN docs (the dreamux repo has one), and silently
    /// redefining it is worse than the link simply being absent.
    /// `FeatureProvisioner.docsLinkName`'s conditional choice is for
    /// aggregation directories; here the collision is always possible,
    /// so the name is unconditional.
    static let docsLinkName = "project-docs"

    /// Leading "/" anchors each pattern to the worktree root.
    static let excludePatterns = [
        "/.mcp.json",
        "/project-docs",
        "/.claude/settings.local.json",
    ]

    @discardableResult
    static func reconcile(projectRoot: URL) -> WorktreeEnvironmentReport {
        var report = WorktreeEnvironmentReport()
        // Linking to a docs home that doesn't exist yet would leave a
        // dangling link, exactly as FeatureProvisioner.linkProjectDocs
        // guards against.
        DocStore.ensureDocsHome(at: projectRoot)

        for repoDir in repoDirectories(projectRoot: projectRoot) {
            guard FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent(".bare").path)
            else { continue }
            GitExcludeBlock.update(
                repoRoot: repoDir,
                startMarker: excludeBlockStart,
                endMarker: excludeBlockEnd,
                patterns: excludePatterns)
            let repo = Repository(rootURL: repoDir)
            for worktree in repo.worktrees {
                installMCP(in: worktree, projectRoot: projectRoot, report: &report)
                linkProjectDocs(in: worktree, report: &report)
                installOrientationHook(in: worktree, repoName: repo.name, report: &report)
            }
        }
        return report
    }

    // MARK: - The three artifacts

    /// `projectScope` is load-bearing: it sets `DREAMUX_PROJECT_DIR` to
    /// the project root, so a session running in a worktree reads and
    /// emits signals against the same scope as everything else. Mirrors
    /// what `PlanRunCoordinator` does for the feature directory.
    private static func installMCP(
        in worktree: URL,
        projectRoot: URL,
        report: inout WorktreeEnvironmentReport
    ) {
        let path = worktree.appendingPathComponent(".mcp.json").path
        switch MCPInstaller.installIfNeeded(at: worktree.path, projectScope: projectRoot.path) {
        case .installed:
            report.equipped.append(path)
        case .alreadyInstalled, .skippedNoScript:
            // Idempotent by design: an existing entry whose command
            // resolves is left alone, so a committed .mcp.json never
            // churns. No runner on this machine is not our problem.
            break
        case .skippedReason(let why):
            report.skipped.append("\(path) (\(why))")
        }
    }

    /// `<worktree>/project-docs` → `<project>/docs`. A worktree sits at
    /// `<project>/repos/<repo>/<branch>/`, so three levels up is the
    /// project root. Relative, like every link Dreamux writes, so the
    /// project folder stays movable.
    private static func linkProjectDocs(
        in worktree: URL,
        report: inout WorktreeEnvironmentReport
    ) {
        let fm = FileManager.default
        let linkURL = worktree.appendingPathComponent(docsLinkName)
        let target = "../../../docs"

        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
            if existing == target { return }
            try? fm.removeItem(at: linkURL)   // stale link under our name — repair
        } else if fm.fileExists(atPath: linkURL.path) {
            // A real file or directory the repo owns. Never touch it.
            report.skipped.append("\(linkURL.path) (repo-owned)")
            return
        }

        do {
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
            report.equipped.append(linkURL.path)
        } catch {
            report.skipped.append("\(linkURL.path) (\(error.localizedDescription))")
        }
    }

    /// Merge a `SessionStart` hook into `.claude/settings.local.json`.
    /// Merge, not replace: these files hold real user content (the
    /// project root's own copy carries `enabledMcpjsonServers`).
    /// Idempotence comes from the sentinel — drop any entry of ours,
    /// then append the current one.
    private static func installOrientationHook(
        in worktree: URL,
        repoName: String,
        report: inout WorktreeEnvironmentReport
    ) {
        let fm = FileManager.default
        let settingsURL = worktree.appendingPathComponent(".claude/settings.local.json")

        var root: [String: Any] = [:]
        let fileExists = fm.fileExists(atPath: settingsURL.path)
        if fileExists {
            guard let data = try? Data(contentsOf: settingsURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                report.skipped.append("\(settingsURL.path) (existing file failed to parse)")
                return
            }
            root = parsed
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var sessionStart = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        sessionStart.removeAll { entry in
            let inner = (entry["hooks"] as? [[String: Any]]) ?? []
            return inner.contains { ($0["command"] as? String)?.contains(hookSentinel) == true }
        }
        // Shape follows the superpowers plugin's own hooks.json. The
        // matcher covers /clear and /compact as well as startup — those
        // are exactly the moments the orientation would otherwise be lost.
        sessionStart.append([
            "matcher": "startup|clear|compact",
            "hooks": [[
                "type": "command",
                "command": orientationCommand(
                    repoName: repoName, branch: worktree.lastPathComponent),
                "shell": "bash",
                "async": false,
            ] as [String: Any]],
        ] as [String: Any])
        hooks["SessionStart"] = sessionStart
        root["hooks"] = hooks

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else {
            report.skipped.append("\(settingsURL.path) (failed to encode)")
            return
        }
        // Byte-compare BEFORE anything expensive. `reconcile` is a
        // whole-project pass and `WorkspaceStore.reloadFeatures` runs one
        // per discovered feature, so "everything is already correct" is
        // by far the hottest path and must cost nothing but a read.
        if let existing = try? Data(contentsOf: settingsURL), existing == data { return }
        // Only now, with a write actually pending, ask git who owns the
        // file. Exclusion suppresses UNTRACKED files only, so a repo that
        // tracks this one owns it: writing would show up in `git status`
        // and eventually in someone's commit.
        //
        // Deliberately behind the byte-compare, not in front of it: this
        // blocks the main actor until git exits, and git can block on
        // index contention while another part of the app is adding or
        // removing worktrees in the same repo. Reaching it only when
        // there is a real change to write keeps a settled pass free of
        // subprocesses entirely.
        if fileExists, isTracked(".claude/settings.local.json", in: worktree) {
            report.skipped.append("\(settingsURL.path) (tracked by the repo)")
            return
        }
        do {
            try fm.createDirectory(
                at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: [.atomic])
            report.equipped.append(settingsURL.path)
        } catch {
            report.skipped.append("\(settingsURL.path) (\(error.localizedDescription))")
        }
    }

    // MARK: - The orientation text

    /// What the hook prints. Claude Code injects a SessionStart hook's
    /// stdout as context, so this is what an agent starting here reads
    /// first.
    static func orientationText(repoName: String, branch: String) -> String {
        """
        You are in a git worktree of the `\(repoName)` repository, inside a Dreamux project.
        - This directory is a normal git checkout of branch `\(branch)` — git commands work here.
        - The Dreamux project's shared docs home is linked as `project-docs/`: specs in `project-docs/specs/`, plans in `project-docs/plans/`. This repository's own `docs/` directory is unrelated to those.
        - The whole project — every repo, every feature worktree, and the `.dreamux/` state directory — is at `../../..`.
        """
    }

    /// A self-contained `printf` — no helper script, no path resolution,
    /// no assumption about the hook's working directory. The sentinel
    /// rides along as a shell comment, so it is inert.
    static func orientationCommand(repoName: String, branch: String) -> String {
        let body = orientationText(repoName: repoName, branch: branch)
        // Single-quote for the shell. A literal ' inside a single-quoted
        // run can only be expressed by closing, escaping, and reopening.
        let quoted = "'" + body.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "printf '%s\\n' \(quoted)  # \(hookSentinel)"
    }

    // MARK: - Helpers

    private static func repoDirectories(projectRoot: URL) -> [URL] {
        let reposDir = projectRoot.appendingPathComponent("repos", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: reposDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// True when `relativePath` is in `worktree`'s index.
    ///
    /// Synchronous on purpose: `reconcile` is a sync pass called from
    /// provisioning and from the sidebar's main-workspace open, and this
    /// is a local, index-only `git ls-files` — no network, no hooks, no
    /// prompts. `GitOperations.runGit` is async-only, so this shells out
    /// directly rather than making the whole pass async.
    private static func isTracked(_ relativePath: String, in worktree: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-files", "--error-unmatch", "--", relativePath]
        process.currentDirectoryURL = worktree
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
