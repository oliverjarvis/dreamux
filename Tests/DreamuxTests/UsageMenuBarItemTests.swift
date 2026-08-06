import XCTest
@testable import Dreamux

/// The menu bar item's decisions and its menu copy. The NSStatusItem
/// itself is AppKit and stays untested, exactly like the views — what's
/// tested is everything that decides what it says and whether it exists.
@MainActor
final class UsageMenuBarItemTests: XCTestCase {

    /// 2026-08-05 12:00:00 UTC, a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func snapshot() -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: .init(usedPercentage: 41.2, resetsAt: now.addingTimeInterval(22_800)),
            sevenDay: .init(usedPercentage: 63.0, resetsAt: now.addingTimeInterval(3 * 86_400)),
            observedAt: now.addingTimeInterval(-720)
        )
    }

    private func display(_ snapshot: ClaudeUsageSnapshot) -> UsageDisplay {
        UsageDisplay.make(snapshot: snapshot, at: now, calendar: calendar,
                          locale: Locale(identifier: "en_GB"))
    }

    func testShownOnlyWhenVisibleAndAReadingExists() {
        XCTAssertTrue(UsageMenuBarItem.shouldShow(snapshot: snapshot(), visible: true))
        XCTAssertFalse(UsageMenuBarItem.shouldShow(snapshot: snapshot(), visible: false),
                       "hidden by the user")
        XCTAssertFalse(UsageMenuBarItem.shouldShow(snapshot: nil, visible: true),
                       "no reading has ever arrived — show no gauge rather than a zeroed one")
    }

    func testMenuSpellsOutBothWindowsTheAgeAndTheWayOut() {
        XCTAssertEqual(UsageMenuBarItem.menuTitles(display(snapshot())), [
            "Session (5h)  41% · resets 18:20",
            "Week (7d)  63% · resets Sat",
            "Last reading 12 minutes ago",
            "Hide from menu bar",
        ])
    }

    func testAWindowPastItsResetDropsItsResetTime() {
        let elapsed = ClaudeUsageSnapshot(
            fiveHour: .init(usedPercentage: 41.2, resetsAt: now.addingTimeInterval(-60)),
            sevenDay: nil,
            observedAt: now
        )
        XCTAssertEqual(UsageMenuBarItem.menuTitles(display(elapsed)), [
            "Session (5h)  0%",
            "Last reading just now",
            "Hide from menu bar",
        ])
    }

    func testTheGaugeGlyphIsBundledAndTinted() throws {
        let image = try XCTUnwrap(PhosphorIcon.nsImage("gauge-fill"),
                                  "gauge-fill.pdf must be bundled under PhosphorIcons")
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
