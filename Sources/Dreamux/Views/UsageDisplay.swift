import Foundation

/// How full a window is, in the three steps the bar tint moves through —
/// so the row reads at a glance without parsing digits.
enum UsageLevel: Sendable, Equatable {
    case calm, warm, hot

    init(percentage: Double) {
        switch percentage {
        case ..<60: self = .calm
        case ..<85: self = .warm
        default: self = .hot
        }
    }
}

/// Everything both surfaces render, derived once from a snapshot and a
/// moment. The strings are final here; the views only lay them out, so
/// the footer and the menu bar can never drift apart.
struct UsageDisplay: Equatable {
    struct Row: Equatable {
        /// "5h" / "7d".
        var label: String
        /// "41%".
        var percentText: String
        /// 0...1 — the bar's fill.
        var fraction: Double
        var level: UsageLevel
        /// "resets 18:20" / "resets Sat", or nil once the window has reset.
        var resetText: String?
    }

    var fiveHour: Row?
    var sevenDay: Row?
    /// "Last reading 12 minutes ago".
    var ageText: String
    /// The menu bar's single figure, e.g. "63%". nil when no window is known.
    var worstText: String?

    static func make(
        snapshot: ClaudeUsageSnapshot,
        at date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> UsageDisplay {
        UsageDisplay(
            fiveHour: row(label: "5h", window: snapshot.effectiveFiveHour(at: date),
                          at: date, calendar: calendar, locale: locale),
            sevenDay: row(label: "7d", window: snapshot.effectiveSevenDay(at: date),
                          at: date, calendar: calendar, locale: locale),
            ageText: ageText(snapshot.age(at: date)),
            worstText: snapshot.worst(at: date).map { "\(Int($0.rounded()))%" }
        )
    }

    private static func row(
        label: String,
        window: ClaudeUsageSnapshot.EffectiveWindow?,
        at date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> Row? {
        guard let window else { return nil }
        return Row(
            label: label,
            percentText: "\(Int(window.usedPercentage.rounded()))%",
            fraction: window.usedPercentage / 100,
            level: UsageLevel(percentage: window.usedPercentage),
            resetText: resetText(window.resetsAt, at: date,
                                 calendar: calendar, locale: locale)
        )
    }

    /// A reset inside the next day is a clock time; further out it's a
    /// weekday, since "resets Sat" is what you actually want to know
    /// about a weekly window. Time style is the locale's own short form
    /// — a 24-hour locale renders "18:20", a 12-hour one "6:20 PM".
    private static func resetText(
        _ resetsAt: Date?, at date: Date, calendar: Calendar, locale: Locale
    ) -> String? {
        guard let resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if resetsAt.timeIntervalSince(date) < 24 * 3600 {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        }
        return "resets " + formatter.string(from: resetsAt)
    }

    private static func ageText(_ age: TimeInterval) -> String {
        let seconds = Int(age)
        if seconds < 60 { return "Last reading just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Last reading \(minutes) \(plural(minutes, "minute")) ago" }
        let hours = minutes / 60
        if hours < 24 { return "Last reading \(hours) \(plural(hours, "hour")) ago" }
        let days = hours / 24
        return "Last reading \(days) \(plural(days, "day")) ago"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? noun : noun + "s"
    }
}
