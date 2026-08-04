import XCTest
@testable import Dreamux

/// Tab titles for concurrent intake sessions. Pure — a tab bar with ten
/// live routers has to read as ten different conversations.
final class IdeaTitleTests: XCTestCase {
    func testShortIdeaIsPrefixedVerbatim() {
        XCTAssertEqual(IdeaTitle.tabTitle(for: "browser tile"), "idea: browser tile")
    }

    func testOnlyTheFirstNonEmptyLineIsUsed() {
        let idea = "\n\n  sidebar hover states  \nand also the tile order\n"
        XCTAssertEqual(IdeaTitle.tabTitle(for: idea), "idea: sidebar hover states")
    }

    func testInnerWhitespaceCollapses() {
        XCTAssertEqual(IdeaTitle.tabTitle(for: "fix\t\tthe   bar"), "idea: fix the bar")
    }

    /// Clip on a word boundary so a tab chip never reads mid-word.
    func testOverLongIdeaClipsOnAWordBoundary() {
        let title = IdeaTitle.tabTitle(
            for: "rework the entire sidebar hierarchy and its hover states")
        XCTAssertTrue(title.hasPrefix("idea: "))
        XCTAssertTrue(title.hasSuffix("…"), "clipped titles are marked: \(title)")
        let body = String(title.dropFirst("idea: ".count).dropLast())
        XCTAssertLessThanOrEqual(body.count, 24)
        XCTAssertFalse(body.hasSuffix(" "), "no trailing space before the ellipsis")
        XCTAssertTrue("rework the entire sidebar hierarchy and its hover states".hasPrefix(body),
                      "the kept prefix is a real prefix of the idea: \(body)")
    }

    /// A single word longer than the budget still has to clip — there is no
    /// boundary to fall back to.
    func testSingleOverLongWordIsHardClipped() {
        let title = IdeaTitle.tabTitle(for: String(repeating: "z", count: 40))
        XCTAssertEqual(title, "idea: " + String(repeating: "z", count: 24) + "…")
    }

    func testEmptyAndWhitespaceOnlyInputYieldsBareIdea() {
        XCTAssertEqual(IdeaTitle.tabTitle(for: ""), "idea")
        XCTAssertEqual(IdeaTitle.tabTitle(for: "   \n\t \n "), "idea")
    }
}
