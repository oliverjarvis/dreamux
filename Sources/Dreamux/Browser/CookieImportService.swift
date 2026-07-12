import Foundation
import WebKit

/// Outcome of an import run, surfaced in the result toast.
struct ImportSummary: Sendable, Equatable {
    var imported: Int
    var skipped: Int          // expired/undecryptable dropped by the source
    var failed: Int           // HTTPCookie rejected the mapping
    var error: CookieImportError?
}

/// Orchestrates a cookie import: read from a source (off-main), map to
/// `HTTPCookie`, inject into the shared WebKit data store (on-main). Owns the
/// one-time "already offered" flag.
@MainActor
final class CookieImportService {
    static let hasOfferedArcKey = "hasOfferedArcImport"

    private let defaults: UserDefaults
    private let dataStore: WKWebsiteDataStore

    init(defaults: UserDefaults = .standard,
         dataStore: WKWebsiteDataStore = .default()) {
        self.defaults = defaults
        self.dataStore = dataStore
    }

    var hasOfferedArc: Bool {
        get { defaults.bool(forKey: Self.hasOfferedArcKey) }
        set { defaults.set(newValue, forKey: Self.hasOfferedArcKey) }
    }

    /// The Arc source when Arc data exists on disk, else nil. Drives banner
    /// visibility and the manual action's enabled state.
    func availableArcSource() -> BrowserCookieSource? {
        let source = ArcCookieSource()
        return source.isAvailable ? source : nil
    }

    func importCookies(from source: BrowserCookieSource) async -> ImportSummary {
        let result: CookieReadResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try source.readCookies()
            }.value
        } catch let error as CookieImportError {
            return ImportSummary(imported: 0, skipped: 0, failed: 0, error: error)
        } catch {
            return ImportSummary(imported: 0, skipped: 0, failed: 0,
                                 error: .databaseUnreadable(error.localizedDescription))
        }

        var imported = 0, failed = 0
        for cookie in result.cookies {
            if let httpCookie = Self.makeHTTPCookie(cookie) {
                await dataStore.httpCookieStore.setCookie(httpCookie)
                imported += 1
            } else {
                failed += 1
            }
        }
        hasOfferedArc = true
        return ImportSummary(imported: imported, skipped: result.skipped,
                             failed: failed, error: nil)
    }

    /// Pure mapping — separated so it's unit-testable without a data store.
    /// Note: HttpOnly has no public `HTTPCookiePropertyKey`, so imported
    /// cookies are not flagged HttpOnly; the cookie still works (HttpOnly only
    /// restricts JS access). SameSite None/unspecified carries no policy key.
    static func makeHTTPCookie(_ c: ImportedCookie) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: c.domain,
            .path: c.path.isEmpty ? "/" : c.path,
            .name: c.name,
            .value: c.value,
        ]
        if let expires = c.expires { props[.expires] = expires }
        if c.isSecure { props[.secure] = "TRUE" }
        if let sameSite = c.sameSite {
            props[.sameSitePolicy] = (sameSite == .lax)
                ? HTTPCookieStringPolicy.sameSiteLax
                : HTTPCookieStringPolicy.sameSiteStrict
        }
        return HTTPCookie(properties: props)
    }
}
