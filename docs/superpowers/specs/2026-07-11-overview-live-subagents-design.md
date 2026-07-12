# Overview Live Subagents — Design

**Slice 1 of the "everything is a graph" roadmap** (1 subagents → 2 sidebar
legibility → 3 Flows-as-graph; slice 4 "auto-disposition" dropped as
already-handled: the planning agent decides the disposition at authoring
time, `CourseCorrection` already appends tasks to an existing plan, and the
queue already enacts a declared `**Runs:**` header).

## Goal

Surface the subagents a run is spawning, where you already look: a live
**"Working now"** strip on a plan-backed workspace's Overview, and a
best-effort **agent label** on the checklist task a subagent is handling.

## Why this is small

The app *already observes* subagents. `FlowStore` builds an `.agent`
`FlowNode` per spawned subagent from Claude's `agentStarted`/`agentStopped`
hook events (see `FlowStore.apply(event:)`), carrying the agent type and a
live `lastActivity` line. This slice is **read-only presentation** of data
that already flows — no new feeds, no orchestration, no scheduler.

## Architecture

Two pure mappers turn the observed graph into view data, one reactive read
wires `FlowStore` into the Overview, and two small view additions render it.
Nothing writes; nothing new is polled.

```
FlowStore.flows ──(filter workspaceID)──> OverviewLiveAgents.subagents(…)
                                              │  (+ SubagentTaskPin.line)
                                              ▼
                                        [LiveSubagent]
                                          │        │
                              Working-now strip   per-task badge
                              (pills, Mode A)     (checklist row)
                                   │
                       onOpenRunFlow(workspaceID) ─> resolve plan lane
                                                     sidebarMode=.flows
                                                     flowsZoomLaneID=lane.id
```

## Tech Stack

SwiftUI, existing `FlowStore`/`FlowGraph` model, existing `PlanDoc`/`PlanTask`
model, existing `OverviewPrimitives`. No new dependencies.

## Global Constraints

- **Shared status vocabulary.** A subagent's running/waiting state uses the
  existing `FlowStatusGlyph` colors (`FlowLaneView.swift`) — never new tint
  rules. Running = orange; waiting = orange. (These are the only two states a
  live subagent can be in here.)
- **House style** (CLAUDE.md): generous type/spacing; hover wash
  `Color.primary.opacity(0.04)`; `RoundedRectangle(cornerRadius:, style:
  .continuous)`; pills read as a set with the existing `OverviewStatusPill`.
- **Reduce-motion aware.** The "working" pulse honors
  `@Environment(\.accessibilityReduceMotion)`, exactly as `OverviewStatusPill`
  already does.
- **Store-free view where possible.** `WorkspaceOverviewView` reads one new
  `@ObservedObject` (`FlowStore`) directly and takes one new closure
  (`onOpenFlowLane`) in its dependencies bundle; it does not gain a reference
  to `WorkspaceStore` or navigation state (matches every other action there).
- **Best-effort pin, never a wrong pin.** The checklist badge appears only
  when a subagent's text names a task unambiguously; otherwise the subagent
  shows in the strip only.

## Scope

- **In:** Mode A (plan-backed) Overview only — the strip and the per-task
  badge both live where the checklist is.
- **Out (explicit non-goals / follow-ons):**
  - Mode B (`main`/scratch) working-now strip — trivial follow-on once the
    strip view exists; deferred to keep this slice tight.
  - Any *orchestration* of subagents (spawning, worktree-per-task,
    scheduling). This slice only *observes*.
  - Node-level selection inside the Flows detail on click — v1 zooms to the
    lane; highlighting the specific node is a later nicety.

## Data source

For the Overview's workspace, the live subagents are the `.agent` nodes of
its `FlowStore` lanes:

- A lane belongs to the workspace when `Flow.workspaceID == workspace.id`.
- A subagent node has `id` prefixed `"agent-"` — **excluding** the main
  session node (`id == "session"`, label `"claude"`) and the fan-out
  collapse node (`id == FlowStore.collapsedAgentNodeID`, label `"agents"`).
- "Working now" = node `status` is `.running` or `.waiting`. `.queued`
  (not started), `.done`, and `.failed` are excluded.
- A node's `label` is the agent **name** (its type, e.g. `code-reviewer`);
  its `lastActivity` is the **what-it's-on** text.

## Components

### 1. `LiveSubagent` (new model)

`Sources/Dreamux/Models/LiveSubagent.swift`

