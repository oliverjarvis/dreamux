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

## The unit: Initiative

An *initiative* is a group of related docs representing one requested
feature:

- **0..1 primary spec** (the design doc),
- **0..n phases** — plan docs, ordered, sequentially blocking,
- **0..n supporting docs** — roadmap, notes that pair with the group.

A lone spec is an initiative in its earliest state ("needs plan"). A
lone plan is an initiative with no spec. Docs that genuinely pair with
nothing stay in the loose-docs bucket (hidden when empty) — it becomes
a last resort, not a dumping ground.

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
   with other members order by `N`; otherwise phases order by
   (date, filename).

Initiative **title**: the primary spec's title (decoration after ` — `
stripped); else the phases' common title prefix; else the humanized
family slug. Initiative **status**: derived, never stored — current
phase = first non-merged phase; progress = checked/total steps summed
across phases.

**Blocking is sequential in v1**: phase *k* is blocked by phase *k−1*.
No dependency syntax, no graphs. The queue already executes a list in
order; the sidebar now just makes that order legible.

## Sidebar design

```
PLANS & SPECS                                              ⟳  +

▾ ◐ Game Boy Emulator with 3D Diorama          ▶ phase 2/3 · 41%
│    ⌘ spec · roadmap                    ← doc chips, click = open
│
├─ ✓ 1 · Core — Workspace, Cartridge, SM83…     merged   60/60
│
├─ ▾ ▶ 2 · PPU & Rendering                      running  12/48
│      unblocked by ✓1 · blocks 3
│    ├─ ✓ Task 1: Background tiles                        6/6
│    ├─ ▶ Task 2: Sprite pipeline        ← current        3/9
│    ├─ ○ Task 3: Window layer                            0/7
│    └─ ○ Task 4: DMA + OAM                               0/5
│
└─ ○ 3 · 3D Diorama                             queued · blocked by 2

▸ ◌ Some Other Feature                          needs plan
     ⌘ spec
```

- **Initiative row** — disclosure; aggregate glyph + `phase k/n · pct`;
  spec-only initiatives read `needs plan` and offer *Write plan* (the
  existing planning-session kickoff).
- **Doc chips** — one compact line under the title for initiative-level
  docs; a spec that backs exactly one phase renders as a chip on that
  phase row instead. Click opens the doc rendered (existing `onOpenDoc`
  path). No more `Docs` accordion inside an initiative.
- **Phase row** — ordinal + title + existing `PlanStatus` badge + step
  progress. Click opens the plan doc. Status-scoped affordances carry
  over from today's plan rows: *Run* (ready), *Resume* / attention
  (inProgress), *Merge & Continue* gate card (awaitingReview, rendered
  under the phase row), **→ workspace** (running — activates the
  feature's workspace and flips to the terminal pane). Unread-activity
  badge from the workspace surfaces as a dot on its phase row.
- **Phase expansion** — tasks from the plan's `### Task N:` headings
  with per-task step counts and a *current* pointer (first unchecked).
  A task row expands one level further to its individual `- [ ]` steps,
  so every step is reachable without dumping 60 rows into the sidebar
  by default. (Decision point: if two disclosure levels feels fussy,
  v1 can ship task rows only — steps are always visible in the opened
  plan doc.)
- **Queue** — mechanically unchanged (`PlanQueueController` still walks
  an ordered path list with merge gates). The initiative row gains
  *Run remaining phases*, which enqueues its non-merged phases in
  order. Gate/attention cards anchor to the initiative.

## Features section retirement

Why: a feature is a plan in its running state — the worktree/workspace
is the plan's execution vehicle. With phase rows carrying status,
progress, and workspace access, the Features list is a second,
redundant projection of the same work.

- Plan-backed workspaces are reachable **only** via their phase row
  (activate, unread dot, and the merge/publish/cleanup actions that
  live on feature rows today move to the phase row's context menu).
- Plan-less work items (Add Feature, ⌘⇧T, externally created worktrees
  discovered at startup) live in a compact **Ad hoc** group below the
  initiatives, hidden when empty. Worktree spinning stays exactly as
  powerful — an ad-hoc item is just a run without paperwork.
- Pinned tiles (Signals, Web) and Repositories are unaffected.

**Staged rollout:** Plan 1 ships the initiative section with Features
still present (parity check in the wild); Plan 2 removes Features once
the phase rows demonstrably cover every action the feature rows offer
today. Both plans execute back-to-back; the stage is a safety valve,
not a pause.

## Model & code impact

- `PlanDoc`: parse task headings + per-task steps (title, checked) —
  today only aggregate `checkedSteps/totalSteps` exist.
- `DocStore`: new derived `initiatives: [Initiative]` (grouping above);
  `plans`/`unpairedSpecs`/`otherDocs` remain for compatibility until the
  UI stops using them. Ledger, statuses, watchers unchanged.
- `PlansSpecsSection`: rewritten around initiative → phase → task rows.
- `WorkspaceSidebar`: Features list replaced by the Ad hoc group
  (Plan 2); action parity moves onto phase rows.
- e2e: `state` gains an `initiatives` dump (title, phase paths/statuses,
  doc chips); existing `listDocs`/`runPlan`/queue commands unchanged.

## Out of scope

- Dependency syntax / non-sequential blocking graphs.
- Editing plan checkboxes from the sidebar (read-only projection).
- Renaming the section or restyling the rest of the sidebar.
- Cross-initiative queue interleaving.

## Verification

- Unit: grouping table-tests — lone spec, lone plan, spec+plan pair,
  multi-phase family with roadmap, phase ordering (explicit N vs date),
  unrelated notes staying loose, adversarial slugs (`x-design-2` etc.).
- Unit: PlanDoc task/step parse against the repo's own plan files.
- GUI (e2e): seed a fake multi-phase initiative, assert the `state`
  initiative dump, screenshot expanded/collapsed states, run a phase
  and assert the → workspace affordance activates the right workspace.
- Parity checklist before Features removal: every action available on a
  feature row today, demonstrated on a phase row (activate, merge,
  publish, cleanup, run scoping, unread).
