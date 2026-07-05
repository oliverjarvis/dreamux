import Darwin
import Foundation
import XCTest
@testable import Dreamux

/// Integration tests for `RunnerManager`'s process lifecycle — real
/// subprocesses, real ports. This is the product promise under test:
/// "open the app in that worktree as well, on a different port", so the
/// must-pass case here is two live instances of the same runner serving
/// two worktrees on two ports at once.
///
/// Layout notes:
/// - `RunnerManager` never touches git; it only needs the
///   `repos/<repo>/<branch>/` directory shape. So worktrees here are
///   plain copies of the `Tests/Fixtures/sample-apps/*` directories —
///   faster and more hermetic than building real bare repos.
/// - Each test composes its `run.toml` body inline and feeds it through
///   `reload(from:)`, exactly like `RunConfigStore` does in the app.
/// - Tests run serially within this class; every test that spawns a
///   process registers a teardown that stops all instances and *waits
///   for exit* (SIGKILL as a last resort), so a failing assertion can't
///   leave orphan python servers squatting on the 46xx/47xx ports.
/// - Port bases are spread across the 46xx range per test so a server
///   leaked by one failing test can't masquerade as the next test's
///   server. The cwd embedded in each fixture's JSON response pins
///   responses to the exact sandbox worktree as a second line of
///   defence.
final class RunnerLifecycleTests: XCTestCase {
    private var sandbox: TestSandbox!

