import XCTest
@testable import Dreamux

final class ArcCookieSourceTests: XCTestCase {
    private let password = "test-storage-pw"

    /// Build a temp `…/Arc/User Data/Default/Cookies` with the given rows.
    private func makeArcTree(rows: [ArcCookieRow]) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-src-\(UUID().uuidString)/User Data", isDirectory: true)
        let profile = base.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try writeCookiesFixture(at: profile.appendingPathComponent("Cookies"), rows: rows)
        return base
    }

    private func encryptedRow(host: String, name: String, value: String,
                              expiresUTC: Int64, blob: Data? = nil) -> ArcCookieRow {
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: password)
        return ArcCookieRow(hostKey: host, name: name,
                            encryptedValue: blob ?? aesCBCEncryptV10(value, key: key),
                            path: "/", expiresUTC: expiresUTC,
                            isSecure: true, isHTTPOnly: false, sameSite: 1)
    }

    func testIsAvailableFalseForEmptyDir() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let src = ArcCookieSource(baseDir: base, keyProvider: { Data() })
        XCTAssertFalse(src.isAvailable)
    }

    func testReadDecryptsAndMaps() throws {
        let far: Int64 = 99_999_999_999_000_000   // year ~5000, not expired
        let base = try makeArcTree(rows: [
            encryptedRow(host: ".github.com", name: "sess", value: "abc", expiresUTC: far),
        ])
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: password)
        let src = ArcCookieSource(baseDir: base, keyProvider: { key })

        XCTAssertTrue(src.isAvailable)
        let result = try src.readCookies()
        XCTAssertEqual(result.cookies.count, 1)
        XCTAssertEqual(result.skipped, 0)
        let c = result.cookies[0]
        XCTAssertEqual(c.domain, ".github.com")
        XCTAssertEqual(c.name, "sess")
        XCTAssertEqual(c.value, "abc")
        XCTAssertFalse(c.hostOnly)          // leading dot → domain cookie
        XCTAssertEqual(c.sameSite, .lax)
    }

    func testExpiredAndUndecryptableAreSkipped() throws {
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: password)
        let far: Int64 = 99_999_999_999_000_000
        let past: Int64 = 13_000_000_000_000_000   // ~2013, expired
        let base = try makeArcTree(rows: [
            encryptedRow(host: "x.com", name: "good", value: "v", expiresUTC: far),
            encryptedRow(host: "x.com", name: "old", value: "v", expiresUTC: past),
            encryptedRow(host: "x.com", name: "junk", value: "", expiresUTC: far,
                         blob: Data("v10garbagebytes!!".utf8)),
        ])
        let src = ArcCookieSource(baseDir: base, keyProvider: { key })
        let result = try src.readCookies()
        XCTAssertEqual(result.cookies.map(\.name), ["good"])
        XCTAssertEqual(result.skipped, 2)
    }

    func testHostOnlyDerivation() throws {
        let far: Int64 = 99_999_999_999_000_000
        let base = try makeArcTree(rows: [
            encryptedRow(host: "app.local", name: "s", value: "v", expiresUTC: far),
        ])
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: password)
        let c = try ArcCookieSource(baseDir: base, keyProvider: { key }).readCookies().cookies[0]
        XCTAssertTrue(c.hostOnly)           // no leading dot → host-only
    }

    func testEnvOverrideDrivesDefaultBaseDir() {
        let key = "DREAMUX_ARC_USER_DATA_DIR"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        setenv(key, "/tmp/some-arc-dir", 1)
        XCTAssertEqual(ArcCookieSource.defaultBaseDir.path, "/tmp/some-arc-dir")
    }

    func testReadCookiesThrowsWhenUnavailable() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let src = ArcCookieSource(baseDir: base, keyProvider: { Data() })
        XCTAssertThrowsError(try src.readCookies()) { error in
            XCTAssertEqual(error as? CookieImportError, .sourceUnavailable(browser: "Arc"))
        }
    }

    func testStoragePasswordEnvOverrideDrivesDefaultKeyProvider() throws {
        // With DREAMUX_ARC_STORAGE_PASSWORD set, the DEFAULT key provider must derive
        // the key from that password (no Keychain), decrypting a fixture encrypted
        // with the same password. No keyProvider is injected here — that's the point.
        let key = "DREAMUX_ARC_STORAGE_PASSWORD"
        let saved = ProcessInfo.processInfo.environment[key]
        defer { if let saved { setenv(key, saved, 1) } else { unsetenv(key) } }
        setenv(key, password, 1)   // `password` is the fixture's encryption password

        let far: Int64 = 99_999_999_999_000_000
        let base = try makeArcTree(rows: [
            encryptedRow(host: ".github.com", name: "sess", value: "abc", expiresUTC: far),
        ])
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }

        let src = ArcCookieSource(baseDir: base)   // default keyProvider → env password path
        let result = try src.readCookies()
        XCTAssertEqual(result.cookies.map(\.value), ["abc"])
    }
}
