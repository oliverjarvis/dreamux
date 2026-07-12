# Project Graph — Design (slice 3A)

**Slice 3A of the graph roadmap** (1 subagents ✓ → 2 sidebar ✓ → **3A project graph** → 3B run task/subagent DAG). Builds the project plan-dependency graph — plans as nodes, `Runs: after` as dependency edges — and renders it twice: a **Flows project panel** and the **sidebar mini-map** deferred from slice 2.

## Goal

One pure `ProjectGraph` model (plans → nodes, `runsAfter` → `.dependency` edges), laid out by the existing `FlowLayoutEngine`, rendered full on the Flows page and compact in the Workspaces rail. Clicking a plan node zooms to that plan's lane on Flows.

## Design decisions (settled in brainstorming)

- **Nodes = plans, edges = `Runs: after`.** Parallel plans have no incoming edge (style C — no marker, consistent with the rail).
- **Merged blockers shown as done (faded).** A merged plan appears as a node **only when it's the resolved blocker of a shown non-merged plan**, so the graph tells the live chain's story without accumulating every done plan.
- **Blocked-ness is derived, not stored:** a node is blocked iff it has an incoming `.dependency` edge whose source node is not `.done`. (No new field — the graph structure carries it.)
- **One model, two renders:** full pills+arrows on Flows; dots+lines in the ~260px mini-map. Shared `ProjectGraph` + `FlowLayoutEngine`.
- **Scope:** the *between-plan* dependency graph only. Drilling a node into its *tasks + live subagents* (the within-plan DAG) is slice 3B.

## Architecture

```
DocStore.plans ──> ProjectGraphBuilder.build(…) ──> ProjectGraph {nodes:[FlowNode], edges:[FlowEdge]}
   (+ runsAfter,                                          │
    status)                                    FlowLayoutEngine.layout(nodes,edges, nodeSize,…)
                                                          │
                                          ┌───────────────┴────────────────┐
                                   ProjectGraphView(compact:false)   ProjectGraphView(compact:true)
                                   Flows project panel                sidebar mini-map
                                   (FlowsOverviewView)                (PlansSpecsSection)
                                          │                                 │
                                click node → zoom lane            click → open Flows panel
```

## Global Constraints

- **Reuse the model, don't fork it.** Nodes are `FlowNode` (new kind `.plan`), edges are `FlowEdge(kind: .dependency)` — so `FlowLayoutEngine` and `FlowStatusGlyph` apply unchanged. `FlowEdgeKind.dependency` is currently defined-but-unused; this is its first constructor.
- **Node id = `"plan-<relativePath>"`** — identical to `PlanFlowBuilder`'s lane id, so a node click can `flowsZoomLaneID = node.id` and land on that plan's lane.
- **Shared status vocabulary** — colors via `FlowStatusGlyph.color`; status via the promoted `PlanStatus.flowStatus`.
- **House style** (CLAUDE.md); reduce-motion honored anywhere animated.
- **Layout engine stays backward-compatible** — new params are optional with defaults equal to today's constants, so existing callers (`FlowDetailView`) are unaffected.

## Components

### 1. `PlanStatus.flowStatus` (promote the mapping)

`Sources/Dreamux/Models/PlanStatus.swift` — add a computed property (the exact switch currently private in `WorkspaceOverviewView.flowStatus`):

```swift
extension PlanStatus {
    /// The shared status vocabulary this plan maps to (glyph/color via
    /// `FlowStatusGlyph`). running→running, awaitingReview→waiting,
    /// merged→done, inProgress/ready/specOnly→queued.
    var flowStatus: FlowStatus {
        switch self {
        case .running: return .running
        case .awaitingReview: return .waiting
        case .merged: return .done
        case .inProgress, .ready, .specOnly: return .queued
        }
    }
}
```
Then replace `WorkspaceOverviewView.flowStatus(for:)`'s body with `status.flowStatus` (or delete it and call `status.flowStatus` at its use sites) — one source of truth.

### 2. `FlowNodeKind.plan` + `ProjectGraph` model (pure) + builder

- `Sources/Dreamux/Models/FlowGraph.swift`: add `plan` to `FlowNodeKind` (`case source, phase, agent, step, task, gate, drain, plan`). Additive — Codable/exhaustive-switch safe (audit switches over `FlowNodeKind`; the node views map unknown/`.plan` to a default pill).
- `Sources/Dreamux/Models/ProjectGraph.swift` (new):

