import XCTest
@testable import Dreamux

final class PlanStatusTests: XCTestCase {
    func testNeverRunIsReady() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 10, hasRun: false, featureExists: false), .ready)
        // A stale feature worktree without a recorded run stays ready —
        // the run ledger is the authority on "this plan was executed".
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: false, featureExists: true), .ready)
    }

    func testRunWithLiveFeatureIsRunning() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: true, featureExists: true), .running)
    }

    func testRunWithoutFeatureAndUncheckedIsInProgress() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 3, total: 10, hasRun: true, featureExists: false), .inProgress)
    }

    func testAllCheckedWithFeatureAwaitsReview() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 10, total: 10, hasRun: true, featureExists: true), .awaitingReview)
    }

    func testAllCheckedFeatureGoneIsMerged() {
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 10, total: 10, hasRun: true, featureExists: false), .merged)
    }

    func testZeroStepPlanNeverCompletes() {
        // Degenerate plan without checkboxes: can run, never auto-merges.
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 0, hasRun: true, featureExists: true), .running)
        XCTAssertEqual(PlanStatusResolver.status(
            checked: 0, total: 0, hasRun: true, featureExists: false), .inProgress)
    }
}
