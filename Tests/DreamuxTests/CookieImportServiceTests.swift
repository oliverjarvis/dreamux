import XCTest
import WebKit
@testable import Dreamux

private struct FakeCookieSource: BrowserCookieSource {
    var displayName = "Fake"
    var isAvailable = true
    var result = CookieReadResult(cookies: [], skipped: 0)
    var error: CookieImportError?
    func readCookies() throws -> CookieReadResult {
        if let error { throw error }
        return result
    }
}

@MainActor
final class CookieImportServiceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        // A unique suite name gives a clean, isolated defaults domain per test.
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    func testMakeHTTPCookieDomainVsHostOnly() {
        let domainCookie = ImportedCookie(domain: ".x.com", name: "a", value: "1", path: "/",
            expires: nil, isSecure: true, isHTTPOnly: false, sameSite: .lax, hostOnly: false)
        let hc = CookieImportService.makeHTTPCookie(domainCookie)
        XCTAssertEqual(hc?.domain, ".x.com")
        XCTAssertTrue(hc!.isSecure)

        let hostOnly = ImportedCookie(domain: "app.local", name: "b", value: "2", path: "/app",
            expires: Date(timeIntervalSince1970: 4_000_000_000), isSecure: false,
            isHTTPOnly: false, sameSite: .strict, hostOnly: true)
        let hc2 = CookieImportService.makeHTTPCookie(hostOnly)
        XCTAssertEqual(hc2?.path, "/app")
        XCTAssertNotNil(hc2?.expiresDate)
    }

    func testImportInjectsIntoDataStoreAndSetsFlag() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let defaults = freshDefaults()
        let service = CookieImportService(defaults: defaults, dataStore: store)
        XCTAssertFalse(service.hasOfferedArc)

        let source = FakeCookieSource(result: .init(cookies: [
            ImportedCookie(domain: ".github.com", name: "s", value: "v", path: "/",
                expires: nil, isSecure: true, isHTTPOnly: false, sameSite: .lax, hostOnly: false),
        ], skipped: 3))

        let summary = await service.importCookies(from: source)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertNil(summary.error)
        XCTAssertTrue(service.hasOfferedArc)

        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "s" && $0.domain.contains("github.com") })
    }

    func testImportErrorDoesNotSetFlag() async {
        let defaults = freshDefaults()
        let service = CookieImportService(defaults: defaults,
                                          dataStore: WKWebsiteDataStore.nonPersistent())
        let source = FakeCookieSource(error: .keychainDenied(browser: "Arc"))
        let summary = await service.importCookies(from: source)
        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.error, .keychainDenied(browser: "Arc"))
        XCTAssertFalse(service.hasOfferedArc)   // retryable
    }
}
