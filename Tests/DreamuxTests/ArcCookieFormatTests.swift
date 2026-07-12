import XCTest
@testable import Dreamux

final class ArcCookieFormatTests: XCTestCase {
    func testZeroMicrosIsSessionCookie() {
        XCTAssertNil(ArcCookieFormat.date(fromChromiumMicros: 0))
    }

    func testEpochConversion() {
        // 13_348_540_800_000_000 µs since 1601 == 2024-01-01T00:00:00Z.
        // (11_644_473_600 s epoch delta + 1_704_067_200 s since the Unix
        // epoch) * 1_000_000. The brief's original fixture,
        // 13_357_248_000_000_000, was off by ~100.78 days from its own
        // stated target date — corrected here; see task-2-report.md.
        let d = ArcCookieFormat.date(fromChromiumMicros: 13_348_540_800_000_000)
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
