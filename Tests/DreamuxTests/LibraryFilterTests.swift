import XCTest
@testable import Dreamux

/// SwiftUI re-exports DeveloperToolsSupport, whose LibraryItem collides
/// with ours in the test target's lookup (not inside the module itself).
private typealias LibraryItem = Dreamux.LibraryItem

/// Pure pipeline behind the library page's chips and grid: activeOnly →
/// query. Kind narrowing is layered on top by the view so chip counts
/// can reflect "what you'd get by clicking this chip".
final class LibraryFilterTests: XCTestCase {
    private func makeItem(
        kind: LibraryItemKind = .skill,
        name: String,
        description: String = "",
        scopeLabel: String = "Global",
        accessible: Bool = false
    ) -> LibraryItem {
        LibraryItem(
            kind: kind, name: name, description: description,
            scopeLabel: scopeLabel,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            accessible: accessible, accessReason: "", detail: [])
    }

    func testEmptyQueryReturnsAll() {
        let items = [makeItem(name: "alpha"), makeItem(name: "beta")]
        XCTAssertEqual(
            LibraryFilter.searchScoped(items, query: "", activeOnly: false),
            items)
    }

    func testActiveOnlyKeepsAccessibleItems() {
        let on = makeItem(name: "on", accessible: true)
        let off = makeItem(name: "off", accessible: false)
        XCTAssertEqual(
            LibraryFilter.searchScoped([on, off], query: "", activeOnly: true),
            [on])
    }

    func testQueryMatchesNameDescriptionAndScopeCaseInsensitively() {
        let byName = makeItem(name: "Playwright")
        let byDescription = makeItem(name: "a", description: "Browser automation")
        let byScope = makeItem(name: "b", scopeLabel: "Plugin: superpowers")
        let miss = makeItem(name: "c", description: "unrelated")
        let items = [byName, byDescription, byScope, miss]
        XCTAssertEqual(
            LibraryFilter.searchScoped(items, query: "playwright", activeOnly: false),
            [byName])
        XCTAssertEqual(
            LibraryFilter.searchScoped(items, query: "BROWSER", activeOnly: false),
            [byDescription])
        XCTAssertEqual(
            LibraryFilter.searchScoped(items, query: "superpowers", activeOnly: false),
            [byScope])
    }

    func testActiveOnlyAndQueryCompose() {
        let activeMatch = makeItem(name: "svelte-skill", accessible: true)
        let inactiveMatch = makeItem(name: "svelte-other", accessible: false)
        XCTAssertEqual(
            LibraryFilter.searchScoped(
                [activeMatch, inactiveMatch], query: "svelte", activeOnly: true),
            [activeMatch])
    }

    func testChipKindSets() {
        XCTAssertNil(LibraryChip.all.kinds)
        XCTAssertEqual(LibraryChip.context.kinds, [.plan, .spec, .configFile])
        XCTAssertEqual(LibraryChip.plugins.kinds, [.plugin])
        XCTAssertEqual(LibraryChip.skills.kinds, [.skill])
        XCTAssertEqual(LibraryChip.mcpServers.kinds, [.mcpServer])
    }

    func testNarrowedFiltersByChipKindSet() {
        let plan = makeItem(kind: .plan, name: "plan")
        let spec = makeItem(kind: .spec, name: "spec")
        let config = makeItem(kind: .configFile, name: "CLAUDE.md")
        let skill = makeItem(kind: .skill, name: "skill")
        let items = [plan, spec, config, skill]
        XCTAssertEqual(LibraryFilter.narrowed(items, chip: .all), items)
        XCTAssertEqual(LibraryFilter.narrowed(items, chip: .context),
                       [plan, spec, config])
        XCTAssertEqual(LibraryFilter.narrowed(items, chip: .skills), [skill])
    }

    func testChipCountSemanticsQueryAndActiveApplyButNotKinds() {
        // A chip's count = narrowed(searchScoped) — the composition the
        // view uses, so Context counts cover all three kinds under the
        // current query/active-toggle.
        let activePlanMatch = makeItem(kind: .plan, name: "alpha plan", accessible: true)
        let inactiveSpecMatch = makeItem(kind: .spec, name: "alpha spec", accessible: false)
        let activeSkillMiss = makeItem(kind: .skill, name: "beta", accessible: true)
        let scoped = LibraryFilter.searchScoped(
            [activePlanMatch, inactiveSpecMatch, activeSkillMiss],
            query: "alpha", activeOnly: true)
        XCTAssertEqual(LibraryFilter.narrowed(scoped, chip: .context), [activePlanMatch])
        XCTAssertEqual(LibraryFilter.narrowed(scoped, chip: .all), [activePlanMatch])
    }
}
