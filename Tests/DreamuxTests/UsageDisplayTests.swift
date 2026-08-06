import XCTest
@testable import Dreamux

/// The strings and fills both surfaces render. Locale and time zone are
/// pinned so the reset formatting is deterministic.
final class UsageDisplayTests: XCTestCase {

    /// 2026-08-05 12:00:00 UTC, a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")

    private func display(
        fiveHour: (Double, TimeInterval)? = nil,
        sevenDay: (Double, TimeInterval)? = nil,
        observedOffset: TimeInterval = 0
    ) -> UsageDisplay {
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: fiveHour.map {
                .init(usedPercentage: $0.0, resetsAt: now.addingTimeInterval($0.1))
            },
            sevenDay: sevenDay.map {
                .init(usedPercentage: $0.0, resetsAt: now.addingTimeInterval($0.1))
            },
            observedAt: now.addingTimeInterval(observedOffset)
        )
        return UsageDisplay.make(snapshot: snapshot, at: now,
                                 calendar: calendar, locale: locale)
    }

    func testRowCarriesLabelPercentAndFill() {
        let row = display(fiveHour: (41.2, 22_800)).fiveHour
        XCTAssertEqual(row?.label, "5h")
        XCTAssertEqual(row?.percentText, "41%")
        XCTAssertEqual(row?.fraction ?? 0, 0.412, accuracy: 0.0001)
    }

    func testAbsentWindowHasNoRow() {
        let display = display(sevenDay: (63, 86_400))
        XCTAssertNil(display.fiveHour)
        XCTAssertNotNil(display.sevenDay)
    }

    func testResetWithinADayReadsAsAClockTime() {
        // 12:00 UTC + 6h20m = 18:20.
        XCTAssertEqual(display(fiveHour: (41.2, 22_800)).fiveHour?.resetText,
                       "resets 18:20")
    }

    func testResetBeyondADayReadsAsAWeekday() {
        // Wednesday + 3 days = Saturday.
        XCTAssertEqual(display(sevenDay: (63, 3 * 86_400)).sevenDay?.resetText,
                       "resets Sat")
    }

    func testAWindowPastItsResetShowsZeroAndNoResetTime() {
        let row = display(fiveHour: (41.2, -60)).fiveHour
        XCTAssertEqual(row?.percentText, "0%")
        XCTAssertNil(row?.resetText)
    }

    func testWorstTextIsTheNumberThatWouldStopYou() {
        XCTAssertEqual(display(fiveHour: (41.2, 600), sevenDay: (63, 86_400)).worstText, "63%")
        XCTAssertNil(display().worstText)
    }

    func testAgeTextCountsUpInHumanUnits() {
        XCTAssertEqual(display(fiveHour: (41.2, 600), observedOffset: -30).ageText,
                       "Last reading just now")
        XCTAssertEqual(display(fiveHour: (41.2, 600), observedOffset: -60).ageText,
                       "Last reading 1 minute ago")
        XCTAssertEqual(display(fiveHour: (41.2, 600), observedOffset: -720).ageText,
                       "Last reading 12 minutes ago")
        XCTAssertEqual(display(fiveHour: (41.2, 600), observedOffset: -7_200).ageText,
                       "Last reading 2 hours ago")
        XCTAssertEqual(display(fiveHour: (41.2, 600), observedOffset: -180_000).ageText,
                       "Last reading 2 days ago")
    }

    func testLevelShiftsAsAWindowFills() {
        XCTAssertEqual(UsageLevel(percentage: 0), .calm)
        XCTAssertEqual(UsageLevel(percentage: 59.9), .calm)
        XCTAssertEqual(UsageLevel(percentage: 60), .warm)
        XCTAssertEqual(UsageLevel(percentage: 84.9), .warm)
        XCTAssertEqual(UsageLevel(percentage: 85), .hot)
        XCTAssertEqual(UsageLevel(percentage: 100), .hot)
    }
}
