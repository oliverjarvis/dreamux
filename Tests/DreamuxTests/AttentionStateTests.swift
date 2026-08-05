import XCTest
@testable import Dreamux

@MainActor
final class AttentionStateTests: XCTestCase {

    private func control(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testAgentStateVerbSetsValue() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control(["state": "working"]))
        XCTAssertEqual(state.value, .working)
    }

    func testOtherVerbsAreIgnored() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control(["state": "working"]))
        state.handleControl(verb: "session-start", json: control(["state": "none"]))
        XCTAssertEqual(state.value, .working, "only agent-state may move attention")
    }

    func testUndecodablePayloadLeavesValueUntouched() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control(["state": "working"]))
        state.handleControl(verb: "agent-state", json: Data("not json".utf8))
        state.handleControl(verb: "agent-state", json: control(["state": "nonsense"]))
        XCTAssertEqual(state.value, .working)
    }

    // MARK: - Acknowledgement rules

    func testVisitingClearsDone() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control(["state": "done", "message": "ok"]))
        state.acknowledgeIfDone()
        XCTAssertEqual(state.value, AgentAttention.none)
    }

    func testVisitingDoesNotClearBlocked() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control([
            "state": "blocked", "reason": "permission", "message": "run npm test",
        ]))
        state.acknowledgeIfDone()
        XCTAssertTrue(state.value.isBlocked, "a prompt still on screen must keep reading as blocked")
    }

    func testDismissClearsBlocked() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control([
            "state": "blocked", "reason": "permission",
        ]))
        state.dismiss()
        XCTAssertEqual(state.value, AgentAttention.none)
    }

    func testHarnessClearsBlockedWithATerminalEvent() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control([
            "state": "blocked", "reason": "permission",
        ]))
        state.handleControl(verb: "agent-state", json: control(["state": "working"]))
        XCTAssertEqual(state.value, .working)
    }

    func testVisitingDoesNotClearWorking() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control(["state": "working"]))
        state.acknowledgeIfDone()
        XCTAssertEqual(state.value, .working)
    }

    // MARK: - Unadapted harnesses

    func testBareNotificationBecomesDone() {
        let state = AttentionState()
        state.noteNotification("Build finished")
        XCTAssertEqual(state.value, .done(message: "Build finished"))
    }

    func testBareNotificationNeverDowngradesABlock() {
        let state = AttentionState()
        state.handleControl(verb: "agent-state", json: control([
            "state": "blocked", "reason": "permission",
        ]))
        state.noteNotification("some chatter")
        XCTAssertTrue(state.value.isBlocked)
    }
}
