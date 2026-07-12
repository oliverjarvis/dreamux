import XCTest
@testable import Dreamux

@MainActor
final class PaletteModelTests: XCTestCase {
    private var performed: [String] = []

    override func setUp() {
        performed = []
    }

    private func candidate(_ id: String, _ title: String) -> PaletteCandidate {
        PaletteCandidate(id: id, title: title, subtitle: nil, icon: "doc") {
            self.performed.append(id)
        }
    }

    private func model(
        projects: [PaletteCandidate] = [],
        commands: [PaletteCandidate] = [],
        files: [PaletteCandidate] = []
    ) -> PaletteModel {
        PaletteModel(sources: [
            PaletteSource(kind: .projects, cap: 5, showsOnEmptyQuery: true) { projects },
            PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) { commands },
            PaletteSource(kind: .files, cap: 8, showsOnEmptyQuery: false) { files },
        ])
    }

    func testEmptyQueryShowsOnlyEmptyQuerySectionsInSourceOrder() {
        let m = model(
            projects: [candidate("p1", "clayspace")],
            commands: [candidate("c1", "New Plan…")],
            files: [candidate("f1", "readme.md")]
        )
        m.refresh()
        XCTAssertEqual(m.sections.map(\.kind), [.projects, .commands])
        XCTAssertEqual(m.selectedRowID, "p1")
    }

    func testEmptyQueryRespectsCap() {
        let many = (1...7).map { candidate("p\($0)", "project-\($0)") }
        let m = model(projects: many)
        m.refresh()
        XCTAssertEqual(m.sections[0].rows.count, 5)
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["p1", "p2", "p3", "p4", "p5"])
    }

    func testQueryFiltersAndSurfacesRequiresQuerySections() {
        let m = model(
            projects: [candidate("p1", "clayspace")],
            commands: [candidate("c1", "New Plan…")],
            files: [candidate("f1", "readme.md"), candidate("f2", "main.swift")]
        )
        m.refresh()
        m.query = "read"
        XCTAssertEqual(m.sections.map(\.kind), [.files])
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["f1"])
    }

    func testQueryRanksByScoreWithinSection() {
        let m = model(projects: [
            candidate("scatter", "superplan-archive"),
            candidate("prefix", "plan.md"),
        ])
        m.refresh()
        m.query = "plan"
        XCTAssertEqual(m.sections[0].rows.map(\.id), ["prefix", "scatter"])
    }

    func testQueryRespectsCapAfterRanking() {
        let many = (1...7).map { candidate("p\($0)", "plan-\($0)") }
        let m = model(projects: many)
        m.refresh()
        m.query = "plan"
        XCTAssertEqual(m.sections[0].rows.count, 5)
    }

    func testMoveSelectionClampsAndWalksAcrossSections() {
        let m = model(
            projects: [candidate("p1", "alpha"), candidate("p2", "beta")],
            commands: [candidate("c1", "gamma")]
        )
        m.refresh()
        XCTAssertEqual(m.selectedRowID, "p1")
        m.moveSelection(by: -1)
        XCTAssertEqual(m.selectedRowID, "p1")
        m.moveSelection(by: 1)
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "c1")
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "c1")
    }

    func testSelectionResetsToFirstWhenRowDisappears() {
        let m = model(projects: [candidate("p1", "alpha"), candidate("p2", "beta")])
        m.refresh()
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selectedRowID, "p2")
        m.query = "alp"
        XCTAssertEqual(m.selectedRowID, "p1")
    }

    func testExecuteSelectedRunsCandidate() {
        let m = model(projects: [candidate("p1", "alpha")])
        m.refresh()
        XCTAssertTrue(m.executeSelected())
        XCTAssertEqual(performed, ["p1"])
    }

    func testExecuteSelectedReturnsFalseWithNoRows() {
        let m = model(projects: [candidate("p1", "alpha")])
        m.refresh()
        m.query = "zzzz"
        XCTAssertFalse(m.executeSelected())
        XCTAssertTrue(performed.isEmpty)
    }

    func testSelectSetsSelection() {
        let m = model(projects: [candidate("p1", "alpha"), candidate("p2", "beta")])
        m.refresh()
        XCTAssertEqual(m.selectedRowID, "p1")
        m.select("p2")
        XCTAssertEqual(m.selectedRowID, "p2")
        XCTAssertEqual(m.selectedRow?.id, "p2")
    }

    func testCapKeepsHighestScoringAfterSort() {
        // "s-u-p-x-plan-archive" matches "plan" only as a scattered
        // subsequence (p at index 4 after a boundary hyphen, then l/a/n
        // picked up later) — FuzzyMatcher scores it 13. "plan-a" through
        // "plan-e" all match "plan" as a full prefix run at index 0 with
        // every character consecutive, which FuzzyMatcher scores far
        // higher (23 each). PaletteModel.rebuild sorts every source's
        // candidates by score before applying the source's cap (5 for
        // .projects), so even though the weak scatter candidate is
        // declared first — and would survive a cap-before-sort — it must
        // be the one dropped, not any of the five stronger, later-
        // declared "plan-*" matches.
        let many = [
            candidate("scatter", "s-u-p-x-plan-archive"),
            candidate("p1", "plan-a"),
            candidate("p2", "plan-b"),
            candidate("p3", "plan-c"),
            candidate("p4", "plan-d"),
            candidate("p5", "plan-e"),
        ]
        let m = model(projects: many)
        m.refresh()
        m.query = "plan"
        XCTAssertEqual(m.sections[0].rows.count, 5)
        XCTAssertFalse(m.sections[0].rows.map(\.id).contains("scatter"))
    }
}