```swift
struct ProjectGraph: Equatable {
    let nodes: [FlowNode]   // id "plan-<path>", kind .plan, label = title, status mapped
    let edges: [FlowEdge]   // kind .dependency, from blocker id → to waiter id

    /// Node ids that are waiting: an incoming `.dependency` edge whose
    /// source node isn't `.done`. Derived, so the renderer can dash them.
    var blockedIDs: Set<String> {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return Set(edges.compactMap { edge in
            byID[edge.from]?.status != .done ? edge.to : nil
        })
    }
}

enum ProjectGraphBuilder {
    /// Build the project graph. Included nodes = every non-merged plan, plus
    /// any merged plan that is the resolved blocker of an included plan (so a
    /// live chain shows its done predecessor). One `.dependency` edge per
    /// resolved `runsAfter` between two included plans.
    static func build(
        plans: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> ProjectGraph
}
```

Builder logic:
1. `status = statusOf(plan)` for each plan; `nonMerged = plans.filter { status != .merged }`.
2. For each `nonMerged` plan with a `runsAfter`, resolve the blocker; collect `(blocker, waiter)` pairs where the blocker is a known plan and not the waiter itself.
3. `included = nonMerged ∪ {blockers from step 2 that are merged}` (a merged blocker is pulled in; a merged plan that blocks nothing stays out).
4. `nodes = included.map { FlowNode(id: "plan-\(relativePath($0))", kind: .plan, label: $0.title, status: statusOf($0).flowStatus) }`, stable-ordered (see below).
5. `edges = pairs.filter { both endpoints are included }.map { FlowEdge(from: "plan-\(blocker)", to: "plan-\(waiter)", kind: .dependency) }`.
6. **Order** nodes deterministically (by `startedAt` when present, else title) so layout is stable between renders.

### 3. Parameterize `FlowLayoutEngine`

`Sources/Dreamux/Models/FlowLayoutEngine.swift` — add optional params to `layout`, defaulting to today's constants (so `FlowDetailView` is untouched):

```swift
static func layout(
    nodes: [FlowNode], edges: [FlowEdge],
    nodeSize: CGSize = Self.nodeSize,     // 150×44
    rankGap: CGFloat = Self.rankGap,      // 48
    siblingGap: CGFloat = Self.siblingGap,// 30
    margin: CGFloat = Self.margin         // 24
) -> FlowLayout
```
Use the params where the constants are currently read. The mini-map calls it with a small `nodeSize` (e.g. `CGSize(width: 16, height: 16)`) and tight gaps so dots pack closely; the Flows panel uses the defaults.

### 4. Extract `FlowEdgeGeometry` (shared edge drawing)

`Sources/Dreamux/Models/FlowEdgeGeometry.swift` (new) — move `FlowDetailView`'s private `smoothedPath(_:)` and `arrowheadPath(into:along:)` here as `static` funcs (pure geometry). `FlowDetailView` calls the shared versions (behavior unchanged); the Flows project panel uses them too, so both DAGs draw identical smoothed splines + arrowheads.

```swift
enum FlowEdgeGeometry {
    static func smoothedPath(_ pts: [CGPoint]) -> Path
    static func arrowheadPath(into target: CGPoint, along pts: [CGPoint]) -> Path?
}
```
(Self-loops stay in `FlowDetailView` — a project graph has none: a plan never `Runs: after` itself, guarded in the builder.)

### 5. `ProjectGraphView` + the Flows project panel

- `Sources/Dreamux/Views/ProjectGraphView.swift` (new):

