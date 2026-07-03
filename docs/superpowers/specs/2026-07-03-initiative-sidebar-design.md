# Initiative-Grouped Plans Sidebar — Design

**Date:** 2026-07-03
**Status:** Draft — awaiting approval
**Supersedes:** the sidebar-presentation portions of
`2026-07-02-plans-specs-orchestration-design.md` (its execution model —
run coordinator, ledger, queue, gates — is untouched and remains the
source of truth for how plans run).

## Problem

The Plans & Specs section renders *files*, not *work*. A single request
("build a Game Boy emulator with 3D diorama rendering") produces one
spec, one roadmap, and N phase plans — and today that shows up as:

- each phase plan as its own top-level row, siblings of everything else,
- the spec as another top-level row with a "needs plan" badge (wrong —
  it has plans, they just aren't paired to it),
- the roadmap exiled to a `Docs (1)` accordion,
- and, once running, the same work *again* as a row in the Features
  section below.

The user has to mentally join four presentations of one initiative. The
unit that matters is: **what did I ask for, and how far along is it?**

## The unit: the plan (grouped into initiatives only when needed)

**Plans are the main item.** The sidebar answers "what implementation
plans are cooking, and how far along are they" — a plan row carries
status, progress, and workspace access, and expands to its tasks.

An *initiative* is the grouping that materializes **only when several
plans belong to one request** (a phased roadmap). It holds:

- **0..1 primary spec** (the design doc),
- **1..n plans** — ordered, sequentially blocking,
- **0..n supporting docs** — roadmap, notes that pair with the group.

**Single-plan initiatives render flat**: no grouping row — the plan is
the top-level item, with its spec chip attached. This is the common
case; the extra level exists only where it earns its keep.

A lone spec is a not-yet-planned item ("needs plan"). Docs that
genuinely pair with nothing stay in the loose-docs bucket (hidden when
empty) — a last resort, not a dumping ground.

### Grouping (shape-based, universal — no tool-specific scoping)

Deterministic signals, applied in order; all operate on the existing
`PlanDoc` parse plus filenames:

1. **Backlinks:** a plan's `**Spec:**` reference binds it to that spec.
   Any doc whose body links to a member (relative path match) joins the
   group (this absorbs roadmaps, which link out to their phase plans).
2. **Slug family:** date-prefix-stripped filename stems, after stripping
   a trailing `-design` / `-roadmap` / `-plan` and any `phase-N` /
   `part-N` segment, that share the same stem are one family
   (`x-phase-1.md`, `x-phase-2.md`, `x-design.md` → family `x`).
3. **Title pattern:** plans titled `Phase N: …` sharing signal 1 or 2
   with other members order by `N`; otherwise plans order by
   (date, filename).

Initiative **title**: the primary spec's title (decoration after ` — `
stripped); else the plans' common title prefix; else the humanized
family slug. Initiative **status**: derived, never stored — current
plan = first non-merged plan; progress = checked/total steps summed
across plans.

**Blocking is sequential in v1**: plan *k* is blocked by plan *k−1*.
No dependency syntax, no graphs. The queue already executes a list in
order; the sidebar now just makes that order legible.

## Sidebar design

```
PLANS & SPECS                                              ⟳  +

▾ ▶ Universal File Viewers                      running  18/42
│    ⌘ spec                     ← single-plan initiative: no nesting,
│  ├─ ✓ Task 1: File-kind classifier    the row IS the plan and expands
│  ├─ ▶ Task 2: CSV table view          straight to tasks   ← current
│  └─ ○ Task 3: Media viewers
│
▾ ◐ Game Boy Emulator with 3D Diorama          ▶ plan 2/3 · 41%
│    ⌘ spec · roadmap           ← only a multi-plan family gets the
│  ├─ ✓ 1 · Core — Workspace, SM83…    merged   60/60   grouping level
│  ├─ ▶ 2 · PPU & Rendering            running  12/48
│  └─ ○ 3 · 3D Diorama                 queued · blocked by 2

▸ ◌ Some Other Feature                          needs plan
     ⌘ spec
```

Three levels maximum: initiative → plan → task. Steps never render in
the sidebar — they live in the opened plan doc.

