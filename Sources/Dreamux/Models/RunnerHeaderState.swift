import Foundation

/// Snapshot driving the header's play/stop capsule for the active
/// workspace. `runningCount` counts associated runners with a live
/// instance on the scope's branch; `attention` is true when any scope
/// instance failed to start or exited non-zero — the capsule renders
/// it as an amber dot.
struct HeaderRunSummary: Equatable {
    var hasConfig: Bool
    var runningCount: Int
    var attention: Bool
}

/// One row in the header's services popover: a runner pinned to a
/// specific branch, with its live status and the port it actually
/// listens on (per-worktree assignment first, declared port second).
struct HeaderServiceRow: Identifiable, Equatable {
    let runner: ParsedRunner
    let branch: String
    let status: RunnerStatus
    let port: Int?
    var id: String { "\(runner.name)@\(branch)" }
}

/// Header aggregation lives in static functions so the exact logic the
/// capsule renders is unit-testable with fabricated dictionaries. The
/// instance conveniences feed them live state.
extension RunnerManager {

    // MARK: - Pure aggregation

    static func headerSummary(
        associated: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        branch: String,
        hasConfig: Bool
    ) -> HeaderRunSummary {
        var running = 0
        var attention = false
        for runner in associated {
            switch statuses[RunnerInstanceKey(runnerName: runner.name, branch: branch)] {
            case .running:
                running += 1
            case .failed:
                attention = true
            case .exited(let code) where code != 0:
                attention = true
            default:
                break
            }
        }
        return HeaderRunSummary(
            hasConfig: hasConfig, runningCount: running, attention: attention)
    }

    static func serviceRows(
        associated: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        assignedPorts: [RunnerInstanceKey: Int],
        branch: String
    ) -> [HeaderServiceRow] {
        associated.map { runner in
            let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
            return HeaderServiceRow(
                runner: runner,
                branch: branch,
                status: statuses[key] ?? .idle,
                port: assignedPorts[key] ?? runner.port)
        }
    }

    static func otherWorktreeRows(
        allRunners: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        assignedPorts: [RunnerInstanceKey: Int],
        excludingBranch branch: String
    ) -> [HeaderServiceRow] {
        var rows: [HeaderServiceRow] = []
        for (key, status) in statuses
        where status.isRunning && key.branch != branch {
            // A status can outlive its runner (removed from run.toml
            // while running is prevented by reload's cleanup, but be
            // defensive) — no definition, no row.
            guard let runner = allRunners.first(where: { $0.name == key.runnerName })
            else { continue }
            rows.append(HeaderServiceRow(
                runner: runner,
                branch: key.branch,
                status: status,
                port: assignedPorts[key] ?? runner.port))
        }
        return rows.sorted {
            ($0.runner.name, $0.branch) < ($1.runner.name, $1.branch)
        }
    }

    // MARK: - Live conveniences (what HeaderRunControls calls)

    func headerSummary(for workspace: Workspace) -> HeaderRunSummary {
        Self.headerSummary(
            associated: runnersAssociated(with: workspace),
            statuses: statusByInstance,
            branch: workspace.name,
            hasConfig: !runners.isEmpty)
    }

    func serviceRows(for workspace: Workspace) -> [HeaderServiceRow] {
        Self.serviceRows(
            associated: runnersAssociated(with: workspace),
            statuses: statusByInstance,
            assignedPorts: assignedPorts,
            branch: workspace.name)
    }

    func otherWorktreeRows(excluding workspace: Workspace) -> [HeaderServiceRow] {
        Self.otherWorktreeRows(
            allRunners: runners,
            statuses: statusByInstance,
            assignedPorts: assignedPorts,
            excludingBranch: workspace.name)
    }
}
