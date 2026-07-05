import XCTest
@testable import Dreamux

/// The absent-key default is the trap: UserDefaults.bool defaults to
/// FALSE, but this feature ships default-ON. The helper is the single
/// sanctioned read path for non-SwiftUI code.
final class WorkflowSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkflowSettings.autoCommitKey)
        super.tearDown()
    }

    func testAutoCommitDefaultsOnWhenKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: WorkflowSettings.autoCommitKey)
        XCTAssertTrue(WorkflowSettings.autoCommitEnabled)
    }

    func testAutoCommitHonorsExplicitOff() {
        UserDefaults.standard.set(false, forKey: WorkflowSettings.autoCommitKey)
        XCTAssertFalse(WorkflowSettings.autoCommitEnabled)
    }
}
