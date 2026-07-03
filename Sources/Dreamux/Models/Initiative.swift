import Foundation

/// A unit of requested work: a design spec (optional), the ordered plans
/// that implement it, and any supporting docs (roadmaps, notes) that pair
/// with the group. Derived by `DocStore` from the doc scan — never
/// stored on disk. Single-plan initiatives are the common case and render
/// flat; the grouping level only earns its keep for multi-plan families.
struct Initiative: Identifiable, Equatable {
    /// The family key (`DocStore` groups by it, so it is unique across
    /// initiatives). See `PlanDoc.familyKey(forFileName:)`.
    let id: String
    let title: String
    let spec: PlanDoc?
    /// Sequentially blocking, ordered by explicit `Phase N`, else date.
    let plans: [PlanDoc]
    let supportingDocs: [PlanDoc]

    /// One plan: renders as a flat top-level row, no grouping level.
    var isSinglePlan: Bool { plans.count == 1 }

    /// A spec with no plans yet — the "needs plan" state.
    var needsPlan: Bool { plans.isEmpty }
}
