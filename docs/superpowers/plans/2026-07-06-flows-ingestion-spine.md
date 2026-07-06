# Flows Group 1 — Ingestion Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the data spine of the Flows observatory: CLI-agnostic FlowGraph model types, a per-project `FlowStore` fed by a 3 s claude-session-registry poll and by hook lifecycle events riding the signals bus, launch replay from signals.db, and the shim/hook changes that emit those events — no UI.

**Architecture:** Three feeds converge on `FlowStore` (`@MainActor`, one per `ProjectSession`): (1) `ClaudeRegistryPoller` reads `$DREAMUX_CLAUDE_HOME/sessions/*.json` every 3 s for session liveness/status; (2) `dreamux-hook` gains a `flow` subcommand that writes `{action:"emit",signal:{…}}` lines to the existing signal emit socket, so SubagentStart/Stop, TaskCreated/Completed, Stop, and Notification become persisted Signals which `ClaudeFlowAdapter` translates to `FlowEvent`s; (3) on launch, `FlowReplayLoader` queries signals.db (24 h window, 5,000-signal cap) to rebuild lanes. All Claude-specific parsing lives in `ClaudeFlowAdapter`/`ClaudeSessionRegistry`; FlowGraph types carry no Claude vocabulary.

**Tech Stack:** Swift 6 / SwiftPM (`swift build`, `swift test`), Combine, XCTest + `TestSandbox`, POSIX `kill(2)` liveness probe, Python 3 (`Tools/dreamux-hook`), POSIX sh (`Tools/claude` shim).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-flows-observatory-design.md`. This plan is Group 1 only — no UI, no transcript tailing, no E2E registration (those are Groups 2–3).
- Claude home root is always resolved via `ClaudeHome.root(environment:)` — `DREAMUX_CLAUDE_HOME` env override, default `~/.claude`. Never hardcode `~/.claude` elsewhere.
- New signal kinds — exact strings: `agent.started`, `agent.stopped`, `task.created`, `task.completed`, `session.stopped`, `session.notification`.
- Hook-side failures are always silent (log-only via the hook's existing `log()`); a hook must never break or slow the user's claude session. Socket writes use a 0.5 s timeout.
- Never read `~/.claude/ide/` or `~/.claude/daemon/`. Registry JSON is untrusted input: tolerant decoding, skip anything malformed.
- Stores are `@MainActor ObservableObject`s constructed in `ProjectSession.init` (house pattern).
- No new package dependencies.
- Commits: stage ONLY the files named in the task (`git add <paths>` — never `git add -A`; parallel sessions may be touching the repo).
- Run tests with `swift test --filter <TestClassName>`; expect ~30 s for an incremental build before test output appears.

---

### Task 1: FlowGraph model types

**Files:**
- Create: `Sources/Dreamux/Models/FlowGraph.swift`
- Test: `Tests/DreamuxTests/FlowGraphTests.swift`

**Interfaces:**
- Consumes: nothing (leaf value types).
- Produces: `FlowStatus`, `FlowKind`, `FlowNodeKind`, `FlowEdgeKind`, `FlowCounters`, `FlowNode`, `FlowEdge`, `Flow` (all `Hashable`, `Codable`, `Sendable`), `Flow.aggregateStatus(of:)`, `FlowAggregates`. Every later task builds on these exact names.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/FlowGraphTests.swift
import XCTest
@testable import Dreamux

final class FlowGraphTests: XCTestCase {
    private func node(_ id: String, _ status: FlowStatus) -> FlowNode {
        FlowNode(id: id, kind: .agent, label: id, status: status)
    }

    func testAggregateStatusPrecedence() {
        // waiting > running > failed > queued > done
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .done), node("b", .waiting), node("c", .running)]), .waiting)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .running), node("b", .failed)]), .running)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .failed), node("b", .queued), node("c", .done)]), .failed)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .queued), node("b", .done)]), .queued)
        XCTAssertEqual(Flow.aggregateStatus(of: [node("a", .done)]), .done)
        XCTAssertEqual(Flow.aggregateStatus(of: []), .done)
    }

    func testFlowStatusUsesAggregate() {
        var flow = Flow(id: "f1", title: "t", kind: .adhoc)
        flow.nodes = [node("a", .running)]
        XCTAssertEqual(flow.status, .running)
    }

    func testCodableRoundTrip() throws {
        var flow = Flow(id: "f1", title: "t", kind: .scheduled)
        flow.workspaceID = UUID()
        flow.sessionID = "s-1"
        flow.detail = "permission: npm run e2e"
        flow.nodes = [FlowNode(id: "n1", kind: .gate, label: "gate", status: .waiting)]
        flow.edges = [FlowEdge(from: "src", to: "n1", kind: .sequence, label: "3 findings", iterations: nil)]
        let data = try JSONEncoder().encode(flow)
        let back = try JSONDecoder().decode(Flow.self, from: data)
        XCTAssertEqual(back, flow)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FlowGraphTests`
