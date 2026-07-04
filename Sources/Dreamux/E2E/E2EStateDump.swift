import Foundation

/// Pure builder for the `initiatives` array of the e2e `state` dump.
/// Extracted from `E2ECommands.stateReply()` so the dump's shape can be
/// unit-tested without standing up the socket server or a live
/// `DocStore`: it takes plain `Initiative` values plus the two
/// project-scoped lookups (`relativePath`, `status`) the command wires
/// from its stores. Keep it in lockstep with the `state` section of
/// `Scripts/e2e/PROTOCOL.md`.
enum E2EStateDump {
    /// One entry per initiative, in `initiatives` order. Paths are
    /// project-relative (via `relativePath`); `specPath` is omitted when
    /// the initiative has no spec. Each plan carries its 1-based `ordinal`
    /// (execution order within the family) and a per-task checkbox rollup.
    ///
    /// `pendingNudges` reports the count of parked live nudges for a plan
    /// (Task 4); it defaults to "none" so the pre-nudge call sites keep
    /// their exact shape.
    static func initiativesPayload(
        _ initiatives: [Initiative],
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus,
        pendingNudges: (PlanDoc) -> Int = { _ in 0 }
    ) -> [[String: Any]] {
        initiatives.map { initiative in
            var entry: [String: Any] = [
                "title": initiative.title,
                "id": initiative.id,
                "docPaths": initiative.supportingDocs.map(relativePath),
                "plans": initiative.plans.enumerated().map { index, plan in
                    planPayload(plan, ordinal: index + 1,
                                relativePath: relativePath, status: status,
                                pendingNudges: pendingNudges)
                },
            ]
            if let spec = initiative.spec {
                entry["specPath"] = relativePath(spec)
            }
            return entry
        }
    }

    /// One entry per plan for the flat `plans` dump `stateReply` keeps
    /// alongside the richer `initiatives` grouping for compatibility.
    /// Extracted here (like `initiativesPayload`) so the plan-shape
    /// fields stay unit-testable without standing up the socket server.
    /// Paths are project-relative (via `relativePath`); `status` is the
    /// derived lifecycle value.
    static func flatPlansPayload(
        _ plans: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus,
        pendingNudges: (PlanDoc) -> Int = { _ in 0 }
    ) -> [[String: Any]] {
        plans.map { plan in
            var entry: [String: Any] = [
                "path": relativePath(plan),
                "status": status(plan).rawValue,
                "checkedSteps": plan.checkedSteps,
                "totalSteps": plan.totalSteps,
            ]
            addDisposition(&entry, for: plan)
            addPendingNudges(&entry, count: pendingNudges(plan))
            return entry
        }
    }

    /// Attaches the plan's ordering disposition — `runsAfter` (the blocker
    /// path when the plan declares `**Runs:** after <plan>`) and
    /// `declaresParallel: true` (when it opts in via `**Runs:** parallel`)
    /// — to a payload entry. Both are omitted when absent, matching
    /// `specPath`'s omitted-not-null convention, so a driver reads a
    /// missing key as "that disposition wasn't declared" rather than a
    /// null. They are mutually exclusive on a well-formed header but dumped
    /// independently, straight from the parsed fields.
    private static func addDisposition(_ entry: inout [String: Any], for plan: PlanDoc) {
        if let runsAfter = plan.runsAfter { entry["runsAfter"] = runsAfter }
        if plan.declaresParallel { entry["declaresParallel"] = true }
    }

    /// Attach `pendingNudges` when the plan has at least one parked live
    /// nudge, omitting it (not `0`) otherwise — the same omitted-not-null
    /// convention `runsAfter`/`specPath` follow, so a driver reads a missing
    /// key as "no nudge parked".
    private static func addPendingNudges(_ entry: inout [String: Any], count: Int) {
        if count > 0 { entry["pendingNudges"] = count }
    }

    private static func planPayload(
        _ plan: PlanDoc,
        ordinal: Int,
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus,
        pendingNudges: (PlanDoc) -> Int
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "path": relativePath(plan),
            "status": status(plan).rawValue,
            "ordinal": ordinal,
            "tasks": plan.tasks.map { task in
                var payload: [String: Any] = [
                    "title": task.title,
                    "checked": task.steps.filter(\.checked).count,
                    "total": task.steps.count,
                ]
                // `## ` section the task falls under (single-file phased
                // plans) — omitted when the plan has no sections, matching
                // specPath's omitted-not-null convention.
                if let phase = task.phase { payload["phase"] = phase }
                return payload
            },
        ]
        addDisposition(&entry, for: plan)
        addPendingNudges(&entry, count: pendingNudges(plan))
        return entry
    }
}
