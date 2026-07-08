import Foundation

/// A compact row for main's mini-dashboard — one non-merged plan's run
/// state, exactly what a row needs to render (title, status, progress)
/// and to jump to its workspace (`featureName`, `id` == the plan's
/// relative path).
struct ProjectRun: Identifiable, Equatable {
    let id: String            // plan relative path
    let title: String
    let status: PlanStatus
    let featureName: String?
    let checked: Int
    let total: Int
}

/// Active (non-merged) plans as compact run rows, most-urgent first —
/// the same rank the rail uses (`PlansSpecsSection.rank(_:)`). Pure:
/// status/feature-name/relative-path are all injected closures so this
/// is testable without a `DocStore`.
enum ProjectRunsSummary {
    static func runs(
        plans: [PlanDoc],
        status: (PlanDoc) -> PlanStatus,
        featureName: (PlanDoc) -> String?,
        relativePath: (PlanDoc) -> String
    ) -> [ProjectRun] {
        plans
            .map { (plan: $0, status: status($0)) }
            .filter { $0.status != .merged }
            .sorted { rank($0.status) < rank($1.status) }
            .map { entry in
                ProjectRun(
                    id: relativePath(entry.plan),
                    title: entry.plan.title,
                    status: entry.status,
                    featureName: featureName(entry.plan),
                    checked: entry.plan.checkedSteps,
                    total: entry.plan.totalSteps)
            }
    }

    /// Mirrors `PlansSpecsSection.rank(_:)` exactly: running → awaiting
    /// review → ready/in-progress. `.specOnly` never reaches here (only
    /// `.plan`-kind docs are passed in) and `.merged` is filtered above;
    /// both rank last defensively.
    private static func rank(_ status: PlanStatus) -> Int {
        switch status {
        case .running: return 0
        case .awaitingReview: return 1
        case .ready, .inProgress: return 2
        case .specOnly, .merged: return 3
        }
    }
}
