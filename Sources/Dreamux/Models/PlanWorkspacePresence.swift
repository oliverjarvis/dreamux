import Foundation

/// The plan row's link to a live feature workspace. Pure logic pulled out
/// of `PlansSpecsSection` so the visibility rule is testable without the
/// view — like `InitiativeProgress` and `DocChipLabel`.
enum PlanWorkspacePresence {
    /// The feature to open from a plan row's → workspace affordance (the
    /// hover button and its *Open workspace* menu item), or nil when the
    /// affordance shouldn't appear. It shows whenever the plan's feature
    /// name resolves AND that workspace currently exists — NOT
    /// status-gated: with the Features list retired this affordance is
    /// the only path to a plan-backed workspace's terminals, so wherever
    /// Merge/Close/run-controls appear (workspace exists), activation
    /// must too. That deliberately covers the `.ready`-with-live-worktree
    /// window (ledger record-loss, name collisions) where status alone
    /// would hide it. An unresolved name or torn-down feature yields nil.
    /// `status` stays in the signature so future status-scoped styling
    /// has the seam, and so tests document the status-independence.
    static func workspaceToOpen(
        status: PlanStatus,
        featureName: String?,
        featureExists: (String) -> Bool
    ) -> String? {
        guard let name = featureName, featureExists(name) else { return nil }
        return name
    }
}
