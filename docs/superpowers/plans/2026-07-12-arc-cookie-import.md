# Arc Cookie Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-click "import your logins from Arc" to Dreamux's in-app browser — read Arc's Chromium cookie database, decrypt it, and inject the cookies into the shared `WKWebView` data store so the user lands already signed in.

**Architecture:** A thin `BrowserCookieSource` protocol with one v1 conformance, `ArcCookieSource`, which composes an `ArcCookieDatabase` (copy-first, read-only SQLite read) and an `ArcCookieDecryptor` (PBKDF2 + AES-128-CBC via CommonCrypto, key from the "Arc Safe Storage" Keychain item). A `@MainActor CookieImportService` maps the engine-neutral cookies to `HTTPCookie`s and injects them via `WKWebsiteDataStore.default().httpCookieStore`. UI is a one-time dismissible banner plus a re-runnable manual action in the browser bar.

**Tech Stack:** Swift 6, SwiftUI, WebKit (`WKHTTPCookieStore`), system `SQLite3` C API, `CommonCrypto` (`CCKeyDerivationPBKDF` / `CCCrypt`), `Security` (`SecItem`). No new package dependencies.

## Global Constraints

- **Platform floor:** macOS 14 (`platforms: [.macOS(.v14)]`). Swift tools 6.0, strict concurrency.
- **No new dependencies.** `CommonCrypto`, `Security`, and `SQLite3` are imported directly from the macOS SDK (as `SQLiteSignalStore` already does for `SQLite3`).
- **Never link XCTest into the app target.** New source files go in the `Dreamux` executable target; test-only helpers go in `Tests/DreamuxTests`.
- **Reuse existing idioms verbatim:** SQLite open/step/finalize discipline from `Sources/Dreamux/Signals/SQLiteSignalStore.swift`; `SecItem` query shape from `Sources/Dreamux/Models/SecretStore.swift`; `DREAMUX_*` env overrides for test/e2e seams (as `SecretStoreFactory` and `CLICredentialImporter` do).
- **Consent gate:** reading Arc's Keychain key is the only consent point; it is always user-triggered (banner button or manual action), never automatic. Do not add any auto-run path.
- **Scope:** whole cookie jar, all Arc profiles merged. Cookies only — no cache, no localStorage, no Safari (all out of scope per the spec).
- **New source files live under** `Sources/Dreamux/Browser/`.
- **Copy `verbatim` UI scale rules from CLAUDE.md** for the banner: readable type (≥13pt), native controls, no `Divider()` rules under headers, one hover wash.

Spec: `docs/superpowers/specs/2026-07-12-arc-cookie-import-design.md`.

---

## File Structure

**Create (app target):**
- `Sources/Dreamux/Browser/BrowserCookieSource.swift` — `ImportedCookie`, `SameSitePolicy`, `CookieReadResult`, `BrowserCookieSource` protocol, `CookieImportError`.
- `Sources/Dreamux/Browser/ArcCookieFormat.swift` — pure Chromium encoding conversions (epoch, samesite).
- `Sources/Dreamux/Browser/ArcCookieDecryptor.swift` — PBKDF2 key derivation, AES-128-CBC decrypt, Keychain key read.
- `Sources/Dreamux/Browser/ArcCookieDatabase.swift` — copy-first read-only SQLite read → `[ArcCookieRow]`.
- `Sources/Dreamux/Browser/ArcCookieSource.swift` — profile discovery, composition, mapping to `ImportedCookie`.
- `Sources/Dreamux/Browser/CookieImportService.swift` — `@MainActor` orchestration, `HTTPCookie` mapping, injection, one-time flag, `ImportSummary`.

**Create (test target):**
- `Tests/DreamuxTests/ArcCookieTestSupport.swift` — shared AES-CBC encrypt helper + SQLite `cookies` fixture builder.
- `Tests/DreamuxTests/ArcCookieFormatTests.swift`
- `Tests/DreamuxTests/ArcCookieDecryptorTests.swift`
- `Tests/DreamuxTests/ArcCookieDatabaseTests.swift`
- `Tests/DreamuxTests/ArcCookieSourceTests.swift`
- `Tests/DreamuxTests/CookieImportServiceTests.swift`

