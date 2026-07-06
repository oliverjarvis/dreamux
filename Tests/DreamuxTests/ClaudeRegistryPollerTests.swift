import XCTest
@testable import Dreamux

@MainActor
final class ClaudeRegistryPollerTests: XCTestCase {
    private func entry(pid: Int32) -> ClaudeSessionEntry {
        try! JSONDecoder().decode(
            ClaudeSessionEntry.self,
            from: Data(#"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/w","status":"busy","kind":"interactive"}"#.utf8)
        )
    }

    func testPollOnceDeliversSnapshotOnMain() async {
        let expected = [entry(pid: 1), entry(pid: 2)]
        var received: [[ClaudeSessionEntry]] = []
        let poller = ClaudeRegistryPoller(
            read: { expected },
            onSnapshot: { received.append($0) }
        )
        await poller.pollOnce()
        XCTAssertEqual(received, [expected])
    }

    func testStartPollingTicksAndStops() async throws {
        let counter = SendableCounter()
        let poller = ClaudeRegistryPoller(
            read: { counter.increment(); return [] },
            onSnapshot: { _ in }
        )
        poller.startPolling(interval: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000) // ~4 ticks
        poller.stopPolling()
        let after = counter.value
        XCTAssertGreaterThanOrEqual(after, 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(counter.value, after) // no ticks after stop
    }
}

/// Tiny thread-safe counter for cross-actor assertions.
final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
