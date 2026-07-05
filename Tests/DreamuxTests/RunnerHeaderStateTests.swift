import XCTest
@testable import Dreamux

/// Pure-logic coverage for the header run cluster's aggregation: the
/// play/stop capsule summary and the services-popover rows. Everything
/// goes through the static functions with fabricated state dictionaries
/// — no subprocess is ever spawned, mirroring RunnerManagerLogicTests.
@MainActor
final class RunnerHeaderStateTests: XCTestCase {

    private func runner(
        name: String = "web",
        port: Int? = nil,
        portEnv: String? = nil,
        open: String? = nil
    ) -> ParsedRunner {
        ParsedRunner(
            name: name, cwd: "repos/\(name)/main", start: "echo hi",
            stop: nil, port: port, portEnv: portEnv, open: open)
    }

    private func key(_ name: String, _ branch: String) -> RunnerInstanceKey {
        RunnerInstanceKey(runnerName: name, branch: branch)
    }

    // MARK: - headerSummary

    /// No run.toml → the capsule's only job is opening the Run pane.
    func testSummaryWithoutConfig() {
        let summary = RunnerManager.headerSummary(
            associated: [], statuses: [:], branch: "feat", hasConfig: false)
        XCTAssertEqual(
            summary,
            HeaderRunSummary(hasConfig: false, runningCount: 0, attention: false))
    }

    /// Only instances on the scope's branch count — a runner alive on
    /// another worktree must not flip the capsule to "running".
    func testSummaryCountsOnlyScopeBranch() {
        let web = runner(name: "web")
        let api = runner(name: "api")
        let statuses: [RunnerInstanceKey: RunnerStatus] = [
            key("web", "feat"): .running(pid: 11),
            key("api", "other"): .running(pid: 22),
        ]
        let summary = RunnerManager.headerSummary(
            associated: [web, api], statuses: statuses, branch: "feat", hasConfig: true)
        XCTAssertEqual(summary.runningCount, 1)
        XCTAssertFalse(summary.attention)
    }

    /// Attention (amber dot): a failed start or a non-zero exit on the
    /// scope's branch. A clean exit is not attention-worthy.
    func testSummaryAttention() {
        let web = runner(name: "web")
        let api = runner(name: "api")
        let db = runner(name: "db")

        let failed = RunnerManager.headerSummary(
            associated: [web],
            statuses: [key("web", "feat"): .failed(message: "port in use")],
            branch: "feat", hasConfig: true)
        XCTAssertTrue(failed.attention)

        let crashed = RunnerManager.headerSummary(
            associated: [api],
            statuses: [key("api", "feat"): .exited(code: 1)],
            branch: "feat", hasConfig: true)
        XCTAssertTrue(crashed.attention)

        let cleanExit = RunnerManager.headerSummary(
            associated: [db],
            statuses: [key("db", "feat"): .exited(code: 0)],
            branch: "feat", hasConfig: true)
        XCTAssertFalse(cleanExit.attention)
    }

    // MARK: - serviceRows

    /// One row per associated runner, in run.toml order; instances the
    /// scope never started show as .idle; the assigned (per-worktree)
    /// port wins over the declared one so the row shows where the
    /// server actually listens.
    func testServiceRowsPortAndStatusResolution() {
        let web = runner(name: "web", port: 3000, portEnv: "WEB_PORT")
        let api = runner(name: "api", port: 4000)
        let rows = RunnerManager.serviceRows(
            associated: [web, api],
            statuses: [key("web", "feat"): .running(pid: 9)],
            assignedPorts: [key("web", "feat"): 3002],
            branch: "feat")

        XCTAssertEqual(rows.map(\.id), ["web@feat", "api@feat"])
        XCTAssertEqual(rows[0].status, .running(pid: 9))
        XCTAssertEqual(rows[0].port, 3002, "assigned per-worktree port wins")
        XCTAssertEqual(rows[1].status, .idle, "never started here → idle")
        XCTAssertEqual(rows[1].port, 4000, "no assignment → declared port")
    }

    // MARK: - otherWorktreeRows

    /// Only *live* instances on other branches appear (a stopped one is
    /// not "invisible running state"); scope-branch instances are the
    /// active list's job; stale statuses whose runner left run.toml are
    /// skipped; output order is deterministic.
    func testOtherWorktreeRows() {
        let web = runner(name: "web", port: 3000)
        let api = runner(name: "api")
        let statuses: [RunnerInstanceKey: RunnerStatus] = [
            key("web", "main"): .running(pid: 1),
            key("web", "feat"): .running(pid: 2),   // scope → excluded
            key("api", "main"): .exited(code: 0),   // dead → excluded
            key("gone", "main"): .running(pid: 3),  // not in run.toml → skipped
        ]
        let rows = RunnerManager.otherWorktreeRows(
            allRunners: [web, api],
            statuses: statuses,
            assignedPorts: [key("web", "main"): 3001],
            excludingBranch: "feat")

        XCTAssertEqual(rows.map(\.id), ["web@main"])
        XCTAssertEqual(rows[0].port, 3001)
        XCTAssertEqual(rows[0].branch, "main")
    }
}
