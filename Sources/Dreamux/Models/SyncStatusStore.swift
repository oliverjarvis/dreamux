import Foundation

/// Where a repo's local default branch stands relative to
/// `origin/<defaultBranch>` — the verdict behind every sync surface
/// (header chip, main's Overview, sidebar badge, popover rows).
enum RepoSyncState: Equatable {
    case noRemote
    case upToDate
    case behind(Int)
    case ahead(Int)
    case diverged(ahead: Int, behind: Int)

    /// Pure verdict from the probe results. `hasRemote` false wins
    /// regardless of counts — counts against a ref that doesn't exist
    /// are meaningless.
    static func decide(ahead: Int, behind: Int, hasRemote: Bool) -> RepoSyncState {
        guard hasRemote else { return .noRemote }
        switch (ahead > 0, behind > 0) {
        case (false, false): return .upToDate
        case (false, true): return .behind(behind)
        case (true, false): return .ahead(ahead)
        case (true, true): return .diverged(ahead: ahead, behind: behind)
        }
    }
}

/// One repo's last-known sync facts. `state` is derived, everything
/// else is what the probes actually saw — kept even when a later fetch
/// fails, because stale counts beat a blank indicator.
struct RepoSyncSnapshot: Equatable {
    var ahead = 0
    var behind = 0
    var hasRemote = false
    var lastFetch: Date?
    var lastFetchFailed = false
    /// Error from the most recent explicit sync/push on this repo;
    /// cleared by the next success. Diverged is a state, not an error.
    var lastActionError: String?

    var state: RepoSyncState {
        .decide(ahead: ahead, behind: behind, hasRemote: hasRemote)
    }
}

/// The project's one source of truth for "is each repo's default branch
/// current with origin?" — owns the counts, the fetch scheduling, and
/// the sync/push actions, so the header chip, main's Overview, the
/// sidebar badge, and the commit-trail popover all read (and mutate)
/// the same state. Extracted from the views for the same reason
/// `MergeFlow` is: tests and automation drive it without a UI.
@MainActor
@Observable
final class SyncStatusStore {
    private let repos: @MainActor () -> [Repository]
    private(set) var snapshots: [String: RepoSyncSnapshot] = [:]
    /// Repos with a sync/push in flight — surfaces swap their button
    /// for a spinner and refuse double-fires.
    private(set) var busy: Set<String> = []
    /// Injected so the periodic tick only fetches while the app is
    /// frontmost. Wired to `NSApplication.shared.isActive` by
    /// `ProjectWindowContents` — NOT here — the same app-vs-test split
    /// as `ProjectSession.onAutoRunFailure`.
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { true }
    @ObservationIgnored private var refreshInFlight: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(repos: @escaping @MainActor () -> [Repository]) {
        self.repos = repos
    }

    func snapshot(for repoName: String) -> RepoSyncSnapshot {
        snapshots[repoName] ?? RepoSyncSnapshot()
    }

    // MARK: - Refresh

