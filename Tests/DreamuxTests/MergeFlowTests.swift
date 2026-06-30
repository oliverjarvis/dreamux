import XCTest
@testable import Dreamux

/// Tests for `MergeFlow` — the merge sheet's orchestration, shared with
/// the e2e `mergeFeature`/`cleanupFeature` commands. Everything runs
/// against real git repositories in a per-test sandbox because the
/// flow's whole job is sequencing git side effects correctly: commit
/// the dirty feature worktree with the workspace name as the message,
/// merge `--no-ff` from inside the *default-branch* worktree, leave
/// conflicts in place, and tear down worktree + branch + symlink in
/// the right order during cleanup.
@MainActor
final class MergeFlowTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    /// Identity flags for commits the tests make directly, mirroring
    /// `GitFixtures` — `-c` covers author and committer, so the suite
    /// never depends on the machine's global git config.
    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    override func setUp() async throws {
        // The flow reaches commits it can't thread `-c user.*` flags
        // into (commitAll, mergeBranch's merge commit); exporting the
        // GIT_* identity variables keeps those working on machines
        // with no global git identity. Same trick as GitOperationsTests.
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    // MARK: - Fixtures

    private let feature = "feat-merge"

    /// Bare-layout repo with a committed `main` worktree plus a feature
    /// worktree branched off its tip.
    private func makeRepoWithFeatureWorktree(
        named name: String,
        mainFiles: [String: String] = ["base.txt": "base\n"]
    ) async throws -> Repository {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: name, files: mainFiles
        )
        try await GitOperations.addWorktree(in: repo.rootURL, branch: feature)
        return repo
    }

    private func makeFlow(
        repos: [Repository],
        onRepoCleanedUp: @escaping (Repository) -> Void = { _ in },
        onAllCleanedUp: @escaping () -> Void = {}
    ) -> MergeFlow {
        MergeFlow(
            workspace: Workspace(name: feature, linkedRepoIDs: repos.map(\.name)),
            repos: repos,
            project: project,
            onRepoCleanedUp: onRepoCleanedUp,
            onAllCleanedUp: onAllCleanedUp
        )
    }

    private func write(_ contents: String, to relativePath: String, in worktree: URL) throws {
        try contents.write(
            to: worktree.appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Stage everything and commit with the test identity.
    private func commitAll(in worktree: URL, message: String) async throws {
        _ = try await GitOperations.runGit(["add", "-A"], in: worktree)
        _ = try await GitOperations.runGit(identity + ["commit", "-m", message], in: worktree)
    }

    private func git(_ args: [String], in cwd: URL) async throws -> String {
        try await GitOperations.runGit(args, in: cwd)
    }

    private func worktree(_ repo: Repository, _ branch: String) -> URL {
        repo.rootURL.appendingPathComponent(branch, isDirectory: true)
    }

    // MARK: - Pre-check

    /// `initializeStates` is what the sheet runs on appear; every row's
    /// initial badge (and which buttons exist) hangs off it, so all
    /// four classifications matter: dirty worktree, commits ahead,
    /// nothing ahead, and worktree already gone.
    func testInitializeStatesClassifiesEachRepo() async throws {
        let dirty = try await makeRepoWithFeatureWorktree(named: "dirty")
        try write("wip\n", to: "wip.txt", in: worktree(dirty, feature))

        let ahead = try await makeRepoWithFeatureWorktree(named: "ahead")
        try write("done\n", to: "done.txt", in: worktree(ahead, feature))
        try await commitAll(in: worktree(ahead, feature), message: "feature work")

        let clean = try await makeRepoWithFeatureWorktree(named: "clean")

        // Never had a feature worktree at all — e.g. cleaned up in an
        // earlier session, or the folder was removed out-of-band.
        let gone = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "gone", files: ["base.txt": "base\n"]
        )

        let flow = makeFlow(repos: [dirty, ahead, clean, gone])
        await flow.initializeStates()

        XCTAssertEqual(flow.state(for: dirty), .featureDirty)
        XCTAssertEqual(flow.state(for: ahead), .pending)
        XCTAssertEqual(flow.state(for: clean), .upToDate)
        XCTAssertEqual(flow.state(for: gone), .cleanedUp)
    }

    // MARK: - Merge

    /// The core contract: the merge runs `--no-ff` *inside the
    /// default-branch worktree*, so the merged file must land on disk
    /// in `repos/<repo>/main/` and main's log must gain an explicit
    /// merge commit. The feature worktree and branch survive — cleanup
    /// is a separate, user-initiated step.
    func testRunMergeMergesIntoDefaultBranchWorktree() async throws {
        let repo = try await makeRepoWithFeatureWorktree(named: "app")
        try write("payload\n", to: "NOTES.md", in: worktree(repo, feature))
        try await commitAll(in: worktree(repo, feature), message: "feature work")

        let flow = makeFlow(repos: [repo])
        await flow.initializeStates()
        XCTAssertEqual(flow.state(for: repo), .pending)

        await flow.runMerge(for: repo)

        XCTAssertEqual(flow.state(for: repo), .merged)
        let mainWT = worktree(repo, "main")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainWT.appendingPathComponent("NOTES.md").path
        ))
        let log = try await git(["log", "--oneline", "-n", "3"], in: mainWT)
        XCTAssertTrue(log.contains("Merge branch '\(feature)'"), "no merge commit in:\n\(log)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree(repo, feature).path))
    }

    /// "Commit & Merge" must commit the dirty feature worktree with the
    /// workspace name as the fixed message, then continue into the
    /// normal merge — losing either half silently strands user work.
    func testCommitAndMergeCommitsWithWorkspaceNameThenMerges() async throws {
        let repo = try await makeRepoWithFeatureWorktree(named: "app")
        try write("uncommitted\n", to: "WIP.md", in: worktree(repo, feature))

        let flow = makeFlow(repos: [repo])
        await flow.initializeStates()
        XCTAssertEqual(flow.state(for: repo), .featureDirty)

        await flow.commitAndMerge(repo)

        XCTAssertEqual(flow.state(for: repo), .merged)
        XCTAssertNil(flow.commitErrors[repo.name])
        // The auto-commit's subject is the workspace name, and it's now
        // reachable from main via the merge.
        let mainWT = worktree(repo, "main")
        let subjects = try await git(["log", "--format=%s", "-n", "5"], in: mainWT)
        XCTAssertTrue(subjects.contains(feature), "auto-commit missing from:\n\(subjects)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainWT.appendingPathComponent("WIP.md").path
        ))
    }

    /// A conflicted merge must be left in place (MERGE_HEAD intact) with
    /// the conflicted paths surfaced, and the poll pass must flip the
    /// repo to `.merged` once someone resolves and commits — that's the
    /// sheet's promise that out-of-band resolution needs no manual
    /// refresh.
    func testRunMergeSurfacesConflictAndPollDetectsResolution() async throws {
        let repo = try await makeRepoWithFeatureWorktree(
            named: "app", mainFiles: ["shared.txt": "base\n"]
        )
        let mainWT = worktree(repo, "main")
        let featureWT = worktree(repo, feature)
        try write("feature side\n", to: "shared.txt", in: featureWT)
        try await commitAll(in: featureWT, message: "feature side")
        try write("main side\n", to: "shared.txt", in: mainWT)
        try await commitAll(in: mainWT, message: "main side")

        let flow = makeFlow(repos: [repo])
        await flow.initializeStates()
        await flow.runMerge(for: repo)

        XCTAssertEqual(flow.state(for: repo), .conflicted(paths: ["shared.txt"]))
        let probe = await GitOperations.mergeProbe(
            in: mainWT, feature: feature, baseBranch: "main"
        )
        if case .inProgress = probe {} else {
            XCTFail("merge was not left in place for resolution: \(probe)")
        }

        // Resolve like a user (or agent) would in a terminal tab, then
        // let one poll pass observe the completed merge.
        try write("resolved\n", to: "shared.txt", in: mainWT)
        try await commitAll(in: mainWT, message: "Resolve conflict")
        await flow.pollConflictedRepos()
        XCTAssertEqual(flow.state(for: repo), .merged)
    }

    /// "Merge All Pending" walks every repo, taking the Commit & Merge
    /// path for dirty ones and the plain merge for pending ones.
    func testMergeAllPendingHandlesDirtyAndPendingRepos() async throws {
        let dirty = try await makeRepoWithFeatureWorktree(named: "dirty")
        try write("wip\n", to: "wip.txt", in: worktree(dirty, feature))

        let ahead = try await makeRepoWithFeatureWorktree(named: "ahead")
        try write("done\n", to: "done.txt", in: worktree(ahead, feature))
        try await commitAll(in: worktree(ahead, feature), message: "feature work")

        let flow = makeFlow(repos: [dirty, ahead])
        await flow.initializeStates()
        await flow.mergeAllPending()

        XCTAssertEqual(flow.state(for: dirty), .merged)
        XCTAssertEqual(flow.state(for: ahead), .merged)
        XCTAssertFalse(flow.isBatchRunning)
        XCTAssertFalse(flow.hasPending)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree(dirty, "main").appendingPathComponent("wip.txt").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree(ahead, "main").appendingPathComponent("done.txt").path
        ))
    }

    // MARK: - Cleanup

    /// Per-repo cleanup must remove the worktree, force-delete the
    /// branch, and drop the aggregation-dir symlink, firing
    /// `onRepoCleanedUp` after each repo and `onAllCleanedUp` exactly
    /// once after the last — the parent's runner-stopping and
    /// workspace-removal hang off that ordering.
    func testCleanupRemovesWorktreeBranchAndSymlinkAndFiresCallbacksInOrder() async throws {
        let first = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "first", files: ["a.txt": "a\n"]
        )
        let second = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "second", files: ["b.txt": "b\n"]
        )
        // Provision through the real path so the aggregation dir and
        // its symlinks exist exactly as the app creates them.
        let featureDir = try await FeatureProvisioner.provision(
            featureName: feature, in: project, across: [first, second]
        )

        var cleanedRepos: [String] = []
        var allCleanedUpCount = 0
        let flow = makeFlow(
            repos: [first, second],
            onRepoCleanedUp: { cleanedRepos.append($0.name) },
            onAllCleanedUp: { allCleanedUpCount += 1 }
        )

        await flow.cleanup(first)
        XCTAssertEqual(flow.state(for: first), .cleanedUp)
        XCTAssertEqual(cleanedRepos, ["first"])
        XCTAssertEqual(allCleanedUpCount, 0, "fired before every repo was cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree(first, feature).path))
        let branches = try await git(["branch", "--list", feature], in: first.rootURL)
        XCTAssertEqual(branches, "", "branch survived cleanup: \(branches)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: featureDir.appendingPathComponent("first").path
        ))
        // The other repo is untouched until its own cleanup.
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree(second, feature).path))

        await flow.cleanup(second)
        XCTAssertEqual(cleanedRepos, ["first", "second"])
        XCTAssertEqual(allCleanedUpCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree(second, feature).path))
    }
}
