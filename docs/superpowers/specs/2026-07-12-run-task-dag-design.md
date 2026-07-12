# Run Task DAG — Design (slice 3B)

**Slice 3B — the roadmap finale** (1 subagents ✓ → 2 sidebar ✓ → 3A project graph ✓ → **3B run task DAG**). Zooming into a plan's Flows lane shows its **tasks as a DAG** (phases as bands) with the **live subagents from slice 1 grafted onto the task each is working**.

## Goal

Replace the plan lane's fixed `src → phases → gate → drain` skeleton with `src → tasks → gate → drain` — task nodes from `PlanDoc.tasks`, status from checkboxes, phases as visual bands — and graft each live subagent onto its pinned task node. Wires the last dead piece (`FlowNodeKind.task` for plan tasks) and connects slice 1's `.agent` nodes into the graph.

## Design decisions (settled in brainstorming)

- **Tasks are the nodes; phases are bands** (not a second node level).
- **Subagents render as nodes branching off their task** (spawn edge), not badges — so task-level work is visible.
- **Observation, not orchestration:** subagents attach to whatever task `SubagentTaskPin` maps them to (usually the current one). The DAG *supports* task-parallelism but 3B never manufactures it.

## Scope

- **In:** task-DAG plan lane (task nodes + phase bands + checkbox status), subagent graft, `FlowDetailView` band rendering.
- **Out (deferred):** app-driven task parallelism / worktree-per-task (a separate future slice); opening a *specific* subagent's transcript (today only the lane-level session transcript exists — the task-DAG lane's transcript button stays disabled, a harmless degrade); rendering a session lane's TodoWrite `.task` nodes (distinct concept).

## Current state (grounded)

- **`PlanFlowBuilder.lanes(from: [PlanLaneInput]) -> [Flow]`** builds `"src"(.source) → "phase-0..N"(.phase) → ["gate"(.gate)] → "drain"(.drain)`, all `.sequence`, lane id `"plan-<planPath>"`. `PlanPhaseSummary` is an **aggregate only** (title/checked/total — no task data).
- **`PlanLaneAssembler.inputs(docStore:queue:store:) -> [PlanLaneInput]`** maps `docStore.plans` — the full `PlanDoc` (`.tasks`) is in scope; it currently reduces to `PlanPhaseSummary` via `PlanPhases.groups`.
- **`FlowsBoard.compose(planLanes:sessionLanes:)`** picks an "engine" session `Flow` per workspace (`engineByWorkspace[ws]` — the full session Flow, `.agent` nodes included) and copies only its `.detail`/`.status` onto the plan lane (lines 107–121), **discarding `live.nodes`/`live.edges`**.
- **`OverviewLiveAgents.subagents(in: [Flow], workspaceID:, tasks: [PlanTask]) -> [LiveSubagent]`** (slice 1): filters `FlowStore.flows` by workspace, keeps live `.agent` nodes, pins each to a `PlanTask.line` via `SubagentTaskPin`. `LiveSubagent { id, name, activity, status, taskLine }`.
- **`FlowDetailView`** renders `lane.flow.nodes/edges` generically via `FlowLayoutEngine`, with three id-literals: auto-selects id `"gate"`, reads id `"drain"` for elapsed time, gates the transcript button on id `"session"`.

## Components

### 1. `FlowNode.group` — phase-band grouping

`Sources/Dreamux/Models/FlowGraph.swift` — add `var group: String?` to `FlowNode` (default `nil`, so every existing constructor is unaffected; Codable-safe). A task node carries its `## Phase` name here; `FlowDetailView` draws a faint band behind consecutive same-`group` nodes.

### 2. `PlanTaskSummary` + `PlanLaneInput.tasks`

