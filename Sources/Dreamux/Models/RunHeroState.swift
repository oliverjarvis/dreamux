import Foundation

/// Maps a plan-backed run's derived state to the Overview hero's treatment:
/// which status pill to show, which `FlowStatus` color it takes, whether the
/// progress bar reads "complete" (green) or "in flight" (accent), and which
/// primary action the run's moment calls for. Pure and total so it can be
/// table-tested without the view.
struct RunHeroState: Equatable {
    enum Phase: Equatable { case ready, running, paused, awaitingReview, merged }
    enum PrimaryAction: Equatable {
        case run             // lime RunPlanButton — start or resume the plan agent
        case running         // RunningIndicator — agent is live; not a button
        case reviewAndMerge  // filled button → gateActions.requestMerge
        case noPrimary       // merged — no primary action
    }

    let phase: Phase
    let pillText: String
    let flow: FlowStatus        // -> FlowStatusGlyph.color/.symbol for the pill
    let progressComplete: Bool  // green bar when true, accent bar when false
    let primary: PrimaryAction

    /// `status` is `docStore.status(for:)`; `hasLiveAgent` is whether a live
    /// claude agent tab is working this workspace (the same signal the rail
    /// uses). A materialized Mode-A workspace never actually reports
    /// `.ready`/`.specOnly`, but both are handled for totality.
    static func resolve(status: PlanStatus, hasLiveAgent: Bool) -> RunHeroState {
        switch status {
        case .merged:
            return RunHeroState(phase: .merged, pillText: "Merged",
                                flow: .done, progressComplete: true, primary: .noPrimary)
        case .awaitingReview:
            return RunHeroState(phase: .awaitingReview, pillText: "Awaiting your review",
                                flow: .waiting, progressComplete: true, primary: .reviewAndMerge)
        case .running, .inProgress:
            if hasLiveAgent {
                return RunHeroState(phase: .running, pillText: "Running",
                                    flow: .running, progressComplete: false, primary: .running)
            }
            return RunHeroState(phase: .paused, pillText: "Paused",
                                flow: .queued, progressComplete: false, primary: .run)
        case .ready, .specOnly:
            return RunHeroState(phase: .ready, pillText: "Ready to run",
                                flow: .queued, progressComplete: false, primary: .run)
        }
    }
}
