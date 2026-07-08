# Workspace Overview Tab — Design Spec

**Status:** approved shape, ready for planning (2026-07-08)

## The problem

The FLOWS section of the work-items rail feels "cursed" for structural
reasons, not cosmetic ones:

1. **Three concepts are fused into one list.** A row is at once a *plan
   definition* (what to build), a *live run* (execution state), and a
   *worktree/workspace* (where it lives). Because running a plan mints a
   worktree, the list is secretly also a worktree list — and the `main`
   row is a pure worktree with **no plan** sitting atop plan cards. That
   seam is the confusion.
2. **A ~260px launcher rail is rendering a deep progress tree.** Plan →
   phases → tasks → step-counts fundamentally needs *width*, so everything
   truncates (`README Generator…`, `Phase 0 — Scaffold (…`) and shrinks.
   The narrow column and the deep hierarchy are at war — a surface problem
   that no font/spacing tweak resolves.
3. So the expansion "doesn't sit right" because **it's detail in the wrong
   surface**: the rail is trying to be both a launcher and a progress
   inspector.

The canonical fix is master-detail: a compact list, with full detail on a
dedicated surface when selected (how Conductor and every master-detail tool
work). We already have that surface — every workspace has an always-present
"Welcome"/home tab. We repurpose it.

## Solution

A pinned, **non-dismissable Overview tab** is the home of every workspace —
a full-width, readable dashboard. It **replaces** the rail's inline
phase/task expansion entirely. The rail becomes a compact monitor/launcher;
the detail lives where it has room.

- **Workspace = worktree = a run's home.** Opening a workspace shows its
  Overview, which tells you exactly what it is (its branch, its plan or lack
  thereof). The worktree's identity lives in its Overview, not as ambiguous
  peer rows.
- Two modes, one tab: a **plan-backed run** dashboard, and a **plain
  workspace** overview (for `main` and scratch workspaces).
- The Flows *page* (the dagre graph, "View all") is unchanged — it stays the
  cross-run *shape* view; the Overview is the *one run, readable* view.

### Decisions locked with the user

- The Overview **replaces** the rail's phase/task accordion (not coexist).
- `main`'s Overview also shows a **mini dashboard of the project's plans /
  worktrees** (a project-level view).
- The tab is named **"Overview"**.

## The Overview tab

### Mechanics

- **Pinned, first, non-dismissable.** One Overview tab per workspace,
  created as the workspace's first tab (in place of the current default
  shell/welcome tab). It cannot be closed: a Bonsplit `BonsplitDelegate`
  (`splitTabBar(_:shouldCloseTab:inPane:) -> false` for the overview tab id)
  vetoes closing, and new-tab positioning keeps it leftmost. Title
  "Overview", icon `square.grid.2x2` / `house` (pick during design).
- **Content dispatch.** `TabContentView` gains a branch that renders
  `WorkspaceOverviewView` for the workspace's overview tab id (tracked on
  `WorkspaceSession`, alongside the existing terminal/file/diff/web session
  maps). Simplest: a dedicated `overviewTabId: TabID?` on the session, no new
  session object needed — the view reads live state from the stores.
- **Live.** The view reads Observation-tracked state (docStore plan/status,
  planQueue, runners, git status) so it updates as the run proceeds — no
  manual refresh.
- A shell tab still opens on demand (the `+`/⌘T and the empty-pane
  affordance are unchanged); the Overview is simply always present first.

### Mode A — plan-backed run

Rendered when the workspace is the feature behind a plan (resolved via the
existing `featureName(for:)` / `store.featureWorkspace(named:)` / DocStore
ledger path). Roomy and readable — **≥14–15pt type, matching the Context
sub-accordions**, not the rail's cramped scale.

- **Header:** plan title, live status (running / awaiting review / …) with
  elapsed; branch/worktree name; linked repos.
- **Spec + progress:** spec link (opens the doc), overall `checked/total`
  with a full-width progress bar.
- **Phases → tasks checklist** — the relocated tree, with room:
  - phases as sections with per-phase rollups (`k/n`), the current phase
    open by default;
  - tasks with step counts and the current task highlighted (`← current`);
  - clicking a phase/task opens the plan doc at that heading
    (`onOpenDocAtLine`), same as the rail does today.
