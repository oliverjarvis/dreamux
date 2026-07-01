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

    /// Provision worktrees in each repo and rewire the
    /// `features/<name>/` aggregation directory. Idempotent for the
    /// aggregation dir but fails if a worktree at this name already
    /// exists in any of the linked repos (git wouldn't let us anyway).
    @discardableResult
    static func provision(
        featureName: String,
        in project: Project,
        across repos: [Repository]
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
        // back so a half-provisioned state doesn't sit on disk.
        var provisionedRepos: [Repository] = []
        do {
            for repo in repos {
                try await GitOperations.addWorktree(in: repo.rootURL, branch: featureName)
                provisionedRepos.append(repo)

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
            await rollback(featureName: featureName, project: project, repos: provisionedRepos)
            throw error
        }

        writeReadme(in: featureDir, featureName: featureName, repos: provisionedRepos)
        // New worktrees must see project-scope skills immediately —
        // discovery stops at the repo root, so links are the bridge.
        SkillLinker.reconcile(projectRoot: project.rootPath)
        return featureDir
    }

    /// Drop a small DREAMUX.md alongside the symlinks so a coding
    /// agent (or a human running `ls` for the first time) knows the
    /// aggregation directory itself isn't a git repo and to `cd` into
    /// one of the symlinked subfolders before running git commands.
    private static func writeReadme(
        in featureDir: URL,
        featureName: String,
        repos: [Repository]
    ) {
        let url = featureDir.appendingPathComponent("DREAMUX.md")
        let entries = repos.map { "- `\($0.name)/` — worktree on branch `\(featureName)` of repo `\($0.name)`" }.joined(separator: "\n")
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
        in its respective repo. They were created via `git worktree add`
        off each repo's default branch.

        ## Multi-repo work

        This feature is intentionally multi-rooted: changes in different
        repos can be made and committed independently in their own
        subfolders. They share only the branch name. Dreamux's Merge
        action will merge each branch into its own repo's default
        branch, in parallel.
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
        // Idempotent rebuild includes the README — covers features that
        // were created by a pre-readme build of Dreamux, or where the
        // file got deleted.
        writeReadme(in: featureDir, featureName: featureName, repos: repos)
        SkillLinker.reconcile(projectRoot: project.rootPath)
        return featureDir
    }

    /// Reverse `provision`: remove worktrees, delete branches, drop
    /// the aggregation folder. Best-effort — used during teardown of
    /// finished or abandoned features.
    static func teardown(
        featureName: String,
        in project: Project,
        across repos: [Repository]
    ) async {
        for repo in repos {
            let worktreeURL = repo.rootURL
                .appendingPathComponent(featureName, isDirectory: true)
            if FileManager.default.fileExists(atPath: worktreeURL.path) {
                try? await GitOperations.removeWorktree(at: worktreeURL, in: repo.rootURL)
            }
            try? await GitOperations.deleteBranch(in: repo.rootURL, branch: featureName)
        }
        let featureDir = featureDirectory(in: project, name: featureName)
        try? FileManager.default.removeItem(at: featureDir)
    }

    private static func rollback(
        featureName: String,
        project: Project,
        repos: [Repository]
    ) async {
        await teardown(featureName: featureName, in: project, across: repos)
    }
}
