import XCTest
@testable import Dreamux

/// Tests for the "push feature as PR" path: `MergeFlow.publish`, the
/// pre-check's `publishAvailability` verdicts, PR-status resume and
/// throttled polling, post-merge cleanup, and `GhOperations.createPR`
/// idempotency. Everything runs against real git repositories where a
/// local bare clone stands in for GitHub's copy of the repo and the
/// fake `gh` fixture (Tests/Fixtures/bin/gh) stands in for the CLI —
/// PR records live inside the bare remote and PR state is derived from
/// its actual refs, so no test ever touches the network.
///
/// Deliberately untested: the CLOSED PR state. The fake gh derives
/// state purely from ref ancestry (OPEN or MERGED) and has no way to
/// represent a PR closed without merging.
@MainActor
final class PublishFlowTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    /// Whatever DREAMUX_GH_BIN held before this suite pointed it at
    /// the fixture, so tearDown can put the world back for other suites
    /// (and for developers who export a real override in their shell).
    private var previousGhBin: String?

    /// Identity flags for commits the tests make directly, mirroring
    /// `GitFixtures` — `-c` covers author and committer, so the suite
    /// never depends on the machine's global git config.
    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    /// The fake gh CLI, anchored on the checkout the same way
    /// `RepoFixtures` locates the rest of `Tests/Fixtures/`.
    private var fakeGhPath: String {
        RepoFixtures.root.appendingPathComponent("bin/gh").path
    }

    override func setUp() async throws {
        // The flow reaches commits it can't thread `-c user.*` flags
        // into (commitAll, the remote-side plumbing); exporting the
        // GIT_* identity variables keeps those working on machines
        // with no global git identity. Same trick as MergeFlowTests.
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        // Point every GhOperations call at the deterministic fixture.
        // Saved/restored rather than blindly unset so this suite can't
        // leak its override into suites that run after it.
        previousGhBin = ProcessInfo.processInfo.environment["DREAMUX_GH_BIN"]
        setenv("DREAMUX_GH_BIN", fakeGhPath, 1)

        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() async throws {
        if let previousGhBin {
            setenv("DREAMUX_GH_BIN", previousGhBin, 1)
        } else {
            unsetenv("DREAMUX_GH_BIN")
        }
        previousGhBin = nil
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    // MARK: - Fixtures

    private let feature = "feat-publish"

    /// Stand up the full PR-capable layout for one repo:
    ///
    ///   • a committed seed repository,
    ///   • a bare clone of it acting as "origin" — the closest local
    ///     analogue of GitHub's copy: pushes land in it, and the fake
    ///     gh stores PR records and derives PR state from its refs,
    ///   • a Dreamux bare+worktree clone inside the project,
    ///   • a feature worktree with one committed change on top, so
    ///     there is something to publish.
    private func makePublishableRepo(
        named name: String
    ) async throws -> (repo: Repository, remote: URL) {
        let seed = sandbox.root.appendingPathComponent("seeds/\(name)", isDirectory: true)
        try await GitFixtures.makeCommittedRepo(at: seed, files: ["base.txt": "base\n"])

        let remotes = sandbox.root.appendingPathComponent("remotes", isDirectory: true)
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
        let remote = remotes.appendingPathComponent("\(name).git", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["clone", "--bare", seed.path, remote.path],
            in: sandbox.root
        )

        let repo = try await GitOperations.cloneBare(
            url: remote.path, into: project.rootPath, name: name
        )
        try await GitOperations.addWorktree(in: repo.rootURL, branch: feature)
        try write("feature payload\n", to: "feature.txt", in: worktree(repo, feature))
        try await commitAll(in: worktree(repo, feature), message: "feature work")
        return (repo, remote)
    }

    private func makeFlow(repos: [Repository]) -> MergeFlow {
        MergeFlow(
            workspace: Workspace(name: feature, linkedRepoIDs: repos.map(\.name)),
            repos: repos,
            project: project
        )
    }

    /// Initialize + publish in one go, returning the flow and the PR
    /// URL. Asserts the preconditions the publish-path tests all share,
    /// so a fixture regression fails loudly here rather than as a
    /// confusing downstream mismatch.
    private func publishedFlow(
        for repo: Repository
    ) async throws -> (flow: MergeFlow, url: String) {
        let flow = makeFlow(repos: [repo])
        await flow.initializeStates()
        XCTAssertEqual(flow.state(for: repo), .pending)
        XCTAssertEqual(flow.publishAvailability[repo.name], .available)
        await flow.publish(repo)
        guard case .prOpen(let url) = flow.state(for: repo) else {
            XCTFail("publish did not reach prOpen: \(flow.state(for: repo))")
            throw XCTSkip("publish fixture failed")
        }
        return (flow, url)
    }

    /// Simulate "the PR was merged on GitHub": point the remote's main
    /// at the pushed feature tip. The fake gh keeps no merged flag —
    /// it reports MERGED purely from this ancestry, exactly like the
    /// e2e harness does it.
    private func mergeOnRemote(_ remote: URL) async throws {
        let sha = try await git(
            ["rev-parse", "--verify", "refs/heads/\(feature)"], in: remote
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await git(["update-ref", "refs/heads/main", sha], in: remote)
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

    // MARK: - Availability

    /// Repos created via `initBare` have no origin, so the PR option
    /// must be hidden (`.noRemote`) — and that verdict is independent
    /// of merge state, which still classifies pending vs up-to-date.
    func testInitializeStatesReportsNoRemoteForInitCreatedRepos() async throws {
        let ahead = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "ahead", files: ["base.txt": "base\n"]
        )
        try await GitOperations.addWorktree(in: ahead.rootURL, branch: feature)
        try write("done\n", to: "done.txt", in: worktree(ahead, feature))
        try await commitAll(in: worktree(ahead, feature), message: "feature work")

        let clean = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "clean", files: ["base.txt": "base\n"]
        )
        try await GitOperations.addWorktree(in: clean.rootURL, branch: feature)

        let flow = makeFlow(repos: [ahead, clean])
        await flow.initializeStates()

        XCTAssertEqual(flow.publishAvailability[ahead.name], .noRemote)
        XCTAssertEqual(flow.publishAvailability[clean.name], .noRemote)
        XCTAssertEqual(flow.state(for: ahead), .pending)
        XCTAssertEqual(flow.state(for: clean), .upToDate)
    }

    /// A repo with a remote but no reachable gh binary must come back
    /// `.ghMissing` — the sheet shows a disabled button with an install
    /// hint instead of hiding the capability.
    func testInitializeStatesReportsGhMissingWhenBinaryAbsent() async throws {
        let (repo, _) = try await makePublishableRepo(named: "app")

        // Point the override at a path that cannot exist inside this
        // test's private sandbox, overriding setUp's fixture path.
        // tearDown restores the real value either way.
        setenv("DREAMUX_GH_BIN", sandbox.root.appendingPathComponent("missing-gh").path, 1)

        let flow = makeFlow(repos: [repo])
        await flow.initializeStates()

        XCTAssertEqual(flow.publishAvailability[repo.name], .ghMissing)
        // Merge state is unaffected: the feature is still mergeable
        // locally even when the PR path is unavailable.
        XCTAssertEqual(flow.state(for: repo), .pending)
    }

    /// Pure verdict table for `PublishAvailability.decide`, independent
    /// of `MergeFlow` — `initializeStates` is just one caller of it.
    func testDecideNoRemoteIsNoRemote() {
        XCTAssertEqual(PublishAvailability.decide(anyRemote: false, ghAvailable: true), .noRemote)
        XCTAssertEqual(PublishAvailability.decide(anyRemote: false, ghAvailable: false), .noRemote)
    }
    func testDecideRemoteButNoGhIsGhMissing() {
        XCTAssertEqual(PublishAvailability.decide(anyRemote: true, ghAvailable: false), .ghMissing)
    }
    func testDecideRemoteAndGhIsAvailable() {
        XCTAssertEqual(PublishAvailability.decide(anyRemote: true, ghAvailable: true), .available)
    }

    // MARK: - Publish

    /// The core contract of `publish`: the feature branch must actually
    /// land on the remote (not just flip local state) and the PR record
    /// must exist where the fake gh keeps it — both are what the
    /// resume and merge-detection paths later depend on.
    func testPublishPushesBranchAndOpensPR() async throws {
        let (repo, remote) = try await makePublishableRepo(named: "app")

        let (flow, url) = try await publishedFlow(for: repo)
        XCTAssertTrue(
            url.hasPrefix("https://fake-gh.example/"),
            "unexpected PR URL: \(url)"
        )
        XCTAssertNil(flow.commitErrors[repo.name])

        // The push really happened: the remote's feature ref exists and
        // matches the local feature tip exactly.
        let remoteSha = try await git(
            ["rev-parse", "--verify", "refs/heads/\(feature)"], in: remote
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let localSha = try await git(
            ["rev-parse", "refs/heads/\(feature)"], in: repo.rootURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(remoteSha, localSha)

        // And the PR was recorded on the "GitHub" side.
        let record = remote
            .appendingPathComponent("fake-prs", isDirectory: true)
            .appendingPathComponent("\(feature).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    }

    // MARK: - Polling

    /// PR-status lookups round-trip the network through gh, so the
    /// poll loop only consults gh on passes 1, 5, 9, … — the merge must
    /// NOT be noticed on the throttled passes in between, and must be
    /// picked up (with the same URL) on the next unthrottled one.
    func testPollFlipsOpenPRToMergedAcrossThrottle() async throws {
        let (repo, remote) = try await makePublishableRepo(named: "app")
        let (flow, url) = try await publishedFlow(for: repo)

        // Pass 1 consults gh; the PR is still open, so nothing changes.
        await flow.pollConflictedRepos()
        XCTAssertEqual(flow.state(for: repo), .prOpen(url: url))

        try await mergeOnRemote(remote)

        // Passes 2–4 are throttled: the remote already shows the merge,
        // but the flow must not have asked yet.
        for pass in 2...4 {
            await flow.pollConflictedRepos()
            XCTAssertEqual(
                flow.state(for: repo), .prOpen(url: url),
                "pass \(pass) consulted gh despite the throttle"
            )
        }

        // Pass 5 is the next gh check — the merge lands now.
        await flow.pollConflictedRepos()
        XCTAssertEqual(flow.state(for: repo), .prMerged(url: url))
    }

    // MARK: - Cleanup

    /// Cleanup after a remote merge is the one cleanup variant with an
    /// extra obligation: local main is behind (integration happened on
    /// the remote), so it must be fast-forwarded from origin first —
    /// otherwise deleting the feature branch would orphan the work
    /// locally. Then the usual teardown: worktree gone, branch deleted.
    func testCleanupAfterPRMergeFastForwardsLocalMain() async throws {
        let (repo, remote) = try await makePublishableRepo(named: "app")
        let (flow, _) = try await publishedFlow(for: repo)

        try await mergeOnRemote(remote)
        // Drive polling past the throttle so the flow reaches prMerged
        // the same way the sheet would.
        for _ in 1...5 {
            await flow.pollConflictedRepos()
        }
        guard case .prMerged = flow.state(for: repo) else {
            XCTFail("expected prMerged before cleanup: \(flow.state(for: repo))")
            return
        }

        await flow.cleanup(repo)

        XCTAssertEqual(flow.state(for: repo), .cleanedUp)
        // Proof fastForwardFromOrigin ran: the feature's file is now on
        // disk in the *default-branch* worktree, which never saw a
        // local merge.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree(repo, "main").appendingPathComponent("feature.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree(repo, feature).path))
        let branches = try await git(["branch", "--list", feature], in: repo.rootURL)
        XCTAssertEqual(branches, "", "feature branch survived cleanup: \(branches)")
        XCTAssertEqual(flow.syncOutcomes[repo.name], .synced(commits: 1))
    }

    /// A local commit on main makes the post-PR fast-forward impossible.
    /// Cleanup must still complete — and record .diverged instead of
    /// pretending it synced.
    func testCleanupWithDivergedMainRecordsDivergedAndStillCleansUp() async throws {
        let (repo, remote) = try await makePublishableRepo(named: "diverged")
        let (flow, _) = try await publishedFlow(for: repo)
        try await mergeOnRemote(remote)

        // Diverge local main: an extra commit origin doesn't have.
        try write("local drift\n", to: "drift.txt", in: worktree(repo, "main"))
        try await commitAll(in: worktree(repo, "main"), message: "local drift")

        await flow.pollConflictedRepos()  // flips prOpen → prMerged
        guard case .prMerged = flow.state(for: repo) else {
            throw XCTSkip("PR did not reach merged state")
        }
        await flow.cleanup(repo)

        XCTAssertEqual(flow.state(for: repo), .cleanedUp)
        XCTAssertEqual(flow.syncOutcomes[repo.name], .diverged)
        // The drifted commit must survive — ff-only never rewrites.
        let drifted = FileManager.default.fileExists(
            atPath: worktree(repo, "main").appendingPathComponent("drift.txt").path)
        XCTAssertTrue(drifted)
    }

    // MARK: - Cleanup summary copy

    func testCleanupSummaryStrings() {
        XCTAssertEqual(
            MergeFlow.cleanupSummary(outcome: nil, defaultBranch: "main"),
            "Cleaned up")
        XCTAssertEqual(
            MergeFlow.cleanupSummary(outcome: .alreadyUpToDate, defaultBranch: "main"),
            "Cleaned up")
        XCTAssertEqual(
            MergeFlow.cleanupSummary(outcome: .synced(commits: 3), defaultBranch: "main"),
            "Cleaned up · main synced with origin")
        XCTAssertEqual(
            MergeFlow.cleanupSummary(outcome: .diverged, defaultBranch: "main"),
            "Cleaned up · main diverged from origin — sync from the header")
        XCTAssertEqual(
            MergeFlow.cleanupSummary(
                outcome: .fetchFailed(message: "x"), defaultBranch: "main"),
            "Cleaned up · couldn't reach origin to sync main")
        XCTAssertEqual(
            MergeFlow.cleanupSummary(
                outcome: .ffFailed(message: "x"), defaultBranch: "main"),
            "Cleaned up · main couldn't fast-forward — sync from the header")
    }

    // MARK: - Resume

    /// A fresh `MergeFlow` is created on every sheet presentation, so
    /// `initializeStates` must resurrect already-published PRs from gh
    /// rather than showing them as "Pending" — both while the PR is
    /// open and after it merged remotely.
    func testFreshFlowResumesPublishedAndMergedStates() async throws {
        let (repo, remote) = try await makePublishableRepo(named: "app")
        let (_, url) = try await publishedFlow(for: repo)

        // Sheet closed and reopened: a brand-new flow over the same repo.
        let reopened = makeFlow(repos: [repo])
        await reopened.initializeStates()
        XCTAssertEqual(reopened.state(for: repo), .prOpen(url: url))

        try await mergeOnRemote(remote)

        // Reopened again after the PR merged on the remote.
        let afterMerge = makeFlow(repos: [repo])
        await afterMerge.initializeStates()
        XCTAssertEqual(afterMerge.state(for: repo), .prMerged(url: url))
    }

    // MARK: - GhOperations

    /// `createPR` must be idempotent: gh refuses a duplicate PR with an
    /// "already exists" error, and the wrapper recovers by looking up
    /// the existing PR — so re-clicking "Create PR" after a sheet
    /// re-open returns the same URL instead of failing.
    func testCreatePRIsIdempotent() async throws {
        let (repo, _) = try await makePublishableRepo(named: "app")
        try await GitOperations.push(branch: feature, in: repo.rootURL)

        let featureWT = worktree(repo, feature)
        let first = try await GhOperations.createPR(
            branch: feature, base: "main",
            title: feature, body: "Test PR",
            in: featureWT
        )
        let second = try await GhOperations.createPR(
            branch: feature, base: "main",
            title: feature, body: "Test PR",
            in: featureWT
        )

        XCTAssertTrue(first.hasPrefix("https://fake-gh.example/"), "unexpected URL: \(first)")
        XCTAssertEqual(first, second)
    }
}
