import XCTest
@testable import Dreamux

final class WebTabNavigationTests: XCTestCase {
    func testSchemeURLPassesThrough() {
        XCTAssertEqual(
            WebTabSession.resolveNavigation("https://reddit.com/r/swift")?.absoluteString,
            "https://reddit.com/r/swift"
        )
    }

    func testHostLikeInputGetsHTTPS() {
        XCTAssertEqual(
            WebTabSession.resolveNavigation("reddit.com")?.absoluteString,
            "https://reddit.com"
        )
    }

    func testFreeTextBecomesGoogleSearch() {
        let url = WebTabSession.resolveNavigation("claude code")
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
        XCTAssertEqual(url?.query?.contains("claude"), true)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(WebTabSession.resolveNavigation("   "))
    }

    // MARK: - directURL — the palette's stricter half

    /// The ⌘K URL source must distinguish "resolved to a real URL/host"
    /// from "fell back to a search" — typing prose into the palette must
    /// never offer to google it (spec: "Palette URL awareness").
    func testDirectURLAcceptsScheme() {
        XCTAssertEqual(
            WebTabSession.directURL("https://github.com/anthropics")?.absoluteString,
            "https://github.com/anthropics"
        )
    }

    func testDirectURLAcceptsBareHost() {
        XCTAssertEqual(
            WebTabSession.directURL("github.com")?.absoluteString,
            "https://github.com"
        )
    }

    func testDirectURLRejectsProse() {
        XCTAssertNil(WebTabSession.directURL("claude code"))
        XCTAssertNil(WebTabSession.directURL("plan"))
        XCTAssertNil(WebTabSession.directURL("   "))
    }

    /// The same prose still searches from the address bar — `directURL`
    /// is a stricter view of one parser, not a second parser.
    func testResolveNavigationStillFallsBackToSearchForProse() {
        let url = WebTabSession.resolveNavigation("claude code")
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
    }
}