**Modify:**
- `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` — `WebTabView` (line ~218): banner + manual action.

---

### Task 1: Engine-neutral cookie model, source protocol, error type

**Files:**
- Create: `Sources/Dreamux/Browser/BrowserCookieSource.swift`
- Test: `Tests/DreamuxTests/BrowserCookieModelTests.swift`

**Interfaces:**
- Produces: `struct ImportedCookie` (fields: `domain,name,value,path: String`, `expires: Date?`, `isSecure,isHTTPOnly,hostOnly: Bool`, `sameSite: SameSitePolicy?`); `enum SameSitePolicy { case lax, strict }`; `struct CookieReadResult { var cookies: [ImportedCookie]; var skipped: Int }`; `protocol BrowserCookieSource: Sendable { var displayName: String { get }; var isAvailable: Bool { get }; func readCookies() throws -> CookieReadResult }`; `enum CookieImportError: LocalizedError, Sendable, Equatable`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/BrowserCookieModelTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BrowserCookieModelTests`
Expected: FAIL — `cannot find 'ImportedCookie' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dreamux/Browser/BrowserCookieSource.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BrowserCookieModelTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Browser/BrowserCookieSource.swift Tests/DreamuxTests/BrowserCookieModelTests.swift
git commit -m "feat(browser): engine-neutral cookie model + source protocol"
```

---

### Task 2: Chromium encoding conversions (`ArcCookieFormat`)

**Files:**
- Create: `Sources/Dreamux/Browser/ArcCookieFormat.swift`
- Test: `Tests/DreamuxTests/ArcCookieFormatTests.swift`

**Interfaces:**
- Consumes: `SameSitePolicy` (Task 1).
- Produces: `enum ArcCookieFormat` with `static func date(fromChromiumMicros: Int64) -> Date?` and `static func sameSite(fromChromiumInt: Int) -> SameSitePolicy?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/ArcCookieFormatTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class ArcCookieFormatTests: XCTestCase {
    func testZeroMicrosIsSessionCookie() {
        XCTAssertNil(ArcCookieFormat.date(fromChromiumMicros: 0))
    }

    func testEpochConversion() {
        // 13_357_248_000_000_000 µs since 1601 == 2024-01-01T00:00:00Z.
        // 2024-01-01 is 1_704_067_200 s since the Unix epoch.
        let d = ArcCookieFormat.date(fromChromiumMicros: 13_357_248_000_000_000)
        XCTAssertNotNil(d)
        XCTAssertEqual(d!.timeIntervalSince1970, 1_704_067_200, accuracy: 1.0)
    }

    func testSameSiteMapping() {
        XCTAssertNil(ArcCookieFormat.sameSite(fromChromiumInt: -1))
        XCTAssertNil(ArcCookieFormat.sameSite(fromChromiumInt: 0))
        XCTAssertEqual(ArcCookieFormat.sameSite(fromChromiumInt: 1), .lax)
        XCTAssertEqual(ArcCookieFormat.sameSite(fromChromiumInt: 2), .strict)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArcCookieFormatTests`
Expected: FAIL — `cannot find 'ArcCookieFormat' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dreamux/Browser/ArcCookieFormat.swift`:

```swift
import Foundation

/// Pure conversions for Arc/Chromium's on-disk cookie encoding. No I/O.
enum ArcCookieFormat {
    /// Seconds between 1601-01-01 (Windows FILETIME epoch) and 1970-01-01.
    private static let epochDelta = 11_644_473_600.0

    /// Chromium stores timestamps as microseconds since 1601-01-01 UTC.
    /// Returns nil for 0 (a session cookie).
    static func date(fromChromiumMicros micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000.0 - epochDelta)
    }

    /// Chromium `samesite`: -1 unspecified, 0 none, 1 lax, 2 strict. None and
    /// unspecified carry no explicit `HTTPCookie` policy, so map to nil.
    static func sameSite(fromChromiumInt raw: Int) -> SameSitePolicy? {
        switch raw {
        case 1: return .lax
        case 2: return .strict
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ArcCookieFormatTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Browser/ArcCookieFormat.swift Tests/DreamuxTests/ArcCookieFormatTests.swift
git commit -m "feat(browser): Chromium epoch + samesite conversions"
```

---

### Task 3: Decryptor + shared test support (`ArcCookieDecryptor`)

**Files:**
- Create: `Sources/Dreamux/Browser/ArcCookieDecryptor.swift`
- Create: `Tests/DreamuxTests/ArcCookieTestSupport.swift`
- Test: `Tests/DreamuxTests/ArcCookieDecryptorTests.swift`

**Interfaces:**
- Consumes: `CookieImportError` (Task 1).
- Produces: `struct ArcCookieDecryptor` with `static func deriveKey(fromStoragePassword: String) -> Data`, `static func decrypt(_ blob: Data, key: Data) -> String?`, `static func copyStoragePassword(service:account:) throws -> String`.
- Produces (test support): `func aesCBCEncryptV10(_ plaintext: String, key: Data) -> Data` and `func writeCookiesFixture(at: URL, rows: [ArcCookieRow]) throws` in `ArcCookieTestSupport.swift` — the latter is used by Tasks 4 and 5 (it references `ArcCookieRow` from Task 4, so Task 3 defines only `aesCBCEncryptV10` first and the fixture writer is added in Task 4).

> Note: `ArcCookieTestSupport.swift` is created here with the encrypt helper only. Task 4 appends `writeCookiesFixture` once `ArcCookieRow` exists.

- [ ] **Step 1: Write the shared encrypt helper**

Create `Tests/DreamuxTests/ArcCookieTestSupport.swift`:

```swift
import Foundation
import CommonCrypto
@testable import Dreamux

/// Test-only: build a Chromium `v10` blob the way Arc would — AES-128-CBC with
/// the fixed all-spaces IV, prefixed with "v10" — so decryptor/source tests can
/// round-trip against a known key without a real Arc install.
func aesCBCEncryptV10(_ plaintext: String, key: Data) -> Data {
    let iv = [UInt8](repeating: 0x20, count: 16)
    let inputBytes = Array(plaintext.utf8)
    var out = [UInt8](repeating: 0, count: inputBytes.count + kCCBlockSizeAES128)
    var moved = 0
    let status = key.withUnsafeBytes { keyPtr in
        CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            keyPtr.baseAddress, key.count,
            iv,
            inputBytes, inputBytes.count,
            &out, out.count,
            &moved
        )
    }
    precondition(status == kCCSuccess, "test encrypt failed")
    return Data("v10".utf8) + Data(out.prefix(moved))
}
```

- [ ] **Step 2: Write the failing decryptor test**

Create `Tests/DreamuxTests/ArcCookieDecryptorTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class ArcCookieDecryptorTests: XCTestCase {
    func testRoundTrip() {
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: "hunter2")
        let blob = aesCBCEncryptV10("session=abc123", key: key)
        XCTAssertEqual(ArcCookieDecryptor.decrypt(blob, key: key), "session=abc123")
    }

    func testUnknownVersionPrefixIsSkipped() {
        let key = ArcCookieDecryptor.deriveKey(fromStoragePassword: "hunter2")
        var blob = aesCBCEncryptV10("x=y", key: key)
        blob.replaceSubrange(0..<3, with: Data("v20".utf8))  // pretend app-bound
        XCTAssertNil(ArcCookieDecryptor.decrypt(blob, key: key))
    }

    func testWrongKeyReturnsNil() {
        let good = ArcCookieDecryptor.deriveKey(fromStoragePassword: "hunter2")
        let bad = ArcCookieDecryptor.deriveKey(fromStoragePassword: "nope")
        let blob = aesCBCEncryptV10("x=y", key: good)
        XCTAssertNil(ArcCookieDecryptor.decrypt(blob, key: bad))
    }

    func testDeriveKeyIsDeterministicAnd16Bytes() {
        let k1 = ArcCookieDecryptor.deriveKey(fromStoragePassword: "pw")
        let k2 = ArcCookieDecryptor.deriveKey(fromStoragePassword: "pw")
        XCTAssertEqual(k1, k2)
        XCTAssertEqual(k1.count, 16)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ArcCookieDecryptorTests`
Expected: FAIL — `cannot find 'ArcCookieDecryptor' in scope`.

- [ ] **Step 4: Write minimal implementation**

Create `Sources/Dreamux/Browser/ArcCookieDecryptor.swift`:

```swift
import Foundation
import CommonCrypto
import Security

/// Decrypts Arc's Chromium `encrypted_value` blobs. The AES key is derived
/// (PBKDF2) from the "Arc Safe Storage" password in the login Keychain, and
/// `v10` values are AES-128-CBC with a fixed all-spaces IV — the standard
/// Chromium-on-macOS scheme. The pure crypto is separate from the one Keychain
/// read so it's unit-testable without a Keychain.
struct ArcCookieDecryptor {
    static let salt = "saltysalt"
    static let iterations: UInt32 = 1003
    static let keyLength = 16                                 // AES-128
    static let iv = [UInt8](repeating: 0x20, count: 16)       // 16 spaces

    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16) → 128-bit AES key.
    static func deriveKey(fromStoragePassword password: String) -> Data {
        let pw = Array(password.utf8)
        let st = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        _ = st.withUnsafeBufferPointer { stPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, pw.count,
                stPtr.baseAddress, stPtr.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                iterations,
                &derived, derived.count
            )
        }
        return Data(derived)
    }

    /// Decrypt one `encrypted_value`. Returns nil (skip, never crash) for a
    /// version prefix we don't handle (app-bound `v20`, GCM, …) or any crypto
    /// failure.
    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3,
              String(bytes: blob.prefix(3), encoding: .utf8) == "v10" else { return nil }
        guard let plaintext = aesCBCDecrypt(Data(blob.dropFirst(3)), key: key) else { return nil }
        if let direct = String(data: plaintext, encoding: .utf8) { return direct }
        // Newer Chromium prepends a 32-byte SHA-256 domain hash to the plaintext.
        if plaintext.count > 32,
           let stripped = String(data: plaintext.dropFirst(32), encoding: .utf8) { return stripped }
        return nil
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, key.count,
                    iv,
                    dataPtr.baseAddress, data.count,
                    &out, out.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    /// The one impure bit: read Arc's storage password from the login Keychain.
    /// This raises the macOS authorization prompt — the consent gate.
    static func copyStoragePassword(
        service: String = "Arc Safe Storage",
        account: String = "Arc"
    ) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8) else {
                throw CookieImportError.keychainKeyMissing(browser: "Arc")
            }
            return password
        case errSecItemNotFound:
            throw CookieImportError.keychainKeyMissing(browser: "Arc")
        default:
            throw CookieImportError.keychainDenied(browser: "Arc")
        }
    }
}
```

> **Note on `password, pw.count`:** `CCKeyDerivationPBKDF`'s password parameter takes a `const char *`; passing the `[UInt8]` array `pw` directly bridges to a pointer, and `pw.count` is its length. Kept as `pw`/`pw.count` here for clarity — if the compiler rejects the implicit bridge, wrap in `pw.withUnsafeBufferPointer { CCKeyDerivationPBKDF(..., $0.baseAddress, $0.count, ...) }` nested inside the salt closure.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ArcCookieDecryptorTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Browser/ArcCookieDecryptor.swift Tests/DreamuxTests/ArcCookieDecryptorTests.swift Tests/DreamuxTests/ArcCookieTestSupport.swift
git commit -m "feat(browser): Arc cookie decryptor (PBKDF2 + AES-128-CBC)"
```

