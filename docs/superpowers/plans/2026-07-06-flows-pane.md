# Flows Group 2 — Flows Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The user-visible Flows board: a sidebar tile with a live badge, an overview pane of source→drain lanes (plan runs, ad-hoc sessions, scheduled/background sessions) ordered needs-you-first, needs-you chips that jump to the terminal, live status dots on plan rows, and e2e coverage with screenshots — plus the Group 1 ride items.

**Architecture:** Two new PURE layers carry all the logic so they're TDD-able without SwiftUI: `PlanFlowBuilder` (plan/queue/ledger state → plan-kind `Flow` lanes) and `FlowsBoard` (composes plan lanes + FlowStore's session lanes: suppresses duplicate ad-hoc lanes, bubbles live session status onto plan lanes, orders sections, computes badge counts). Views (`FlowsOverviewView`, `FlowLaneView`) are thin renderers over `FlowsBoard.Lane` and are covered by e2e screenshots + a `flowsState` command, not unit tests (house style: no SwiftUI render tests). Glue lands in `ContentView`/`ProjectSession` following the Signals/Library patterns exactly.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, XCTest for pure layers, e2e via the unix-socket NDJSON harness (`Scripts/e2e/driver.py`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-flows-observatory-design.md` (Group 2). Group 1 is merged (`main` at cf14699); everything it produced is available (see Interfaces blocks).
- PlansSpecsSection's existing rows and controls are UNTOUCHED except for the additive live dot (spec decision 3: additive, no consolidation).
- Only `running` nodes/glyphs animate; respect `accessibilityReduceMotion`.
- Status glyph vocabulary (spec): ● running, ○ queued, ✓ done, ✗ failed, ! needs-you, ↺ scheduled/loop. Colors: running amber/orange, done green, failed red, needs-you orange/red-tinted, queued gray.
- Idle-but-alive session lanes read `.queued` (Group 1 final-review consequence) — the board labels them "idle" and sorts them with queued, never with finished.
- Stores/pure types: no new package dependencies; commits stage ONLY named files (never `git add -A`); parallel sessions may touch the repo.
- Run tests with `swift test --filter <TestClassName>`; run the full suite + `swift build` before each commit of an integration task.
- e2e: screenshots capture native SwiftUI fine; Ghostty terminal pixels render blank (assert via commands, not pixels).

## Adaptation ground rules (integration tasks 4, 6, 7, 8)

The pure-layer tasks (1–3, 5) contain complete code — transcribe them. The integration tasks modify large existing files; their code blocks are sketches with verified anchors: adapt names to what you find, and if the anchor doesn't exist in the described shape, STOP and report NEEDS_CONTEXT. Verified anchors as of cf14699:

- `SidebarTile` enum: `Sources/Dreamux/Models/SidebarTile.swift` (cases signals/browser/library with `symbol`/`tint`/`label` switches). `SidebarLayoutStore.reconcile` already unions `SidebarTile.allCases` (line ~80) — a new case appears automatically.
- `SidebarMode` enum: `Sources/Dreamux/Views/ContentView.swift:664` (cases workspace/run/signals/library); `mainPane` switch at `ContentView.swift:274-291`; tile selection highlight in `WorkspaceSidebar.tileRow` (`Views/WorkspaceSidebar.swift:423-456`, `selected` computed at :424-425); `handleTileTap` at :460.
- Jump-to-terminal idiom (`WorkspaceSidebar.selectWorkspace`, :621-624): `sidebarMode = .workspace; store.activate(workspace.id)`.
- Plan rows: `PlansSpecsSection.planRow(_:status:ordinal:blockedBy:)` at `Views/PlansSpecsSection.swift:644`; it already computes `let workspace = name.flatMap(workspaceForFeature)` — the live dot keys off that workspace's id.
- e2e: `E2ECommands.handle` switch at `Sources/Dreamux/E2E/E2ECommands.swift:50-110`; `setSidebarMode` at :438-465 (arms for workspace/signals/run — note `library` is MISSING, an accepted group-6 deferred item this plan folds in); `E2EProjectHandles` + `registerWithE2E()` in `E2ERegistry.swift` / `ProjectSession.swift:524+`.
- Queue/plan state for the builder glue: `PlanQueueController` (`@MainActor @Observable`, `entries: [String]` (plan paths), `state: PlanQueueState` idle/running/atGate/attention, `currentPlanPath: String?`); `PlanStatus` (specOnly/ready/inProgress/running/awaitingReview/merged); `PlanRunLedger.recordForPlan(_ relativePath:) -> PlanRunRecord?` (`planPath`, `featureName`, `startedAt`); `PlanPhases.Group` (has `checkedSteps`/`totalSteps` computed vars + a title and tasks — verify exact property names in `Models/PlanPhases.swift` before writing the glue); `DocStore` publishes initiatives/plans (see `PlansSpecsSection` usage).
- Group 1 interfaces consumed throughout: `Flow`/`FlowNode`/`FlowEdge`/`FlowStatus`/`FlowKind`/`FlowNodeKind`/`FlowAggregates` (`Models/FlowGraph.swift`), `FlowStore` (`@Published flows: [Flow]`, `aggregates`; lane ids `session-<id>`, node ids `src`/`session`/`drain`/`agent-*`/`task-*`), `ClaudeFlowAdapter`/`FlowEvent`, `FlowReplayLoader.events(store:now:window:cap:)`, `SignalKind.flowKinds`.

---

### Task 1: Group 1 hardening (ride items)

**Files:**
- Modify: `Sources/Dreamux/Models/FlowStore.swift` (makeSessionLane + apply(event:))
- Modify: `Sources/Dreamux/Models/FlowReplayLoader.swift`
- Test: `Tests/DreamuxTests/FlowStoreTests.swift`, `Tests/DreamuxTests/FlowReplayLoaderTests.swift`, `Tests/DreamuxTests/ClaudeFlowAdapterTests.swift`

**Interfaces:**
- Consumes: everything Group 1.
- Produces: unchanged signatures; behavior fixes later tasks rely on: event-created lanes carry `startedAt = event.at`; replay never emits `.notification` events.

- [ ] **Step 1: Write the failing tests**

Append to `FlowStoreTests`:

```swift
    func testEventCreatedLaneUsesEventTimestamp() {
        let store = FlowStore(workspaceForCwd: { _ in nil })
        let t = Date(timeIntervalSince1970: 500)
        store.apply(event: .agentStarted(
            sessionID: "s1", agentID: "a1", agentType: nil, description: nil, cwd: "/w", at: t
        ))
        XCTAssertEqual(store.flows[0].startedAt, t)
    }
```

Append to `FlowReplayLoaderTests` (uses the existing `flowSignal` helper; add a payload message variant inline):

```swift
    func testReplayDropsNotificationEvents() async {
        let now = Date()
        store.append(Signal(
            source: "claude.hooks",
            kind: SignalKind.sessionNotification,
            ts: now.addingTimeInterval(-5),
            tags: ["cwd": "/w"],
            payload: .object(["session_id": .string("s1"), "message": .string("needs permission")])
        ))
        store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1", ts: now.addingTimeInterval(-4)))
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 5_000)
        XCTAssertEqual(events.count, 1)
        guard case .agentStarted = events[0] else { return XCTFail("notification should be dropped in replay") }
    }

    func testReplayCapAcrossKinds() async {
        let now = Date()
        // 6 older agentStarted + 6 newer agentStopped; cap 8 must keep the
        // 8 most recent ACROSS kinds (6 stopped + 2 newest started).
        for i in 0..<6 {
            store.append(flowSignal(kind: SignalKind.agentStarted, session: "s1",
                                    ts: now.addingTimeInterval(TimeInterval(-100 - i)), agent: "old\(i)"))
        }
        for i in 0..<6 {
            store.append(flowSignal(kind: SignalKind.agentStopped, session: "s1",
                                    ts: now.addingTimeInterval(TimeInterval(-10 - i)), agent: "new\(i)"))
        }
        let events = await FlowReplayLoader.events(store: store, now: now, window: 86_400, cap: 8)
        XCTAssertEqual(events.count, 8)
        let startedCount = events.filter { if case .agentStarted = $0 { return true }; return false }.count
        XCTAssertEqual(startedCount, 2)
    }
