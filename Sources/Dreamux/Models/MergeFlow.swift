import Foundation

/// Per-repo state of merging the feature branch into its default
/// branch. Owned by `MergeFlow`; the sheet creates a fresh flow per
/// presentation, so the map resets every time the sheet is opened.
enum MergeRepoState: Equatable {
    case pending
    case working
    case upToDate
    case featureDirty
    case merged
    case conflicted(paths: [String])
    case failed(message: String)
    case cleaningUp
    case cleanedUp
    /// Pushing the feature branch to origin / creating the PR.
    case pushing
    /// A PR for the feature branch exists and is open on the remote.
    /// Deliberately NOT cleanup-able: the branch is the PR's head, so
    /// removing it locally before the PR merges would strand the PR.
    case prOpen(url: String)
    /// The remote reports the PR merged (by any method — merge commit,
    /// squash, or rebase). Cleanup is now safe and additionally
    /// fast-forwards local main from origin first.
    case prMerged(url: String)

    var isTerminal: Bool {
        switch self {
        case .pending, .working, .cleaningUp, .pushing: return false
        default: return true
        }
    }

    var canMerge: Bool {
        switch self {
        case .pending, .failed: return true
        default: return false
        }
    }

    /// Publishing shares merge's preconditions: a committed feature
    /// branch that's ahead of base. (Remote/gh availability is a
    /// separate, per-repo check in `MergeFlow.publishAvailability`.)
    var canPublish: Bool { canMerge }

    var canCleanup: Bool {
        switch self {
        case .merged, .upToDate, .prMerged: return true
        default: return false
        }
    }

    /// URL of the PR this state refers to, if any. Lets the row offer
    /// "View PR" for both open and merged PRs without re-matching.
    var prURL: String? {
        switch self {
        case .prOpen(let url), .prMerged(let url): return url
        default: return nil
        }
    }
}

/// Whether the "Create PR" path can be offered for a repo, decided in
/// `MergeFlow.initializeStates`. Split from `MergeRepoState` because
/// it's a property of the repo's configuration, not of the merge's
/// progress — it never changes while the sheet is open.
enum PublishAvailability: Equatable {
    case available
    /// Repo has no `origin` remote (e.g. created via init) — there is
    /// nowhere to push, so the option is hidden entirely.
    case noRemote
    /// Repo has a remote but no `gh` CLI was found — the option shows
    /// disabled with an install hint rather than vanishing, so the
    /// user learns the capability exists.
    case ghMissing
}

extension PublishAvailability {
    /// Pure verdict from the two probes the pre-check gathers: no remote
    /// ⇒ the option can never apply (hidden); a remote but no gh ⇒
    /// fixable, shown disabled; both present ⇒ available.
    static func decide(anyRemote: Bool, ghAvailable: Bool) -> PublishAvailability {
        guard anyRemote else { return .noRemote }
        return ghAvailable ? .available : .ghMissing
    }
}

/// The merge sheet's orchestration, extracted from the view — the
/// `StartPlan` pattern again — so the exact same code runs whether the
/// user clicks through `MergeFeatureSheet`, the e2e automation server
/// executes `mergeFeature`/`cleanupFeature`, or a unit test drives a
/// scenario directly. Presentation (badges, buttons, the resolution
/// prompt) stays in the view layer; everything that decides or mutates
/// the repos lives here.
///
/// One instance per sheet presentation: the state map, commit errors
/// and live output are meaningless across presentations because the
/// world they describe (worktrees, branches, merges in flight) changes
/// underneath them.
@MainActor
@Observable
final class MergeFlow {
    let workspace: Workspace
    let repos: [Repository]
    let project: Project

    /// Fires after each individual repo successfully reaches the
    /// `.cleanedUp` state. The sheet's parent uses it to stop any
    /// runner whose active worktree was the one we just removed.
    let onRepoCleanedUp: (Repository) -> Void
    /// Fires once when every repo in this flow has reached
    /// `.cleanedUp`. The sheet's parent uses it to remove the workspace
    /// from the sidebar, delete the now-empty `features/<name>/`
    /// aggregation directory, and dismiss the sheet.
    let onAllCleanedUp: () -> Void
    /// Fires right after a PR is successfully opened in `publish`. The
    /// sheet's parent uses it to start tracking the feature on
    /// `ProjectSession.prStatus` so the Flows lane picks up the PR
    /// badge without waiting for the next app launch's seed pass.
    let onPublished: (Repository, String) -> Void

