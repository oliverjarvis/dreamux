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