```swift
struct ProjectGraphView: View {
    let graph: ProjectGraph
    let compact: Bool                 // false = Flows panel; true = mini-map
    let onSelectPlan: (String) -> Void  // node id ("plan-<path>")
}
```
- Computes `FlowLayoutEngine.layout(...)` (defaults when `!compact`; small nodeSize + tight gaps when `compact`).
- **Full (`compact == false`):** a `Canvas` draws each edge through `layout.edgePoints` via `FlowEdgeGeometry.smoothedPath` + `arrowheadPath` (straight `[from,to]` fallback when a waypoint list is absent), under a node `ForEach` of pills — `RoundedRectangle(cornerRadius: 9)` filled/outlined by `FlowStatusGlyph.color(node.status)`, **dashed border when `graph.blockedIDs.contains(node.id)`**, a status dot + the title, tappable → `onSelectPlan(node.id)`. Wrapped in an `overflow`-scrolling frame sized to `layout.size`.
- **Compact (`compact == true`):** same layout, but nodes render as small dots (`FlowStatusGlyph.color`, dashed ring when blocked) and edges as plain straight lines (no splines/arrowheads at thumbnail scale). Fixed height (~90pt); the whole view is one tap target when embedded (see Component 6).
- **`FlowsOverviewView`** (`Sources/Dreamux/Views/FlowsOverviewView.swift`): add a `projectGraph: () -> ProjectGraph` input; in `body`, when **not zoomed**, render a "This project" panel (`ProjectGraphView(graph:, compact: false)`) inside the `LazyVStack` between `headerRow` and the `ForEach(board.sections)`. `onSelectPlan = { id in zoomedLaneID = id }` (zooms to that plan's lane; a merged/laneless node no-ops).
- **`ContentView`**: build the graph and pass it — `projectGraph: { ProjectGraphBuilder.build(plans: docStore.plans, relativePath: docStore.relativePath, resolveBlocker: { docStore.plans.first { $0.fileURL.standardizedFileURL == docStore.resolvedURL(forReference: $0Ref) } }, statusOf: { docStore.status(for: $0, featureExists: featureExists) }) }` (resolver mirrors `PlanBlocking`'s call site in `PlansSpecsSection`).

### 6. Sidebar mini-map + navigation

- **`PlansSpecsSection`** already holds `docStore` + `featureExists` + `planStatuses()`. Build the graph once in `body` and render `ProjectGraphView(graph:, compact: true)` at the **foot of the section** (after `newWorkspaceRow`, inside the `plansExpanded` block), inside the existing mini-map container styling (title "Dependencies", "Open in Flows →"). Hidden when the graph has ≤1 node.
- **Navigation (new plumbing, mirrors `onOpenRunFlow`):** add `onOpenProjectGraph: () -> Void` threaded `ContentView → WorkspaceSidebar → PlansSpecsSection`. Tapping the mini-map calls it; `ContentView` sets `sidebarMode = .flows; flowsZoomLaneID = nil` (the project panel is the un-zoomed Flows overview). A node tap inside the compact view routes through `onSelectPlan` → `sidebarMode = .flows; flowsZoomLaneID = "plan-<path>"` (jump straight to that plan).

## Data flow

`docStore.plans` (+ `runsAfter`, status) → `ProjectGraphBuilder.build` (pure) → `ProjectGraph` → `FlowLayoutEngine.layout` → `ProjectGraphView` (×2). All derived each render; no persistence. The graph updates reactively because `docStore` is observed at both call sites.

## States & edge cases

| Condition | Behavior |
|---|---|
| ≤1 plan node | Mini-map hidden; Flows panel shows the single node or nothing |
| Plan with `runsAfter` to a **merged** blocker | Blocker pulled in as a `.done` node; waiter not blocked (source is done) |
| `runsAfter` unresolvable / self | No edge (builder drops it); plan renders unblocked |
| Node click with no matching lane (e.g. a merged node) | `zoomedLaneID` set but `lane(forID:)` finds nothing → the existing overview clears zoom (no crash) |
| Parallel plans | No incoming edge → solid/undashed, side by side |
| Reduce motion | No animated layout transitions |

## Testing

- **`ProjectGraphBuilderTests`** (pure): non-merged plans become nodes; a `runsAfter` yields a `.dependency` edge blocker→waiter; a **merged blocker is included** iff it blocks a shown plan (and excluded when it blocks nothing); unresolvable/self `runsAfter` → no edge; node ids are `plan-<path>`; `blockedIDs` marks a waiter behind a non-done blocker and NOT one behind a done blocker; deterministic order.
- **`FlowLayoutEngineTests`** (extend): passing a custom `nodeSize`/gaps changes positions/size; defaults reproduce the pre-change layout for an existing fixture.
- **`FlowEdgeGeometryTests`**: `smoothedPath`/`arrowheadPath` reproduce `FlowDetailView`'s prior output for a sample waypoint list (guards the extraction).
- View layer (`ProjectGraphView`, the panel, the mini-map, nav) — `swift build` + inspection, as in prior slices.

## Files

- Modify: `Sources/Dreamux/Models/PlanStatus.swift` (add `flowStatus`), `Sources/Dreamux/Views/WorkspaceOverviewView.swift` (use it)
- Modify: `Sources/Dreamux/Models/FlowGraph.swift` (add `.plan` kind)
- Create: `Sources/Dreamux/Models/ProjectGraph.swift`, `Tests/DreamuxTests/ProjectGraphBuilderTests.swift`
- Modify: `Sources/Dreamux/Models/FlowLayoutEngine.swift` (params) + `Tests/DreamuxTests/FlowLayoutEngineTests.swift`
- Create: `Sources/Dreamux/Models/FlowEdgeGeometry.swift`, `Tests/DreamuxTests/FlowEdgeGeometryTests.swift`; Modify `Sources/Dreamux/Views/FlowDetailView.swift` (call the shared geometry)
- Create: `Sources/Dreamux/Views/ProjectGraphView.swift`
- Modify: `Sources/Dreamux/Views/FlowsOverviewView.swift` (panel), `Sources/Dreamux/Views/ContentView.swift` (build + pass graph, nav), `Sources/Dreamux/Views/WorkspaceSidebar.swift` + `Sources/Dreamux/Views/PlansSpecsSection.swift` (mini-map + `onOpenProjectGraph`)
