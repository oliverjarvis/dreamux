import XCTest
@testable import Dreamux

/// Workspace-level aggregation and acknowledgement, exercised through
/// `AttentionState` directly so no PTY or Bonsplit controller is needed.
@MainActor
final class WorkspaceAttentionTests: XCTestCase {

    private func blocked() -> AgentAttention {
        .blocked(Blocked(reason: .permission, message: "run npm test",
                         toolName: "Bash", requestID: "t1"))
    }

    func testWorkspaceReportsTheLoudestTab() {
        let quiet = AttentionState(), loud = AttentionState()
        quiet.noteNotification("finished")
        loud.handleControl(verb: "agent-state", json: try! JSONSerialization.data(
            withJSONObject: ["state": "blocked", "reason": "permission"]
        ))
        XCTAssertTrue(
            AttentionAggregate.combine([quiet.value, loud.value]).isBlocked
        )
    }

    func testAcknowledgingOneTabDoesNotTouchAnother() {
        let a = AttentionState(), b = AttentionState()
        a.noteNotification("a finished")
        b.noteNotification("b finished")
        a.acknowledgeIfDone()
        XCTAssertEqual(a.value, AgentAttention.none)
        XCTAssertEqual(b.value, .done(message: "b finished"))
    }

    func testWorkspaceStaysBlockedAfterAcknowledgingEveryTab() {
        let states = [AttentionState(), AttentionState()]
        states[0].noteNotification("done")
        states[1].handleControl(verb: "agent-state", json: try! JSONSerialization.data(
            withJSONObject: ["state": "blocked", "reason": "permission"]
        ))
        states.forEach { $0.acknowledgeIfDone() }
        XCTAssertTrue(AttentionAggregate.combine(states.map(\.value)).isBlocked)
    }

    func testWorkspaceGoesQuietOnceTheHarnessUnblocks() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: try! JSONSerialization.data(
            withJSONObject: ["state": "blocked", "reason": "permission"]
        ))
        state.handleControl(verb: "agent-state", json: try! JSONSerialization.data(
            withJSONObject: ["state": "none"]
        ))
        XCTAssertEqual(AttentionAggregate.combine([state.value]), AgentAttention.none)
    }
}
