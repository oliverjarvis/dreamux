import XCTest
@testable import Dreamux

/// The sync-status primitives: the pure `RepoSyncState.decide` verdict
/// and the `aheadBehind` probe it reads. Fixture layout mirrors
/// `PublishFlowTests` minus gh: seed repo → bare "origin" clone → a
/// Dreamux bare+worktree clone inside the project.
final class SyncStatusTests: XCTestCase {
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

    // MARK: - Fixtures

    /// Seed + bare remote + Dreamux clone. Local main starts even with
    /// origin/main.
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

    /// Land one commit on the remote's main via a throwaway clone —
    /// the local repo won't know until it fetches.
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

    /// One commit on the local main worktree.
    private func advanceLocalMain(_ repo: Repository, file: String) async throws {
        let worktree = repo.rootURL.appendingPathComponent("main", isDirectory: true)
        try "local\n".write(
            to: worktree.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await GitOperations.runGit(["add", "-A"], in: worktree)
        _ = try await GitOperations.runGit(
            identity + ["commit", "-m", "local work"], in: worktree)
    }

    // MARK: - decide

    func testDecideNoRemoteWinsRegardlessOfCounts() {
        XCTAssertEqual(RepoSyncState.decide(ahead: 3, behind: 2, hasRemote: false), .noRemote)
    }

    func testDecideZeroZeroIsUpToDate() {
        XCTAssertEqual(RepoSyncState.decide(ahead: 0, behind: 0, hasRemote: true), .upToDate)
    }

    func testDecideBehindOnly() {
        XCTAssertEqual(RepoSyncState.decide(ahead: 0, behind: 2, hasRemote: true), .behind(2))
    }

    func testDecideAheadOnly() {
        XCTAssertEqual(RepoSyncState.decide(ahead: 1, behind: 0, hasRemote: true), .ahead(1))
    }

    func testDecideBothIsDiverged() {
        XCTAssertEqual(
            RepoSyncState.decide(ahead: 1, behind: 2, hasRemote: true),
            .diverged(ahead: 1, behind: 2))
    }

    // MARK: - aheadBehind

    func testFreshCloneIsEven() async throws {
        let (repo, _) = try await makeClonedRepo(named: "even")
        let counts = await GitOperations.aheadBehind(branch: "main", in: repo.rootURL)
        XCTAssertEqual(counts?.ahead, 0)
        XCTAssertEqual(counts?.behind, 0)
    }

    func testRemoteCommitShowsAsBehindAfterFetch() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "behind")
        try await advanceRemoteMain(remote, file: "remote.txt")
        _ = try await GitOperations.runGit(["fetch", "origin", "main"], in: repo.rootURL)
        let counts = await GitOperations.aheadBehind(branch: "main", in: repo.rootURL)
        XCTAssertEqual(counts?.behind, 1)
        XCTAssertEqual(counts?.ahead, 0)
    }

    func testLocalCommitShowsAsAhead() async throws {
        let (repo, _) = try await makeClonedRepo(named: "ahead")
        try await advanceLocalMain(repo, file: "local.txt")
        let counts = await GitOperations.aheadBehind(branch: "main", in: repo.rootURL)
        XCTAssertEqual(counts?.ahead, 1)
        XCTAssertEqual(counts?.behind, 0)
    }

    func testBothSidesShowAsDiverged() async throws {
        let (repo, remote) = try await makeClonedRepo(named: "diverged")
        try await advanceRemoteMain(remote, file: "remote.txt")
        try await advanceLocalMain(repo, file: "local.txt")
        _ = try await GitOperations.runGit(["fetch", "origin", "main"], in: repo.rootURL)
        let counts = await GitOperations.aheadBehind(branch: "main", in: repo.rootURL)
        XCTAssertEqual(counts?.ahead, 1)
        XCTAssertEqual(counts?.behind, 1)
    }

    func testNoRemoteRepoReturnsNil() async throws {
        let repo = try await GitOperations.initBare(into: project.rootPath, name: "loner")
        let counts = await GitOperations.aheadBehind(branch: "main", in: repo.rootURL)
        XCTAssertNil(counts)
    }
}
