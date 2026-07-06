import Foundation
import Combine

/// Per-project store of Flow lanes. Pure state machine: the three
/// feeds (registry poll, live signals, launch replay) call `apply`,
/// views read `flows`/`aggregates`. No parsing, no IO — that lives in
/// the adapter and the feed owners (ProjectSession wiring).
@MainActor
final class FlowStore: ObservableObject {
    @Published private(set) var flows: [Flow] = []
    @Published private(set) var aggregates = FlowAggregates(runningCount: 0, needsYouCount: 0)

    /// Maps a session's cwd to a workspace so lanes link to worktrees
    /// and terminal tabs. Injected: ProjectSession supplies the real
    /// lookup; tests supply stubs.
    private let workspaceForCwd: (String) -> UUID?

    init(workspaceForCwd: @escaping (String) -> UUID? = { _ in nil }) {
        self.workspaceForCwd = workspaceForCwd
    }

    // MARK: - Registry feed

    /// Reconcile lanes against a registry snapshot: upsert a lane per
    /// live session, and complete lanes whose session vanished.
    func apply(registry entries: [ClaudeSessionEntry]) {
        var seen = Set<String>()
        for entry in entries {
            let laneID = "session-\(entry.sessionId)"
            seen.insert(laneID)
            var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
                laneID: laneID,
                sessionID: entry.sessionId,
                kind: entry.isBackground ? .scheduled : .adhoc,
                cwd: entry.cwd
            )
            lane.title = entry.name ?? entry.sessionId
            if lane.workspaceID == nil { lane.workspaceID = workspaceForCwd(entry.cwd) }
            setNode(in: &lane, id: "session") { node in
                node.status = entry.flowStatus
                node.label = "claude"
            }
            if entry.flowStatus != .waiting { lane.detail = nil }
            upsert(lane)
        }
        // Sessions that disappeared from the registry are over. Skip
        // lanes already done so a steady-state poll doesn't republish
        // `flows` forever; event-created lanes can't be swept wrongly
        // here since the registry file is written at session start,
        // before any hook event can fire.
        for index in flows.indices where !seen.contains(flows[index].id) && flows[index].status != .done {
            completeSessionNodes(in: &flows[index])
        }
        recomputeAggregates()
    }

    // MARK: - Event feed (live signals + replay)

    func apply(event: FlowEvent) {
        let laneID: String
        switch event {
        case let .agentStarted(sessionID, _, _, _, _, _),
             let .agentStopped(sessionID, _, _, _),
             let .taskCreated(sessionID, _, _, _, _),
             let .taskCompleted(sessionID, _, _, _),
             let .sessionStopped(sessionID, _, _),
             let .notification(sessionID, _, _, _):
            laneID = "session-\(sessionID)"
        }
        var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
            laneID: laneID,
            sessionID: String(laneID.dropFirst("session-".count)),
            kind: .adhoc,
            cwd: event.cwd
        )

        switch event {
        case let .agentStarted(_, agentID, agentType, description, _, at):
            let nodeID = "agent-\(agentID)"
            if !lane.nodes.contains(where: { $0.id == nodeID }) {
                lane.nodes.append(FlowNode(
                    id: nodeID,
                    kind: .agent,
                    label: agentType ?? description ?? agentID,
                    status: .running,
                    startedAt: at
                ))
                lane.edges.append(FlowEdge(from: "session", to: nodeID, kind: .spawn))
            }
        case let .agentStopped(_, agentID, _, at):
            setNode(in: &lane, id: "agent-\(agentID)") { node in
                node.status = .done
                node.endedAt = at
            }
        case let .taskCreated(_, taskID, subject, _, at):
            // A nil task_id means a malformed hook payload — there's no
            // id a later taskCompleted could ever match, so drop it
            // rather than mint an unclosable node.
            guard let taskID else { break }
            let nodeID = "task-\(taskID)"
            if !lane.nodes.contains(where: { $0.id == nodeID }) {
                lane.nodes.append(FlowNode(
                    id: nodeID, kind: .task, label: subject ?? "task", status: .queued, startedAt: at
                ))
                lane.edges.append(FlowEdge(from: "session", to: nodeID, kind: .spawn))
            }
        case let .taskCompleted(_, taskID, _, at):
            if let taskID {
                setNode(in: &lane, id: "task-\(taskID)") { node in
                    node.status = .done
                    node.endedAt = at
                }
            }
        case let .notification(_, message, _, _):
            lane.detail = message
        case .sessionStopped:
            completeSessionNodes(in: &lane)
        }
        upsert(lane)
        recomputeAggregates()
    }

    // MARK: - Internals

    private func makeSessionLane(laneID: String, sessionID: String, kind: FlowKind, cwd: String?) -> Flow {
        Flow(
            id: laneID,
            title: sessionID,
            kind: kind,
            workspaceID: cwd.flatMap(workspaceForCwd),
            sessionID: sessionID,
            startedAt: Date(),
            nodes: [
                FlowNode(id: "src", kind: .source, label: "prompt", status: .done),
                FlowNode(id: "session", kind: .agent, label: "claude", status: .running),
                FlowNode(id: "drain", kind: .drain, label: "done", status: .queued),
            ],
            edges: [
                FlowEdge(from: "src", to: "session", kind: .sequence),
                FlowEdge(from: "session", to: "drain", kind: .sequence),
            ]
        )
    }

    private func completeSessionNodes(in lane: inout Flow) {
        setNode(in: &lane, id: "session") { $0.status = .done }
        setNode(in: &lane, id: "drain") { $0.status = .done }
        // A vanished session can't be waiting on anyone.
        lane.detail = nil
        // Anything still running or queued (e.g. a task that was never
        // completed) is over now too — the session that would have
        // finished it is gone.
        for index in lane.nodes.indices
        where lane.nodes[index].status == .running || lane.nodes[index].status == .queued {
            lane.nodes[index].status = .done
        }
    }

    /// Mutate one node by id. A missing node is ignored silently —
    /// degrade, never break.
    private func setNode(in lane: inout Flow, id: String, _ mutate: (inout FlowNode) -> Void) {
        guard let index = lane.nodes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&lane.nodes[index])
    }

    private func upsert(_ lane: Flow) {
        if let index = flows.firstIndex(where: { $0.id == lane.id }) {
            flows[index] = lane
        } else {
            flows.append(lane)
        }
    }

    private func recomputeAggregates() {
        let next = FlowAggregates(
            runningCount: flows.filter { $0.status == .running }.count,
            needsYouCount: flows.filter { $0.status == .waiting }.count
        )
        // @Published fires objectWillChange on assignment regardless of
        // equality, so skip the write when nothing actually changed.
        guard next != aggregates else { return }
        aggregates = next
    }
}
