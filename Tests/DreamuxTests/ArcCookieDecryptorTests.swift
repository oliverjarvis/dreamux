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
