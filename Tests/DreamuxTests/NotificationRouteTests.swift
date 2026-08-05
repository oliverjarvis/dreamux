import XCTest
import UserNotifications
@testable import Dreamux

final class NotificationRouteTests: XCTestCase {
    private let workspaceID = UUID()
    private let tabID = UUID()

    private func userInfo(requestID: String = "toolu_1") -> [AnyHashable: Any] {
        [
            "workspaceID": workspaceID.uuidString,
            "tabID": tabID.uuidString,
            "requestID": requestID,
            "harness": "Claude Code",
        ]
    }

    func testDefaultActionDecodesAsOpen() throws {
        let route = try XCTUnwrap(NotificationRoute(
            userInfo: userInfo(),
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
        XCTAssertEqual(route.intent, .open)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, tabID)
        XCTAssertEqual(route.requestID, "toolu_1")
    }

    func testApproveAndDenyDecode() throws {
        XCTAssertEqual(
            try XCTUnwrap(NotificationRoute(userInfo: userInfo(),
                                            actionIdentifier: NotificationActionID.approve)).intent,
            .approve
        )
        XCTAssertEqual(
            try XCTUnwrap(NotificationRoute(userInfo: userInfo(),
                                            actionIdentifier: NotificationActionID.deny)).intent,
            .deny
        )
    }

    func testDismissDecodes() throws {
        XCTAssertEqual(
            try XCTUnwrap(NotificationRoute(userInfo: userInfo(),
                                            actionIdentifier: NotificationActionID.dismiss)).intent,
            .dismiss
        )
    }

    func testMalformedUserInfoDecodesToNil() {
        XCTAssertNil(NotificationRoute(userInfo: [:], actionIdentifier: "x"))
        XCTAssertNil(NotificationRoute(userInfo: ["workspaceID": "not-a-uuid", "tabID": tabID.uuidString],
                                       actionIdentifier: "x"))
    }

    // MARK: - The staleness gate

    private func blocked(_ requestID: String?) -> AgentAttention {
        .blocked(Blocked(reason: .permission, message: "Claude wants to run: npm test",
                         toolName: "Bash", requestID: requestID))
    }

    private func route(_ intent: NotificationRoute.Intent, requestID: String = "toolu_1") -> NotificationRoute {
        NotificationRoute(workspaceID: workspaceID, tabID: tabID,
                          requestID: requestID, intent: intent)
    }

    func testApproveResolvesToAKeystrokeWhenTheRequestStillMatches() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.approve),
                                       attention: blocked("toolu_1"),
                                       approve: "y\r", deny: "n\r"),
            .send("y\r")
        )
    }

    func testDenyResolvesToItsOwnKeystroke() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.deny),
                                       attention: blocked("toolu_1"),
                                       approve: "y\r", deny: "n\r"),
            .send("n\r")
        )
    }

    func testStaleRequestIDFocusesInsteadOfActing() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.approve, requestID: "toolu_OLD"),
                                       attention: blocked("toolu_NEW"),
                                       approve: "y\r", deny: "n\r"),
            .focus,
            "a banner must never answer a prompt that has already moved on"
        )
    }

    func testAlreadyAnsweredPromptFocusesInsteadOfActing() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.approve),
                                       attention: .working,
                                       approve: "y\r", deny: "n\r"),
            .focus
        )
    }

    func testMissingRecipeFocusesInsteadOfActing() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.approve),
                                       attention: blocked("toolu_1"),
                                       approve: nil, deny: nil),
            .focus
        )
    }

    func testOpenAlwaysFocuses() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.open),
                                       attention: blocked("toolu_1"),
                                       approve: "y\r", deny: "n\r"),
            .focus
        )
    }

    func testDismissResolvesToDismiss() {
        XCTAssertEqual(
            NotificationRouter.resolve(route: route(.dismiss),
                                       attention: blocked("toolu_1"),
                                       approve: "y\r", deny: "n\r"),
            .dismiss
        )
    }
}
