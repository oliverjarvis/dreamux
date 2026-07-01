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
}
