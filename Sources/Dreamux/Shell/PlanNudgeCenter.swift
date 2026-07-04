import Foundation
import Observation

/// Parks and delivers *nudges* — one-line prompts typed into a running
/// plan's live agent — for the two Phase-2 intake flows (spec: "Phase 2 —
/// integrating into a RUNNING plan" and "Phase 2 — course correction").
///
/// A nudge is enqueued when work is folded into a plan whose agent is
/// already executing: an intake-integrate append (detected here on a
/// DocStore refresh, `noteRefresh`) or a course correction (Task 3 calls
/// `enqueue`). Delivery is deliberately *not* immediate — the same
/// quiescence discipline every programmatic send obeys governs it:
///
/// - **Quiescence**: never type into a streaming agent. A nudge delivers
///   only when the feature's agent tab has been quiet (`isQuiescent`);
///   otherwise it stays parked and `deliverPending` retries it — from the
///   queue's poll tick and from each DocStore refresh (both wired in
///   `ProjectSession`).
/// - **Gate rail**: a plan the queue holds at a merge gate, or that is
///   awaiting review, never receives a nudge — the fix-task/append is
///   still written, but the nudge parks until the plan resumes.
/// - **No double-delivery**: a parked nudge is removed only after it is
///   sent, so repeated ticks can't type it twice.
///
/// Every terminal-touching effect is an injected closure (`status`,
/// `isQuiescent`, `send`), so the state machine is unit-testable without a
/// real PTY — `ProjectSession` wires the closures to the live stores.
@MainActor
@Observable
final class PlanNudgeCenter {
    /// A parked nudge: which feature's agent to type into, the exact
    /// one-line prompt, and when it was filed (injected by the caller so
    /// the store never reads `Date.now` itself).
    struct Nudge: Equatable {
        let featureName: String
        let prompt: String
        let createdAt: Date
    }

    /// Pending nudges keyed by plan path — at most one per plan (a newer
    /// nudge for the same plan replaces the parked one; the latest
    /// instruction wins).
    private(set) var pending: [String: Nudge] = [:]

    /// Pending nudge count, for the e2e state dump (Task 4).
    var pendingCount: Int { pending.count }

    // MARK: - Injected effects (wired in ProjectSession; fakes in tests)

    /// The plan's derived status, for the gate rail. `nil` (unresolvable
    /// plan) parks the nudge. `ProjectSession` folds the queue's `atGate`
    /// into `awaitingReview` here so a course correction that adds an
    /// unchecked step (which would otherwise flip the derived status back
    /// to `running`) can't slip a nudge past the merge gate.
    @ObservationIgnored var status: (String) -> PlanStatus? = { _ in nil }

    /// Whether the plan's agent tab is quiescent (prompt drawn, not
    /// streaming). `false` when there is no live agent tab, which parks the
    /// nudge until one exists.
    @ObservationIgnored var isQuiescent: (String) -> Bool = { _ in false }

    /// Deliver `prompt` into the plan's agent tab, echo-verified (the
    /// production wiring reuses `ClaudePromptDriver`). Called only for a
    /// nudge that has cleared the gate rail and the quiescence check.
    @ObservationIgnored var send: (_ planPath: String, _ prompt: String) -> Void = { _, _ in }

    /// Statuses at which the gate rail parks a nudge rather than delivering
    /// it. A plan at a merge gate reads as `awaitingReview` (all boxes
    /// checked, feature open) — see `ProjectSession`'s `status` wiring.
    static let gatedStatuses: Set<PlanStatus> = [.awaitingReview]

    // MARK: - Enqueue

    /// Park a nudge for `planPath`, replacing any nudge already parked for
    /// the same plan. `createdAt` is injected so tests and the e2e harness
    /// stay deterministic.
    func enqueue(planPath: String, featureName: String, prompt: String, createdAt: Date) {
        guard !planPath.isEmpty else { return }
        pending[planPath] = Nudge(featureName: featureName, prompt: prompt, createdAt: createdAt)
    }

    // MARK: - Delivery

