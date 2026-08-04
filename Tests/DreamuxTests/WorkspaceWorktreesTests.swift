import XCTest
@testable import Dreamux

/// The resolver every worktree-shaped question routes through. Pure
/// value math plus one existence check, so these are plain unit tests
/// over directories laid down by hand — no git needed.
final class WorkspaceWorktreesTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    /// Lay down `repos/<repo>/<branch>/`.
    @discardableResult
    private func makeWorktree(repo: String, branch: String) throws -> URL {
        let dir = project.rootPath
            .appendingPathComponent("repos/\(repo)/\(branch)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func repo(_ name: String, defaultBranch: String = "main") -> Repository {
        Repository(
            rootURL: project.rootPath.appendingPathComponent("repos/\(name)", isDirectory: true),
            defaultBranch: defaultBranch
        )
    }

    // MARK: - worktreeURL

    func testMainWorkspaceMeansEachRepoOwnDefaultBranch() {
        // The main workspace's display name is only the FIRST repo's
        // default branch, so `name` is the wrong answer for every other
        // repo (WorkspaceSidebar.openMainWorkspace).
        let ws = Workspace(name: "main", linkedRepoIDs: ["web", "api"], isMain: true)

        XCTAssertEqual(
            WorkspaceWorktrees.worktreeURL(for: ws, in: repo("web", defaultBranch: "main")).path,
            project.rootPath.appendingPathComponent("repos/web/main").path)
        XCTAssertEqual(
            WorkspaceWorktrees.worktreeURL(for: ws, in: repo("api", defaultBranch: "master")).path,
            project.rootPath.appendingPathComponent("repos/api/master").path)
    }

    func testFeatureWorkspaceMeansItsOwnName() {
        let ws = Workspace(name: "auth-refresh", linkedRepoIDs: ["web"])
        XCTAssertEqual(
            WorkspaceWorktrees.worktreeURL(for: ws, in: repo("web", defaultBranch: "master")).path,
            project.rootPath.appendingPathComponent("repos/web/auth-refresh").path)
    }

    func testWorktreeURLIsPathArithmeticOnly() {
        // Nothing on disk; the answer is still a well-formed URL.
        let ws = Workspace(name: "ghost", linkedRepoIDs: ["nope"])
        XCTAssertEqual(
            WorkspaceWorktrees.worktreeURL(for: ws, in: repo("nope")).path,
            project.rootPath.appendingPathComponent("repos/nope/ghost").path)
    }

    // MARK: - existing

    func testExistingReturnsPresentWorktreesInLinkedRepoOrder() throws {
        try makeWorktree(repo: "web", branch: "main")
        try makeWorktree(repo: "api", branch: "master")
        let ws = Workspace(name: "main", linkedRepoIDs: ["api", "web"], isMain: true)

        let found = WorkspaceWorktrees.existing(
            for: ws,
            in: [repo("web", defaultBranch: "main"), repo("api", defaultBranch: "master")])

        XCTAssertEqual(found.map(\.lastPathComponent), ["master", "main"])
    }

    func testExistingSkipsMissingWorktreesAndUnknownRepos() throws {
        try makeWorktree(repo: "web", branch: "feat")
        // "api" is linked but has no worktree at this branch; "gone" is
        // linked but the project no longer has the repo at all.
        let ws = Workspace(name: "feat", linkedRepoIDs: ["web", "api", "gone"])

        let found = WorkspaceWorktrees.existing(for: ws, in: [repo("web"), repo("api")])

        XCTAssertEqual(found.map(\.lastPathComponent), ["feat"])
    }

    // MARK: - shellHome

    func testShellHomeDescendsIntoTheSoleWorktree() throws {
        let worktree = try makeWorktree(repo: "web", branch: "feat")
        let ws = Workspace(
            name: "feat",
            workingDirectory: project.rootPath.appendingPathComponent("features/feat").path,
            linkedRepoIDs: ["web"])

        XCTAssertEqual(
            WorkspaceWorktrees.shellHome(for: ws, in: [repo("web")]),
            worktree.path)
    }

    func testShellHomeDescendsForASingleRepoMainWorkspace() throws {
        let worktree = try makeWorktree(repo: "api", branch: "master")
        let ws = Workspace(
            name: "master",
            workingDirectory: project.rootPath.path,
            linkedRepoIDs: ["api"],
            isMain: true)

        XCTAssertEqual(
            WorkspaceWorktrees.shellHome(for: ws, in: [repo("api", defaultBranch: "master")]),
            worktree.path)
    }

    func testShellHomeStaysPutForTwoLinkedReposEvenWhenOneWorktreeExists() throws {
        // The decision keys on how many repos the workspace LINKS, not on
        // how many worktrees happen to be provisioned — otherwise the same
        // workspace answers the same question two different ways depending
        // on provisioning timing.
        try makeWorktree(repo: "web", branch: "feat")
        let aggregation = project.rootPath.appendingPathComponent("features/feat").path
        let ws = Workspace(
            name: "feat", workingDirectory: aggregation, linkedRepoIDs: ["web", "api"])

        XCTAssertEqual(
            WorkspaceWorktrees.shellHome(for: ws, in: [repo("web"), repo("api")]),
            aggregation)
    }

    func testShellHomeStaysPutWhenTheSoleWorktreeIsMissing() {
        let aggregation = project.rootPath.appendingPathComponent("features/feat").path
        let ws = Workspace(name: "feat", workingDirectory: aggregation, linkedRepoIDs: ["web"])

        XCTAssertEqual(
            WorkspaceWorktrees.shellHome(for: ws, in: [repo("web")]),
            aggregation)
    }

    func testShellHomePassesThroughForAWorkspaceWithNoLinkedRepos() {
        let ws = Workspace(name: "scratch", workingDirectory: project.rootPath.path)
        XCTAssertEqual(
            WorkspaceWorktrees.shellHome(for: ws, in: [repo("web")]),
            project.rootPath.path)
    }

    func testShellHomePassesThroughNilWorkingDirectory() {
        let ws = Workspace(name: "scratch")
        XCTAssertNil(WorkspaceWorktrees.shellHome(for: ws, in: []))
    }
}
