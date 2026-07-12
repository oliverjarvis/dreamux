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
