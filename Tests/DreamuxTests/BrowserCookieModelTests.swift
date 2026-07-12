import XCTest
@testable import Dreamux

final class BrowserCookieModelTests: XCTestCase {
    func testImportedCookieIsValueEquatable() {
        let a = ImportedCookie(domain: ".x.com", name: "s", value: "1", path: "/",
                               expires: nil, isSecure: true, isHTTPOnly: false,
                               sameSite: .lax, hostOnly: false)
        let b = a
        XCTAssertEqual(a, b)
    }

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertEqual(CookieImportError.sourceUnavailable(browser: "Arc").errorDescription,
                       "Arc doesn't appear to be installed.")
        XCTAssertTrue(CookieImportError.keychainDenied(browser: "Arc")
            .errorDescription!.contains("denied"))
        XCTAssertNotNil(CookieImportError.keychainKeyMissing(browser: "Arc").errorDescription)
        XCTAssertNotNil(CookieImportError.databaseUnreadable("x").errorDescription)
    }
}