```swift
struct LiveSubagent: Identifiable, Equatable {
    let id: String          // the FlowNode id, e.g. "agent-abc123"
    let name: String        // node.label (agent type)
    let activity: String?   // node.lastActivity ("what it's on"), may be nil
    let status: FlowStatus  // .running or .waiting only
    let taskLine: Int?      // best-effort pin to a PlanTask.line, else nil
}
```

> **No `laneID`.** A subagent lives on the *session* lane, but the Flows
> board **suppresses** that session lane under the workspace's **plan lane**
> (`FlowsBoard.compose` — the plan lane is the user's mental model; the
> session is its engine). A pill therefore navigates to the workspace's plan
> lane, resolved by `workspaceID` at the call site (see Component 7), not to
> the subagent's own (unrenderable-in-board) session lane. Once slice 3 draws
> subagent sub-nodes on the plan lane, the same click lands on the node.

### 2. `OverviewLiveAgents` (new, pure projection)

`Sources/Dreamux/Models/OverviewLiveAgents.swift`

```swift
enum OverviewLiveAgents {
    /// Live subagents for a workspace, across all its lanes, each
    /// best-effort pinned to a plan task. Excludes the main "session"
    /// node and the collapsed "agents" node; keeps only running/waiting.
    /// Sorted by startedAt (oldest first) for a stable left-to-right order.
    static func subagents(
        in flows: [Flow],
        workspaceID: UUID,
        tasks: [PlanTask]
    ) -> [LiveSubagent]
}
```

- Iterate lanes with `workspaceID`, then their nodes; keep `kind == .agent`,
  `id != "session"`, `id != FlowStore.collapsedAgentNodeID`, and
  `status ∈ {.running, .waiting}`.
- `taskLine = SubagentTaskPin.line(forAgentText: <name + " " + (activity ?? "")>, tasks:)`.
- Stable order by `startedAt` (nil sorts last), then `id` as a tiebreak so
  the pill row never reshuffles between renders.

### 3. `SubagentTaskPin` (new, pure best-effort matcher)

`Sources/Dreamux/Models/SubagentTaskPin.swift`

```swift
enum SubagentTaskPin {
    /// The line of the plan task a subagent's text refers to, or nil.
    /// Conservative: matches ONLY an explicit `Task <n>` / `Task <n.m>`
    /// token in the text against the task whose title parses to that same
    /// number. No token, no number match, or two tasks with that number →
    /// nil (never guess a row).
    static func line(forAgentText text: String, tasks: [PlanTask]) -> Int?
}
```

- Extract the first `Task\s+\d+(\.\d+)*` token from `text` (case-insensitive).
- Parse each task title's own `Task N[.M]` number (reuse the same grammar as
  `PlanDoc`/`CourseCorrection`).
- Return the line of the unique task whose parsed number equals the token's;
  nil if zero or multiple match.

### 4. `LiveSubagentPill` (new view)

`Sources/Dreamux/Views/OverviewPrimitives.swift` (append — it already houses
`OverviewStatusPill`, so the pills read as one family).

```swift
struct LiveSubagentPill: View {
    let subagent: LiveSubagent
    let onOpen: () -> Void
}
```

- An outlined capsule: a small **pulsing dot** in the status color
  (`FlowStatusGlyph.color(subagent.status)`, pulse gated on reduce-motion),
  the **name** (13pt medium), then, when present, `·` + a truncated
  **secondary** activity line (prefer the pinned task's clean title when
  `taskLine != nil`, else `activity`).
- Whole pill is a `.plain` button → `onOpen()`. Hover wash per house style.

### 5. Working-now strip in `WorkspaceOverviewView.modeA`

Between the hero card and the `OverviewSectionLabel("Tasks")`:

```swift
if !liveSubagents.isEmpty {
    OverviewSectionLabel(title: "Working now")
    <wrapping row> of LiveSubagentPill(subagent: sub) { onOpenRunFlow(session.workspace.id) }
}
```

