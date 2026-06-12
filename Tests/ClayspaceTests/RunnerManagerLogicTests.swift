import XCTest
@testable import Clayspace

/// Pure-logic coverage for `RunnerManager`: concurrency gating, cwd →
/// repo/branch derivation, branch overrides, branch-folder listing, and
/// `reload(from:)` bookkeeping. No runner subprocess is ever spawned —
/// the one test that touches `start()` points its cwd at a directory
/// that doesn't exist precisely so `Process.run()` throws before a
/// child appears.
@MainActor
final class RunnerManagerLogicTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var manager: RunnerManager!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "logic-proj")
        manager = RunnerManager(project: project, signals: SignalStore())
    }

    override func tearDown() {
        manager = nil
        project = nil
        sandbox?.destroy()
        sandbox = nil
        super.tearDown()
    }

    /// Builder with the canonical detect-output defaults so each test
    /// only spells out the fields it actually cares about.
    private func runner(
        name: String = "web",
        cwd: String? = "repos/web/main",
        start: String = "echo hi",
        stop: String? = nil,
        port: Int? = nil,
        portEnv: String? = nil
    ) -> ParsedRunner {
        ParsedRunner(name: name, cwd: cwd, start: start, stop: stop, port: port, portEnv: portEnv)
    }

    // MARK: - canRunConcurrently

    /// The full gating matrix. The interesting row is the last one:
    /// `port_env = ""` must read as NOT isolatable, because an empty
    /// env-var name means start() can't actually inject a unique port.
    func testCanRunConcurrentlyMatrix() {
        XCTAssertTrue(manager.canRunConcurrently(runner(port: nil)),
                      "no port → nothing to collide on")
        XCTAssertFalse(manager.canRunConcurrently(runner(port: 4670)),
                       "fixed port, no port_env → single instance only")
        XCTAssertTrue(manager.canRunConcurrently(runner(port: 4670, portEnv: "WEB_PORT")),
                      "port + port_env → per-instance ports available")
        XCTAssertFalse(manager.canRunConcurrently(runner(port: 4670, portEnv: "")),
                       "empty port_env can't carry a port; treat as not isolated")
    }

    // MARK: - repoName(for:)

    func testRepoNameAcrossCwdShapes() {
        XCTAssertEqual(manager.repoName(for: runner(cwd: "repos/web/main")), "web")
        XCTAssertEqual(
            manager.repoName(for: runner(cwd: "repos/web/main/packages/api")), "web",
            "monorepo sub-path must still anchor on the segment after 'repos'"
        )
        XCTAssertEqual(
            manager.repoName(for: runner(cwd: "somewhere/web/main")), "web",
            "legacy configs without a 'repos' anchor fall back to the second-to-last segment"
        )
        XCTAssertEqual(
            manager.repoName(for: runner(name: "fallback", cwd: "")), "fallback",
            "unparseable cwd falls back to the runner's own name"
        )
    }

    // MARK: - currentBranch / setActiveBranch

    func testCurrentBranchDerivesFromCwd() {
        XCTAssertEqual(manager.currentBranch(for: runner(cwd: "repos/web/main")), "main")
        XCTAssertEqual(
            manager.currentBranch(for: runner(cwd: "repos/webapp/main/packages/api")), "main",
            "branch is the segment right after the repo, even with a monorepo sub-path"
        )
    }

    func testSetActiveBranchOverridesAndClears() {
        let web = runner(cwd: "repos/web/main")

        manager.setActiveBranch("feat-a", for: web)
        XCTAssertEqual(manager.currentBranch(for: web), "feat-a")

        // Picking the default branch again is equivalent to clearing:
        // the override entry must vanish, not sit there shadowing the
        // (identical, for now) default from run.toml.
        manager.setActiveBranch("main", for: web)
        XCTAssertNil(manager.activeBranches[web.name],
                     "selecting the default must remove the override entry")
        XCTAssertEqual(manager.currentBranch(for: web), "main")

        manager.setActiveBranch("feat-b", for: web)
        XCTAssertEqual(manager.currentBranch(for: web), "feat-b")
        manager.setActiveBranch(nil, for: web)
        XCTAssertNil(manager.activeBranches[web.name])
        XCTAssertEqual(manager.currentBranch(for: web), "main")
    }

    // MARK: - availableBranches

    /// Plain directories are enough here — availableBranches only looks
    /// at the filesystem under repos/<name>/, never at git.
    func testAvailableBranchesSkipsBareAndHiddenAndSortsDefaultFirst() throws {
        let repoDir = project.rootPath
            .appendingPathComponent("repos/web", isDirectory: true)
        for folder in [".bare", ".hidden", "alpha", "beta", "main"] {
            try FileManager.default.createDirectory(
                at: repoDir.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // A stray regular file must not show up as a "branch" either.
        try "not a worktree".write(
            to: repoDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )

        // "main" sorts after alpha/beta alphabetically, so getting it
        // first proves the default-branch pinning actually reorders.
        XCTAssertEqual(
            manager.availableBranches(for: runner(cwd: "repos/web/main")),
            ["main", "alpha", "beta"]
        )
    }

    // MARK: - reload(from:)

    func testReloadKeepsRunnerListInSync() {
        manager.reload(from: """
        [[runners]]
        name = "web"
        start = "echo web"

        [[runners]]
        name = "api"
        start = "echo api"
        """)
        XCTAssertEqual(manager.runners.map(\.name), ["web", "api"])

        manager.reload(from: """
        [[runners]]
        name = "api"
        start = "echo api"
        """)
        XCTAssertEqual(manager.runners.map(\.name), ["api"],
                       "runner removed from the TOML must drop out of the list")

        manager.reload(from: nil)
        XCTAssertEqual(manager.runners, [], "missing run.toml means no runners")
    }

    /// Seed instance status WITHOUT spawning anything: a cwd that
    /// doesn't exist makes `Process.run()` throw, which records a
    /// `.failed` status for the (runner, branch) key. Reload must keep
    /// that entry while the runner stays in the TOML and drop it the
    /// moment the runner disappears — otherwise ghost statuses haunt
    /// renamed runners forever.
    func testReloadDropsStatusForRemovedRunners() {
        let ghost = runner(name: "ghost", cwd: "repos/ghost/main", start: "echo boo")
        manager.start(ghost)
        let seeded = manager.status(for: ghost, on: "main")
        guard case .failed = seeded else {
            return XCTFail("expected a .failed status from the nonexistent cwd, got \(String(describing: seeded))")
        }

        manager.reload(from: """
        [[runners]]
        name = "ghost"
        cwd = "repos/ghost/main"
        start = "echo boo"
        """)
        XCTAssertNotNil(manager.status(for: ghost, on: "main"),
                        "status for a surviving runner must be retained across reload")

        manager.reload(from: """
        [[runners]]
        name = "other"
        start = "echo other"
        """)
        XCTAssertNil(manager.status(for: ghost, on: "main"),
                     "status for a runner removed from the TOML must be dropped")
    }
}