    private(set) var states: [String: MergeRepoState] = [:]
    private(set) var commitErrors: [String: String] = [:]
    /// Per-repo result of the post-PR fast-forward that `cleanup` runs
    /// on the `.prMerged` path — what lets the sheet's "Cleaned up"
    /// badge say whether main actually caught up with origin.
    private(set) var syncOutcomes: [String: GitOperations.FastForwardOutcome] = [:]
    /// Per-repo verdict on whether "Create PR" can be offered, filled
    /// once by `initializeStates`. Missing key (pre-check still
    /// running) renders the same as `.noRemote` — no PR button.
    private(set) var publishAvailability: [String: PublishAvailability] = [:]
    /// Counts polling passes so PR-status lookups (which hit the
    /// network through gh) run every ~10s instead of every 2.5s tick.
    private var prPollTick = 0
    /// Live tail of the most recent git output per repo. We keep the
    /// last `liveOutputCap` lines so a slow `git add -A` shows progress
    /// rather than freezing the sheet.
    private(set) var liveOutput: [String: [String]] = [:]
    /// In-flight git tasks per repo so Cancel can SIGTERM the child.
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private(set) var isBatchRunning = false

    private let liveOutputCap = 5

    init(
        workspace: Workspace,
        repos: [Repository],
        project: Project,
        onRepoCleanedUp: @escaping (Repository) -> Void = { _ in },
        onAllCleanedUp: @escaping () -> Void = {},
        onPublished: @escaping (Repository, String) -> Void = { _, _ in }
    ) {
        self.workspace = workspace
        self.repos = repos
        self.project = project
        self.onRepoCleanedUp = onRepoCleanedUp
        self.onAllCleanedUp = onAllCleanedUp
        self.onPublished = onPublished
    }

    /// State for one repo, defaulting to `.pending` the same way the
    /// sheet's rows render before `initializeStates` has landed.
    func state(for repo: Repository) -> MergeRepoState {
        states[repo.name] ?? .pending
    }

    var hasPending: Bool {
        states.values.contains { $0.canMerge || $0 == .featureDirty }
    }

    func baseWorktreeURL(for repo: Repository) -> URL {
        repo.rootURL.appendingPathComponent(repo.defaultBranch, isDirectory: true)
    }

    func featureWorktreeURL(for repo: Repository) -> URL {
        repo.rootURL.appendingPathComponent(workspace.name, isDirectory: true)
    }

    // MARK: - Pre-check

    /// Pre-check every repo before the user clicks Merge:
    ///   • If the feature worktree is already gone, treat it as cleaned up.
    ///   • If `git status --porcelain` is non-empty in the feature worktree,
    ///     mark the repo `.featureDirty` so the user knows to commit first.
    ///   • If there are zero commits ahead of base, jump straight to
    ///     `.upToDate` — saves a redundant `git merge` and makes
    ///     "nothing to merge" obvious.
    func initializeStates() async {
        var map: [String: MergeRepoState] = [:]
        for repo in repos {
            let featureWorktree = featureWorktreeURL(for: repo)
            if !FileManager.default.fileExists(atPath: featureWorktree.path) {
                // The branch may also be gone — for our purposes the
                // repo no longer has anything to clean up.
                map[repo.name] = .cleanedUp
                continue
            }
            if await GitOperations.hasUncommittedChanges(in: featureWorktree) {
                map[repo.name] = .featureDirty
                continue
            }
            let ahead = await GitOperations.commitsAhead(
                of: repo.defaultBranch,
                feature: workspace.name,
                in: repo.rootURL
            )
            map[repo.name] = ahead == 0 ? .upToDate : .pending
        }
        states = map

        // PR availability: per-repo remote check, plus one shared gh
        // probe (skipped entirely when no repo has a remote — common
        // for local-only projects, and it keeps the sheet snappy).
        var hasRemote: [String: Bool] = [:]
        var anyRemote = false
        for repo in repos {
            let remote = await GitOperations.remoteURL(in: repo.rootURL) != nil
            hasRemote[repo.name] = remote
            if remote { anyRemote = true }
        }
        let ghAvailable = anyRemote ? await GhOperations.isAvailable() : false
        var availability: [String: PublishAvailability] = [:]
        for repo in repos {
            availability[repo.name] = PublishAvailability.decide(
                anyRemote: hasRemote[repo.name] ?? false, ghAvailable: ghAvailable)
        }
        publishAvailability = availability

        // A fresh flow is created every time the sheet opens, so an
        // already-published PR would otherwise come back as "Pending".
        // For publishable repos still pending, ask gh whether this
        // branch already has a PR and resume from its actual state.
        for repo in repos
        where availability[repo.name] == .available && states[repo.name] == .pending {
            guard let status = await GhOperations.prStatus(
                branch: workspace.name,
                in: featureWorktreeURL(for: repo)
            ) else { continue }
            switch status.state {
            case .open: states[repo.name] = .prOpen(url: status.url)
            case .merged: states[repo.name] = .prMerged(url: status.url)
            case .closed: break
            }
        }
    }

