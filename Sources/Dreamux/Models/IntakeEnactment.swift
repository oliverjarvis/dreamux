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
    /// enacts nothing — the row caption still renders (Task 5).
    ///
    /// `ensureQueued` is edge-triggered, so running this on every refresh only
    /// enqueues a (plan, blocker) pair once and leaves the user's later queue
    /// edits alone.
    ///
    /// Blocker matching goes through `resolveReference` (DocStore's
    /// `resolve` + `standardizedFileURL` discipline) so a `./docs/…` header
    /// and the canonical doc URL match symmetrically, exactly as the
    /// `**Spec:**` back-link resolves.
    ///
    /// The `kind == .plan` gate is required, not incidental: `runsAfter`
    /// parses off spec/doc kinds too, and only plans enact.
    @MainActor
    static func enact(
        docs: [PlanDoc],
        queue: PlanQueueController,
        relativePath: (PlanDoc) -> String,
        resolveReference: (String) -> URL,
        status: (PlanDoc) -> PlanStatus
    ) {
        let plans = docs.filter { $0.kind == .plan }
        // A blocker is always a plan file, so only plans populate the index —
        // a `runsAfter` pointing at a spec/doc resolves to nothing. Keyed by
        // the standardized URL so resolution, not raw string equality, pairs
        // the waiter to its blocker.
        let planByURL = Dictionary(
            plans.map { ($0.fileURL.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first })

        for plan in plans {
            guard let blockerRef = plan.runsAfter else { continue }
            // Only enqueue a plan that hasn't been enacted yet; a running,
            // in-progress, awaiting-review, or merged plan has already run.
            guard status(plan) == .ready else { continue }
            guard let blocker = planByURL[resolveReference(blockerRef)],
                  blocker.fileURL != plan.fileURL,
                  status(blocker) != .merged else { continue }
            queue.ensureQueued(relativePath(plan), after: relativePath(blocker))
        }
    }

    /// Whether a freshly discovered plan should auto-launch under the
    /// per-project auto-run toggle (spec: Decisions §1 — default OFF, and an
    /// explicit `**Runs:** parallel` header is required; absence stays
    /// manual). True only when the toggle is on, the doc is a runnable PLAN
    /// still in `.ready`, it states `parallel` explicitly
    /// (`declaresParallel`), and it names no blocker (`runsAfter == nil` —
    /// the spec's "a fresh plan with no runsAfter and a stated-parallel
    /// disposition"). A toggle-off, a spec/doc kind, an already-run plan, or
    /// the absence of the explicit header all read false.
    ///
    /// Pure over its inputs so the decision table is unit-testable without a
    /// live session; the edge-trigger (fire at most once per plan) lives in
    /// `enactAutoRun`, not here.
    static func shouldAutoRun(doc: PlanDoc, status: PlanStatus, toggleOn: Bool) -> Bool {
        toggleOn
            && doc.kind == .plan
            && doc.declaresParallel
            && doc.runsAfter == nil
            && status == .ready
    }

    /// Auto-run enactment (spec: "Enactment (app side)"). For every plan that
    /// `shouldAutoRun` and hasn't already been auto-run (`hasAutoRun`), record
    /// it (`markAutoRun`) and then `launch` it.
    ///
    /// Edge-triggered off the fired-once record, mirroring the queue's
    /// `enactedBlockers` discipline: a plan fires at most once, and a plan that
    /// was auto-run and later reset to `.ready` (its worktree closed, ledger
    /// record pruned) is never relaunched — the record, not the live status,
    /// is the trigger. Because the record is *persisted* (see
    /// `PlanQueueController.markAutoRun`), that guarantee holds across a
    /// relaunch of the app, not just within a session. The path is recorded
    /// before `launch` runs, so a failed launch does not re-fire on the next
    /// refresh (no provisioning loop); the user can still Run it by hand.
    @MainActor
    static func enactAutoRun(
        docs: [PlanDoc],
        toggleOn: Bool,
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus,
        hasAutoRun: (String) -> Bool,
        markAutoRun: (String) -> Void,
        launch: (PlanDoc) -> Void
    ) {
        guard toggleOn else { return }
        for plan in docs where plan.kind == .plan {
            let path = relativePath(plan)
            guard !hasAutoRun(path) else { continue }
            guard shouldAutoRun(doc: plan, status: status(plan), toggleOn: toggleOn) else { continue }
            markAutoRun(path)
            launch(plan)
        }
    }

    /// The `after <blocker>` caption a waiting plan carries beside its status
    /// (spec: "Enactment (app side)" — the sidebar treatment). `nil` for a
    /// plan with no `runsAfter`; `after <title>` when the blocker resolves to
    /// a known doc via `resolveTitle`; `after <filename> (missing)` when it
    /// doesn't — an unresolvable blocker degrades visibly rather than
    /// vanishing (spec: Decisions §3). Pure over `resolveTitle` so the view
    /// can inject DocStore resolution and the formatting stays unit-testable.
    static func afterCaption(runsAfter: String?, resolveTitle: (String) -> String?) -> String? {
        guard let runsAfter else { return nil }
        if let title = resolveTitle(runsAfter) { return "after \(title)" }
        return "after \((runsAfter as NSString).lastPathComponent) (missing)"
    }
}