- **Actions:** run/stop (the shared run controls), Open terminal, View
  changes / diff (task- and plan-level, reusing `viewTaskChanges` /
  `branchDiffStat`), and the **gate card** (review & merge) when the queue
  is at this plan's gate — the same actions the rail scatters, gathered in
  one roomy place.
- **Session signal:** claude busy/waiting, loop badges (reuse
  `FlowStatusGlyph` / the flow lane for this workspace).

### Mode B — plain workspace (`main`, scratch)

Rendered when the workspace has no plan behind it.

- **Header:** branch name, linked repos, working-tree status (`+N −M`,
  clean/dirty) via `GitOperations.headStatus`.
- **Quick actions:** open a shell here, start/stop the workspace's services
  (run controls), view working-tree changes/diff, and **"Plan something
  here"** (opens the planning session — `onNewPlan`).
- **`main`'s mini dashboard** (project-level): a compact, readable list of
  the project's plans / active runs — title, status, progress — each with a
  jump that activates that run's workspace (and its Overview). This is the
  "what's going on across this project" glance, at a comfortable size. It is
  only shown for the reserved `main` workspace.

## Rail simplification (FLOWS)

With detail relocated, the rail becomes a compact monitor:

- **Drop** `planTasks` (the phase/task accordion), the per-plan disclosure
  chevron, and the inline gate card from the rail. Keep the queue section
  (it's cross-plan) and the doc chip line may stay or fold — decide in
  planning.
- Each run renders as a **compact card**: status glyph, title, progress bar,
  and a single **"current: Phase 1 · Task 1.10"** line (derived from the
  plan's current phase/task). Actions stay: **Open** (activates the
  workspace → its Overview) and Run.
- Clicking the card body (or Open) activates the workspace and focuses its
  Overview tab. Double-click is no longer needed for expansion.
- The `main` row stays as the launcher for the main workspace (opens its
  Overview / Mode B).

## Delivery groups (hand to writing-plans)

1. **Overview tab scaffolding.** `overviewTabId` on `WorkspaceSession`;
   create it first per workspace; Bonsplit delegate vetoes its close and
   pins it leftmost; `TabContentView` renders a placeholder
   `WorkspaceOverviewView`. e2e: the tab exists, is first, has no close
   affordance / refuses to close.
2. **Mode A — plan-backed dashboard.** Header, spec+progress, the roomy
   phases→tasks checklist, and the gathered actions (run/stop, open, diff,
   gate). Reuse the plan/phase/task model and the gate/diff plumbing.
3. **Mode B — plain workspace + `main` mini dashboard.** Header, quick
   actions, and the project plans/runs list for `main`.
4. **Rail simplification.** Strip the accordion/expansion; compact run
   cards with the current-phase/task line; wire Open/click → Overview.
5. **Polish + e2e.** Screenshots of both modes and the simplified rail;
   `flowsState`/e2e coverage for the Overview and the rail change.

## Non-goals

- The Flows graph page (dagre view) is unchanged.
- Plan/spec *files* stay in the Context section (already shipped).
- No new git or session machinery — the Overview is a new front door onto
  existing plan/worktree/queue/diff state.

## Resolved decisions (planning inputs)

- **Auto-activate on single click.** Clicking a run that *has a workspace*
  (running / awaiting review / gated) activates that workspace and switches
  the main pane to its Overview; "Open" is the explicit equivalent. A
  **not-yet-run plan has no workspace**, so clicking it opens the plan doc
  (preview) and **Run** is what provisions the workspace (whose Overview
  then becomes home). This nudges FLOWS toward *runs*; ready plans are
  launched from Context / the Run button. No "preview Overview" for
  un-run plans in this pass.
- **Queue stays in the rail; the doc-chip (spec/roadmap) line moves to the
  Overview header.** The queue is a compact project-level control and not
  the cursed part; the per-plan spec chip is detail that belongs in the
  Overview and keeps the rail card compact.
- **Tab title "Overview", icon `house.fill`.** Short and identical across
  workspaces — the workspace identity is already carried by the project
  header and rail selection.
