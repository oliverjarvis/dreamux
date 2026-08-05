import XCTest
@testable import Dreamux

/// Where a shell a WorkspaceSession opens actually starts. The whole
/// behaviour change is `handleDidCreateTab`'s cwd line, so these tests
/// drive real tab creation and read `TabSession.cwd` back.
final class WorkspaceSessionShellHomeTests: XCTestCase {
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

    /// Create a plain shell tab the way ⌘T does, and report its cwd.
    @MainActor
    private func newShellCwd(in session: WorkspaceSession) -> String? {
        session.createTab()
        guard let id = session.lastCreatedTabID else { return nil }
        return session.tabSession(for: id)?.cwd
    }

    @MainActor
    func testNewShellDescendsIntoTheSoleWorktree() throws {
        let worktree = try makeWorktree(repo: "web", branch: "feat")
        let session = WorkspaceSession(workspace: Workspace(
            name: "feat",
            workingDirectory: project.rootPath.appendingPathComponent("features/feat").path,
            linkedRepoIDs: ["web"]))
        session.repositories = { [self.repo("web")] }

        XCTAssertEqual(newShellCwd(in: session), worktree.path)
    }

    @MainActor
    func testMultiRepoWorkspaceKeepsItsAggregationDirectory() throws {
        try makeWorktree(repo: "web", branch: "feat")
        try makeWorktree(repo: "api", branch: "feat")
        let aggregation = project.rootPath.appendingPathComponent("features/feat").path
        let session = WorkspaceSession(workspace: Workspace(
            name: "feat", workingDirectory: aggregation, linkedRepoIDs: ["web", "api"]))
        session.repositories = { [self.repo("web"), self.repo("api")] }

        XCTAssertEqual(newShellCwd(in: session), aggregation)
    }

    @MainActor
    func testMissingWorktreeFallsBackToTheWorkingDirectory() {
        let aggregation = project.rootPath.appendingPathComponent("features/feat").path
        let session = WorkspaceSession(workspace: Workspace(
            name: "feat", workingDirectory: aggregation, linkedRepoIDs: ["web"]))
        session.repositories = { [self.repo("web")] }

        XCTAssertEqual(newShellCwd(in: session), aggregation)
    }

    @MainActor
    func testUnwiredSessionKeepsTodaysBehaviour() {
        // Default `repositories` is `{ [] }` — a session nobody wired up
        // resolves to no worktrees and stays where it always started.
        let session = WorkspaceSession(workspace: Workspace(
            name: "feat", workingDirectory: project.rootPath.path, linkedRepoIDs: ["web"]))

        XCTAssertEqual(newShellCwd(in: session), project.rootPath.path)
    }

    @MainActor
    func testAgentTabOverrideStillWins() throws {
        try makeWorktree(repo: "web", branch: "feat")
        let aggregation = project.rootPath.appendingPathComponent("features/feat").path
        let session = WorkspaceSession(workspace: Workspace(
            name: "feat", workingDirectory: aggregation, linkedRepoIDs: ["web"]))
        session.repositories = { [self.repo("web")] }

        // Plan runs, the composer, run-config, idea intake and the merge
        // UI all go through an explicit cwd. That must beat shellHome.
        let returned = session.openAgentTab(
            at: aggregation, title: "plan: x", icon: "text.badge.checkmark")
        XCTAssertEqual(returned?.cwd, aggregation)

        // And the override is consumed, not sticky: the next plain shell
        // resolves to the worktree again.
        XCTAssertEqual(
            newShellCwd(in: session),
            project.rootPath.appendingPathComponent("repos/web/feat").path)
    }

    @MainActor
    func testStoreWiresEachSessionToItsProjectRepositories() throws {
        let worktree = try makeWorktree(repo: "web", branch: "feat")
        let store = WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        store.repositories = { [self.repo("web")] }
        let workspace = Workspace(
            name: "feat",
            workingDirectory: project.rootPath.appendingPathComponent("features/feat").path,
            linkedRepoIDs: ["web"])

        let session = store.session(for: workspace)

        XCTAssertEqual(newShellCwd(in: session), worktree.path)
    }
}
