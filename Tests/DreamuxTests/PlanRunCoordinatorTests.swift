import XCTest
@testable import Dreamux

/// Integration test for `PlanRunCoordinator.runPlan` using a real git
/// repo in a `TestSandbox` (via `GitFixtures.makeBareLayoutRepo`, the
/// same helper `FeatureProvisionerTests` uses) — real worktree, real
/// symlink, no mocks. `sendPrompt` is swapped for a capturing closure so
/// the assertion can see the prompt without driving a PTY.
@MainActor
final class PlanRunCoordinatorTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    override func setUp() async throws {
        // Same rationale as FeatureProvisionerTests: initBare's starter
        // commit (and the fixture commit GitFixtures makes on top) need
        // a git identity, which CI/dev machines may not have globally.
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    func testRunPlanProvisionsRecordsAndSendsPrompt() async throws {
        // Real repo so FeatureProvisioner can add a worktree — reuse the
        // GitFixtures helper the provisioner tests use.
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "api", files: ["README.md": "hi"])
        let repoStore = RepoStore(project: project)
        repoStore.refresh()

        try "# X Implementation Plan\n### Task 1: a\n- [ ] **Step 1: t**\n"
            .write(to: {
                let dir = project.rootPath.appendingPathComponent("docs/plans")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent("2026-07-02-x.md")
            }(), atomically: true, encoding: .utf8)

        let docStore = DocStore(project: project)
        docStore.refresh()
        let workspaceStore = WorkspaceStore()
        let coordinator = PlanRunCoordinator(
            project: project, workspaceStore: workspaceStore,
            repoStore: repoStore, docStore: docStore)

        var sentPrompt: String?
        coordinator.sendPrompt = { prompt, _ in sentPrompt = prompt }

        let workspace = try await coordinator.runPlan(
            docStore.plans[0], branchName: "x", repoNames: [repo.name])

        XCTAssertEqual(workspace.name, "x")
        XCTAssertEqual(docStore.ledger.recordForPlan("docs/plans/2026-07-02-x.md")?.featureName, "x")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("features/x/api").path))
        XCTAssertEqual(sentPrompt?.contains("docs/plans/2026-07-02-x.md"), true)
        XCTAssertEqual(workspaceStore.activeID, workspace.id)
    }
}
