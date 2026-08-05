import XCTest
@testable import Dreamux

/// The reset rule, the worst-of-two figure, the age, clamping, and what
/// a partial payload is allowed to become. No clock and no I/O anywhere
/// — every question takes the moment as an argument.
final class ClaudeUsageSnapshotTests: XCTestCase {

    /// 2026-08-05 12:00:00 UTC — a fixed "now" every case reads against.
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    private func snapshot(
        fiveHour: (Double, TimeInterval)? = nil,
        sevenDay: (Double, TimeInterval)? = nil,
        observedOffset: TimeInterval = 0
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: fiveHour.map {
                .init(usedPercentage: $0.0, resetsAt: now.addingTimeInterval($0.1))
            },
            sevenDay: sevenDay.map {
                .init(usedPercentage: $0.0, resetsAt: now.addingTimeInterval($0.1))
            },
            observedAt: now.addingTimeInterval(observedOffset)
        )
    }

    // MARK: - The reset rule

    func testWindowBeforeItsResetReadsItsPercentageAndItsResetTime() {
        let snap = snapshot(fiveHour: (41.2, 600))
        let window = snap.effectiveFiveHour(at: now)
        XCTAssertEqual(window?.usedPercentage, 41.2)
        XCTAssertEqual(window?.resetsAt, now.addingTimeInterval(600))
    }

    func testWindowExactlyAtItsResetIsEmptyWithNoKnownNextReset() {
        // The boundary belongs to the reset: resets_at states when the
        // window empties, so at that instant it is already empty.
        let snap = snapshot(fiveHour: (41.2, 0))
        let window = snap.effectiveFiveHour(at: now)
        XCTAssertEqual(window?.usedPercentage, 0)
        XCTAssertNil(window?.resetsAt,
                     "the next window's reset is set by its first use — unknown until a fresh reading")
    }

    func testWindowPastItsResetIsEmpty() {
        let snap = snapshot(sevenDay: (63, -3600))
        let window = snap.effectiveSevenDay(at: now)
        XCTAssertEqual(window?.usedPercentage, 0)
        XCTAssertNil(window?.resetsAt)
    }

    func testEachWindowResetsIndependently() {
        // Five-hour elapsed, seven-day still live: one reads 0, the
        // other is untouched.
        let snap = snapshot(fiveHour: (41.2, -60), sevenDay: (63, 86_400))
        XCTAssertEqual(snap.effectiveFiveHour(at: now)?.usedPercentage, 0)
        XCTAssertEqual(snap.effectiveSevenDay(at: now)?.usedPercentage, 63)
    }

    // MARK: - worst

    func testWorstIsTheHigherOfTheTwoEffectivePercentages() {
        let snap = snapshot(fiveHour: (41.2, 600), sevenDay: (63, 86_400))
        XCTAssertEqual(snap.worst(at: now), 63)
    }

    func testWorstIgnoresAResetWindow() {
        // The seven-day figure is higher on paper but its window has
        // elapsed, so the five-hour figure is the one that would stop you.
        let snap = snapshot(fiveHour: (41.2, 600), sevenDay: (63, -1))
        XCTAssertEqual(snap.worst(at: now), 41.2)
    }

    func testWorstUsesTheOnlyPresentWindow() {
        XCTAssertEqual(snapshot(sevenDay: (63, 86_400)).worst(at: now), 63)
    }

    func testWorstIsNilWhenNeitherWindowIsKnown() {
        XCTAssertNil(snapshot().worst(at: now))
    }

    // MARK: - age

    func testAgeIsTheDistanceFromTheObservation() {
        XCTAssertEqual(snapshot(observedOffset: -720).age(at: now), 720)
    }

    func testAgeNeverGoesNegative() {
        // Clock skew can stamp a reading slightly in the future; it
        // reads as brand new rather than as "in -30 seconds".
        XCTAssertEqual(snapshot(observedOffset: 30).age(at: now), 0)
    }

    // MARK: - Parsing

    func testParsesBothWindowsAndTheObservationTime() throws {
        let snap = try XCTUnwrap(ClaudeUsageSnapshot(json: [
            "five_hour": ["used_percentage": 41.2, "resets_at": 1_785_900_000],
            "seven_day": ["used_percentage": 63.0, "resets_at": 1_786_200_000],
            "observed_at": 1_785_869_358,
        ], receivedAt: now))
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 41.2)
        XCTAssertEqual(snap.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_785_900_000))
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 63.0)
        XCTAssertEqual(snap.observedAt, Date(timeIntervalSince1970: 1_785_869_358))
    }

    func testClampsPercentagesIntoZeroToOneHundred() throws {
        let snap = try XCTUnwrap(ClaudeUsageSnapshot(json: [
            "five_hour": ["used_percentage": 132.0, "resets_at": 1_785_900_000],
            "seven_day": ["used_percentage": -4.0, "resets_at": 1_786_200_000],
        ], receivedAt: now))
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 100)
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 0)
    }

    func testAPartialPayloadYieldsOneWindowRatherThanAZeroedSecond() throws {
        // A window missing either number is ABSENT, not zero — "we know
        // about one window" beats a confident lie about two.
        let snap = try XCTUnwrap(ClaudeUsageSnapshot(json: [
            "five_hour": ["used_percentage": 41.2, "resets_at": 1_785_900_000],
            "seven_day": ["used_percentage": 63.0],
        ], receivedAt: now))
        XCTAssertNotNil(snap.fiveHour)
        XCTAssertNil(snap.sevenDay)
    }

    func testObservationTimeFallsBackToWhenWeReceivedIt() throws {
        let snap = try XCTUnwrap(ClaudeUsageSnapshot(json: [
            "five_hour": ["used_percentage": 10.0, "resets_at": 1_785_900_000],
        ], receivedAt: now))
        XCTAssertEqual(snap.observedAt, now)
    }

    func testNoUsableWindowIsNotASnapshot() {
        XCTAssertNil(ClaudeUsageSnapshot(json: [:], receivedAt: now))
        XCTAssertNil(ClaudeUsageSnapshot(json: ["five_hour": "nonsense"], receivedAt: now))
    }

    func testRoundTripsThroughCodable() throws {
        let snap = snapshot(fiveHour: (41.2, 600), sevenDay: (63, 86_400))
        let decoded = try JSONDecoder().decode(
            ClaudeUsageSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)
    }
}