```

Append to `ClaudeFlowAdapterTests`:

```swift
    func testEveryFlowKindMapsToAnEvent() {
        for kind in SignalKind.flowKinds {
            let s = signal(kind: kind, payload: [
                "session_id": .string("s1"), "agent_id": .string("a1"),
            ])
            XCTAssertNotNil(ClaudeFlowAdapter.event(from: s), "kind \(kind) does not map — flowKinds and the adapter switch have drifted")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FlowStoreTests && swift test --filter FlowReplayLoaderTests && swift test --filter ClaudeFlowAdapterTests`
Expected: `testEventCreatedLaneUsesEventTimestamp` FAILS (startedAt is wall-clock), `testReplayDropsNotificationEvents` FAILS (2 events returned), `testReplayCapAcrossKinds` FAILS or passes-by-luck (verify it exercises the trim), `testEveryFlowKindMapsToAnEvent` PASSES already (guards future drift — keep it).

- [ ] **Step 3: Implement**

In `FlowStore.swift`: give `makeSessionLane` a `startedAt: Date` parameter; `apply(registry:)` passes `Date()`, `apply(event:)` passes `event.at`:

```swift
    private func makeSessionLane(laneID: String, sessionID: String, kind: FlowKind, cwd: String?, startedAt: Date) -> Flow {
        Flow(
            id: laneID,
            title: sessionID,
            kind: kind,
            workspaceID: cwd.flatMap(workspaceForCwd),
            sessionID: sessionID,
            startedAt: startedAt,
            ...unchanged nodes/edges...
        )
    }
```

(Adapt the two call sites; keep everything else identical.)

In `FlowReplayLoader.swift`, after the compactMap, drop notifications (replayed needs-you text is stale by definition; the registry re-establishes live `waiting` within 3 s):

```swift
        return recentFirst
            .compactMap(ClaudeFlowAdapter.event(from:))
            .filter { if case .notification = $0 { return false }; return true }
            .sorted { $0.at < $1.at }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FlowStoreTests && swift test --filter FlowReplayLoaderTests && swift test --filter ClaudeFlowAdapterTests`
Expected: all PASS (13 + 4 + 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowStore.swift Sources/Dreamux/Models/FlowReplayLoader.swift Tests/DreamuxTests/FlowStoreTests.swift Tests/DreamuxTests/FlowReplayLoaderTests.swift Tests/DreamuxTests/ClaudeFlowAdapterTests.swift
git commit -m "Flows: event-time lane starts, replay drops stale notifications, kind-drift guard"
```

---

### Task 2: PlanFlowBuilder — plan state → plan lanes

**Files:**
- Create: `Sources/Dreamux/Models/PlanFlowBuilder.swift`
- Test: `Tests/DreamuxTests/PlanFlowBuilderTests.swift`

**Interfaces:**
- Consumes: `Flow`/`FlowNode`/`FlowEdge` types, `PlanStatus`, `PlanQueueState` (existing enums).
- Produces (later tasks rely on these exact names):
  - `struct PlanPhaseSummary: Equatable { let title: String; let checkedSteps: Int; let totalSteps: Int }`
  - `struct PlanLaneInput: Equatable { let planPath: String; let title: String; let status: PlanStatus; let phases: [PlanPhaseSummary]; let queueOrdinal: Int?; let isCurrentQueuePlan: Bool; let queueState: PlanQueueState?; let workspaceID: UUID?; let startedAt: Date? }`
  - `enum PlanFlowBuilder { static func lanes(from inputs: [PlanLaneInput]) -> [Flow] }`
  - Lane id convention `"plan-<planPath>"`; node ids `"src"`, `"phase-<index>"`, `"gate"`, `"drain"`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/PlanFlowBuilderTests.swift
import XCTest
@testable import Dreamux

final class PlanFlowBuilderTests: XCTestCase {
    private func input(
        path: String = "plans/auth.md", title: String = "Auth refresh",
        status: PlanStatus = .running,
        phases: [PlanPhaseSummary] = [
            PlanPhaseSummary(title: "Plan", checkedSteps: 4, totalSteps: 4),
            PlanPhaseSummary(title: "Implement", checkedSteps: 1, totalSteps: 6),
            PlanPhaseSummary(title: "Test", checkedSteps: 0, totalSteps: 3),
        ],
        ordinal: Int? = nil, isCurrent: Bool = false, queueState: PlanQueueState? = nil,
        workspaceID: UUID? = nil, startedAt: Date? = Date(timeIntervalSince1970: 100)
    ) -> PlanLaneInput {
        PlanLaneInput(
            planPath: path, title: title, status: status, phases: phases,
            queueOrdinal: ordinal, isCurrentQueuePlan: isCurrent, queueState: queueState,
            workspaceID: workspaceID, startedAt: startedAt
        )
    }

    func testRunningPlanLaneShape() {
        let wsID = UUID()
        let lanes = PlanFlowBuilder.lanes(from: [input(workspaceID: wsID)])
        XCTAssertEqual(lanes.count, 1)
        let lane = lanes[0]
        XCTAssertEqual(lane.id, "plan-plans/auth.md")
        XCTAssertEqual(lane.kind, .plan)
        XCTAssertEqual(lane.title, "Auth refresh")
        XCTAssertEqual(lane.workspaceID, wsID)
        XCTAssertEqual(lane.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "phase-0", "phase-1", "phase-2", "drain"])
        XCTAssertEqual(lane.nodes[0].status, .done)      // src
        XCTAssertEqual(lane.nodes[1].status, .done)      // 4/4
        XCTAssertEqual(lane.nodes[2].status, .running)   // 1/6, plan running
        XCTAssertEqual(lane.nodes[2].label, "Implement")
        XCTAssertEqual(lane.nodes[3].status, .queued)    // 0/3
        XCTAssertEqual(lane.nodes[4].status, .queued)    // drain pending
        // Sequential edges src→p0→p1→p2→drain
        XCTAssertEqual(lane.edges.count, 4)
        XCTAssertTrue(lane.edges.allSatisfy { $0.kind == .sequence })
        XCTAssertEqual(lane.status, .running)
    }

    func testPartialPhaseIsQueuedWhenPlanNotRunning() {
        // A half-checked phase only reads running while the plan itself runs.
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .inProgress)])
        XCTAssertEqual(lanes[0].nodes[2].status, .queued)
    }

    func testGateNodeAppearsAtGateAndReadsWaiting() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .awaitingReview, isCurrent: true, queueState: .atGate),
        ])
        let lane = lanes[0]
        XCTAssertEqual(lane.nodes.map(\.id), ["src", "phase-0", "phase-1", "phase-2", "gate", "drain"])
        XCTAssertEqual(lane.nodes.first { $0.id == "gate" }?.status, .waiting)
        XCTAssertEqual(lane.nodes.first { $0.id == "gate" }?.kind, .gate)
        XCTAssertEqual(lane.status, .waiting)
    }

    func testAttentionAlsoReadsWaiting() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .running, isCurrent: true, queueState: .attention),
        ])
        XCTAssertEqual(lanes[0].nodes.first { $0.id == "gate" }?.status, .waiting)
    }

    func testAwaitingReviewWithoutQueueShowsWaitingGate() {
        // A plan can reach review outside the queue; the gate still needs the human.
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .awaitingReview)])
        XCTAssertEqual(lanes[0].nodes.first { $0.id == "gate" }?.status, .waiting)
    }

    func testMergedPlanIsAllDone() {
        let phases = [PlanPhaseSummary(title: "All", checkedSteps: 5, totalSteps: 5)]
        let lanes = PlanFlowBuilder.lanes(from: [input(status: .merged, phases: phases)])
        let lane = lanes[0]
        XCTAssertNil(lane.nodes.first { $0.id == "gate" })
        XCTAssertEqual(lane.nodes.first { $0.id == "drain" }?.status, .done)
        XCTAssertEqual(lane.status, .done)
    }

    func testQueuedPlanShowsOrdinalDetailAndQueuedNodes() {
        let lanes = PlanFlowBuilder.lanes(from: [
            input(status: .ready, ordinal: 2, phases: [PlanPhaseSummary(title: "All", checkedSteps: 0, totalSteps: 5)], startedAt: nil),
        ])
        let lane = lanes[0]
        XCTAssertEqual(lane.detail, "queued #2")
        XCTAssertEqual(lane.status, .queued)
        XCTAssertEqual(lane.nodes.first { $0.id == "src" }?.status, .queued) // not started yet
    }

    func testNoPhasesYieldsSingleTasksPhase() {
        let lanes = PlanFlowBuilder.lanes(from: [input(phases: [])])
        XCTAssertEqual(lanes[0].nodes.map(\.id), ["src", "phase-0", "drain"])
        XCTAssertEqual(lanes[0].nodes[1].label, "tasks")
    }

    func testSpecOnlyPlansAreSkipped() {
        XCTAssertTrue(PlanFlowBuilder.lanes(from: [input(status: .specOnly)]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlanFlowBuilderTests`
Expected: compile FAILURE — `cannot find 'PlanLaneInput' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/PlanFlowBuilder.swift
import Foundation

/// One phase of a plan, pre-summarized so the builder stays decoupled
/// from PlanDoc/PlanPhases internals — the glue in ContentView does the
/// summarizing.
struct PlanPhaseSummary: Equatable {
    let title: String
    let checkedSteps: Int
    let totalSteps: Int
}

/// Everything the builder needs to know about one plan. Assembled by
/// thin glue from DocStore + PlanQueueController + PlanRunLedger +
/// WorkspaceStore; pure value so tests construct it directly.
struct PlanLaneInput: Equatable {
    let planPath: String
    let title: String
    let status: PlanStatus
    let phases: [PlanPhaseSummary]
    let queueOrdinal: Int?
    let isCurrentQueuePlan: Bool
    let queueState: PlanQueueState?
    let workspaceID: UUID?
    let startedAt: Date?
}

/// Plan state → plan-kind Flow lanes. Pure; no store access.
///
/// Lane shape: src → phase-0 … phase-N [→ gate] → drain.
/// - src: done once the plan has started (any status past .ready).
/// - phase-i: done when fully checked, running when partially checked
///   AND the plan is actively running, else queued.
/// - gate: present when the plan needs the human — queue atGate or
///   attention on this plan, or status .awaitingReview — always .waiting.
/// - drain: done only when merged.
enum PlanFlowBuilder {
    static func lanes(from inputs: [PlanLaneInput]) -> [Flow] {
        inputs.compactMap(lane(from:))
    }

    private static func lane(from input: PlanLaneInput) -> Flow? {
        guard input.status != .specOnly else { return nil }

        let started = input.status != .ready
        let isActive = input.status == .running
        let needsHuman = input.status == .awaitingReview
            || (input.isCurrentQueuePlan && (input.queueState == .atGate || input.queueState == .attention))

        var nodes: [FlowNode] = [
            FlowNode(id: "src", kind: .source, label: "plan", status: started ? .done : .queued),
        ]
        let phases = input.phases.isEmpty
            ? [PlanPhaseSummary(title: "tasks", checkedSteps: 0, totalSteps: 1)]
            : input.phases
        for (index, phase) in phases.enumerated() {
            let status: FlowStatus
            if input.status == .merged || (phase.totalSteps > 0 && phase.checkedSteps == phase.totalSteps) {
                status = .done
            } else if isActive && phase.checkedSteps > 0 {
                status = .running
            } else if isActive && isFirstUnfinished(phases, index) {
                status = .running
            } else {
                status = .queued
            }
            nodes.append(FlowNode(id: "phase-\(index)", kind: .phase, label: phase.title, status: status))
        }
        if needsHuman {
            nodes.append(FlowNode(id: "gate", kind: .gate, label: "review & merge", status: .waiting))
        }
        nodes.append(FlowNode(id: "drain", kind: .drain, label: "merge",
                              status: input.status == .merged ? .done : .queued))

        var edges: [FlowEdge] = []
        for pair in zip(nodes, nodes.dropFirst()) {
            edges.append(FlowEdge(from: pair.0.id, to: pair.1.id, kind: .sequence))
        }

        var flow = Flow(
            id: "plan-\(input.planPath)",
            title: input.title,
            kind: .plan,
            workspaceID: input.workspaceID,
            sessionID: nil,
            startedAt: input.startedAt,
            nodes: nodes,
            edges: edges
        )
        if let ordinal = input.queueOrdinal, input.status == .ready {
            flow.detail = "queued #\(ordinal)"
        }
        return flow
    }

    /// The active plan's "current" phase: the first not-fully-checked one.
    private static func isFirstUnfinished(_ phases: [PlanPhaseSummary], _ index: Int) -> Bool {
        let firstUnfinished = phases.firstIndex { $0.checkedSteps < $0.totalSteps }
        return firstUnfinished == index
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlanFlowBuilderTests`
Expected: PASS (9 tests). If `testRunningPlanLaneShape` fails on phase-2 expecting `.queued` while phase-1 is the first-unfinished running phase — that is the intended semantics; re-check the implementation, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanFlowBuilder.swift Tests/DreamuxTests/PlanFlowBuilderTests.swift
git commit -m "Flows: PlanFlowBuilder maps plan/queue/ledger state to plan lanes"
```

---

### Task 3: FlowsBoard — composition, ordering, badge counts

**Files:**
- Create: `Sources/Dreamux/Models/FlowsBoard.swift`
- Test: `Tests/DreamuxTests/FlowsBoardTests.swift`

**Interfaces:**
- Consumes: `Flow`, `FlowStatus`, `FlowKind` (Group 1), `PlanFlowBuilder` output shape (Task 2).
- Produces (views + e2e rely on these exact names):
  - `struct FlowsBoard: Equatable` with `let sections: [Section]`, `let runningCount: Int`, `let needsYouCount: Int`
  - `struct FlowsBoard.Lane: Equatable, Identifiable { let flow: Flow; let effectiveStatus: FlowStatus; let sessionChip: String?; var id: String { flow.id } }`
  - `enum FlowsBoard.SectionKind: String { case needsYou, running, queued, scheduled, finished }`
  - `struct FlowsBoard.Section: Equatable, Identifiable { let kind: SectionKind; let lanes: [Lane]; var id: String { kind.rawValue } }`
  - `static func compose(planLanes: [Flow], sessionLanes: [Flow]) -> FlowsBoard`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/FlowsBoardTests.swift
import XCTest
@testable import Dreamux

final class FlowsBoardTests: XCTestCase {
    private func lane(
        id: String, kind: FlowKind, status: FlowStatus,
        workspaceID: UUID? = nil, detail: String? = nil, startedAt: Date? = nil
    ) -> Flow {
        Flow(
            id: id, title: id, kind: kind, workspaceID: workspaceID,
            sessionID: nil, detail: detail, startedAt: startedAt,
            nodes: [FlowNode(id: "session", kind: .agent, label: "x", status: status)],
            edges: []
        )
    }

    func testAdhocLaneMatchingPlanWorkspaceIsSuppressedAndBubblesStatus() {
        let wsID = UUID()
        let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
        let session = lane(id: "session-s", kind: .adhoc, status: .waiting, workspaceID: wsID, detail: "needs permission")
        let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [session])

        let all = board.sections.flatMap(\.lanes)
        XCTAssertEqual(all.map(\.id), ["plan-p"]) // adhoc suppressed
        let planLane = all[0]
        XCTAssertEqual(planLane.effectiveStatus, .waiting)      // bubbled from live session
        XCTAssertEqual(planLane.flow.detail, "needs permission") // detail grafted
        XCTAssertEqual(board.needsYouCount, 1)
        XCTAssertEqual(board.runningCount, 0)
    }

    func testUnmatchedSessionLanesStay() {
        let board = FlowsBoard.compose(
            planLanes: [lane(id: "plan-p", kind: .plan, status: .running, workspaceID: UUID())],
            sessionLanes: [lane(id: "session-s", kind: .adhoc, status: .running)]
        )
        XCTAssertEqual(Set(board.sections.flatMap(\.lanes).map(\.id)), ["plan-p", "session-s"])
        XCTAssertEqual(board.runningCount, 2)
    }

    func testSectionOrderAndMembership() {
        let board = FlowsBoard.compose(
            planLanes: [
                lane(id: "plan-wait", kind: .plan, status: .waiting),
                lane(id: "plan-done", kind: .plan, status: .done),
            ],
            sessionLanes: [
                lane(id: "session-run", kind: .adhoc, status: .running),
                lane(id: "session-idle", kind: .adhoc, status: .queued),
                lane(id: "session-bg", kind: .scheduled, status: .done),
            ]
        )
        XCTAssertEqual(board.sections.map(\.kind), [.needsYou, .running, .queued, .scheduled, .finished])
        XCTAssertEqual(board.sections[0].lanes.map(\.id), ["plan-wait"])
        XCTAssertEqual(board.sections[1].lanes.map(\.id), ["session-run"])
        XCTAssertEqual(board.sections[2].lanes.map(\.id), ["session-idle"])
        XCTAssertEqual(board.sections[3].lanes.map(\.id), ["session-bg"]) // scheduled section regardless of doneness
        XCTAssertEqual(board.sections[4].lanes.map(\.id), ["plan-done"])
    }

    func testEmptySectionsAreOmitted() {
        let board = FlowsBoard.compose(planLanes: [], sessionLanes: [lane(id: "session-r", kind: .adhoc, status: .running)])
        XCTAssertEqual(board.sections.map(\.kind), [.running])
    }

    func testIdleSessionChipAndFreshnessOrderWithinSection() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [
                lane(id: "session-old", kind: .adhoc, status: .queued, startedAt: old),
                lane(id: "session-new", kind: .adhoc, status: .queued, startedAt: new),
            ]
        )
        XCTAssertEqual(board.sections[0].lanes.map(\.id), ["session-new", "session-old"]) // newest first
        XCTAssertEqual(board.sections[0].lanes[0].sessionChip, "idle")
    }

    func testWaitingSessionChipShowsWaiting() {
        let board = FlowsBoard.compose(
            planLanes: [],
            sessionLanes: [lane(id: "session-w", kind: .adhoc, status: .waiting)]
        )
        XCTAssertEqual(board.sections[0].lanes[0].sessionChip, "waiting on you")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FlowsBoardTests`
Expected: compile FAILURE — `cannot find 'FlowsBoard' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Dreamux/Models/FlowsBoard.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter FlowsBoardTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FlowsBoard.swift Tests/DreamuxTests/FlowsBoardTests.swift
git commit -m "Flows: FlowsBoard composes, suppresses, orders, and counts lanes"
```

---

### Task 4: SidebarTile.flows + SidebarMode.flows + e2e mode arms

**Files:**
- Modify: `Sources/Dreamux/Models/SidebarTile.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift` (SidebarMode enum :664; mainPane :274)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (setSidebarMode :438)
- Test: `Tests/DreamuxTests/SidebarLayoutStoreTests.swift` (existing reconcile coverage picks the new case up — verify)

This is small integration; adapt to the real files (see Adaptation ground rules).

- [ ] **Step 1: Add the tile case**

In `SidebarTile.swift`, add `case flows` after `case browser` (before `library`, so the default order groups activity tiles together), plus switch arms:

```swift
        case .flows: return "point.3.connected.trianglepath.dotted"   // symbol
        case .flows: return .orange                                   // tint
        case .flows: return "Flows"                                   // label
```

- [ ] **Step 2: Add the mode + pane arm**

In `ContentView.swift`: add `case flows` to `SidebarMode`; add to `mainPane`:

```swift
        case .flows:
            FlowsOverviewView(
                flows: session.flows,
                planLaneInputs: { planLaneInputs() },
                onJumpToTerminal: { workspaceID in
                    store.activate(workspaceID)
                    sidebarMode = .workspace
                }
            )
```

`FlowsOverviewView` and `planLaneInputs()` don't exist until Tasks 5–6 — to keep this task independently buildable, add the arm as `case .flows: Color.clear` with a `// Flows pane lands in Task 6` comment, and let Task 6 replace it. Also mirror the tile-selection highlight in `WorkspaceSidebar.tileRow` (`selected` computed, :424) and route the tap in `handleTileTap` (:460) the same way `.signals`/`.library` do (`sidebarMode = .flows`).

Note: `session` here refers to however `ContentView` reaches its `ProjectSession` — check the property names used by the `.signals` arm's neighbors and match them.

- [ ] **Step 3: e2e setSidebarMode arms**

In `E2ECommands.setSidebarMode` add BOTH missing arms (library is the accepted group-6 deferred item):

```swift
        case "flows":
            handles.bridge.pendingSidebarMode = .flows
        case "library":
            handles.bridge.pendingSidebarMode = .library
```

and extend the `default:` error message to name all five modes.

- [ ] **Step 4: Build + run layout tests**

Run: `swift build && swift test --filter SidebarLayoutStoreTests`
Expected: build clean; reconcile tests pass (allCases union admits the new tile; if a test pins an exact tile list, update its expectation to include `.flows` — that is the test tracking reality, not weakening).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SidebarTile.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/E2E/E2ECommands.swift Tests/DreamuxTests/SidebarLayoutStoreTests.swift
git commit -m "Flows: sidebar tile, SidebarMode.flows, e2e mode arms (incl. deferred library arm)"
```

---

### Task 5: FlowLaneView + node chips

**Files:**
- Create: `Sources/Dreamux/Views/FlowLaneView.swift`

**Interfaces:**
- Consumes: `FlowsBoard.Lane`, `Flow`, `FlowNode`, `FlowStatus` (Tasks 2–3, Group 1).
- Produces: `struct FlowLaneView: View` with `init(lane: FlowsBoard.Lane, onJumpToTerminal: ((UUID) -> Void)?)`; `enum FlowStatusGlyph { static func symbol(_ status: FlowStatus) -> String; static func color(_ status: FlowStatus) -> Color }` — Task 6 and 7 reuse `FlowStatusGlyph`.

No unit test (house style: view internals get e2e coverage in Task 9); the deliverable gate is `swift build` + Task 9's screenshots.

- [ ] **Step 1: Write the view**

```swift
// Sources/Dreamux/Views/FlowLaneView.swift
import SwiftUI

/// Shared status glyph vocabulary for the Flows surfaces (lanes, plan-row
/// dots, tile badge). Spec: ● running (amber, pulses), ○ queued (gray),
/// ✓ done (green), ✗ failed (red), ! needs-you (orange).
enum FlowStatusGlyph {
    static func symbol(_ status: FlowStatus) -> String {
        switch status {
        case .running: return "circle.fill"
        case .queued: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .waiting: return "exclamationmark.circle.fill"
        }
    }

    static func color(_ status: FlowStatus) -> Color {
        switch status {
        case .running: return .orange
        case .queued: return .secondary
        case .done: return .green
        case .failed: return .red
        case .waiting: return Color(nsColor: .systemOrange)
        }
    }
}

/// One lane: header row (glyph, title, elapsed, session chip) above a
/// horizontal source→drain pipeline of node chips. Scheduled lanes get
/// the compact single-row treatment with a ↺ marker.
struct FlowLaneView: View {
    let lane: FlowsBoard.Lane
    var onJumpToTerminal: ((UUID) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            pipeline
            if lane.effectiveStatus == .waiting, let detail = lane.flow.detail {
                needsYouChip(detail)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if lane.flow.kind == .scheduled {
                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            statusGlyph(lane.effectiveStatus, size: 10)
            Text(lane.flow.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let startedAt = lane.flow.startedAt, lane.effectiveStatus == .running {
                Text(startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let chip = lane.sessionChip {
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pipeline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(lane.flow.nodes.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    nodeChip(node)
                }
            }
        }
    }

    private func nodeChip(_ node: FlowNode) -> some View {
        HStack(spacing: 4) {
            statusGlyph(node.status, size: 7)
            Text(node.label)
                .font(.caption)
                .lineLimit(1)
            if let multiplicity = node.counters.multiplicity, multiplicity > 1 {
                Text("×\(multiplicity)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(FlowStatusGlyph.color(node.status).opacity(node.status == .queued ? 0.06 : 0.12))
        )
        .help("\(node.label) — \(String(describing: node.status))")
    }

    private func needsYouChip(_ detail: String) -> some View {
        Button {
            if let ws = lane.flow.workspaceID { onJumpToTerminal?(ws) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11))
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
            }
            .foregroundStyle(FlowStatusGlyph.color(.waiting))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(FlowStatusGlyph.color(.waiting).opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(lane.flow.workspaceID == nil)
        .help("Jump to this workspace's terminal")
    }

    /// Only `.running` pulses; reduce-motion pins full opacity.
    private func statusGlyph(_ status: FlowStatus, size: CGFloat) -> some View {
        Image(systemName: FlowStatusGlyph.symbol(status))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(FlowStatusGlyph.color(status))
            .opacity(status == .running && pulsing && !reduceMotion ? 0.35 : 1.0)
            .animation(
                status == .running && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean. (If `arrow.trianglehead.2.counterclockwise` is unavailable on the deployment target, use `"arrow.2.circlepath"` — check how other views in the repo pick SF Symbols and match the safest one used.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/FlowLaneView.swift
git commit -m "Flows: lane view with node-chip pipeline and needs-you jump chip"
```

---

### Task 6: FlowsOverviewView + ContentView glue

**Files:**
- Create: `Sources/Dreamux/Views/FlowsOverviewView.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift` (replace Task 4's placeholder arm; add `planLaneInputs()` glue)

**Interfaces:**
- Consumes: `FlowsBoard`, `PlanFlowBuilder`, `FlowLaneView`, `FlowStore`, plus existing stores (`DocStore`, `PlanQueueController`, `PlanRunLedger` via `ProjectSession`, `WorkspaceStore`).
- Produces: `struct FlowsOverviewView: View` with `init(flows: FlowStore, planLaneInputs: @escaping () -> [PlanLaneInput], onJumpToTerminal: @escaping (UUID) -> Void)`. A `planLaneInputs()` free/private function in ContentView that later tasks (e2e `flowsState`) can mirror.

- [ ] **Step 1: Write the overview view**

```swift
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
```

- [ ] **Step 2: Write the ContentView glue**

Replace Task 4's placeholder `.flows` arm with the real construction, and add the input-assembly function near the other private helpers. The glue summarizes plans exactly the way `PlansSpecsSection` derives its rows — reuse the SAME sources it uses (check its `ForEach(active)`/`statusForPlan`/`featureName(plan)` helpers around `PlansSpecsSection.swift:286+` and mirror the closures `ContentView` already wires into `PlanQueueController` at construction):

```swift
    /// Assemble PlanLaneInputs from the same state PlansSpecsSection
    /// renders: DocStore plans, derived PlanStatus, PlanPhases groups,
    /// queue position, ledger start time, live workspace.
    private func planLaneInputs() -> [PlanLaneInput] {
        let queue = session.planQueue
        return docStore.allPlans.map { plan in
            let status = statusForPlan(plan) // mirror PlansSpecsSection's derivation
            let groups = PlanPhases.shouldGroup(plan.tasks) ? PlanPhases.groups(plan.tasks) : []
            let record = session.planLedger.recordForPlan(plan.relativePath)
            let workspace = featureName(plan).flatMap { name in
                store.workspaces.first { $0.name == name }
            }
            return PlanLaneInput(
                planPath: plan.relativePath,
                title: plan.title,
                status: status,
                phases: groups.map {
                    PlanPhaseSummary(title: $0.title, checkedSteps: $0.checkedSteps, totalSteps: $0.totalSteps)
                },
                queueOrdinal: queue.entries.firstIndex(of: plan.relativePath).map { $0 + 1 },
                isCurrentQueuePlan: queue.currentPlanPath == plan.relativePath,
                queueState: queue.state,
                workspaceID: workspace?.id,
                startedAt: record?.startedAt
            )
        }
    }
```

ADAPT every name in this sketch to reality: `docStore.allPlans` / `plan.relativePath` / `plan.tasks` / `PlanPhases.Group.title` / how ContentView reaches the ledger and queue — find the real accessors (PlansSpecsSection and ProjectSession show all of them). If plan identity is a URL rather than a relative path, key `PlanLaneInput.planPath` off the same string the queue's `entries` uses so ordinal/current matching works.

- [ ] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: build clean, full suite green (glue is view-side; no store behavior changed).

Re-render caveat to verify while you're in the code: `FlowsOverviewView` observes only `FlowStore`; plan-state reads happen through the `planLaneInputs` closure during body evaluation. If `PlanQueueController` (`@Observable`) and the plan/doc source are Observation-tracked, closure reads during body ARE tracked and plan changes re-render. If the doc source is an old-style `ObservableObject` reached only through the closure, its changes will NOT re-render the pane until a FlowStore publish (up to one 3 s tick, or indefinitely when the upsert equality gate suppresses publishes). Check which world each source lives in; if untracked, pass it into `FlowsOverviewView` as an observed property alongside `flows` and note that in your report.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/FlowsOverviewView.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Flows: overview pane with sectioned lanes, empty state, plan-lane glue"
```

---

### Task 7: Tile badge + plan-row live dots

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (tileRow :423)
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift` (planRow :644)

**Interfaces:**
- Consumes: `FlowStore.aggregates` (`FlowAggregates(runningCount:needsYouCount:)`), `FlowStore.flows` (lookup by workspaceID), `FlowStatusGlyph` (Task 5).
- Produces: user-visible badge on the Flows tile; live dot on plan rows. Both purely additive.

- [ ] **Step 1: Tile badge**

`WorkspaceSidebar` needs the FlowStore — add it to the view's stored properties the same way it receives its other stores (check the memberwise init call sites; ContentView constructs it). In `tileRow`, after the `Text(tile.label)` and before `Spacer()`, render for `.flows` only:

```swift
                if tile == .flows {
                    let agg = flows.aggregates
                    if agg.needsYouCount > 0 {
                        badgeText("!\(agg.needsYouCount)", color: FlowStatusGlyph.color(.waiting))
                    }
                    if agg.runningCount > 0 {
                        badgeText("●\(agg.runningCount)", color: FlowStatusGlyph.color(.running))
                    }
                }
```

with a tiny private helper:

```swift
    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
```

Also add `.flows` to the `selected` computed in tileRow (`|| (tile == .flows && sidebarMode == .flows)`) and to `handleTileTap` if Task 4 didn't already. Note the badge intentionally counts SESSION lanes only (FlowStore aggregates); plan-gate needs-you already surfaces through the queue's existing attention affordances — don't double-count.

- [ ] **Step 2: Plan-row live dot**

`planRow` already computes `let workspace = name.flatMap(workspaceForFeature)` (:656). Inject the FlowStore into `PlansSpecsSection` (same pattern as its other stores). Where the row renders its trailing affordances (find the `docRow(...)` trailing content or the hover-controls overlay — put the dot BEFORE the unread dot so the two never overlap), add:

```swift
    /// Live claude-session status for this plan's workspace: ! waiting
    /// (needs you), ● running. Nothing when no live session lane exists.
    @ViewBuilder
    private func liveFlowDot(for workspace: Workspace?) -> some View {
        if let ws = workspace,
           let lane = flows.flows.first(where: { $0.workspaceID == ws.id && $0.kind == .adhoc }),
           lane.status == .waiting || lane.status == .running {
            Image(systemName: FlowStatusGlyph.symbol(lane.status))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FlowStatusGlyph.color(lane.status))
                .help(lane.status == .waiting ? (lane.detail ?? "Waiting on you") : "claude busy")
        }
    }
```

- [ ] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: clean/green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Flows: live tile badge and plan-row status dots"
```

(Include ContentView only if constructor call sites needed the new store parameter.)

---

### Task 8: SignalsView visibility + flowsState e2e command

**Files:**
- Modify: `Sources/Dreamux/Models/ProjectSession.swift` (signal forwarding filter ~:391; `registerWithE2E` :524+)
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift` (E2EProjectHandles)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (new command)
- Test: covered by Task 9's scenario; `swift build` + full suite here.

**Interfaces:**
- Consumes: `FlowStore`, `FlowsBoard`, existing forwarding filter, `E2EProjectHandles`.
- Produces: flow signals visible in SignalsView; e2e command `flowsState` returning `{ok, lanes: [{id, title, kind, status, chip?, detail?, nodes: [{id, label, status}]}], running, needsYou}`.

- [ ] **Step 1: Widen the SignalsView forwarding filter**

In `ProjectSession`'s signal forwarding (the `tags["project_dir"] == projectDir` check near :391), accept flow signals scoped by cwd — reuse the same `isInProject` closure the flow wiring built (hoist it if it's currently local to the flow block):

```swift
            let matchesProject = signal.tags["project_dir"] == projectDir
                || (SignalKind.flowKinds.contains(signal.kind)
                    && (signal.tags["cwd"].map(isInProject) ?? false))
```

- [ ] **Step 2: Register the store + add the command**

Add `weak var flows: FlowStore?` (or matching non-weak pattern — copy whatever `E2EProjectHandles` does for the other stores) to `E2EProjectHandles`; set it in `ProjectSession.registerWithE2E()`. In `E2ECommands`, add:

```swift
        case "flowsState":
            return try flowsState(request: request)
```

```swift
    private static func flowsState(request: [String: Any]) throws -> [String: Any] {
        let (handles, _, _) = try projectStores()
        guard let flows = handles.flows else { throw CommandError(message: "flows store not registered") }
        // Session lanes only — plan lanes are derived in the view from plan
        // state the e2e can already assert via queueState/listDocs.
        let lanes: [[String: Any]] = flows.flows.map { flow in
            var lane: [String: Any] = [
                "id": flow.id, "title": flow.title,
                "kind": flow.kind.rawValue, "status": flow.status.rawValue,
                "nodes": flow.nodes.map { ["id": $0.id, "label": $0.label, "status": $0.status.rawValue] },
            ]
            if let detail = flow.detail { lane["detail"] = detail }
            return lane
        }
        return [
            "ok": true,
            "lanes": lanes,
            "running": flows.aggregates.runningCount,
            "needsYou": flows.aggregates.needsYouCount,
        ]
    }
```

(`E2ECommands.handle` is MainActor-serialized — check how other store-reading commands access MainActor state and match.)

- [ ] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: clean/green.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Models/ProjectSession.swift Sources/Dreamux/E2E/E2ERegistry.swift Sources/Dreamux/E2E/E2ECommands.swift
git commit -m "Flows: flow signals reach SignalsView; flowsState e2e command"
```

---

### Task 9: e2e scenario_flows

**Files:**
- Modify: `Scripts/e2e/run-e2e.sh` (env export block, ~:56-63)
- Modify: `Scripts/e2e/driver.py` (new scenario)
- Modify: `Scripts/e2e/PROTOCOL.md` (document `flowsState` + `setSidebarMode` flows/library)

**Interfaces:**
- Consumes: `flowsState` + `setSidebarMode` (Tasks 4, 8), `DREAMUX_CLAUDE_HOME` (Group 1), the emit socket (`/tmp/dreamux-emit-<bundle-id>.sock` — discover the actual path: the app under e2e uses `SignalEmitSocketServer.defaultSocketPath()`; read the bundle id the e2e app reports or compute from the built app's Info.plist).
- Produces: `scenario_flows` with screenshots `NN-flows-overview.png`, `NN-flows-needs-you.png`.

- [ ] **Step 1: Export the synthetic claude home**

In `run-e2e.sh` next to the other exports:

```bash
export DREAMUX_CLAUDE_HOME="$SANDBOX/claude-home"
mkdir -p "$DREAMUX_CLAUDE_HOME/sessions"
```

- [ ] **Step 2: Write the scenario**

Follow the shape of an existing scenario (e.g. `scenario_discovery`, driver.py:465) — `d` is the driver with `d.cmd(...)`, `require(...)`, `d.screenshot(...)` helpers; verify exact helper names in the file first:

```python
def scenario_flows(d):
    """Flows pane: synthetic registry session + real hook signals render lanes."""
    import json, os, socket, time

    home = os.environ["DREAMUX_CLAUDE_HOME"]
    feature_dir = d.feature_dir("flows-demo")  # ADAPT: however other scenarios get a workspace path; create the feature first via createFeature if needed

    # 1. A live "busy" claude session in the registry, pid = this driver
    #    (alive for the whole scenario, so the liveness probe keeps it).
    entry = {
        "pid": os.getpid(), "sessionId": "e2e-session-1", "cwd": feature_dir,
        "status": "busy", "kind": "interactive", "name": "flows-demo",
    }
    with open(os.path.join(home, "sessions", f"{os.getpid()}.json"), "w") as f:
        json.dump(entry, f)

    # 2. A subagent start via the REAL emit socket (same wire the hook uses).
    sock_path = d.emit_socket_path()  # ADAPT: derive /tmp/dreamux-emit-<bundle-id>.sock from the app's bundle id; add a tiny helper if none exists
    envelope = {"action": "emit", "signal": {
        "kind": "agent.started", "source": "claude.hooks", "severity": "info",
        "tags": {"cwd": feature_dir},
        "payload": {"session_id": "e2e-session-1", "agent_id": "e2e-a1", "agent_type": "Explore"},
    }}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.sendall((json.dumps(envelope) + "\n").encode())
    s.recv(256); s.close()

    # 3. Wait for the 3s registry poll + signal to land, then assert.
    deadline = time.time() + 10
    lanes = []
    while time.time() < deadline:
        state = d.cmd({"cmd": "flowsState"})
        lanes = state.get("lanes", [])
        if any(l["id"] == "session-e2e-session-1" for l in lanes):
            lane = next(l for l in lanes if l["id"] == "session-e2e-session-1")
            if any(n["id"] == "agent-e2e-a1" for n in lane["nodes"]):
                break
        time.sleep(0.5)
    lane = next((l for l in lanes if l["id"] == "session-e2e-session-1"), None)
    require(lane is not None, "session lane never appeared in flowsState")
    require(lane["status"] == "running", f"lane should be running, got {lane['status']}")
    require(any(n["id"] == "agent-e2e-a1" and n["status"] == "running" for n in lane["nodes"]),
            "agent node missing or not running")
    require(state["running"] >= 1, "running aggregate should count the lane")

    # 4. Render + screenshot.
    d.cmd({"cmd": "setSidebarMode", "mode": "flows"})
    time.sleep(1.0)
    d.screenshot("flows-overview")

    # 5. Needs-you: flip the registry entry to waiting + emit notification.
    entry["status"] = "waiting"
    with open(os.path.join(home, "sessions", f"{os.getpid()}.json"), "w") as f:
        json.dump(entry, f)
    envelope["signal"]["kind"] = "session.notification"
    envelope["signal"]["payload"] = {"session_id": "e2e-session-1", "message": "Claude needs permission to run npm"}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.sendall((json.dumps(envelope) + "\n").encode())
    s.recv(256); s.close()

    deadline = time.time() + 10
    while time.time() < deadline:
        state = d.cmd({"cmd": "flowsState"})
        if state.get("needsYou", 0) >= 1:
            break
        time.sleep(0.5)
    require(state.get("needsYou", 0) >= 1, "needsYou aggregate never rose")
    lane = next(l for l in state["lanes"] if l["id"] == "session-e2e-session-1")
    require(lane.get("detail") == "Claude needs permission to run npm", "notification detail missing")
    time.sleep(1.0)
    d.screenshot("flows-needs-you")
```

Register the scenario wherever the driver enumerates scenarios (match how `scenario_discovery` is registered/ordered — likely a list or naming convention; place it after the plan/queue scenarios so a feature workspace exists to map `cwd` onto). ADAPT the two flagged helpers (`feature_dir`, `emit_socket_path`) to the driver's real API — if no bundle-id helper exists, compute the socket path in run-e2e.sh (`defaults read "$ROOT/Dreamux.app/Contents/Info" CFBundleIdentifier`) and export it as `E2E_EMIT_SOCKET` for the driver.

- [ ] **Step 3: Document**

Add `flowsState` (request/response shape) and the new `setSidebarMode` modes (`flows`, `library`) to `Scripts/e2e/PROTOCOL.md`, matching its existing entry format.

- [ ] **Step 4: Run the scenario**

Run: `Scripts/e2e/run-e2e.sh flows` (check how the runner selects scenarios — pass the name the same way existing docs/scenarios do; if it always runs the full suite, run the full suite).
Expected: scenario passes; `artifacts/e2e/latest/` contains `NN-flows-overview.png` and `NN-flows-needs-you.png`. Look at both screenshots — the overview must show the Running section with the flows-demo lane and its agent chip; needs-you must show the orange chip with the permission text.

- [ ] **Step 5: Commit**

```bash
git add Scripts/e2e/run-e2e.sh Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md
git commit -m "Flows: e2e scenario with synthetic registry, real socket signals, screenshots"
```

---

## Deferred (explicitly NOT this plan)

- Zoomed DAG + inspector + tailer (Group 3); loop detection (Group 4); gate action cards with view-diff/merge buttons (Group 5 — the gate NODE renders in lanes now, but its expanded card with actions is Group 5).
- Scheduled lanes' run-history strip (spec: "chips open that run's transcript") — the chips need Group 3's transcript viewer, and the per-run history derives from replayed session.stopped events; the whole strip rides to Group 3. This group renders scheduled lanes as compact ↺ lanes without history.
- Grafting session agent/task nodes INTO plan-lane phases (Group 3, needs the tailer's phase attribution).
- TaskCreated `task_id`/`subject` reality check: during this group's live validation, run a session with `DREAMUX_HOOK_DEBUG=1` and read `~/Library/Logs/Dreamux-hook.log` (`flow_in` lines) — record the answer in the ledger.
