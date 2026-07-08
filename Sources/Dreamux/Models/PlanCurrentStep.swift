import Foundation

/// The rail's compact-card one-liner naming what's in flight right now —
/// pure over `plan.tasks`, reusing `PlanPhases`' grouping/current-group
/// rule and the "first task with an unchecked step" rule the Overview's
/// checklist uses, but rendered short enough for a card (`Phase N`/
/// `Task N[.N]`, not the full heading prose).
enum PlanCurrentStep {
    /// `"Phase 1 · Task 1.10"` for a phased plan's current phase/task,
    /// `"Task 3"` when the plan is unphased, or nil when nothing is in
    /// flight (every step checked, or no tasks carry steps at all).
    static func label(for plan: PlanDoc) -> String? {
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        guard !tasks.isEmpty else { return nil }

        if PlanPhases.shouldGroup(tasks) {
            let groups = PlanPhases.groups(tasks)
            guard let currentIndex = PlanPhases.currentGroupIndex(groups) else { return nil }
            let group = groups[currentIndex]
            guard let task = currentTask(in: group.tasks) else { return nil }
            guard let phase = shortPhase(group.phase) else { return taskLabel(task) }
            return "\(phase) · \(taskLabel(task))"
        }

        guard let task = currentTask(in: tasks) else { return nil }
        return taskLabel(task)
    }

    /// The first task carrying an unchecked step, within the given
    /// (already phase-scoped, where applicable) task list.
    private static func currentTask(in tasks: [PlanTask]) -> PlanTask? {
        tasks.first { task in task.steps.contains { !$0.checked } }
    }

    /// `"Phase 1 — Core mechanic"` → `"Phase 1"`; a section name that
    /// isn't a `Phase N` heading is used verbatim (better than dropping
    /// the phase entirely).
    private static func shortPhase(_ phase: String?) -> String? {
        guard let phase else { return nil }
        guard let match = phase.range(of: #"^Phase\s+\d+"#, options: .regularExpression)
        else { return phase }
        return String(phase[match])
    }

    /// `"Task 1.10: The real thing"` → `"Task 1.10"`; a synthetic/untitled
    /// task (no heading) falls back to `"Steps"`, matching the rail's own
    /// fallback for the same case.
    private static func taskLabel(_ task: PlanTask) -> String {
        guard let match = task.title.range(
            of: #"^Task\s+\d+(?:\.\d+)*"#, options: .regularExpression)
        else { return task.title.isEmpty ? "Steps" : task.title }
        return String(task.title[match])
    }
}