---

### Task 4: Cookie database reader (`ArcCookieDatabase`)

**Files:**
- Create: `Sources/Dreamux/Browser/ArcCookieDatabase.swift`
- Modify: `Tests/DreamuxTests/ArcCookieTestSupport.swift` (append `writeCookiesFixture`)
- Test: `Tests/DreamuxTests/ArcCookieDatabaseTests.swift`

**Interfaces:**
- Consumes: `CookieImportError` (Task 1).
- Produces: `struct ArcCookieRow` (fields: `hostKey,name,path: String`, `encryptedValue: Data`, `expiresUTC: Int64`, `isSecure,isHTTPOnly: Bool`, `sameSite: Int`); `enum ArcCookieDatabase` with `static func readRows(cookiesURL: URL) throws -> [ArcCookieRow]` and `static func readRowsDirect(dbURL: URL) throws -> [ArcCookieRow]`.
- Produces (test support): `func writeCookiesFixture(at dbURL: URL, rows: [ArcCookieRow]) throws`.

- [ ] **Step 1: Append the fixture writer to `ArcCookieTestSupport.swift`**

Add to `Tests/DreamuxTests/ArcCookieTestSupport.swift` (needs `import SQLite3` at top of that file):

```swift
import SQLite3

/// Test-only: write a minimal Chromium `cookies` table containing `rows` to a
/// fresh SQLite file at `dbURL`. Only the 8 columns the reader SELECTs exist.
func writeCookiesFixture(at dbURL: URL, rows: [ArcCookieRow]) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db,
                          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else { throw CookieImportError.databaseUnreadable("fixture open") }
    defer { sqlite3_close_v2(db) }

    let create = """
        CREATE TABLE cookies (
            host_key TEXT, name TEXT, encrypted_value BLOB, path TEXT,
            expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER);
    """
    guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
        throw CookieImportError.databaseUnreadable("fixture create")
    }

    let insert = """
        INSERT INTO cookies (host_key,name,encrypted_value,path,expires_utc,
                             is_secure,is_httponly,samesite)
        VALUES (?,?,?,?,?,?,?,?);
    """
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for row in rows {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieImportError.databaseUnreadable("fixture prepare")
        }
        sqlite3_bind_text(stmt, 1, row.hostKey, -1, transient)
        sqlite3_bind_text(stmt, 2, row.name, -1, transient)
        _ = row.encryptedValue.withUnsafeBytes {
            sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(row.encryptedValue.count), transient)
        }
        sqlite3_bind_text(stmt, 4, row.path, -1, transient)
        sqlite3_bind_int64(stmt, 5, row.expiresUTC)
        sqlite3_bind_int(stmt, 6, row.isSecure ? 1 : 0)
        sqlite3_bind_int(stmt, 7, row.isHTTPOnly ? 1 : 0)
        sqlite3_bind_int(stmt, 8, Int32(row.sameSite))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            throw CookieImportError.databaseUnreadable("fixture insert")
        }
        sqlite3_finalize(stmt)
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/DreamuxTests/ArcCookieDatabaseTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class ArcCookieDatabaseTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("arcdb-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testReadRowsDirect() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        let row = ArcCookieRow(hostKey: ".github.com", name: "sess",
                               encryptedValue: Data([0x01, 0x02]), path: "/",
                               expiresUTC: 13_357_248_000_000_000,
                               isSecure: true, isHTTPOnly: true, sameSite: 1)
        try writeCookiesFixture(at: db, rows: [row])

        let out = try ArcCookieDatabase.readRowsDirect(dbURL: db)
        XCTAssertEqual(out, [row])
    }

    func testReadRowsCopiesFirstAndLeavesSourceIntact() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        let row = ArcCookieRow(hostKey: "x.com", name: "n", encryptedValue: Data(),
                               path: "/", expiresUTC: 0, isSecure: false,
                               isHTTPOnly: false, sameSite: -1)
        try writeCookiesFixture(at: db, rows: [row])

        let out = try ArcCookieDatabase.readRows(cookiesURL: db)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))  // source untouched
    }

    func testMissingDBThrows() {
        let missing = tempDir().appendingPathComponent("Cookies")
        XCTAssertThrowsError(try ArcCookieDatabase.readRowsDirect(dbURL: missing))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ArcCookieDatabaseTests`
