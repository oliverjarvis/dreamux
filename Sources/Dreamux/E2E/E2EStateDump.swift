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
    static func initiativesPayload(
        _ initiatives: [Initiative],
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus
    ) -> [[String: Any]] {
        initiatives.map { initiative in
            var entry: [String: Any] = [
                "title": initiative.title,
                "id": initiative.id,
                "docPaths": initiative.supportingDocs.map(relativePath),
                "plans": initiative.plans.enumerated().map { index, plan in
                    planPayload(plan, ordinal: index + 1,
                                relativePath: relativePath, status: status)
                },
            ]
            if let spec = initiative.spec {
                entry["specPath"] = relativePath(spec)
            }
            return entry
        }
    }

    private static func planPayload(
        _ plan: PlanDoc,
        ordinal: Int,
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus
    ) -> [String: Any] {
        [
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
    }
}
