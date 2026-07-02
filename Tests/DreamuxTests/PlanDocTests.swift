import XCTest
@testable import Dreamux

final class PlanDocTests: XCTestCase {
    private func doc(_ name: String, _ contents: String) -> PlanDoc {
        PlanDoc.parse(fileURL: URL(fileURLWithPath: "/p/docs/\(name)"), contents: contents)
    }

    func testPlanByH1Marker() {
        let d = doc("2026-07-02-widgets.md", """
        # Widgets Implementation Plan

        **Goal:** Build widgets.

        **Spec:** docs/specs/2026-07-02-widgets-design.md — read it first.
        """)
        XCTAssertEqual(d.kind, .plan)
        XCTAssertEqual(d.title, "Widgets Implementation Plan")
        XCTAssertEqual(d.date, "2026-07-02")
        XCTAssertEqual(d.goal, "Build widgets.")
        XCTAssertEqual(d.specReference, "docs/specs/2026-07-02-widgets-design.md")
    }

    func testPlanByTaskAndCheckboxShape() {
        let d = doc("notes.md", """
        # Some work

        ### Task 1: Do it
        - [x] **Step 1: a**
        - [ ] **Step 2: b**

        ### Task 2: More
        - [ ] **Step 1: c**
        """)
        XCTAssertEqual(d.kind, .plan)
        XCTAssertEqual(d.checkedSteps, 1)
        XCTAssertEqual(d.totalSteps, 3)
        XCTAssertNil(d.date)
    }

    func testSpecByFilenameSuffix() {
        let d = doc("2026-07-02-widgets-design.md", "# Widgets\n\nSome design.")
        XCTAssertEqual(d.kind, .spec)
        XCTAssertEqual(d.title, "Widgets")
    }

    func testCheckboxesAloneAreJustADoc() {
        let d = doc("todo.md", "# Todo\n- [ ] milk\n- [x] eggs\n")
        XCTAssertEqual(d.kind, .doc)
        XCTAssertEqual(d.totalSteps, 2)
    }

    func testTitleFallsBackToFilenameWithoutDatePrefix() {
        let d = doc("2026-01-01-no-heading.md", "no heading here")
        XCTAssertEqual(d.title, "no-heading")
    }

    func testSpecReferenceStripsBackticksAndTrailingProse() {
        let d = doc("p.md", """
        # X Implementation Plan
        **Spec:** `docs/specs/x-design.md` — read it before starting.
        """)
        XCTAssertEqual(d.specReference, "docs/specs/x-design.md")
    }

    func testBranchNameDerivation() {
        XCTAssertEqual(PlanDoc.branchName(forFileName: "2026-07-02-universal-file-viewers.md"),
                       "universal-file-viewers")
        XCTAssertEqual(PlanDoc.branchName(forFileName: "widgets-design.md"), "widgets")
        XCTAssertEqual(PlanDoc.branchName(forFileName: "plain.md"), "plain")
    }
}
