import Foundation

/// A cookie lifted from another browser, in engine-neutral form. No WebKit
/// or Chromium types cross this boundary — a `BrowserCookieSource` produces
/// these; `CookieImportService` maps them to `HTTPCookie`.
struct ImportedCookie: Equatable, Sendable {
    var domain: String      // leading dot when !hostOnly (a domain cookie)
    var name: String
    var value: String
    var path: String
    var expires: Date?      // nil = session cookie
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSite: SameSitePolicy?
    var hostOnly: Bool
}

/// The two SameSite policies we can express through `HTTPCookie`. None /
/// unspecified maps to `nil` (no explicit policy).
enum SameSitePolicy: Sendable, Equatable { case lax, strict }

/// Result of reading a source: the importable cookies plus a count of ones
/// dropped (expired or undecryptable) so the UI can say "N imported, M skipped".
struct CookieReadResult: Sendable, Equatable {
    var cookies: [ImportedCookie]
    var skipped: Int
}

/// A browser Dreamux can import cookies from. v1 ships only `ArcCookieSource`;
/// this protocol is the seam a later Safari/Chrome source slots into.
protocol BrowserCookieSource: Sendable {
    var displayName: String { get }
    /// True iff this browser's cookie data exists on disk right now.
    var isAvailable: Bool { get }
    /// Read + decrypt all importable cookies. May prompt (Keychain) and do I/O.
    func readCookies() throws -> CookieReadResult
}

enum CookieImportError: LocalizedError, Sendable, Equatable {
    case sourceUnavailable(browser: String)
    case keychainDenied(browser: String)
    case keychainKeyMissing(browser: String)
    case databaseUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let b):
            return "\(b) doesn't appear to be installed."
        case .keychainDenied(let b):
            return "Permission to read \(b)'s saved key was denied. You can try the import again."
        case .keychainKeyMissing(let b):
            return "Couldn't find \(b)'s encryption key in the Keychain."
        case .databaseUnreadable(let detail):
            return "Couldn't read the cookie database: \(detail)"
        }
    }
}
