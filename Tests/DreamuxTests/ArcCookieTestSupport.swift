import Foundation
import CommonCrypto
import SQLite3
@testable import Dreamux

/// Test-only: build a Chromium `v10` blob the way Arc would — AES-128-CBC with
/// the fixed all-spaces IV, prefixed with "v10" — so decryptor/source tests can
/// round-trip against a known key without a real Arc install.
func aesCBCEncryptV10(_ plaintext: String, key: Data) -> Data {
    aesCBCEncryptV10(Data(plaintext.utf8), key: key)
}

/// Test-only: v10-encrypt raw plaintext bytes (used to simulate the 32-byte
/// SHA-256 domain-hash prefix modern Chromium prepends before the value).
func aesCBCEncryptV10(_ plaintextData: Data, key: Data) -> Data {
    let iv = [UInt8](repeating: 0x20, count: 16)
    let inputBytes = [UInt8](plaintextData)
    var out = [UInt8](repeating: 0, count: inputBytes.count + kCCBlockSizeAES128)
    var moved = 0
    let status = key.withUnsafeBytes { keyPtr in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                keyPtr.baseAddress, key.count, iv,
                inputBytes, inputBytes.count, &out, out.count, &moved)
    }
    precondition(status == kCCSuccess, "test encrypt failed")
    return Data("v10".utf8) + Data(out.prefix(moved))
}

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
