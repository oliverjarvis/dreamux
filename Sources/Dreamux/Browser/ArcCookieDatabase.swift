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
