# Project Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project plan-dependency graph (plans → nodes, `Runs: after` → dependency edges) rendered twice — a Flows project panel and the sidebar mini-map — from one `ProjectGraph` model laid out by the existing `FlowLayoutEngine`.

**Architecture:** Pure `ProjectGraphBuilder` produces `[FlowNode]`/`[FlowEdge]`; `FlowLayoutEngine` (parameterized) lays it out; one `ProjectGraphView` (a `compact` flag) renders it full on Flows and tight in the rail. Shared edge geometry is extracted from `FlowDetailView`.

**Tech Stack:** SwiftUI, existing `FlowGraph`/`FlowLayoutEngine`/`FlowStatusGlyph`/`PlanDoc`/`DocStore`, SwiftDagre (already vendored), XCTest.

**Spec:** docs/superpowers/specs/2026-07-12-project-graph-design.md — read it first.

## Global Constraints

- **Reuse, don't fork:** nodes are `FlowNode` (new kind `.plan`), edges are `FlowEdge(kind: .dependency)` — `FlowLayoutEngine`/`FlowStatusGlyph` apply unchanged. `.dependency` is defined-but-unused today; this is its first constructor.
- **Node id = `"plan-<relativePath>"`** (identical to `PlanFlowBuilder`'s lane id) so a node click → `flowsZoomLaneID = node.id` lands on that plan's lane.
- **Status via `PlanStatus.flowStatus`; colors via `FlowStatusGlyph.color`.**
- **Layout engine stays backward-compatible** — new params optional, defaults == today's constants; `FlowDetailView` unaffected.
- **Merged-blocker-as-done:** a merged plan is a node ONLY when it's the resolved blocker of a shown non-merged plan.
- **Blocked-ness is derived** (incoming `.dependency` from a non-`.done` source), never stored.
- **House style** (CLAUDE.md); reduce-motion honored anywhere animated.

## File Structure

- `Sources/Dreamux/Models/PlanStatus.swift` (modify) — `flowStatus`.
- `Sources/Dreamux/Models/FlowGraph.swift` (modify) — `.plan` kind.
- `Sources/Dreamux/Models/ProjectGraph.swift` (new) — model + builder.
- `Sources/Dreamux/Models/FlowLayoutEngine.swift` (modify) — params.
- `Sources/Dreamux/Models/FlowEdgeGeometry.swift` (new) — extracted geometry.
- `Sources/Dreamux/Views/FlowDetailView.swift` (modify) — call shared geometry.
- `Sources/Dreamux/Views/ProjectGraphView.swift` (new) — the renderer.
- `Sources/Dreamux/Views/FlowsOverviewView.swift`, `ContentView.swift`, `WorkspaceSidebar.swift`, `PlansSpecsSection.swift` (modify) — mounts + nav.
- Tests: `ProjectGraphBuilderTests`, `FlowEdgeGeometryTests` (new); `FlowLayoutEngineTests` (extend).

---

### Task 1: `PlanStatus.flowStatus` — promote the mapping

**Files:** Modify `Sources/Dreamux/Models/PlanStatus.swift`, `Sources/Dreamux/Views/WorkspaceOverviewView.swift`. Test: `Tests/DreamuxTests/PlanStatusFlowTests.swift`.

**Interfaces:** Produces `PlanStatus.flowStatus: FlowStatus`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/PlanStatusFlowTests.swift
import XCTest
@testable import Dreamux

final class PlanStatusFlowTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(PlanStatus.running.flowStatus, .running)
        XCTAssertEqual(PlanStatus.awaitingReview.flowStatus, .waiting)
        XCTAssertEqual(PlanStatus.merged.flowStatus, .done)
        XCTAssertEqual(PlanStatus.inProgress.flowStatus, .queued)
        XCTAssertEqual(PlanStatus.ready.flowStatus, .queued)
        XCTAssertEqual(PlanStatus.specOnly.flowStatus, .queued)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter PlanStatusFlowTests` → FAIL (no `flowStatus`).

- [ ] **Step 3: Implement** — append to `PlanStatus.swift`:

```swift
extension PlanStatus {
    /// The shared status vocabulary this plan maps to (glyph/color via
    /// `FlowStatusGlyph`).
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
Then in `WorkspaceOverviewView.swift`, replace the body of `private func flowStatus(for status: PlanStatus) -> FlowStatus` with `status.flowStatus` (keep the method as a thin forwarder so its call sites are untouched).

- [ ] **Step 4: Run to verify it passes** — `swift test --filter PlanStatusFlowTests` → PASS (1 test). Then `swift build` → clean.

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Models/PlanStatus.swift Sources/Dreamux/Views/WorkspaceOverviewView.swift Tests/DreamuxTests/PlanStatusFlowTests.swift
git commit -m "ProjectGraph: promote PlanStatus.flowStatus"
```

---

### Task 2: `FlowNodeKind.plan` + `ProjectGraph` + builder

**Files:** Modify `Sources/Dreamux/Models/FlowGraph.swift`. Create `Sources/Dreamux/Models/ProjectGraph.swift`, `Tests/DreamuxTests/ProjectGraphBuilderTests.swift`.

**Interfaces:**
- Consumes: `PlanDoc` (`runsAfter`, `title`, `fileURL`), `PlanStatus.flowStatus` (Task 1), `FlowNode`/`FlowEdge`/`FlowEdgeKind.dependency`.
- Produces: `struct ProjectGraph { nodes, edges, blockedIDs }` + `ProjectGraphBuilder.build(plans:relativePath:resolveBlocker:statusOf:) -> ProjectGraph`.

- [ ] **Step 1: Add the `.plan` node kind**

In `FlowGraph.swift`, change `enum FlowNodeKind` to add `plan`:
```swift
enum FlowNodeKind: String, Codable, Hashable, Sendable {
    case source, phase, agent, step, task, gate, drain, plan
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/DreamuxTests/ProjectGraphBuilderTests.swift
import XCTest
@testable import Dreamux

final class ProjectGraphBuilderTests: XCTestCase {
    private func plan(_ name: String, runsAfter: String? = nil) -> PlanDoc {
        PlanDoc(fileURL: URL(fileURLWithPath: "/p/\(name).md"), kind: .plan,
                title: name, date: nil, goal: nil, specReference: nil,
                runsAfter: runsAfter, declaresParallel: false,
                checkedSteps: 0, totalSteps: 1, tasks: [])
    }
    // resolveBlocker matches by the "<name>" token in a "after <name>" ref.
    private func build(_ plans: [PlanDoc], status: [String: PlanStatus]) -> ProjectGraph {
        ProjectGraphBuilder.build(
            plans: plans,
            relativePath: { $0.fileURL.deletingPathExtension().lastPathComponent },
            resolveBlocker: { ref in plans.first { $0.fileURL.deletingPathExtension().lastPathComponent == ref } },
            statusOf: { status[$0.title] ?? .ready })
    }

    func testNonMergedBecomeNodesWithPlanIds() {
        let g = build([plan("a"), plan("b")], status: ["a": .running, "b": .ready])
        XCTAssertEqual(Set(g.nodes.map(\.id)), ["plan-a", "plan-b"])
        XCTAssertTrue(g.nodes.allSatisfy { $0.kind == .plan })
        XCTAssertEqual(g.nodes.first { $0.id == "plan-a" }?.status, .running)
    }
    func testRunsAfterMakesDependencyEdge() {
        let g = build([plan("a"), plan("b", runsAfter: "a")], status: ["a": .running, "b": .ready])
        XCTAssertEqual(g.edges, [FlowEdge(from: "plan-a", to: "plan-b", kind: .dependency)])
        XCTAssertTrue(g.blockedIDs.contains("plan-b"))   // behind a non-done blocker
    }
    func testMergedBlockerIncludedAsDoneAndWaiterNotBlocked() {
        let g = build([plan("a"), plan("b", runsAfter: "a")], status: ["a": .merged, "b": .ready])
        XCTAssertTrue(g.nodes.contains { $0.id == "plan-a" && $0.status == .done })
        XCTAssertFalse(g.blockedIDs.contains("plan-b"))  // blocker done → not blocked
    }
    func testMergedPlanBlockingNothingIsExcluded() {
        let g = build([plan("a"), plan("b")], status: ["a": .merged, "b": .ready])
        XCTAssertEqual(g.nodes.map(\.id), ["plan-b"])
    }
    func testUnresolvableAndSelfRefMakeNoEdge() {
        let g1 = build([plan("b", runsAfter: "missing")], status: ["b": .ready])
        XCTAssertTrue(g1.edges.isEmpty)
        let g2 = build([plan("b", runsAfter: "b")], status: ["b": .ready])
        XCTAssertTrue(g2.edges.isEmpty)
    }
    func testDeterministicOrder() {
        let a = build([plan("b"), plan("a")], status: [:]).nodes.map(\.id)
        let b = build([plan("a"), plan("b")], status: [:]).nodes.map(\.id)
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 3: Run to verify they fail** — `swift test --filter ProjectGraphBuilderTests` → FAIL (undefined).

- [ ] **Step 4: Implement**

```swift
// Sources/Dreamux/Models/ProjectGraph.swift
import Foundation

/// The project's plan-dependency graph: a node per shown plan, a
/// `.dependency` edge per `Runs: after`. Pure; laid out by FlowLayoutEngine
/// and rendered by ProjectGraphView (full on Flows, compact in the rail).
struct ProjectGraph: Equatable {
    let nodes: [FlowNode]   // id "plan-<path>", kind .plan
    let edges: [FlowEdge]   // kind .dependency, blocker → waiter

    /// Node ids waiting on a not-yet-done blocker (an incoming `.dependency`
    /// whose source isn't `.done`). Derived, so the renderer can dash them.
    var blockedIDs: Set<String> {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(edges.compactMap { byID[$0.from]?.status != .done ? $0.to : nil })
    }
}

enum ProjectGraphBuilder {
    static func build(
        plans: [PlanDoc],
        relativePath: (PlanDoc) -> String,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> ProjectGraph {
        let statusByURL = Dictionary(plans.map { ($0.fileURL, statusOf($0)) },
                                     uniquingKeysWith: { a, _ in a })
        func st(_ p: PlanDoc) -> PlanStatus { statusByURL[p.fileURL] ?? .ready }

        let nonMerged = plans.filter { st($0) != .merged }
        // (blocker, waiter) for non-merged waiters with a resolvable, non-self blocker.
        var pairs: [(blocker: PlanDoc, waiter: PlanDoc)] = []
        for waiter in nonMerged {
            guard let ref = waiter.runsAfter, let blocker = resolveBlocker(ref),
                  blocker.fileURL != waiter.fileURL else { continue }
            pairs.append((blocker, waiter))
        }
        // Included = non-merged, plus any MERGED blocker of a pair.
        var includedURLs = Set(nonMerged.map { $0.fileURL })
        for pair in pairs where st(pair.blocker) == .merged {
            includedURLs.insert(pair.blocker.fileURL)
        }
        // Stable order by relative path (PlanDoc carries no startedAt).
        let included = plans
            .filter { includedURLs.contains($0.fileURL) }
            .sorted { relativePath($0) < relativePath($1) }

        let nodes = included.map { plan in
            FlowNode(id: "plan-\(relativePath(plan))", kind: .plan,
                     label: plan.title, status: st(plan).flowStatus)
        }
        let edges = pairs
            .filter { includedURLs.contains($0.blocker.fileURL) && includedURLs.contains($0.waiter.fileURL) }
            .map { FlowEdge(from: "plan-\(relativePath($0.blocker))",
                            to: "plan-\(relativePath($0.waiter))", kind: .dependency) }
        return ProjectGraph(nodes: nodes, edges: edges)
    }
}
```

- [ ] **Step 5: Run to verify they pass** — `swift test --filter ProjectGraphBuilderTests` → PASS (6 tests). Then `swift build`.

- [ ] **Step 6: Audit `FlowNodeKind` switches** — grep `switch` over `FlowNodeKind` (e.g. `FlowDetailView.statusGlyph`/`nodeView`, `FlowLaneView`); ensure adding `.plan` didn't create a non-exhaustive switch (add a `.plan` branch or a `default` mapping it to a plain pill where needed). `swift build` confirms exhaustiveness.

- [ ] **Step 7: Commit**
```bash
git add Sources/Dreamux/Models/FlowGraph.swift Sources/Dreamux/Models/ProjectGraph.swift Tests/DreamuxTests/ProjectGraphBuilderTests.swift Sources/Dreamux/Views/FlowDetailView.swift Sources/Dreamux/Views/FlowLaneView.swift
git commit -m "ProjectGraph: model + builder (plans -> nodes, runsAfter -> dependency edges)"
```
(Only stage the view files if the exhaustiveness audit actually edited them.)

---

### Task 3: Parameterize `FlowLayoutEngine`

**Files:** Modify `Sources/Dreamux/Models/FlowLayoutEngine.swift`; extend `Tests/DreamuxTests/FlowLayoutEngineTests.swift`.

**Interfaces:** Produces `FlowLayoutEngine.layout(nodes:edges:nodeSize:rankGap:siblingGap:margin:)` (new params optional, defaults = current constants).

- [ ] **Step 1: Write the failing test** (append to `FlowLayoutEngineTests.swift`; if none exists, create it)

```swift
func testCustomNodeSizeShrinksLayout() {
    let nodes = [FlowNode(id: "a", kind: .plan, label: "a", status: .queued),
                 FlowNode(id: "b", kind: .plan, label: "b", status: .queued)]
    let edges = [FlowEdge(from: "a", to: "b", kind: .dependency)]
    let big = FlowLayoutEngine.layout(nodes: nodes, edges: edges)
    let small = FlowLayoutEngine.layout(nodes: nodes, edges: edges,
                                        nodeSize: CGSize(width: 16, height: 16),
                                        rankGap: 12, siblingGap: 8, margin: 6)
    XCTAssertLessThan(small.size.height, big.size.height)
    XCTAssertLessThan(small.size.width, big.size.width)
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter FlowLayoutEngineTests` → FAIL (extra-argument / undefined).

- [ ] **Step 3: Implement** — read `FlowLayoutEngine.swift`; change the signature to accept the four optional params (defaulting to `Self.nodeSize` / `Self.rankGap` / `Self.siblingGap` / `Self.margin`) and use the PARAMS everywhere the code currently reads those static constants (the SwiftDagre `nodeSize`, `LayoutOptions.nodesep`/`.ranksep`/`.marginx`/`.marginy`). Leave the static constants as the defaults.

- [ ] **Step 4: Run to verify it passes** — `swift test --filter FlowLayoutEngineTests` → PASS. `swift build`.

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Models/FlowLayoutEngine.swift Tests/DreamuxTests/FlowLayoutEngineTests.swift
git commit -m "FlowLayoutEngine: optional node-size/gap params (defaults unchanged)"
```

---

### Task 4: Extract `FlowEdgeGeometry`

**Files:** Create `Sources/Dreamux/Models/FlowEdgeGeometry.swift`, `Tests/DreamuxTests/FlowEdgeGeometryTests.swift`. Modify `Sources/Dreamux/Views/FlowDetailView.swift`.

**Interfaces:** Produces `FlowEdgeGeometry.smoothedPath(_:) -> Path` and `FlowEdgeGeometry.arrowheadPath(into:along:) -> Path?` — verbatim moves of `FlowDetailView`'s private methods.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/FlowEdgeGeometryTests.swift
import XCTest
import SwiftUI
@testable import Dreamux

final class FlowEdgeGeometryTests: XCTestCase {
    func testSmoothedPathSpansItsPoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 20), CGPoint(x: 100, y: 0)]
        let rect = FlowEdgeGeometry.smoothedPath(pts).boundingRect
        XCTAssertFalse(rect.isEmpty)
        XCTAssertLessThanOrEqual(rect.minX, 1)
        XCTAssertGreaterThanOrEqual(rect.maxX, 99)
    }
    func testArrowheadNilForTooFewPoints() {
        XCTAssertNil(FlowEdgeGeometry.arrowheadPath(into: .zero, along: [.zero]))
    }
    func testArrowheadNonNilForAnEdge() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)]
        XCTAssertNotNil(FlowEdgeGeometry.arrowheadPath(into: CGPoint(x: 0, y: 100), along: pts))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter FlowEdgeGeometryTests` → FAIL.

- [ ] **Step 3: Implement** — create `FlowEdgeGeometry` (an `enum` with two `static` funcs) and MOVE the bodies of `FlowDetailView.smoothedPath(_:)` and `arrowheadPath(into:along:)` into it verbatim (they're pure geometry; `import SwiftUI`). In `FlowDetailView`, delete the two private methods and replace their call sites with `FlowEdgeGeometry.smoothedPath(...)` / `FlowEdgeGeometry.arrowheadPath(...)`. Leave `selfLoopPath` in `FlowDetailView`.

- [ ] **Step 4: Run to verify it passes + build** — `swift test --filter FlowEdgeGeometryTests` → PASS. `swift build` → clean (confirms FlowDetailView still compiles against the moved geometry).

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Models/FlowEdgeGeometry.swift Tests/DreamuxTests/FlowEdgeGeometryTests.swift Sources/Dreamux/Views/FlowDetailView.swift
git commit -m "Flows: extract FlowEdgeGeometry (smoothed spline + arrowhead) for reuse"
```

---

### Task 5: `ProjectGraphView` + the Flows project panel

View task — verified by `swift build` + inspection (no view-test harness), per prior slices.

**Files:** Create `Sources/Dreamux/Views/ProjectGraphView.swift`. Modify `Sources/Dreamux/Views/FlowsOverviewView.swift`, `Sources/Dreamux/Views/ContentView.swift`.

**Interfaces:**
- Consumes: `ProjectGraph` (Task 2), `FlowLayoutEngine.layout(...)` (Task 3), `FlowEdgeGeometry` (Task 4), `FlowStatusGlyph`.
- Produces: `struct ProjectGraphView { let graph: ProjectGraph; let compact: Bool; let onSelectPlan: (String) -> Void }`.

- [ ] **Step 1: Build `ProjectGraphView`**

```swift
// Sources/Dreamux/Views/ProjectGraphView.swift
import SwiftUI

struct ProjectGraphView: View {
    let graph: ProjectGraph
    let compact: Bool
    let onSelectPlan: (String) -> Void

    private var layout: FlowLayout {
        compact
            ? FlowLayoutEngine.layout(nodes: graph.nodes, edges: graph.edges,
                                      nodeSize: CGSize(width: 16, height: 16),
                                      rankGap: 16, siblingGap: 14, margin: 8)
            : FlowLayoutEngine.layout(nodes: graph.nodes, edges: graph.edges)
    }

    var body: some View {
        let l = layout
        ZStack(alignment: .topLeading) {
            // edges
            Canvas { ctx, _ in
                for edge in graph.edges {
                    let pts = l.edgePoints[.init(from: edge.from, to: edge.to)]
                        ?? [l.positions[edge.from], l.positions[edge.to]].compactMap { $0 }
                    guard pts.count >= 2 else { continue }
                    if compact {
                        var line = Path(); line.move(to: pts.first!); line.addLine(to: pts.last!)
                        ctx.stroke(line, with: .color(Color(nsColor: .separatorColor)), lineWidth: 1.2)
                    } else {
                        ctx.stroke(FlowEdgeGeometry.smoothedPath(pts),
                                   with: .color(Color(nsColor: .separatorColor)), lineWidth: 1.6)
                        if let head = FlowEdgeGeometry.arrowheadPath(into: pts.last!, along: pts) {
                            ctx.fill(head, with: .color(Color(nsColor: .separatorColor)))
                        }
                    }
                }
            }
            .frame(width: l.size.width, height: l.size.height)
            // nodes
            ForEach(graph.nodes) { node in
                if let p = l.positions[node.id] {
                    nodeView(node).position(p)
                }
            }
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func nodeView(_ node: FlowNode) -> some View {
        let blocked = graph.blockedIDs.contains(node.id)
        let color = FlowStatusGlyph.color(node.status)
        if compact {
            Circle()
                .strokeBorder(blocked ? Color.secondary : color, style: StrokeStyle(lineWidth: 1.5, dash: blocked ? [3, 2] : []))
                .background(Circle().fill(node.status == .done || node.status == .running ? color : Color.clear))
                .frame(width: 12, height: 12)
                .onTapGesture { onSelectPlan(node.id) }
        } else {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(node.label).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).foregroundStyle(blocked ? .secondary : .primary)
            }
            .padding(.horizontal, 11).frame(height: 40)
            .frame(maxWidth: FlowLayoutEngine.nodeSize.width)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(blocked ? Color.secondary.opacity(0.5) : color,
                                      style: StrokeStyle(lineWidth: 1.4, dash: blocked ? [4, 3] : [])))
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelectPlan(node.id) }
        }
    }
}
```
(`FlowLayout.EdgeKey` is `.init(from:to:)`. If `FlowStatusGlyph`/`FlowLayout` names differ, match the actual definitions.)

- [ ] **Step 2: Mount the Flows project panel**

In `FlowsOverviewView.swift`: add `let projectGraph: () -> ProjectGraph`. In `body`, only when not zoomed, insert between `headerRow(board)` and `ForEach(board.sections)`:
```swift
let graph = projectGraph()
if graph.nodes.count > 1 {
    VStack(alignment: .leading, spacing: 8) {
        Text("This project").font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase).kerning(0.4).foregroundStyle(.secondary)
        ScrollView(.horizontal, showsIndicators: false) {
            ProjectGraphView(graph: graph, compact: false) { id in zoomedLaneID = id }
                .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
    }
    .padding(.bottom, 6)
}
```

- [ ] **Step 3: Build + pass the graph from `ContentView`**

At the `FlowsOverviewView(...)` call, add:
```swift
projectGraph: {
    ProjectGraphBuilder.build(
        plans: docStore.plans,
        relativePath: { docStore.relativePath(of: $0) },
        resolveBlocker: { ref in
            let target = docStore.resolvedURL(forReference: ref)
            return docStore.plans.first { $0.fileURL.standardizedFileURL == target }
        },
        statusOf: { docStore.status(for: $0, featureExists: featureExists) })
},
```
(Match `docStore`/`featureExists` to the names in scope where `FlowsOverviewView` is constructed.)

- [ ] **Step 4: Build + manually verify** — `swift build` → clean. Run the app (outside a subagent): the Flows overview shows a "This project" panel of plan nodes with dependency arrows; a running plan is orange, a blocked one dashed/dim, parallels stand apart; clicking a node zooms to that plan's lane.

- [ ] **Step 5: Commit**
```bash
git add Sources/Dreamux/Views/ProjectGraphView.swift Sources/Dreamux/Views/FlowsOverviewView.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Flows: project graph panel (plan-dependency DAG)"
```

---

### Task 6: Sidebar mini-map + navigation

View task — `swift build` + inspection.

**Files:** Modify `Sources/Dreamux/Views/PlansSpecsSection.swift`, `Sources/Dreamux/Views/WorkspaceSidebar.swift`, `Sources/Dreamux/Views/ContentView.swift`.

**Interfaces:** Consumes `ProjectGraphView` (Task 5). Produces `onOpenProjectGraph: () -> Void` threaded to `PlansSpecsSection`.

- [ ] **Step 1: Thread the nav closure**

Add `let onOpenProjectGraph: () -> Void` to `PlansSpecsSection` and to `WorkspaceSidebar` (forwarded to `PlansSpecsSection`). In `ContentView`, at the `WorkspaceSidebar(...)` call, pass:
```swift
onOpenProjectGraph: { sidebarMode = .flows; flowsZoomLaneID = nil },
```

- [ ] **Step 2: Render the mini-map at the foot of the section**

In `PlansSpecsSection.body`, inside the `plansExpanded` block after `newWorkspaceRow`, build the graph (reusing `docStore`/`featureExists`/`planStatuses()` already in scope) and render it in the mini-map container:
```swift
let graph = ProjectGraphBuilder.build(
    plans: docStore.plans,
    relativePath: { docStore.relativePath(of: $0) },
    resolveBlocker: { ref in
        let target = docStore.resolvedURL(forReference: ref)
        return docStore.plans.first { $0.fileURL.standardizedFileURL == target }
    },
    statusOf: { docStore.status(for: $0, featureExists: featureExists) })
if graph.nodes.count > 1 {
    Button(action: onOpenProjectGraph) {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dependencies").font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase).kerning(0.4).foregroundStyle(.tertiary)
                Spacer()
                Text("Open in Flows →").font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            ProjectGraphView(graph: graph, compact: true) { _ in onOpenProjectGraph() }
                .frame(maxWidth: .infinity, minHeight: 70)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .padding(.top, 8)
}
```
(In `compact` mode a node tap and a background tap both currently open the project panel — a per-node jump can be a later refinement; for now both routes land on Flows.)

- [ ] **Step 3: Build + manually verify** — `swift build` → clean. The Workspaces rail shows a "Dependencies" mini-map (dots + lines) at the foot when there's >1 plan; clicking it opens the Flows project panel. Hidden with ≤1 plan.

- [ ] **Step 4: Commit**
```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Sidebar: project-graph mini-map at the foot of Workspaces"
```

---

## Self-Review

- **Spec coverage:** `PlanStatus.flowStatus` (T1), `.plan` kind + `ProjectGraph`/builder + merged-blocker rule + `blockedIDs` (T2), layout params (T3), `FlowEdgeGeometry` extraction (T4), `ProjectGraphView` + Flows panel + node→zoom (T5), mini-map + `onOpenProjectGraph` nav (T6). All spec components map to a task.
- **Type consistency:** `ProjectGraphBuilder.build(plans:relativePath:resolveBlocker:statusOf:)`, `ProjectGraph{nodes,edges,blockedIDs}`, `ProjectGraphView(graph:compact:onSelectPlan:)`, `FlowLayoutEngine.layout(nodes:edges:nodeSize:rankGap:siblingGap:margin:)`, `FlowEdgeGeometry.smoothedPath/arrowheadPath`, node id `plan-<path>` — used identically across tasks.
- **No placeholders:** pure tasks carry full code + commands; view tasks give the concrete structure + build/inspect checks, and flag the two "match the actual name in scope" spots (T5 status-glyph names, T5/T6 `docStore`/`featureExists` scope).
