import Foundation

/// Rebuilds flow history on launch from signals.db so lanes survive
/// app restarts and capture sessions that ran while Dreamux was
/// closed. Spec: 24 h window, 5,000-signal cap (most recent win).
enum FlowReplayLoader {
    static func events(
        store: SQLiteSignalStore,
        now: Date = Date(),
        window: TimeInterval = 86_400,
        cap: Int = 5_000
    ) async -> [FlowEvent] {
        let since = now.addingTimeInterval(-window)
        var signals: [Signal] = []
        // Replay never uses notifications — they're stale by definition —
        // so exclude them from the cap budget to avoid evicting real events.
        let replayKinds = SignalKind.flowKinds.filter { $0 != SignalKind.sessionNotification }
        for kind in replayKinds {
            // query() filters a single kind; per-kind fetches share the
            // global cap so one chatty kind can't evict the others
            // entirely before the global trim below.
            let batch = (try? await store.query(
                kind: kind, source: nil, projectDir: nil, since: since, limit: cap
            )) ?? []
            signals.append(contentsOf: batch)
        }
        let recentFirst = signals.sorted { $0.ts > $1.ts }.prefix(cap)
        return recentFirst
            .compactMap(ClaudeFlowAdapter.event(from:))
            .filter { if case .notification = $0 { return false }; return true }
            .sorted { $0.at < $1.at }
    }
}
