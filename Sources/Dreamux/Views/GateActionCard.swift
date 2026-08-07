// Sources/Dreamux/Views/GateActionCard.swift
import SwiftUI
import AppKit

/// Gate-card actions, injected from ContentView — the only layer that
/// can reach git, the workspace store, and the plan queue. Each closure
/// lands on an existing, already-tested channel: diff tabs via
/// `WorkspaceSession.openDiffTab`, merge via
/// `PlanQueueController.mergeAndContinue` or
/// `ProjectSession.pendingGateMergeWorkspaceID` (the sidebar's sheet).
struct FlowGateActions {
    let openDiff: (UUID) -> Void
    let requestMerge: (UUID) -> Void
    let fetchDiffStat: (UUID) async -> GitBranchDiffStat?
    /// Present the merge sheet with publish emphasized (reuses the
    /// existing pendingGateMergeWorkspaceID channel + MergeFlow.publish).
    let requestPublish: (UUID) -> Void
    /// Async, appearance-time — mirrors fetchDiffStat. Decides whether
    /// "Create PR" is offered for this workspace.
    let fetchPublishAvailability: (UUID) async -> PublishAvailability
}

/// The expanded gate card (spec "Gate cards"): headline, branch-vs-base
/// diff stat, [view diff], and — only when the plan is truly at review —
/// [merge & continue]. Embedded by the canvas's native inspector
/// (`FlowsCanvasView`), which is the one place a waiting gate is
/// actioned from.
struct GateActionCard: View {
    let workspaceID: UUID
    /// False for the queue-`attention` gate: the plan stalled with steps
    /// unchecked, so a merge would ship half a plan (and the queue's
    /// mergeAndContinue would refuse anyway). The card degrades to
    /// diff-inspection; Resume/Skip live in the sidebar's queue box.
    let mergeActionable: Bool
    let actions: FlowGateActions
    /// GitHub PR lifecycle for this gate's workspace, if tracked (Task 6's
    /// `FlowsBoard.Lane.prState`, threaded through by the caller). `nil`
    /// renders today's card unchanged — no badge, no "View PR" button.
    let prState: PRLaneState?

    /// A `let` default value doesn't produce a memberwise-init parameter
    /// (Swift hardcodes it instead), so this explicit init is what
    /// actually makes `prState` optional at call sites.
    init(workspaceID: UUID, mergeActionable: Bool, actions: FlowGateActions, prState: PRLaneState? = nil) {
        self.workspaceID = workspaceID
        self.mergeActionable = mergeActionable
        self.actions = actions
        self.prState = prState
    }

    /// One-shot fetch on appearance; a stat seconds stale is fine and
    /// the card is rare (spec: no new pollers).
    @State private var stat: GitBranchDiffStat?
    /// One-shot fetch alongside `stat` — decides whether "Create PR"
    /// is offered next to "Merge locally". Defaults to `.noRemote` so
    /// the card renders today's single "Merge & continue" button until
    /// the fetch lands.
    @State private var publish: PublishAvailability = .noRemote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    mergeActionable ? "waiting: review & merge" : "waiting: needs attention",
                    systemImage: mergeActionable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FlowStatusGlyph.color(.waiting))
                if let prState {
                    Spacer(minLength: 8)
                    PRStatusBadge(state: prState, onOpen: openPR)
                }
            }
            if let stat {
                HStack(spacing: 6) {
                    Text("+\(stat.insertions)")
                        .foregroundStyle(.green)
                    Text("−\(stat.deletions)")
                        .foregroundStyle(.red)
                    Text("· \(stat.filesChanged) file\(stat.filesChanged == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button("View diff") { actions.openDiff(workspaceID) }
                if prState != nil {
                    Button("View PR", action: openPR)
                }
                if mergeActionable {
                    if publish == .available {
                        Button("Merge locally") { actions.requestMerge(workspaceID) }
                        Button("Create PR") { actions.requestPublish(workspaceID) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Merge & continue") { actions.requestMerge(workspaceID) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FlowStatusGlyph.color(.waiting).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(FlowStatusGlyph.color(.waiting).opacity(0.25), lineWidth: 1)
        )
        .task {
            stat = await actions.fetchDiffStat(workspaceID)
            publish = await actions.fetchPublishAvailability(workspaceID)
        }
    }

    /// Opens the tracked PR in the user's browser; guards the URL parse
    /// since `prState.url` is server-sourced text, not a validated URL.
    private func openPR() {
        guard let prState, let url = URL(string: prState.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
