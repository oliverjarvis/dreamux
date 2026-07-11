import XCTest
@testable import Dreamux

final class RunHeroStateTests: XCTestCase {
    func testMergedIsDoneWithNoPrimary() {
        let s = RunHeroState.resolve(status: .merged, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .merged)
        XCTAssertEqual(s.flow, .done)
        XCTAssertTrue(s.progressComplete)
        XCTAssertEqual(s.primary, .noPrimary)
        XCTAssertEqual(s.pillText, "Merged")
    }

    func testAwaitingReviewOffersReviewAndMerge() {
        let s = RunHeroState.resolve(status: .awaitingReview, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .awaitingReview)
        XCTAssertEqual(s.flow, .waiting)
        XCTAssertTrue(s.progressComplete)
        XCTAssertEqual(s.primary, .reviewAndMerge)
        XCTAssertEqual(s.pillText, "Awaiting your review")
    }

    func testRunningWithLiveAgent() {
        let s = RunHeroState.resolve(status: .running, hasLiveAgent: true)
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.flow, .running)
        XCTAssertFalse(s.progressComplete)
        XCTAssertEqual(s.primary, .running)
        XCTAssertEqual(s.pillText, "Running")
    }

    func testRunningWithoutAgentIsPaused() {
        let s = RunHeroState.resolve(status: .running, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.flow, .queued)
        XCTAssertEqual(s.primary, .run)
        XCTAssertEqual(s.pillText, "Paused")
    }

    func testInProgressWithoutAgentIsPaused() {
        let s = RunHeroState.resolve(status: .inProgress, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.primary, .run)
    }

    func testInProgressWithAgentRuns() {
        let s = RunHeroState.resolve(status: .inProgress, hasLiveAgent: true)
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.primary, .running)
    }

    func testReadyIsRunnable() {
        let s = RunHeroState.resolve(status: .ready, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.flow, .queued)
        XCTAssertEqual(s.primary, .run)
        XCTAssertEqual(s.pillText, "Ready to run")
    }

    func testSpecOnlyFallsBackToReady() {
        let s = RunHeroState.resolve(status: .specOnly, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.primary, .run)
    }
}
