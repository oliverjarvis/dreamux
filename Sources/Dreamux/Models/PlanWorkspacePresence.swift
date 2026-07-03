import Foundation

/// The plan row's link to a live feature workspace. Pure logic pulled out
/// of `PlansSpecsSection` so the visibility rule is testable without the
/// view — like `InitiativeProgress` and `DocChipLabel`.
enum PlanWorkspacePresence {
    /// The feature to open from a plan row's → workspace affordance (the
    /// hover button and its *Open workspace* menu item), or nil when the
    /// affordance shouldn't appear. It shows only for an in-flight plan
    /// (`.running` or `.awaitingReview`) whose feature name resolves AND
    /// currently exists in the sidebar — a `.ready`/`.merged` plan, an
    /// unresolved name, or a torn-down feature all yield nil.
    static func workspaceToOpen(
        status: PlanStatus,
        featureName: String?,
        featureExists: (String) -> Bool
    ) -> String? {
        guard status == .running || status == .awaitingReview,
              let name = featureName, featureExists(name)
        else { return nil }
        return name
    }
}
