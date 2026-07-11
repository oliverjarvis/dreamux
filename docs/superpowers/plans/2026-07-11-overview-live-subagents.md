# Overview Live Subagents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the subagents a run is spawning on the plan-backed workspace Overview — a "Working now" strip of subagent pills, plus a best-effort agent badge on the checklist task a subagent is handling.

**Architecture:** Two pure, unit-tested mappers turn FlowStore's already-observed `.agent` nodes into `[LiveSubagent]`; `WorkspaceOverviewView` reads `FlowStore` as an `@ObservedObject` and renders the strip + badges; a pill click zooms the Flows page to the run's plan lane. No new feeds, no orchestration — read-only presentation of existing data.

**Tech Stack:** SwiftUI, existing `FlowStore`/`FlowGraph`, `PlanDoc`/`PlanTask`, `OverviewPrimitives`, XCTest. No new dependencies.

**Spec:** docs/superpowers/specs/2026-07-11-overview-live-subagents-design.md — read it first.

## Global Constraints

- **Shared status vocabulary.** A subagent's running/waiting color comes from `FlowStatusGlyph.color(_:)` (`FlowLaneView.swift`) — never new tint rules.
- **House style** (CLAUDE.md): generous type/spacing; hover/selection washes `Color.primary.opacity(0.04)`/`0.08`; `RoundedRectangle`/`Capsule` with `.continuous`; the pill reads as one family with `OverviewStatusPill`.
- **Reduce-motion aware.** The "working" pulse honors `@Environment(\.accessibilityReduceMotion)` (mirror `OverviewStatusPill`).
- **Best-effort pin, never a wrong pin.** A checklist badge appears only when a subagent's text names a task by number unambiguously.
- **Mode A only.** The strip and badge live on the plan-backed Overview; Mode B is out of scope.

## File Structure

- `Sources/Dreamux/Models/SubagentTaskPin.swift` (new) — pure best-effort matcher (subagent text → `PlanTask.line`).
- `Sources/Dreamux/Models/LiveSubagent.swift` (new) — the display value type.
- `Sources/Dreamux/Models/OverviewLiveAgents.swift` (new) — pure projection (workspace lanes → `[LiveSubagent]`).
- `Sources/Dreamux/Models/FlowStore.swift` (modify) — expose `collapsedAgentNodeID` (drop `private`).
- `Sources/Dreamux/Views/OverviewPrimitives.swift` (modify) — add `LiveSubagentPill`.
- `Sources/Dreamux/Views/WorkspaceOverviewView.swift` (modify) — `flows`/`onOpenRunFlow` inputs, the "Working now" strip, the per-task badge.
- `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` (modify) — pass the two new inputs at the `WorkspaceOverviewView(...)` call.
- `Sources/Dreamux/Views/ContentView.swift` (modify) — add the two fields to the `WorkspaceOverviewDependencies` bundle.
- `Tests/DreamuxTests/SubagentTaskPinTests.swift` (new)
- `Tests/DreamuxTests/OverviewLiveAgentsTests.swift` (new)

---

### Task 1: `SubagentTaskPin` — best-effort task matcher

**Files:**
- Create: `Sources/Dreamux/Models/SubagentTaskPin.swift`
- Test: `Tests/DreamuxTests/SubagentTaskPinTests.swift`

