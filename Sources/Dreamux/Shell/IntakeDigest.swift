import Foundation

/// The intake digest: a compact, deterministic snapshot of every
/// non-merged plan the planning agent needs to pick a disposition
/// (parallel / wait / integrate) for a fresh idea. It rides *inside* the
/// New Plan kickoff prompt, so it is terse, self-describing, and hard-
/// capped — the caller fences it in a code block; this type never does.
///
/// `render` is a pure function (input order in, same bytes out, no I/O);
/// `build` is the async assembly that reads the live `DocStore` and, for
/// running plans, the worktree territory via an injected diffstat closure
/// (so tests never shell out).
enum IntakeDigest {
    /// Serialized ceiling. The digest shares a prompt with the disposition
    /// instructions, so an unbounded inventory would crowd them out. Sits
    /// well past a healthy project's plan count; over it, the tail is
    /// dropped and an explicit marker takes its place.
    static let maxBytes = 2048

    /// Remaining tasks listed per plan before the rest collapse into a
    /// `… +N more` line — enough to convey shape, not so many that one
    /// busy plan dominates the digest.
    static let maxTasksPerPlan = 6

    /// One plan's row in the digest. Deliberately a plain tuple: the
    /// caller (`build`, or a test) owns the projection from `PlanDoc`.
    typealias Entry = (
        title: String,
        path: String,
        status: PlanStatus,
        feature: String?,
        remainingTasks: [String]
    )

    /// Format the inventory. `plans` render in the given order (never
    /// sorted here); `territories` maps a plan path to its touched
    /// top-level paths (present only for running plans); `queue` is the
    /// current queue order. Output is plain text with no surrounding
    /// fence, capped at `maxBytes` with a truncation marker.
    static func render(
        plans: [Entry],
        territories: [String: [String]],
        queue: [String]
    ) -> String {
        guard !plans.isEmpty else { return "(no plans on record)" }

        var lines: [String] = []
        for plan in plans {
            var header = "- \(plan.title) — \(plan.status.label), \(plan.path)"
            if let feature = plan.feature, !feature.isEmpty {
                header += ", feature \(feature)"
            }
            lines.append(header)

            let shown = plan.remainingTasks.prefix(maxTasksPerPlan)
            for title in shown {
                lines.append("    · \(title)")
            }
            let overflow = plan.remainingTasks.count - shown.count
            if overflow > 0 {
                lines.append("    · … +\(overflow) more")
            }

            // Territory is populated only for running plans, so its mere
            // presence is the signal — no need to re-check status here.
            if let touched = territories[plan.path], !touched.isEmpty {
                lines.append("    touches: \(touched.joined(separator: ", "))")
            }
        }

        if !queue.isEmpty {
            lines.append("")
            lines.append("queue: \(queue.joined(separator: " → "))")
        }

        return capped(lines)
    }

    /// Join `lines` with newlines, stopping before the running total
    /// would exceed `maxBytes`. On overflow, whole trailing lines are
    /// dropped and a marker naming the number of dropped lines is
    /// appended so the truncation is never silent. The result is always
    /// ≤ `maxBytes`.
    private static func capped(_ lines: [String]) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            let candidate = out.isEmpty ? line : out + "\n" + line
            guard candidate.utf8.count > maxBytes else { out = candidate; continue }

            let marker = "… [truncated — \(lines.count - i) more line(s)]"
            var kept = out
            while !kept.isEmpty,
                  kept.utf8.count + 1 + marker.utf8.count > maxBytes {
                if let nl = kept.lastIndex(of: "\n") {
                    kept = String(kept[..<nl])
                } else {
                    kept = ""
                }
            }
            return kept.isEmpty ? marker : kept + "\n" + marker
        }
        return out
    }

    /// Assemble the digest from live app state. Reads the in-memory
    /// `DocStore` inventory (plans, statuses, remaining tasks) and, for
    /// running plans, the touched territory: `<repoRoot>/<feature>` is the
    /// worktree per repo, and `diffstat` returns its top-level paths.
    /// Merged plans are dropped — they are noise for a disposition. The
    /// diffstat closure is injected (defaulting to real git) so tests
    /// never spawn a process.
    @MainActor
    static func build(
        docStore: DocStore,
        repoRoots: [URL],
        queue: [String],
        featureExists: (String) -> Bool,
        diffstat: @Sendable (URL) async -> [String] = {
            await GitOperations.diffStatTopLevelPaths(in: $0)
        }
    ) async -> String {
        var entries: [Entry] = []
        var territories: [String: [String]] = [:]

        for plan in docStore.plans {
            let status = docStore.status(for: plan, featureExists: featureExists)
            guard status != .merged else { continue }

            let path = docStore.relativePath(of: plan)
            let feature = docStore.ledger.recordForPlan(path)?.featureName
            let remaining = plan.tasks
                .filter { task in task.steps.contains { !$0.checked } }
                .map(\.title)
                .filter { !$0.isEmpty }
            entries.append((
                title: plan.title, path: path, status: status,
                feature: feature, remainingTasks: remaining))

            if status == .running, let feature {
                var touched: [String] = []
                for repoRoot in repoRoots {
                    let worktree = repoRoot.appendingPathComponent(feature, isDirectory: true)
                    touched.append(contentsOf: await diffstat(worktree))
                }
                // Dedupe across repos and order deterministically — the
                // per-repo git output order is not something to depend on.
                let unique = Array(Set(touched)).sorted()
                if !unique.isEmpty { territories[path] = unique }
            }
        }

        return render(plans: entries, territories: territories, queue: queue)
    }
}
