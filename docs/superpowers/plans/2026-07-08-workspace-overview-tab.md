# Workspace Overview Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every workspace a pinned, non-dismissable **Overview** tab — its home dashboard — that relocates the cursed rail phase/task tree into a full-width, readable surface, and simplify the FLOWS rail into a compact run list.

**Architecture:** A new `WorkspaceOverviewView` renders as the first tab of every workspace's Bonsplit pane. `WorkspaceSession` (already the `BonsplitController` delegate) creates it first, tracks its `overviewTabId`, and vetoes its close via `shouldCloseTab`. The view is a *new front door onto existing state* — plan/phase/task model, run controls, git status, queue/gate — in two modes (plan-backed run vs plain/main). The rail (`PlansSpecsSection`) drops its accordion and becomes compact cards that click-activate a workspace and focus its Overview.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, Bonsplit (vendored), XCTest, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-08-workspace-overview-tab-design.md` (read its Resolved decisions).
- **No new git/session machinery.** The Overview reads existing state only.
- **Readable scale ≥14–15pt** for the Overview and rail (project design principle in `CLAUDE.md` — "Be generous with size and space"): row labels 14–15pt, section headers 13pt, sub-group headers 14pt primary, icons 14–16pt, counts 12–13pt secondary. The relocated checklist matches the Context sub-accordions, NOT the old rail scale.
- Reuse `FlowStatusGlyph` for status glyphs/colors; reuse the shared run controls (`WorkspaceSidebar.runControls(for:)` / the `makeRunControls` closure).
- The Flows graph page (`FlowDetailView`/`FlowsOverviewView`) is **unchanged**.
- Auto-activate: a rail run *with a workspace* → single-click activates it + focuses its Overview; a **not-yet-run plan has no workspace** → click opens the plan doc, Run provisions it. No preview-Overview for un-run plans.
- Queue **stays in the rail**; the per-plan doc-chip (spec/roadmap) line **moves to the Overview header**.
- Overview tab: title `"Overview"`, icon `house.fill`.
- Degrade, never crash. Stage only named files. `swift test --filter X`; e2e reads + verifies screenshots.

## Adaptation ground rules

Anchors verified at HEAD (2026-07-08). Pure helpers carry complete code + tests; view/Bonsplit tasks are anchored sketches, build-gated, verified by e2e screenshots (house style — no unit tests for SwiftUI views).

- `Sources/Dreamux/Models/WorkspaceSession.swift`: `@Observable @MainActor`; `controller: BonsplitController`, `controller.delegate = self` (init ~72); `bootstrapIfNeeded()` (~86) currently does `controller.createTab(title: "shell", icon: "terminal.fill")`; per-kind session maps `tabSessions`/`webTabSessions`/`fileTabSessions`/`diffTabSessions` with `tabSession(for:)` etc.; `extension WorkspaceSession: BonsplitDelegate` (~508) implements `didCreateTab`/`didCloseTab`/`didSplitPane`/`didSelectTab`/`didReceiveFileDrops` — **`shouldCloseTab` is NOT implemented (defaults to `true`)**. `handleDidCreateTab`/`handleDidCloseTab` exist (private).
- `vendor/bonsplit` API: `createTab(title:icon:isDirty:inPane:) -> TabID?`; `selectTab(_:)`; `moveTab(_:toIndex:inPane:)`; `tabs(inPane:) -> [Tab]`; `isTabSelected(_:)`; delegate `splitTabBar(_:shouldCloseTab:inPane:) -> Bool` (default true), `Tab.id: TabID`.
- `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`: `TabContentView` (~77–104) dispatches by session-type lookup (`tabSession(for:)` → terminal, else file/diff/web, else `Color.clear`) — the Overview branch inserts here; `WorkspaceBonsplitPane` (~58) hosts `BonsplitView` + `.onAppear { session.bootstrapIfNeeded() }`.
- `Sources/Dreamux/Views/PlansSpecsSection.swift`: `planRow` (the card), `planMetaLine`, `planActionRow`, `planContextMenu`, `planTasks`/`phaseBlock`/`taskRow` (the accordion to remove), `mainRow`, `queueSection`, `chipLine`/`docChips`, `planBlock` (composes row + chips + gate + tasks), `renderableTasks(plan)`, `chevronColumnWidth`; `PlanPhases.shouldGroup/groups/currentGroupIndex`, `group.phase/.tasks/.checkedSteps/.totalSteps`; `PlanTask.title/.line/.steps/.phaseLine`; `plan.title/.tasks/.checkedSteps/.totalSteps/.fileURL`; `liveFlowDot`/`preferredFlowLane`. Consumes closures from `WorkspaceSidebar` (`onOpenFeature`, `onOpenDocAtLine`, `makeRunControls`, `onRunPlan`, `workspaceForFeature`, `featureName`, `onViewTaskChanges`, gate channels).
- `Sources/Dreamux/Views/ContentView.swift`: `mainPane`, `sidebarMode`, `store.activate(id)`, `openFile(_:)`/`openFile(_:atLine:)`, `gitStatus`/`gitWorktree`/`branchDiffStat`; `WorkspaceSidebar(...)` wiring; `ProjectSession` provides `store`/`docStore`/`planQueue`/`runners`/`repoStore`.
- `Sources/Dreamux/Shell/GitOperations.swift`: `headStatus(in:)` (working-tree +N −M), `branchDiffStat(vs:in:)` (committed merge-base→HEAD, Group-5 helper); `worktreeURL(forBranch:in:)`.
- `PlanQueueController`: `state` (.idle/.running/.atGate/.attention), `currentPlanPath`, `mergeAndContinue()`, `featureNameForPlan(_:)`.
- Reserved main workspace: `store.workspaces.first(where: \.isMain)`, `Workspace.isMain`.

