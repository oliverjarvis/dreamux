import Foundation

/// CLI-agnostic run-graph model for the Flows observatory. Nothing in
/// this file may reference Claude vocabulary — adapters (e.g.
/// `ClaudeFlowAdapter`) translate tool-specific artifacts into these
/// shapes. See docs/superpowers/specs/2026-07-06-flows-observatory-design.md.

enum FlowStatus: String, Codable, Hashable, Sendable {
    case queued, running, waiting, done, failed
}

enum FlowKind: String, Codable, Hashable, Sendable {
    case plan       // driven by a plan run (lane skeleton from plan state)
    case adhoc      // an interactive session with no plan attached
    case scheduled  // background/recurring (registry kind == "bg")
}

enum FlowNodeKind: String, Codable, Hashable, Sendable {
    case source, phase, agent, step, task, gate, drain
}

enum FlowEdgeKind: String, Codable, Hashable, Sendable {
    case sequence, spawn, dependency, message, loop
}

/// Small typed counters bag shown as node badges (never a [String: Any]).
struct FlowCounters: Hashable, Codable, Sendable {
    var tokens: Int?
    var findings: Int?
    var multiplicity: Int?

    init(tokens: Int? = nil, findings: Int? = nil, multiplicity: Int? = nil) {
        self.tokens = tokens
        self.findings = findings
        self.multiplicity = multiplicity
    }
}

struct FlowNode: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var kind: FlowNodeKind
    var label: String
    var status: FlowStatus
    var startedAt: Date?
    var endedAt: Date?
    var counters: FlowCounters
    /// Inspector's "last activity" line — a tool summary or agent
    /// description, refreshed as transcript events arrive.
    var lastActivity: String?

    init(
        id: String,
        kind: FlowNodeKind,
        label: String,
        status: FlowStatus,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        counters: FlowCounters = FlowCounters(),
        lastActivity: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.counters = counters
        self.lastActivity = lastActivity
    }
}

struct FlowEdge: Hashable, Codable, Sendable {
    var from: String
    var to: String
    var kind: FlowEdgeKind
    var label: String?
    /// Loop edges only: how many times the cycle has repeated.
    var iterations: Int?

    init(from: String, to: String, kind: FlowEdgeKind, label: String? = nil, iterations: Int? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.label = label
        self.iterations = iterations
    }
}

/// One lane in the Flows pane: a source→drain DAG plus lane metadata.
struct Flow: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var kind: FlowKind
    var workspaceID: UUID?
    /// Backing session identifier in the source tool, when there is one.
    var sessionID: String?
    /// The session's working directory, when known — the zoom detail
    /// view's lazy-tail seam and its "open transcript" button both
    /// derive `ClaudeHome` paths from this rather than re-deriving a
    /// workspace's cwd, since a lane can outlive the workspace lookup
    /// (a finished session's workspace may since have been removed).
    var sessionCwd: String?
    /// One-line needs-you context (e.g. the permission-request text).
    var detail: String?
    var startedAt: Date?
    var nodes: [FlowNode]
    var edges: [FlowEdge]
    /// Set once a lane's transcript tail has dropped enough unparsable
    /// lines that its detail can't be trusted (see `noteSkippedLines`).
    var detailUnavailable: Bool

    init(
        id: String,
        title: String,
        kind: FlowKind,
        workspaceID: UUID? = nil,
        sessionID: String? = nil,
        sessionCwd: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil,
        nodes: [FlowNode] = [],
        edges: [FlowEdge] = [],
        detailUnavailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.sessionCwd = sessionCwd
        self.detail = detail
        self.startedAt = startedAt
        self.nodes = nodes
        self.edges = edges
        self.detailUnavailable = detailUnavailable
    }

    /// Lane status, derived. Precedence mirrors what the user must see
    /// first: blocked-on-me beats everything, activity beats outcomes,
    /// a failure beats not-started, and an empty lane reads as done.
    var status: FlowStatus { Flow.aggregateStatus(of: nodes) }

    static func aggregateStatus(of nodes: [FlowNode]) -> FlowStatus {
        let statuses = Set(nodes.map(\.status))
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.queued) { return .queued }
        return .done
    }
}

/// Sidebar-badge aggregates published by FlowStore.
struct FlowAggregates: Hashable, Sendable {
    var runningCount: Int
    var needsYouCount: Int
}
