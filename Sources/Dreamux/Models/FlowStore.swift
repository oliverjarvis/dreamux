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
                cwd: entry.cwd,
                startedAt: Date()
            )
            lane.title = entry.name ?? entry.sessionId
            // An event-created lane defaults to .adhoc (it arrives before
            // the registry can say otherwise); once the registry is seen,
            // its `kind` is the source of truth on every poll.
            lane.kind = entry.isBackground ? .scheduled : .adhoc
            if lane.workspaceID == nil { lane.workspaceID = workspaceForCwd(entry.cwd) }
            setNode(in: &lane, id: "session") { node in
                node.status = entry.flowStatus
                node.label = "claude"
            }
            if entry.flowStatus == .running || entry.flowStatus == .waiting {
                // Self-heal: a stale/replayed sessionStopped event can
                // mark drain done while the registry shows this session
                // is still alive (e.g. before the SessionEnd fix, a
                // per-turn Stop-hook misfire did exactly this). The
                // vanish-sweep below remains the fallback terminal for
                // sessions that actually crashed.
                setNode(in: &lane, id: "drain") { node in
                    if node.status == .done { node.status = .queued }
                }
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
            cwd: event.cwd,
            startedAt: event.at
        )

        switch event {
        case let .agentStarted(_, agentID, agentType, description, _, at):
            let nodeID = "agent-\(agentID)"
            if !lane.nodes.contains(where: { $0.id == nodeID }) {
                insertBeforeDrain(in: &lane, FlowNode(
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
                insertBeforeDrain(in: &lane, FlowNode(
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

    // MARK: - Transcript feed (tailer + zoom)

    /// toolUseID → agentID, keyed by lane, once `apply(meta:)` has
    /// joined a subagent's hook identity to its transcript tool-call
    /// id. `apply(transcript:)` consults this to decide whether a
    /// `toolFinished` result closes an agent or an ordinary tool call.
    private var agentIDByToolUse: [String: [String: String]] = [:]
    private var pendingSpawns: [String: [String: (type: String?, desc: String?)]] = [:]
    private var skippedByLane: [String: Int] = [:]

    private static let skippedLinesThreshold = 50
    private static let agentFanOutCap = 6
    private static let collapsedAgentNodeID = "agents-collapsed"

    /// A transcript event's own `at`, when it has one — used only to
    /// seed a lane's `startedAt` if the transcript beats the registry.
    private func transcriptAt(_ event: TranscriptEvent) -> Date? {
        switch event {
        case let .toolStarted(_, _, _, at), let .toolFinished(_, _, at), let .agentSpawned(_, _, _, at):
            return at
        }
    }

    func apply(transcript event: TranscriptEvent, sessionID: String) {
        let laneID = "session-\(sessionID)"
        var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
            laneID: laneID, sessionID: sessionID, kind: .adhoc, cwd: nil, startedAt: transcriptAt(event) ?? Date()
        )

        switch event {
        case let .toolStarted(toolUseID, tool, summary, _):
            // Agent/Task tool_use blocks never reach here as toolStarted
            // (the parser already routed them to agentSpawned); the
            // join-map check is defense in depth against an id collision.
            if agentIDByToolUse[laneID]?[toolUseID] == nil && pendingSpawns[laneID]?[toolUseID] == nil {
                setNode(in: &lane, id: "session") { $0.lastActivity = summary ?? tool }
            }
        case let .agentSpawned(toolUseID, agentType, description, _):
            if let agentID = agentIDByToolUse[laneID]?[toolUseID] {
                setNode(in: &lane, id: "agent-\(agentID)") { node in
                    if let agentType { node.label = agentType }
                }
            } else {
                // Hooks own node creation; a replayed transcript slice
                // can re-observe the same spawn line, so this never
                // mints a node itself.
                pendingSpawns[laneID, default: [:]][toolUseID] = (agentType, description)
            }
        case let .toolFinished(toolUseID, isError, at):
            // `.failed` is reserved for agent results — a failed
            // ordinary tool call (a Bash exit-1, a bad Read) is normal
            // agent life and must not surface as a lane failure.
            if let agentID = agentIDByToolUse[laneID]?[toolUseID] {
                setNode(in: &lane, id: "agent-\(agentID)") { node in
                    node.status = isError ? .failed : .done
                    node.endedAt = at
                }
            }
        }

        collapseFanOut(in: &lane)
        upsert(lane)
        recomputeAggregates()
    }

    func apply(meta: SubagentMeta, sessionID: String) {
        let laneID = "session-\(sessionID)"
        var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
            laneID: laneID, sessionID: sessionID, kind: .adhoc, cwd: nil, startedAt: Date()
        )

        var pending: (type: String?, desc: String?)?
        if let toolUseID = meta.toolUseID {
            agentIDByToolUse[laneID, default: [:]][toolUseID] = meta.agentID
            pending = pendingSpawns[laneID]?.removeValue(forKey: toolUseID)
        }
        setNode(in: &lane, id: "agent-\(meta.agentID)") { node in
            node.label = meta.agentType ?? pending?.type ?? node.label
            node.lastActivity = meta.description ?? pending?.desc ?? node.lastActivity
        }

        collapseFanOut(in: &lane)
        upsert(lane)
        recomputeAggregates()
    }

    func apply(agentActivity: String, agentID: String, sessionID: String) {
        let laneID = "session-\(sessionID)"
        var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
            laneID: laneID, sessionID: sessionID, kind: .adhoc, cwd: nil, startedAt: Date()
        )
        setNode(in: &lane, id: "agent-\(agentID)") { $0.lastActivity = agentActivity }
        upsert(lane)
        recomputeAggregates()
    }

    /// Cumulative per lane: a transcript tail that keeps dropping
    /// malformed/oversized lines eventually can't be trusted, so the
    /// lane says so instead of silently showing a partial picture.
    func noteSkippedLines(_ count: Int, sessionID: String) {
        let laneID = "session-\(sessionID)"
        var lane = flows.first { $0.id == laneID } ?? makeSessionLane(
            laneID: laneID, sessionID: sessionID, kind: .adhoc, cwd: nil, startedAt: Date()
        )
        skippedByLane[laneID, default: 0] += count
        if skippedByLane[laneID]! >= Self.skippedLinesThreshold {
            lane.detailUnavailable = true
        }
        upsert(lane)
        recomputeAggregates()
    }

    /// Keeps the overview pipeline legible: once a lane's agent-ish
    /// node count exceeds the cap, the oldest *done* agents merge into
    /// one `agents-collapsed` node. Running/waiting/failed agents are
    /// never touched — only finished work piles up.
    private func collapseFanOut(in lane: inout Flow) {
        let agentIndices = lane.nodes.indices.filter {
            lane.nodes[$0].kind == .agent && lane.nodes[$0].id != "session"
        }
        guard agentIndices.count > Self.agentFanOutCap else { return }

        let hasCollapsed = lane.nodes.contains { $0.id == Self.collapsedAgentNodeID }
        let excess = agentIndices.count - Self.agentFanOutCap
        // Folding the first candidates into a brand-new collapsed node
        // costs one node (N done → 1 collapsed), so it takes one extra
        // merge to net the same reduction as growing an existing one.
        let needed = hasCollapsed ? excess : excess + 1

        let doneCandidates = agentIndices
            .filter { lane.nodes[$0].status == .done && lane.nodes[$0].id != Self.collapsedAgentNodeID }
            .sorted { (lane.nodes[$0].startedAt ?? .distantPast) < (lane.nodes[$1].startedAt ?? .distantPast) }
        let toMerge = Array(doneCandidates.prefix(needed))
        guard !toMerge.isEmpty else { return }

        let mergedIDs = Set(toMerge.map { lane.nodes[$0].id })
        lane.nodes.removeAll { mergedIDs.contains($0.id) }
        lane.edges.removeAll { mergedIDs.contains($0.from) || mergedIDs.contains($0.to) }

        if let index = lane.nodes.firstIndex(where: { $0.id == Self.collapsedAgentNodeID }) {
            lane.nodes[index].counters.multiplicity = (lane.nodes[index].counters.multiplicity ?? 0) + toMerge.count
        } else {
            insertBeforeDrain(in: &lane, FlowNode(
                id: Self.collapsedAgentNodeID, kind: .agent, label: "agents", status: .done,
                counters: FlowCounters(multiplicity: toMerge.count)
            ))
            lane.edges.append(FlowEdge(from: "session", to: Self.collapsedAgentNodeID, kind: .spawn))
        }
    }

    // MARK: - Internals

    private func makeSessionLane(laneID: String, sessionID: String, kind: FlowKind, cwd: String?, startedAt: Date) -> Flow {
        Flow(
            id: laneID,
            title: sessionID,
            kind: kind,
            workspaceID: cwd.flatMap(workspaceForCwd),
            sessionID: sessionID,
            startedAt: startedAt,
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

    /// Insert a newly-arrived agent/task node just before the drain
    /// node, so lanes render `prompt → claude → agent/task… → done`
    /// (PROTOCOL.md's documented order) instead of shunting new work
    /// behind the terminal skeleton node. Falls back to append when no
    /// drain node exists.
    private func insertBeforeDrain(in lane: inout Flow, _ node: FlowNode) {
        if let drainIndex = lane.nodes.firstIndex(where: { $0.id == "drain" }) {
            lane.nodes.insert(node, at: drainIndex)
        } else {
            lane.nodes.append(node)
        }
    }

    private func upsert(_ lane: Flow) {
        if let index = flows.firstIndex(where: { $0.id == lane.id }) {
            // @Published fires objectWillChange on assignment regardless
            // of equality, so skip the write when nothing actually
            // changed — otherwise a steady-state registry poll
            // republishes `flows` every cycle for identical state.
            guard flows[index] != lane else { return }
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

/// Pure helpers for wiring FlowStore into a project. Kept off the
/// store so they're testable without MainActor hops.
enum FlowWiring {
    /// Match a session cwd to a workspace: the feature aggregation dir
    /// (`features/<name>/`) or any per-repo worktree
    /// (`<root>/repos/<repo>/<name>/`), boundary-safe.
    static func workspaceID(forCwd cwd: String, workspaces: [Workspace], projectRoot: URL) -> UUID? {
        for workspace in workspaces {
            var candidates: [String] = []
            if let wd = workspace.workingDirectory, !wd.isEmpty { candidates.append(wd) }
            for repo in workspace.linkedRepoIDs {
                candidates.append(
                    projectRoot
                        .appendingPathComponent("repos", isDirectory: true)
                        .appendingPathComponent(repo, isDirectory: true)
                        .appendingPathComponent(workspace.name, isDirectory: true)
                        .path
                )
            }
            for candidate in candidates {
                if cwd == candidate || cwd.hasPrefix(candidate + "/") { return workspace.id }
            }
        }
        return nil
    }
}