---

## GROUP 1 — Overview tab scaffolding

### Task 1: Pin a non-dismissable Overview tab first per workspace

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`
- Create: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` (placeholder shell this task; filled in Groups 2–3)
- Test: `Tests/DreamuxTests/WorkspaceOverviewTabTests.swift`

**Interfaces:**
- Produces: `WorkspaceSession.overviewTabId: TabID?` (nil until bootstrap); `WorkspaceSession.isOverviewTab(_ id: TabID) -> Bool`; `WorkspaceSession.focusOverview()` (selects the overview tab). `WorkspaceOverviewView(session:store:docStore:planQueue:runners:repoStore:sidebarMode:onOpenDoc:onOpenDocAtLine:...)` — exact params finalized in Group 2; a placeholder init for now.

Semantics:
1. `bootstrapIfNeeded()` creates the Overview tab FIRST (`createTab(title: "Overview", icon: "house.fill")`), stores its id in `overviewTabId`, then creates the shell tab, then re-selects a sensible default (shell, so the terminal is focused on open — the Overview is present but not stealing focus). Actually SELECT the Overview by default? Decision: **select the Overview on open** so the workspace opens on its dashboard (spec intent: the home). Keep the shell available.
2. `shouldCloseTab` returns `false` when `tab.id == overviewTabId` (non-dismissable); `true` otherwise. Add the delegate method to the `BonsplitDelegate` extension (nonisolated + `MainActor.assumeIsolated`, matching the others).
3. Keep it leftmost: on `didCreateTab` for any *other* tab, if the overview isn't at index 0, `moveTab(overviewTabId, toIndex: 0, inPane:)`. (Overview created first already sits at 0; this guards reorders/new tabs — new-tab-position is `.current`, so a tab created while Overview is selected lands after it; the guard covers drags.)
4. `isOverviewTab(_:)` and `focusOverview()` helpers.
5. `TabContentView`: FIRST branch — `if session.isOverviewTab(tabId) { WorkspaceOverviewView(...placeholder...) }` before the terminal/file/diff/web lookups.

