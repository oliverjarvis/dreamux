import XCTest
@testable import Clayspace

/// Unit tests for `RunnerManager.startPlan(for:)` / `executeStart(_:)`
/// — the decision logic the workspace Play button (and the e2e
/// `startFeature` command) runs through. Play is worktree-centric and
/// never asks: flexible-port runners run alongside other worktrees,
/// fixed-port runners switch (displacing the other worktree's
/// instance). The plan-shape cases need no subprocesses; the
/// switch-live and execute cases spawn short `sleep`-based instances
/// inside the sandbox so a real fixed-port runner is alive on another
/// worktree, matching how the switch arises in the app.
@MainActor
final class StartPlanTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var signals: SignalStore!
    private var manager: RunnerManager!

    override func setUp() async throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
        signals = SignalStore()
        manager = RunnerManager(project: project, signals: signals)
    }

    override func tearDown() async throws {
        // SIGTERM anything still alive before the sandbox dir vanishes
        // from under it. `stop` is per-instance, so walk every key.
        if let manager {
            for (key, status) in manager.statusByInstance where status.isRunning {
                if let runner = manager.runners.first(where: { $0.name == key.runnerName }) {
                    manager.stop(runner, on: key.branch)
                }
            }
            // Give the signals a beat to land — not strictly required,
            // but avoids termination handlers racing sandbox removal.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        manager = nil
        signals = nil
        project = nil
        sandbox?.destroy()
        sandbox = nil
    }

    // MARK: - Fixtures

    /// run.toml with one fixed-port runner (can't run concurrently)
    /// and one env-driven runner (can). Ports in the test-reserved
    /// 46xx range; `sleep` keeps live instances alive long enough to
    /// observe without binding anything.
    private let sampleTOML = """
    [[runners]]
    name = "api"
    cwd = "repos/api/main"
    start = "sleep 5"
    port = 4651

    [[runners]]
    name = "web"
    cwd = "repos/web/main"
    start = "sleep 5"
    port = 4652
    port_env = "WEB_PORT"
    """

    private func runner(named name: String) throws -> ParsedRunner {
        try XCTUnwrap(manager.runners.first { $0.name == name })
    }

    /// Create `repos/<repo>/<branch>/` so a runner's resolved cwd
    /// exists — `Process.run` fails on a missing working directory.
    private func makeWorktreeDir(repo: String, branch: String) throws {
        let dir = project.rootPath
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(branch, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func workspace(_ name: String, repos: [String]) -> Workspace {
        Workspace(name: name, linkedRepoIDs: repos)
    }

    /// Poll until the given instance reports running (executeStart
    /// kicks off an unstructured Task, so the start isn't synchronous
    /// from the caller's perspective).
    private func waitUntilRunning(
        _ runner: ParsedRunner,
        on branch: String,
        timeout: TimeInterval = 3.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if manager.status(for: runner, on: branch)?.isRunning == true { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return manager.status(for: runner, on: branch)?.isRunning == true
    }

    // MARK: - Plan shapes (no processes)

    func testStartPlanWithNoRunnersOpensRunPane() {
        manager.reload(from: nil)
        XCTAssertEqual(
            manager.startPlan(for: workspace("feat", repos: ["api"])),
            .openRunPane
        )
    }

    func testStartPlanScopesToLinkedRunnersAndTargetsWorkspaceBranch() throws {
        manager.reload(from: sampleTOML)
        let plan = manager.startPlan(for: workspace("feat", repos: ["api"]))

        guard case .start(let toStart, let displacing) = plan else {
            return XCTFail("expected .start, got \(plan)")
        }
        XCTAssertEqual(toStart.map(\.name), ["api"])
        XCTAssertTrue(displacing.isEmpty, "nothing is live, so nothing gets displaced")

        // The linked runner must now point at the feature's worktree;
        // the unrelated runner keeps its default branch.
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "api")), "feat")
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "web")), "main")
    }

    func testStartPlanFallsBackToAllRunnersWhenNoneLinked() throws {
        manager.reload(from: sampleTOML)
        let plan = manager.startPlan(for: workspace("feat", repos: ["unrelated"]))

        guard case .start(let toStart, _) = plan else {
            return XCTFail("expected .start, got \(plan)")
        }
        XCTAssertEqual(Set(toStart.map(\.name)), ["api", "web"])

        // Fallback runners aren't linked to the workspace, so their
        // branch targeting must stay untouched.
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "api")), "main")
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "web")), "main")
    }

    /// `runnersAssociated(with:)` / `openableRunners(for:)` feed the
    /// sidebar row's open button on every render, so they must be PURE
    /// — the old association helper pointed runners' active branches at
    /// the workspace as a side effect, which would silently retarget
    /// runners every time the sidebar redrew.
    func testWorkspaceAssociationQueriesArePureAndFilterHeadless() throws {
        let headlessTOML = sampleTOML + """


        [[runners]]
        name = "worker"
        cwd = "repos/worker/main"
        start = "sleep 5"
        """
        manager.reload(from: headlessTOML)

        let associated = manager.runnersAssociated(with: workspace("feat", repos: ["api", "worker"]))
        XCTAssertEqual(Set(associated.map(\.name)), ["api", "worker"])
        // Pure: no branch retargeting happened.
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "api")), "main")
        XCTAssertEqual(manager.currentBranch(for: try runner(named: "worker")), "main")

        // Fallback to every runner when nothing linked has a runner.
        let fallback = manager.runnersAssociated(with: workspace("feat", repos: ["unrelated"]))
        XCTAssertEqual(Set(fallback.map(\.name)), ["api", "web", "worker"])

        // worker has no port and no open target — headless, so the
        // open button must not offer it.
        let openable = manager.openableRunners(for: workspace("feat", repos: ["api", "worker"]))
        XCTAssertEqual(openable.map(\.name), ["api"])
    }

    // MARK: - Switching with a live instance

    /// The product promise, half one: a fixed-port runner live on
    /// another worktree doesn't block Play — the plan reports it as a
    /// displacement, and executing the plan switches the instance over
    /// (old worktree stops, requested worktree runs).
    func testStartPlanSwitchesFixedPortRunnerOffOtherBranch() async throws {
        manager.reload(from: sampleTOML)
        try makeWorktreeDir(repo: "api", branch: "main")
        try makeWorktreeDir(repo: "api", branch: "feat")

        // Bring the fixed-port runner up on its default worktree, the
        // way the user would from another feature's row.
        let api = try runner(named: "api")
        manager.start(api)
        XCTAssertEqual(manager.status(for: api, on: "main")?.isRunning, true)

        let plan = manager.startPlan(for: workspace("feat", repos: ["api"]))
        guard case .start(let toStart, let displacing) = plan else {
            return XCTFail("expected .start, got \(plan)")
        }
        XCTAssertEqual(toStart.map(\.name), ["api"])
        XCTAssertEqual(displacing.map(\.runner.name), ["api"])
        XCTAssertEqual(displacing.map(\.fromBranch), ["main"])

        // Planning is still just planning — nothing starts or stops
        // until the caller executes.
        XCTAssertNil(manager.status(for: api, on: "feat"))
        XCTAssertEqual(manager.status(for: api, on: "main")?.isRunning, true)

        manager.executeStart(toStart)
        let isUp = await waitUntilRunning(api, on: "feat", timeout: 6.0)
        XCTAssertTrue(isUp, "the requested worktree must end up running")
        XCTAssertNotEqual(
            manager.status(for: api, on: "main")?.isRunning, true,
            "the displaced worktree's instance must be stopped — that's the switch"
        )
    }

    /// The product promise, half two: an env-driven runner live on
    /// another worktree doesn't displace anything — both run at once.
    func testStartPlanAllowsConcurrentRunnerAlongsideOtherBranch() async throws {
        manager.reload(from: sampleTOML)
        try makeWorktreeDir(repo: "web", branch: "main")

        let web = try runner(named: "web")
        manager.start(web)
        XCTAssertEqual(manager.status(for: web, on: "main")?.isRunning, true)

        let plan = manager.startPlan(for: workspace("feat", repos: ["web"]))
        guard case .start(let toStart, let displacing) = plan else {
            return XCTFail("expected .start, got \(plan)")
        }
        XCTAssertEqual(toStart.map(\.name), ["web"])
        XCTAssertTrue(displacing.isEmpty, "flexible ports never displace — they run side by side")
    }

    // MARK: - executeStart

    func testExecuteStartBringsLinkedRunnerUpOnFeatureWorktree() async throws {
        manager.reload(from: sampleTOML)
        try makeWorktreeDir(repo: "web", branch: "feat")

        let plan = manager.startPlan(for: workspace("feat", repos: ["web"]))
        guard case .start(let toStart, _) = plan else {
            return XCTFail("expected .start, got \(plan)")
        }
        manager.executeStart(toStart)

        let web = try runner(named: "web")
        let isUp = await waitUntilRunning(web, on: "feat")
        XCTAssertTrue(isUp, "runner never reached .running on the feature branch")

        // Port-env isolation assigns the base port to the first
        // instance and exports it through the runner's env var.
        let key = RunnerInstanceKey(runnerName: "web", branch: "feat")
        XCTAssertEqual(manager.assignedPorts[key], 4652)
    }
}