- **Plan row (the main item)** — title + existing `PlanStatus` badge +
  step progress; in a multi-plan family, also its ordinal and a
  `blocked by k` annotation. Click opens the plan doc. Status-scoped
  affordances carry over from today's plan rows: *Run* (ready),
  *Resume* / attention (inProgress), *Merge & Continue* gate card
  (awaitingReview, rendered under the row), **→ workspace** (running —
  activates the feature's workspace and flips to the terminal pane).
  Unread-activity badge from the workspace surfaces as a dot on the
  plan row. Expansion shows the plan's tasks (from `### Task N:`
  headings) with per-task step counts and a *current* pointer (first
  unchecked task).
- **Initiative row (multi-plan families only)** — disclosure; aggregate
  glyph + `plan k/n · pct`. Spec-only items read `needs plan` and offer
  *Write plan* (the existing planning-session kickoff).
- **Doc chips** — one compact line for initiative-level docs (on the
  grouping row, or directly under a flat plan row); a spec that backs
  exactly one plan in a family renders as a chip on that plan's row
  instead. Click opens the doc rendered (existing `onOpenDoc` path).
  No more `Docs` accordion inside an initiative.
- **Queue** — mechanically unchanged (`PlanQueueController` still walks
  an ordered path list with merge gates). A multi-plan initiative gains
  *Run remaining plans*, which enqueues its non-merged plans in order.
  Gate/attention cards anchor to the plan row they concern.

## Features section retirement

Why: a feature is a plan in its running state — the worktree/workspace
is the plan's execution vehicle. With plan rows carrying status,
progress, and workspace access, the Features list is a second,
redundant projection of the same work.

- Plan-backed workspaces are reachable **only** via their plan row
  (activate, unread dot, and the merge/publish/cleanup actions that
  live on feature rows today move to the plan row's context menu).
- Plan-less work items (Add Feature, ⌘⇧T, externally created worktrees
  discovered at startup) live in a compact **Ad hoc** group below the
  initiatives, hidden when empty. Worktree spinning stays exactly as
  powerful — an ad-hoc item is just a run without paperwork.
- Pinned tiles (Signals, Web) and Repositories are unaffected.

**Staged rollout:** Plan 1 ships the initiative section with Features
still present (parity check in the wild); Plan 2 removes Features once
the plan rows demonstrably cover every action the feature rows offer
today. Both plans execute back-to-back; the stage is a safety valve,
not a pause.

## Model & code impact

- `PlanDoc`: parse task headings + per-task steps (title, checked) —
  today only aggregate `checkedSteps/totalSteps` exist.
- `DocStore`: new derived `initiatives: [Initiative]` (grouping above);
  `plans`/`unpairedSpecs`/`otherDocs` remain for compatibility until the
  UI stops using them. Ledger, statuses, watchers unchanged.
- `PlansSpecsSection`: rewritten around initiative → plan → task rows.
- `WorkspaceSidebar`: Features list replaced by the Ad hoc group
  (Plan 2); action parity moves onto plan rows.
- e2e: `state` gains an `initiatives` dump (title, plan paths/statuses,
  doc chips); existing `listDocs`/`runPlan`/queue commands unchanged.

## Out of scope

- Dependency syntax / non-sequential blocking graphs.
- Editing plan checkboxes from the sidebar (read-only projection).
- Renaming the section or restyling the rest of the sidebar.
- Cross-initiative queue interleaving.

## Verification

- Unit: grouping table-tests — lone spec, lone plan, spec+plan pair,
  multi-phase family with roadmap, plan ordering (explicit N vs date),
  unrelated notes staying loose, adversarial slugs (`x-design-2` etc.).
- Unit: PlanDoc task/step parse against the repo's own plan files.
- GUI (e2e): seed a fake multi-phase initiative, assert the `state`
  initiative dump, screenshot expanded/collapsed states, run a plan
  and assert the → workspace affordance activates the right workspace.
- Parity checklist before Features removal: every action available on a
  feature row today, demonstrated on a plan row (activate, merge,
  publish, cleanup, run scoping, unread).