Expected: FAIL — `cannot find 'ArcCookieRow' in scope`.

- [ ] **Step 4: Write minimal implementation**

Create `Sources/Dreamux/Browser/ArcCookieDatabase.swift`:

```swift
import Foundation
import SQLite3

/// One raw row from Arc's Chromium `cookies` table — value still encrypted.
struct ArcCookieRow: Equatable, Sendable {
    var hostKey: String
    var name: String
    var encryptedValue: Data
    var path: String
    var expiresUTC: Int64
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSite: Int
}

/// Reads Arc's cookie SQLite DB. Arc keeps a lock on the live file, so
/// `readRows` copies it (plus any -wal/-shm) to a temp dir and opens the copy
/// read-only; `readRowsDirect` opens a given file straight (used by tests).
enum ArcCookieDatabase {
    static func readRows(cookiesURL: URL) throws -> [ArcCookieRow] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("arc-cookies-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tempDir, withIntermediateDirectories: true) }
        catch { throw CookieImportError.databaseUnreadable(error.localizedDescription) }
        defer { try? fm.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("Cookies", isDirectory: false)
        do {
            try fm.copyItem(at: cookiesURL, to: tempDB)
            for suffix in ["-wal", "-shm"] {
                let sib = URL(fileURLWithPath: cookiesURL.path + suffix)
                if fm.fileExists(atPath: sib.path) {
                    try fm.copyItem(at: sib, to: URL(fileURLWithPath: tempDB.path + suffix))
                }
            }
        } catch {
            throw CookieImportError.databaseUnreadable(error.localizedDescription)
        }
        return try readRowsDirect(dbURL: tempDB)
    }

    static func readRowsDirect(dbURL: URL) throws -> [ArcCookieRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw CookieImportError.databaseUnreadable(msg)
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
            SELECT host_key, name, encrypted_value, path, expires_utc,
                   is_secure, is_httponly, samesite
            FROM cookies;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CookieImportError.databaseUnreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [ArcCookieRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let blobLen = Int(sqlite3_column_bytes(stmt, 2))
            let encrypted: Data
            if let blobPtr = sqlite3_column_blob(stmt, 2), blobLen > 0 {
                encrypted = Data(bytes: blobPtr, count: blobLen)
            } else {
                encrypted = Data()
            }
            rows.append(ArcCookieRow(
                hostKey: Self.text(stmt, 0),
                name: Self.text(stmt, 1),
                encryptedValue: encrypted,
                path: Self.text(stmt, 3),
                expiresUTC: sqlite3_column_int64(stmt, 4),
                isSecure: sqlite3_column_int(stmt, 5) != 0,
                isHTTPOnly: sqlite3_column_int(stmt, 6) != 0,
                sameSite: Int(sqlite3_column_int(stmt, 7))
            ))
        }
        return rows
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ArcCookieDatabaseTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Browser/ArcCookieDatabase.swift Tests/DreamuxTests/ArcCookieDatabaseTests.swift Tests/DreamuxTests/ArcCookieTestSupport.swift
git commit -m "feat(browser): copy-first read-only Arc cookie DB reader"
```

