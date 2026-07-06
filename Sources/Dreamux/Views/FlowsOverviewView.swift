// Sources/Dreamux/Views/FlowsOverviewView.swift
import SwiftUI

/// The Flows pane: sections of lanes composed by FlowsBoard, refreshed
/// whenever FlowStore publishes (3 s registry cadence + live hook
/// signals) or plan state changes a render pass.
struct FlowsOverviewView: View {
    @ObservedObject var flows: FlowStore
    let planLaneInputs: () -> [PlanLaneInput]
    /// Lane id currently zoomed into (or `nil` for the overview),
    /// lifted to `ContentView` so the e2e `zoomFlow` command and a
    /// lane tap both drive the same state.
    @Binding var zoomedLaneID: String?
    let onJumpToTerminal: (UUID) -> Void
    let onOpenTranscript: (String) -> Void
    /// Zoom lazy-tail seam (`ProjectSession.beginFlowsZoom`/
    /// `endFlowsZoom`, keyed by session id) — fired from the detail
    /// view's appear/disappear below, not from `FlowDetailView` itself
    /// (it only knows its lane, not the tailer pool).
    let onZoomBegin: (String) -> Void
    let onZoomEnd: (String) -> Void
    /// Gate-card wiring (ContentView is the only layer that can reach
    /// git, the workspace store, and the plan queue) — passed straight
    /// through to every plan lane's `GateActionCard`.
    let gateActions: FlowGateActions

    @State private var showFinished = false

    var body: some View {
        let inputs = planLaneInputs()
        let board = FlowsBoard.compose(
            planLanes: PlanFlowBuilder.lanes(from: inputs),
            sessionLanes: flows.flows
        )
        // Which plan lanes may offer "merge & continue" (Task 2's
        // predicate), keyed by lane id so `lanesList` can look it up
        // per-lane without re-deriving `PlanLaneInput`s itself.
        let mergeActionableLaneIDs = Set(
            inputs.filter(PlanFlowBuilder.isGateMergeActionable)
                .map { "plan-\($0.planPath)" })
        return Group {
            if let zoomedLaneID, let lane = lane(forID: zoomedLaneID, in: board) {
                FlowDetailView(
                    lane: lane,
                    onBack: { self.zoomedLaneID = nil },
                    onJumpToTerminal: onJumpToTerminal,
                    onOpenTranscript: onOpenTranscript,
                    gateActions: gateActions,
                    gateMergeActionable: mergeActionableLaneIDs.contains(lane.id)
                )
                // Without this, zooming straight from one lane to another
                // (non-nil -> different non-nil, e.g. a second zoomFlow before
                // clearing the first) reuses the same view identity — SwiftUI
                // sees "still a FlowDetailView here" and never fires
                // onDisappear/onAppear, so the old lane's lazy tail never
                // releases and the new lane's never begins.
                .id(zoomedLaneID)
                .onAppear {
                    if let sessionID = lane.flow.sessionID { onZoomBegin(sessionID) }
                }
                .onDisappear {
                    if let sessionID = lane.flow.sessionID { onZoomEnd(sessionID) }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        headerRow(board)
                        if board.sections.isEmpty {
                            emptyState
                        } else {
                            ForEach(board.sections) { section in
                                sectionView(section, mergeActionableLaneIDs: mergeActionableLaneIDs)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onChange(of: board) { oldBoard, newBoard in
            // Clear zoom binding if the zoomed lane no longer exists in the board
            if zoomedLaneID != nil && lane(forID: zoomedLaneID!, in: newBoard) == nil {
                zoomedLaneID = nil
            }
        }
    }

    /// First lane matching `id` across every section, regardless of
    /// whether the Finished disclosure group is expanded — that's only
    /// a display fold, not a data filter.
    private func lane(forID id: String, in board: FlowsBoard) -> FlowsBoard.Lane? {
        for section in board.sections {
            if let match = section.lanes.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    private func headerRow(_ board: FlowsBoard) -> some View {
        HStack(spacing: 10) {
            Text("Flows")
                .font(.title3.weight(.semibold))
            Spacer()
            if board.runningCount > 0 {
                badge("\(board.runningCount) running", color: FlowStatusGlyph.color(.running))
            }
            if board.needsYouCount > 0 {
                badge("\(board.needsYouCount) needs you", color: FlowStatusGlyph.color(.waiting))
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private func sectionView(_ section: FlowsBoard.Section, mergeActionableLaneIDs: Set<String>) -> some View {
        if section.kind == .finished {
            DisclosureGroup(isExpanded: $showFinished) {
                lanesList(section.lanes, mergeActionableLaneIDs: mergeActionableLaneIDs)
            } label: {
                Text("\(section.kind.title) (\(section.lanes.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                lanesList(section.lanes, mergeActionableLaneIDs: mergeActionableLaneIDs)
            }
        }
    }

    private func lanesList(_ lanes: [FlowsBoard.Lane], mergeActionableLaneIDs: Set<String>) -> some View {
        ForEach(lanes) { lane in
            FlowLaneView(
                lane: lane,
                onJumpToTerminal: onJumpToTerminal,
                onZoom: { zoomedLaneID = lane.id },
                gateActions: gateActions,
                gateMergeActionable: mergeActionableLaneIDs.contains(lane.id)
            )
            .opacity(lane.effectiveStatus == .done ? 0.6 : 1.0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing in flight")
                .font(.headline)
            Text("Run a plan, or open a terminal and start claude — sessions, subagents, and plan runs appear here as live lanes the moment they start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.top, 24)
    }
}
