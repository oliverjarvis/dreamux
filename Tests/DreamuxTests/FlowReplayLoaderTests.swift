import XCTest
@testable import Dreamux

final class FlowReplayLoaderTests: XCTestCase {
    var sandbox: TestSandbox!
    var store: SQLiteSignalStore!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        store = try SQLiteSignalStore(dbURL: sandbox.root.appendingPathComponent("signals.db"))
    }

    override func tearDown() {
        store = nil
        sandbox.destroy()
        sandbox = nil
    }

    private func flowSignal(kind: String, session: String, ts: Date, agent: String = "a1") -> Signal {
        Signal(
            source: "claude.hooks",
            kind: kind,
            ts: ts,
            tags: ["cwd": "/w"],
            payload: .object([
                "session_id": .string(session),
                "agent_id": .string(agent),
            ])
        )
    }

    func testReplayReturnsChronologicalFlowEvents() async {
        let now = Date()
        store.append(flowSignal(kind: SignalKind.agentStopped, session: "s1", ts: now.addingTimeInterval(-10)))
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1", ts: now.addingTimeInterval(-20)))
        store.append(Signal(source: "svc", kind: SignalKind.terminalLine, ts: now, payload: .null)) // foreign — ignored
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "old", ts: now.addingTimeInterval(-100_000))) // outside window

        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 5_000)
        XCTAssertEqual(events.count, 2)
        guard case .agentStarted = events[0], case .agentStopped = events[1] else {
            return XCTFail("expected chronological agentStarted then agentStopped, got \(events)")
        }
    }

    func testReplayHonorsCap() async {
        let now = Date()
        for i in 0..<30 {
            store.append(flowSignal(
                kind: SignalKind.agentStarted, session: "s1",
                ts: now.addingTimeInterval(TimeInterval(-i)), agent: "a\(i)"
            ))
        }
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 10)
        XCTAssertEqual(events.count, 10)
        // Cap keeps the MOST RECENT signals.
        guard case let .agentStarted(_, agentID, _, _, _, _) = events.last! else {
            return XCTFail("expected agentStarted")
        }
        XCTAssertEqual(agentID, "a0")
    }

    func testReplayDropsNotificationEvents() async {
        let now = Date()
        store.append(Signal(
            source: "claude.hooks",
            kind: SignalKind.sessionNotification,
            ts: now.addingTimeInterval(-5),
            tags: ["cwd": "/w"],
            payload: .object(["session_id": .string("s1"), "message": .string("needs permission")])
        ))
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1", ts: now.addingTimeInterval(-4)))
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 5_000)
        XCTAssertEqual(events.count, 1)
        guard case .agentStarted = events[0] else { return XCTFail("notification should be dropped in replay") }
    }

    func testReplayCapAcrossKinds() async {
        let now = Date()
        // 6 older agentStarted + 6 newer agentStopped; cap 8 must keep the
        // 8 most recent ACROSS kinds (6 stopped + 2 newest started).
        for i in 0..<6 {
            store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1",
                                    ts: now.addingTimeInterval(TimeInterval(-100 - i)), agent: "old\(i)"))
        }
        for i in 0..<6 {
            store.append(flowSignal(kind: SignalKind.agentStopped, session: "s1",
                                    ts: now.addingTimeInterval(TimeInterval(-10 - i)), agent: "new\(i)"))
        }
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 8)
        XCTAssertEqual(events.count, 8)
        let startedCount = events.filter { if case .agentStarted = $0 { return true }; return false }.count
        XCTAssertEqual(startedCount, 2)
    }

    func testReplayNotificationsDoNotConsumeCapSlots() async {
        let now = Date()
        // NEWER notification should not evict the OLDER agentStarted from the cap budget.
        store.append(Signal(
            source: "claude.hooks",
            kind: SignalKind.sessionNotification,
            ts: now.addingTimeInterval(-1),
            tags: ["cwd": "/w"],
            payload: .object(["session_id": .string("s1"), "message": .string("needs permission")])
        ))
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1",
                                ts: now.addingTimeInterval(-10), agent: "a1"))
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 1)
        XCTAssertEqual(events.count, 1)
        guard case .agentStarted = events[0] else {
            return XCTFail("cap: 1 must return the agentStarted, not the (dropped) notification")
        }
    }
}
