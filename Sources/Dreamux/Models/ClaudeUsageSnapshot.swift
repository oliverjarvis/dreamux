import Foundation

/// Claude's subscription quota exactly as Claude Code reported it in a
/// `statusLine` payload's `rate_limits` object, plus when we saw it.
///
/// The whole of this feature's logic lives here as pure functions of
/// `self` and a caller-supplied `Date` — no clock, no I/O — so both
/// surfaces and every test ask the same questions the same way.
struct ClaudeUsageSnapshot: Codable, Sendable, Equatable {
    /// One quota window: how full it is, and the instant it empties.
    struct Window: Codable, Sendable, Equatable {
        /// 0...100, clamped when parsed.
        var usedPercentage: Double
        /// Stated outright by the payload — never estimated.
        var resetsAt: Date
    }

    /// A window as it reads at some particular moment.
    struct EffectiveWindow: Sendable, Equatable {
        var usedPercentage: Double
        /// nil once the window has reset: the next window's reset time
        /// is set by its first use, so it is genuinely unknown until a
        /// fresh reading arrives.
        var resetsAt: Date?
    }

    var fiveHour: Window?
    var sevenDay: Window?
    var observedAt: Date

    init(fiveHour: Window?, sevenDay: Window?, observedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
    }

    /// Parse the `usage` object the statusline tap posts over the emit
    /// socket. A window survives only when BOTH its numbers parse — a
    /// partial payload degrades to "we know about one window" rather
    /// than to a confident zero. Returns nil when neither window
    /// survives, since a snapshot with nothing in it is not a reading.
    init?(json: [String: Any], receivedAt: Date) {
        let five = Self.window(from: json["five_hour"])
        let seven = Self.window(from: json["seven_day"])
        guard five != nil || seven != nil else { return nil }
        let observed = (json["observed_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        self.init(fiveHour: five, sevenDay: seven, observedAt: observed ?? receivedAt)
    }

    private static func window(from raw: Any?) -> Window? {
        guard let dict = raw as? [String: Any],
              let used = dict["used_percentage"] as? NSNumber,
              let resets = dict["resets_at"] as? NSNumber
        else { return nil }
        return Window(
            usedPercentage: min(100, max(0, used.doubleValue)),
            resetsAt: Date(timeIntervalSince1970: resets.doubleValue)
        )
    }

    /// The reset rule. `resets_at` states exactly when a window empties,
    /// so at or after that instant the window reads 0% with no known
    /// next reset. This is not an estimate — it is a fact the payload
    /// handed us, and it is what makes it safe to keep displaying a
    /// reading taken an hour ago.
    static func effective(_ window: Window?, at date: Date) -> EffectiveWindow? {
        guard let window else { return nil }
        guard date < window.resetsAt else {
            return EffectiveWindow(usedPercentage: 0, resetsAt: nil)
        }
        return EffectiveWindow(usedPercentage: window.usedPercentage,
                               resetsAt: window.resetsAt)
    }

    func effectiveFiveHour(at date: Date) -> EffectiveWindow? {
        Self.effective(fiveHour, at: date)
    }

    func effectiveSevenDay(at date: Date) -> EffectiveWindow? {
        Self.effective(sevenDay, at: date)
    }

    /// The higher of the two effective percentages — the one that would
    /// actually stop you — or the only present one, or nil when neither
    /// window is known. This is the single number the menu bar shows.
    func worst(at date: Date) -> Double? {
        [effectiveFiveHour(at: date), effectiveSevenDay(at: date)]
            .compactMap { $0?.usedPercentage }
            .max()
    }

    /// How long ago this reading was taken. Never negative: clock skew
    /// can stamp a reading slightly in the future, and "just now" is the
    /// honest reading of that.
    func age(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(observedAt))
    }
}