    /// Re-run the up-front pre-check for a single repo. The sheet's
    /// poller calls this for any repo still in `.featureDirty` so
    /// committing externally (via Open in Terminal, or any other path)
    /// flips the row back to `.pending` within ~2.5s without the user
    /// touching the sheet.
    func recheckRepo(_ repo: Repository) async {
        let featureWorktree = featureWorktreeURL(for: repo)
        if !FileManager.default.fileExists(atPath: featureWorktree.path) {
            states[repo.name] = .cleanedUp
            return
        }
        if await GitOperations.hasUncommittedChanges(in: featureWorktree) {
            states[repo.name] = .featureDirty
            return
        }
        let ahead = await GitOperations.commitsAhead(
            of: repo.defaultBranch,
            feature: workspace.name,
            in: repo.rootURL
        )
        states[repo.name] = ahead == 0 ? .upToDate : .pending
    }

    // MARK: - Polling

    /// One poll pass: for any repo our state map still shows as
    /// conflicted, ask git whether the conflict has been resolved —
    /// this is what makes the sheet flip to "Merged" automatically once
    /// the user (or their agent) finishes resolving and commits. Repos
    /// stuck on `.featureDirty` get the pre-check re-run for the same
    /// reason. The sheet drives this every ~2.5s while it's on screen.
    func pollConflictedRepos() async {
        prPollTick += 1
        for repo in repos {
            let state = states[repo.name] ?? .pending
            switch state {
            case .conflicted:
                await pollConflictResolution(for: repo)
            case .featureDirty:
                await recheckRepo(repo)
            case .prOpen:
                // gh round-trips the network; every 4th tick (~10s) is
                // plenty to notice a PR merging. tick==1 so the first
                // pass after the sheet opens still refreshes promptly.
                if prPollTick % 4 == 1 {
                    await pollPRStatus(for: repo)
                }
            default:
                continue
            }
        }
    }

    private func pollPRStatus(for repo: Repository) async {
        let worktree = featureWorktreeURL(for: repo)
        guard let status = await GhOperations.prStatus(
            branch: workspace.name,
            in: worktree
        ) else { return }
        switch status.state {
        case .merged:
            states[repo.name] = .prMerged(url: status.url)
        case .closed:
            // PR closed without merging — back to pending so the user
            // can merge locally or push a fresh PR.
            states[repo.name] = .pending
        case .open:
            break
        }
    }

    private func pollConflictResolution(for repo: Repository) async {
        let baseURL = baseWorktreeURL(for: repo)
        let probe = await GitOperations.mergeProbe(
            in: baseURL,
            feature: workspace.name,
            baseBranch: repo.defaultBranch
        )
        switch probe {
        case .inProgress:
            // Refresh the conflicted file list — the agent might
            // have resolved a few but not all yet.
            let paths = await GitOperations.conflictedPaths(in: baseURL)
            if !paths.isEmpty {
                states[repo.name] = .conflicted(paths: paths)
            }
        case .merged:
            states[repo.name] = .merged
        case .notMerged:
            // External `git merge --abort` or unrelated change.
            states[repo.name] = .pending
        }
    }

    // MARK: - Merge