---

### Task 5: Arc source composition (`ArcCookieSource`)

**Files:**
- Create: `Sources/Dreamux/Browser/ArcCookieSource.swift`
- Test: `Tests/DreamuxTests/ArcCookieSourceTests.swift`

**Interfaces:**
- Consumes: `BrowserCookieSource`, `ImportedCookie`, `CookieReadResult`, `CookieImportError` (Task 1); `ArcCookieFormat` (Task 2); `ArcCookieDecryptor` (Task 3); `ArcCookieDatabase`, `ArcCookieRow` (Task 4).
- Produces: `struct ArcCookieSource: BrowserCookieSource` with `init(baseDir: URL? = nil, keyProvider: (@Sendable () throws -> Data)? = nil, now: Date = Date())`, `static var defaultBaseDir: URL`, `var cookieDBs: [URL]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/ArcCookieSourceTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ArcCookieSourceTests`
Expected: FAIL — `cannot find 'ArcCookieSource' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dreamux/Browser/ArcCookieSource.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ArcCookieSourceTests`
Expected: PASS (5 tests). This exercises the full pipeline (fixture DB → real AES decrypt → mapping) with no Keychain, via the injected `keyProvider`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Browser/ArcCookieSource.swift Tests/DreamuxTests/ArcCookieSourceTests.swift
git commit -m "feat(browser): ArcCookieSource — profile discovery + decrypt + map"
```

---

### Task 6: Import service (`CookieImportService`)

**Files:**
- Create: `Sources/Dreamux/Browser/CookieImportService.swift`
- Test: `Tests/DreamuxTests/CookieImportServiceTests.swift`

**Interfaces:**
- Consumes: `BrowserCookieSource`, `ImportedCookie`, `CookieReadResult`, `SameSitePolicy`, `CookieImportError` (Task 1); `ArcCookieSource` (Task 5).
- Produces: `struct ImportSummary: Sendable, Equatable { var imported, skipped, failed: Int; var error: CookieImportError? }`; `@MainActor final class CookieImportService` with `init(defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore = .default())`, `var hasOfferedArc: Bool { get set }`, `func availableArcSource() -> BrowserCookieSource?`, `func importCookies(from: BrowserCookieSource) async -> ImportSummary`, `static func makeHTTPCookie(_:) -> HTTPCookie?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/CookieImportServiceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CookieImportServiceTests`
Expected: FAIL — `cannot find 'CookieImportService' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Dreamux/Browser/CookieImportService.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CookieImportServiceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Browser/CookieImportService.swift Tests/DreamuxTests/CookieImportServiceTests.swift
git commit -m "feat(browser): CookieImportService — map + inject + one-time flag"
```

---

### Task 7: Browser-bar UI — banner + manual action

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` (`WebTabView`, ~line 218)

