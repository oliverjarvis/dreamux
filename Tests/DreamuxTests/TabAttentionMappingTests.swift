import XCTest
import Bonsplit
@testable import Dreamux

final class TabAttentionMappingTests: XCTestCase {

    func testEveryAgentAttentionMapsToATabAttention() {
        XCTAssertEqual(TabAttention(AgentAttention.none), .none)
        XCTAssertEqual(TabAttention(.working), .working)
        XCTAssertEqual(TabAttention(.done(message: "ok")), .done)
        XCTAssertEqual(
            TabAttention(.blocked(Blocked(reason: .permission, message: nil,
                                          toolName: nil, requestID: nil))),
            .blocked
        )
    }

    func testBlockedReasonDoesNotChangeTheChip() {
        for reason in [Blocked.Reason.permission, .question, .elicitation, .subagentInput] {
            XCTAssertEqual(
                TabAttention(.blocked(Blocked(reason: reason, message: nil,
                                              toolName: nil, requestID: nil))),
                .blocked,
                "chip shows only that the tab is blocked, not why"
            )
        }
    }
}
