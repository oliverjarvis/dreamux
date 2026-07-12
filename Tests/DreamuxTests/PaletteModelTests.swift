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
}
