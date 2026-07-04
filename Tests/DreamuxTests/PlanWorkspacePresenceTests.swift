import XCTest
@testable import Dreamux

/// The → workspace affordance's visibility rule is the one piece of that
/// row feature worth isolating from the view: it composes name resolution
/// and feature existence (deliberately status-independent — see the
/// resolver's doc comment). Table-tested directly, mirroring
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

    func testEveryStatusShowsAffordanceWhileWorkspaceExists() {
        // With the Features list retired, this affordance is the only
        // path to a plan-backed workspace's terminals — so it must show
        // wherever Merge/Close/run-controls do (workspace exists),
        // including the `.ready`-with-live-worktree record-loss window.
        for status in [PlanStatus.ready, .inProgress, .running,
                       .awaitingReview, .merged, .specOnly] {
            XCTAssertEqual(
                PlanWorkspacePresence.workspaceToOpen(
                    status: status, featureName: "gameboy", featureExists: { _ in true }),
                "gameboy",
                "\(status) with a live workspace must keep the affordance")
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
