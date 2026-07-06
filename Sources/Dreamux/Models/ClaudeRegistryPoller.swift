import Foundation

/// 3 s heartbeat over the claude session registry (the
/// PlanQueueController.startPolling shape). The read closure runs off
/// the main actor — registry files are tiny but they're still disk IO —
/// and snapshots are delivered back on the main actor.
@MainActor
final class ClaudeRegistryPoller {
    private let read: @Sendable () -> [ClaudeSessionEntry]
    private let onSnapshot: ([ClaudeSessionEntry]) -> Void
    private var poller: Task<Void, Never>?

    init(
        read: @escaping @Sendable () -> [ClaudeSessionEntry],
        onSnapshot: @escaping ([ClaudeSessionEntry]) -> Void
    ) {
        self.read = read
        self.onSnapshot = onSnapshot
    }

    func startPolling(interval: TimeInterval = 3.0) {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func pollOnce() async {
        let read = self.read
        let entries = await Task.detached(priority: .utility) { read() }.value
        guard !Task.isCancelled else { return }
        onSnapshot(entries)
    }

    deinit { poller?.cancel() }
}
