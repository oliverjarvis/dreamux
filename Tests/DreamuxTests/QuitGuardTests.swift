import XCTest
@testable import Dreamux

/// A source whose counts the test controls directly.
@MainActor
private final class FakeSource: QuitGuardSource {
    var work: BusyWork
    init(runs: Int = 0, busyTerminals: Int = 0) {
        work = BusyWork(runs: runs, busyTerminals: busyTerminals)
    }
    var busyWork: BusyWork { work }
}

/// Registry + summary logic for the quit guard. Each test uses its own
/// `QuitGuard` instance — `.shared` collects real RunnerManagers created
/// by other test classes in this process, so asserting on it would race.
@MainActor
final class QuitGuardTests: XCTestCase {

    func testNoSourcesIsIdle() {
        XCTAssertNil(QuitGuard().busySummary())
    }

    func testSourceWithNoWorkIsIdle() {
        let guard_ = QuitGuard()
        let source = FakeSource()
        guard_.register(source)
        XCTAssertNil(guard_.busySummary())
    }

    func testDeallocatedSourceDoesNotBlockQuit() {
        let guard_ = QuitGuard()
        var source: FakeSource? = FakeSource(runs: 3)
        guard_.register(source!)
        // Drain the pool: allObjects autoreleases its snapshot, which
        // would otherwise keep the source alive past `source = nil`.
        autoreleasepool {
            XCTAssertNotNil(guard_.busySummary())
        }
        source = nil
        XCTAssertNil(guard_.busySummary(), "weak registry must drop dead sources")
    }

    func testCountsSumAcrossSources() {
        let guard_ = QuitGuard()
        let a = FakeSource(runs: 1)
        let b = FakeSource(runs: 1, busyTerminals: 1)
        guard_.register(a)
        guard_.register(b)
        XCTAssertEqual(guard_.busySummary(), "2 runs and 1 busy terminal will be terminated.")
    }

    func testRegisteringTwiceCountsOnce() {
        let guard_ = QuitGuard()
        let source = FakeSource(runs: 1)
        guard_.register(source)
        guard_.register(source)
        XCTAssertEqual(guard_.busySummary(), "1 run will be terminated.")
    }

    // MARK: - PTY busy decision

    /// A terminal is busy iff a real job owns the foreground: pgid equal
    /// to the shell's is an idle prompt, and <= 0 is tcgetpgrp failing
    /// (dead PTY) — neither should block quit.
    func testForegroundBusyDecision() {
        XCTAssertFalse(PTYShellSession.foregroundIsBusy(foregroundPGID: 500, shellPID: 500))
        XCTAssertTrue(PTYShellSession.foregroundIsBusy(foregroundPGID: 501, shellPID: 500))
        XCTAssertFalse(PTYShellSession.foregroundIsBusy(foregroundPGID: -1, shellPID: 500))
        XCTAssertFalse(PTYShellSession.foregroundIsBusy(foregroundPGID: 0, shellPID: 500))
    }

    func testUnstartedPTYSessionReportsNoBusyWork() {
        XCTAssertEqual(PTYShellSession().busyWork, BusyWork())
    }

    // MARK: - PTY integration (real shell)

    /// Regression: ⌘Q while `claude` (or any foreground job) ran in a
    /// terminal quit without the alert. A real PTY running a real job
    /// must report busy through the real tcgetpgrp path.
    func testRealPTYWithForegroundJobReportsBusy() async throws {
        let session = PTYShellSession()
        session.start()
        defer { session.stop() }

        // Wait for the shell's line editor to come up (zle's init
        // flushes input typed before it's ready).
        for _ in 0..<100 where !session.isQuiescent(for: 0.5) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(session.hasProducedOutput, "shell never came up")
        XCTAssertEqual(session.busyWork, BusyWork(), "idle prompt must not be busy")

        session.send("sleep 30\n")
        var work = BusyWork()
        for _ in 0..<50 {
            work = session.busyWork
            if work.busyTerminals == 1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(work, BusyWork(busyTerminals: 1),
                       "a foreground job must count as a busy terminal")
    }

    // MARK: - RunnerManager source

    func testRunnerManagerCountsRunningInstances() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.destroy() }
        let project = try sandbox.makeProject(named: "quitguard")
        let manager = RunnerManager(project: project, signals: SignalStore())
        XCTAssertEqual(manager.busyWork, BusyWork(), "no instances → no busy work")

        let runner = ParsedRunner(
            name: "sleeper", cwd: nil, start: "sleep 30",
            stop: nil, port: nil, portEnv: nil
        )
        manager.start(runner)
        addTeardownBlock { @MainActor in manager.stop(runner) }
        XCTAssertEqual(manager.busyWork, BusyWork(runs: 1))

        manager.stop(runner)
        // Exit flows back through an async termination handler; poll.
        for _ in 0..<100 where manager.busyWork != BusyWork() {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(manager.busyWork, BusyWork(), "a stopped run must not block quit")
    }

    // MARK: - Wording

    func testSummaryWording() {
        XCTAssertNil(QuitGuard.summaryText(for: BusyWork()))
        XCTAssertEqual(QuitGuard.summaryText(for: BusyWork(runs: 1)),
                       "1 run will be terminated.")
        XCTAssertEqual(QuitGuard.summaryText(for: BusyWork(runs: 2)),
                       "2 runs will be terminated.")
        XCTAssertEqual(QuitGuard.summaryText(for: BusyWork(busyTerminals: 1)),
                       "1 busy terminal will be terminated.")
        XCTAssertEqual(QuitGuard.summaryText(for: BusyWork(busyTerminals: 3)),
                       "3 busy terminals will be terminated.")
        XCTAssertEqual(QuitGuard.summaryText(for: BusyWork(runs: 2, busyTerminals: 1)),
                       "2 runs and 1 busy terminal will be terminated.")
    }
}
