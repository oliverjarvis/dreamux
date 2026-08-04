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
            PaletteSource(kind: .projects, cap: 5, showsOnEmptyQuery: true) { _ in projects },
            PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) { _ in commands },
            PaletteSource(kind: .files, cap: 8, showsOnEmptyQuery: false) { _ in files },
        ])
    }

    // MARK: - Query-dependent sources (the ⌘K URL source)

    /// A source whose candidates ARE a function of the query can't be
    /// snapshotted at `refresh()`. `dependsOnQuery` re-pulls it on every
    /// keystroke and takes its rows verbatim — no fuzzy filter, because the
    /// source already decided what this query yields.
    private func urlModel() -> PaletteModel {
        PaletteModel(sources: [
            PaletteSource(kind: .url, cap: 1, showsOnEmptyQuery: false,
                          dependsOnQuery: true) { query in
                guard let url = WebTabSession.directURL(query) else { return [] }
                return [PaletteCandidate(
                    id: "url-\(url.absoluteString)",
                    title: "Open \(url.host ?? url.absoluteString)",
                    subtitle: url.absoluteString,
                    icon: "globe"
                ) { self.performed.append("url") }]
            },
            PaletteSource(kind: .commands, cap: 5, showsOnEmptyQuery: true) { _ in
                [self.candidate("c1", "Open Browser")]
            },
        ])
    }

    func testQueryDependentSourceIsSilentOnEmptyQuery() {
        let m = urlModel()
        m.refresh()
        XCTAssertEqual(m.sections.map(\.kind), [.commands])
    }

    func testQueryDependentSourceOffersATypedHost() {
        let m = urlModel()
        m.refresh()
        m.query = "github.com"
        XCTAssertEqual(m.sections.first?.kind, .url, "the URL source ranks first")
        XCTAssertEqual(m.sections.first?.rows.first?.candidate.title, "Open github.com")
        XCTAssertEqual(m.sections.first?.rows.first?.candidate.subtitle, "https://github.com")
    }

    /// Prose must never offer to google it from ⌘K.
    func testQueryDependentSourceIgnoresProse() {
        let m = urlModel()
        m.refresh()
        m.query = "open browser"
        XCTAssertFalse(m.sections.contains { $0.kind == .url })
    }

    /// The source is re-pulled per keystroke, not frozen at open time.
    func testQueryDependentSourceTracksSuccessiveQueries() {
        let m = urlModel()
        m.refresh()
        m.query = "github.com"
        XCTAssertEqual(m.sections.first?.rows.first?.candidate.subtitle, "https://github.com")
        m.query = "example.org"
        XCTAssertEqual(m.sections.first?.rows.first?.candidate.subtitle, "https://example.org")
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