- [ ] **Step 1: Failing test** — `WorkspaceOverviewTabTests` (`@MainActor`):
  1. `testBootstrapCreatesOverviewFirstAndNonClosable` — make a `WorkspaceSession` (use the same construction the existing session tests use; if none, construct with a scratch `Workspace`), call `bootstrapIfNeeded()`; assert `overviewTabId != nil`, the pane's `tabs(inPane:)` first tab id == `overviewTabId`, and there are ≥2 tabs (overview + shell).
  2. `testOverviewTabRefusesToClose` — call the delegate `splitTabBar(controller, shouldCloseTab: <overview Tab>, inPane:)` → `false`; and for the shell tab → `true`. (Build the `Tab` via the controller's `tabs(inPane:)`.)
  3. `testIsOverviewTab` — `isOverviewTab(overviewTabId!)` true; a shell tab id false.
  Write full code; follow existing `@MainActor` session-test idioms (check `Tests/DreamuxTests` for a WorkspaceSession/ProjectSession test to mirror construction).

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** per semantics (overviewTabId, bootstrap order, shouldCloseTab, leftmost guard, isOverviewTab/focusOverview; placeholder `WorkspaceOverviewView` = `VStack { Text("Overview") }.frame(maxWidth:.infinity,maxHeight:.infinity)` accepting a `session` for now; TabContentView branch).  - [ ] **Step 4: Green + full `swift test` + `swift build`.**  - [ ] **Step 5: Commit** (stage the 3 files + test): `git commit -m "Overview tab: pinned, non-dismissable, first per workspace"`

- [ ] **Step 6: e2e** — the existing flows/feature scenarios open a workspace; confirm the tab bar now shows an "Overview" tab first (screenshot `02-sidebar-feature` or similar). READ it; the Overview tab must be present, leftmost, and have no close control (or refuse to close). If the default scenario doesn't show it, add an assertion via the e2e tab-summary state.

---

## GROUP 2 — Mode A: plan-backed run dashboard

### Task 2: Resolve the plan behind a workspace (pure)

**Files:**
- Create: `Sources/Dreamux/Models/WorkspacePlanResolver.swift`
- Test: `Tests/DreamuxTests/WorkspacePlanResolverTests.swift`

**Interfaces:**
- Produces:
```swift
enum WorkspacePlanResolver {
    /// The plan a workspace is running, matched by the workspace's branch
    /// name against each plan's resolved feature name. `featureName` is the
    /// SAME resolver the rail uses (ledger record first, else filename-
    /// derived branch) — pass it in so this stays pure/testable.
    static func plan(forWorkspaceNamed name: String, plans: [PlanDoc],
                     featureName: (PlanDoc) -> String?) -> PlanDoc?
}
```
Semantics: return the first plan whose `featureName(plan) == name`; nil if none (→ Mode B). Deterministic (plans already date-ordered by the store).

- [ ] **Step 1: Failing test** — `WorkspacePlanResolverTests`: build 2 `PlanDoc`s (use the `PlanDoc` init the other doc tests use), a `featureName` closure mapping planA→"feat-a", planB→"feat-b"; assert `plan(forWorkspaceNamed: "feat-b", ...) === planB`, `"feat-a" → planA`, `"main" → nil`, empty plans → nil. Full code.
- [ ] **Step 2: Fail.**  - [ ] **Step 3: Implement.**  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** (2 files): `git commit -m "Overview: resolve the plan behind a workspace"`

### Task 3: Overview Mode A — header, progress, checklist, actions

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` (thread the real params into `WorkspaceOverviewView(...)`)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (supply the Overview its dependencies where `WorkspaceBonsplitPane`/tab content is built — pass `docStore`, `planQueue`, `runners`, `repoStore`, the plan `featureName`, `onOpenDoc`/`onOpenDocAtLine`, `makeRunControls`, gate channels, `onRunPlan`)

**Interfaces:**
- Consumes: `WorkspacePlanResolver.plan(forWorkspaceNamed:plans:featureName:)`; `PlanPhases`/`PlanTask`; `makeRunControls(Workspace)`; `branchDiffStat`; gate via `PlanQueueController`.

Spec (Mode A — readable, ≥14–15pt): when `WorkspacePlanResolver.plan(...)` is non-nil for `session.workspace.name`, render a scrollable dashboard:
1. **Header:** `FlowStatusGlyph` + plan title (large, ~20pt semibold), status label + elapsed, branch/worktree name, linked repos.
2. **Spec + progress:** the doc chips (spec/roadmap) as links (`onOpenDoc`); overall `checkedSteps/totalSteps` + a full-width progress bar.
3. **Checklist:** LIFT the rail's `planTasks`/`phaseBlock`/`taskRow` rendering here and **size it up** (14–15pt task text, 14pt phase headers primary, per-phase rollups, current task `← current` highlighted, `onOpenDocAtLine` on click). This is the relocated tree with room. (Copy the logic from `PlansSpecsSection` — Group 4 removes it there.)
4. **Actions row:** `makeRunControls(workspace)`, Open terminal (focus a shell tab / `session.createTab()`), View changes (`branchDiffStat` summary + open diff via the existing `onViewTaskChanges`/diff-tab path), and the **gate card** (review & merge) when `planQueue.state == .atGate && currentPlanPath == thisPlan` (reuse the gate action wiring).

Build-gated; verified by e2e screenshot (Task 8).

- [ ] **Step 1: Implement Mode A** per spec, reusing lifted checklist code sized up.
- [ ] **Step 2: `swift build` + full `swift test`** (unchanged count).
- [ ] **Step 3: Commit** (staged files): `git commit -m "Overview: plan-backed run dashboard (Mode A)"`

---

## GROUP 3 — Mode B (plain workspace) + main mini-dashboard

### Task 4: Overview Mode B — plain workspace

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift`

Spec (Mode B — when `WorkspacePlanResolver.plan(...)` is nil): render a lighter overview:
- **Header:** branch name, linked repos, working-tree status (`+N −M`, clean/dirty via `GitOperations.headStatus(in: worktreeURL)`).
- **Quick actions:** open a shell here (`session.createTab()`), start/stop services (`makeRunControls`), view working-tree changes/diff, and **"Plan something here"** (`onNewPlan`).

- [ ] **Step 1: Implement Mode B.**  - [ ] **Step 2: build + full suite.**  - [ ] **Step 3: Commit:** `git commit -m "Overview: plain-workspace overview (Mode B)"`

### Task 5: main's mini-dashboard (project runs)

**Files:**
- Create: `Sources/Dreamux/Models/ProjectRunsSummary.swift` (pure)
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift`
- Test: `Tests/DreamuxTests/ProjectRunsSummaryTests.swift`

**Interfaces:**
```swift
struct ProjectRun: Identifiable, Equatable {
    let id: String            // plan relative path
    let title: String
    let status: PlanStatus
    let featureName: String?
    let checked: Int
    let total: Int
}
enum ProjectRunsSummary {
    /// Active (non-merged) plans as compact run rows, most-urgent first —
    /// the same rank the rail uses.
    static func runs(plans: [PlanDoc],
                     status: (PlanDoc) -> PlanStatus,
                     featureName: (PlanDoc) -> String?,
                     relativePath: (PlanDoc) -> String) -> [ProjectRun]
}
```
Semantics: map each non-`.merged` plan to a `ProjectRun`; sort by the rail's rank (running→awaiting→ready/inProgress). Pure; injected closures.

Spec: when `session.workspace.isMain`, Mode B additionally renders a **compact list of `ProjectRunsSummary.runs(...)`** — title, status glyph, `checked/total` + mini bar — each row jumping to that run's workspace/Overview (`store.featureWorkspace(named:)` + `store.activate` + focus Overview; if no workspace yet, open the plan doc). Readable scale.

- [ ] **Step 1: Failing test** — `ProjectRunsSummaryTests`: 3 plans with statuses running/awaitingReview/merged → `runs` returns 2 (merged excluded), ordered running-first, with correct titles/counts. Full code.
- [ ] **Step 2: Fail.**  - [ ] **Step 3: Implement summary + wire the main list.**  - [ ] **Step 4: Green + full suite + build.**  - [ ] **Step 5: Commit** (3 files): `git commit -m "Overview: main mini-dashboard of project runs"`

---

## GROUP 4 — Rail simplification

### Task 6: Compact run cards; click activates the Overview

**Files:**
- Create: `Sources/Dreamux/Models/PlanCurrentStep.swift` (pure)
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (the `onOpenFeature`/activation closure focuses the Overview)
- Test: `Tests/DreamuxTests/PlanCurrentStepTests.swift`

**Interfaces:**
```swift
enum PlanCurrentStep {
    /// "Phase 1 · Task 1.10" for the plan's current phase/task, or "Task 3"
    /// when unphased, or nil when nothing is in flight (done/no tasks).
    static func label(for plan: PlanDoc) -> String?
}
```
Semantics: reuse `PlanPhases.shouldGroup`/`groups`/`currentGroupIndex` and the "first task with an unchecked step" rule to build a one-line current-step label. Pure over `plan.tasks`.

Rail changes (`PlansSpecsSection`):
1. `planBlock` no longer renders `planTasks`, the disclosure chevron, the inline `gateCard`, or the `chipLine`. Delete `planTasks`/`phaseBlock`/`taskRow`/`planDisclosure`/`chevronColumnWidth`/`expandedPlans`/`expandedPhaseOverrides` usage (they moved to the Overview). Keep the queue's `gateCard` fallback? — the gate now lives on the Overview; keep only the **queue box** and its Start/Stop.
2. `planRow` becomes the compact card: `FlowStatusGlyph` + title (15pt), `planMetaLine` (status + `checked/total`), the full-width progress bar, a **`PlanCurrentStep.label(for:)`** one-liner ("current: …"), and the action row (`Open`, `Run`/run-controls) — sized per the readable scale.
3. **Single-click the card** → if the plan has a workspace (`workspaceForFeature(name) != nil`) → activate it (`onOpenFeature(name)`) AND focus its Overview; else (not-yet-run) → open the plan doc (`onOpenDoc(plan.fileURL)`). `Run` still launches. The activation closure in `WorkspaceSidebar` (`onOpenFeature`) already does `sidebarMode = .workspace; store.activate(id)` — extend it to also focus the workspace's Overview (`store.session(for: workspace).focusOverview()`).
4. `mainRow` stays (opens the main workspace → its Overview via the same activation).

- [ ] **Step 1: Failing test** — `PlanCurrentStepTests`: a phased plan with phase 1 partially done, current task 1.10 unchecked → `"Phase 1 · Task 1.10"` (assert the exact format your impl produces — pick and pin it); an unphased plan → `"Task N"`; a fully-checked plan → nil. Full code.
- [ ] **Step 2: Fail.**  - [ ] **Step 3: Implement** `PlanCurrentStep` + rail simplification + Overview-focus on activate.
- [ ] **Step 4: Green + full `swift test` (the removed accordion had no unit tests; confirm nothing else referenced the deleted helpers) + `swift build`.**
- [ ] **Step 5: Commit** (staged): `git commit -m "Rail: compact run cards; click opens the workspace Overview"`

---

## GROUP 5 — Polish + e2e

### Task 7: e2e coverage — both modes and the simplified rail

**Files:**
- Modify: `Scripts/e2e/driver.py` (+ `Scripts/e2e/PROTOCOL.md` only if a new state field is added)

Spec: extend the flows/plan scenarios so a plan is running (Mode A) and `main`/a scratch workspace is shown (Mode B). Screenshot: `overview-plan` (Mode A dashboard — header, progress, readable checklist, actions), `overview-main` (Mode B + main mini-dashboard), `rail-compact` (the simplified FLOWS list with compact cards + current-step line, no accordion). Assert via e2e state where possible (the workspace's tab summary includes an Overview tab; the rail no longer emits task rows). READ every screenshot — a passing assertion with a cramped/blank Overview is a failure; iterate.

- [ ] **Step 1: Scenario + full e2e run; READ + describe screenshots; iterate to genuinely green.**
- [ ] **Step 2: full `swift test` once.**
- [ ] **Step 3: Commit** (driver.py [+ PROTOCOL.md]): `git commit -m "Overview + rail: e2e coverage and screenshots"`

---

## Deferred (explicitly NOT this plan)

Preview-Overview for un-run plans; moving the queue out of the rail; changes to the Flows graph page; any new git/session machinery.
