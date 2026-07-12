import XCTest
@testable import Dreamux

@MainActor
final class AppStudioIntentsTests: XCTestCase {
    func testConsumeClearsAndReportsOnce() {
        // A fresh instance, not .shared — keeps the singleton clean across tests.
        let intents = AppStudioIntents()
        XCTAssertFalse(intents.consumePendingNewApplet())
        intents.pendingNewApplet = true
        XCTAssertTrue(intents.consumePendingNewApplet())
        XCTAssertFalse(intents.pendingNewApplet)
        XCTAssertFalse(intents.consumePendingNewApplet())
    }
}
