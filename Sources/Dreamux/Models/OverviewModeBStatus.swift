import Foundation

/// Maps a plain (plan-less) workspace's working-tree summary to the Overview
/// hero pill. `nil` insertions/deletions mean the git status hasn't resolved
/// yet — no pill. Pure for testing; the view passes
/// `headStatus?.insertions` / `headStatus?.deletions`.
enum OverviewModeBStatus {
    struct Pill: Equatable {
        let text: String
        let flow: FlowStatus
    }

    static func pill(insertions: Int?, deletions: Int?) -> Pill? {
        guard let insertions, let deletions else { return nil }
        if insertions == 0 && deletions == 0 {
            return Pill(text: "Clean", flow: .done)
        }
        return Pill(text: "Uncommitted changes", flow: .waiting)
    }
}