    func runMerge(for repo: Repository) async {
        states[repo.name] = .working
        liveOutput[repo.name] = []
        let baseURL = baseWorktreeURL(for: repo)
        let task = Task { @MainActor in
            do {
                let outcome = try await GitOperations.mergeBranch(
                    feature: workspace.name,
                    into: repo.defaultBranch,
                    in: baseURL,
                    onLine: liveLineHandler(for: repo.name)
                )
                switch outcome {
                case .alreadyUpToDate: states[repo.name] = .upToDate
                case .merged:          states[repo.name] = .merged
                case .conflicted(let paths): states[repo.name] = .conflicted(paths: paths)
                }
            } catch is CancellationError {
                states[repo.name] = .failed(message: "Cancelled.")
            } catch {
                states[repo.name] = .failed(message: error.localizedDescription)
            }
        }
        activeTasks[repo.name] = task
        await task.value
        activeTasks.removeValue(forKey: repo.name)
    }

    func mergeAllPending() async {
        isBatchRunning = true
        for repo in repos {
            let state = states[repo.name] ?? .pending
            if state == .featureDirty {
                await commitAndMerge(repo)
            } else if state.canMerge {
                await runMerge(for: repo)
            }
        }
        isBatchRunning = false
    }

    // MARK: - Publish (push + PR)

    /// Push the feature branch to origin and open a PR against the
    /// repo's default branch. The local default branch is untouched —
    /// integration happens on the remote, and `pollPRStatus` flips the
    /// row to `.prMerged` once GitHub reports the merge.
    func publish(_ repo: Repository) async {
        states[repo.name] = .pushing
        liveOutput[repo.name] = []
        let task = Task { @MainActor in
            do {
                try await GitOperations.push(
                    branch: workspace.name,
                    in: repo.rootURL,
                    onLine: liveLineHandler(for: repo.name)
                )
                let url = try await GhOperations.createPR(
                    branch: workspace.name,
                    base: repo.defaultBranch,
                    title: workspace.name,
                    body: await prBody(for: repo),
                    in: featureWorktreeURL(for: repo)
                )
                states[repo.name] = .prOpen(url: url)
                onPublished(repo, url)
            } catch is CancellationError {
                states[repo.name] = .failed(message: "Cancelled.")
            } catch {
                states[repo.name] = .failed(message: error.localizedDescription)
            }
        }
        activeTasks[repo.name] = task
        await task.value
        activeTasks.removeValue(forKey: repo.name)
    }

    /// The featureDirty variant of `publish`, mirroring `commitAndMerge`:
    /// stage + commit everything in the feature worktree, then push & PR.
    func commitAndPublish(_ repo: Repository) async {
        commitErrors.removeValue(forKey: repo.name)
        states[repo.name] = .pushing
        liveOutput[repo.name] = []
        let worktree = featureWorktreeURL(for: repo)
        do {
            try await GitOperations.commitAll(
                message: workspace.name,
                in: worktree,
                onLine: liveLineHandler(for: repo.name)
            )
        } catch {
            commitErrors[repo.name] = "Commit failed: \(error.localizedDescription)"
            states[repo.name] = .featureDirty
            return
        }
        await publish(repo)
    }

    /// PR description: the feature's commit subjects against base, so
    /// the PR opens with a meaningful summary even when the user never
    /// edits it. Capped — a 200-commit feature shouldn't produce a
    /// novel.
    private func prBody(for repo: Repository) async -> String {
        let log = (try? await GitOperations.runGit(
            ["log", "--oneline", "--no-decorate", "-n", "30",
             "\(repo.defaultBranch)..\(workspace.name)"],
            in: repo.rootURL
        )) ?? ""
        let commits = log.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = "Feature `\(workspace.name)` from Dreamux."
        if !commits.isEmpty {
            body += "\n\n## Commits\n\n```\n\(commits)\n```"
        }
        return body
    }

    func abortMerge(for repo: Repository) async {
        let baseURL = baseWorktreeURL(for: repo)
        states[repo.name] = .working
        await GitOperations.abortMerge(in: baseURL)
        states[repo.name] = .pending
    }

