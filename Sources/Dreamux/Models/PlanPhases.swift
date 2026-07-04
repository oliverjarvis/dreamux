import Foundation

/// Groups a plan's tasks by their recorded `## ` section for the
/// sidebar's expansion — pure logic, testable without the view, in the
/// house style of `InitiativeProgress`/`PlanWorkspacePresence`.
enum PlanPhases {
    struct Group: Equatable {
        let phase: String?
        let tasks: [PlanTask]

        var checkedSteps: Int { tasks.reduce(0) { $0 + $1.steps.filter(\.checked).count } }
        var totalSteps: Int { tasks.reduce(0) { $0 + $1.steps.count } }
    }

    /// Consecutive tasks sharing a phase collapse into one group, in
    /// document order. (Phases don't interleave in practice; consecutive
    /// grouping keeps document order authoritative if one ever does.)
    static func groups(_ tasks: [PlanTask]) -> [Group] {
        var result: [Group] = []
        for task in tasks {
            if let last = result.last, last.phase == task.phase {
                result[result.count - 1] = Group(phase: last.phase, tasks: last.tasks + [task])
            } else {
                result.append(Group(phase: task.phase, tasks: [task]))
            }
        }
        return result
    }

    /// Phase grouping only materializes when at least two DISTINCT named
    /// sections contain tasks — a plan whose tasks all sit under one
    /// generic H2 (`## Tasks`), or under none, renders its tasks flat
    /// exactly as before.
    static func shouldGroup(_ tasks: [PlanTask]) -> Bool {
        Set(tasks.compactMap(\.phase)).count >= 2
    }

    /// The group holding the plan's current task (first task with an
    /// unchecked step), so the sidebar can default-expand just that
    /// phase. Nil when everything is checked.
    static func currentGroupIndex(_ groups: [Group]) -> Int? {
        groups.firstIndex { group in
            group.tasks.contains { task in task.steps.contains { !$0.checked } }
        }
    }
}
