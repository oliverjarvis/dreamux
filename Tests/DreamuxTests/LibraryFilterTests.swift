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
}
