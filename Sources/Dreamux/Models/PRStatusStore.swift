import Foundation

/// The persistent PR-status axis: latest known `PRLifecycle` + url per
/// feature/branch (== `workspace.name`), plus the set of features worth
/// polling. `@Observable`, so a poll pass that mutates `states`
/// re-renders every view that read `state(for:)`. Lives on ProjectSession,
/// fed by `PRStatusPoller`.
@MainActor
@Observable
final class PRStatusStore {
    struct Entry: Equatable, Sendable {
        var lifecycle: PRLifecycle
        var url: String
        init(lifecycle: PRLifecycle, url: String) { self.lifecycle = lifecycle; self.url = url }
    }

    private(set) var states: [String: Entry] = [:]
    private(set) var tracked: [String: URL] = [:]

    /// Register a feature worth polling (idempotent). Only tracked
    /// features are ever fetched — a plan whose branch was never pushed
    /// never hits gh.
    func track(feature: String, worktreeURL: URL) { tracked[feature] = worktreeURL }

    func untrack(feature: String) {
        tracked.removeValue(forKey: feature)
        states.removeValue(forKey: feature)
    }

    func state(for feature: String) -> Entry? { states[feature] }

    var trackedFeatures: [(feature: String, worktreeURL: URL)] {
        tracked.map { (feature: $0.key, worktreeURL: $0.value) }
    }

    /// Merge one poll pass. Absent features are left as-is so a transient
    /// gh miss can't blank a known PR.
    func apply(_ snapshot: [String: Entry]) {
        for (feature, entry) in snapshot { states[feature] = entry }
    }
}

/// ~10s heartbeat over the tracked PR set — the ClaudeRegistryPoller shape.
/// `tracked` runs on the main actor (reads the store); `fetch` runs off it
/// (gh is network IO); snapshots land back on main. Fetches ONLY tracked
/// features, so an empty tracked set makes zero gh calls.
@MainActor
final class PRStatusPoller {
    private let tracked: @MainActor () -> [(feature: String, worktreeURL: URL)]
    private let fetch: @Sendable (String, URL) async -> PRStatusStore.Entry?
    private let onSnapshot: ([String: PRStatusStore.Entry]) -> Void
    private var poller: Task<Void, Never>?

    init(
        tracked: @escaping @MainActor () -> [(feature: String, worktreeURL: URL)],
        fetch: @escaping @Sendable (String, URL) async -> PRStatusStore.Entry?,
        onSnapshot: @escaping ([String: PRStatusStore.Entry]) -> Void
    ) {
        self.tracked = tracked
        self.fetch = fetch
        self.onSnapshot = onSnapshot
    }

    func startPolling(interval: TimeInterval = 10) {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() { poller?.cancel(); poller = nil }

    func pollOnce() async {
        let items = tracked()
        guard !items.isEmpty else { return }
        var snapshot: [String: PRStatusStore.Entry] = [:]
        for item in items {
            if let entry = await fetch(item.feature, item.worktreeURL) {
                snapshot[item.feature] = entry
            }
        }
        guard !Task.isCancelled else { return }
        onSnapshot(snapshot)
    }

    deinit { poller?.cancel() }
}
