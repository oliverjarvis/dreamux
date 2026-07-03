import Foundation

/// Aggregate progress for an INITIATIVE — a family of ordered, sequentially
/// blocking plans. Entirely DERIVED from the members' `PlanStatus` values and
/// their summed checkbox counts; like `PlanStatus`, nothing is stored.
///
/// The derivation:
/// - **current plan** = the first member that is not `.merged`. Plans run in
///   order, so the earliest unfinished plan is the one in flight; its index is
///   0-based, and the label reports it 1-based.
/// - **all merged** ⇒ no plan in flight: `currentIndex` is nil and the label
///   reads `done`. An empty `statuses` array is the vacuous all-merged case and
///   resolves the same way (`done`) — an initiative with no plans has nothing
///   in flight, which is the least surprising reading.
/// - **label** otherwise reads `plan k/n` — the 1-based current plan over the
///   member count. `plan 1/1` for a single-plan initiative, which the caller
///   elides but which still resolves correctly.
/// - **fraction** = `checked / total` summed across the members, or nil when
///   `total == 0` (a family whose plans carry no checkboxes has no meaningful
///   percentage).
enum InitiativeProgress {
    static func resolve(
        statuses: [PlanStatus],
        checked: Int,
        total: Int
    ) -> (currentIndex: Int?, label: String, fraction: Double?) {
        let fraction = total > 0 ? Double(checked) / Double(total) : nil
        guard let current = statuses.firstIndex(where: { $0 != .merged }) else {
            return (nil, "done", fraction)
        }
        return (current, "plan \(current + 1)/\(statuses.count)", fraction)
    }
}
