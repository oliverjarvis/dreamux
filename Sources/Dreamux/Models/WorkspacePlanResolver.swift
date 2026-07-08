import Foundation

enum WorkspacePlanResolver {
    /// The plan a workspace is running, matched by the workspace's branch
    /// name against each plan's resolved feature name. `featureName` is the
    /// SAME resolver the rail uses (ledger record first, else filename-
    /// derived branch) — pass it in so this stays pure/testable.
    ///
    /// - Parameters:
    ///   - name: The workspace branch name to match
    ///   - plans: Array of plans, date-ordered by the store
    ///   - featureName: Closure that resolves a plan's feature name
    /// - Returns: The first plan whose `featureName(plan) == name`, or nil if none
    static func plan(
        forWorkspaceNamed name: String,
        plans: [PlanDoc],
        featureName: (PlanDoc) -> String?
    ) -> PlanDoc? {
        plans.first { plan in
            featureName(plan) == name
        }
    }
}
