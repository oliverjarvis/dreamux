import XCTest
@testable import Dreamux

/// `SyncStatusStore` against real fixture repos: refresh computes
/// counts, sync fast-forwards, push updates the remote, and failures
/// mark the snapshot instead of vanishing. Fixture helpers mirror
/// `SyncStatusTests`.
@MainActor
final class SyncStatusStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    private let identity = [
        "-c", "user.name=Dreamux Tests",
        "-c", "user.email=tests@dreamux.local",
    ]

    override func setUp() async throws {
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

    // MARK: - Fixtures (same shapes as SyncStatusTests)

    private func makeClonedRepo(
        named name: String
    ) async throws -> (repo: Repository, remote: URL) {
        let seed = sandbox.root.appendingPathComponent("seeds/\(name)", isDirectory: true)
        try await GitFixtures.makeCommittedRepo(at: seed, files: ["base.txt": "base\n"])
        let remotes = sandbox.root.appendingPathComponent("remotes", isDirectory: true)
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
        let remote = remotes.appendingPathComponent("\(name).git", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["clone", "--bare", seed.path, remote.path], in: sandbox.root)
        let repo = try await GitOperations.cloneBare(
            url: remote.path, into: project.rootPath, name: name)
        return (repo, remote)
    }

    private func advanceRemoteMain(_ remote: URL, file: String) async throws {
        let clone = sandbox.root.appendingPathComponent(
            "tmp-\(UUID().uuidString)", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["clone", remote.path, clone.path], in: sandbox.root)
        try "payload\n".write(
            to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await GitOperations.runGit(["add", "-A"], in: clone)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "remote work"], in: clone)
        _ = try await GitOperations.runGit(["push", "origin", "main"], in: clone)
    }

    private func advanceLocalMain(_ repo: Repository, file: String) async throws {
        let worktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)
        try "local\n".write(
            to: worktree.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await GitOperations.runGit(["add", "-A"], in: worktree)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "local work"], in: worktree)
    }

    private func makeStore(_ repos: [Repository]) -> SyncStatusStore {
        SyncStatusStore(repos: { repos })
    }

    // MARK: - Refresh

    func testRefreshWithFetchSeesRemoteCommit() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "behind")
        try await advanceRemoteMain(remote, file: "remote.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .behind(1))
        XCTAssertNotNil(store.snapshot(for: repo.name).lastFetch)
        XCTAssertFalse(store.snapshot(for: repo.name).lastFetchFailed)
    }

    func testRefreshWithoutFetchIsOfflineOnly() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "offline")
        try await advanceRemoteMain(remote, file: "remote.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: false)
        // No fetch — the local remote ref hasn't moved, so still even.
        XCTAssertEqual(store.snapshot(for: repo.name).state, .upToDate)
        XCTAssertNil(store.snapshot(for: repo.name).lastFetch)
    }

    func testNoRemoteRepoIsNoRemote() async throws {
        let repo = try await GitOperations.initBare(into: project.rootPath, name: "loner")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .noRemote)
    }

    func testFetchFailureIsMarkedAndCountsSurvive() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "flaky")
        try await advanceRemoteMain(remote, file: "remote.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .behind(1))

        try FileManager.default.removeItem(at: remote)
        await store.refresh(fetch: true)
        XCTAssertTrue(store.snapshot(for: repo.name).lastFetchFailed)
        // Last-known counts stay — stale beats blank.
        XCTAssertEqual(store.snapshot(for: repo.name).behind, 1)
    }

    // MARK: - Actions

    func testSyncFastForwardsBehindMain() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "syncme")
        try await advanceRemoteMain(remote, file: "remote.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        await store.sync(repo)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .upToDate)
        let landed = FileManager.default.fileExists(
            atPath: repo.rootURL.appendingPathComponent("main/remote.txt").path)
        XCTAssertTrue(landed)
    }

    func testPushPublishesAheadMain() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "pushme")
        try await advanceLocalMain(repo, file: "local.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .ahead(1))
        await store.push(repo)
        XCTAssertEqual(store.snapshot(for: repo.name).state, .upToDate)
        let localTip = try await GitOperations.runGit(
            ["rev-parse", "refs/heads/main"], in: repo.rootURL)
        let remoteTip = try await GitOperations.runGit(
            ["rev-parse", "refs/heads/main"], in: remote)
        XCTAssertEqual(
            localTip.trimmingCharacters(in: .whitespacesAndNewlines),
            remoteTip.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSyncOnDivergedLeavesStateAndSetsNoError() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "stuck")
        try await advanceRemoteMain(remote, file: "remote.txt")
        try await advanceLocalMain(repo, file: "local.txt")
        let store = makeStore([repo])
        await store.refresh(fetch: true)
        await store.sync(repo)
        XCTAssertEqual(
            store.snapshot(for: repo.name).state, .diverged(ahead: 1, behind: 1))
        // Diverged is a state, not an action error.
        XCTAssertNil(store.snapshot(for: repo.name).lastActionError)
    }

    func testSyncAllOnlyTouchesBehindRepos() async throws {
        let (behindRepo, behindRemote) = try await makeClonedRepo(named: "b1")
        try await advanceRemoteMain(behindRemote, file: "remote.txt")
        let (evenRepo, _) = try await makeClonedRepo(named: "b2")
        let store = makeStore([behindRepo, evenRepo])
        await store.refresh(fetch: true)
        await store.syncAll()
        XCTAssertEqual(store.snapshot(for: behindRepo.name).state, .upToDate)
        XCTAssertEqual(store.snapshot(for: evenRepo.name).state, .upToDate)
    }

    // MARK: - Copy

    func testBadgeText() {
        XCTAssertNil(SyncStatusStore.badgeText(behind: 0, ahead: 0))
        XCTAssertEqual(SyncStatusStore.badgeText(behind: 3, ahead: 0), "↓3")
        XCTAssertEqual(SyncStatusStore.badgeText(behind: 0, ahead: 2), "↑2")
        XCTAssertEqual(SyncStatusStore.badgeText(behind: 3, ahead: 1), "↓3 ↑1")
    }

    func testRowText() {
        XCTAssertEqual(SyncStatusStore.rowText(for: .upToDate), "Up to date")
        XCTAssertEqual(SyncStatusStore.rowText(for: .behind(3)), "3 behind")
        XCTAssertEqual(SyncStatusStore.rowText(for: .ahead(2)), "2 to push")
        XCTAssertEqual(
            SyncStatusStore.rowText(for: .diverged(ahead: 1, behind: 2)),
            "Diverged — resolve in terminal")
        XCTAssertEqual(SyncStatusStore.rowText(for: .noRemote), "No remote")
    }

    func testOverviewText() {
        XCTAssertEqual(
            SyncStatusStore.overviewText(behind: 0, ahead: 0), "Up to date with origin")
        XCTAssertEqual(
            SyncStatusStore.overviewText(behind: 3, ahead: 0), "3 behind origin")
        XCTAssertEqual(
            SyncStatusStore.overviewText(behind: 0, ahead: 2), "2 to push")
        XCTAssertEqual(
            SyncStatusStore.overviewText(behind: 1, ahead: 1), "Diverged from origin")
    }

    func testStalenessText() {
        XCTAssertNil(SyncStatusStore.stalenessText(lastFetch: nil, failed: false))
        XCTAssertEqual(
            SyncStatusStore.stalenessText(lastFetch: nil, failed: true),
            "couldn't reach origin")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "couldn't reach origin · last checked \(formatter.string(from: stamp))"
        }()
        XCTAssertEqual(
            SyncStatusStore.stalenessText(lastFetch: stamp, failed: true), expected)
    }
}
