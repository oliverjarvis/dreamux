// Sources/Dreamux/Views/FlowsOverviewView.swift
import SwiftUI

/// The Flows pane: sections of lanes composed by FlowsBoard, refreshed
/// whenever FlowStore publishes (3 s registry cadence + live hook
/// signals) or plan state changes a render pass.
struct FlowsOverviewView: View {
    @ObservedObject var flows: FlowStore
    let planLaneInputs: () -> [PlanLaneInput]
    /// Grafts a plan lane's live subagents (Task 3's `RunLaneGraft`) onto its
    /// task nodes before the lane reaches `FlowsBoard.compose` — a closure
    /// (not a stored value) so it always sees live `FlowStore`/`DocStore`
    /// state, same pattern as `planLaneInputs`/`projectGraph`.
    let graftSubagents: (Flow) -> Flow
    /// The project's plan-dependency DAG for the overview's "This project"
    /// panel — a closure (not a stored value) so it's rebuilt each render
    /// pass from live `DocStore` state, same pattern as `planLaneInputs`.
    let projectGraph: () -> ProjectGraph
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
            planLanes: PlanFlowBuilder.lanes(from: inputs).map(graftSubagents),
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
                        projectGraphPanel(board)
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

    /// The project's plan-dependency DAG, shown above the sections whenever
    /// there's more than a single node to relate — a lone plan (or none)
    /// has nothing to say here. A node tap zooms straight to that plan's
    /// lane, same destination as clicking its row below.
    @ViewBuilder
    private func projectGraphPanel(_ board: FlowsBoard) -> some View {
        let graph = projectGraph()
        if graph.nodes.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("This project")
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    ProjectGraphView(graph: graph, compact: false) { id in
                        // Only zoom when a lane exists for this plan — a merged/
                        // done node has none, so leave the overview as-is rather
                        // than dangle `zoomedLaneID` at a laneless id.
                        if lane(forID: id, in: board) != nil { zoomedLaneID = id }
                    }
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
            }
            .padding(.bottom, 6)
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
