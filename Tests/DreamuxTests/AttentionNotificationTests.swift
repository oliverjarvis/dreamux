import XCTest
@testable import Dreamux

final class AttentionNotificationTests: XCTestCase {
    private let workspaceID = UUID()
    private let tabID = UUID()

    private func make(
        _ attention: AgentAttention,
        hasVerifiedPermissionRecipe: Bool = false
    ) -> AttentionNotification? {
        AttentionNotification.make(
            workspaceName: "feature-x",
            workspaceID: workspaceID,
            tabID: tabID,
            tabTitle: "shell",
            harnessDisplayName: "Claude Code",
            attention: attention,
            hasVerifiedPermissionRecipe: hasVerifiedPermissionRecipe
        )
    }

    private func permission(_ requestID: String? = "toolu_1") -> AgentAttention {
        .blocked(Blocked(reason: .permission, message: "Claude wants to run: npm test",
                         toolName: "Bash", requestID: requestID))
    }

    func testWorkingAndNoneNeverProduceABanner() {
        XCTAssertNil(make(.working))
        XCTAssertNil(make(.none))
    }

    func testBlockedIsTimeSensitiveAndDoneIsNot() throws {
        XCTAssertEqual(try XCTUnwrap(make(permission())).urgency, .timeSensitive)
        XCTAssertEqual(try XCTUnwrap(make(.done(message: "ok"))).urgency, .active)
    }

    func testOneRequestIdentifierPerTabSoBannersReplaceRatherThanStack() throws {
        let a = try XCTUnwrap(make(permission()))
        let b = try XCTUnwrap(make(.done(message: "ok")))
        XCTAssertEqual(a.identifier, b.identifier)
        XCTAssertEqual(a.identifier, "dreamux.attention.\(tabID.uuidString)")
    }

    func testBannersGroupByWorkspace() throws {
        XCTAssertEqual(
            try XCTUnwrap(make(permission())).threadIdentifier,
            workspaceID.uuidString
        )
    }

    func testPermissionUsesTheActionableCategoryOnlyWithAVerifiedRecipe() throws {
        XCTAssertEqual(
            try XCTUnwrap(make(permission(), hasVerifiedPermissionRecipe: true)).categoryIdentifier,
            NotificationCategoryID.blockedPermission
        )
        XCTAssertEqual(
            try XCTUnwrap(make(permission(), hasVerifiedPermissionRecipe: false)).categoryIdentifier,
            NotificationCategoryID.blocked
        )
    }

    func testNonPermissionBlocksNeverGetApproveDeny() throws {
        let question = AgentAttention.blocked(
            Blocked(reason: .question, message: "which one?", toolName: nil, requestID: "r1")
        )
        XCTAssertEqual(
            try XCTUnwrap(make(question, hasVerifiedPermissionRecipe: true)).categoryIdentifier,
            NotificationCategoryID.blocked
        )
    }

    func testPermissionWithoutARequestIDCannotBeActedOn() throws {
        XCTAssertEqual(
            try XCTUnwrap(make(permission(nil), hasVerifiedPermissionRecipe: true)).categoryIdentifier,
            NotificationCategoryID.blocked,
            "no request id means no staleness check, so no acting from the banner"
        )
    }

    func testDoneUsesTheDoneCategory() throws {
        XCTAssertEqual(
            try XCTUnwrap(make(.done(message: "ok"))).categoryIdentifier,
            NotificationCategoryID.done
        )
    }

    func testContentNamesTheWorkspaceHarnessAndTab() throws {
        let banner = try XCTUnwrap(make(permission()))
        XCTAssertEqual(banner.title, "feature-x")
        XCTAssertEqual(banner.subtitle, "Claude Code · shell")
        XCTAssertEqual(banner.body, "Claude wants to run: npm test")
    }

    func testMissingMessageFallsBackToTheReason() throws {
        let banner = try XCTUnwrap(make(
            .blocked(Blocked(reason: .permission, message: nil, toolName: nil, requestID: nil))
        ))
        XCTAssertEqual(banner.body, "Waiting for a permission decision")

        let done = try XCTUnwrap(make(.done(message: nil)))
        XCTAssertEqual(done.body, "Finished")
    }

    func testUserInfoCarriesEverythingTheClickHandlerNeeds() throws {
        let banner = try XCTUnwrap(make(permission()))
        XCTAssertEqual(banner.userInfo["workspaceID"], workspaceID.uuidString)
        XCTAssertEqual(banner.userInfo["tabID"], tabID.uuidString)
        XCTAssertEqual(banner.userInfo["requestID"], "toolu_1")
        XCTAssertEqual(banner.userInfo["harness"], "Claude Code")
    }
}
