import Foundation

/// Decides when a plan is *waiting* on another, for the Workspaces rail's
/// blocked treatment. A plan waits iff it declares `**Runs:** after
/// <blocker>`, the blocker resolves to a known, non-merged plan (and isn't
/// the plan itself), and the waiter is still `.ready` — the same condition
/// `IntakeEnactment.enact` uses to enqueue it. Pure over its resolvers.
enum PlanBlocking {
    struct Blocker: Equatable {
        let title: String    // for the `after ↳ <title>` caption
        let fileURL: URL     // the scroll-to / flash target
    }

    static func blocker(
        for plan: PlanDoc,
        status: PlanStatus,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> Blocker? {
        guard status == .ready,
              let reference = plan.runsAfter,
              let blocker = resolveBlocker(reference),
              blocker.fileURL != plan.fileURL,
              statusOf(blocker) != .merged
        else { return nil }
        return Blocker(title: blocker.title, fileURL: blocker.fileURL)
    }
}