    /// Recompute every repo's counts from local refs; with `fetch`,
    /// refresh `origin/<defaultBranch>` first. Coalesced: a refresh
    /// requested while one is running awaits the running one instead
    /// of stacking a duplicate against the same remotes.
    func refresh(fetch: Bool) async {
        if let refreshInFlight {
            await refreshInFlight.value
            return
        }
        let task = Task { @MainActor in
            for repo in self.repos() {
                await self.refreshRepo(repo, fetch: fetch)
            }
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    private func refreshRepo(_ repo: Repository, fetch: Bool) async {
        var snap = snapshots[repo.name] ?? RepoSyncSnapshot()
        let hasRemote = await GitOperations.remoteURL(in: repo.rootURL) != nil
        snap.hasRemote = hasRemote
        if hasRemote, fetch {
            do {
                _ = try await GitOperations.runGit(
                    ["fetch", "origin", repo.defaultBranch], in: repo.rootURL)
                snap.lastFetch = Date()
                snap.lastFetchFailed = false
            } catch {
                snap.lastFetchFailed = true
            }
        }
        if hasRemote,
           let counts = await GitOperations.aheadBehind(
               branch: repo.defaultBranch, in: repo.rootURL) {
            snap.ahead = counts.ahead
            snap.behind = counts.behind
        } else if snap.lastFetch == nil {
            // Remote configured but origin/<branch> unknown and never
            // fetched — nothing trustworthy to show yet.
            snap.hasRemote = false
        }
        snapshots[repo.name] = snap
    }

    // MARK: - Actions

    /// Fetch + fast-forward the repo's default branch. Diverged is
    /// reported by the resulting state, not attempted.
    func sync(_ repo: Repository) async {
        guard !busy.contains(repo.name) else { return }
        busy.insert(repo.name)
        defer { busy.remove(repo.name) }
        let base = repo.rootURL.appendingPathComponent(
            repo.defaultBranch, isDirectory: true)
        let outcome = await GitOperations.fastForwardFromOrigin(
            branch: repo.defaultBranch, in: base)
        var snap = snapshots[repo.name] ?? RepoSyncSnapshot()
        switch outcome {
        case .synced, .alreadyUpToDate, .diverged:
            snap.lastActionError = nil
            snap.lastFetch = Date()
            snap.lastFetchFailed = false
        case .fetchFailed(let message):
            snap.lastFetchFailed = true
            snap.lastActionError = message
        case .ffFailed(let message):
            snap.lastActionError = message
        }
        snapshots[repo.name] = snap
        await refreshRepo(repo, fetch: false)
    }

    /// Publish an ahead default branch to origin.
    func push(_ repo: Repository) async {
        guard !busy.contains(repo.name) else { return }
        busy.insert(repo.name)
        defer { busy.remove(repo.name) }
        var snap = snapshots[repo.name] ?? RepoSyncSnapshot()
        do {
            try await GitOperations.push(
                branch: repo.defaultBranch, in: repo.rootURL)
            snap.lastActionError = nil
        } catch {
            snap.lastActionError = error.localizedDescription
        }
        snapshots[repo.name] = snap
        await refreshRepo(repo, fetch: false)
    }

    func syncAll() async {
        for repo in repos() where snapshot(for: repo.name).behind > 0 {
            await sync(repo)
        }
    }

    func pushAll() async {
        for repo in repos() {
            let snap = snapshot(for: repo.name)
            if snap.ahead > 0, snap.behind == 0 {
                await push(repo)
            }
        }
    }

    // MARK: - Polling

    /// Slow background freshness while the app is frontmost — the
    /// "teammate merged something" case. Same task-lifecycle shape as
    /// `PRStatusPoller`.
    func startPolling(interval: TimeInterval = 300) {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.isAppActive() {
                    await self.refresh(fetch: true)
                }
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    deinit { poller?.cancel() }

    // MARK: - Aggregates & copy

    var aggregateBehind: Int {
        snapshots.values.reduce(0) { $0 + $1.behind }
    }

    var aggregateAhead: Int {
        snapshots.values.reduce(0) { $0 + $1.ahead }
    }

    /// Compact chip/badge text for the aggregate, `nil` when even.
    var badgeText: String? {
        Self.badgeText(behind: aggregateBehind, ahead: aggregateAhead)
    }

    static func badgeText(behind: Int, ahead: Int) -> String? {
        switch (behind > 0, ahead > 0) {
        case (false, false): return nil
        case (true, false): return "↓\(behind)"
        case (false, true): return "↑\(ahead)"
        case (true, true): return "↓\(behind) ↑\(ahead)"
        }
    }

    /// Popover per-repo row text.
    static func rowText(for state: RepoSyncState) -> String {
        switch state {
        case .noRemote: return "No remote"
        case .upToDate: return "Up to date"
        case .behind(let n): return "\(n) behind"
        case .ahead(let n): return "\(n) to push"
        case .diverged: return "Diverged — resolve in terminal"
        }
    }

    /// Main Overview's sync line.
    static func overviewText(behind: Int, ahead: Int) -> String {
        switch (behind > 0, ahead > 0) {
        case (false, false): return "Up to date with origin"
        case (true, false): return "\(behind) behind origin"
        case (false, true): return "\(ahead) to push"
        case (true, true): return "Diverged from origin"
        }
    }

    /// Staleness note for a repo whose last fetch failed; `nil` while
    /// the remote is reachable.
    static func stalenessText(lastFetch: Date?, failed: Bool) -> String? {
        guard failed else { return nil }
        guard let lastFetch else { return "couldn't reach origin" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "couldn't reach origin · last checked \(formatter.string(from: lastFetch))"
    }
}
