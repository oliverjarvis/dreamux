import XCTest
@testable import Dreamux

/// The → workspace affordance's visibility rule is the one piece of that
/// row feature worth isolating from the view: it composes a status gate,
/// name resolution, and feature existence. Table-tested directly, mirroring
/// `InitiativeProgressTests`.
final class PlanWorkspacePresenceTests: XCTestCase {
    func testRunningRowWithLiveFeatureOpensIt() {
        XCTAssertEqual(
            PlanWorkspacePresence.workspaceToOpen(
                status: .running, featureName: "gameboy", featureExists: { $0 == "gameboy" }),
            "gameboy")
    }

    func testAwaitingReviewRowWithLiveFeatureOpensIt() {
        // An agent can still be at a gate with every box checked — the
        // affordance survives into awaiting-review.
        XCTAssertEqual(
            PlanWorkspacePresence.workspaceToOpen(
                status: .awaitingReview, featureName: "gameboy", featureExists: { _ in true }),
            "gameboy")
    }

    func testReadyAndInProgressAndMergedNeverShowAffordance() {
        // Only in-flight rows carry a workspace to open; a not-yet-run,
        // detached, or torn-down plan has none.
        for status in [PlanStatus.ready, .inProgress, .merged, .specOnly] {
            XCTAssertNil(
                PlanWorkspacePresence.workspaceToOpen(
                    status: status, featureName: "gameboy", featureExists: { _ in true }),
                "\(status) should not show the affordance")
        }
    }

    func testUnresolvedFeatureNameShowsNothing() {
        XCTAssertNil(
            PlanWorkspacePresence.workspaceToOpen(
                status: .running, featureName: nil, featureExists: { _ in true }))
    }

    func testResolvedNameThatIsNotAWorkspaceShowsNothing() {
        // The ledger/derivation can name a feature that has since been
        // closed — no live workspace, no affordance.
        XCTAssertNil(
            PlanWorkspacePresence.workspaceToOpen(
                status: .running, featureName: "gameboy", featureExists: { _ in false }))
    }
}