- `Sources/Dreamux/Models/PlanFlowBuilder.swift` — add:
```swift
struct PlanTaskSummary: Equatable {
    let line: Int            // PlanTask.line — the node id suffix + pin target
    let title: String        // clean title (strip a leading "Task N: ")
    let phase: String?       // node.group (band)
    let checkedSteps: Int
    let totalSteps: Int
    let isCurrent: Bool       // first task with an unchecked step
}
```
- `PlanLaneInput` gains `let tasks: [PlanTaskSummary]`.
- `PlanLaneAssembler` projects it from `plan.tasks` (already in scope): filter `!steps.isEmpty`, mark `isCurrent` = the first task with an unchecked step (the rule `PlanCurrentStep` uses privately — re-derive: `tasks.first { $0.steps.contains { !$0.checked } }`). Reuse `WorkspaceOverviewView.cleanTitle`-style stripping for the label (promote a small `PlanTaskTitle.clean(_:)` helper so it isn't duplicated).

### 3. `PlanFlowBuilder` — task-DAG mode

When `input.tasks` is non-empty, build task nodes instead of phase nodes:
`"src"(.source) → "plan-task-<line>"(.task, one per summary) → ["gate"] → "drain"`, all `.sequence`.
- Node: `FlowNode(id: "plan-task-\(t.line)", kind: .task, label: t.title, status: taskStatus(t), group: t.phase)`.
- `taskStatus(_ t:)`: `t.checkedSteps == t.totalSteps` → `.done`; else `t.isCurrent` → `.running`; else `.queued`. (Blocked/failed don't apply at task granularity here.)
- **Keep the `"src"`/`"gate"`/`"drain"` node ids** (so `FlowDetailView`'s literals still work). Gate presence unchanged (only when `needsHuman`).
- When `input.tasks` is empty, fall back to today's phase skeleton (unchanged) — a spec-only/task-less plan still lanes.

### 4. Subagent graft — reuse slice 1, add `RunLaneGraft`

- `Sources/Dreamux/Models/RunLaneGraft.swift` (new, pure):
```swift
enum RunLaneGraft {
    /// Graft live subagents onto a task-DAG plan lane: for each subagent,
    /// add an `.agent` node and a `.spawn` edge from its pinned task node
    /// ("plan-task-<taskLine>"), or from the current task node when unpinned.
    /// Skips a subagent whose target task node isn't in the lane.
    static func graft(_ lane: Flow, subagents: [LiveSubagent], currentTaskLine: Int?) -> Flow
}
```
Per subagent: `target = "plan-task-\(sub.taskLine ?? currentTaskLine)"`; if `lane.nodes` contains `target`, append `FlowNode(id: sub.id, kind: .agent, label: sub.name, status: sub.status)` and `FlowEdge(from: target, to: sub.id, kind: .spawn)`. (`sub.id` is already `"agent-<id>"` — distinct namespace from `plan-task-`.)
- **Wiring:** `ContentView` has `docStore.plans` + `session.flows`. It builds, per plan with a workspace, `OverviewLiveAgents.subagents(in: session.flows.flows, workspaceID: ws, tasks: plan.tasks)`, keyed by lane id (`"plan-<planPath>"`), and passes a `graftSubagents: (Flow) -> Flow` (or a `[laneID: [LiveSubagent]]` map) into `FlowsOverviewView`. `FlowsOverviewView` applies `RunLaneGraft.graft` to each plan lane **before** `FlowsBoard.compose` — so `compose` then suppresses the session lane (subagents show grafted on the plan lane, not double as a separate lane).
- `currentTaskLine` per lane = the `isCurrent` task's line (from the summaries), so unpinned subagents attach to the current task.

### 5. `FlowDetailView` — phase bands + id-compat

- Draw a **faint rounded band** behind each maximal run of task nodes sharing a `group` (using their laid-out positions), with a small uppercase phase label — cosmetic, under the nodes. Skip nodes with `group == nil`.
- **Id-literals:** the task-DAG lane keeps `"gate"`/`"drain"` (preserved by Component 3) so auto-select + elapsed keep working. It has **no `"session"` node**, so the transcript button stays disabled for its nodes — accept this (out of scope); optionally hide the button when `lane.flow.nodes` has no `"session"`.
- `.task`-kind node inspector: reuse the existing generic node inspector (label/status/activity); a `plan-task-` node shows its title/status.

## Data flow

`docStore.plans` → `PlanLaneAssembler` (task summaries) → `PlanFlowBuilder` (task-DAG lane) → `ContentView` grafts live subagents (`OverviewLiveAgents` + `RunLaneGraft`) → `FlowsBoard.compose` (suppresses session lane) → `FlowDetailView` (bands + nodes). All derived each render; reactive via `docStore` + `flows` (`FlowStore`) observation — the DAG updates as checkboxes tick and subagents start/stop.

## States & edge cases

| Condition | Behavior |
|---|---|
| Plan not running (ready) | Task DAG shows, statuses from checkboxes, **no subagent nodes** |
| Subagent pinned to a task | Agent node + spawn edge off `plan-task-<line>` |
| Subagent unpinned (`taskLine == nil`) | Attaches to the current task node; if none, skipped |
| Subagent whose target node absent | Skipped (no dangling edge) |
| Task-less / spec-only plan | Falls back to today's phase skeleton |
| Many subagents on one task | Reuse the existing >6 fan-out collapse if it bites (follow-up; not required v1) |
| Transcript button on a task-DAG lane | Disabled (no `"session"` node) — accepted |

## Testing

- **`PlanFlowBuilderTests`** (extend): with `input.tasks`, the lane is `src → plan-task-<line>… → drain` (+ gate when `needsHuman`), `.task` kind, `group == phase`, status mapping (all-checked→done, current→running, else queued), ids `plan-task-<line>`; empty `tasks` → old phase skeleton unchanged.
- **`RunLaneGraftTests`** (new): a pinned subagent adds an `.agent` node + `.spawn` from `plan-task-<line>`; unpinned → current task; target-absent → skipped; ids preserved.
- **`PlanTaskTitle` / summary projection** — a small unit test for the title-clean + `isCurrent` derivation.
- View layer (`FlowDetailView` bands, wiring) — `swift build` + inspection, as in prior slices.

## Files

- Modify: `Sources/Dreamux/Models/FlowGraph.swift` (`FlowNode.group`)
- Modify: `Sources/Dreamux/Models/PlanFlowBuilder.swift` (`PlanTaskSummary`, `PlanLaneInput.tasks`, task-DAG mode) + `Tests/DreamuxTests/PlanFlowBuilderTests.swift`
- Modify: `Sources/Dreamux/Models/PlanLaneAssembler.swift` (project task summaries); Create `Sources/Dreamux/Models/PlanTaskTitle.swift` (+ test) if promoting the title-clean helper
- Create: `Sources/Dreamux/Models/RunLaneGraft.swift` + `Tests/DreamuxTests/RunLaneGraftTests.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift` (compute per-lane live subagents, pass graft), `Sources/Dreamux/Views/FlowsOverviewView.swift` (apply graft before compose), `Sources/Dreamux/Views/FlowDetailView.swift` (phase bands)
