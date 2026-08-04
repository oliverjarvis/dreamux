import XCTest
@testable import Dreamux

/// The copy is the contract here: the old labels ("New workspace", "New
/// Plan") both described something the button does NOT do — a workspace is
/// minted when a plan is RUN, and the conversation may end in a queued
/// plan, extra tasks on an existing plan, or no new file at all. These
/// strings are asserted so a future edit has to be deliberate.
final class IdeaIntakeCopyTests: XCTestCase {
    func testSheetTitleAndHelpTextNameWhatActuallyHappens() {
        XCTAssertEqual(NewPlanSheet.title, "New idea")
        XCTAssertEqual(
            NewPlanSheet.helpText,
            "Describes an idea to claude, which decides whether it's new "
            + "work, work that should wait on something in flight, or extra "
            + "tasks for a plan you already have.")
    }

    func testSidebarRowLabelMatchesTheSheet() {
        XCTAssertEqual(PlansSpecsSection.newIdeaRowLabel, "New idea")
    }
}
