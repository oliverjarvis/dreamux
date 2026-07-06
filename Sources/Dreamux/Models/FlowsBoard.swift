import Foundation

/// The composed, ordered content of the Flows pane. Pure function of
/// (plan lanes, session lanes) so ordering/suppression/badge logic is
/// unit-tested without views. Views render it verbatim.
struct FlowsBoard: Equatable {
    enum SectionKind: String, CaseIterable {
        case needsYou, running, queued, scheduled, finished

        var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .running: return "Running"
            case .queued: return "Queued & idle"
            case .scheduled: return "Scheduled"
            case .finished: return "Finished"
            }
        }
    }

    struct Lane: Equatable, Identifiable {
        let flow: Flow
        /// Lane status after bubbling live session state onto plan lanes.
        let effectiveStatus: FlowStatus
        /// Short trailing chip text: "idle", "waiting on you", nil.
        let sessionChip: String?
        var id: String { flow.id }
    }

    struct Section: Equatable, Identifiable {
        let kind: SectionKind
        let lanes: [Lane]
        var id: String { kind.rawValue }
    }

    let sections: [Section]
    let runningCount: Int
    let needsYouCount: Int

    /// Compose the board. Ad-hoc session lanes whose workspace already
    /// has a plan lane are suppressed — their live status and needs-you
    /// detail bubble onto the plan lane instead (the plan lane is the
    /// user's mental model; the session is its engine).
    static func compose(planLanes: [Flow], sessionLanes: [Flow]) -> FlowsBoard {
        let planWorkspaces = Set(planLanes.compactMap(\.workspaceID))

        var lanes: [Lane] = []
        var liveByWorkspace: [UUID: Flow] = [:]
        for session in sessionLanes {
            if session.kind == .adhoc,
               let ws = session.workspaceID, planWorkspaces.contains(ws) {
                liveByWorkspace[ws] = session // suppressed; feeds its plan lane
            } else {
                lanes.append(Lane(
                    flow: session,
                    effectiveStatus: session.status,
                    sessionChip: chip(for: session.status, kind: session.kind)
                ))
            }
        }
        for plan in planLanes {
            var flow = plan
            var effective = plan.status
            var chipText: String? = nil
            if let ws = plan.workspaceID, let live = liveByWorkspace[ws] {
                if live.detail != nil { flow.detail = live.detail }
                // A live waiting/running session outranks derived plan
                // status for "what is happening right now".
                if live.status == .waiting || (live.status == .running && effective != .waiting) {
                    effective = live.status
                }
                chipText = chip(for: live.status, kind: .adhoc)
            }
            lanes.append(Lane(flow: flow, effectiveStatus: effective, sessionChip: chipText))
        }

        let sections = SectionKind.allCases.compactMap { kind -> Section? in
            let members = lanes
                .filter { section(for: $0) == kind }
                .sorted { ($0.flow.startedAt ?? .distantPast) > ($1.flow.startedAt ?? .distantPast) }
            return members.isEmpty ? nil : Section(kind: kind, lanes: members)
        }

        return FlowsBoard(
            sections: sections,
            runningCount: lanes.filter { $0.effectiveStatus == .running }.count,
            needsYouCount: lanes.filter { $0.effectiveStatus == .waiting }.count
        )
    }

    private static func section(for lane: Lane) -> SectionKind {
        if lane.flow.kind == .scheduled { return .scheduled }
        switch lane.effectiveStatus {
        case .waiting: return .needsYou
        case .running: return .running
        case .queued: return .queued // includes idle-but-alive sessions
        case .failed: return .needsYou // a failure needs the human too
        case .done: return .finished
        }
    }

    private static func chip(for status: FlowStatus, kind: FlowKind) -> String? {
        guard kind == .adhoc else { return nil }
        switch status {
        case .queued: return "idle"
        case .waiting: return "waiting on you"
        case .running: return "claude busy"
        case .done, .failed: return nil
        }
    }
}