    /// Cache-free session for poking the fixture servers. URLSession's
    /// default cache can replay a previous 200 for an identical GET,
    /// which would fake out "is this server still alive?" assertions.
    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
    }

    override func tearDown() {
        sandbox?.destroy()
        sandbox = nil
        super.tearDown()
    }

    // MARK: - 1. Start basics

    @MainActor
    func testStartAssignsBasePortAndServesWorktree() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "basics")
        try installWorktree(app: "portenv-server", branch: "main", project: project)

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4600))
        let runner = try XCTUnwrap(manager.runners.first)
        let key = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")

        manager.start(runner)

        guard case .running(let pid) = manager.statusByInstance[key] ?? .idle else {
            XCTFail("expected .running, got \(String(describing: manager.statusByInstance[key]))")
            return
        }
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(kill(pid, 0), 0, "reported pid should be a live process")
        XCTAssertEqual(manager.assignedPorts[key], 4600, "first instance gets the base port")

        let info = try await fetchServerInfo(port: 4600)
        XCTAssertEqual(info.app, "portenv-server")
        XCTAssertEqual(info.port, 4600, "server should honour the injected PORTENV_SERVER_PORT")
        XCTAssertTrue(
            info.cwd.hasSuffix("repos/portenv-server/main"),
            "server should run from the main worktree, got cwd \(info.cwd)"
        )

        manager.stop(runner)
        try await waitUntil("the instance to exit after stop") {
            if case .exited = manager.statusByInstance[key] ?? .idle { return true }
            return false
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "server process should be gone after stop")
        XCTAssertNil(manager.assignedPorts[key], "assigned port should be released on exit")
    }

    // MARK: - 2. Concurrent two-branch isolation (the must-pass case)

    @MainActor
    func testConcurrentBranchInstancesServeDistinctPorts() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "concurrent")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4600))
        let runner = try XCTUnwrap(manager.runners.first)
        XCTAssertTrue(manager.canRunConcurrently(runner), "port_env runner must allow concurrency")

        manager.start(runner)
        let mainInfo = try await fetchServerInfo(port: 4600)
        XCTAssertTrue(mainInfo.cwd.hasSuffix("repos/portenv-server/main"), "got cwd \(mainInfo.cwd)")

        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)

        let mainKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")
        let featKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "feat-b")
        let liveKeys = manager.statusByInstance.filter { $0.value.isRunning }.keys
        XCTAssertEqual(Set(liveKeys), [mainKey, featKey], "exactly two live instances on distinct keys")
        XCTAssertEqual(manager.assignedPorts[mainKey], 4600)
        XCTAssertEqual(manager.assignedPorts[featKey], 4601, "second instance takes the next offset")

        let featInfo = try await fetchServerInfo(port: 4601)
        XCTAssertEqual(featInfo.port, 4601)
        XCTAssertTrue(
            featInfo.cwd.hasSuffix("repos/portenv-server/feat-b"),
            "each port must serve its own worktree, got cwd \(featInfo.cwd)"
        )

        // Stopping one branch must not disturb the other — that's the
        // whole point of the per-(runner, branch) instance keying.
        manager.stop(runner, on: "feat-b")
        try await waitUntil("the feat-b instance to exit") {
            if case .exited = manager.statusByInstance[featKey] ?? .idle { return true }
            return false
        }
        XCTAssertEqual(manager.statusByInstance[mainKey]?.isRunning, true)
        let survivingMain = try await fetchServerInfo(port: 4600)
        XCTAssertTrue(
            survivingMain.cwd.hasSuffix("repos/portenv-server/main"),
            "main instance should keep serving 4600 after feat-b stops"
        )
    }

    // MARK: - 3. Port reuse after stop

    @MainActor
    func testPortReassignedToLowestFreeOffsetAfterStop() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "port-reuse")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4620))
        let runner = try XCTUnwrap(manager.runners.first)
        let featKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "feat-b")

        manager.start(runner)
        _ = try await fetchServerInfo(port: 4620)
        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)
        XCTAssertEqual(manager.assignedPorts[featKey], 4621)
        _ = try await fetchServerInfo(port: 4621)
        let firstFeatPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "feat-b"))

        // Wait for the exit *and* the port release — allocation reads
        // assignedPorts, which the termination handler cleans up.
        manager.stop(runner, on: "feat-b")
        try await waitUntil("the feat-b instance to exit and release its port") {
            guard case .exited = manager.statusByInstance[featKey] ?? .idle else { return false }
            return manager.assignedPorts[featKey] == nil
        }

        manager.start(runner)
        XCTAssertEqual(
            manager.assignedPorts[featKey], 4621,
            "lowest free offset (base+1, since main holds the base) should be reused"
        )
        let info = try await fetchServerInfo(port: 4621)
        XCTAssertTrue(info.cwd.hasSuffix("repos/portenv-server/feat-b"), "got cwd \(info.cwd)")
        let secondFeatPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "feat-b"))
        XCTAssertNotEqual(secondFeatPid, firstFeatPid, "restarted instance must be a fresh process")
    }

    // MARK: - 4. Restart replaces across branches

    @MainActor
    func testRestartReplacesAllInstancesWithOneOnCurrentBranch() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "restart")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4630))
        let runner = try XCTUnwrap(manager.runners.first)
        let featKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "feat-b")

        manager.start(runner)
        _ = try await fetchServerInfo(port: 4630)
        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)
        _ = try await fetchServerInfo(port: 4631)

        let oldMainPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "main"))
        let oldFeatPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "feat-b"))

        // restart() SIGTERMs every live instance across branches, waits
        // for them to die, then starts fresh on the current branch
        // (still feat-b — the override survives the restart).
        await manager.restart(runner)

        try await waitUntil("both old pids to be reaped") {
            kill(oldMainPid, 0) != 0 && kill(oldFeatPid, 0) != 0
        }
        let live = manager.statusByInstance.filter { $0.value.isRunning }
        XCTAssertEqual(live.count, 1, "restart must leave exactly one live instance")
        XCTAssertEqual(live.first?.key, featKey, "the survivor runs on the runner's current branch")

        let newPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "feat-b"))
        XCTAssertNotEqual(newPid, oldFeatPid)
        XCTAssertNotEqual(newPid, oldMainPid)

        // Old ports were released before the new allocation, so the
        // replacement lands back on the base port.
        XCTAssertEqual(manager.assignedPorts[featKey], 4630)
        let info = try await fetchServerInfo(port: 4630)
        XCTAssertTrue(info.cwd.hasSuffix("repos/portenv-server/feat-b"), "got cwd \(info.cwd)")
    }

    // MARK: - 4b. Scoped restart touches only its own branch

    /// Regression test for the header popover's per-row Restart: it
    /// must scope to the row's own branch, not `restart(_:)`'s
    /// every-branch sweep. For a concurrent-safe (`port_env`) runner
    /// live on two worktrees, restarting one branch's instance must
    /// leave the sibling branch's instance running throughout — same
    /// pid, same port, uninterrupted — while the targeted branch comes
    /// back as a fresh process.
    @MainActor
    func testScopedRestartOnlyReplacesTargetBranchInstance() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "scoped-restart")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4680))
        let runner = try XCTUnwrap(manager.runners.first)
        let mainKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")
        let featKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "feat-b")

        manager.start(runner)
        _ = try await fetchServerInfo(port: 4680)
        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)
        _ = try await fetchServerInfo(port: 4681)

        let oldMainPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "main"))
        let oldFeatPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "feat-b"))

        // Scoped restart targets main only — feat-b must never be
        // touched.
        await manager.restart(runner, on: "main")

        try await waitUntil("the old main pid to be reaped") {
            kill(oldMainPid, 0) != 0
        }
        try await waitUntil("main to come back up on a fresh pid") {
            manager.statusByInstance[mainKey]?.isRunning == true
        }

        XCTAssertEqual(
            kill(oldFeatPid, 0), 0,
            "feat-b's instance must survive a main-scoped restart untouched"
        )
        XCTAssertEqual(
            runningPID(of: manager, runner: "portenv-server", branch: "feat-b"), oldFeatPid,
            "feat-b must still be its original process, not restarted"
        )
        XCTAssertEqual(manager.assignedPorts[featKey], 4681, "feat-b keeps its original port")

        let newMainPid = try XCTUnwrap(runningPID(of: manager, runner: "portenv-server", branch: "main"))
        XCTAssertNotEqual(newMainPid, oldMainPid, "main must be a fresh process after its restart")
        XCTAssertEqual(manager.assignedPorts[mainKey], 4680, "main's port is reused once released")

        let mainInfo = try await fetchServerInfo(port: 4680)
        XCTAssertTrue(mainInfo.cwd.hasSuffix("repos/portenv-server/main"), "got cwd \(mainInfo.cwd)")
        let featInfo = try await fetchServerInfo(port: 4681)
        XCTAssertTrue(
            featInfo.cwd.hasSuffix("repos/portenv-server/feat-b"),
            "feat-b must keep serving its own worktree throughout, got cwd \(featInfo.cwd)"
        )
    }

    // MARK: - 5. Non-concurrent (fixed-port) runner

    @MainActor
    func testFixedPortRunnerCannotRunConcurrentlyAndGetsNoInjectedPort() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "fixedport")
        try installWorktree(app: "fixedport-server", branch: "main", project: project)

        let toml = runnerBlock(
            name: "fixedport-server",
            cwd: "repos/fixedport-server/main",
            start: "python3 server.py",
            port: 4700
        )
        let manager = makeManager(project: project, toml: toml)
        let runner = try XCTUnwrap(manager.runners.first)

        XCTAssertFalse(
            manager.canRunConcurrently(runner),
            "a port without a port_env means instances would collide"
        )

        manager.start(runner)
        XCTAssertTrue(
            manager.assignedPorts.isEmpty,
            "no port_env, so the manager must not inject or track a port"
        )

        let info = try await fetchServerInfo(port: 4700)
        XCTAssertEqual(info.app, "fixedport-server")
        XCTAssertEqual(info.port, 4700, "fixture's hardcoded port, untouched by the manager")
        XCTAssertTrue(info.cwd.hasSuffix("repos/fixedport-server/main"), "got cwd \(info.cwd)")
    }

    // MARK: - 6. Fast-fail detection

    @MainActor
    func testFastFailReflectsExitSpeed() async throws {
        // No python needed — plain `/bin/sh` one-liners. The cwd just
        // has to exist for Process.run, so an empty dir suffices.
        let project = try sandbox.makeProject(named: "fastfail")
        let cwd = project.rootPath.appendingPathComponent("repos/failer/main", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let toml = runnerBlock(name: "fast-failer", cwd: "repos/failer/main", start: "exit 7")
            + runnerBlock(name: "slow-failer", cwd: "repos/failer/main", start: "sleep 4; exit 7")
        let manager = makeManager(project: project, toml: toml)
        let fast = try XCTUnwrap(manager.runners.first { $0.name == "fast-failer" })
        let slow = try XCTUnwrap(manager.runners.first { $0.name == "slow-failer" })

        // Run both side by side so the suite only pays the slow one's
        // 4 seconds once. 4s is deliberately just past the manager's
        // 3s fast-fail threshold — don't be tempted to shrink it.
        manager.start(fast)
        manager.start(slow)

        let fastKey = RunnerInstanceKey(runnerName: "fast-failer", branch: "main")
        let slowKey = RunnerInstanceKey(runnerName: "slow-failer", branch: "main")

        try await waitUntil("fast-failer to exit") {
            if case .exited = manager.statusByInstance[fastKey] ?? .idle { return true }
            return false
        }
        XCTAssertEqual(manager.statusByInstance[fastKey], .exited(code: 7))
        XCTAssertTrue(
            manager.didFastFail(fast, on: "main"),
            "non-zero exit in well under 3s must read as a fast fail"
        )

        try await waitUntil(timeout: 15, "slow-failer to exit") {
            if case .exited = manager.statusByInstance[slowKey] ?? .idle { return true }
            return false
        }
        XCTAssertEqual(manager.statusByInstance[slowKey], .exited(code: 7))
        XCTAssertFalse(
            manager.didFastFail(slow, on: "main"),
            "the same exit code after ~4s of runtime is a normal failure, not a fast fail"
        )
    }

    // MARK: - 7. Stop command safety

    @MainActor
    func testStopCommandSkippedWhileAnotherInstanceIsLive() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "stop-safety")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        // The real fixtures use `pkill -f 'python3 server.py'`, which —
        // if RunnerManager's liveCount<=1 guard ever regressed — would
        // also nuke every other python server on the machine, including
        // other test suites'. A sentinel file proves the exact same
        // thing ("the user stop command ran") without the blast radius.
        let marker = sandbox.root.appendingPathComponent("stop-command-ran")
        let toml = portenvTOML(basePort: 4650, stop: "touch \(marker.path)")
        let manager = makeManager(project: project, toml: toml)
        let runner = try XCTUnwrap(manager.runners.first)
        let mainKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")
        let featKey = RunnerInstanceKey(runnerName: "portenv-server", branch: "feat-b")

        manager.start(runner)
        _ = try await fetchServerInfo(port: 4650)
        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)
        _ = try await fetchServerInfo(port: 4651)

        manager.stop(runner, on: "feat-b")
        try await waitUntil("the feat-b instance to exit") {
            if case .exited = manager.statusByInstance[featKey] ?? .idle { return true }
            return false
        }

        // Grace window before the *negative* assertion: if the guard
        // were broken, stop() would have spawned the command before the
        // SIGTERM, so 500ms is ample time for `touch` to land.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "user stop command must not run while another instance of the runner is live"
        )
        XCTAssertEqual(manager.statusByInstance[mainKey]?.isRunning, true)
        let survivor = try await fetchServerInfo(port: 4650)
        XCTAssertTrue(
            survivor.cwd.hasSuffix("repos/portenv-server/main"),
            "the main instance must survive a targeted stop of its sibling"
        )
    }

    // MARK: - 8. Stop kills the whole process tree

    /// Regression test for "two apps on one port with two PIDs": real
    /// dev servers are process *trees* (sh → npm → node), and
    /// `Process.terminate()` used to SIGTERM only the direct child —
    /// the listener deeper in the tree survived as an orphan, kept the
    /// port bound, and RunnerManager (believing the instance exited)
    /// happily started a second copy against the same port. The
    /// process-group wrapper in `RunnerManager.start` must take the
    /// whole tree down.
    ///
    /// `server.py & wait $!` emulates the npm→node shape deterministically:
    /// the shell cannot exec-optimize away (it must stay parent to run
    /// `wait`), so the listener is always a grandchild of the manager.
    /// A plain compound command is NOT a reliable repro — bash execs
    /// the tail command of `cd x && server` and the kill lands on the
    /// server by luck. We assert on the kernel's view of the port, not
    /// on RunnerManager's bookkeeping — the bookkeeping looked fine
    /// while the bug was live.
    @MainActor
    func testStopKillsWholeProcessTreeForCompoundCommands() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "tree-kill")
        try installWorktree(app: "portenv-server", branch: "main", project: project)

        let toml = runnerBlock(
            name: "portenv-server",
            cwd: "repos/portenv-server/main",
            start: "python3 server.py & wait $!",
            port: 4670,
            portEnv: "PORTENV_SERVER_PORT"
        )
        let manager = makeManager(project: project, toml: toml)
        let runner = try XCTUnwrap(manager.runners.first)
        let key = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")

        manager.start(runner)
        let info = try await fetchServerInfo(port: 4670)
        XCTAssertEqual(info.port, 4670)
        XCTAssertTrue(
            portHasListener(4670),
            "lsof must see the live listener, or the negative assertion below is vacuous"
        )

        manager.stop(runner)
        try await waitUntil("the instance to exit after stop") {
            if case .exited = manager.statusByInstance[key] ?? .idle { return true }
            return false
        }
        try await waitUntil("the port to be released by the (possibly orphaned) server") {
            !portHasListener(4670)
        }
    }

    // MARK: - 9. Auto-open after the server answers

    /// Play fires the runner's `open` target once the port actually
    /// accepts connections — with `{port}` resolved per instance, so
    /// two worktrees open two different URLs. The override hook keeps
    /// real browsers out of the test run; `openedTargets` records the
    /// fires either way.
    @MainActor
    func testAutoOpenFiresPerWorktreeOnceServing() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "auto-open")
        try installWorktree(app: "portenv-server", branch: "main", project: project)
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let toml = portenvTOML(basePort: 4625) + "\nopen = \"http://localhost:{port}/\""
        let manager = makeManager(project: project, toml: toml)
        manager.openOverride = { _ in }
        let runner = try XCTUnwrap(manager.runners.first)

        manager.start(runner)
        try await waitUntil("the first open to fire once 4625 answers") {
            manager.openedTargets == ["http://localhost:4625/"]
        }

        manager.setActiveBranch("feat-b", for: runner)
        manager.start(runner)
        try await waitUntil("the second open to fire with the second worktree's port") {
            manager.openedTargets == ["http://localhost:4625/", "http://localhost:4626/"]
        }
    }

    /// URL targets route in-app first (a browser tab in the branch's
    /// workspace) — the external override must only be consulted when
    /// the in-app handler declines (returns false).
    @MainActor
    func testAutoOpenRoutesURLsInAppWithBranchContext() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "in-app-open")
        try installWorktree(app: "portenv-server", branch: "feat-b", project: project)

        let toml = runnerBlock(
            name: "portenv-server",
            cwd: "repos/portenv-server/feat-b",
            start: "python3 server.py",
            port: 4665,
            portEnv: "PORTENV_SERVER_PORT"
        ) + "\nopen = \"http://localhost:{port}/\""
        let manager = makeManager(project: project, toml: toml)

        var inApp: [(url: String, branch: String)] = []
        var externalFired = false
        manager.openURLInApp = { url, branch, _ in
            inApp.append((url.absoluteString, branch))
            return true
        }
        manager.openOverride = { _ in externalFired = true }

        let runner = try XCTUnwrap(manager.runners.first)
        manager.start(runner)
        try await waitUntil("the in-app route to receive the open") {
            !inApp.isEmpty
        }
        XCTAssertEqual(inApp.first?.url, "http://localhost:4665/")
        XCTAssertEqual(inApp.first?.branch, "feat-b",
                       "the workspace lookup needs the instance's branch")
        XCTAssertFalse(externalFired, "in-app handled it; external must not fire")
        XCTAssertEqual(manager.openedTargets, ["http://localhost:4665/"],
                       "recording happens regardless of routing")
    }

    /// A runner that dies before its port ever answers must not open
    /// anything — no dead browser tabs for fast-failed servers.
    @MainActor
    func testNoAutoOpenWhenRunnerExitsBeforeServing() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "no-open")
        try installWorktree(app: "portenv-server", branch: "main", project: project)

        let toml = runnerBlock(
            name: "portenv-server",
            cwd: "repos/portenv-server/main",
            start: "exit 7",
            port: 4635,
            portEnv: "PORTENV_SERVER_PORT"
        ) + "\nopen = \"http://localhost:{port}/\""
        let manager = makeManager(project: project, toml: toml)
        manager.openOverride = { _ in }
        let runner = try XCTUnwrap(manager.runners.first)
        let key = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")

        manager.start(runner)
        try await waitUntil("the instance to exit") {
            if case .exited = manager.statusByInstance[key] ?? .idle { return true }
            return false
        }
        // The open poller checks every 250ms; give it a couple of
        // cycles to notice the exit and abort before asserting.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(manager.openedTargets.isEmpty,
                      "a fast-failed runner must not open anything")
    }

    // MARK: - 10. Ports already in use by untracked processes

    /// A fixed-port runner must refuse to start when its port is held
    /// by something RunnerManager never spawned (a server launched in
    /// a terminal tab, another app). Spawning anyway either crashes
    /// the server or lets port-hopping dev servers come up elsewhere
    /// while the UI claims the configured port — the "two apps on one
    /// port" report.
    @MainActor
    func testFixedPortStartRefusedWhenPortHeldByForeignProcess() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "busy-fixed")
        try installWorktree(app: "fixedport-server", branch: "main", project: project)

        var squatter: Int32? = try occupyPort(4690)
        defer { if let fd = squatter { Darwin.close(fd) } }

        let toml = runnerBlock(
            name: "fixedport-server",
            cwd: "repos/fixedport-server/main",
            start: "python3 server.py",
            port: 4690
        )
        let manager = makeManager(project: project, toml: toml)
        let runner = try XCTUnwrap(manager.runners.first)
        let key = RunnerInstanceKey(runnerName: "fixedport-server", branch: "main")

        manager.start(runner)
        guard case .failed(let message) = manager.statusByInstance[key] ?? .idle else {
            XCTFail("expected .failed, got \(String(describing: manager.statusByInstance[key]))")
            return
        }
        XCTAssertTrue(message.contains("4690"), "failure should name the contested port")

        // Releasing the port unblocks the same runner without any
        // state surgery — .failed is a retryable state.
        if let fd = squatter { Darwin.close(fd) }
        squatter = nil
        manager.start(runner)
        try await waitUntil("the runner to start once the port is free") {
            manager.statusByInstance[key]?.isRunning == true
        }
    }

    /// Port-isolated runners must skip ports the kernel says are taken
    /// — not just ports RunnerManager itself assigned — when picking
    /// an offset from the base.
    @MainActor
    func testEnvPortAssignmentSkipsForeignListener() async throws {
        try skipUnlessPython3Works()
        let project = try sandbox.makeProject(named: "busy-env")
        try installWorktree(app: "portenv-server", branch: "main", project: project)

        let squatter = try occupyPort(4640)
        defer { Darwin.close(squatter) }

        let manager = makeManager(project: project, toml: portenvTOML(basePort: 4640))
        let runner = try XCTUnwrap(manager.runners.first)
        let key = RunnerInstanceKey(runnerName: "portenv-server", branch: "main")

        manager.start(runner)
        XCTAssertEqual(
            manager.assignedPorts[key], 4641,
            "base port is foreign-held, so the first free offset is base+1"
        )
        let info = try await fetchServerInfo(port: 4641)
        XCTAssertEqual(info.port, 4641)
    }

    /// Bind + listen on a port the way a foreign server would, so the
    /// tests above have something real to collide with. Returns the fd;
    /// callers close it to release the port.
    private func occupyPort(_ port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw PollTimeout(what: "binding test squatter on port \(port)")
        }
        return fd
    }

    /// True while any process holds a LISTEN socket on the port — the
    /// kernel's view, regardless of what RunnerManager believes. This
    /// is exactly the user-visible symptom of the orphan bug: the port
    /// stayed bound by a process nobody was tracking.
    private func portHasListener(_ port: Int) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        probe.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    // MARK: - Fixture plumbing

    /// Copy a sample app from `Tests/Fixtures/sample-apps/<app>/` into
    /// `<project>/repos/<app>/<branch>/`. RunnerManager resolves cwd and
    /// branches purely from this directory shape, so no git involved.
    private func installWorktree(app: String, branch: String, project: Project) throws {
        let repoDir = project.rootPath
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(app, isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: RepoFixtures.sampleApp(app),
            to: repoDir.appendingPathComponent(branch, isDirectory: true)
        )
    }

    /// One `[[runners]]` block in the exact shape `ParsedRunner.parseAll`
    /// understands (see RunSetupView's documented run.toml contract).
    private func runnerBlock(
        name: String,
        cwd: String,
        start: String,
        stop: String? = nil,
        port: Int? = nil,
        portEnv: String? = nil
    ) -> String {
        var lines = [
            "[[runners]]",
            "name = \"\(name)\"",
            "cwd = \"\(cwd)\"",
            "start = \"\(start)\"",
        ]
        if let stop { lines.append("stop = \"\(stop)\"") }
        if let port { lines.append("port = \(port)") }
        if let portEnv { lines.append("port_env = \"\(portEnv)\"") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The portenv fixture reads `PORTENV_SERVER_PORT`, so any base in
    /// the 46xx range works — each test picks its own base so a leaked
    /// server from one test can't answer for another.
    private func portenvTOML(basePort: Int, stop: String? = nil) -> String {
        runnerBlock(
            name: "portenv-server",
            cwd: "repos/portenv-server/main",
            start: "python3 server.py",
            stop: stop,
            port: basePort,
            portEnv: "PORTENV_SERVER_PORT"
        )
    }

    /// Build a manager over the project, load the toml, and — before
    /// anything gets started — register the teardown that guarantees no
    /// fixture server outlives the test, pass or fail.
    @MainActor
    private func makeManager(project: Project, toml: String) -> RunnerManager {
        let manager = RunnerManager(project: project, signals: SignalStore())
        manager.reload(from: toml)
        addTeardownBlock { @MainActor in
            // Stop per instance (never relying on user stop commands —
            // see test 7 for why) and wait for real exits so the next
            // test's ports are genuinely free.
            for runner in manager.runners {
                let liveBranches = manager.statusByInstance
                    .filter { $0.key.runnerName == runner.name && $0.value.isRunning }
                    .map(\.key.branch)
                for branch in liveBranches {
                    manager.stop(runner, on: branch)
                }
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline,
                  manager.statusByInstance.values.contains(where: \.isRunning) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Anything still alive ignored SIGTERM for 10s — force it
            // down rather than leak an orphan into the port range.
            for status in manager.statusByInstance.values {
                if case .running(let pid) = status {
                    kill(pid, SIGKILL)
                }
            }
        }
        return manager
    }

    // MARK: - Process and HTTP helpers

    private struct PollTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    /// Poll `condition` until it holds or `timeout` elapses. The failure
    /// both records (so the test report shows *what* never happened) and
    /// throws (so the test stops instead of cascading misleading
    /// assertion failures).
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(what)", file: file, line: line)
        throw PollTimeout(what: what)
    }

    private struct ServerInfo {
        let app: String
        let cwd: String
        let port: Int
    }

    /// GET the fixture server's JSON, retrying until it binds. Servers
    /// need a beat to come up after Process.run (login shell + python
    /// startup), so connection-refused is an expected transient here.
    /// MainActor-isolated only so the @MainActor tests can call it
    /// without sending non-Sendable `self` across actors — the awaits
    /// inside suspend rather than block, so nothing main-thread-heavy
    /// happens here.
    @MainActor
    private func fetchServerInfo(port: Int, timeout: TimeInterval = 15) async throws -> ServerInfo {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = PollTimeout(what: "any HTTP response on port \(port)")
        while Date() < deadline {
            do {
                let (data, _) = try await Self.httpSession.data(for: request)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let app = object["app"] as? String,
                      let cwd = object["cwd"] as? String,
                      let reportedPort = object["port"] as? Int else {
                    throw PollTimeout(what: "well-formed fixture JSON from port \(port)")
                }
                return ServerInfo(app: app, cwd: cwd, port: reportedPort)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError
    }

    /// Pid of the live instance for (runner, branch), or nil when it
    /// isn't `.running`.
    @MainActor
    private func runningPID(of manager: RunnerManager, runner name: String, branch: String) -> Int32? {
        let key = RunnerInstanceKey(runnerName: name, branch: branch)
        if case .running(let pid) = manager.statusByInstance[key] ?? .idle { return pid }
        return nil
    }

    /// Skip process tests on machines without a working python3. We
    /// probe through the same `/bin/sh -lc` shell RunnerManager uses
    /// rather than just checking `/usr/bin/python3` exists — on macOS
    /// that path is a stub that exists even when the developer tools
    /// (and thus a runnable python3) are missing.
    private func skipUnlessPython3Works() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-lc", "python3 -c 'pass'"]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        do {
            try probe.run()
        } catch {
            throw XCTSkip("could not probe for python3: \(error.localizedDescription)")
        }
        probe.waitUntilExit()
        try XCTSkipUnless(
            probe.terminationStatus == 0,
            "python3 unavailable; skipping process lifecycle test"
        )
    }
}
