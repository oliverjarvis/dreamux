import Foundation

enum FeatureError: LocalizedError {
    case alreadyExists(name: String)
    case noRepositories
    case directoryCreationFailed(underlying: Error)
    case symlinkFailed(repo: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "A feature named “\(name)” already exists in this project."
        case .noRepositories:
            return "Pick at least one repository for the feature."
        case .directoryCreationFailed(let error):
            return "Couldn't create the feature folder: \(error.localizedDescription)"
        case .symlinkFailed(let repo, let error):
            return "Couldn't link the worktree for \(repo): \(error.localizedDescription)"
        }
    }
}

/// Sets up (and tears down) the on-disk shape for a Dreamux feature:
///
///     <project>/repos/<repo>/<feature>/      ← worktree per repo, branch == feature name
///     <project>/features/<feature>/<repo>    ← symlink → ../../repos/<repo>/<feature>
///
/// The aggregation directory at `features/<feature>/` is what tabs cd
/// into so the agent sees one folder containing every relevant repo.
@MainActor
enum FeatureProvisioner {
    static func featuresDirectory(for project: Project) -> URL {
        project.rootPath.appendingPathComponent("features", isDirectory: true)
    }

    static func featureDirectory(in project: Project, name: String) -> URL {
        featuresDirectory(for: project).appendingPathComponent(name, isDirectory: true)
    }

    /// Name of the project-docs symlink inside a feature dir: `docs`,
    /// unless a linked repo claims that name — then `project-docs`.
    static func docsLinkName(repoNames: [String]) -> String {
        repoNames.contains("docs") ? "project-docs" : "docs"
    }

    /// Link the shared project docs home into the aggregation dir so
    /// every agent session reads and writes the same specs/plans (and
    /// checkbox ticks are visible to the app instantly).
    private static func linkProjectDocs(
        into featureDir: URL,
        project: Project,
        repos: [Repository]
    ) {
        DocStore.ensureDocsHome(at: project.rootPath)
        let linkURL = featureDir.appendingPathComponent(
            docsLinkName(repoNames: repos.map(\.name)))
        let target = "../../docs"
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
           existing == target { return }
        try? FileManager.default.removeItem(at: linkURL)
        try? FileManager.default.createSymbolicLink(
            atPath: linkURL.path, withDestinationPath: target)
    }

