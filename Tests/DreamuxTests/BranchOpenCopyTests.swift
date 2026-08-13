import XCTest
@testable import Dreamux

/// The picker's copy is the contract — the empty states have to name the
/// situation ("no branches in *this repo*", "add a repository first")
/// rather than render a blank list, and the fetch note must never read as
/// an error. Pinned exactly as `IdeaIntakeCopyTests` pins the intake copy.
final class BranchOpenCopyTests: XCTestCase {
    func testSheetCopyNamesTheSituation() {
        XCTAssertEqual(BranchOpenSheet.title, "Open Branch")
        XCTAssertEqual(
            BranchOpenSheet.fetchFailedNote,
            "Couldn't reach origin — showing last-known branches.")
        XCTAssertEqual(BranchOpenSheet.refreshingNote, "Updating from origin…")
        XCTAssertEqual(
            BranchOpenSheet.noRepositoriesMessage,
            "Add a repository before opening a branch.")
        XCTAssertEqual(
            BranchOpenSheet.noBranchesMessage(repoNames: ["dreamux"]),
            "No other branches in dreamux.")
    }

    func testConfirmButtonSaysWhatItWillDo() {
        // Provisioning and activating are different actions; the button
        // says which one this row gets.
        XCTAssertEqual(BranchOpenSheet.openButtonTitle, "Open")
        XCTAssertEqual(BranchOpenSheet.activateButtonTitle, "Activate")
    }

    func testBadgesDistinguishWhereABranchLives() {
        XCTAssertEqual(BranchOpenSheet.localBadge, "local")
        XCTAssertEqual(BranchOpenSheet.remoteBadge, "origin")
        XCTAssertEqual(BranchOpenSheet.openBadge, "Open")
    }

    func testRepoSummaryMatchesTheSidebarSubtitleShape() {
        XCTAssertEqual(BranchOpenSheet.repoSummary(["alpha"]), "alpha")
        XCTAssertEqual(BranchOpenSheet.repoSummary(["a", "b", "c"]), "a · b · c")
        XCTAssertEqual(BranchOpenSheet.repoSummary(["a", "b", "c", "d"]), "a · b · +2")
    }

    func testSidebarRowLabelMatchesTheSheetItOpens() {
        // The ellipsis says it opens a picker, matching "Customize…" and
        // "Course correct…" elsewhere in the sidebar.
        XCTAssertEqual(PlansSpecsSection.openBranchRowLabel, "Open branch…")
    }
}
