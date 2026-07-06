import XCTest
@testable import Dreamux

final class ClaudeFlowAdapterTests: XCTestCase {
    private func signal(kind: String, payload: [String: SignalPayload], cwd: String? = "/w") -> Signal {
        Signal(
            source: "claude.hooks",
            kind: kind,
            ts: Date(timeIntervalSince1970: 1_000),
            tags: cwd.map { ["cwd": $0] } ?? [:],
            payload: .object(payload)
        )
    }

    func testAgentStarted() {
        let s = signal(kind: SignalKind.agentStarted, payload: [
            "session_id": .string("s1"), "agent_id": .string("a1"),
            "agent_type": .string("Explore"), "description": .string("map repo"),
        ])
        guard case let .agentStarted(sessionID, agentID, agentType, description, cwd, at)? = ClaudeFlowAdapter.event(from: s) else {
            return XCTFail("expected agentStarted")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(agentID, "a1")
        XCTAssertEqual(agentType, "Explore")
        XCTAssertEqual(description, "map repo")
        XCTAssertEqual(cwd, "/w")
        XCTAssertEqual(at, Date(timeIntervalSince1970: 1_000))
    }

    func testAgentStopped() {
        let s = signal(kind: SignalKind.agentStopped, payload: [
            "session_id": .string("s1"), "agent_id": .string("a1"),
        ])
        guard case let .agentStopped(sessionID, agentID, _, _)? = ClaudeFlowAdapter.event(from: s) else {
            return XCTFail("expected agentStopped")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(agentID, "a1")
    }

    func testTaskAndSessionAndNotification() {
        let created = signal(kind: SignalKind.taskCreated, payload: [
            "session_id": .string("s1"), "task_id": .string("7"), "subject": .string("Fix bug"),
        ])
        guard case let .taskCreated(_, taskID, subject, _, _)? = ClaudeFlowAdapter.event(from: created) else {
            return XCTFail("expected taskCreated")
        }
        XCTAssertEqual(taskID, "7")
        XCTAssertEqual(subject, "Fix bug")

        let completed = signal(kind: SignalKind.taskCompleted, payload: [
            "session_id": .string("s1"), "task_id": .string("7"),
        ])
        guard case .taskCompleted? = ClaudeFlowAdapter.event(from: completed) else {
            return XCTFail("expected taskCompleted")
        }

        let stopped = signal(kind: SignalKind.sessionStopped, payload: ["session_id": .string("s1")])
        guard case .sessionStopped? = ClaudeFlowAdapter.event(from: stopped) else {
            return XCTFail("expected sessionStopped")
        }

        let notif = signal(kind: SignalKind.sessionNotification, payload: [
            "session_id": .string("s1"), "message": .string("needs permission"),
        ])
        guard case let .notification(_, message, _, _)? = ClaudeFlowAdapter.event(from: notif) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(message, "needs permission")
    }

    func testMissingSessionIDOrForeignKindIsNil() {
        XCTAssertNil(ClaudeFlowAdapter.event(from: signal(kind: SignalKind.agentStarted, payload: [:])))
        XCTAssertNil(ClaudeFlowAdapter.event(from: signal(kind: SignalKind.terminalLine, payload: [
            "session_id": .string("s1"),
        ])))
    }

    func testEventAccessors() {
        let s = signal(kind: SignalKind.sessionStopped, payload: ["session_id": .string("s1")], cwd: "/w2")
        let event = ClaudeFlowAdapter.event(from: s)!
        XCTAssertEqual(event.at, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(event.cwd, "/w2")
    }
}
