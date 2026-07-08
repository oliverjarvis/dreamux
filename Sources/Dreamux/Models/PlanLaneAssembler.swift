import Foundation

/// Assembles `PlanLaneInput`s from live store state — the one place
/// plan state becomes lane inputs. Hoisted verbatim from ContentView's
/// `planLaneInputs()` (line-by-line verified in the Flows-tailer G2
/// final review) so both the Flows pane and the e2e `flowsState`
/// command build lanes through the same, now-testable path.
@MainActor
enum PlanLaneAssembler {
    /// Assemble PlanLaneInputs from the same state `PlansSpecsSection`
    /// renders: DocStore plans, derived PlanStatus, PlanPhases groups,
    /// queue position, ledger start time, live workspace.
    static func inputs(
        docStore: DocStore,
        queue: PlanQueueController,
        store: WorkspaceStore
    ) -> [PlanLaneInput] {
        docStore.plans.map { plan in
            let path = docStore.relativePath(of: plan)
            let status = docStore.status(for: plan) { name in store.featureNames.contains(name) }
            // Mirrors the same task filter used elsewhere (the Overview's
            // checklist, `PlanCurrentStep`): a heading with no checkbox
            // steps (e.g. `### Notes`) isn't a row worth counting.
            let tasks = plan.tasks.filter { !$0.steps.isEmpty }
            let phaseSummaries: [PlanPhaseSummary]
            if PlanPhases.shouldGroup(tasks) {
                phaseSummaries = PlanPhases.groups(tasks).map {
                    PlanPhaseSummary(title: $0.phase ?? "Steps", checkedSteps: $0.checkedSteps, totalSteps: $0.totalSteps)
                }
            } else {
                let checked = tasks.reduce(0) { $0 + $1.steps.filter(\.checked).count }
                let total = tasks.reduce(0) { $0 + $1.steps.count }
                phaseSummaries = total > 0
                    ? [PlanPhaseSummary(title: "tasks", checkedSteps: checked, totalSteps: total)]
                    : []
            }
            let record = docStore.ledger.recordForPlan(path)
            let feature = AdHocWorkspaces.featureName(for: plan) { doc in
                docStore.ledger.recordForPlan(docStore.relativePath(of: doc))
            }
            let workspace = store.featureWorkspace(named: feature)
            return PlanLaneInput(
                planPath: path,
                title: plan.title,
                status: status,
                phases: phaseSummaries,
                queueOrdinal: queue.entries.firstIndex(of: path).map { $0 + 1 },
                isCurrentQueuePlan: queue.currentPlanPath == path,
                queueState: queue.state,
                workspaceID: workspace?.id,
                startedAt: record?.startedAt
            )
        }
    }
}
