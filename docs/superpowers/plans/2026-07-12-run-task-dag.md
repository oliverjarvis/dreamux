# Run Task DAG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zooming into a plan's Flows lane shows its tasks as a DAG (phases as bands, status from checkboxes) with live subagents grafted onto the task each is working.

**Architecture:** `PlanLaneAssembler` projects `PlanTaskSummary`s; `PlanFlowBuilder` builds `src → plan-task-<line> → gate → drain`; `RunLaneGraft` attaches slice 1's `OverviewLiveAgents` output as `.agent` nodes; `ContentView`/`FlowsOverviewView` graft before `FlowsBoard.compose`; `FlowDetailView` draws phase bands.

**Tech Stack:** SwiftUI, existing `FlowGraph`/`FlowLayoutEngine`/`PlanFlowBuilder`/`PlanLaneAssembler`/`OverviewLiveAgents`/`SubagentTaskPin`, XCTest.

**Spec:** docs/superpowers/specs/2026-07-12-run-task-dag-design.md — read it first.

## Global Constraints

- **Reuse slice 1 for the graft** — `OverviewLiveAgents.subagents(in:workspaceID:tasks:)` already filters live `.agent` nodes + pins each to a `PlanTask.line`. Don't reimplement pinning.
- **Keep `"src"`/`"gate"`/`"drain"` node ids** in the task-DAG lane (FlowDetailView auto-selects `"gate"`, reads `"drain"` for elapsed). Plan-task nodes use their own namespace **`"plan-task-<line>"`** (session lanes already use `"task-<id>"`).
- **`FlowNode.group` is additive** (nil default) — existing constructors unaffected.
- **Observation only** — no task-parallelism orchestration; subagents attach where `SubagentTaskPin` maps them (current task when unpinned).
- **Empty-tasks fallback** — a task-less/spec-only plan still builds today's phase skeleton unchanged.

## File Structure

- `Sources/Dreamux/Models/PlanTaskTitle.swift` (new) — title-clean helper.
- `Sources/Dreamux/Models/PlanFlowBuilder.swift` (modify) — `PlanTaskSummary`, `PlanLaneInput.tasks`, task-DAG mode.
- `Sources/Dreamux/Models/PlanLaneAssembler.swift` (modify) — project summaries.
- `Sources/Dreamux/Models/FlowGraph.swift` (modify) — `FlowNode.group`.
- `Sources/Dreamux/Models/RunLaneGraft.swift` (new) — the graft.
- `Sources/Dreamux/Views/ContentView.swift`, `FlowsOverviewView.swift`, `FlowDetailView.swift` (modify).
- Tests: `PlanTaskSummaryTests`, `RunLaneGraftTests` (new); `PlanFlowBuilderTests` (extend).

---

### Task 1: Task-data plumbing — `PlanTaskSummary` + projection

**Files:** Create `Sources/Dreamux/Models/PlanTaskTitle.swift`, `Tests/DreamuxTests/PlanTaskSummaryTests.swift`. Modify `Sources/Dreamux/Models/PlanFlowBuilder.swift` (add `PlanTaskSummary` + `PlanLaneInput.tasks`), `Sources/Dreamux/Models/PlanLaneAssembler.swift` (project).

**Interfaces:**
- Consumes: `PlanTask` (`title`, `steps`, `phase`, `line`).
- Produces: `PlanTaskTitle.clean(_:) -> String`; `PlanTaskSummary { line, title, phase, checkedSteps, totalSteps, isCurrent }` + `PlanTaskSummary.summaries(from: [PlanTask]) -> [PlanTaskSummary]`; `PlanLaneInput.tasks: [PlanTaskSummary]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/PlanTaskSummaryTests.swift
import XCTest
@testable import Dreamux

final class PlanTaskSummaryTests: XCTestCase {
    private func task(_ title: String, line: Int, checks: [Bool]) -> PlanTask {
        PlanTask(title: title, steps: checks.map { PlanStep(title: "s", checked: $0) }, phase: "P1", line: line)
    }
    func testCleanStripsLeadingTaskN() {
        XCTAssertEqual(PlanTaskTitle.clean("Task 3: collisions"), "collisions")
        XCTAssertEqual(PlanTaskTitle.clean("Ad-hoc thing"), "Ad-hoc thing")
        XCTAssertEqual(PlanTaskTitle.clean(""), "Steps")
    }
    func testSummariesStatusAndCurrent() {
        let tasks = [task("Task 1: a", line: 5, checks: [true, true]),
                     task("Task 2: b", line: 9, checks: [true, false]),
                     task("Task 3: c", line: 14, checks: [false])]
        let s = PlanTaskSummary.summaries(from: tasks)
        XCTAssertEqual(s.map(\.line), [5, 9, 14])
        XCTAssertEqual(s.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(s[0].checkedSteps, 2); XCTAssertEqual(s[0].totalSteps, 2)
        // current = first task with an unchecked step (line 9)
        XCTAssertEqual(s.map(\.isCurrent), [false, true, false])
        XCTAssertEqual(s[0].phase, "P1")
    }
    func testEmptyStepTasksExcluded() {
        let tasks = [PlanTask(title: "Task 1: x", steps: [], phase: nil, line: 1),
                     task("Task 2: y", line: 4, checks: [false])]
        XCTAssertEqual(PlanTaskSummary.summaries(from: tasks).map(\.line), [4])
    }
    func testAllCheckedHasNoCurrent() {
        let s = PlanTaskSummary.summaries(from: [task("Task 1: a", line: 1, checks: [true])])
        XCTAssertEqual(s.map(\.isCurrent), [false])
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter PlanTaskSummaryTests` → FAIL.