**Interfaces:**
- Consumes: `PlanTask` (`title: String`, `line: Int`) from `PlanDoc.swift`.
- Produces: `SubagentTaskPin.line(forAgentText: String, tasks: [PlanTask]) -> Int?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/SubagentTaskPinTests.swift
import XCTest
@testable import Dreamux

final class SubagentTaskPinTests: XCTestCase {
    private func task(_ title: String, line: Int) -> PlanTask {
        PlanTask(title: title, steps: [PlanStep(title: "s", checked: false)], line: line)
    }

    func testPinsExplicitTaskNumber() {
        let tasks = [task("Task 1: Model", line: 10), task("Task 3: Checklist restyle", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "Implementing Task 3: the restyle", tasks: tasks), 40)
    }
    func testCaseInsensitive() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "working on task 3", tasks: tasks), 40)
    }
    func testDottedNumber() {
        let tasks = [task("Task 0.2: Phase task", line: 22)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "Task 0.2 in progress", tasks: tasks), 22)
    }
    func testPaddingAndSpacingNormalize() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertEqual(SubagentTaskPin.line(forAgentText: "task  03 running", tasks: tasks), 40)
    }
    func testNoTokenIsNil() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "reviewing the diff", tasks: tasks))
    }
    func testNumberWithNoMatchingTitleIsNil() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "Task 9 here", tasks: tasks))
    }
    func testAmbiguousNumberIsNil() {
        let tasks = [task("Task 3: X", line: 40), task("Task 3: dup", line: 80)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "Task 3", tasks: tasks))
    }
    func testDoesNotMatchSubstringWord() {
        let tasks = [task("Task 3: X", line: 40)]
        XCTAssertNil(SubagentTaskPin.line(forAgentText: "subtask 3 stuff", tasks: tasks))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SubagentTaskPinTests`
Expected: FAIL — `SubagentTaskPin` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/Dreamux/Models/SubagentTaskPin.swift
import Foundation

/// Best-effort match of a live subagent to the plan task it's working.
/// Conservative by design: it pins ONLY when the subagent's text names a
/// task by number (`Task 3`, `Task 0.2`) and exactly one plan task carries
/// that number. No token, no numbered match, or an ambiguous number → nil,
/// so the checklist never badges the wrong row.
enum SubagentTaskPin {
    static func line(forAgentText text: String, tasks: [PlanTask]) -> Int? {
        guard let wanted = firstTaskNumber(in: text) else { return nil }
        let matches = tasks.filter { taskNumber(of: $0.title) == wanted }
        guard matches.count == 1 else { return nil }
        return matches.first?.line
    }

