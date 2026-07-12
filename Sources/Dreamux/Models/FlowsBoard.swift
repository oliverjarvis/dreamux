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
        /// GitHub PR lifecycle for this lane's workspace, if tracked — a
        /// derived, per-render annotation from `prStatesByWorkspace`, never
        /// part of the CLI-agnostic `Flow`/`FlowStatus` model.
        var prState: PRLaneState? = nil
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
    /// user's mental model; the session is its engine). When multiple
    /// ad-hoc sessions exist on the same plan workspace, the highest-priority
    /// one (by status and freshness) becomes the engine; all others stay visible.
    static func compose(
        planLanes: [Flow], sessionLanes: [Flow],
        prStatesByWorkspace: [UUID: PRLaneState] = [:]
    ) -> FlowsBoard {
        let planWorkspaces = Set(planLanes.compactMap(\.workspaceID))

        // Group ad-hoc sessions by workspace for those that match plan workspaces
        var adhocByWorkspace: [UUID: [Flow]] = [:]
        var otherSessions: [Flow] = []

        for session in sessionLanes {
            if session.kind == .adhoc,
               let ws = session.workspaceID, planWorkspaces.contains(ws) {
                if adhocByWorkspace[ws] == nil {
                    adhocByWorkspace[ws] = []
                }
                adhocByWorkspace[ws]?.append(session)
            } else {
                otherSessions.append(session)
            }
        }

        // Choose the engine session per workspace (highest priority by status then freshness)
        var engineByWorkspace: [UUID: Flow] = [:]
        var extraSessionsByWorkspace: [UUID: [Flow]] = [:]

        for (ws, sessions) in adhocByWorkspace {
            let sorted = sessions.sorted { a, b in
                let aPriority = statusPriority(a.status)
                let bPriority = statusPriority(b.status)
                if aPriority != bPriority {
                    return aPriority > bPriority
                }
                // Tie-break by newest startedAt
                return (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
            }
            engineByWorkspace[ws] = sorted[0]
            if sorted.count > 1 {
                extraSessionsByWorkspace[ws] = Array(sorted.dropFirst())
            }
        }

        var lanes: [Lane] = []

        // Add non-matching sessions and extra sessions from the same workspace
        for session in otherSessions {
            lanes.append(Lane(
                flow: session,
                effectiveStatus: session.status,
                sessionChip: chip(for: session.status, kind: session.kind),
                prState: session.workspaceID.flatMap { prStatesByWorkspace[$0] }
            ))
        }

        for (_, extraSessions) in extraSessionsByWorkspace {
            for session in extraSessions {
                lanes.append(Lane(
                    flow: session,
                    effectiveStatus: session.status,
                    sessionChip: chip(for: session.status, kind: session.kind),
                    prState: session.workspaceID.flatMap { prStatesByWorkspace[$0] }
                ))
            }
        }

        // Process plan lanes with their engine sessions
        for plan in planLanes {
            var flow = plan
            var effective = plan.status
            var chipText: String? = nil
            if let ws = plan.workspaceID, let live = engineByWorkspace[ws] {
                if live.detail != nil { flow.detail = live.detail }
                // A live waiting/running session outranks derived plan
                // status for "what is happening right now".
                if live.status == .waiting || live.status == .failed
                    || (live.status == .running && effective != .waiting && effective != .failed) {
                    effective = live.status
                }
                chipText = chip(for: live.status, kind: .adhoc)
            }
            lanes.append(Lane(
                flow: flow, effectiveStatus: effective, sessionChip: chipText,
                prState: flow.workspaceID.flatMap { prStatesByWorkspace[$0] }
            ))
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
            needsYouCount: lanes.filter { $0.effectiveStatus == .waiting || $0.effectiveStatus == .failed }.count
        )
    }

    private static func statusPriority(_ status: FlowStatus) -> Int {
        switch status {
        case .waiting: return 5
        case .running: return 4
        case .queued: return 3
        case .failed: return 2
        case .done: return 1
        }
    }

    private static func section(for lane: Lane) -> SectionKind {
        // Needs-you outranks everything, including the scheduled section:
        // a background session waiting on a human is the board's most
        // actionable state and must never hide under ↺.
        if lane.effectiveStatus == .waiting || lane.effectiveStatus == .failed { return .needsYou }
        if lane.flow.kind == .scheduled { return .scheduled }
        switch lane.effectiveStatus {
        case .running: return .running
        case .queued: return .queued
        case .done: return .finished
        case .waiting, .failed: return .needsYou // unreachable; keeps switch exhaustive
        }
    }

    private static func chip(for status: FlowStatus, kind: FlowKind) -> String? {
        guard kind == .adhoc else { return nil }
        switch status {
        case .queued: return "idle"
        case .waiting: return "waiting on you"
        case .running: return "claude busy"
        case .failed: return "failed"
        case .done: return nil
        }
    }
}
