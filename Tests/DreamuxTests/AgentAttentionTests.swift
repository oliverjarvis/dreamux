import XCTest
@testable import Dreamux

final class AgentAttentionTests: XCTestCase {

    // MARK: - Aggregation

    func testBlockedOutranksEverything() {
        let states: [AgentAttention] = [
            .done(message: "finished"),
            .working,
            .blocked(Blocked(reason: .permission, message: "run npm test", toolName: "Bash", requestID: "t1")),
            .none,
        ]
        XCTAssertTrue(AttentionAggregate.combine(states).isBlocked)
    }

    func testDoneOutranksWorking() {
        XCTAssertEqual(
            AttentionAggregate.combine([.working, .done(message: "hi"), .none]),
            .done(message: "hi")
        )
    }

    func testWorkingOutranksNone() {
        XCTAssertEqual(AttentionAggregate.combine([.none, .working]), .working)
    }

    func testEmptyAggregatesToNone() {
        XCTAssertEqual(AttentionAggregate.combine([]), AgentAttention.none)
    }

    func testAggregationIsOrderIndependent() {
        let blocked = AgentAttention.blocked(
            Blocked(reason: .question, message: "which?", toolName: nil, requestID: nil)
        )
        XCTAssertEqual(
            AttentionAggregate.combine([blocked, .done(message: "a"), .working]),
            AttentionAggregate.combine([.working, .done(message: "a"), blocked])
        )
    }

    // MARK: - Control payload decoding

    func testDecodesBlockedPermissionPayload() throws {
        let payload: [String: Any] = [
            "harness": "claude",
            "state": "blocked",
            "reason": "permission",
            "message": "Claude wants to run: npm test",
            "tool": "Bash",
            "request_id": "toolu_01ABC",
        ]
        let attention = try XCTUnwrap(AgentAttention(controlPayload: payload))
        guard case .blocked(let blocked) = attention else {
            return XCTFail("expected .blocked, got \(attention)")
        }
        XCTAssertEqual(blocked.reason, .permission)
        XCTAssertEqual(blocked.message, "Claude wants to run: npm test")
        XCTAssertEqual(blocked.toolName, "Bash")
        XCTAssertEqual(blocked.requestID, "toolu_01ABC")
    }

    func testDecodesDonePayload() throws {
        let attention = try XCTUnwrap(
            AgentAttention(controlPayload: ["state": "done", "message": "All tests pass"])
        )
        XCTAssertEqual(attention, .done(message: "All tests pass"))
    }

    func testDecodesWorkingAndNone() throws {
        XCTAssertEqual(try XCTUnwrap(AgentAttention(controlPayload: ["state": "working"])), .working)
        XCTAssertEqual(try XCTUnwrap(AgentAttention(controlPayload: ["state": "none"])), AgentAttention.none)
    }

    func testUnknownStateDecodesToNil() {
        XCTAssertNil(AgentAttention(controlPayload: ["state": "confused"]))
        XCTAssertNil(AgentAttention(controlPayload: [:]))
    }

    func testBlockedWithUnknownReasonFallsBackToQuestion() throws {
        let attention = try XCTUnwrap(
            AgentAttention(controlPayload: ["state": "blocked", "reason": "wat"])
        )
        guard case .blocked(let blocked) = attention else {
            return XCTFail("expected .blocked")
        }
        XCTAssertEqual(blocked.reason, .question)
    }

    func testEmptyStringsDecodeToNilRatherThanEmptyValues() throws {
        let attention = try XCTUnwrap(
            AgentAttention(controlPayload: ["state": "blocked", "reason": "permission",
                                           "message": "", "tool": "", "request_id": ""])
        )
        guard case .blocked(let blocked) = attention else {
            return XCTFail("expected .blocked")
        }
        XCTAssertNil(blocked.message)
        XCTAssertNil(blocked.toolName)
        XCTAssertNil(blocked.requestID)
    }
}