    /// Attempt to deliver every parked nudge. Each is sent only when its
    /// plan is not gated (the gate rail) and its agent is quiescent; a
    /// nudge that clears both is delivered and removed. Anything gated or
    /// busy stays parked for a later tick. Safe to call repeatedly — a
    /// removed nudge is never re-sent.
    func deliverPending() {
        for (path, nudge) in pending where deliverable(path) {
            send(path, nudge.prompt)
            pending[path] = nil
        }
    }

    private func deliverable(_ path: String) -> Bool {
        guard let status = status(path) else { return false }
        guard !Self.gatedStatuses.contains(status) else { return false }
        return isQuiescent(path)
    }

    // MARK: - Appended-task detection (intake-integrate)

    /// Last-seen parse per plan path — the snapshot the appended-task
    /// detector diffs against. Held here (the detection seam), never in
    /// `DocStore`.
    @ObservationIgnored private var lastSeen: [String: PlanDoc] = [:]

    /// Fold a DocStore refresh in: for every RUNNING plan whose task list
    /// grew since the last scan with a non-course-correction append, park a
    /// `planUpdated` re-read nudge (spec: "Phase 2 — integrating into a
    /// RUNNING plan"). Course-correction appends carry the
    /// `*(course correction …)*` marker and are Task 3's own flow, so they
    /// are suppressed here to avoid a double nudge. A plan seen for the
    /// first time only records a baseline; non-running plans only update
    /// the snapshot.
    func noteRefresh(
        docs: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        status: (PlanDoc) -> PlanStatus,
        featureName: (String) -> String?,
        now: () -> Date
    ) {
        for doc in docs where doc.kind == .plan {
            let path = relativePath(doc)
            defer { lastSeen[path] = doc }
            guard let before = lastSeen[path], status(doc) == .running else { continue }
            guard let range = IntakeGrowthDetector.appendedTaskRange(before: before, after: doc),
                  let feature = featureName(path) else { continue }
            enqueue(planPath: path, featureName: feature,
                    prompt: PlanPrompts.planUpdated(taskRange: range, planRelativePath: path),
                    createdAt: now())
        }
    }
}

/// Pure classifier for intake-integrate appends: given two parses of one
/// plan, whether (and where) a re-read nudge is owed. Kept free of state
/// so the growth tests drive it with before/after `PlanDoc`s directly.
enum IntakeGrowthDetector {
    /// The appended task-number range between two parses of the same plan,
    /// or `nil` when there's nothing to nudge: `totalSteps` didn't grow, no
    /// genuinely new task heading appeared (e.g. a step added to an
    /// existing task), or the new tasks are course corrections (which carry
    /// their own nudge). Detection keys on task TITLES, not positions, so a
    /// fix-task inserted mid-document is still recognized as new.
    static func appendedTaskRange(before: PlanDoc, after: PlanDoc) -> String? {
        guard after.totalSteps > before.totalSteps else { return nil }
        let beforeTitles = Set(before.tasks.map(\.title))
        let newTasks = after.tasks.filter { !$0.title.isEmpty && !beforeTitles.contains($0.title) }
        guard !newTasks.isEmpty else { return nil }
        guard !newTasks.contains(where: { $0.title.contains("*(course correction") }) else {
            return nil
        }
        return range(of: newTasks)
    }

    /// A `Task 5` / `Task 5–Task 7` range from the appended tasks' leading
    /// `Task N[.M]` labels; falls back to a plain count when the headings
    /// don't carry parseable numbers.
    private static func range(of tasks: [PlanTask]) -> String {
        let labels = tasks.compactMap { taskLabel($0.title) }
        if let first = labels.first, let last = labels.last {
            return first == last ? first : "\(first)–\(last)"
        }
        return tasks.count == 1 ? "1 new task" : "\(tasks.count) new tasks"
    }

    /// The `Task N[.M]` label at the head of a task title (matching the
    /// parser's heading grammar): `Task 5: Foo *(added …)*` → `Task 5`.
    private static func taskLabel(_ title: String) -> String? {
        guard let range = title.range(
            of: #"^Task\s+\d+(?:\.\d+)*"#, options: .regularExpression) else { return nil }
        return String(title[range])
    }
}
