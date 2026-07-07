import XCTest
@testable import Dreamux

/// Integration tests for `GitOperations` against real `git` repositories
/// inside a per-test `TestSandbox`. Nothing is mocked: every assertion
/// observes what the actual git plumbing left on disk, because the
/// bare-plus-worktrees layout (`repos/<name>/{.bare,.git,<branch>}`) is
/// the contract everything else in the app builds on.
final class GitOperationsTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    /// Identity flags for commits the tests make directly, mirroring
    /// `GitFixtures` — `-c` covers author and committer, so the suite
    /// never depends on the machine's global git config.
    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    override func setUpWithError() throws {
        // Some GitOperations entry points create commits internally
        // (initBare's starter commit, mergeBranch's merge commit,
        // commitAll) and offer no way to thread `-c user.*` flags in.
        // `runGit` snapshots the process environment on every call, so
        // exporting the GIT_* identity variables here keeps those
        // commits working on machines with no global git identity.
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
        super.tearDown()
    }

    // MARK: - initBare / cloneBare

    func testInitBareCreatesLayoutWithInitialCommit() async throws {
        let repo = try await GitOperations.initBare(into: project.rootPath, name: "demo")

        XCTAssertEqual(repo.defaultBranch, "main")
        let repoDir = project.rootPath.appendingPathComponent("repos/demo", isDirectory: true)
        XCTAssertEqual(repo.rootURL.path, repoDir.path)

        // `.bare/` is a real bare repository, and the `.git` pointer file
        // is what lets git commands run from anywhere under the repo dir.
        let isBare = try await git(["--git-dir=.bare", "rev-parse", "--is-bare-repository"], in: repoDir)
        XCTAssertEqual(isBare, "true")
        XCTAssertEqual(
            try String(contentsOf: repoDir.appendingPathComponent(".git"), encoding: .utf8),
            "gitdir: ./.bare\n"
        )

        // The default-branch worktree exists, sits on `main`, and carries
        // the starter commit (exactly one) tracking the seeded README.
        let mainWorktree = repoDir.appendingPathComponent("main", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainWorktree.appendingPathComponent("README.md").path
        ))
        let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: mainWorktree)
        XCTAssertEqual(head, "main")
        let commitCount = try await git(["rev-list", "--count", "HEAD"], in: mainWorktree)
        XCTAssertEqual(commitCount, "1")
        let tracked = try await git(["ls-files"], in: mainWorktree)
        XCTAssertTrue(tracked.contains("README.md"))
    }

    func testCloneBareFromLocalPath() async throws {
        // A plain local repository stands in for the remote — cloning by
        // filesystem path keeps the test offline.
        let sourceURL = sandbox.root.appendingPathComponent("origin-src", isDirectory: true)
        try await GitFixtures.makeCommittedRepo(at: sourceURL, files: ["hello.txt": "hi\n"])

        let repo = try await GitOperations.cloneBare(
            url: sourceURL.path,
            into: project.rootPath,
            name: "cloned"
        )
        XCTAssertEqual(repo.defaultBranch, "main")

        let repoDir = project.rootPath.appendingPathComponent("repos/cloned", isDirectory: true)
        let isBare = try await git(["--git-dir=.bare", "rev-parse", "--is-bare-repository"], in: repoDir)
        XCTAssertEqual(isBare, "true")
        XCTAssertEqual(
            try String(contentsOf: repoDir.appendingPathComponent(".git"), encoding: .utf8),
            "gitdir: ./.bare\n"
        )

        // The default-branch worktree was added and contains the source
        // repo's committed content.
        let mainWorktree = repoDir.appendingPathComponent("main", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: mainWorktree.appendingPathComponent("hello.txt"), encoding: .utf8),
            "hi\n"
        )

        // Bare clones default to fetching nothing useful; cloneBare must
        // reconfigure the refspec so future fetches behave like a normal
        // working copy's.
        let refspec = try await git(
            ["--git-dir=.bare", "config", "--get", "remote.origin.fetch"], in: repoDir
        )
        XCTAssertEqual(refspec, "+refs/heads/*:refs/remotes/origin/*")
    }

    // MARK: - Worktrees

    func testAddWorktreeCreatesNewBranchOffHead() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )

        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-a")

        // The worktree lands at repos/<name>/<branch>, checked out on a
        // branch of the same name, created off the repo's current HEAD.
        let worktree = repo.rootURL.appendingPathComponent("feature-a", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree)
        XCTAssertEqual(head, "feature-a")
        let featureTip = try await git(["rev-parse", "refs/heads/feature-a"], in: repo.rootURL)
        let mainTip = try await git(["rev-parse", "refs/heads/main"], in: repo.rootURL)
        XCTAssertEqual(featureTip, mainTip)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("app.txt").path
        ))
    }

    func testAddWorktreeReusesExistingBranch() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )
        let worktree = repo.rootURL.appendingPathComponent("topic", isDirectory: true)

        // Put a commit on `topic` that `main` doesn't have, then drop the
        // worktree while keeping the branch alive.
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "topic")
        try write("extra\n", to: "extra.txt", in: worktree)
        try await commit("Topic-only commit", in: worktree)
        let tipBefore = try await git(["rev-parse", "refs/heads/topic"], in: repo.rootURL)
        try await GitOperations.removeWorktree(at: worktree, in: repo.rootURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))

        try await GitOperations.addWorktree(in: repo.rootURL, branch: "topic")

        // A re-created branch (off HEAD == main) wouldn't have the extra
        // commit — its presence proves the existing branch was checked
        // out rather than replaced.
        let tipAfter = try await git(["rev-parse", "refs/heads/topic"], in: repo.rootURL)
        XCTAssertEqual(tipAfter, tipBefore)
        let worktreeHead = try await git(["rev-parse", "HEAD"], in: worktree)
        XCTAssertEqual(worktreeHead, tipBefore)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("extra.txt").path
        ))
    }

    func testRemoveWorktreeAndDeleteBranch() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )
        let worktree = repo.rootURL.appendingPathComponent("doomed", isDirectory: true)
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "doomed")

        try await GitOperations.removeWorktree(at: worktree, in: repo.rootURL)
        try await GitOperations.deleteBranch(in: repo.rootURL, branch: "doomed")

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        let branchSurvives = await gitSucceeds(
            ["rev-parse", "--verify", "--quiet", "refs/heads/doomed"], in: repo.rootURL
        )
        XCTAssertFalse(branchSurvives, "branch must be deleted, not just its worktree")
        let worktreeList = try await git(["worktree", "list", "--porcelain"], in: repo.rootURL)
        XCTAssertFalse(worktreeList.contains("doomed"), "worktree list must be pruned")
    }

    // MARK: - Merge

    func testMergeBranchCleanProducesNoFFMergeCommit() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )
        let mainWorktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)
        let featureWorktree = repo.rootURL.appendingPathComponent("feature-m", isDirectory: true)
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-m")
        try write("new\n", to: "feature.txt", in: featureWorktree)
        try await commit("Feature work", in: featureWorktree)

        let outcome = try await GitOperations.mergeBranch(
            feature: "feature-m", into: "main", in: mainWorktree
        )

        XCTAssertEqual(outcome, .merged)
        // --no-ff means an explicit merge commit even though main never
        // diverged: HEAD must be a merge (rev-list finds it) and the
        // feature tip must now be reachable from main.
        let mergeCount = try await git(["rev-list", "--merges", "--count", "HEAD"], in: mainWorktree)
        XCTAssertEqual(mergeCount, "1")
        let reachable = await gitSucceeds(
            ["merge-base", "--is-ancestor", "feature-m", "main"], in: mainWorktree
        )
        XCTAssertTrue(reachable)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainWorktree.appendingPathComponent("feature.txt").path
        ))
    }

    func testMergeBranchAlreadyUpToDate() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )
        let mainWorktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)
        // A branch with no commits of its own has nothing to merge.
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "noop")

        let outcome = try await GitOperations.mergeBranch(
            feature: "noop", into: "main", in: mainWorktree
        )

        XCTAssertEqual(outcome, .alreadyUpToDate)
    }

    func testMergeBranchConflictThenAbortRestoresCleanState() async throws {
        let (_, mainWorktree, outcome) = try await makeConflictedMerge(feature: "feature-c")

        guard case .conflicted(let paths) = outcome else {
            return XCTFail("expected .conflicted, got \(outcome)")
        }
        XCTAssertEqual(paths, ["shared.txt"])

        // The contract is to leave the worktree mid-merge for a human or
        // agent to resolve — MERGE_HEAD must still exist.
        let midMerge = await gitSucceeds(
            ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: mainWorktree
        )
        XCTAssertTrue(midMerge, "conflicted merge must be left in progress")

        await GitOperations.abortMerge(in: mainWorktree)

        let stillMidMerge = await gitSucceeds(
            ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], in: mainWorktree
        )
        XCTAssertFalse(stillMidMerge)
        let dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertFalse(dirty, "abort must restore a clean worktree")
        XCTAssertEqual(
            try String(contentsOf: mainWorktree.appendingPathComponent("shared.txt"), encoding: .utf8),
            "main change\n",
            "abort must restore main's version of the conflicted file"
        )
    }

    func testMergeProbeLifecycle() async throws {
        let (repo, mainWorktree, outcome) = try await makeConflictedMerge(feature: "feature-p")
        guard case .conflicted = outcome else {
            return XCTFail("expected .conflicted, got \(outcome)")
        }

        var probe = await GitOperations.mergeProbe(
            in: mainWorktree, feature: "feature-p", baseBranch: "main"
        )
        XCTAssertEqual(probe, .inProgress)

        // Resolve the way an agent would: take the feature side, stage,
        // and commit — git concludes the merge because MERGE_HEAD exists.
        _ = try await GitOperations.runGit(["checkout", "--theirs", "shared.txt"], in: mainWorktree)
        _ = try await GitOperations.runGit(["add", "shared.txt"], in: mainWorktree)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "Resolve conflict"], in: mainWorktree
        )

        probe = await GitOperations.mergeProbe(
            in: mainWorktree, feature: "feature-p", baseBranch: "main"
        )
        XCTAssertEqual(probe, .merged)

        // A fresh branch with its own commit is neither in progress nor
        // reachable from main.
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "fresh-b")
        let freshWorktree = repo.rootURL.appendingPathComponent("fresh-b", isDirectory: true)
        try write("fresh\n", to: "fresh.txt", in: freshWorktree)
        try await commit("Fresh work", in: freshWorktree)

        probe = await GitOperations.mergeProbe(
            in: mainWorktree, feature: "fresh-b", baseBranch: "main"
        )
        XCTAssertEqual(probe, .notMerged)
    }

    // MARK: - Status helpers

    func testCommitsAheadBeforeAndAfterCommits() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo", files: ["app.txt": "v1\n"]
        )
        let worktree = repo.rootURL.appendingPathComponent("counting", isDirectory: true)
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "counting")

        var ahead = await GitOperations.commitsAhead(of: "main", feature: "counting", in: repo.rootURL)
        XCTAssertEqual(ahead, 0)

        try write("one\n", to: "one.txt", in: worktree)
        try await commit("First", in: worktree)
        try write("two\n", to: "two.txt", in: worktree)
        try await commit("Second", in: worktree)

        ahead = await GitOperations.commitsAhead(of: "main", feature: "counting", in: repo.rootURL)
        XCTAssertEqual(ahead, 2)
    }

    func testUncommittedChangesAndCommitAllRespectingGitignore() async throws {
        // The .gitignore ships in the initial commit so `git add -A`
        // already knows what to skip when commitAll runs.
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo",
            files: ["app.txt": "v1\n", ".gitignore": "ignored.txt\n"]
        )
        let mainWorktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)

        var dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertFalse(dirty, "fresh fixture worktree must be clean")

        // Untracked file counts as uncommitted.
        try write("notes\n", to: "notes.txt", in: mainWorktree)
        dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertTrue(dirty)

        let headBefore = try await git(["rev-parse", "HEAD"], in: mainWorktree)
        try await GitOperations.commitAll(message: "Add notes", in: mainWorktree)
        dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertFalse(dirty)
        let headAfter = try await git(["rev-parse", "HEAD"], in: mainWorktree)
        XCTAssertNotEqual(headAfter, headBefore)
        let trackedAfterCommit = try await git(["ls-files"], in: mainWorktree)
        XCTAssertTrue(trackedAfterCommit.contains("notes.txt"))

        // Modified tracked file counts as uncommitted; an ignored file
        // arriving at the same time must be staged by commitAll's
        // `add -A` ... except it can't be, because .gitignore wins.
        try write("v2\n", to: "app.txt", in: mainWorktree)
        try write("secret\n", to: "ignored.txt", in: mainWorktree)
        dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertTrue(dirty)

        try await GitOperations.commitAll(message: "Update app", in: mainWorktree)

        dirty = await GitOperations.hasUncommittedChanges(in: mainWorktree)
        XCTAssertFalse(dirty)
        let tracked = try await git(["ls-files"], in: mainWorktree)
        XCTAssertFalse(tracked.contains("ignored.txt"), "gitignored file must stay untracked")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainWorktree.appendingPathComponent("ignored.txt").path
        ), "gitignored file must survive on disk")
    }

    // MARK: - Territory (intake digest)

    func testChangedTopLevelPathsSpanCommittedAndUncommittedVsMergeBase() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "demo",
            files: ["README.md": "root\n", "docs/keep.md": "keep\n"]
        )
        try await GitOperations.addWorktree(in: repo.rootURL, branch: "feature-t")
        let worktree = repo.rootURL.appendingPathComponent("feature-t", isDirectory: true)

        // A COMMITTED change on the feature branch — the crux of diffing
        // against the merge-base rather than the working tree: agents commit
        // per task, so a bare `git diff` would miss this entirely.
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try write("fn\n", to: "Sources/app.swift", in: worktree)
        try await commit("Add source", in: worktree)
        // An UNCOMMITTED change to a tracked file (modification, unstaged).
        try write("root edited\n", to: "README.md", in: worktree)

        // Baseline contrast: a bare working-tree diff sees only the
        // uncommitted edit, never the committed new file.
        let bareDiff = try await git(["diff", "--name-only"], in: worktree)
        XCTAssertFalse(bareDiff.contains("Sources/app.swift"),
                       "a bare diff must miss committed work (that's why we use merge-base)")

        let paths = await GitOperations.changedTopLevelPaths(in: worktree, baseBranch: "main")

        XCTAssertTrue(paths.contains("Sources"), "committed change's top-level path must appear")
        XCTAssertTrue(paths.contains("README.md"), "uncommitted change's top-level path must appear")
        XCTAssertFalse(paths.contains("docs"), "an unchanged base path must not appear")
    }

    func testChangedTopLevelPathsMissingWorktreeIsEmpty() async throws {
        // Tolerant contract: a path with no repo/worktree yields [] rather
        // than throwing, so one absent worktree never fails the digest.
        let ghost = project.rootPath.appendingPathComponent("repos/ghost/feature", isDirectory: true)
        let paths = await GitOperations.changedTopLevelPaths(in: ghost, baseBranch: "main")
        XCTAssertEqual(paths, [])
    }

    // MARK: - deriveName

    func testDeriveNameFromCloneURLs() {
        XCTAssertEqual(GitOperations.deriveName(from: "git@github.com:foo/bar.git"), "bar")
        XCTAssertEqual(GitOperations.deriveName(from: "https://github.com/foo/bar.git"), "bar")
        XCTAssertEqual(GitOperations.deriveName(from: "https://github.com/foo/bar"), "bar")
        XCTAssertEqual(GitOperations.deriveName(from: "https://github.com/foo/bar/"), "bar")
        // Characters unsafe in folder names become "-", and dangling
        // separators are trimmed; -_. survive untouched.
        XCTAssertEqual(GitOperations.deriveName(from: "https://host.example/team/my app!.git"), "my-app")
        XCTAssertEqual(GitOperations.deriveName(from: "git@host:team/my_repo.v2.git"), "my_repo.v2")
    }

    // MARK: - slug

    func testSlugFromProjectName() {
        XCTAssertEqual(GitOperations.slug(from: "Pokemon Emulator"), "pokemon-emulator")
        // Runs of non-alphanumerics collapse to one hyphen; ends trimmed.
        XCTAssertEqual(GitOperations.slug(from: "  My  Cool  App!! "), "my-cool-app")
        XCTAssertEqual(GitOperations.slug(from: "already-slugged"), "already-slugged")
        XCTAssertEqual(GitOperations.slug(from: "under_scores.kept"), "under-scores-kept")
        // A name of only punctuation slugs to empty (the modal blocks it).
        XCTAssertEqual(GitOperations.slug(from: "!!!"), "")
        XCTAssertEqual(GitOperations.slug(from: "Café Déjà"), "caf-d-j")
    }

    // MARK: - Helpers

    /// Run git via the same plumbing under test and trim the trailing
    /// newline so assertions can compare against bare values.
    private func git(_ args: [String], in cwd: URL) async throws -> String {
        try await GitOperations.runGit(args, in: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the git command exits 0 — the natural shape for
    /// `--verify` / `--is-ancestor` style probes whose answer *is* the
    /// exit code.
    private func gitSucceeds(_ args: [String], in cwd: URL) async -> Bool {
        (try? await GitOperations.runGit(args, in: cwd)) != nil
    }

    private func write(_ contents: String, to name: String, in dir: URL) throws {
        try contents.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// Stage everything and commit with the test identity.
    private func commit(_ message: String, in worktree: URL) async throws {
        _ = try await GitOperations.runGit(["add", "-A"], in: worktree)
        _ = try await GitOperations.runGit(identity + ["commit", "-m", message], in: worktree)
    }

    /// Build a repo where `main` and a feature branch each rewrote the
    /// same line of `shared.txt`, then run the merge so the main worktree
    /// is left mid-conflict (feature side says "feature change", main
    /// side says "main change"). Returns the merge outcome so callers
    /// can assert on the conflict shape themselves.
    private func makeConflictedMerge(
        feature: String
    ) async throws -> (repo: Repository, mainWorktree: URL, outcome: GitOperations.MergeOutcome) {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "conflict-repo",
            files: ["shared.txt": "original\n"]
        )
        let mainWorktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)
        let featureWorktree = repo.rootURL.appendingPathComponent(feature, isDirectory: true)
        try await GitOperations.addWorktree(in: repo.rootURL, branch: feature)

        try write("feature change\n", to: "shared.txt", in: featureWorktree)
        try await commit("Feature edit", in: featureWorktree)
        try write("main change\n", to: "shared.txt", in: mainWorktree)
        try await commit("Main edit", in: mainWorktree)

        let outcome = try await GitOperations.mergeBranch(
            feature: feature, into: "main", in: mainWorktree
        )
        return (repo, mainWorktree, outcome)
    }
}
