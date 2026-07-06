# Flows Group 3 — Hot-Set Tailer + Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live transcript detail for the Flows board — a kqueue tailer over busy/waiting sessions' JSONL (plus their subagents), transcript/meta/journal parsing into node enrichment (tool activity, agent labels, failures, workflow phases), a pure layered DAG layout engine, and the zoomed `FlowDetailView` with inspector — plus the eleven Group 2 ride items.

**Architecture:** Parsing stays pure and fixture-tested: `ClaudeFlowAdapter` grows `transcriptEvents(...)` producing a new `TranscriptEvent` enum; `SubagentMeta` and `WorkflowRunArtifacts` parse the sibling files. IO lives in `ClaudeTranscriptTailer` (one file: offsets, inode checks, partial-line buffering, kqueue DispatchSource) and `FlowTailerPool` (@MainActor: hot-set reconcile from registry snapshots, lazy tail for zoom). `FlowStore` correlates events into richer lanes (lastActivity, `.failed`, fan-out collapse). `FlowLayoutEngine` is pure geometry; `FlowDetailView` renders it with Canvas edges + node views + inspector. Everything degrades to Group 2's skeleton when parsing fails.

**Tech Stack:** Swift 6 / SwiftPM, DispatchSource kqueue, XCTest + TestSandbox + checked-in redacted fixtures, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-flows-observatory-design.md` (Group 3 + Ingestion guardrails). Groups 1–2 merged (main at aee91ca).
- **Degrade, never break:** unknown transcript entry types skipped and counted; parse failure never crashes or blocks the skeleton; caps everywhere (line length 1 MB, batch 2,000 lines per wake, journal 10,000 lines).
- Claude home only via `ClaudeHome.root(environment:)`; never read `~/.claude/ide/` or `daemon/`; `tool-results/*.txt` only on demand (inspector; 256 KB cap) — NOT in this group (no inspector need yet — do not add).
- Tailing scope: sessions with registry status busy/waiting ("hot set") + lazy tail while a lane is zoomed. All file IO off the main actor; FlowStore mutations on `@MainActor`.
- Swift 6 isolation rule (from the G2 crash): any Combine operator closure formed inside a `@MainActor` context is MainActor-isolated even if it touches nothing isolated — pre-hop filters MUST be nonisolated named functions passed by reference, never closure literals.
- Loop detection is Group 4; gate action cards are Group 5 — do not implement either.
- No new package dependencies. Commits stage ONLY named files. `swift test --filter <Class>`; full suite + `swift build` before each integration commit.
- Fixtures: structure-preserving redaction only (see Task 4) — no real prompt/response text, no tokens, no email addresses may be checked in.

## Adaptation ground rules (integration tasks 2, 3, 10, 12, 13)

Pure tasks (1, 4–9, 11) carry complete code — transcribe. Integration tasks adapt sketches to verified anchors; if an anchor is missing, STOP → NEEDS_CONTEXT. Anchors as of aee91ca:

- `wireSignalPersistence()` (Models/ProjectSession.swift:360+): XCTest-gated; `isInProject` closure defined at ~:389; `busSubscription` hop-then-filter at ~:404; flow wiring (flowBusSubscription, replay Task, registryPoller) below it. The poller's `onSnapshot` currently filters + `flows.apply(registry:)` — Task 10 extends this same callback for hot-set reconcile.
- `FlowsOverviewView` (Views/FlowsOverviewView.swift): `@ObservedObject flows`, `planLaneInputs` closure, `board` computed, sections ForEach — Task 12 lifts zoom state to ContentView and swaps list⇄detail.
- ContentView: `.flows` mainPane arm constructs FlowsOverviewView; `planLaneInputs()` private func (Task 3 hoists it); `openFile(_ url:)` at :676 → `WorkspaceSession.openFileTab(at:revealingLine:)` (Models/WorkspaceSession.swift:408) — inspector's open-transcript reuses this glue; e2e pending-consume pattern (`consumePendingSidebarModeIfAny`, `E2EBridge`) for the zoom command.
- DocStore kqueue idiom (Models/DocStore.swift:396-420): `open(path, O_EVTONLY)` + `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)` + cancel-closes-fd. The tailer mirrors it but on a utility queue with offset reads instead of full rescans.
- Registry entry (Models/ClaudeSessionRegistry.swift): `ClaudeSessionEntry {pid, sessionId, cwd, status, name, kind, version}`; NO transcript path — Task 10 derives it via the cwd slug.
- Group 1–2 types in play: `FlowStore` (lanes `session-<id>`, nodes `src/session/drain/agent-<id>/task-<id>`, `insertBeforeDrain`), `FlowEvent`, `SignalKind.flowKinds`, `FlowsBoard` (engine selection, `section(for:)`, counts), `PlanFlowBuilder`/`PlanLaneInput`, `FlowStatusGlyph`, `flowsState` command, `scenario_flows` (Scripts/e2e/driver.py), PROTOCOL.md.

Real on-disk shapes (verified July 2026, claude 2.1.201 — memory `claude-code-observability-surfaces`):
- Transcript `~/.claude/projects/<slug>/<sessionId>.jsonl`; slug = cwd with every non-alphanumeric char replaced by `-`. Assistant responses split one line per content block sharing `message.id`; envelope has `uuid`, `parentUuid`, `timestamp` (ISO8601), `type`.
- Subagents: `projects/<slug>/<sessionId>/subagents/agent-<agentId>.jsonl` + `agent-<agentId>.meta.json` = `{agentType, description, toolUseId, spawnDepth}` (team variants add more keys — ignore unknown keys).
- Workflow runs persist script + journal under the session directory; journal format undocumented — parse defensively, expect `{...}` per line.

---

### Task 1: Board/store semantics ride items

**Files:**
- Modify: `Sources/Dreamux/Models/FlowsBoard.swift`
- Test: `Tests/DreamuxTests/FlowsBoardTests.swift`, `Tests/DreamuxTests/FlowStoreTests.swift`, `Tests/DreamuxTests/PlanFlowBuilderTests.swift`

**Interfaces:**
- Consumes: existing FlowsBoard/FlowStore/PlanFlowBuilder.
- Produces: behavior later tasks rely on: waiting/failed SCHEDULED lanes section under needsYou (attention beats kind); a `.failed` engine session bubbles onto its plan lane like `.waiting` does; regression tests for first-seen startedAt and merged-straggler.

- [ ] **Step 1: Write the failing tests**

Append to `FlowsBoardTests`:

```swift
    func testWaitingScheduledLaneSectionsUnderNeedsYou() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [lane(id: "session-bg", kind: .scheduled, status: .waiting)]
        )
        XCTAssertEqual(board.sections.map(\.kind), [.needsYou])
        XCTAssertEqual(board.needsYouCount, 1)
    }

    func testFailedEngineBubblesOntoPlanLane() {
        let wsID = UUID()
        let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
        let engine = lane(id: "session-s", kind: .adhoc, status: .failed, workspaceID: wsID, detail: "test suite crashed")
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [engine])
        let planLane = board.sections.flatMap(\.lanes).first { $0.id == "plan-p" }!
        XCTAssertEqual(planLane.effectiveStatus, .failed)
        XCTAssertEqual(planLane.flow.detail, "test suite crashed")
        XCTAssertEqual(board.needsYouCount, 1)
    }
```

Append to `FlowStoreTests` (uses the existing `entry(...)` helper):

```swift
    func testStartedAtIsFirstSeen() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        let t0 = Date(timeIntervalSince1970: 100)
        store.apply(event: .agentStarted(sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: t0))
        store.apply(event: .agentStarted(sessionID: "s1", agentID: "a2", agentType: nil, description: nil, cwd: "/w", at: Date(timeIntervalSince1970: 999)))
        store.apply(registry: [entry()])
        XCTAssertEqual(store.flows[0].startedAt, t0) // never overwritten
    }
```

Append to `PlanFlowBuilderTests`:

```swift
    func testMergedPlanWithStragglerPhaseIsStillDone() {
        let lanes = PlanFlowBuilder.lanes(from: [input(
            status: .merged,
            phases: [PlanPhaseSummary(title: "Straggler", checkedSteps: 2, totalSteps: 5)]
        )])
        XCTAssertEqual(lanes[0].status, .done)
        XCTAssertEqual(lanes[0].nodes.first { $0.id == "phase-0" }?.status, .done)
    }
```

- [ ] **Step 2: Run to verify failures**

Run: `swift test --filter FlowsBoardTests && swift test --filter FlowStoreTests && swift test --filter PlanFlowBuilderTests`
Expected: `testWaitingScheduledLaneSectionsUnderNeedsYou` FAILS (sections under .scheduled); `testFailedEngineBubblesOntoPlanLane` FAILS (bubbling guards only .waiting/.running); the two regression tests PASS already (they pin verified behavior — keep them).

- [ ] **Step 3: Implement**

In `FlowsBoard.swift`:

1. `section(for:)` — attention beats kind:

```swift
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
```

2. Bubbling — failed joins waiting as an override (a failure needs the human even more than a permission prompt; only a *newer* waiting state outranks it, which engine selection already encodes):

```swift
                if live.status == .waiting || live.status == .failed
                    || (live.status == .running && effective != .waiting && effective != .failed) {
                    effective = live.status
                }
```

- [ ] **Step 4: Run to verify green**

Run: the three filters from Step 2, then `swift test`
Expected: all PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowsBoard.swift Tests/DreamuxTests/FlowsBoardTests.swift Tests/DreamuxTests/FlowStoreTests.swift Tests/DreamuxTests/PlanFlowBuilderTests.swift
git commit -m "Flows: attention outranks scheduled section, failed engines bubble, ride-item regression tests"
```

---

### Task 2: Perf + lane polish ride items

**Files:**
- Modify: `Sources/Dreamux/Signals/SignalEnvelope.swift` (SignalKind body)
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (flowBusSubscription)
- Modify: `Sources/Dreamux/Views/FlowLaneView.swift` (elapsed gate)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (ungrouped-plan phase summary in planLaneInputs)
- Test: `Tests/DreamuxTests/ClaudeFlowAdapterTests.swift`

**Interfaces:**
- Produces: `SignalKind.isFlowSignal(_ signal: Signal) -> Bool` (nonisolated static method — pre-hop safe when passed BY REFERENCE).

- [ ] **Step 1: Add the nonisolated predicate + test**

In `SignalEnvelope.swift`, inside `enum SignalKind`:

```swift
    /// Pre-hop Combine predicate. MUST be passed by function reference
    /// (`.filter(SignalKind.isFlowSignal)`) — a closure literal formed in
    /// a @MainActor context is MainActor-isolated under Swift 6 even when
    /// it touches nothing isolated, and Combine invokes filters
    /// synchronously on the upstream queue (this exact shape trapped at
    /// runtime in Group 2). A nonisolated named function has no isolation
    /// to violate.
    nonisolated static func isFlowSignal(_ signal: Signal) -> Bool {
        flowKinds.contains(signal.kind)
    }
```

Test (append to `ClaudeFlowAdapterTests`):

```swift
    func testIsFlowSignalPredicate() {
        XCTAssertTrue(SignalKind.isFlowSignal(signal(kind: SignalKind.agentStarted, payload: [:])))
        XCTAssertFalse(SignalKind.isFlowSignal(signal(kind: SignalKind.terminalLine, payload: [:])))
    }
```

- [ ] **Step 2: Use it pre-hop**

In `wireSignalPersistence()`'s flow subscription, change

```swift
        flowBusSubscription = bus.publisher
            .receive(on: DispatchQueue.main)
            .filter { SignalKind.flowKinds.contains($0.kind) }
```

to

```swift
        flowBusSubscription = bus.publisher
            .filter(SignalKind.isFlowSignal)   // nonisolated fn ref — safe on the bus queue
            .receive(on: DispatchQueue.main)
```

Do NOT touch `busSubscription` (it needs everything for SignalsView).

- [ ] **Step 3: Elapsed on waiting lanes + ungrouped-plan progress**

`FlowLaneView.header`: change the elapsed gate from `lane.effectiveStatus == .running` to `lane.effectiveStatus == .running || lane.effectiveStatus == .waiting` (the mock shows "4m" on waiting lanes — how long you've been blocking matters most there).

ContentView `planLaneInputs()`: where phases are `[]` for ungrouped plans, pass one real summary instead (adapt names to the glue's actuals):

```swift
            let phaseSummaries: [PlanPhaseSummary]
            if PlanPhases.shouldGroup(tasks) {
                phaseSummaries = PlanPhases.groups(tasks).map {
                    PlanPhaseSummary(title: $0.phase, checkedSteps: $0.checkedSteps, totalSteps: $0.totalSteps)
                }
            } else {
                let checked = tasks.reduce(0) { $0 + $1.steps.filter(\.checked).count }
                let total = tasks.reduce(0) { $0 + $1.steps.count }
                phaseSummaries = total > 0
                    ? [PlanPhaseSummary(title: "tasks", checkedSteps: checked, totalSteps: total)]
                    : []
            }
```

(PlanFlowBuilder's `[]→"tasks 0/1"` fallback stays as the safety net.)

- [ ] **Step 4: Build + tests**

Run: `swift test --filter ClaudeFlowAdapterTests && swift build && swift test`
Expected: green; no isolation warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Signals/SignalEnvelope.swift Sources/Dreamux/Models/ProjectSession.swift Sources/Dreamux/Views/FlowLaneView.swift Sources/Dreamux/Views/ContentView.swift Tests/DreamuxTests/ClaudeFlowAdapterTests.swift
git commit -m "Flows: nonisolated pre-hop filter, waiting elapsed, real ungrouped-plan progress"
```

---

### Task 3: Shared plan-lane assembly + flowsState planLanes

**Files:**
- Create: `Sources/Dreamux/Models/PlanLaneAssembler.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift` (planLaneInputs delegates to it)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (flowsState grows planLanes)
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift` (handles gain what the assembler needs, if not already registered)
- Modify: `Scripts/e2e/PROTOCOL.md`
- Test: `Tests/DreamuxTests/PlanLaneAssemblerTests.swift`

**Interfaces:**
- Produces: `@MainActor enum PlanLaneAssembler { static func inputs(docStore: DocStore, queue: PlanQueueController, store: WorkspaceStore) -> [PlanLaneInput] }` — the ONE place plan state becomes lane inputs; ContentView and flowsState both call it (kills the untested-glue gap from the G2 final review).

- [ ] **Step 1: Hoist**

Move the body of ContentView's `planLaneInputs()` verbatim into `PlanLaneAssembler.inputs(...)` (parameterizing the store accesses); ContentView's function becomes a one-line delegate. Keep every accessor exactly as the glue has it today (it was line-by-line verified in the G2 final review) — this is a move, not a rewrite, apart from Task 2's phase-summary change which lands first.

- [ ] **Step 2: Test the assembler**

`PlanLaneAssemblerTests` — build a `TestSandbox` project with one plan doc on disk the way `PlanQueueControllerTests` seeds plans (copy its fixture idiom; read that test file first), a queue with the plan enqueued, and assert the assembled `PlanLaneInput` fields (planPath = relativePath, ordinal 1, phases summarized, workspaceID nil when no worktree). At minimum two tests: enqueued-ready plan, and running plan with ledger record → startedAt set.

- [ ] **Step 3: flowsState planLanes**

In the `flowsState` command, after the session lanes, add:

```swift
        let planLanes = PlanFlowBuilder.lanes(
            from: PlanLaneAssembler.inputs(docStore: docStore, queue: queue, store: store)
        ).map { flow -> [String: Any] in
            var lane: [String: Any] = [
                "id": flow.id, "title": flow.title, "kind": flow.kind.rawValue,
                "status": flow.status.rawValue,
                "nodes": flow.nodes.map { ["id": $0.id, "label": $0.label, "status": $0.status.rawValue] },
            ]
            if let detail = flow.detail { lane["detail"] = detail }
            return lane
        }
        // ... add "planLanes": planLanes to the response dict
```

(reach docStore/queue/store through the existing handles — they're already registered for other commands; verify and add to `E2EProjectHandles` only if missing). Document the new field in PROTOCOL.md.

- [ ] **Step 4: Build + tests + full suite**

Run: `swift test --filter PlanLaneAssemblerTests && swift build && swift test`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanLaneAssembler.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/E2E/E2ECommands.swift Sources/Dreamux/E2E/E2ERegistry.swift Scripts/e2e/PROTOCOL.md Tests/DreamuxTests/PlanLaneAssemblerTests.swift
git commit -m "Flows: shared PlanLaneAssembler feeds pane and flowsState planLanes"
```

---

### Task 4: Redacted transcript fixtures

**Files:**
- Create: `Tests/DreamuxTests/Fixtures/claude-session/` (transcript.jsonl, subagents/*.meta.json, subagents/agent-sample.jsonl)
- Create: `Scripts/redact-claude-fixture.py`
- Create: `Tests/DreamuxTests/Support/ClaudeFixtures.swift`
- Test: `Tests/DreamuxTests/ClaudeFixturesTests.swift`

**Interfaces:**
- Produces: `enum ClaudeFixtures { static func transcriptLines() throws -> [String]; static func subagentMetaURLs() throws -> [URL]; static func agentTranscriptLines() throws -> [String]; static var fixturesRoot: URL }` (bundle-relative via `#filePath`). Tasks 5–8 parse these fixtures.

- [ ] **Step 1: Write the redaction script**

`Scripts/redact-claude-fixture.py` (python3, stdlib only): reads a JSONL file, walks every JSON value, and (a) replaces every string VALUE longer than 40 chars with `"[redacted-<n>-chars-<len>]"` EXCEPT values of keys in the allowlist `{"type","subtype","name","id","uuid","parentUuid","sessionId","message_id","model","stop_reason","role","tool_use_id","toolUseId","agentType","hook_event_name","timestamp","requestId","agentId","version","cwd","gitBranch"}` and except `content[].type`/`tool_use.name` structural markers; (b) replaces `cwd`/`gitBranch` values with `"/redacted/project"` / `"main"`; (c) drops lines whose `type` is not in `{user, assistant, system, attachment}`; (d) truncates `tool_use.input` string fields to 60 chars with the same marker. Deterministic (no randomness). Print counts of lines kept/dropped/strings redacted.

- [ ] **Step 2: Extract the slice**

Source: the July 5 research session of THIS project — find it: `ls -lt ~/.claude/projects/-Users-olliejarvis-Development-clayspace/*.jsonl | head` and pick the session directory that ALSO has a `<uuid>/subagents/` sibling with several `agent-*.meta.json` (the research session spawned 4 named agents). Extract:
- The transcript slice: the first 400 lines plus every line containing `"name":"Agent"` or a matching `tool_result` (grep by the tool_use ids found), concatenated in original order, deduplicated — target ≤ 600 lines.
- Two `agent-*.meta.json` files verbatim (they contain no prose beyond `description` — redact description via the script too).
- One `agent-*.jsonl` first 100 lines.
Run each through the redaction script into `Tests/DreamuxTests/Fixtures/claude-session/`. MANUALLY grep the outputs for `@`, `sk-`, `ghp_`, `oliver` (case-insensitive) — zero matches required; if any hit, widen the redaction and re-run. Record the source sessionId and extraction commands in your report (not in the fixture).

- [ ] **Step 3: Loader + smoke test**

```swift
// Tests/DreamuxTests/Support/ClaudeFixtures.swift
import Foundation

/// Redacted slices of a real claude session (structure-true, content
/// scrubbed by Scripts/redact-claude-fixture.py). The real fan-out these
/// came from: a session that spawned multiple named Agent tool calls.
enum ClaudeFixtures {
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()             // Support
            .deletingLastPathComponent()             // DreamuxTests
            .appendingPathComponent("Fixtures/claude-session", isDirectory: true)
    }

    static func transcriptLines() throws -> [String] {
        try String(contentsOf: fixturesRoot.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    static func subagentMetaURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixturesRoot.appendingPathComponent("subagents"), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".meta.json") }.sorted { $0.path < $1.path }
    }

    static func agentTranscriptLines() throws -> [String] {
        try String(contentsOf: fixturesRoot.appendingPathComponent("subagents/agent-sample.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}
```

`ClaudeFixturesTests`: assert transcriptLines() count > 100; every line parses as a JSON object with a `type` key; at least one line contains an `Agent` tool_use; meta URLs count ≥ 2; NO line contains "@" (redaction held).

- [ ] **Step 4: Run + commit**

Run: `swift test --filter ClaudeFixturesTests` → PASS.

```bash
git add Scripts/redact-claude-fixture.py Tests/DreamuxTests/Fixtures Tests/DreamuxTests/Support/ClaudeFixtures.swift Tests/DreamuxTests/ClaudeFixturesTests.swift
git commit -m "Flows: redacted real-session fixtures + loader"
```

---

### Task 5: TranscriptEvent + transcript parsing

**Files:**
- Modify: `Sources/Dreamux/Models/ClaudeFlowAdapter.swift`
- Test: `Tests/DreamuxTests/ClaudeTranscriptParsingTests.swift`

**Interfaces:**
- Produces (Tasks 8–10 rely on exact shapes):

```swift
enum TranscriptEvent: Equatable, Sendable {
    case toolStarted(toolUseID: String, tool: String, summary: String?, at: Date?)
    case toolFinished(toolUseID: String, isError: Bool, at: Date?)
    case agentSpawned(toolUseID: String, agentType: String?, description: String?, at: Date?)
    // NOTE deliberately no agentReturned case: the parser cannot know
    // whether a tool_result closes an agent — FlowStore's toolUse→agent
    // join map makes that call when it applies toolFinished.
}
extension ClaudeFlowAdapter {
    /// Parse appended JSONL lines. Stateless; skips anything malformed
    /// or unknown. `skipped` counts lines that didn't parse (degrade
    /// telemetry for the store's "detail unavailable" threshold).
    static func transcriptEvents(fromLines lines: [String]) -> (events: [TranscriptEvent], skipped: Int)
}
```

- [ ] **Step 1: Write the failing tests** — fixture-driven plus surgical synthetic lines:

```swift
// Tests/DreamuxTests/ClaudeTranscriptParsingTests.swift
import XCTest
@testable import Dreamux

final class ClaudeTranscriptParsingTests: XCTestCase {
    func testFixtureParsesWithAgentSpawns() throws {
        let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: try ClaudeFixtures.transcriptLines())
        XCTAssertFalse(events.isEmpty)
        let spawns = events.compactMap { if case let .agentSpawned(id, _, _, _) = $0 { return id } else { return nil as String? } }
        XCTAssertFalse(spawns.isEmpty, "the fixture session spawned agents")
        // Every agentSpawned toolUseID eventually gets an agentReturned in the slice OR not — 
        // but no agentReturned may reference an id that never spawned within the same slice
        // ONLY when the slice includes the spawn (replay slices can start mid-stream) — so just
        // assert the parser produced both kinds without crashing.
        XCTAssertGreaterThanOrEqual(skipped, 0)
    }

    func testAgentToolUseBecomesAgentSpawned() {
        let line = #"{"type":"assistant","timestamp":"2026-07-06T10:00:00.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_01","name":"Agent","input":{"description":"map repo","subagent_type":"Explore","prompt":"go"}}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [line])
        guard case let .agentSpawned(id, type, desc, at)? = events.first else { return XCTFail("expected agentSpawned") }
        XCTAssertEqual(id, "toolu_01")
        XCTAssertEqual(type, "Explore")
        XCTAssertEqual(desc, "map repo")
        XCTAssertNotNil(at)
    }

    func testTaskToolNameAlsoSpawns() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Task","input":{"description":"d","subagent_type":"general-purpose"}}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [line])
        guard case .agentSpawned? = events.first else { return XCTFail("Task tool must map to agentSpawned") }
    }

    func testOrdinaryToolUseAndResult() {
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter X\necho done"}}]}}"#
        let ok = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [use, ok])
        guard case let .toolStarted(id, tool, summary, _)? = events.first else { return XCTFail("expected toolStarted") }
        XCTAssertEqual(id, "t3"); XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(summary, "swift test --filter X") // first line only
        guard case let .toolFinished(fid, isError, _)? = events.dropFirst().first else { return XCTFail("expected toolFinished") }
        XCTAssertEqual(fid, "t3"); XCTAssertFalse(isError)
    }

    func testErrorResultSetsIsError() {
        let err = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":"boom"}]}}"#
        let (events, _) = ClaudeFlowAdapter.transcriptEvents(fromLines: [err])
        guard case let .toolFinished(_, isError, _)? = events.first else { return XCTFail() }
        XCTAssertTrue(isError)
    }

    func testGarbageAndUnknownTypesSkippedNotFatal() {
        let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: [
            "not json", #"{"type":"file-history-snapshot","x":1}"#, #"{"no":"type"}"#, "",
            String(repeating: "x", count: 2_000_000), // over the 1 MB line cap
        ])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(skipped, 3) // garbage, no-type, oversized; known-but-unused type and empty line are silent skips, not "skipped"
    }
}
```

- [ ] **Step 2: Verify failures** — `swift test --filter ClaudeTranscriptParsingTests` → compile FAIL (`TranscriptEvent` missing).

- [ ] **Step 3: Implement** (append to ClaudeFlowAdapter.swift):

```swift
enum TranscriptEvent: Equatable, Sendable {
    case toolStarted(toolUseID: String, tool: String, summary: String?, at: Date?)
    case toolFinished(toolUseID: String, isError: Bool, at: Date?)
    case agentSpawned(toolUseID: String, agentType: String?, description: String?, at: Date?)
    // NOTE deliberately no agentReturned case: the parser cannot know
    // whether a tool_result closes an agent — FlowStore's toolUse→agent
    // join map makes that call when it applies toolFinished.
}

extension ClaudeFlowAdapter {
    /// Line cap: a single transcript line (huge pastes, base64 images)
    /// must never balloon parsing. Spec guardrail.
    private static let maxLineBytes = 1_048_576
    private static let agentToolNames: Set<String> = ["Agent", "Task"]
    /// Entry types we understand but produce no events for — silent skips.
    private static let knownQuietTypes: Set<String> = [
        "system", "attachment", "summary", "ai-title", "last-prompt", "mode",
        "permission-mode", "file-history-snapshot", "queue-operation",
        "worktree-state", "relocated",
    ]

    static func transcriptEvents(fromLines lines: [String]) -> (events: [TranscriptEvent], skipped: Int) {
        var events: [TranscriptEvent] = []
        var skipped = 0
        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in lines {
            if line.isEmpty { continue }
            guard line.utf8.count <= maxLineBytes,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { skipped += 1; continue }

            let at = (obj["timestamp"] as? String).flatMap { isoParser.date(from: $0) ?? isoPlain.date(from: $0) }

            switch type {
            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_use" {
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    if agentToolNames.contains(name) {
                        events.append(.agentSpawned(
                            toolUseID: id,
                            agentType: input["subagent_type"] as? String,
                            description: input["description"] as? String,
                            at: at
                        ))
                    } else {
                        events.append(.toolStarted(
                            toolUseID: id, tool: name, summary: toolSummary(name: name, input: input), at: at
                        ))
                    }
                }
            case "user":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where (block["type"] as? String) == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let isError = (block["is_error"] as? Bool) ?? false
                    // The store decides agent-vs-tool via its toolUse→agent
                    // join map when applying this event.
                    events.append(.toolFinished(toolUseID: id, isError: isError, at: at))
                }
            default:
                // Known-quiet and unknown NEW types alike: silent skip,
                // not an error — forward compat. `skipped` counts only
                // lines that failed to parse at all.
                break
            }
        }
        return (events, skipped)
    }

    /// One-line human summary for the inspector's "last activity".
    private static func toolSummary(name: String, input: [String: Any]) -> String? {
        let raw: String?
        switch name {
        case "Bash": raw = input["command"] as? String
        case "Read", "Write", "Edit": raw = input["file_path"] as? String
        default: raw = input["description"] as? String ?? input["prompt"] as? String
        }
        guard let raw, !raw.isEmpty else { return nil }
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }
}
```

NOTE for the implementer: `testGarbageAndUnknownTypesSkippedNotFatal` expects skipped == 3 with the above semantics (garbage +1, missing-type +1, oversized +1; `file-history-snapshot` is a knownQuietType so silent; empty string continues). Verify the arithmetic against the code as you write it; if the assertion and implementation disagree, the TEST above is the contract — make the implementation match.

- [ ] **Step 4: Verify green** — the filter, then full suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeFlowAdapter.swift Tests/DreamuxTests/ClaudeTranscriptParsingTests.swift
git commit -m "Flows: transcript JSONL parsing into TranscriptEvents"
```

---

### Task 6: Subagent meta + agent-file activity parsing

**Files:**
- Modify: `Sources/Dreamux/Models/ClaudeFlowAdapter.swift`
- Test: `Tests/DreamuxTests/SubagentMetaTests.swift`

**Interfaces:**
- Produces:

```swift
struct SubagentMeta: Equatable, Sendable {
    let agentID: String        // derived from filename agent-<id>.meta.json
    let agentType: String?
    let description: String?
    let toolUseID: String?
    let spawnDepth: Int?
    static func parse(url: URL) -> SubagentMeta?   // tolerant; nil on malformed
}
extension ClaudeFlowAdapter {
    /// Last-activity summary from a subagent transcript's appended lines:
    /// the most recent toolStarted summary, if any.
    static func lastActivity(fromAgentLines lines: [String]) -> String?
}
```

- [ ] **Step 1: Failing tests**

```swift
// Tests/DreamuxTests/SubagentMetaTests.swift
import XCTest
@testable import Dreamux

final class SubagentMetaTests: XCTestCase {
    var sandbox: TestSandbox!
    override func setUpWithError() throws { sandbox = try TestSandbox() }
    override func tearDown() { sandbox.destroy(); sandbox = nil }

    func testParsesFixtureMetas() throws {
        for url in try ClaudeFixtures.subagentMetaURLs() {
            let meta = SubagentMeta.parse(url: url)
            XCTAssertNotNil(meta, "fixture meta failed to parse: \(url.lastPathComponent)")
            XCTAssertFalse(meta!.agentID.isEmpty)
        }
    }

    func testAgentIDComesFromFilename() throws {
        let url = sandbox.root.appendingPathComponent("agent-abc123.meta.json")
        try #"{"agentType":"Explore","description":"d","toolUseId":"toolu_9","spawnDepth":1}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let meta = try XCTUnwrap(SubagentMeta.parse(url: url))
        XCTAssertEqual(meta.agentID, "abc123")
        XCTAssertEqual(meta.toolUseID, "toolu_9")
        XCTAssertEqual(meta.agentType, "Explore")
        XCTAssertEqual(meta.spawnDepth, 1)
    }

    func testUnknownKeysAndMissingFieldsTolerated() throws {
        let url = sandbox.root.appendingPathComponent("agent-x.meta.json")
        try #"{"name":"teammate","taskKind":"in_process_teammate","weird":[1,2]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let meta = try XCTUnwrap(SubagentMeta.parse(url: url))
        XCTAssertEqual(meta.agentID, "x")
        XCTAssertNil(meta.toolUseID)
    }

    func testMalformedReturnsNil() throws {
        let url = sandbox.root.appendingPathComponent("agent-y.meta.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(SubagentMeta.parse(url: url))
    }

    func testLastActivityFromAgentLines() throws {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/a/b.swift"}}]}}"#,
        ]
        XCTAssertEqual(ClaudeFlowAdapter.lastActivity(fromAgentLines: lines), "/a/b.swift")
        XCTAssertNil(ClaudeFlowAdapter.lastActivity(fromAgentLines: ["garbage"]))
    }

    func testFixtureAgentTranscriptYieldsActivity() throws {
        // The fixture agent file contains at least one tool_use.
        XCTAssertNotNil(ClaudeFlowAdapter.lastActivity(fromAgentLines: try ClaudeFixtures.agentTranscriptLines()))
    }
}
```

- [ ] **Step 2: Verify failures** — compile FAIL.

- [ ] **Step 3: Implement**

```swift
struct SubagentMeta: Equatable, Sendable {
    let agentID: String
    let agentType: String?
    let description: String?
    let toolUseID: String?
    let spawnDepth: Int?

    /// Filename convention: agent-<id>.meta.json. Tolerant of unknown
    /// keys (team-member metas carry extras) and missing fields.
    static func parse(url: URL) -> SubagentMeta? {
        let name = url.lastPathComponent
        guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { return nil }
        let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
        guard !agentID.isEmpty,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SubagentMeta(
            agentID: agentID,
            agentType: obj["agentType"] as? String,
            description: obj["description"] as? String,
            toolUseID: obj["toolUseId"] as? String,
            spawnDepth: obj["spawnDepth"] as? Int
        )
    }
}

extension ClaudeFlowAdapter {
    static func lastActivity(fromAgentLines lines: [String]) -> String? {
        let (events, _) = transcriptEvents(fromLines: lines)
        for event in events.reversed() {
            if case let .toolStarted(_, _, summary, _) = event, let summary { return summary }
        }
        return nil
    }
}
```

- [ ] **Step 4: Verify green.**  - [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeFlowAdapter.swift Tests/DreamuxTests/SubagentMetaTests.swift
git commit -m "Flows: subagent meta joins and agent last-activity parsing"
```

---

### Task 7: Workflow artifacts (defensive)

**Files:**
- Modify: `Sources/Dreamux/Models/ClaudeFlowAdapter.swift`
- Test: `Tests/DreamuxTests/WorkflowArtifactsTests.swift`

**Interfaces:**
- Produces:

```swift
struct WorkflowRunArtifacts: Equatable, Sendable {
    let runID: String
    let name: String?
    let phases: [String]
    static func parse(scriptText: String, runID: String) -> WorkflowRunArtifacts?
}
```

Scope: parse the persisted workflow SCRIPT's `export const meta = {...}` literal for `name` and `phases[].title` via a tolerant scan (regex over a pure literal, not a JS parser). Journal parsing is deliberately OUT (undocumented format, no consumer yet — the DAG's phase grouping uses timing, Task 8); do not add it.

- [ ] **Step 1: Failing tests**

```swift
// Tests/DreamuxTests/WorkflowArtifactsTests.swift
import XCTest
@testable import Dreamux

final class WorkflowArtifactsTests: XCTestCase {
    func testParsesMetaNameAndPhases() {
        let script = """
        export const meta = {
          name: 'review-changes',
          description: 'Review changed files',
          phases: [
            { title: 'Review', detail: 'x' },
            { title: "Verify" },
          ],
        }
        const x = await agent('...')
        """
        let artifacts = WorkflowRunArtifacts.parse(scriptText: script, runID: "wf_1")
        XCTAssertEqual(artifacts?.name, "review-changes")
        XCTAssertEqual(artifacts?.phases, ["Review", "Verify"])
    }

    func testNoMetaReturnsNil() {
        XCTAssertNil(WorkflowRunArtifacts.parse(scriptText: "const a = 1", runID: "wf_2"))
    }

    func testPhaselessMetaParsesWithEmptyPhases() {
        let script = "export const meta = { name: 'solo', description: 'd' }\n"
        let artifacts = WorkflowRunArtifacts.parse(scriptText: script, runID: "wf_3")
        XCTAssertEqual(artifacts?.name, "solo")
        XCTAssertEqual(artifacts?.phases, [])
    }
}
```

- [ ] **Step 2: Verify compile FAIL.**

- [ ] **Step 3: Implement**

```swift
struct WorkflowRunArtifacts: Equatable, Sendable {
    let runID: String
    let name: String?
    let phases: [String]

    /// The workflow meta block is required to be a pure literal, so a
    /// line-oriented scan is reliable enough — and when it isn't, we
    /// return nil and the lane simply shows no phase nodes. Degrade,
    /// never break.
    static func parse(scriptText: String, runID: String) -> WorkflowRunArtifacts? {
        guard scriptText.contains("export const meta") else { return nil }
        func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        let name = firstMatch(#"name:\s*['"]([^'"]+)['"]"#, in: scriptText)
        var phases: [String] = []
        if let phasesBlock = firstMatch(#"phases:\s*\[([\s\S]*?)\]"#, in: scriptText) {
            let regex = try? NSRegularExpression(pattern: #"title:\s*['"]([^'"]+)['"]"#)
            let range = NSRange(phasesBlock.startIndex..., in: phasesBlock)
            regex?.enumerateMatches(in: phasesBlock, range: range) { match, _, _ in
                if let match, match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: phasesBlock) {
                    phases.append(String(phasesBlock[r]))
                }
            }
        }
        if name == nil && phases.isEmpty { return nil }
        return WorkflowRunArtifacts(runID: runID, name: name, phases: phases)
    }
}
```

- [ ] **Step 4: Verify green.**  - [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeFlowAdapter.swift Tests/DreamuxTests/WorkflowArtifactsTests.swift
git commit -m "Flows: defensive workflow script meta parsing"
```

---

### Task 8: FlowStore transcript application

**Files:**
- Modify: `Sources/Dreamux/Models/FlowGraph.swift` (FlowNode gains `lastActivity: String?`)
- Modify: `Sources/Dreamux/Models/FlowStore.swift`
- Test: `Tests/DreamuxTests/FlowStoreTranscriptTests.swift`

**Interfaces:**
- Produces (Tasks 10, 12 rely on):

```swift
// FlowNode: additive stored property with default —
//   var lastActivity: String? = nil   (init gains a defaulted param at the end)
extension FlowStore {  // conceptually; implement inside the class
    func apply(transcript event: TranscriptEvent, sessionID: String)
    func apply(meta: SubagentMeta, sessionID: String)
    func apply(agentActivity: String, agentID: String, sessionID: String)
    func noteSkippedLines(_ count: Int, sessionID: String)   // ≥ 50 skipped → lane.detailUnavailable
}
// Flow gains: var detailUnavailable: Bool = false (additive, Codable default)
```

Semantics (all on the `session-<sessionID>` lane; missing lane → create via the existing event path semantics; every mutation ends in upsert + recomputeAggregates):
- `toolStarted` → session node `lastActivity = summary ?? tool`; if the toolUseID matches a known agent spawn (map below), ignore (agents track their own activity).
- `agentSpawned(toolUseID, type, desc)` → remember `pendingSpawns[lane][toolUseID] = (type, desc)`; if a HOOK-created node `agent-<agentID>` already got joined to this toolUseID via meta, enrich its label instead. Do NOT create nodes from transcript spawns (hooks own creation; replay slices would double-create).
- `apply(meta:)` → the join: `agentIDByToolUse[lane][meta.toolUseID] = meta.agentID`; if node `agent-<agentID>` exists, set label to `meta.agentType ?? label` and `lastActivity = meta.description`; consume any pendingSpawn for that toolUseID to enrich description.
- `toolFinished(toolUseID, isError)` → if `agentIDByToolUse` maps it: set that agent node `.done`/`.failed` (isError → `.failed`) + endedAt; else session-node lastActivity unchanged (results carry no summary), but isError on a NON-agent tool sets nothing (a failed Bash call is normal agent life — `.failed` is reserved for agent results; spec's conservative failure surfacing).
- `apply(agentActivity:)` → node `agent-<agentID>`.lastActivity = string.
- Fan-out collapse: when a lane's agent-node count exceeds 6, the OLDEST done agents merge into a single `agents-collapsed` node (kind .agent, label "agents", counters.multiplicity = merged count, status .done) — running/waiting/failed agents never collapse. (Keeps the overview pipeline legible per spec; DetailView shows the same collapsed node expandable in a later group — no expansion this group.)
- `noteSkippedLines` → cumulative per lane; ≥ 50 sets `flow.detailUnavailable = true` (Board/lane view render nothing new for it this group; flowsState exposes it — one boolean in the lane dict).

- [ ] **Step 1: Failing tests** — write `FlowStoreTranscriptTests` with these cases (construct events directly; reuse `entry()` helper pattern from FlowStoreTests for registry lanes):
1. `testToolStartedSetsSessionLastActivity` — registry lane; toolStarted(Bash, "swift build") → session node lastActivity "swift build".
2. `testMetaJoinEnrichesHookCreatedAgent` — hook agentStarted(agentID "a1") creates node; apply(meta: toolUseID "tu1", agentID "a1", agentType "Explore", description "map") → node label "Explore", lastActivity "map".
3. `testAgentResultMarksDoneViaJoin` — same setup; toolFinished("tu1", isError false) → agent-a1 .done with endedAt.
4. `testAgentErrorMarksFailed` — isError true → `.failed` (and lane aggregates .failed → board needsYou per Task 1).
5. `testNonAgentToolErrorDoesNotFail` — toolFinished on unmapped id, isError true → no node status change.
6. `testFanOutCollapsesOldestDoneAgents` — create 8 hook agents, complete all; assert nodes contain `agents-collapsed` with multiplicity ≥ 2, total agent-ish nodes ≤ 7, and no running agent was collapsed (make one still running → it survives).
7. `testSkippedLinesThresholdSetsDetailUnavailable` — noteSkippedLines(49) → false; +1 → true.
8. `testTranscriptSpawnAloneCreatesNoNode` — agentSpawned with no hook node and no meta → node count unchanged.

Write the full test code following the established FlowStoreTests idioms (MainActor test class, direct event construction, `store.flows[0].nodes` assertions). Every test asserts via node id lookups AND (where order matters) `nodes.map(\.id)` — agents must still insert before drain.

- [ ] **Step 2: Verify compile FAIL.**

- [ ] **Step 3: Implement** — inside FlowStore: two private dictionaries keyed by laneID (`pendingSpawns: [String: [String: (type: String?, desc: String?)]]`, `agentIDByToolUse: [String: [String: String]]`), a `skippedByLane: [String: Int]`, the four apply methods per the semantics above, the collapse pass invoked after agent-node mutations, `FlowNode.lastActivity` + `Flow.detailUnavailable` additive fields with defaulted init params. Keep `insertBeforeDrain` for any node insertion. Follow existing comment style (constraints, not narration).

- [ ] **Step 4: Verify green** — filter + FULL suite (FlowNode init change ripples; existing tests must stay green WITHOUT edits — defaulted params guarantee it; if a test needs editing, stop and reconsider the change).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowGraph.swift Sources/Dreamux/Models/FlowStore.swift Tests/DreamuxTests/FlowStoreTranscriptTests.swift
git commit -m "Flows: transcript events enrich lanes — activity, joins, failures, fan-out collapse"
```

---

### Task 9: ClaudeTranscriptTailer

**Files:**
- Create: `Sources/Dreamux/Models/ClaudeTranscriptTailer.swift`
- Test: `Tests/DreamuxTests/ClaudeTranscriptTailerTests.swift`

**Interfaces:**
- Produces:

```swift
/// Tails ONE append-only file. Not @MainActor — lives on the caller's
/// queue contract: init/start/stop from anywhere (internally serialized);
/// `onLines` delivered on the provided queue.
final class ClaudeTranscriptTailer {
    init(url: URL, deliveryQueue: DispatchQueue, onLines: @escaping ([String]) -> Void)
    func start(replayExisting: Bool)   // replayExisting: read from byte 0 first (lazy-zoom); else seek to EOF
    func stop()
}
```

Behavior (all covered by tests): kqueue DispatchSource (`.write/.extend/.rename/.delete`) on an internal utility queue; on wake, read from stored offset to EOF in 64 KB chunks; split on `\n`, buffer the trailing partial line (cap 1 MB — over-cap partials are dropped with the buffer reset); batch cap 2,000 lines per wake (re-arm immediately when more remain); `fstat` inode check on every wake — inode change or size < offset ⇒ reset offset to 0 and reread (rotation/truncation); `.delete/.rename` ⇒ close fd, retry open once after 500 ms (session dirs appear before files sometimes), else go dormant until `start` is called again; `stop()` cancels the source (cancel handler closes the fd) and is idempotent.

- [ ] **Step 1: Failing tests** — `ClaudeTranscriptTailerTests` (TestSandbox; XCTestExpectation on a serial delivery queue):
1. `testReplayExistingReadsFromZero` — write 3 lines, start(replayExisting: true) → receives 3.
2. `testSeekToEOFSkipsExisting` — write 3 lines, start(replayExisting: false), append 2 → receives exactly 2.
3. `testPartialLineBufferedUntilNewline` — append `"half"` (no \n) → nothing; append `"-rest\nnext\n"` → receives ["half-rest", "next"].
4. `testTruncationResetsOffset` — 3 lines received; truncate file to zero + write 1 new line → receives that line (offset reset).
5. `testStopIsIdempotentAndStopsDelivery` — stop(); append → nothing delivered within 0.5 s; stop() again doesn't crash.

Write full test code (helper `append(_ s: String, to url: URL)` using FileHandle seek-to-end; expectations with 2 s timeouts; inverted expectations for the "nothing delivered" cases).

- [ ] **Step 2: Verify compile FAIL.**

- [ ] **Step 3: Implement** — complete file, mirroring DocStore's fd/DispatchSource idiom but with offset reads. Internal state (fd, offset, inode, partial buffer, source) guarded by the internal serial queue; `start`/`stop` dispatch onto it. Use `open(url.path, O_EVTONLY)` for the event source but a separate `FileHandle(forReadingAtPath:)` for reads (seek to offset). Inode via `fstat` on the read handle's fd. Comment the accepted race: an in-flight read may deliver once after stop() enqueued — the pool tears down consumers first (same accepted-race shape as ClaudeRegistryPoller).

- [ ] **Step 4: Verify green** — run the filter TWICE (timing-sensitive suite; both runs must pass — if flaky, fix timing margins, do not weaken asserts). Then full suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeTranscriptTailer.swift Tests/DreamuxTests/ClaudeTranscriptTailerTests.swift
git commit -m "Flows: offset-tracking kqueue transcript tailer"
```

---

### Task 10: FlowTailerPool + wiring

**Files:**
- Create: `Sources/Dreamux/Models/FlowTailerPool.swift`
- Modify: `Sources/Dreamux/Models/ClaudeSessionRegistry.swift` (ClaudeHome gains path derivation)
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (poller onSnapshot reconciles the pool)
- Test: `Tests/DreamuxTests/FlowTailerPoolTests.swift`, `Tests/DreamuxTests/ClaudeSessionRegistryTests.swift`

**Interfaces:**
- Produces:

```swift
extension ClaudeHome {
    /// Non-alphanumeric → "-" (claude's project-slug convention).
    static func projectSlug(forCwd cwd: String) -> String
    static func transcriptURL(home: URL, cwd: String, sessionID: String) -> URL          // <home>/projects/<slug>/<sessionID>.jsonl
    static func subagentsDirURL(home: URL, cwd: String, sessionID: String) -> URL       // <home>/projects/<slug>/<sessionID>/subagents
}

@MainActor final class FlowTailerPool {
    init(home: URL,
         onTranscriptLines: @escaping (_ sessionID: String, _ lines: [String]) -> Void,
         onAgentLines: @escaping (_ sessionID: String, _ agentID: String, _ lines: [String]) -> Void,
         onMeta: @escaping (_ sessionID: String, _ meta: SubagentMeta) -> Void)
    func reconcile(hot: [ClaudeSessionEntry])       // busy/waiting entries — start missing, stop departed
    func ensureLazyTail(sessionID: String, cwd: String)  // zoom: replayExisting tail regardless of hot status
    func releaseLazyTail(sessionID: String)
    var activeSessionIDs: Set<String> { get }       // test seam
}
```

Pool internals: per session, one transcript tailer (seek-to-EOF for hot; replayExisting for lazy) + a directory WATCHER on the subagents dir (DocStore idiom; on event, list `agent-*.meta.json` not yet seen → `SubagentMeta.parse` → onMeta; list `agent-*.jsonl` not yet tailed → spawn agent tailers, replayExisting: false for hot / true for lazy) + per-agent tailers feeding onAgentLines. Missing subagents dir at start = fine (watch the session dir's parent creation lazily: just retry listing on every transcript wake — simpler than watching a nonexistent dir; note this in a comment). Sessions leaving the hot set keep their OFFSET state (tailers stopped but not forgotten) so re-entry is incremental; a lane can be hot AND lazy — lazy release only stops tailers when the session isn't hot.

Wiring (ProjectSession, inside the gated section): construct the pool with callbacks that hop straight into the store —

```swift
        let pool = FlowTailerPool(
            home: ClaudeHome.root(),
            onTranscriptLines: { [weak flows] sessionID, lines in
                let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: lines)
                for event in events { flows?.apply(transcript: event, sessionID: sessionID) }
                if skipped > 0 { flows?.noteSkippedLines(skipped, sessionID: sessionID) }
            },
            onAgentLines: { [weak flows] sessionID, agentID, lines in
                if let activity = ClaudeFlowAdapter.lastActivity(fromAgentLines: lines) {
                    flows?.apply(agentActivity: activity, agentID: agentID, sessionID: sessionID)
                }
            },
            onMeta: { [weak flows] sessionID, meta in
                flows?.apply(meta: meta, sessionID: sessionID)
            }
        )
        flowTailerPool = pool
```

and extend the existing poller `onSnapshot` (after the registry apply): `pool.reconcile(hot: projectEntries.filter { $0.flowStatus == .running || $0.flowStatus == .waiting })`. Pool delivery queues: tailers deliver on a shared utility queue; the pool trampolines to `@MainActor` via `Task { @MainActor in ... }` before invoking the three callbacks (test this: callbacks land on main).

- [ ] **Step 1: Failing tests**
- Slug tests in `ClaudeSessionRegistryTests`: `projectSlug(forCwd: "/Users/x/dev.app/y") == "-Users-x-dev-app-y"`; transcriptURL/subagentsDirURL compose correctly.
- `FlowTailerPoolTests` (TestSandbox as fake claude home): seed `projects/<slug>/<sid>.jsonl`; `reconcile` with one busy entry → `activeSessionIDs` contains sid, appended transcript line arrives via onTranscriptLines ON MAIN (assert `Thread.isMainThread`); meta file dropped into subagents dir → onMeta fires; reconcile with empty → activeSessionIDs empty; append after stop → no delivery; `ensureLazyTail` on a cold session with pre-existing lines → lines replayed from zero.

Write full test code (async expectations, 3 s timeouts, the registry-entry JSON helper idiom).

- [ ] **Step 2: Verify compile FAIL.**  - [ ] **Step 3: Implement** per the interface + internals above (complete new file; ClaudeHome extension; ProjectSession wiring with `private var flowTailerPool: FlowTailerPool?` stored prop).

- [ ] **Step 4: Verify green** — pool filter TWICE + registry filter + `swift build` + FULL suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowTailerPool.swift Sources/Dreamux/Models/ClaudeSessionRegistry.swift Sources/Dreamux/Models/ProjectSession.swift Tests/DreamuxTests/FlowTailerPoolTests.swift Tests/DreamuxTests/ClaudeSessionRegistryTests.swift
git commit -m "Flows: hot-set tailer pool wired to registry snapshots"
```

---

### Task 11: FlowLayoutEngine

**Files:**
- Create: `Sources/Dreamux/Models/FlowLayoutEngine.swift`
- Test: `Tests/DreamuxTests/FlowLayoutEngineTests.swift`

**Interfaces:**
- Produces:

```swift
struct FlowLayout: Equatable {
    let positions: [String: CGPoint]   // node id → CENTER point
    let size: CGSize
}
enum FlowLayoutEngine {
    static let nodeSize = CGSize(width: 150, height: 44)
    static let rankGap: CGFloat = 56
    static let siblingGap: CGFloat = 18
    /// Top-to-bottom layered layout: rank = longest path from a source
    /// (node with no incoming edges), row order within a rank = average
    /// of parents' column indices (stable tiebreak: node id).
    static func layout(nodes: [FlowNode], edges: [FlowEdge]) -> FlowLayout
}
```

- [ ] **Step 1: Failing tests** — geometry, no views:
1. Chain src→a→drain: three ranks, x centered equal, y increasing by nodeSize.height + rankGap.
2. Fan-out src→{a,b,c}→drain (spawn edges from src): a,b,c share a rank, ordered by id, drain below.
3. Diamond keeps drain below the deepest branch (src→a→b→drain, src→drain edge too: drain rank = 3 not 1 — longest path).
4. Cycle safety: an edge back up (loop edge a→src) must not hang or crash — rank computation ignores edges that would revisit a node (DFS with visited set); assert it returns with all nodes positioned.
5. Empty input → zero size, empty positions.
6. size = max extent + one nodeSize margin on both axes; no two same-rank nodes overlap (pairwise distance ≥ nodeSize.width + siblingGap on x).

Write full test code with exact expected coordinates for cases 1–2 (derive from the constants: first rank centers at y = nodeSize.height/2 + margin where margin = nodeSize.height/2... define: y(rank) = margin + rank * (nodeSize.height + rankGap) + nodeSize.height/2 with margin = 24; x centers spread symmetrically around size.width/2. State these formulas in the test comments and assert exact values).

- [ ] **Step 2: Verify compile FAIL.**  - [ ] **Step 3: Implement** — pure, ~90 lines: build adjacency; ranks via memoized longest-path DFS with a visiting-set to cut cycles; group by rank; sort each rank by (average parent column, id); assign x by index within rank centered on the widest rank; margin 24. No Date, no IO.

- [ ] **Step 4: Verify green.**  - [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowLayoutEngine.swift Tests/DreamuxTests/FlowLayoutEngineTests.swift
git commit -m "Flows: pure layered DAG layout engine"
```

---

### Task 12: FlowDetailView + zoom navigation + e2e

**Files:**
- Create: `Sources/Dreamux/Views/FlowDetailView.swift`
- Modify: `Sources/Dreamux/Views/FlowsOverviewView.swift`, `Sources/Dreamux/Views/ContentView.swift`, `Sources/Dreamux/Views/FlowLaneView.swift` (lane tap)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`, `Sources/Dreamux/E2E/E2ERegistry.swift` (E2EBridge pendingFlowsZoom), `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`

**Interfaces:**
- Produces: `FlowDetailView(lane: FlowsBoard.Lane, onBack: () -> Void, onJumpToTerminal: (UUID) -> Void, onOpenTranscript: (String) -> Void)`; ContentView owns `@State flowsZoomLaneID: String?` passed as `Binding` to FlowsOverviewView; e2e command `zoomFlow {"laneID": ...}` + `zoomFlow {"laneID": null}` to clear; lane tap zooms; scenario extension.

View spec (mirror the approved zoom mock): breadcrumb row (`◀` button = onBack, "flows / <lane title>", trailing status + elapsed); horizontal split: left = ScrollView([.horizontal,.vertical]) containing a ZStack sized to `layout.size` — Canvas draws edges (straight lines center-to-center, loop-kind edges drawn dashed) beneath node views positioned at `layout.positions` (`.position()`); right = fixed 280 pt inspector. Node view: rounded rect, status glyph + label + multiplicity, selected stroke; tap selects. Inspector for selected node: status/rawValue + elapsed (startedAt/endedAt), lastActivity ("last activity" caption + monospaced line), buttons `[open transcript]` (session node → onOpenTranscript(sessionID); agent nodes → disabled this group) and `[jump to terminal]` (lane.flow.workspaceID). Nothing selected → lane summary (title, chip, node count). Pulse only on `.running` glyphs (reuse FlowStatusGlyph + reduceMotion gating idiom from FlowLaneView).

Zoom data: on appear, if the lane has `sessionID`, call the new ProjectSession lazy-tail seam: expose `func beginFlowsZoom(sessionID: String, cwd: String?)` / `endFlowsZoom(sessionID:)` on ProjectSession that forward to the pool's ensureLazyTail/releaseLazyTail (cwd from the lane's workspace working directory or project root fallback — the pool derives paths from cwd; store cwd per lane? The registry apply knows each session's cwd — persist it: add `var sessionCwd: String?` to Flow, set in apply(registry:)/event creation. Additive Codable default nil.) — wire through ContentView the way onJumpToTerminal is.

Open transcript: `onOpenTranscript(sessionID)` in ContentView resolves `ClaudeHome.transcriptURL(home: ClaudeHome.root(), cwd: lane.flow.sessionCwd ?? project.rootPath.path, sessionID:)` and calls the existing `openFile(url)` glue (verify Monaco opens absolute out-of-project URLs — smoke it in the e2e; if the viewer rejects external paths, fall back to `NSWorkspace.shared.open(url)` and note it).

e2e: `zoomFlow` command parks `bridge.pendingFlowsZoomLaneID` (String?, with a sentinel for clear — copy the pendingSidebarMode consume-and-clear idiom); ContentView consumes into `flowsZoomLaneID`. Extend `scenario_flows`: after the needs-you screenshot — emit a second agent + meta-join is NOT possible via socket alone (transcript files!): write a synthetic transcript + subagents meta into `$DREAMUX_CLAUDE_HOME/projects/<slug>/` matching the registry session (slug of the feature dir cwd — compute in python with the same non-alphanumeric→dash rule), flip entry to busy, wait for flowsState to show the agent node label enriched ("Explore") and session lastActivity, then `zoomFlow` the lane, screenshot `flows-zoom`, assert via flowsState that detailUnavailable is false, then `zoomFlow` null. Update PROTOCOL.md (zoomFlow + the new lane fields sessionCwd?/detailUnavailable if exposed).

- [ ] **Step 1: Build the view + navigation** (no unit tests — e2e covers; `swift build` gate).
- [ ] **Step 2: e2e scenario extension + run the suite; READ the three screenshots (overview, needs-you, zoom) — the zoom one must show the DAG with src/session/agent/drain nodes, the inspector pane, and the breadcrumb.**
- [ ] **Step 3: Full `swift test` + `swift build`.**
- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/FlowDetailView.swift Sources/Dreamux/Views/FlowsOverviewView.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/FlowLaneView.swift Sources/Dreamux/Models/FlowGraph.swift Sources/Dreamux/Models/FlowStore.swift Sources/Dreamux/Models/ProjectSession.swift Sources/Dreamux/E2E/E2ECommands.swift Sources/Dreamux/E2E/E2ERegistry.swift Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md
git commit -m "Flows: zoomed DAG detail view with inspector, lazy tail, e2e zoom scenario"
```

(If `sessionCwd` lands in Task 12 rather than earlier, FlowGraph/FlowStore belong in this commit; keep the diff reviewable by making the model change a separate first commit within this task if it grows.)

---

### Task 13: Semi-live validation

**Files:**
- Create: `Scripts/e2e/validate-flows-live.sh`
- Modify: `.superpowers/sdd/progress.md` is NOT committed — findings go in the task report + ledger via the controller.

Purpose: the spec's Group 3 exit criterion ("live validation against a real multi-worktree afternoon") without touching the user's running app or live `~/.claude`.

- [ ] **Step 1: Write the script** — `validate-flows-live.sh`: rsync a READ-ONLY slice of the real home into a sandbox (`rsync -a --exclude 'ide' --exclude 'daemon*' --exclude 'jobs' ~/.claude/sessions ~/.claude/projects "$SANDBOX/claude-home/"` — sessions + projects only), then run a focused swift executable? No — simplest: a dedicated XCTest, `LiveShapeValidationTests`, SKIPPED by default (`try XCTSkipUnless(ProcessInfo.processInfo.environment["DREAMUX_LIVE_VALIDATION"] == "1")`), which points `ClaudeHome` at the copy and (a) reads the registry via `ClaudeSessionRegistryReader` (liveness ignored: inject `{ _ in true }`), (b) for every session with an existing transcript, runs `ClaudeFlowAdapter.transcriptEvents` over the full file and asserts skipped-ratio < 20%, (c) parses every `agent-*.meta.json` under every session dir and counts parse failures (assert zero), (d) prints a summary table (sessions, events, spawns, joins, skip counts). The shell script = rsync + `DREAMUX_LIVE_VALIDATION=1 swift test --filter LiveShapeValidationTests`.
- [ ] **Step 2: Run it against this machine.** Paste the summary into the task report. Investigate any assertion failure — a >20% skip ratio or meta parse failure on real data is a REAL finding (fix the parser in this task if small; report BLOCKED with specifics if structural).
- [ ] **Step 3: DREAMUX_HOOK_DEBUG reality check (documentation step):** grep `~/Library/Logs/Dreamux-hook.log` for `flow_in`; if absent (likely — the user hasn't relaunched with the new shim), record in the report: "task_id/subject presence on TaskCreated stdin still unverified — check hook log after the user's first DREAMUX_HOOK_DEBUG=1 session" so the controller ledgers it for Group 4.
- [ ] **Step 4: Commit**

```bash
git add Scripts/e2e/validate-flows-live.sh Tests/DreamuxTests/LiveShapeValidationTests.swift
git commit -m "Flows: semi-live shape validation harness against copied real state"
```

---

## Deferred (explicitly NOT this plan)

- Loop detection (Group 4). Gate action cards + agent-transcript inspector opening (Group 5 / later).
- Journal.jsonl consumption and workflow phase-node rendering in lanes (parse landed in Task 7; rendering waits for a real workflow fixture — Group 4 rider).
- Collapsed-node expansion in DetailView; run-history strip on scheduled lanes (needs per-run history model).
- Unifying tile vs board aggregates (documented divergence stands; revisit with Group 5's gate cards).
