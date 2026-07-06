// Sources/Dreamux/Views/FlowsOverviewView.swift
import SwiftUI

/// The Flows pane: sections of lanes composed by FlowsBoard, refreshed
/// whenever FlowStore publishes (3 s registry cadence + live hook
/// signals) or plan state changes a render pass.
struct FlowsOverviewView: View {
    @ObservedObject var flows: FlowStore
    let planLaneInputs: () -> [PlanLaneInput]
    let onJumpToTerminal: (UUID) -> Void

    @State private var showFinished = false

    private var board: FlowsBoard {
        FlowsBoard.compose(
            planLanes: PlanFlowBuilder.lanes(from: planLaneInputs()),
            sessionLanes: flows.flows
        )
    }

    var body: some View {
        let board = self.board
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                headerRow(board)
                if board.sections.isEmpty {
                    emptyState
                } else {
                    ForEach(board.sections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(16)
        }
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
    private func sectionView(_ section: FlowsBoard.Section) -> some View {
        if section.kind == .finished {
            DisclosureGroup(isExpanded: $showFinished) {
                lanesList(section.lanes)
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
                lanesList(section.lanes)
            }
        }
    }

    private func lanesList(_ lanes: [FlowsBoard.Lane]) -> some View {
        ForEach(lanes) { lane in
            FlowLaneView(lane: lane, onJumpToTerminal: onJumpToTerminal)
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