    /// The first `Task <n>[.<m>…]` number mentioned in free text (whole-word
    /// `task`, so `subtask 3` never matches), normalized.
    private static func firstTaskNumber(in text: String) -> String? {
        guard let range = text.range(
            of: #"(?i)\btask\s+\d+(?:\.\d+)*"#, options: .regularExpression)
        else { return nil }
        return normalize(String(text[range]))
    }

    /// The `Task N[.M…]` number a task title declares (anchored at the
    /// start), normalized, or nil.
    private static func taskNumber(of title: String) -> String? {
        guard let range = title.range(
            of: #"(?i)^task\s+\d+(?:\.\d+)*"#, options: .regularExpression)
        else { return nil }
        return normalize(String(title[range]))
    }

    /// `"Task 03"` / `"task  3"` → `"3"`; `"Task 0.2"` → `"0.2"`. Strips the
    /// word and collapses each numeric segment (drops leading zeros) so a
    /// mention and a title compare equal regardless of spacing/padding.
    private static func normalize(_ token: String) -> String {
        token
            .replacingOccurrences(of: #"(?i)^task\s+"#, with: "", options: .regularExpression)
            .split(separator: ".")
            .map { String(Int($0) ?? 0) }
            .joined(separator: ".")
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter SubagentTaskPinTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SubagentTaskPin.swift Tests/DreamuxTests/SubagentTaskPinTests.swift
git commit -m "Subagents: best-effort task-pin matcher"
```

---

### Task 2: `LiveSubagent` + `OverviewLiveAgents` — pure projection

**Files:**
- Create: `Sources/Dreamux/Models/LiveSubagent.swift`
- Create: `Sources/Dreamux/Models/OverviewLiveAgents.swift`
- Modify: `Sources/Dreamux/Models/FlowStore.swift:162` — expose `collapsedAgentNodeID`
- Test: `Tests/DreamuxTests/OverviewLiveAgentsTests.swift`

**Interfaces:**
- Consumes: `Flow`/`FlowNode`/`FlowStatus` (`FlowGraph.swift`), `PlanTask` (`PlanDoc.swift`), `SubagentTaskPin.line(forAgentText:tasks:)` (Task 1), `FlowStore.collapsedAgentNodeID`.
- Produces:
  - `struct LiveSubagent: Identifiable, Equatable { id, name, activity, status, taskLine }`
  - `OverviewLiveAgents.subagents(in: [Flow], workspaceID: UUID, tasks: [PlanTask]) -> [LiveSubagent]`

- [ ] **Step 1: Expose the collapsed-agent node id**

In `Sources/Dreamux/Models/FlowStore.swift:162`, change:
```swift
    private static let collapsedAgentNodeID = "agents-collapsed"
```
to:
```swift
    static let collapsedAgentNodeID = "agents-collapsed"
```

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/DreamuxTests/OverviewLiveAgentsTests.swift
import XCTest
@testable import Dreamux

final class OverviewLiveAgentsTests: XCTestCase {
    private let ws = UUID()

    private func lane(_ id: String, workspace: UUID?, nodes: [FlowNode]) -> Flow {
        var f = Flow(id: id, title: id, kind: .adhoc, workspaceID: workspace)
        f.nodes = nodes
        return f
    }
    private func agent(_ id: String, label: String, status: FlowStatus,
                       started: Date? = nil, activity: String? = nil) -> FlowNode {
        FlowNode(id: id, kind: .agent, label: label, status: status,
                 startedAt: started, lastActivity: activity)
    }

    func testExcludesSessionKeepsRunningSubagent() {
        let flows = [lane("l1", workspace: ws, nodes: [
            FlowNode(id: "session", kind: .agent, label: "claude", status: .running),
            agent("agent-1", label: "code-reviewer", status: .running),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["agent-1"])
        XCTAssertEqual(result.first?.name, "code-reviewer")
    }

    func testExcludesCollapsedQueuedDoneFailed() {
        let flows = [lane("l1", workspace: ws, nodes: [
            agent("agent-done", label: "Explore", status: .done),
            agent("agent-queued", label: "Explore", status: .queued),
            agent("agent-failed", label: "Explore", status: .failed),
            FlowNode(id: FlowStore.collapsedAgentNodeID, kind: .agent, label: "agents", status: .running),
            agent("agent-live", label: "Explore", status: .waiting),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["agent-live"])
    }

    func testAggregatesAcrossLanesIgnoresOtherWorkspaces() {
        let other = UUID()
        let flows = [
            lane("l1", workspace: ws, nodes: [agent("a1", label: "x", status: .running, started: Date(timeIntervalSince1970: 10))]),
            lane("l2", workspace: ws, nodes: [agent("a2", label: "y", status: .running, started: Date(timeIntervalSince1970: 20))]),
            lane("l3", workspace: other, nodes: [agent("a3", label: "z", status: .running)]),
        ]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: [])
        XCTAssertEqual(result.map(\.id), ["a1", "a2"])  // stable, oldest first
    }

    func testAppliesPinFromActivity() {
        let tasks = [PlanTask(title: "Task 3: X", steps: [PlanStep(title: "s", checked: false)], line: 42)]
        let flows = [lane("l1", workspace: ws, nodes: [
            agent("a1", label: "general-purpose", status: .running, activity: "Implementing Task 3"),
        ])]
        let result = OverviewLiveAgents.subagents(in: flows, workspaceID: ws, tasks: tasks)
        XCTAssertEqual(result.first?.taskLine, 42)
        XCTAssertEqual(result.first?.activity, "Implementing Task 3")
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter OverviewLiveAgentsTests`
Expected: FAIL — `LiveSubagent` / `OverviewLiveAgents` undefined.

- [ ] **Step 4: Implement**

```swift
// Sources/Dreamux/Models/LiveSubagent.swift
import Foundation

/// A subagent currently working on a run, projected from a FlowStore
/// `.agent` node for the workspace Overview's "Working now" strip.
struct LiveSubagent: Identifiable, Equatable {
    let id: String          // the FlowNode id, e.g. "agent-abc123"
    let name: String        // node.label (agent type)
    let activity: String?   // node.lastActivity ("what it's on"), may be nil
    let status: FlowStatus  // .running or .waiting only
    let taskLine: Int?      // best-effort pin to a PlanTask.line, else nil
}
```

```swift
// Sources/Dreamux/Models/OverviewLiveAgents.swift
import Foundation

/// Projects a workspace's live subagents out of its FlowStore lanes for the
/// Overview's "Working now" strip. Pure over its inputs (no store, no IO).
/// Excludes the main "session" node and the fan-out collapse node; keeps
/// only running/waiting; best-effort pins each to a plan task.
enum OverviewLiveAgents {
    static func subagents(
        in flows: [Flow],
        workspaceID: UUID,
        tasks: [PlanTask]
    ) -> [LiveSubagent] {
        let nodes = flows
            .filter { $0.workspaceID == workspaceID }
            .flatMap(\.nodes)
            .filter { node in
                node.kind == .agent
                    && node.id != "session"
                    && node.id != FlowStore.collapsedAgentNodeID
                    && (node.status == .running || node.status == .waiting)
            }
            .sorted { a, b in
                let ad = a.startedAt ?? .distantFuture   // nil sorts last
                let bd = b.startedAt ?? .distantFuture
                if ad != bd { return ad < bd }
                return a.id < b.id
            }
        return nodes.map { node in
            let text = node.label + " " + (node.lastActivity ?? "")
            return LiveSubagent(
                id: node.id,
                name: node.label,
                activity: node.lastActivity,
                status: node.status,
                taskLine: SubagentTaskPin.line(forAgentText: text, tasks: tasks))
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --filter OverviewLiveAgentsTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/LiveSubagent.swift Sources/Dreamux/Models/OverviewLiveAgents.swift Sources/Dreamux/Models/FlowStore.swift Tests/DreamuxTests/OverviewLiveAgentsTests.swift
git commit -m "Subagents: LiveSubagent projection from FlowStore lanes"
```

---

### Task 3: `LiveSubagentPill` + wiring + the "Working now" strip

No automated view test exists in this codebase for this layer (the Overview redesign followed the same pattern — mappers are unit-tested, views verified by build + inspection). Verification here is `swift build` + the manual checklist in Step 6. The projection's correctness is already covered by Tasks 1–2.

**Files:**
- Modify: `Sources/Dreamux/Views/OverviewPrimitives.swift` — add `LiveSubagentPill`
- Modify: `Sources/Dreamux/Views/ContentView.swift:836` — add two fields to the bundle
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift:90` — pass them to `WorkspaceOverviewView`
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — inputs + strip

**Interfaces:**
- Consumes: `OverviewLiveAgents.subagents(...)` (Task 2), `FlowStatusGlyph.color(_:)`, `FlowStore` (`ProjectSession.flows`), existing `OverviewSectionLabel`, `WorkspaceOverviewView.cleanTitle(_:)`.
- Produces: `struct LiveSubagentPill: View { subagent: LiveSubagent; detail: String?; onOpen: () -> Void }`; two new inputs on `WorkspaceOverviewView` (`@ObservedObject var flows: FlowStore`, `let onOpenRunFlow: (UUID) -> Void`) carried by `WorkspaceOverviewDependencies`.

- [ ] **Step 1: Add `LiveSubagentPill`** (append to `OverviewPrimitives.swift`)

```swift
/// A live subagent as a clickable pill for the Overview's "Working now"
/// strip: a pulsing status dot, the agent name, and a `· detail` tail
/// (the pinned task title, or the live activity — the strip decides).
/// Same visual family as `OverviewStatusPill`.
struct LiveSubagentPill: View {
    let subagent: LiveSubagent
    let detail: String?
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Circle()
                    .fill(FlowStatusGlyph.color(subagent.status))
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 1 : (pulse ? 0.35 : 1))
                Text(subagent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(0.05))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open this run's flow")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
```

- [ ] **Step 2: Add the two inputs to `WorkspaceOverviewView`**

After `@Bindable var session: WorkspaceSession` add:
```swift
    /// The project's live flow state — read reactively so the Overview's
    /// "Working now" strip updates as subagents start and stop. Carried by
    /// `WorkspaceOverviewDependencies` (a plain reference) and re-wrapped
    /// here so `@Published flows` drives re-render.
    @ObservedObject var flows: FlowStore
```
Alongside the other `let` closures add:
```swift
    /// Zoom the Flows page to this workspace's run lane — the pill's click
    /// target. See `WorkspaceOverviewDependencies.onOpenRunFlow`.
    let onOpenRunFlow: (UUID) -> Void
```

- [ ] **Step 3: Carry both on `WorkspaceOverviewDependencies`** (top of `WorkspaceOverviewView.swift`)

Add to the struct:
```swift
    /// Live flow state, passed as a plain reference and re-wrapped as an
    /// `@ObservedObject` on the view (a struct field can't be observed).
    let flows: FlowStore
    /// Zoom the Flows page to a workspace's run lane (the "Working now"
    /// pill's click target). ContentView resolves the workspace's plan lane
    /// — the session lane the subagent lives on is board-suppressed.
    let onOpenRunFlow: (UUID) -> Void
```

- [ ] **Step 4: Wire the two call sites**

In `WorkspaceTerminalContainer.swift` at the `WorkspaceOverviewView(` call (~line 90), add:
```swift
                flows: overview.flows,
                onOpenRunFlow: overview.onOpenRunFlow,
```
(place alongside the existing arguments; the surrounding call already forwards `overview.` fields).

In `ContentView.swift` inside the `WorkspaceOverviewDependencies(` literal (~line 837), add:
```swift
            flows: session.flows,
            onOpenRunFlow: { ws in
                let lane = session.flows.flows.first { $0.workspaceID == ws && $0.kind == .plan }
                    ?? session.flows.flows.first { $0.workspaceID == ws }   // Mode B fallback
                if let lane {
                    sidebarMode = .flows
                    flowsZoomLaneID = lane.id
                }
            },
```
(`session` here is the `ProjectSession`; `sidebarMode`/`flowsZoomLaneID` are existing `@State` — this mirrors the existing e2e `zoomFlow` path.)

- [ ] **Step 5: Render the strip in `modeA` + the `detail` helper**

In `WorkspaceOverviewView.modeA`, compute the subagents once and pass them into the checklist (Task 4 uses them too):
```swift
    private func modeA(_ plan: PlanDoc) -> some View {
        let status = docStore.status(for: plan, featureExists: { _ in true })
        let hero = RunHeroState.resolve(status: status, hasLiveAgent: hasLiveAgent(session.workspace))
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        let live = OverviewLiveAgents.subagents(
            in: flows.flows, workspaceID: session.workspace.id, tasks: plan.tasks)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard(plan, hero: hero)
                if !live.isEmpty {
                    workingNow(plan, subagents: live)
                }
                OverviewSectionLabel(title: "Tasks", trailing: "\(tasks.count) tasks")
                checklist(plan)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if expandedTaskLines.isEmpty, let line = currentTaskLine(plan) {
                expandedTaskLines.insert(line)
            }
        }
    }

    /// The "Working now" strip: a pill per live subagent. Horizontal scroll
    /// is a safe fallback for the rare overflow (done agents are collapsed
    /// upstream, so live ones are few). Hidden entirely when `subagents` is
    /// empty (caller guards).
    private func workingNow(_ plan: PlanDoc, subagents: [LiveSubagent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OverviewSectionLabel(title: "Working now")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(subagents) { sub in
                        LiveSubagentPill(subagent: sub, detail: detailText(for: sub, plan: plan)) {
                            onOpenRunFlow(session.workspace.id)
                        }
                    }
                }
            }
        }
    }

    /// Prefer the pinned task's clean title (so the pill and the badged row
    /// agree); fall back to the subagent's live activity.
    private func detailText(for sub: LiveSubagent, plan: PlanDoc) -> String? {
        if let line = sub.taskLine, let task = plan.tasks.first(where: { $0.line == line }) {
            return cleanTitle(task.title)
        }
        return sub.activity
    }
```

`checklist(_:)` is unchanged in this task — the `live` value computed in
`modeA` feeds only `workingNow` here; Task 4 threads it into the checklist for
the per-task badge.

- [ ] **Step 6: Build + manually verify**

Run: `swift build`
Expected: `Build complete!`

Then run the app (outside any subagent) and confirm on a plan-backed workspace with a live run that spawns subagents:
- A "Working now" strip appears between the hero and Tasks, with a pill per live subagent (name + pulsing dot + activity/task).
- The strip disappears when no subagent is live.
- Clicking a pill switches to the Flows page zoomed on the run's lane.
- Reduce Motion (System Settings → Accessibility) stops the pulse.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Views/OverviewPrimitives.swift Sources/Dreamux/Views/WorkspaceOverviewView.swift Sources/Dreamux/Views/WorkspaceTerminalContainer.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Overview: 'Working now' subagent strip"
```

---

### Task 4: Per-task agent badge on the checklist

No automated view test (same rationale as Task 3): verify by `swift build` + inspection. The pin logic it depends on is covered by Tasks 1–2.

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — thread `live` into the checklist, add the badge

**Interfaces:**
- Consumes: `live` computed in `modeA` (Task 3), `FlowStatusGlyph.color(_:)`.
- Produces: an agent chip on the row a subagent is pinned to.

- [ ] **Step 1: Thread `live` from `modeA` into the checklist**

In `modeA`, pass the already-computed `live` to the checklist:
```swift
                checklist(plan, live: live)
```
Add the parameter to `checklist`, `phaseSection`, and `taskRow`, forwarding it down:
```swift
    @ViewBuilder
    private func checklist(_ plan: PlanDoc, live: [LiveSubagent]) -> some View {
        // ...unchanged body, except each call forwards `live:`...
        //   phaseSection(group, plan: plan, numbers: numbers,
        //                isCurrentGroup: index == currentGroup, live: live)
        //   taskRow(task, number: index + 1, plan: plan,
        //           isCurrent: index == currentIndex, live: live)
    }

    private func phaseSection(
        _ group: PlanPhases.Group, plan: PlanDoc, numbers: [Int: Int],
        isCurrentGroup: Bool, live: [LiveSubagent]
    ) -> some View {
        // ...unchanged, except its taskRow(...) call forwards `live: live`...
    }

    private func taskRow(
        _ task: PlanTask, number: Int, plan: PlanDoc, isCurrent: Bool, live: [LiveSubagent]
    ) -> some View { /* Step 2 adds the badge */ }
```

- [ ] **Step 2: Render the badge in `taskRow`**

Inside `taskRow`, after computing `checked/total`, resolve the pinned subagent:
```swift
        let pinned = live.first { $0.taskLine == task.line }
```
In the row's `HStack`, immediately after the `currentTag()` block (before `Spacer(minLength: 0)`), add:
```swift
                if let pinned {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(FlowStatusGlyph.color(pinned.status))
                            .frame(width: 6, height: 6)
                        Text(pinned.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                    .help("\(pinned.name) is working this task")
                }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Manually verify**

With a run whose subagent names a task by number (e.g. activity mentions "Task 3"), confirm that task's row shows the agent chip, and the same subagent's pill in the strip shows the task title. Confirm a subagent whose text names no task shows in the strip but badges no row.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceOverviewView.swift
git commit -m "Overview: per-task agent badge on the checklist"
```

---

## Self-Review

- **Spec coverage:** "Working now" strip (Task 3), per-task badge (Task 4), `OverviewLiveAgents` + `LiveSubagent` (Task 2), `SubagentTaskPin` (Task 1), reactive `FlowStore` read + `onOpenRunFlow` navigation (Task 3), hide-when-empty (Task 3, `modeA` guard), reduce-motion (Task 3 pill). All spec sections map to a task.
- **Type consistency:** `SubagentTaskPin.line(forAgentText:tasks:)`, `OverviewLiveAgents.subagents(in:workspaceID:tasks:)`, `LiveSubagent` fields, and `LiveSubagentPill(subagent:detail:onOpen:)` are used identically across tasks. `live` is computed once in `modeA` (Task 3, feeding `workingNow`) and threaded `modeA → checklist → phaseSection → taskRow` in Task 4 for the badge — no unused parameters at any task boundary.
- **No placeholders:** every code step carries full code; commands have expected output.
