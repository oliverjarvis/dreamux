import Foundation

/// Reactive intake enactment (spec: "Enactment (app side)"). `ProjectSession`
/// wires this to `DocStore.onRefresh`, so every rescan of the docs tree
/// auto-enqueues any plan that declares `**Runs:** after <blocker>` behind
/// its blocker. Pure over its inputs — the queue is the only effect — so the
/// decision logic is unit-testable without a live `DocStore`.
enum IntakeEnactment {
    /// For every PLAN in `docs` with a `runsAfter` blocker, enqueue it behind
    /// the blocker when the blocker is a *known, non-merged* plan and the
    /// waiting plan itself hasn't run yet (`status == .ready`). A `runsAfter`
    /// that resolves to a merged plan, an unknown path, or the plan itself
    /// enacts nothing — the row caption still renders (Task 5). Idempotent
    /// (`ensureQueued` dedupes), so it is safe to run on every refresh.
    ///
    /// The `kind == .plan` gate is required, not incidental: `runsAfter`
    /// parses off spec/doc kinds too, and only plans enact.
    @MainActor
    static func enact(
        docs: [PlanDoc],
        queue: PlanQueueController,
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus
    ) {
        let plans = docs.filter { $0.kind == .plan }
        // A blocker is always a plan file, so only plans populate the index —
        // a `runsAfter` pointing at a spec/doc resolves to nothing.
        let planByPath = Dictionary(
            plans.map { (relativePath($0), $0) }, uniquingKeysWith: { first, _ in first })

        for plan in plans {
            guard let blockerRef = plan.runsAfter else { continue }
            // Only enqueue a plan that hasn't been enacted yet; a running,
            // in-progress, awaiting-review, or merged plan has already run.
            guard status(plan) == .ready else { continue }
            guard let blocker = planByPath[blockerRef],
                  blocker.fileURL != plan.fileURL,
                  status(blocker) != .merged else { continue }
            queue.ensureQueued(relativePath(plan), after: relativePath(blocker))
        }
    }
}
