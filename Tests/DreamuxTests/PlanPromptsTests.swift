import XCTest
@testable import Dreamux

final class PlanPromptsTests: XCTestCase {
    func testRunPlanPromptNamesTheFileAndCheckboxContract() {
        let p = PlanPrompts.runPlan(
            planRelativePath: "docs/plans/2026-07-02-x.md", docsLinkName: "docs")
        XCTAssertTrue(p.contains("docs/plans/2026-07-02-x.md"))
        XCTAssertTrue(p.contains("- [ ]"))
        XCTAssertTrue(p.contains("- [x]"))
        XCTAssertTrue(p.contains("task-by-task"))
    }

    func testResumePromptMentionsContinuing() {
        let p = PlanPrompts.resumePlan(
            planRelativePath: "docs/plans/x.md", docsLinkName: "project-docs")
        XCTAssertTrue(p.contains("project-docs/plans/x.md")
                      || p.contains("docs/plans/x.md"))
        XCTAssertTrue(p.lowercased().contains("continue"))
    }

    func testBrainstormKickoffCarriesIdeaAndTargets() {
        let p = PlanPrompts.brainstormKickoff(idea: "make widgets fast")
        XCTAssertTrue(p.contains("make widgets fast"))
        XCTAssertTrue(p.contains("docs/specs/"))
        XCTAssertTrue(p.contains("docs/plans/"))
        XCTAssertTrue(p.contains("brainstorming"))
    }

    func testWritePlanKickoffTargetsSpec() {
        let p = PlanPrompts.writePlanKickoff(specRelativePath: "docs/specs/x-design.md")
        XCTAssertTrue(p.contains("docs/specs/x-design.md"))
        XCTAssertTrue(p.contains("writing-plans"))
    }
}