    /// One-click "fix the missing commit". Stages everything in the
    /// feature worktree, commits with the workspace name as the message,
    /// and then runs the normal merge. On commit failure we surface the
    /// error inline and bounce the row back to `.featureDirty` so the
    /// user can retry or fall back to the terminal.
    func commitAndMerge(_ repo: Repository) async {
        commitErrors.removeValue(forKey: repo.name)
        states[repo.name] = .working
        liveOutput[repo.name] = []
        let worktree = featureWorktreeURL(for: repo)
        let task = Task { @MainActor in
            do {
                try await GitOperations.commitAll(
                    message: workspace.name,
                    in: worktree,
                    onLine: liveLineHandler(for: repo.name)
                )
            } catch is CancellationError {
                commitErrors[repo.name] = "Cancelled."
                states[repo.name] = .featureDirty
                return
            } catch {
                commitErrors[repo.name] = "Commit failed: \(error.localizedDescription)"
                states[repo.name] = .featureDirty
                return
            }
            await runMerge(for: repo)
        }
        activeTasks[repo.name] = task
        await task.value
        activeTasks.removeValue(forKey: repo.name)
    }

    /// Cancel the in-flight git task for a repo. SIGTERMs the child via
    /// the cancellation handler we wired into `GitOperations.runGit`.
    func cancel(_ repo: Repository) {
        activeTasks[repo.name]?.cancel()
    }

    // MARK: - Cleanup

    func cleanup(_ repo: Repository) async {
        let priorState = states[repo.name] ?? .pending
        states[repo.name] = .cleaningUp

        // PR path: the integration happened on the remote, so local
        // main is behind. Fast-forward it from origin first — then the
        // rest of cleanup leaves the repo in the same shape a local
        // merge would have.
        if case .prMerged = priorState {
            syncOutcomes[repo.name] = await GitOperations.fastForwardFromOrigin(
                branch: repo.defaultBranch,
                in: baseWorktreeURL(for: repo),
                onLine: liveLineHandler(for: repo.name)
            )
        }

        // Remove the worktree, delete the branch, drop the dangling
        // symlink in the feature aggregation directory so `cd <repo>`
        // from the feature dir doesn't lead into a broken link.
        let worktreeURL = featureWorktreeURL(for: repo)
        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            try? await GitOperations.removeWorktree(at: worktreeURL, in: repo.rootURL)
        }
        try? await GitOperations.deleteBranch(in: repo.rootURL, branch: workspace.name)

        let symlinkURL = FeatureProvisioner
            .featureDirectory(in: project, name: workspace.name)
            .appendingPathComponent(repo.name)
        try? FileManager.default.removeItem(at: symlinkURL)

        states[repo.name] = .cleanedUp
        onRepoCleanedUp(repo)

        // If every repo we manage is now cleanedUp, the feature is
        // fully gone — hand off to the owner so it can drop the
        // workspace from the sidebar and remove the aggregation dir.
        if repos.allSatisfy({ states[$0.name] == .cleanedUp }) {
            onAllCleanedUp()
        }
    }

    // MARK: - Live output

    /// Sendable callback that funnels every git output line into the
    /// per-repo ring buffer on the main actor. Capped at `liveOutputCap`
    /// lines so the sheet doesn't grow without bound on chatty commands
    /// (notably `git add -A` against a missing-gitignore tree).
    private func liveLineHandler(for repoName: String) -> @Sendable (String) -> Void {
        let cap = liveOutputCap
        return { line in
            Task { @MainActor in
                var buffer = self.liveOutput[repoName] ?? []
                buffer.append(line)
                if buffer.count > cap {
                    buffer.removeFirst(buffer.count - cap)
                }
                self.liveOutput[repoName] = buffer
            }
        }
    }

    // MARK: - Cleanup summary

    /// The "Cleaned up" badge's full text for a repo — base text plus
    /// what the post-PR fast-forward actually did. `nil`/upToDate keep
    /// the plain text: the local-merge path has no sync step, and an
    /// already-current main needs no annotation.
    static func cleanupSummary(
        outcome: GitOperations.FastForwardOutcome?,
        defaultBranch: String
    ) -> String {
        switch outcome {
        case nil, .alreadyUpToDate:
            return "Cleaned up"
        case .synced:
            return "Cleaned up · \(defaultBranch) synced with origin"
        case .diverged:
            return "Cleaned up · \(defaultBranch) diverged from origin — sync from the header"
        case .fetchFailed:
            return "Cleaned up · couldn't reach origin to sync \(defaultBranch)"
        case .ffFailed:
            return "Cleaned up · \(defaultBranch) couldn't fast-forward — sync from the header"
        }
    }

    func cleanupSummary(for repo: Repository) -> String {
        Self.cleanupSummary(
            outcome: syncOutcomes[repo.name], defaultBranch: repo.defaultBranch)
    }
}