- `liveSubagents = OverviewLiveAgents.subagents(in: flows.flows, workspaceID:
  session.workspace.id, tasks: plan.tasks)` — computed once in `modeA` and
  passed into `checklist`/`taskRow` (so rows don't recompute it).
- **Hidden entirely when empty** — no dead "Working now" header on runs that
  spawn nothing.
- Every pill navigates to the **same target** (this run's plan lane); the
  subagent-specific node isn't drawn there until slice 3, so a per-pill
  target would be indistinguishable now.
- **Layout:** prefer a wrapping row. If the codebase has no reusable wrap
  helper, a `ScrollView(.horizontal, showsIndicators: false)` of pills in an
  `HStack` is an acceptable v1 — live subagents are few (done ones are
  collapsed upstream), so horizontal scroll rarely engages. No artificial cap.

### 6. Per-task badge in `WorkspaceOverviewView.taskRow`

- Build `let pinned = liveSubagents.first { $0.taskLine == task.line }` (pass
  the computed `liveSubagents` down into the checklist so it isn't recomputed
  per row).
- When `pinned != nil`, render a compact agent chip on the row — placed just
  before the `checked/total` count, styled like `currentTag()` but in the
  subagent's status color, showing the agent name (e.g. `◉ code-reviewer`).
- The chip is presentational (the row's tap still toggles expansion); the
  strip's pill is the clickable route to the Flows lane.

### 7. Wiring

- **`WorkspaceOverviewView`**: add `@ObservedObject var flows: FlowStore`.
  Add `let onOpenRunFlow: (UUID) -> Void` to `WorkspaceOverviewDependencies`
  (and the view's matching stored property), threaded the same way the other
  dependencies are.
- **`ContentView`**: pass `session.flows`; construct `onOpenRunFlow` to
  resolve the workspace's **plan lane** from the store and zoom to it —
  robust against the board-suppression wrinkle and free of id-string coupling:

  ```swift
  onOpenRunFlow = { ws in
      let lane = session.flows.flows.first { $0.workspaceID == ws && $0.kind == .plan }
          ?? session.flows.flows.first { $0.workspaceID == ws }   // Mode B fallback
      if let lane { sidebarMode = .flows; flowsZoomLaneID = lane.id }
  }
  ```

  (`sidebarMode` and `flowsZoomLaneID` are existing `@State`; this mirrors the
  existing e2e `zoomFlow` path at `ContentView.swift:1118`.) Thread the closure
  through `WorkspaceTerminalContainer` → `WorkspaceBonsplitPane` →
  `TabContentView` like the rest of the bundle.

## Data flow

`agentStarted` hook → `FlowStore.apply(event:)` appends an `.agent` node →
`@Published flows` fires → `WorkspaceOverviewView` (observing `flows`)
recomputes `OverviewLiveAgents.subagents(…)` → strip + badges re-render.
`agentStopped` flips the node to `.done` → it drops out of the running/waiting
filter → its pill and badge disappear. No timers; the existing feeds drive it.

## States & edge cases

| Condition | Behavior |
|---|---|
| Workspace has no lane, or no running/waiting `.agent` nodes | Strip hidden; no badges |
| Subagent has no `lastActivity` and no pin | Pill shows name only |
| Subagent pinned to a task | Pill shows `name · <task title>`; that task row shows the chip |
| Subagent text names no task (or ambiguous) | Pill shown in strip; **no** badge |
| >1 subagent pinned to the same task | Badge shows the first (stable order); all still appear in the strip |
| Reduce motion on | Dot is solid (no pulse) |
| Main session (`"claude"`) / collapsed `"agents"` node | Never shown as a subagent |

## Testing

Pure logic gets unit tests; the wiring is exercised by a small view-model-level
test where practical.

- **`SubagentTaskPinTests`**
  - `"Implementing Task 3: the classifier"` + tasks incl. title `Task 3: …` → that task's line.
  - Dotted: `"Task 0.2"` → task titled `Task 0.2: …`.
  - No `Task N` token → nil. Number with no matching title → nil. Two tasks
    numbered 3 → nil (no guess).
  - Case-insensitive (`"task 3"`).
- **`OverviewLiveAgentsTests`**
  - Excludes the `"session"` node and the collapsed `"agents"` node.
  - Keeps only `.running`/`.waiting`; drops `.queued`/`.done`/`.failed`.
  - Aggregates across two lanes with the same `workspaceID`; ignores other
    workspaces' lanes.
  - Applies the pin (a node whose text names `Task 3` gets that task's line).
  - Stable order by `startedAt` then `id`.

## Files

- Create: `Sources/Dreamux/Models/LiveSubagent.swift`
- Create: `Sources/Dreamux/Models/OverviewLiveAgents.swift`
- Create: `Sources/Dreamux/Models/SubagentTaskPin.swift`
- Create: `Tests/DreamuxTests/SubagentTaskPinTests.swift`
- Create: `Tests/DreamuxTests/OverviewLiveAgentsTests.swift`
- Modify: `Sources/Dreamux/Views/OverviewPrimitives.swift` (add `LiveSubagentPill`)
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` (strip + badge + `flows`/`onOpenFlowLane`)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (+ the container hops) — pass `session.flows` + `onOpenRunFlow`