    /// Provision worktrees in each repo and rewire the
    /// `features/<name>/` aggregation directory. Idempotent for the
    /// aggregation dir but fails if a worktree at this name already
    /// exists in any of the linked repos (git wouldn't let us anyway).
    ///
    /// `startPoints` maps a repo NAME to the ref a *new* local branch
    /// should be cut from and track — `origin/<name>` for a branch that
    /// exists on the remote and not locally. Absent for a repo, the
    /// behaviour is exactly as before: check out an existing local head,
    /// or create the branch off HEAD.
    @discardableResult
    static func provision(
        featureName: String,
        in project: Project,
        across repos: [Repository],
        startPoints: [String: String] = [:]
    ) async throws -> URL {
        guard !repos.isEmpty else { throw FeatureError.noRepositories }

        let fm = FileManager.default
        let featureDir = featureDirectory(in: project, name: featureName)

        // Create the parent `features/` and the per-feature folder.
        do {
            try fm.createDirectory(
                at: featuresDirectory(for: project),
                withIntermediateDirectories: true
            )
        } catch {
            throw FeatureError.directoryCreationFailed(underlying: error)
        }

        if fm.fileExists(atPath: featureDir.path) {
            throw FeatureError.alreadyExists(name: featureName)
        }

        do {
            try fm.createDirectory(at: featureDir, withIntermediateDirectories: true)
        } catch {
            throw FeatureError.directoryCreationFailed(underlying: error)
        }

        // Create worktrees + symlinks. On failure roll the whole feature
        // back so a half-provisioned state doesn't sit on disk. We track
        // which repos got a branch WE created, because rollback must not
        // delete a branch that was already there.
        var provisionedRepos: [Repository] = []
        var createdBranchRepos: Set<String> = []
        do {
            for repo in repos {
                let created = try await GitOperations.addWorktree(
                    in: repo.rootURL,
                    branch: featureName,
                    startPoint: startPoints[repo.name]
                )
                provisionedRepos.append(repo)
                if created { createdBranchRepos.insert(repo.name) }

                let symlinkURL = featureDir.appendingPathComponent(repo.name)
                // Relative target keeps the symlink portable if the project
                // folder is moved.
                let relativeTarget = "../../repos/\(repo.name)/\(featureName)"
                do {
                    try fm.createSymbolicLink(
                        atPath: symlinkURL.path,
                        withDestinationPath: relativeTarget
                    )
                } catch {
                    throw FeatureError.symlinkFailed(repo: repo.name, underlying: error)
                }
            }
        } catch {
            await rollback(
                featureName: featureName, project: project,
                repos: provisionedRepos, createdBranchRepos: createdBranchRepos)
            throw error
        }

        linkProjectDocs(into: featureDir, project: project, repos: provisionedRepos)
        writeReadme(
            in: featureDir, featureName: featureName, repos: provisionedRepos,
            origin: startPoints.isEmpty && createdBranchRepos.count == provisionedRepos.count
                ? .created
                : .existing(trackingOrigin: !startPoints.isEmpty))
        // New worktrees must see project-scope skills immediately —
        // discovery stops at the repo root, so links are the bridge.
        SkillLinker.reconcile(projectRoot: project.rootPath)
        // …and must be equipped before the first shell lands in them.
        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)
        return featureDir
    }

    /// Where a feature's branches came from — decides one sentence in
    /// DREAMUX.md. `provision` knows (it just made them); the idempotent
    /// rebuild does not, so it says only what is true either way rather
    /// than guessing.
    enum BranchOrigin {
        /// Every branch was cut fresh off its repo's default branch.
        case created
        /// At least one branch already existed. `trackingOrigin` is true
        /// when at least one was opened from the remote.
        case existing(trackingOrigin: Bool)
        /// Rebuilt after the fact.
        case unknown
    }

    private static func originSentence(
        _ origin: BranchOrigin, featureName: String
    ) -> String {
        switch origin {
        case .created:
            return "They were created via `git worktree add` off each repo's default branch."
        case .existing(let trackingOrigin):
            return trackingOrigin
                ? "They were checked out via `git worktree add` from a branch that already existed — where it came from the remote, the local branch tracks `origin/\(featureName)`."
                : "They were checked out via `git worktree add` from a branch that already existed locally."
        case .unknown:
            return "They were set up via `git worktree add`."
        }
    }

    /// Drop a small DREAMUX.md alongside the symlinks so a coding
    /// agent (or a human running `ls` for the first time) knows the
    /// aggregation directory itself isn't a git repo and to `cd` into
    /// one of the symlinked subfolders before running git commands.
    private static func writeReadme(
        in featureDir: URL,
        featureName: String,
        repos: [Repository],
        origin: BranchOrigin
    ) {
        let url = featureDir.appendingPathComponent("DREAMUX.md")
        let entries = repos.map { "- `\($0.name)/` — worktree on branch `\(featureName)` of repo `\($0.name)`" }.joined(separator: "\n")
        let docsName = docsLinkName(repoNames: repos.map(\.name))
        let body = """
        # Feature: \(featureName)

        This folder is **not** a git repository. It's a Dreamux feature
        aggregation directory — each subfolder is a symlink to a separate
        git worktree, one per repository this feature spans.

        ## Layout

        \(entries)

        ## Working in a repo

        `cd` into one of the subfolders before running `git`:

            cd \(repos.first?.name ?? "<repo>")
            git status        # works — this is a real worktree
            git add ...
            git commit ...

        Each subfolder is checked out on the branch named `\(featureName)`
        in its respective repo. \(originSentence(origin, featureName: featureName))

        ## Multi-repo work

        This feature is intentionally multi-rooted: changes in different
        repos can be made and committed independently in their own
        subfolders. They share only the branch name. Dreamux's Merge
        action will merge each branch into its own repo's default
        branch, in parallel.

        ## Project docs — specs & plans

        `\(docsName)/` here is a symlink to the PROJECT-level docs home shared
        by every feature (it is not part of any repo). When you write design
        specs or implementation plans (e.g. via brainstorming/writing-plans
        skills), save them there instead of any per-repo docs folder:

        - specs → `\(docsName)/specs/YYYY-MM-DD-<topic>-design.md`
        - plans → `\(docsName)/plans/YYYY-MM-DD-<topic>.md`

        Dreamux's sidebar lists these files and tracks plan progress from
        their `- [ ]` checkboxes — tick each step's checkbox in the plan file
        as you complete it.
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Idempotent rebuild of the `features/<name>/` aggregation
    /// directory and its symlinks. Used during launch-time feature
    /// rediscovery so a feature whose worktrees exist on disk gets a
    /// well-formed aggregation folder even if it was never created
    /// through the in-app provision flow (or the folder was removed
    /// out from under us).
    @discardableResult
    static func ensureFeatureDirectory(
        featureName: String,
        in project: Project,
        across repos: [Repository]
    ) async -> URL {
        let fm = FileManager.default
        let featureDir = featureDirectory(in: project, name: featureName)

        try? fm.createDirectory(
            at: featuresDirectory(for: project),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(at: featureDir, withIntermediateDirectories: true)

        for repo in repos {
            let symlinkURL = featureDir.appendingPathComponent(repo.name)
            let target = "../../repos/\(repo.name)/\(featureName)"

            if let existing = try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path),
               existing == target {
                continue
            }
            try? fm.removeItem(at: symlinkURL)
            try? fm.createSymbolicLink(
                atPath: symlinkURL.path,
                withDestinationPath: target
            )
        }
        linkProjectDocs(into: featureDir, project: project, repos: repos)
        // Idempotent rebuild includes the README — covers features that
        // were created by a pre-readme build of Dreamux, or where the
        // file got deleted.
        writeReadme(
            in: featureDir, featureName: featureName, repos: repos, origin: .unknown)
        SkillLinker.reconcile(projectRoot: project.rootPath)
        WorktreeEnvironment.reconcile(projectRoot: project.rootPath)
        return featureDir
    }

    /// Reverse `provision`: remove worktrees, drop the aggregation
    /// folder, and — unless `deleteBranch` is false — delete the
    /// branches. Best-effort; used during teardown of finished or
    /// abandoned features, and when closing a workspace.
    ///
    /// `deleteBranch: false` is how an OPENED branch closes: the
    /// worktree and folder go, the branch (often someone else's work,
    /// possibly with local commits) stays.
    static func teardown(
        featureName: String,
        in project: Project,
        across repos: [Repository],
        deleteBranch: Bool = true
    ) async {
        for repo in repos {
            let worktreeURL = repo.rootURL
                .appendingPathComponent(featureName, isDirectory: true)
            if FileManager.default.fileExists(atPath: worktreeURL.path) {
                try? await GitOperations.removeWorktree(at: worktreeURL, in: repo.rootURL)
            }
            if deleteBranch {
                try? await GitOperations.deleteBranch(in: repo.rootURL, branch: featureName)
            }
        }
        let featureDir = featureDirectory(in: project, name: featureName)
        try? FileManager.default.removeItem(at: featureDir)
    }

    /// Undo a partial provision. Branches are force-deleted ONLY where
    /// this run created them: opening a branch that already existed and
    /// failing part-way through a multi-repo project must leave that
    /// branch exactly as it was.
    private static func rollback(
        featureName: String,
        project: Project,
        repos: [Repository],
        createdBranchRepos: Set<String>
    ) async {
        await teardown(
            featureName: featureName, in: project, across: repos, deleteBranch: false)
        for repo in repos where createdBranchRepos.contains(repo.name) {
            try? await GitOperations.deleteBranch(in: repo.rootURL, branch: featureName)
        }
    }
}
