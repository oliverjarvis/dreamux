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
}