- [ ] **Step 3: Implement**

```swift
// Sources/Dreamux/Models/PlanTaskTitle.swift
import Foundation

enum PlanTaskTitle {
    /// Strip a leading `Task N:` / `Task N.M:` from a heading (a node/row
    /// already carries the ordinal); keep any other title verbatim; an empty
    /// title reads as "Steps".
    static func clean(_ title: String) -> String {
        if let r = title.range(of: #"^Task\s+\d+(?:\.\d+)*:\s*"#, options: .regularExpression) {
            let rest = String(title[r.upperBound...])
            return rest.isEmpty ? "Steps" : rest
        }
        return title.isEmpty ? "Steps" : title
    }
}
```

In `PlanFlowBuilder.swift` add the summary type:
```swift
struct PlanTaskSummary: Equatable {
    let line: Int
    let title: String
    let phase: String?
    let checkedSteps: Int
    let totalSteps: Int
    let isCurrent: Bool

    /// Project a plan's checkbox-bearing tasks into lane summaries. The
    /// current task is the first with an unchecked step (PlanCurrentStep's
    /// rule); an all-checked plan has none.
    static func summaries(from tasks: [PlanTask]) -> [PlanTaskSummary] {
        let real = tasks.filter { !$0.steps.isEmpty }
        let currentLine = real.first { $0.steps.contains { !$0.checked } }?.line
        return real.map { t in
            PlanTaskSummary(
                line: t.line, title: PlanTaskTitle.clean(t.title), phase: t.phase,
                checkedSteps: t.steps.filter(\.checked).count, totalSteps: t.steps.count,
                isCurrent: t.line == currentLine)
        }
    }
}
```

Add `tasks` to `PlanLaneInput` **with a defaulted custom init** so existing constructors (which omit it) keep compiling: add `let tasks: [PlanTaskSummary]` as the last stored property, and give `PlanLaneInput` an explicit `init(...)` listing every field with `tasks: [PlanTaskSummary] = []` last. In `PlanLaneAssembler.inputs(...)`, pass `tasks: PlanTaskSummary.summaries(from: plan.tasks)` when constructing each `PlanLaneInput`.

