import Foundation

/// Pure parameter resolution for the e2e `courseCorrect` command
/// (spec: "Phase 2 — course correction"). Extracted from the command
/// body so the whole mapping — plan lookup, task/phase/absent → anchor,
/// priority token, empty-text rejection — is table-tested without
/// standing up the socket server or a live `DocStore`. The command
/// itself then does only the I/O the course-correct sheet does:
/// `CourseCorrection.apply` plus the live-plan nudge.
enum CourseCorrectCommand {
    /// Map the raw request params to a plan doc + anchor + priority + text,
    /// or throw a `ResolveError` whose message names the problem. `plans`
    /// and `relativePath` are the active project's plan docs and its
    /// project-relative path lookup (the command passes `docStore.plans`
    /// and `docStore.relativePath`).
    ///
    /// - `plan` must name one of `plans` by its project-relative path.
    /// - `text` must be non-empty once trimmed (the fix-task writer builds a
    ///   malformed heading from a blank observation — the sheet disables
    ///   submit for the same reason).
    /// - `priority` must be one of `now` / `next` / `queue`.
    /// - Anchor: `task` (when given) wins and matches a task by exact title
    ///   or a unique substring; otherwise `phase` names a `## ` section;
    ///   otherwise the correction lands in the plan's current phase — the
    ///   plan-row default the sheet uses.
    static func resolve(
        plans: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        plan: String?,
        task: String?,
        phase: String?,
        text: String?,
        priority: String?
    ) throws -> Resolved {
        guard let plan, !plan.isEmpty else {
            throw ResolveError(message: "missing or empty \"plan\" parameter")
        }
        guard let doc = plans.first(where: { relativePath($0) == plan }) else {
            throw ResolveError(message: "no plan at \(plan)")
        }
        let resolvedText = try resolveText(text)
        let resolvedPriority = try resolvePriority(priority)
        let anchor = try resolveAnchor(tasks: doc.tasks, task: task, phase: phase)
        return Resolved(doc: doc, anchor: anchor, priority: resolvedPriority, text: resolvedText)
    }

    private static func resolveText(_ raw: String?) throws -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResolveError(message: "missing or empty \"text\" parameter")
        }
        return raw
    }

    private static func resolvePriority(_ raw: String?) throws -> CorrectionPriority {
        guard let raw, !raw.isEmpty else {
            throw ResolveError(
                message: "missing \"priority\" (one of \"now\", \"next\", \"queue\")")
        }
        guard let priority = CorrectionPriority(rawValue: raw) else {
            throw ResolveError(
                message: "invalid \"priority\" \"\(raw)\": expected \"now\", \"next\", or \"queue\"")
        }
        return priority
    }

    /// `task` wins over `phase` (a task row is the most specific anchor);
    /// both absent lands the correction in the current phase — the anchor
    /// the sheet's plan row supplies.
    private static func resolveAnchor(
        tasks: [PlanTask], task: String?, phase: String?
    ) throws -> CourseCorrection.Anchor {
        if let query = task?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return try taskAnchor(tasks: tasks, query: query)
        }
        if let phase = phase?.trimmingCharacters(in: .whitespacesAndNewlines), !phase.isEmpty {
            return .phase(name: phase)
        }
        return .currentPhase
    }

    /// Resolve a task query to its heading line. An exact title match wins
    /// outright (so a title that is also a substring of a sibling isn't an
    /// ambiguity); otherwise a unique substring match is used, and zero or
    /// multiple substring matches are reported as errors the driver can act
    /// on.
    private static func taskAnchor(
        tasks: [PlanTask], query: String
    ) throws -> CourseCorrection.Anchor {
        let exact = tasks.filter { $0.title == query }
        if exact.count == 1 { return .task(line: exact[0].line) }
        if exact.count > 1 {
            throw ResolveError(
                message: "ambiguous task \"\(query)\": \(exact.count) task headings match exactly")
        }
        let substring = tasks.filter { !$0.title.isEmpty && $0.title.contains(query) }
        switch substring.count {
        case 1:
            return .task(line: substring[0].line)
        case 0:
            throw ResolveError(message: "no task matching \"\(query)\" in this plan")
        default:
            let titles = substring.map { "\"\($0.title)\"" }.joined(separator: ", ")
            throw ResolveError(
                message: "ambiguous task \"\(query)\": matches \(substring.count) tasks "
                    + "(\(titles)) — use a more specific substring or the exact title")
        }
    }

    /// The resolved command: which plan doc, where the fix-task attaches,
    /// the nudge priority, and the raw observation text.
    struct Resolved: Equatable {
        let doc: PlanDoc
        let anchor: CourseCorrection.Anchor
        let priority: CorrectionPriority
        let text: String
    }

    /// A resolution failure — the message becomes the command's
    /// `{"ok":false,"error":…}`.
    struct ResolveError: Error, Equatable {
        let message: String
    }
}