**Interfaces:**
- Consumes: `CookieImportService`, `ImportSummary`, `BrowserCookieSource` (Tasks 1/6).

This task is SwiftUI + Keychain glue; its automated gate is `swift build` plus the full existing suite as regression. Behavioral verification is manual (the real Keychain prompt and SwiftUI rendering can't run headless) — concrete steps below. The whole logic pipeline is already covered automatically by Tasks 1–6, including the full fixture-DB → real-AES-decrypt path in Task 5.

- [ ] **Step 1: Add import-state to `WebTabView`**

In `WorkspaceTerminalContainer.swift`, add these stored properties to `WebTabView` (below `@FocusState private var addressFocused`):

```swift
    @State private var importService = CookieImportService()
    @State private var arcSource: BrowserCookieSource?
    @State private var showArcBanner = false
    @State private var importStatus: String?
    @State private var isImporting = false
```

- [ ] **Step 2: Discover Arc on appear**

Extend the existing `.onAppear` on the `VStack` (currently `address = session.currentURL.absoluteString`) to also resolve the source:

```swift
        .onAppear {
            address = session.currentURL.absoluteString
            let source = importService.availableArcSource()
            arcSource = source
            showArcBanner = source != nil && !importService.hasOfferedArc
        }
```

- [ ] **Step 3: Add the manual action to the bar**

In the `HStack` bar, immediately before the existing "open externally" (`safari`) `Button`, insert a manual import control shown only when Arc is available:

```swift
                if arcSource != nil {
                    Button {
                        runArcImport()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isImporting)
                    .help("Import logins from Arc")
                }
```

- [ ] **Step 4: Add the banner + status strip and the import action**

Insert a banner between the bar's `.background(.bar)` block and the `Divider()`:

```swift
            if showArcBanner {
                arcBanner
            }
            if let importStatus {
                Text(importStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
```

Add these members to `WebTabView`:

```swift
    private var arcBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Text("Import your logins from Arc? macOS will ask permission to read Arc's saved key.")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if isImporting {
                ProgressView().controlSize(.small)
            } else {
                Button("Import") { runArcImport() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Not now") {
                    importService.hasOfferedArc = true
                    showArcBanner = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func runArcImport() {
        guard let source = arcSource, !isImporting else { return }
        isImporting = true
        importStatus = nil
        Task {
            let summary = await importService.importCookies(from: source)
            isImporting = false
            showArcBanner = false
            if let error = summary.error {
                importStatus = error.errorDescription
            } else {
                var msg = "Imported \(summary.imported) login\(summary.imported == 1 ? "" : "s") from Arc"
                if summary.skipped > 0 { msg += " · \(summary.skipped) skipped" }
                importStatus = msg
                session.reload()   // pick up the freshly injected cookies
            }
        }
    }
```

- [ ] **Step 5: Build + regression**

Run: `swift build`
Expected: builds with no errors.

Run: `swift test`
Expected: full suite passes (Tasks 1–6 tests plus all pre-existing tests).

- [ ] **Step 6: Manual verification**

With a real Arc install:
1. `swift run Dreamux` (or launch the built app), open a workspace, press play / open an in-app browser tab.
2. Confirm the banner appears: *"Import your logins from Arc?…"*.
3. Click **Import** → a macOS Keychain prompt naming "Arc Safe Storage" appears → approve.
4. Confirm the status strip shows "Imported N logins from Arc", the banner disappears, and the page reloads. Navigate to a site you're logged into in Arc (e.g. github.com) and confirm you're signed in.
5. Reopen a browser tab → the banner does **not** reappear (one-time flag set), but the `square.and.arrow.down` manual action is still available.

Without Arc installed (or `DREAMUX_ARC_USER_DATA_DIR` pointed at an empty dir): confirm no banner and no manual action appear.

Optional e2e-style check without a real Keychain: set `DREAMUX_ARC_USER_DATA_DIR` to a fixture `User Data` dir containing `Default/Cookies` (built with the Task 3/4 helpers) and `DREAMUX_ARC_STORAGE_PASSWORD` to the matching password, launch, and drive Import — the full path runs with no Keychain prompt.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "feat(browser): Arc login-import banner + manual action in web tab"
```

---

## Self-Review

**1. Spec coverage:**
- Engine-neutral model + `BrowserCookieSource` seam → Task 1. ✓
- `ArcCookieDatabase` copy-first read-only SQLite → Task 4. ✓
- `ArcCookieDecryptor` (Keychain key, PBKDF2, AES-128-CBC, v10, domain-hash strip, unknown-version skip) → Task 3. ✓
- `ArcCookieSource` (profile discovery, `isAvailable`, env override, expired/undecryptable skip, hostOnly) → Task 5. ✓
- `CookieImportService` (map to HTTPCookie, inject to shared default store, `ImportSummary`, one-time flag not set on error) → Task 6. ✓
- UI: one-time banner + re-runnable manual action, result strip, reload → Task 7. ✓
- Chromium epoch + samesite → Task 2. ✓
- Whole-jar/all-profiles, cookies-only, consent gate, no new deps → Global Constraints + Tasks 3/5. ✓
- Testing: decryptor round-trip, epoch/samesite, DB fixture, mapping, injection into ephemeral store, isAvailable + flag transitions, full env-override pipeline → Tasks 2–6. ✓
- Out-of-scope items (cache, Safari, localStorage, v20) are not implemented — correct.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases". Every code step shows complete code; every run step gives an exact command and expected result. The `deriveKey` pointer-bridging note gives a concrete fallback, not a placeholder.

**3. Type consistency:** `readCookies()` returns `CookieReadResult` everywhere (protocol Task 1, impl Task 5, consumed Task 6). `ArcCookieRow` fields match between the fixture writer (Task 3/4), reader (Task 4), and source test (Task 5). `SameSitePolicy` (`.lax`/`.strict`) consistent across Tasks 1/2/5/6. `makeHTTPCookie` / `importCookies` / `availableArcSource` / `hasOfferedArc` signatures match between Task 6 impl and its tests and the Task 7 UI callers. `defaultBaseDir` / `defaultKeyProvider` / `cookieDBs` consistent Task 5. Env keys `DREAMUX_ARC_USER_DATA_DIR` and `DREAMUX_ARC_STORAGE_PASSWORD` spelled identically in impl and tests.

## Known implementation risks (call out at execution)
- **`import CommonCrypto` in SwiftPM:** works against the macOS SDK on modern toolchains. If the module fails to resolve during `swift build`, the fallback is a tiny system-library shim target — but try the direct import first (Task 3 build is the canary).
- **`CCKeyDerivationPBKDF` password pointer bridging:** see the note in Task 3, Step 4 — nest a `withUnsafeBufferPointer` if the implicit `[UInt8]`→pointer bridge is rejected under strict concurrency.
- **`WKHTTPCookieStore.setCookie` on `.nonPersistent()` in tests:** must run on the main actor (the test class is `@MainActor`); `allCookies()` is async — already awaited.