- [ ] **Step 4: Run to verify they pass + build** — `swift test --filter PlanTaskSummaryTests` → PASS (4). `swift build` → clean (confirms the defaulted init didn't break existing `PlanLaneInput` call sites/tests).

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Models/PlanTaskTitle.swift Sources/Dreamux/Models/PlanFlowBuilder.swift Sources/Dreamux/Models/PlanLaneAssembler.swift Tests/DreamuxTests/PlanTaskSummaryTests.swift
git commit -m "Run DAG: PlanTaskSummary + lane-input task projection"
```

---

### Task 2: `FlowNode.group` + `PlanFlowBuilder` task-DAG mode

**Files:** Modify `Sources/Dreamux/Models/FlowGraph.swift` (`FlowNode.group`), `Sources/Dreamux/Models/PlanFlowBuilder.swift` (task-DAG). Extend `Tests/DreamuxTests/PlanFlowBuilderTests.swift`.

**Interfaces:**
- Consumes: `PlanLaneInput.tasks` (Task 1), `PlanTaskSummary`.
- Produces: `FlowNode.group: String?`; a task-DAG `Flow` when `input.tasks` non-empty.

- [ ] **Step 1: Add `FlowNode.group`**

In `FlowGraph.swift`, add `var group: String? = nil` to `FlowNode` (and its `init`, defaulted last) — additive, so existing constructors are unaffected.

- [ ] **Step 2: Write the failing test** (append to `PlanFlowBuilderTests.swift`)

```swift
func testTaskDagWhenInputHasTasks() {
    let tasks = [
        PlanTaskSummary(line: 5, title: "a", phase: "Phase 1", checkedSteps: 1, totalSteps: 1, isCurrent: false),
        PlanTaskSummary(line: 9, title: "b", phase: "Phase 2", checkedSteps: 0, totalSteps: 2, isCurrent: true),
        PlanTaskSummary(line: 14, title: "c", phase: "Phase 2", checkedSteps: 0, totalSteps: 1, isCurrent: false),
    ]
    let input = PlanLaneInput(planPath: "docs/plans/x.md", title: "X", status: .running,
                              phases: [], queueOrdinal: nil, isCurrentQueuePlan: false,
                              queueState: nil, workspaceID: nil, startedAt: nil, tasks: tasks)
    let lane = PlanFlowBuilder.lanes(from: [input]).first!
    XCTAssertEqual(lane.nodes.map(\.id).prefix(4).map { $0 },
                   ["src", "plan-task-5", "plan-task-9", "plan-task-14"])
    let t9 = lane.nodes.first { $0.id == "plan-task-9" }!
    XCTAssertEqual(t9.kind, .task)
    XCTAssertEqual(t9.status, .running)      // current
    XCTAssertEqual(t9.group, "Phase 2")
    XCTAssertEqual(lane.nodes.first { $0.id == "plan-task-5" }?.status, .done)  // all checked
    XCTAssertEqual(lane.nodes.first { $0.id == "plan-task-14" }?.status, .queued)
    XCTAssertTrue(lane.nodes.contains { $0.id == "drain" })
}
```
(Also confirm an `input` with empty `tasks` still yields the phase skeleton — add/keep a `testEmptyTasksKeepsPhaseSkeleton` mirroring an existing phase-skeleton assertion.)

- [ ] **Step 3: Run to verify it fails** — `swift test --filter PlanFlowBuilderTests` → FAIL.

- [ ] **Step 4: Implement** — in `PlanFlowBuilder.lanes(from:)`, read the current node-building block; when `!input.tasks.isEmpty`, build task nodes instead of phase nodes:
```swift
// after the "src" node, when input has tasks:
for t in input.tasks {
    nodes.append(FlowNode(id: "plan-task-\(t.line)", kind: .task, label: t.title,
                          status: taskStatus(t), group: t.phase))
}
// then the existing gate (when needsHuman) + drain, unchanged.
```
with:
```swift
private static func taskStatus(_ t: PlanTaskSummary) -> FlowStatus {
    if t.totalSteps > 0 && t.checkedSteps == t.totalSteps { return .done }
    return t.isCurrent ? .running : .queued
}
```
Keep the `.sequence` edge-zip and the `"src"`/`"gate"`/`"drain"` ids exactly as today. When `input.tasks` is empty, take the existing phase-skeleton path unchanged.

- [ ] **Step 5: Run to verify it passes + build** — `swift test --filter PlanFlowBuilderTests` → PASS. `swift build`.

- [ ] **Step 6: Commit**
```bash
git add Sources/Dreamux/Models/FlowGraph.swift Sources/Dreamux/Models/PlanFlowBuilder.swift Tests/DreamuxTests/PlanFlowBuilderTests.swift
git commit -m "Run DAG: FlowNode.group + PlanFlowBuilder task-DAG mode"
```

---

### Task 3: `RunLaneGraft` — attach live subagents

**Files:** Create `Sources/Dreamux/Models/RunLaneGraft.swift`, `Tests/DreamuxTests/RunLaneGraftTests.swift`.

**Interfaces:**
- Consumes: `Flow`, `FlowNode`/`FlowEdge`, `LiveSubagent` (slice 1: `{ id, name, activity, status, taskLine }`).
- Produces: `RunLaneGraft.graft(_ lane: Flow, subagents: [LiveSubagent], currentTaskLine: Int?) -> Flow`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/RunLaneGraftTests.swift
import XCTest
@testable import Dreamux

final class RunLaneGraftTests: XCTestCase {
    private func lane(taskLines: [Int]) -> Flow {
        var f = Flow(id: "plan-x", title: "X", kind: .plan)
        f.nodes = [FlowNode(id: "src", kind: .source, label: "plan", status: .done)]
            + taskLines.map { FlowNode(id: "plan-task-\($0)", kind: .task, label: "t", status: .queued) }
            + [FlowNode(id: "drain", kind: .drain, label: "merge", status: .queued)]
        return f
    }
    private func sub(_ id: String, taskLine: Int?) -> LiveSubagent {
        LiveSubagent(id: id, name: "code-reviewer", activity: nil, status: .running, taskLine: taskLine)
    }
    func testPinnedSubagentAddsNodeAndSpawnEdge() {
        let g = RunLaneGraft.graft(lane(taskLines: [5, 9]), subagents: [sub("agent-1", taskLine: 9)], currentTaskLine: 5)
        XCTAssertTrue(g.nodes.contains { $0.id == "agent-1" && $0.kind == .agent })
        XCTAssertTrue(g.edges.contains(FlowEdge(from: "plan-task-9", to: "agent-1", kind: .spawn)))
    }
    func testUnpinnedAttachesToCurrent() {
        let g = RunLaneGraft.graft(lane(taskLines: [5, 9]), subagents: [sub("agent-1", taskLine: nil)], currentTaskLine: 5)
        XCTAssertTrue(g.edges.contains(FlowEdge(from: "plan-task-5", to: "agent-1", kind: .spawn)))
    }
    func testUnpinnedNoCurrentSkipped() {
        let g = RunLaneGraft.graft(lane(taskLines: [5]), subagents: [sub("agent-1", taskLine: nil)], currentTaskLine: nil)
        XCTAssertFalse(g.nodes.contains { $0.id == "agent-1" })
    }
    func testTargetAbsentSkipped() {
        let g = RunLaneGraft.graft(lane(taskLines: [5]), subagents: [sub("agent-1", taskLine: 99)], currentTaskLine: 5)
        XCTAssertFalse(g.nodes.contains { $0.id == "agent-1" })
    }
    func testDuplicateAgentIdSkipped() {
        var l = lane(taskLines: [5]); l.nodes.append(FlowNode(id: "agent-1", kind: .agent, label: "x", status: .running))
        let g = RunLaneGraft.graft(l, subagents: [sub("agent-1", taskLine: 5)], currentTaskLine: 5)
        XCTAssertEqual(g.nodes.filter { $0.id == "agent-1" }.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --filter RunLaneGraftTests` → FAIL.

- [ ] **Step 3: Implement**

```swift
// Sources/Dreamux/Models/RunLaneGraft.swift
import Foundation

/// Grafts live subagents onto a task-DAG plan lane: each subagent becomes an
/// `.agent` node with a `.spawn` edge from its pinned task node
/// ("plan-task-<line>"), or from the current task when unpinned. Skips a
/// subagent whose target task isn't in the lane, or a duplicate id. Pure.
enum RunLaneGraft {
    static func graft(_ lane: Flow, subagents: [LiveSubagent], currentTaskLine: Int?) -> Flow {
        var lane = lane
        for sub in subagents {
            guard let targetLine = sub.taskLine ?? currentTaskLine else { continue }
            let target = "plan-task-\(targetLine)"
            guard lane.nodes.contains(where: { $0.id == target }) else { continue }
            guard !lane.nodes.contains(where: { $0.id == sub.id }) else { continue }
            lane.nodes.append(FlowNode(id: sub.id, kind: .agent, label: sub.name, status: sub.status))
            lane.edges.append(FlowEdge(from: target, to: sub.id, kind: .spawn))
        }
        return lane
    }
}
```

- [ ] **Step 4: Run to verify they pass + build** — `swift test --filter RunLaneGraftTests` → PASS (5). `swift build`.

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Models/RunLaneGraft.swift Tests/DreamuxTests/RunLaneGraftTests.swift
git commit -m "Run DAG: RunLaneGraft — attach live subagents to task nodes"
```

---

### Task 4: Wire the graft (ContentView → FlowsOverviewView)

View/integration task — `swift build` + inspection.

**Files:** Modify `Sources/Dreamux/Views/ContentView.swift`, `Sources/Dreamux/Views/FlowsOverviewView.swift`.

**Interfaces:** Consumes `OverviewLiveAgents.subagents(in:workspaceID:tasks:)`, `RunLaneGraft.graft`, `PlanFlowBuilder.lanes`. Produces a `graftSubagents: (Flow) -> Flow` passed to `FlowsOverviewView`.

- [ ] **Step 1: Compute per-lane subagents in `ContentView`**

`ContentView` has `docStore.plans` and `session.flows`. Build a closure that, given a plan lane's `Flow`, returns it with subagents grafted:
```swift
// A graft closure keyed by lane id ("plan-<planPath>"). For each plan with a
// live workspace, pull its subagents (slice 1) and the current task line.
let graftSubagents: (Flow) -> Flow = { lane in
    guard let plan = docStore.plans.first(where: { "plan-\(docStore.relativePath(of: $0))" == lane.id }),
          let ws = lane.workspaceID else { return lane }
    let subs = OverviewLiveAgents.subagents(in: session.flows.flows, workspaceID: ws, tasks: plan.tasks)
    let current = plan.tasks.first { $0.steps.contains { !$0.checked } }?.line
    return RunLaneGraft.graft(lane, subagents: subs, currentTaskLine: current)
}
```
Pass `graftSubagents:` into `FlowsOverviewView(...)`. (Match the exact `docStore`/`session` symbols already used at that call site — the `projectGraph` closure from slice 3A is the template.)

- [ ] **Step 2: Apply the graft in `FlowsOverviewView` before compose**

`FlowsOverviewView` gains `let graftSubagents: (Flow) -> Flow`. Where it builds plan lanes for `FlowsBoard.compose`, map them through the graft first:
```swift
let planLanes = PlanFlowBuilder.lanes(from: planLaneInputs()).map(graftSubagents)
let board = FlowsBoard.compose(planLanes: planLanes, sessionLanes: flows.flows)
```
(Find the exact current `FlowsBoard.compose(...)` call and insert the `.map(graftSubagents)` on the plan-lanes argument.) `compose` then suppresses the session lane as today, so subagents show grafted on the plan lane, not double.

- [ ] **Step 3: Build + manually verify** — `swift build` → clean. Run the app (outside a subagent): zoom into a running plan's lane on Flows → task nodes, and live subagents branch off the task they're on; a ready plan shows tasks with no subagents.

- [ ] **Step 4: Commit**
```bash
git add Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/FlowsOverviewView.swift
git commit -m "Run DAG: graft live subagents onto plan lanes before compose"
```

---

### Task 5: `FlowDetailView` — phase bands

View task — `swift build` + inspection.

**Files:** Modify `Sources/Dreamux/Views/FlowDetailView.swift`.

**Interfaces:** Consumes `FlowNode.group` (Task 2) + the laid-out `FlowLayout.positions`.

- [ ] **Step 1: Draw phase bands behind grouped task nodes**

In `FlowDetailView`, before the node `ForEach` (so bands sit under nodes), compute a band per maximal run of nodes sharing a non-nil `group`: for each group, the union of its nodes' laid-out rects (`positions[id]` ± half `nodeSize`), padded; draw a faint `RoundedRectangle` (`Color.primary.opacity(0.03)`) with a small uppercase phase label at the top-left. Skip `group == nil` nodes (src/gate/drain/agents). Keep it purely decorative — no hit testing, no effect on layout.

- [ ] **Step 2: (Optional) hide the transcript button when no `"session"` node** — in `nodeInspector`, the button is already `disabled(!isSessionNode || …)`; leave as-is (it correctly stays disabled for a task-DAG lane). No change required; note it.

- [ ] **Step 3: Build + manually verify** — `swift build` → clean. Zoom into a phased plan → faint bands group tasks under their phase name; the task chain + grafted subagents read clearly.

- [ ] **Step 4: Commit**
```bash
git add Sources/Dreamux/Views/FlowDetailView.swift
git commit -m "Run DAG: phase bands behind grouped task nodes"
```

---

## Self-Review

- **Spec coverage:** `FlowNode.group` (T2), `PlanTaskSummary` + assembler projection (T1), task-DAG builder (T2), `RunLaneGraft` (T3), the graft wiring before compose (T4), phase bands (T5). All spec components map to a task.
- **Type consistency:** `PlanTaskSummary.summaries(from:)`, `PlanLaneInput.tasks`, node ids `plan-task-<line>`, `RunLaneGraft.graft(_:subagents:currentTaskLine:)`, `FlowNode.group`, `taskStatus` mapping — used identically across tasks. The graft's `plan-task-<line>` ids (T3) match the builder's (T2) and the wiring's `currentTaskLine` derivation (T4).
- **No placeholders:** pure tasks (T1–T3) carry full code + commands; view tasks (T4–T5) give concrete structure + the two "match the symbol in scope" spots, with build/inspect checks.