Expected: compile FAILURE — `cannot find type 'Flow' in scope` (and friends).

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/FlowGraph.swift
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

    init(
        id: String,
        kind: FlowNodeKind,
        label: String,
        status: FlowStatus,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        counters: FlowCounters = FlowCounters()
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.counters = counters
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
    /// One-line needs-you context (e.g. the permission-request text).
    var detail: String?
    var startedAt: Date?
    var nodes: [FlowNode]
    var edges: [FlowEdge]

    init(
        id: String,
        title: String,
        kind: FlowKind,
        workspaceID: UUID? = nil,
        sessionID: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil,
        nodes: [FlowNode] = [],
        edges: [FlowEdge] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.detail = detail
        self.startedAt = startedAt
        self.nodes = nodes
        self.edges = edges
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FlowGraphTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowGraph.swift Tests/DreamuxTests/FlowGraphTests.swift
git commit -m "Flows: CLI-agnostic FlowGraph model types"
```

---

### Task 2: Claude home resolution + session-registry reader

**Files:**
- Create: `Sources/Dreamux/Models/ClaudeSessionRegistry.swift`
- Test: `Tests/DreamuxTests/ClaudeSessionRegistryTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ClaudeHome.root(environment:) -> URL`; `ClaudeSessionEntry` (`pid: Int32`, `sessionId: String`, `cwd: String`, `status: String`, `name: String?`, `kind: String`, `version: String?`, computed `flowStatus: FlowStatus`, `isBackground: Bool`); `ClaudeSessionRegistryReader` with `init(home: URL, isAlive: @escaping (Int32) -> Bool = ClaudeSessionRegistryReader.processExists)` and `func entries() -> [ClaudeSessionEntry]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/ClaudeSessionRegistryTests.swift
import XCTest
@testable import Dreamux

final class ClaudeSessionRegistryTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private func writeSession(_ name: String, _ json: String) throws {
        let dir = sandbox.root.appendingPathComponent("claude-home/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var home: URL { sandbox.root.appendingPathComponent("claude-home", isDirectory: true) }

    func testClaudeHomeDefaultsAndOverride() {
        let def = ClaudeHome.root(environment: [:])
        XCTAssertEqual(def.path, NSString(string: "~/.claude").expandingTildeInPath)
        let overridden = ClaudeHome.root(environment: ["DREAMUX_CLAUDE_HOME": "/tmp/fake-claude"])
        XCTAssertEqual(overridden.path, "/tmp/fake-claude")
    }

    func testReadsWellFormedEntries() throws {
        try writeSession("101.json", #"""
        {"pid":101,"sessionId":"aaa-bbb","cwd":"/Users/x/proj/features/auth","startedAt":"x",
         "version":"2.1.201","kind":"interactive","name":"clayspace-ba","status":"busy","updatedAt":123}
        """#)
        try writeSession("102.json", #"""
        {"pid":102,"sessionId":"ccc-ddd","cwd":"/Users/x/other","kind":"bg","status":"idle"}
        """#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        let entries = reader.entries().sorted { $0.pid < $1.pid }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].sessionId, "aaa-bbb")
        XCTAssertEqual(entries[0].flowStatus, .running)
        XCTAssertEqual(entries[0].name, "clayspace-ba")
        XCTAssertFalse(entries[0].isBackground)
        XCTAssertTrue(entries[1].isBackground)
        XCTAssertEqual(entries[1].flowStatus, .done) // idle → done ("nothing in flight")
        XCTAssertNil(entries[1].name)
    }

    func testStatusMapping() throws {
        try writeSession("7.json", #"{"pid":7,"sessionId":"s","cwd":"/x","kind":"interactive","status":"waiting"}"#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        XCTAssertEqual(reader.entries().first?.flowStatus, .waiting)
    }

    func testSkipsMalformedAndDeadEntries() throws {
        try writeSession("1.json", #"{"pid":1,"sessionId":"live","cwd":"/x","kind":"interactive","status":"busy"}"#)
        try writeSession("2.json", #"{"pid":2,"sessionId":"dead","cwd":"/x","kind":"interactive","status":"busy"}"#)
        try writeSession("3.json", "not json at all {")
        try writeSession("4.json", #"{"sessionId":"missing-pid"}"#)
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { pid in pid == 1 })
        let entries = reader.entries()
        XCTAssertEqual(entries.map(\.sessionId), ["live"])
    }

    func testMissingSessionsDirYieldsEmpty() {
        let reader = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true })
        XCTAssertEqual(reader.entries(), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeSessionRegistryTests`
Expected: compile FAILURE — `cannot find 'ClaudeHome' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/ClaudeSessionRegistry.swift
import Foundation

/// Where Claude Code keeps its state. Tests and e2e point
/// DREAMUX_CLAUDE_HOME at a synthetic root; production resolves the
/// real `~/.claude`. Always route through here — never hardcode.
enum ClaudeHome {
    static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["DREAMUX_CLAUDE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(
            fileURLWithPath: NSString(string: "~/.claude").expandingTildeInPath,
            isDirectory: true
        )
    }
}

/// One running claude process, as advertised in
/// `<claude-home>/sessions/<pid>.json`. Untrusted, evolving input:
/// we decode only the fields we use and skip files that don't parse.
struct ClaudeSessionEntry: Decodable, Equatable, Sendable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    /// Raw registry status: "idle" | "busy" | "waiting" (open set).
    let status: String
    let name: String?
    /// "interactive" | "bg" (open set).
    let kind: String
    let version: String?

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, status, name, kind, version
    }

    var isBackground: Bool { kind == "bg" }

    /// busy → running; waiting → waiting (blocked on the human);
    /// idle → done — an idle interactive session has nothing in
    /// flight, and unknown future statuses read as done rather than
    /// inventing activity. (Spec: degrade, never break.)
    var flowStatus: FlowStatus {
        switch status {
        case "busy": return .running
        case "waiting": return .waiting
        default: return .done
        }
    }
}

/// Reads the live-session registry. Pure with respect to its inputs:
/// `home` is injected (synthetic roots in tests) and the liveness
/// probe is injected (no real PIDs needed in tests).
struct ClaudeSessionRegistryReader {
    let home: URL
    let isAlive: (Int32) -> Bool

    init(
        home: URL,
        isAlive: @escaping (Int32) -> Bool = ClaudeSessionRegistryReader.processExists
    ) {
        self.home = home
        self.isAlive = isAlive
    }

    /// `kill(pid, 0)` == "does this process exist" without signaling.
    /// EPERM means it exists but isn't ours — still alive.
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Every well-formed, live entry under `<home>/sessions/`. Stale
    /// files (dead PIDs) and malformed JSON are silently skipped —
    /// claude cleans its own registry eventually; we don't wait for it.
    func entries() -> [ClaudeSessionEntry] {
        let dir = home.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ClaudeSessionEntry? in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(ClaudeSessionEntry.self, from: data)
                else { return nil }
                return isAlive(entry.pid) ? entry : nil
            }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeSessionRegistryTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeSessionRegistry.swift Tests/DreamuxTests/ClaudeSessionRegistryTests.swift
git commit -m "Flows: claude home resolution + tolerant session-registry reader"
```

---

### Task 3: Flow signal kinds + FlowEvent adapter

**Files:**
- Modify: `Sources/Dreamux/Signals/SignalEnvelope.swift` (add constants inside `enum SignalKind`, currently at line 65)
- Create: `Sources/Dreamux/Models/ClaudeFlowAdapter.swift`
- Test: `Tests/DreamuxTests/ClaudeFlowAdapterTests.swift`

**Interfaces:**
- Consumes: `Signal`, `SignalPayload` (Signals/SignalEnvelope.swift).
- Produces: `SignalKind.agentStarted/.agentStopped/.taskCreated/.taskCompleted/.sessionStopped/.sessionNotification` (String constants), `SignalKind.flowKinds: [String]`; `FlowEvent` enum with `var at: Date`, `var cwd: String?`; `ClaudeFlowAdapter.event(from: Signal) -> FlowEvent?`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/ClaudeFlowAdapterTests.swift
import XCTest
@testable import Dreamux

final class ClaudeFlowAdapterTests: XCTestCase {
    private func signal(kind: String, payload: [String: SignalPayload], cwd: String? = "/w") -> Signal {
        Signal(
            source: "claude.hooks",
            kind: kind,
            ts: Date(timeIntervalSince1970: 1_000),
            tags: cwd.map { ["cwd": $0] } ?? [:],
            payload: .object(payload)
        )
    }

    func testAgentStarted() {
        let s = signal(kind: SignalKind.agentStarted, payload: [
            "session_id": .string("s1"), "agent_id": .string("a1"),
            "agent_type": .string("Explore"), "description": .string("map repo"),
        ])
        guard case let .agentStarted(sessionID, agentID, agentType, description, cwd, at)? = ClaudeFlowAdapter.event(from: s) else {
            return XCTFail("expected agentStarted")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(agentID, "a1")
        XCTAssertEqual(agentType, "Explore")
        XCTAssertEqual(description, "map repo")
        XCTAssertEqual(cwd, "/w")
        XCTAssertEqual(at, Date(timeIntervalSince1970: 1_000))
    }

    func testAgentStopped() {
        let s = signal(kind: SignalKind.agentStopped, payload: [
            "session_id": .string("s1"), "agent_id": .string("a1"),
        ])
        guard case let .agentStopped(sessionID, agentID, _, _)? = ClaudeFlowAdapter.event(from: s) else {
            return XCTFail("expected agentStopped")
        }
        XCTAssertEqual(sessionID, "s1")
        XCTAssertEqual(agentID, "a1")
    }

    func testTaskAndSessionAndNotification() {
        let created = signal(kind: SignalKind.taskCreated, payload: [
            "session_id": .string("s1"), "task_id": .string("7"), "subject": .string("Fix bug"),
        ])
        guard case let .taskCreated(_, taskID, subject, _, _)? = ClaudeFlowAdapter.event(from: created) else {
            return XCTFail("expected taskCreated")
        }
        XCTAssertEqual(taskID, "7")
        XCTAssertEqual(subject, "Fix bug")

        let completed = signal(kind: SignalKind.taskCompleted, payload: [
            "session_id": .string("s1"), "task_id": .string("7"),
        ])
        guard case .taskCompleted? = ClaudeFlowAdapter.event(from: completed) else {
            return XCTFail("expected taskCompleted")
        }

        let stopped = signal(kind: SignalKind.sessionStopped, payload: ["session_id": .string("s1")])
        guard case .sessionStopped? = ClaudeFlowAdapter.event(from: stopped) else {
            return XCTFail("expected sessionStopped")
        }

        let notif = signal(kind: SignalKind.sessionNotification, payload: [
            "session_id": .string("s1"), "message": .string("needs permission"),
        ])
        guard case let .notification(_, message, _, _)? = ClaudeFlowAdapter.event(from: notif) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(message, "needs permission")
    }

    func testMissingSessionIDOrForeignKindIsNil() {
        XCTAssertNil(ClaudeFlowAdapter.event(from: signal(kind: SignalKind.agentStarted, payload: [:])))
        XCTAssertNil(ClaudeFlowAdapter.event(from: signal(kind: SignalKind.terminalLine, payload: [
            "session_id": .string("s1"),
        ])))
    }

    func testEventAccessors() {
        let s = signal(kind: SignalKind.sessionStopped, payload: ["session_id": .string("s1")], cwd: "/w2")
        let event = ClaudeFlowAdapter.event(from: s)!
        XCTAssertEqual(event.at, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(event.cwd, "/w2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeFlowAdapterTests`
Expected: compile FAILURE — `type 'SignalKind' has no member 'agentStarted'`.

- [ ] **Step 3: Add the kind constants**

In `Sources/Dreamux/Signals/SignalEnvelope.swift`, extend the existing enum body:

```swift
enum SignalKind {
    static let terminalLine = "terminal.line"
    static let serviceHealth = "service.health"

    // Flow lifecycle events emitted by dreamux-hook (Flows spec,
    // 2026-07-06). Exact strings are load-bearing: the hook script
    // and the replay query both use them.
    static let agentStarted = "agent.started"
    static let agentStopped = "agent.stopped"
    static let taskCreated = "task.created"
    static let taskCompleted = "task.completed"
    static let sessionStopped = "session.stopped"
    static let sessionNotification = "session.notification"

    /// Every kind FlowStore consumes — subscription filter + replay set.
    static let flowKinds: [String] = [
        agentStarted, agentStopped, taskCreated,
        taskCompleted, sessionStopped, sessionNotification,
    ]
}
```

- [ ] **Step 4: Write the adapter**

```swift
// Sources/Dreamux/Models/ClaudeFlowAdapter.swift
import Foundation

/// A tool-agnostic lifecycle event consumed by FlowStore. Adapters
/// produce these; nothing downstream knows where they came from.
enum FlowEvent: Equatable, Sendable {
    case agentStarted(sessionID: String, agentID: String, agentType: String?, description: String?, cwd: String?, at: Date)
    case agentStopped(sessionID: String, agentID: String, cwd: String?, at: Date)
    case taskCreated(sessionID: String, taskID: String?, subject: String?, cwd: String?, at: Date)
    case taskCompleted(sessionID: String, taskID: String?, cwd: String?, at: Date)
    case sessionStopped(sessionID: String, cwd: String?, at: Date)
    case notification(sessionID: String, message: String?, cwd: String?, at: Date)

    var at: Date {
        switch self {
        case let .agentStarted(_, _, _, _, _, at), let .agentStopped(_, _, _, at),
             let .taskCreated(_, _, _, _, at), let .taskCompleted(_, _, _, at),
             let .sessionStopped(_, _, at), let .notification(_, _, _, at):
            return at
        }
    }

    var cwd: String? {
        switch self {
        case let .agentStarted(_, _, _, _, cwd, _), let .agentStopped(_, _, cwd, _),
             let .taskCreated(_, _, _, cwd, _), let .taskCompleted(_, _, cwd, _),
             let .sessionStopped(_, cwd, _), let .notification(_, _, cwd, _):
            return cwd
        }
    }
}

/// The ONLY place that knows how claude's hook payloads are shaped.
/// (Registry parsing lives in ClaudeSessionRegistry; transcript
/// parsing arrives with Group 3 and lives here too.)
enum ClaudeFlowAdapter {
    /// nil for signals that aren't flow lifecycle events or that are
    /// missing the session id — never throws, never logs per-signal.
    static func event(from signal: Signal) -> FlowEvent? {
        guard case let .object(fields) = signal.payload else { return nil }
        guard let sessionID = string(fields["session_id"]), !sessionID.isEmpty else { return nil }
        let cwd = signal.tags["cwd"].flatMap { $0.isEmpty ? nil : $0 }
        let at = signal.ts

        switch signal.kind {
        case SignalKind.agentStarted:
            guard let agentID = string(fields["agent_id"]) else { return nil }
            return .agentStarted(
                sessionID: sessionID,
                agentID: agentID,
                agentType: string(fields["agent_type"]),
                description: string(fields["description"]),
                cwd: cwd,
                at: at
            )
        case SignalKind.agentStopped:
            guard let agentID = string(fields["agent_id"]) else { return nil }
            return .agentStopped(sessionID: sessionID, agentID: agentID, cwd: cwd, at: at)
        case SignalKind.taskCreated:
            return .taskCreated(
                sessionID: sessionID,
                taskID: string(fields["task_id"]),
                subject: string(fields["subject"]),
                cwd: cwd,
                at: at
            )
        case SignalKind.taskCompleted:
            return .taskCompleted(sessionID: sessionID, taskID: string(fields["task_id"]), cwd: cwd, at: at)
        case SignalKind.sessionStopped:
            return .sessionStopped(sessionID: sessionID, cwd: cwd, at: at)
        case SignalKind.sessionNotification:
            return .notification(sessionID: sessionID, message: string(fields["message"]), cwd: cwd, at: at)
        default:
            return nil
        }
    }

    private static func string(_ payload: SignalPayload?) -> String? {
        if case let .string(s)? = payload, !s.isEmpty { return s }
        return nil
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ClaudeFlowAdapterTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Signals/SignalEnvelope.swift Sources/Dreamux/Models/ClaudeFlowAdapter.swift Tests/DreamuxTests/ClaudeFlowAdapterTests.swift
git commit -m "Flows: flow signal kinds + hook-signal to FlowEvent adapter"
```

---

### Task 4: FlowStore

**Files:**
- Create: `Sources/Dreamux/Models/FlowStore.swift`
- Test: `Tests/DreamuxTests/FlowStoreTests.swift`

**Interfaces:**
- Consumes: `Flow`/`FlowNode`/`FlowEdge`/`FlowAggregates` (Task 1), `ClaudeSessionEntry` (Task 2), `FlowEvent` (Task 3).
- Produces: `FlowStore` — `@MainActor final class FlowStore: ObservableObject` with `@Published private(set) var flows: [Flow]`, `@Published private(set) var aggregates: FlowAggregates`, `init(workspaceForCwd: @escaping (String) -> UUID?)`, `func apply(registry: [ClaudeSessionEntry])`, `func apply(event: FlowEvent)`. Node id conventions later groups rely on: `"src"`, `"session"`, `"drain"`, `"agent-<agentID>"`, `"task-<taskID>"`; lane id `"session-<sessionId>"`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/FlowStoreTests.swift
import XCTest
@testable import Dreamux

@MainActor
final class FlowStoreTests: XCTestCase {
    private func entry(
        pid: Int32 = 1, session: String = "s1", cwd: String = "/w",
        status: String = "busy", kind: String = "interactive", name: String? = "auth-refresh"
    ) -> ClaudeSessionEntry {
        let json = """
        {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","status":"\(status)",
         "kind":"\(kind)"\(name.map { ",\"name\":\"\($0)\"" } ?? "")}
        """
        return try! JSONDecoder().decode(ClaudeSessionEntry.self, from: Data(json.utf8))
    }

    func testRegistryCreatesSessionLane() {
        let wsID = UUID()
        let store = FlowStore(workspaceForCwd: { $0 == "/w" ? wsID : nil })
        store.apply(registry: [entry()])

        XCTAssertEqual(store.flows.count, 1)
        let lane = store.flows[0]
        XCTAssertEqual(lane.id, "session-s1")
        XCTAssertEqual(lane.title, "auth-refresh")
        XCTAssertEqual(lane.kind, .adhoc)
        XCTAssertEqual(lane.workspaceID, wsID)
        XCTAssertEqual(lane.sessionID, "s1")
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "session", "drain"])
        XCTAssertEqual(lane.nodes[0].status, .done)     // source: the prompt happened
        XCTAssertEqual(lane.nodes[1].status, .running)  // busy
        XCTAssertEqual(lane.nodes[2].status, .queued)   // drain pending
        XCTAssertEqual(lane.edges, [
            FlowEdge(from: "src", to: "session", kind: .sequence),
            FlowEdge(from: "session", to: "drain", kind: .sequence),
        ])
        XCTAssertEqual(store.aggregates, FlowAggregates(runningCount: 1, needsYouCount: 0))
    }

    func testBackgroundSessionIsScheduledLane() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry(kind: "bg", name: nil)])
        XCTAssertEqual(store.flows[0].kind, .scheduled)
        XCTAssertEqual(store.flows[0].title, "s1") // falls back to session id
    }

    func testWaitingDrivesNeedsYou() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry(status: "waiting")])
        XCTAssertEqual(store.flows[0].status, .waiting)
        XCTAssertEqual(store.aggregates.needsYouCount, 1)
    }

    func testVanishedSessionCompletesLane() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        store.apply(registry: []) // session gone from registry
        let lane = store.flows[0]
        XCTAssertEqual(lane.nodes.first { $0.id == "session" }?.status, .done)
        XCTAssertEqual(lane.nodes.first { $0.id == "drain" }?.status, .done)
        XCTAssertEqual(store.aggregates.runningCount, 0)
    }

    func testAgentEventsAddAndCloseAgentNodes() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let t0 = Date(timeIntervalSince1970: 100)
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: "Explore",
            description: "map repo", cwd: "/w", at: t0
        ))

        var lane = store.flows[0]
        let agent = lane.nodes.first { $0.id == "agent-a1" }
        XCTAssertEqual(agent?.kind, .agent)
        XCTAssertEqual(agent?.status, .running)
        XCTAssertEqual(agent?.label, "Explore")
        XCTAssertEqual(agent?.startedAt, t0)
        XCTAssertTrue(lane.edges.contains(FlowEdge(from: "session", to: "agent-a1", kind: .spawn)))

        let t1 = Date(timeIntervalSince1970: 200)
        store.apply(event: .agentStopped(sessionID: "s1", agentID: "a1", cwd: "/w", at: t1))
        lane = store.flows[0]
        XCTAssertEqual(lane.nodes.first { $0.id == "agent-a1" }?.status, .done)
        XCTAssertEqual(lane.nodes.first { $0.id == "agent-a1" }?.endedAt, t1)
    }

    func testEventBeforeRegistryCreatesLane() {
        // Replay can deliver events before the first registry poll.
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(event: .agentStarted(
            sessionID: "s9", agentID: "a1", agentType: nil,
            description: nil, cwd: "/w", at: Date()
        ))
        XCTAssertEqual(store.flows.map(\.id), ["session-s9"])
        XCTAssertNotNil(store.flows[0].nodes.first { $0.id == "agent-a1" })
    }

    func testTaskEventsAndNotificationAndStop() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(registry: [entry()])
        let t = Date()
        store.apply(event: .taskCreated(sessionID: "s1", taskID: "7", subject: "Fix bug", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .queued)
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.label, "Fix bug")

        store.apply(event: .taskCompleted(sessionID: "s1", taskID: "7", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "task-7" }?.status, .done)

        store.apply(event: .notification(sessionID: "s1", message: "needs permission", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].detail, "needs permission")

        store.apply(event: .sessionStopped(sessionID: "s1", cwd: "/w", at: t))
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "session" }?.status, .done)
        XCTAssertEqual(store.flows[0].nodes.first { $0.id == "drain" }?.status, .done)
    }

    func testUnknownSessionEventForUnknownAgentStopIsIgnored() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        store.apply(event: .agentStopped(sessionID: "nope", agentID: "aX", cwd: nil, at: Date()))
        // Creates the lane (session known now) but no phantom agent node.
        XCTAssertNil(store.flows.first?.nodes.first { $0.id == "agent-aX" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FlowStoreTests`
Expected: compile FAILURE — `cannot find 'FlowStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/FlowStore.swift
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
        // Sessions that disappeared from the registry are over.
        for index in flows.indices where !seen.contains(flows[index].id) {
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
            setNode(in: &lane, id: "agent-\(agentID)", ifPresent: true) { node in
                node.status = .done
                node.endedAt = at
            }
        case let .taskCreated(_, taskID, subject, _, at):
            let nodeID = "task-\(taskID ?? UUID().uuidString)"
            if !lane.nodes.contains(where: { $0.id == nodeID }) {
                lane.nodes.append(FlowNode(
                    id: nodeID, kind: .task, label: subject ?? "task", status: .queued, startedAt: at
                ))
                lane.edges.append(FlowEdge(from: "session", to: nodeID, kind: .spawn))
            }
        case let .taskCompleted(_, taskID, _, at):
            if let taskID {
                setNode(in: &lane, id: "task-\(taskID)", ifPresent: true) { node in
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
        for index in lane.nodes.indices where lane.nodes[index].status == .running {
            lane.nodes[index].status = .done
        }
    }

    /// Mutate one node by id. With `ifPresent: false` (default) this
    /// is a hard expectation and missing nodes are ignored silently —
    /// degrade, never break.
    private func setNode(
        in lane: inout Flow, id: String, ifPresent: Bool = false, _ mutate: (inout FlowNode) -> Void
    ) {
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
        aggregates = FlowAggregates(
            runningCount: flows.filter { $0.status == .running }.count,
            needsYouCount: flows.filter { $0.status == .waiting }.count
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FlowStoreTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowStore.swift Tests/DreamuxTests/FlowStoreTests.swift
git commit -m "Flows: FlowStore state machine over registry snapshots and flow events"
```

---

### Task 5: Registry poller

**Files:**
- Create: `Sources/Dreamux/Models/ClaudeRegistryPoller.swift`
- Test: `Tests/DreamuxTests/ClaudeRegistryPollerTests.swift`

**Interfaces:**
- Consumes: `ClaudeSessionEntry` (Task 2).
- Produces: `ClaudeRegistryPoller` — `@MainActor final class` with `init(read: @escaping @Sendable () -> [ClaudeSessionEntry], onSnapshot: @escaping ([ClaudeSessionEntry]) -> Void)`, `func startPolling(interval: TimeInterval = 3.0)`, `func stopPolling()`, `func pollOnce() async`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/ClaudeRegistryPollerTests.swift
import XCTest
@testable import Dreamux

@MainActor
final class ClaudeRegistryPollerTests: XCTestCase {
    private func entry(pid: Int32) -> ClaudeSessionEntry {
        try! JSONDecoder().decode(
            ClaudeSessionEntry.self,
            from: Data(#"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/w","status":"busy","kind":"interactive"}"#.utf8)
        )
    }

    func testPollOnceDeliversSnapshotOnMain() async {
        let expected = [entry(pid: 1), entry(pid: 2)]
        var received: [[ClaudeSessionEntry]] = []
        let poller = ClaudeRegistryPoller(
            read: { expected },
            onSnapshot: { received.append($0) }
        )
        await poller.pollOnce()
        XCTAssertEqual(received, [expected])
    }

    func testStartPollingTicksAndStops() async throws {
        let counter = SendableCounter()
        let poller = ClaudeRegistryPoller(
            read: { counter.increment(); return [] },
            onSnapshot: { _ in }
        )
        poller.startPolling(interval: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000) // ~4 ticks
        poller.stopPolling()
        let after = counter.value
        XCTAssertGreaterThanOrEqual(after, 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(counter.value, after) // no ticks after stop
    }
}

/// Tiny thread-safe counter for cross-actor assertions.
final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeRegistryPollerTests`
Expected: compile FAILURE — `cannot find 'ClaudeRegistryPoller' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/ClaudeRegistryPoller.swift
import Foundation

/// 3 s heartbeat over the claude session registry (the
/// PlanQueueController.startPolling shape). The read closure runs off
/// the main actor — registry files are tiny but they're still disk IO —
/// and snapshots are delivered back on the main actor.
@MainActor
final class ClaudeRegistryPoller {
    private let read: @Sendable () -> [ClaudeSessionEntry]
    private let onSnapshot: ([ClaudeSessionEntry]) -> Void
    private var poller: Task<Void, Never>?

    init(
        read: @escaping @Sendable () -> [ClaudeSessionEntry],
        onSnapshot: @escaping ([ClaudeSessionEntry]) -> Void
    ) {
        self.read = read
        self.onSnapshot = onSnapshot
    }

    func startPolling(interval: TimeInterval = 3.0) {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func pollOnce() async {
        let read = self.read
        let entries = await Task.detached(priority: .utility) { read() }.value
        guard !Task.isCancelled else { return }
        onSnapshot(entries)
    }

    deinit { poller?.cancel() }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeRegistryPollerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeRegistryPoller.swift Tests/DreamuxTests/ClaudeRegistryPollerTests.swift
git commit -m "Flows: main-actor registry poller with off-main reads"
```

---

### Task 6: Launch replay from signals.db

**Files:**
- Create: `Sources/Dreamux/Models/FlowReplayLoader.swift`
- Test: `Tests/DreamuxTests/FlowReplayLoaderTests.swift`

**Interfaces:**
- Consumes: `SQLiteSignalStore.query(kind:source:projectDir:since:limit:)` (Signals/SQLiteSignalStore.swift), `SignalKind.flowKinds` (Task 3), `ClaudeFlowAdapter.event(from:)` (Task 3).
- Produces: `FlowReplayLoader.events(store:now:window:cap:) async -> [FlowEvent]` — chronologically ascending, capped.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/FlowReplayLoaderTests.swift
import XCTest
@testable import Dreamux

final class FlowReplayLoaderTests: XCTestCase {
    var sandbox: TestSandbox!
    var store: SQLiteSignalStore!

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        store = try SQLiteSignalStore(dbURL: sandbox.root.appendingPathComponent("signals.db"))
    }

    override func tearDown() {
        store = nil
        sandbox.destroy()
        sandbox = nil
    }

    private func flowSignal(kind: String, session: String, ts: Date, agent: String = "a1") -> Signal {
        Signal(
            source: "claude.hooks",
            kind: kind,
            ts: ts,
            tags: ["cwd": "/w"],
            payload: .object([
                "session_id": .string(session),
                "agent_id": .string(agent),
            ])
        )
    }

    func testReplayReturnsChronologicalFlowEvents() async {
        let now = Date()
        store.append(flowSignal(kind: SignalKind.agentStopped, session: "s1", ts: now.addingTimeInterval(-10)))
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1", ts: now.addingTimeInterval(-20)))
        store.append(Signal(source: "svc", kind: SignalKind.terminalLine, ts: now, payload: .null)) // foreign — ignored
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "old", ts: now.addingTimeInterval(-100_000))) // outside window

        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 5_000)
        XCTAssertEqual(events.count, 2)
        guard case .agentStarted = events[0], case .agentStopped = events[1] else {
            return XCTFail("expected chronological agentStarted then agentStopped, got \(events)")
        }
    }

    func testReplayHonorsCap() async {
        let now = Date()
        for i in 0..<30 {
            store.append(flowSignal(
                kind: SignalKind.agentStarted, session: "s1",
                ts: now.addingTimeInterval(TimeInterval(-i)), agent: "a\(i)"
            ))
        }
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 10)
        XCTAssertEqual(events.count, 10)
        // Cap keeps the MOST RECENT signals.
        guard case let .agentStarted(_, agentID, _, _, _, _) = events.last! else {
            return XCTFail("expected agentStarted")
        }
        XCTAssertEqual(agentID, "a0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FlowReplayLoaderTests`
Expected: compile FAILURE — `cannot find 'FlowReplayLoader' in scope`.

Note: `SQLiteSignalStore.append` is fire-and-forget onto its private queue; `query` funnels through the same serial queue, so appends land before a later query — no sleeps needed.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/FlowReplayLoader.swift
import Foundation

/// Rebuilds flow history on launch from signals.db so lanes survive
/// app restarts and capture sessions that ran while Dreamux was
/// closed. Spec: 24 h window, 5,000-signal cap (most recent win).
enum FlowReplayLoader {
    static func events(
        store: SQLiteSignalStore,
        now: Date = Date(),
        window: TimeInterval = 86_400,
        cap: Int = 5_000
    ) async -> [FlowEvent] {
        let since = now.addingTimeInterval(-window)
        var signals: [Signal] = []
        for kind in SignalKind.flowKinds {
            // query() filters a single kind; per-kind fetches share the
            // global cap so one chatty kind can't evict the others
            // entirely before the global trim below.
            let batch = (try? await store.query(
                kind: kind, source: nil, projectDir: nil, since: since, limit: cap
            )) ?? []
            signals.append(contentsOf: batch)
        }
        let recentFirst = signals.sorted { $0.ts > $1.ts }.prefix(cap)
        return recentFirst
            .compactMap(ClaudeFlowAdapter.event(from:))
            .sorted { $0.at < $1.at }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FlowReplayLoaderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowReplayLoader.swift Tests/DreamuxTests/FlowReplayLoaderTests.swift
git commit -m "Flows: launch replay of flow signals from signals.db"
```

---

### Task 7: dreamux-hook — `flow` subcommand + emit-socket sink

**Files:**
- Modify: `Tools/dreamux-hook` (Python 3; add `emit_signal`, `flow_handler`; extend `stop_handler`, `notify_handler`, `main`)
- Test: `Tests/DreamuxTests/DreamuxHookFlowTests.swift`

**Interfaces:**
- Consumes: `SignalEmitSocketServer` wire protocol — one JSON line `{"action":"emit","signal":{"kind","source","severity","tags","payload"}}`, response `{"ok":true,...}` (Signals/SignalEmitSocketServer.swift `parseAndEmit`). Env `DREAMUX_EMIT_SOCKET` (set by Task 9; absent ⇒ silently skip).
- Produces: `dreamux-hook flow` subcommand mapping stdin `hook_event_name` → signal kinds `agent.started`/`agent.stopped`/`task.created`/`task.completed`; `stop` additionally emits `session.stopped`; `notify` additionally emits `session.notification` and now prefers the stdin JSON `message` field.

The hook is Python 3, so the sink uses Python's `socket` module directly — strictly better than the spec's illustrative `nc -U` sketch (no external binary, explicit timeout). Note this deviation in the commit message.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/DreamuxHookFlowTests.swift
import XCTest
import Combine
@testable import Dreamux

/// End-to-end: run the real Tools/dreamux-hook script against a real
/// SignalEmitSocketServer on a temp socket and assert the signal
/// arrives on the bus. Covers the Python sink, the wire protocol, and
/// the kind/payload mapping in one shot.
final class DreamuxHookFlowTests: XCTestCase {
    private var bus: SignalBus!
    private var socketPath: String!
    private var subscriptions = Set<AnyCancellable>()

    /// Repo root, derived from this file's path:
    /// <root>/Tests/DreamuxTests/DreamuxHookFlowTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DreamuxTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }

    override func setUp() {
        super.setUp()
        bus = SignalBus(store: nil, startSocket: false)
        // sun_path limit: keep the socket path short — /tmp, not the sandbox.
        socketPath = "/tmp/dreamux-hook-test-\(UUID().uuidString.prefix(8)).sock"
        _ = bus.attachSocketServer(path: socketPath)
    }

    override func tearDown() {
        subscriptions.removeAll()
        try? FileManager.default.removeItem(atPath: socketPath)
        bus = nil
        super.tearDown()
    }

    private func runHook(args: [String], stdin: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path] + args
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_EMIT_SOCKET"] = socketPath
        process.environment = env
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = Pipe() // swallow any OSC output
        try process.run()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func expectSignal(kind: String) -> (XCTestExpectation, () -> Signal?) {
        let expectation = expectation(description: "signal \(kind)")
        let box = SignalBox()
        bus.publisher
            .filter { $0.kind == kind }
            .sink { signal in box.set(signal); expectation.fulfill() }
            .store(in: &subscriptions)
        return (expectation, { box.get() })
    }

    func testSubagentStartBecomesAgentStartedSignal() throws {
        let (exp, received) = expectSignal(kind: SignalKind.agentStarted)
        try runHook(args: ["flow"], stdin: #"""
        {"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1",
         "agent_type":"Explore","cwd":"/tmp/worktree","transcript_path":"/tmp/t.jsonl"}
        """#)
        wait(for: [exp], timeout: 5)
        let signal = received()
        XCTAssertEqual(signal?.source, "claude.hooks")
        XCTAssertEqual(signal?.tags["cwd"], "/tmp/worktree")
        guard case let .object(fields)? = signal?.payload else { return XCTFail("object payload expected") }
        XCTAssertEqual(fields["session_id"], .string("s1"))
        XCTAssertEqual(fields["agent_id"], .string("a1"))
        XCTAssertEqual(fields["agent_type"], .string("Explore"))
    }

    func testTaskCompletedMapsKind() throws {
        let (exp, _) = expectSignal(kind: SignalKind.taskCompleted)
        try runHook(args: ["flow"], stdin: #"""
        {"hook_event_name":"TaskCompleted","session_id":"s1","task_id":"3","cwd":"/w"}
        """#)
        wait(for: [exp], timeout: 5)
    }

    func testNotifyEmitsSessionNotification() throws {
        let (exp, received) = expectSignal(kind: SignalKind.sessionNotification)
        try runHook(args: ["notify"], stdin: #"""
        {"hook_event_name":"Notification","session_id":"s1","cwd":"/w",
         "message":"Claude needs permission to run npm"}
        """#)
        wait(for: [exp], timeout: 5)
        guard case let .object(fields)? = received()?.payload else { return XCTFail("object payload expected") }
        XCTAssertEqual(fields["message"], .string("Claude needs permission to run npm"))
    }

    func testUnknownEventAndMissingSocketAreSilentlyFine() throws {
        // Unknown hook_event_name → no signal, exit 0.
        try runHook(args: ["flow"], stdin: #"{"hook_event_name":"SomethingNew","session_id":"s1"}"#)
        // Missing socket → exit 0 (the sink must never break a session).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repoRoot.appendingPathComponent("Tools/dreamux-hook").path, "flow"]
        var env = ProcessInfo.processInfo.environment
        env["DREAMUX_EMIT_SOCKET"] = "/tmp/definitely-not-there-\(UUID().uuidString).sock"
        process.environment = env
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a"}"#.utf8))
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// Lock-boxed Signal for cross-queue capture in expectations.
final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var signal: Signal?
    func set(_ s: Signal) { lock.lock(); signal = s; lock.unlock() }
    func get() -> Signal? { lock.lock(); defer { lock.unlock() }; return signal }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DreamuxHookFlowTests`
Expected: FAIL — the `flow` subcommand doesn't exist yet, so no signal ever arrives (`testSubagentStartBecomesAgentStartedSignal` times out; `notify` currently emits no signal).

- [ ] **Step 3: Extend Tools/dreamux-hook**

Add after the existing `read_stdin_json()` function:

```python
# ---------------------------------------------------------------------------
# Signal sink — mirror hook lifecycle events onto Dreamux's signal bus.
#
# Transport: one JSON line to the Unix socket in $DREAMUX_EMIT_SOCKET
# (set by Dreamux's PTY sessions; absent outside Dreamux → no-op).
# Failures are ALWAYS silent (log-only): a hook must never break or
# slow the user's claude session.
# ---------------------------------------------------------------------------

# Fields copied verbatim from the hook's stdin JSON into the signal
# payload. Whitelist, not passthrough: hook payloads can contain large
# prompts/transcript excerpts we don't want in signals.db.
PAYLOAD_FIELDS = (
    "session_id",
    "agent_id",
    "agent_type",
    "description",
    "task_id",
    "subject",
    "message",
    "hook_event_name",
)

HOOK_EVENT_KINDS = {
    "SubagentStart": "agent.started",
    "SubagentStop": "agent.stopped",
    "TaskCreated": "task.created",
    "TaskCompleted": "task.completed",
}


def emit_signal(kind: str, stdin_payload: Optional[dict], message: Optional[str] = None) -> None:
    sock_path = os.environ.get("DREAMUX_EMIT_SOCKET", "")
    if not sock_path:
        log("signal_skip", reason="no_socket_env", kind=kind)
        return
    payload: dict = {}
    if stdin_payload:
        for field in PAYLOAD_FIELDS:
            value = stdin_payload.get(field)
            if isinstance(value, str) and value:
                payload[field] = value
    if message and "message" not in payload:
        payload["message"] = message
    if not payload.get("session_id"):
        log("signal_skip", reason="no_session_id", kind=kind)
        return
    cwd = ""
    if stdin_payload and isinstance(stdin_payload.get("cwd"), str):
        cwd = stdin_payload["cwd"]
    envelope = {
        "action": "emit",
        "signal": {
            "kind": kind,
            "source": "claude.hooks",
            "severity": "info",
            "tags": {"cwd": cwd},
            "payload": payload,
        },
    }
    try:
        import socket as socketlib

        s = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
        s.settimeout(0.5)
        try:
            s.connect(sock_path)
            s.sendall((json.dumps(envelope) + "\n").encode("utf-8"))
            try:
                s.recv(256)  # ack; best-effort
            except Exception:
                pass
        finally:
            s.close()
        log("signal_sent", kind=kind)
    except Exception as exc:
        log("signal_fail", kind=kind, error=str(exc))


def flow_handler() -> None:
    """`dreamux-hook flow` — generic lifecycle relay. The event name
    comes from stdin's hook_event_name, so one settings entry covers
    all four lifecycle hooks."""
    payload = read_stdin_json()
    if not payload:
        log("flow_skip", reason="no_stdin_json")
        return
    event = payload.get("hook_event_name") or ""
    kind = HOOK_EVENT_KINDS.get(event)
    if not kind:
        log("flow_skip", reason="unknown_event", event=event)
        return
    emit_signal(kind, payload)
```

In `stop_handler()`, immediately after the `payload is None` early-return (before the transcript polling, so the signal isn't delayed by it):

```python
    emit_signal("session.stopped", payload)
```

Replace `notify_handler()` with (stdin-first, argv/env fallback preserved):

```python
def notify_handler() -> None:
    payload = read_stdin_json()
    message = None
    if payload and isinstance(payload.get("message"), str):
        message = payload["message"]
    if not message:
        message = (
            sys.argv[2]
            if len(sys.argv) > 2
            else os.environ.get("CLAUDE_NOTIFICATION_MESSAGE", "Agent is waiting on you")
        )
    if payload:
        emit_signal("session.notification", payload, message=message)
    if not message:
        return
    emit(message)
```

In `main()`, add the subcommand before the free-text fallback:

```python
    elif cmd == "flow":
        flow_handler()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DreamuxHookFlowTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Regression-check the notify path manually**

Run: `printf '{"hook_event_name":"Notification","session_id":"s1","message":"hi"}' | python3 Tools/dreamux-hook notify | cat -v`
Expected: output contains `^[]9;hi^G` (OSC-9 still emitted; signal skipped silently because `DREAMUX_EMIT_SOCKET` is unset).

- [ ] **Step 6: Commit**

```bash
git add Tools/dreamux-hook Tests/DreamuxTests/DreamuxHookFlowTests.swift
git commit -m "Flows: dreamux-hook flow subcommand + emit-socket signal sink

Python socket module instead of the spec's illustrative nc -U —
no external binary, explicit 0.5s timeout, still silent on failure."
```

---

### Task 8: Shim registers the lifecycle hooks

**Files:**
- Modify: `Tools/claude` (the `SETTINGS_JSON=` line near the end)
- Test: `Tests/DreamuxTests/ClaudeShimSettingsTests.swift`

**Interfaces:**
- Consumes: `Tools/dreamux-hook flow` (Task 7).
- Produces: claude sessions launched inside Dreamux fire SubagentStart/SubagentStop/TaskCreated/TaskCompleted as async command hooks. (Per the hooks reference: SubagentStart/SubagentStop take matchers; TaskCreated/TaskCompleted do not — no `matcher` key for those.)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/ClaudeShimSettingsTests.swift
import XCTest
@testable import Dreamux

/// Runs the real Tools/claude shim with PATH rigged so the "real"
/// claude is a fake that captures its argv, then asserts the injected
/// --settings JSON is valid and wires every expected hook.
final class ClaudeShimSettingsTests: XCTestCase {
    var sandbox: TestSandbox!

    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShimInjectsLifecycleHooks() throws {
        let fakeBin = sandbox.root.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let capture = sandbox.root.appendingPathComponent("argv.txt")
        let fakeClaude = fakeBin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(capture.path)"
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [repoRoot.appendingPathComponent("Tools/claude").path, "--version"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(repoRoot.appendingPathComponent("Tools").path):\(fakeBin.path):/usr/bin:/bin"
        process.environment = env
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let argv = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv.first, "--settings")
        XCTAssertEqual(argv.last, "--version")

        let settings = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(argv[1].utf8)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for event in ["Stop", "Notification", "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted"] {
            XCTAssertNotNil(hooks[event], "missing hook registration for \(event)")
        }
        // Lifecycle hooks are async `dreamux-hook flow` commands.
        let subagentStart = try XCTUnwrap(hooks["SubagentStart"] as? [[String: Any]])
        let entry = try XCTUnwrap((subagentStart.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["async"] as? Bool, true)
        XCTAssertTrue((entry["command"] as? String ?? "").hasSuffix("\" flow"))
        // Task hooks take no matcher (hooks reference).
        let taskCreated = try XCTUnwrap(hooks["TaskCreated"] as? [[String: Any]])
        XCTAssertNil(taskCreated.first?["matcher"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeShimSettingsTests`
Expected: FAIL — `missing hook registration for SubagentStart`.

- [ ] **Step 3: Extend the shim's settings JSON**

In `Tools/claude`, replace the single-line `SETTINGS_JSON=...` assignment with (still one logical assignment, built in readable pieces; POSIX sh string concatenation):

```sh
# Build inline hooks JSON.
#
# Stop/Notification: notification pipeline (see dreamux-hook docstring).
# SubagentStart/SubagentStop/TaskCreated/TaskCompleted: flow lifecycle
# events for the Flows observatory — `dreamux-hook flow` relays them to
# the app's signal socket. async:true so claude never waits on them.
# TaskCreated/TaskCompleted take no matcher (hooks reference).
HOOK_CMD='"\"'"$HOOK"'\"'
SYNC_STOP='{"matcher":"","hooks":[{"type":"command","command":'"$HOOK_CMD"' stop"}]}'
SYNC_NOTIFY='{"matcher":"","hooks":[{"type":"command","command":'"$HOOK_CMD"' notify"}]}'
FLOW_MATCHED='{"matcher":"","hooks":[{"type":"command","command":'"$HOOK_CMD"' flow","async":true}]}'
FLOW_PLAIN='{"hooks":[{"type":"command","command":'"$HOOK_CMD"' flow","async":true}]}'
SETTINGS_JSON='{"hooks":{'
SETTINGS_JSON="$SETTINGS_JSON"'"Stop":['"$SYNC_STOP"'],'
SETTINGS_JSON="$SETTINGS_JSON"'"Notification":['"$SYNC_NOTIFY"'],'
SETTINGS_JSON="$SETTINGS_JSON"'"SubagentStart":['"$FLOW_MATCHED"'],'
SETTINGS_JSON="$SETTINGS_JSON"'"SubagentStop":['"$FLOW_MATCHED"'],'
SETTINGS_JSON="$SETTINGS_JSON"'"TaskCreated":['"$FLOW_PLAIN"'],'
SETTINGS_JSON="$SETTINGS_JSON"'"TaskCompleted":['"$FLOW_PLAIN"']'
SETTINGS_JSON="$SETTINGS_JSON"'}}'
```

Sanity-check the quoting locally before running the suite: `sh -c 'HOOK=/tmp/h; <paste the block>; printf "%s" "$SETTINGS_JSON" | python3 -m json.tool'` must print valid JSON with `"command": "\"/tmp/h\" flow"`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeShimSettingsTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Tools/claude Tests/DreamuxTests/ClaudeShimSettingsTests.swift
git commit -m "Flows: shim registers async subagent/task lifecycle hooks"
```

---

### Task 9: Wire the spine into ProjectSession + export the socket env

**Files:**
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (stored props around line 19–30; construction in `init` near line 77; the `SignalBus` wiring section near lines 332–400)
- Modify: `Sources/Dreamux/Shell/PTYShellSession.swift` (env construction, next to `env["DREAMUX_BIN"]` at line ~136)
- Test: `Tests/DreamuxTests/FlowWiringTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6; `SignalBus.shared.publisher`; `SignalEmitSocketServer.defaultSocketPath()`; `WorkspaceStore` (`store.workspaces`), `Project.rootPath`.
- Produces: `ProjectSession.flows: FlowStore` (live, replayed, polling); `DREAMUX_EMIT_SOCKET` in every Dreamux shell's environment; `FlowWiring.workspaceID(forCwd:workspaces:projectRoot:)` — the pure cwd→workspace matcher, unit-tested.

- [ ] **Step 1: Write the failing test for the cwd matcher**

```swift
// Tests/DreamuxTests/FlowWiringTests.swift
import XCTest
@testable import Dreamux

final class FlowWiringTests: XCTestCase {
    func testMatchesAggregationDirAndWorktreePaths() {
        let ws = Workspace(
            name: "auth-refresh",
            workingDirectory: "/proj/features/auth-refresh",
            linkedRepoIDs: ["dreamux"]
        )
        let root = URL(fileURLWithPath: "/proj")

        // Exact aggregation dir and children of it.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh", workspaces: [ws], projectRoot: root),
            ws.id
        )
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh/sub", workspaces: [ws], projectRoot: root),
            ws.id
        )
        // Per-repo worktree path: <root>/repos/<repo>/<workspace-name>.
        XCTAssertEqual(
            FlowWiring.workspaceID(forCwd: "/proj/repos/dreamux/auth-refresh/Sources", workspaces: [ws], projectRoot: root),
            ws.id
        )
        // Prefix must respect path boundaries.
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/proj/features/auth-refresh-2", workspaces: [ws], projectRoot: root)
        )
        XCTAssertNil(
            FlowWiring.workspaceID(forCwd: "/elsewhere", workspaces: [ws], projectRoot: root)
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FlowWiringTests`
Expected: compile FAILURE — `cannot find 'FlowWiring' in scope`.

- [ ] **Step 3: Implement the matcher and wire ProjectSession**

Add to a new section at the bottom of `Sources/Dreamux/Models/FlowStore.swift` (it's FlowStore's companion glue, not worth a file):

```swift
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
```

In `Sources/Dreamux/Models/ProjectSession.swift`:

1. Add stored properties next to the existing store list (line ~30):

```swift
    let flows: FlowStore
    private var registryPoller: ClaudeRegistryPoller?
    private var flowBusSubscription: AnyCancellable?
```

2. In `init`, alongside the other store constructions (near line 77). Capture the local `WorkspaceStore` variable that init creates and later assigns to `self.store` — check its actual local name at the top of `init` and use that in the capture list (shown here as `workspaceStore`):

```swift
        let projectRoot = project.rootPath
        let flows = FlowStore(workspaceForCwd: { [weak workspaceStore] cwd in
            guard let workspaceStore else { return nil }
            return FlowWiring.workspaceID(
                forCwd: cwd, workspaces: workspaceStore.workspaces, projectRoot: projectRoot
            )
        })
        self.flows = flows
```

3. In the same guarded section that wires `SignalBus.shared` today (the one skipped under XCTest, lines ~332–368 — reuse its existing `bus` local and XCTest gate; do NOT create a second gate), add:

```swift
        // Flows spine: live flow signals → adapter → store.
        let isInProject: (String) -> Bool = { [weak self] cwd in
            guard let self else { return false }
            return FlowWiring.workspaceID(
                forCwd: cwd, workspaces: self.store.workspaces, projectRoot: self.project.rootPath
            ) != nil || cwd.hasPrefix(self.project.rootPath.path)
        }
        flowBusSubscription = bus.publisher
            .filter { SignalKind.flowKinds.contains($0.kind) }
            .receive(on: DispatchQueue.main)
            .sink { [weak flows] signal in
                guard let event = ClaudeFlowAdapter.event(from: signal),
                      let cwd = event.cwd, isInProject(cwd) else { return }
                flows?.apply(event: event)
            }

        // Launch replay: rebuild lanes from persisted signals.
        if let sqlite = bus.store {
            Task { @MainActor [weak flows] in
                let events = await FlowReplayLoader.events(store: sqlite)
                guard let flows else { return }
                for event in events where event.cwd.map(isInProject) == true {
                    flows.apply(event: event)
                }
            }
        }

        // Registry poll: session liveness + status.
        let home = ClaudeHome.root()
        let reader = ClaudeSessionRegistryReader(home: home)
        let poller = ClaudeRegistryPoller(
            read: { reader.entries() },
            onSnapshot: { [weak flows] entries in
                flows?.apply(registry: entries.filter { isInProject($0.cwd) })
            }
        )
        registryPoller = poller
        poller.startPolling()
```

If `deinit`/teardown exists for the bus subscription, cancel `registryPoller` there too (`registryPoller?.stopPolling()`); otherwise add it to whatever teardown the existing `busSubscription` uses.

4. In `Sources/Dreamux/Shell/PTYShellSession.swift`, next to `env["DREAMUX_BIN"] = bin` (line ~136):

```swift
        // Flow hooks (dreamux-hook flow) find the app's signal socket
        // through this; unset outside Dreamux, so the hook no-ops.
        env["DREAMUX_EMIT_SOCKET"] = SignalEmitSocketServer.defaultSocketPath()
```

- [ ] **Step 4: Run the new test, then the whole suite**

Run: `swift test --filter FlowWiringTests`
Expected: PASS (1 test).

Run: `swift test`
Expected: PASS — everything green; ProjectSession changes are behind the existing XCTest gate, so no store test regressions.

- [ ] **Step 5: Live smoke test (manual, optional but recommended)**

Launch the app from a built bundle, open a project, run `claude` in a tab, then in another terminal:
`sqlite3 ~/Library/Application\ Support/*/signals.db "select kind, count(*) from signals where kind like 'agent.%' or kind like 'session.%' group by kind;"`
Expected: rows appear after asking claude something that spawns a subagent (e.g. "explore this repo with an agent"). `DREAMUX_HOOK_DEBUG=1` in the tab makes the hook log to `~/Library/Logs/Dreamux-hook.log`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/FlowStore.swift Sources/Dreamux/Models/ProjectSession.swift Sources/Dreamux/Shell/PTYShellSession.swift Tests/DreamuxTests/FlowWiringTests.swift
git commit -m "Flows: wire registry poll, signal feed, and replay into ProjectSession"
```

---

## Deferred (explicitly NOT this plan)

- Plan-lane skeletons from `PlanQueueController`/`PlanRunLedger` — Group 2, built with the pane that shows them.
- E2E registration + `flowsState` command — Group 2.
- Transcript tailing, subagent joins, workflow scripts/journal — Group 3.
- Loop detection — Group 4. Gate cards — Group 5.
