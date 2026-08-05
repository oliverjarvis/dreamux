import XCTest
@testable import Dreamux

final class NotificationHealthTests: XCTestCase {

    func testHealthyShowsNothing() {
        XCTAssertNil(NotificationHealth.healthy.bannerText)
        XCTAssertNil(NotificationHealth.unknown.bannerText)
    }

    func testDeniedTellsTheUserWhereToFixIt() {
        XCTAssertEqual(
            NotificationHealth.denied.bannerText,
            "Notifications are off. Enable Dreamux in System Settings to get agent alerts."
        )
    }

    func testFailureSurfacesTheReason() {
        XCTAssertEqual(
            NotificationHealth.failed("not registered").bannerText,
            "Notifications could not be delivered: not registered"
        )
    }

    func testFailureIsShownEvenWhenAuthorizationLooksFine() {
        // The machine this was written on reports no authorization
        // problem yet is absent from Notification Center entirely, so a
        // delivery failure must never be masked by a healthy status.
        XCTAssertNotNil(NotificationHealth.failed("no bundle registration").bannerText)
    }
}
