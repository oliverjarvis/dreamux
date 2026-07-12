import Foundation

/// One phase of a plan, pre-summarized so the builder stays decoupled
/// from PlanDoc/PlanPhases internals — the glue in ContentView does the
/// summarizing.
struct PlanPhaseSummary: Equatable {
    let title: String
    let checkedSteps: Int
    let totalSteps: Int
}

/// One checkbox-bearing task, projected for lane/node consumers that need
/// per-task detail (not just phase rollups).
struct PlanTaskSummary: Equatable {
    let line: Int
    let title: String
    let phase: String?
    let checkedSteps: Int
    let totalSteps: Int
    let isCurrent: Bool

    /// Project a plan's checkbox-bearing tasks into lane summaries. The
    /// current task is the first with an unchecked step (PlanCurrentStep's
    /// rule); an all-checked plan has none.
    static func summaries(from tasks: [PlanTask]) -> [PlanTaskSummary] {
        let real = tasks.filter { !$0.steps.isEmpty }
        let currentLine = real.first { $0.steps.contains { !$0.checked } }?.line
        return real.map { t in
            PlanTaskSummary(
                line: t.line, title: PlanTaskTitle.clean(t.title), phase: t.phase,
                checkedSteps: t.steps.filter(\.checked).count, totalSteps: t.steps.count,
                isCurrent: t.line == currentLine)
        }
    }
}

/// Everything the builder needs to know about one plan. Assembled by
/// thin glue from DocStore + PlanQueueController + PlanRunLedger +
/// WorkspaceStore; pure value so tests construct it directly.
struct PlanLaneInput: Equatable {
    let planPath: String
    let title: String
    let status: PlanStatus
    let phases: [PlanPhaseSummary]
    let queueOrdinal: Int?
    let isCurrentQueuePlan: Bool
    let queueState: PlanQueueState?
    let workspaceID: UUID?
    let startedAt: Date?
    let tasks: [PlanTaskSummary]

    init(
        planPath: String,
        title: String,
        status: PlanStatus,
        phases: [PlanPhaseSummary],
        queueOrdinal: Int?,
        isCurrentQueuePlan: Bool,
        queueState: PlanQueueState?,
        workspaceID: UUID?,
        startedAt: Date?,
        tasks: [PlanTaskSummary] = []
    ) {
        self.planPath = planPath
        self.title = title
        self.status = status
        self.phases = phases
        self.queueOrdinal = queueOrdinal
        self.isCurrentQueuePlan = isCurrentQueuePlan
        self.queueState = queueState
        self.workspaceID = workspaceID
        self.startedAt = startedAt
        self.tasks = tasks
    }
}

/// Plan state → plan-kind Flow lanes. Pure; no store access.
///
/// Lane shape: src → phase-0 … phase-N [→ gate] → drain.
/// - src: done once the plan has started (any status past .ready).
/// - phase-i: done when fully checked, running when partially checked
///   AND the plan is actively running, else queued.
/// - gate: present when the plan needs the human — queue atGate or
///   attention on this plan, or status .awaitingReview — always .waiting.
/// - drain: done only when merged.
enum PlanFlowBuilder {
    static func lanes(from inputs: [PlanLaneInput]) -> [Flow] {
        inputs.compactMap(lane(from:))
    }

    private static func lane(from input: PlanLaneInput) -> Flow? {
        guard input.status != .specOnly else { return nil }

        let started = input.status != .ready
        let isActive = input.status == .running
        let needsHuman = input.status == .awaitingReview
            || (input.isCurrentQueuePlan && (input.queueState == .atGate || input.queueState == .attention))

        var nodes: [FlowNode] = [
            FlowNode(id: "src", kind: .source, label: "plan", status: started ? .done : .queued),
        ]
        let phases = input.phases.isEmpty
            ? [PlanPhaseSummary(title: "tasks", checkedSteps: 0, totalSteps: 1)]
            : input.phases
        for (index, phase) in phases.enumerated() {
            let status: FlowStatus
            if input.status == .merged || (phase.totalSteps > 0 && phase.checkedSteps == phase.totalSteps) {
                status = .done
            } else if isActive && phase.checkedSteps > 0 {
                status = .running
            } else if isActive && isFirstUnfinished(phases, index) {
                status = .running
            } else {
                status = .queued
            }
            nodes.append(FlowNode(id: "phase-\(index)", kind: .phase, label: phase.title, status: status))
        }
        if needsHuman {
            nodes.append(FlowNode(id: "gate", kind: .gate, label: "review & merge", status: .waiting))
        }
        nodes.append(FlowNode(id: "drain", kind: .drain, label: "merge",
                              status: input.status == .merged ? .done : .queued))

        var edges: [FlowEdge] = []
        for pair in zip(nodes, nodes.dropFirst()) {
            edges.append(FlowEdge(from: pair.0.id, to: pair.1.id, kind: .sequence))
        }

        var flow = Flow(
            id: "plan-\(input.planPath)",
            title: input.title,
            kind: .plan,
            workspaceID: input.workspaceID,
            sessionID: nil,
            startedAt: input.startedAt,
            nodes: nodes,
            edges: edges
        )
        if let ordinal = input.queueOrdinal, input.status == .ready {
            flow.detail = "queued #\(ordinal)"
        }
        return flow
    }

    /// The active plan's "current" phase: the first not-fully-checked one.
    private static func isFirstUnfinished(_ phases: [PlanPhaseSummary], _ index: Int) -> Bool {
        let firstUnfinished = phases.firstIndex { $0.checkedSteps < $0.totalSteps }
        return firstUnfinished == index
    }

    /// Whether the gate card may offer "merge & continue" for this plan.
    /// True exactly when the plan is truly at review: derived
    /// `.awaitingReview` (all boxes checked, feature open), or the queue
    /// holds THIS plan at its gate (which survives a course correction
    /// flipping the derived status back to `.running`). `attention`
    /// deliberately fails — steps are unchecked, and the queue box's
    /// Resume/Skip is the recovery surface, not a merge.
    static func isGateMergeActionable(_ input: PlanLaneInput) -> Bool {
        input.status == .awaitingReview
            || (input.isCurrentQueuePlan && input.queueState == .atGate)
    }
}
