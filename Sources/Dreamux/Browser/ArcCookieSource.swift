import Foundation

/// Imports cookies from Arc (Chromium-based). Owns Arc's on-disk layout and
/// composes `ArcCookieDatabase` + `ArcCookieDecryptor`. The Keychain read is
/// injected via `keyProvider` so tests/e2e can supply a known key.
struct ArcCookieSource: BrowserCookieSource {
    let baseDir: URL                                   // …/Arc/User Data
    let keyProvider: @Sendable () throws -> Data
    let now: Date

    init(baseDir: URL? = nil,
         keyProvider: (@Sendable () throws -> Data)? = nil,
         now: Date = Date()) {
        self.baseDir = baseDir ?? Self.defaultBaseDir
        self.keyProvider = keyProvider ?? Self.defaultKeyProvider
        self.now = now
    }

    /// `$DREAMUX_ARC_USER_DATA_DIR` override (tests/e2e), else the real path.
    static var defaultBaseDir: URL {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_ARC_USER_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data", isDirectory: true)
    }

    /// Real key path: `$DREAMUX_ARC_STORAGE_PASSWORD` (tests/e2e — skips the
    /// Keychain prompt), else the login Keychain (raises the consent prompt).
    static let defaultKeyProvider: @Sendable () throws -> Data = {
        if let pw = ProcessInfo.processInfo.environment["DREAMUX_ARC_STORAGE_PASSWORD"],
           !pw.isEmpty {
            return ArcCookieDecryptor.deriveKey(fromStoragePassword: pw)
        }
        return ArcCookieDecryptor.deriveKey(
            fromStoragePassword: try ArcCookieDecryptor.copyStoragePassword())
    }

    var displayName: String { "Arc" }

    /// Profile dirs (Default, Profile N) that actually contain a Cookies DB.
    var cookieDBs: [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .map { $0.appendingPathComponent("Cookies", isDirectory: false) }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    var isAvailable: Bool { !cookieDBs.isEmpty }

    func readCookies() throws -> CookieReadResult {
        let dbs = cookieDBs
        guard !dbs.isEmpty else { throw CookieImportError.sourceUnavailable(browser: "Arc") }
        let key = try keyProvider()
        var cookies: [ImportedCookie] = []
        var skipped = 0
        for db in dbs {
            for row in try ArcCookieDatabase.readRows(cookiesURL: db) {
                guard let value = ArcCookieDecryptor.decrypt(row.encryptedValue, key: key) else {
                    skipped += 1; continue
                }
                let expires = ArcCookieFormat.date(fromChromiumMicros: row.expiresUTC)
                if let expires, expires < now { skipped += 1; continue }
                cookies.append(ImportedCookie(
                    domain: row.hostKey,
                    name: row.name,
                    value: value,
                    path: row.path.isEmpty ? "/" : row.path,
                    expires: expires,
                    isSecure: row.isSecure,
                    isHTTPOnly: row.isHTTPOnly,
                    sameSite: ArcCookieFormat.sameSite(fromChromiumInt: row.sameSite),
                    hostOnly: !row.hostKey.hasPrefix(".")
                ))
            }
        }
        return CookieReadResult(cookies: cookies, skipped: skipped)
    }
}
