# Plans & Specs Orchestration

**Date:** 2026-07-02
**Status:** Approved
**Supersedes:** `2026-06-12-specs-plans-browser-design.md`

## Problem

Dreamux is feature-forward: the entry point to work is naming a branch,
and the intent behind the work lives nowhere the app can see. The
superpowers workflow inverts this — a spec captures the design, an
implementation plan turns it into checkboxed tasks, and execution is
mechanical — but Dreamux can neither display these documents nor drive
them. The 2026-06-12 browser spec (approved, never built) addressed
display only, placed docs in a main-pane swap, and scanned per-repo
`docs/superpowers/` paths.

Two things changed since: the file tree + editor tabs shipped (docs can
open as tabs — the browser is the editor), and the goal grew from
browsing to orchestration: create, run, and queue plans from the app.

The worktree machinery (provisioning, aggregation symlinks, merge flow,
port isolation) is not the problem and is retained unchanged. What
changes is the entry point: plans become the unit of intent; a feature
worktree becomes the execution vehicle a plan provisions. Ad-hoc
features remain for quick hacks.

## Decision

A project-level `docs/` directory, detected by document shape rather
than superpowers-specific paths, rendered in a collapsible **Plans &
Specs** sidebar section above Features. Plans can be run individually
(provision worktree → drive `claude` in a terminal tab → live checkbox
progress → existing merge flow) or sequentially through a queue with a
user-approved merge gate between plans.

Approaches considered:

- **Sidebar section above Features (chosen)** vs the 2026-06-12
  `SidebarMode.docs` pane swap: docs now open in editor tabs, so a
  dedicated master-detail pane is redundant; the sidebar section keeps
  plans, their progress, and features visible together, which the
  status model needs.
- **Project-level docs home (chosen)** vs per-repo `docs/superpowers/`
  scanning: per-repo docs are invisible to other features until merged,
  and multi-repo projects have no natural home for project-wide
  documents. A single project-level directory, symlinked into every
  feature's aggregation dir, gives every claude session the same view
  and makes checkbox ticks visible to the app instantly, with no merge
  dance. Per-repo scanning can be added later as a read-only source.
- **Detection by shape (chosen)** vs by path: any markdown file
  qualifying as a plan/spec is recognized wherever it sits under
  `docs/`, so superpowers output works natively without Dreamux being
  married to its layout.
- **Execution scope:** single-plan execution *and* queue orchestration
  are both in scope (explicit product decision); auto-merge is not —
  the merge gate is always user-approved in v1.

## Design

### 1. Docs home and provisioning

- `<project>/docs/` alongside `.dreamux/`, with `specs/` and `plans/`
  subdirectories created on demand (first project open, and by any flow
  that writes there). The subdirectories are a default layout, not a
  requirement — discovery scans all of `docs/` recursively.
- `FeatureProvisioner.provision` and `ensureFeatureDirectory` gain a
  relative symlink `features/<feature>/docs` → `<project>/docs`, so
  every agent session reads and writes the same project-level docs. If
  a linked repo is itself named `docs`, the symlink is named
  `project-docs` instead (collision rule, documented in `DREAMUX.md`).
- The generated `DREAMUX.md` gains an instruction block: specs go to
  `docs/specs/YYYY-MM-DD-<topic>-design.md`, plans to
  `docs/plans/YYYY-MM-DD-<topic>.md` — phrasing it as the user
  preference that superpowers' brainstorming/writing-plans skills honor
  over their own defaults.
- The docs dir is not inside any repo's git history in v1 (it can be
  git-inited independently later; out of scope here).

### 2. Discovery — `DocStore` (`Models/DocStore.swift`)

`@MainActor @Observable`, created per project alongside the other
stores, registered with `E2ERegistry`.

- **Scan:** all `*.md` under `<project>/docs/` recursively (hidden
  files and directories skipped).
- **Classification by shape:**
  - *Plan* — H1 ending in `Implementation Plan`, **or** at least one
    `### Task N:` heading with `- [ ]`/`- [x]` checkbox steps beneath
    it.
  - *Spec* — filename ending `-design.md`, **or** referenced by any
    plan's `**Spec:**` header line.
  - *Doc* — any other markdown file (still listed, under a Docs
    disclosure).
- **Parsed per entry:** title (first H1, filename fallback), optional
  `YYYY-MM-DD-` date prefix, and for plans: `**Goal:**` line,
  `**Spec:**` back-link (resolved relative to the plan file), task list
  (`### Task N: <name>`), and progress = checked/total across all
  checkbox steps.
- **Pairing:** a plan and its spec are linked via `**Spec:**` when
  present, else by filename match (spec filename minus `-design`).
  Specs with no plan are *spec-only* — surfaced as actionable.
- **Freshness:** an FSEvents watcher on `<project>/docs/` triggers a
  debounced (500 ms) rescan — this is what makes checkbox ticks from a
  running claude session appear live. A manual refresh affordance also
  exists in the section header.

### 3. Status model (derived — no metadata format invented)

Per plan, computed from files, the run ledger (§5), and git:

| Status | Derivation |
|---|---|
| `specOnly` | spec with no paired plan ("needs plan") |
| `ready` | plan with no live session and no recorded run |
| `inProgress` | recorded run exists, session ended, boxes remain unchecked (resumable) |
| `running` | a live session is linked to the plan via the run ledger |
| `awaitingReview` | all checkbox steps checked, linked branch not merged |
| `merged` | linked branch merged into the default branch (or recorded run's feature closed after completion) |

The run ledger is `.dreamux/plan-runs.json`: an array of
`{planPath, featureName, startedAt}` records written when a plan run
provisions, so plan↔feature links survive relaunch. Records are removed
when their feature is closed without merging.

### 4. Sidebar — Plans & Specs section

In `Views/WorkspaceSidebar.swift`, a collapsible section **above**
Features (collapsed state persisted in `SidebarLayoutStore`):

- **Plan rows:** status glyph, title, progress (`checked/total` with a
  thin progress bar), running indicator (reusing the feature row's
  running-dot pattern), and the paired spec as a small secondary line.
  Hover reveals a Run button (mirroring the feature row's hover
  controls).
- **Spec-only rows:** listed beneath plans with a "needs plan" glyph
  and a hover "Write plan" action (§7).
- **Docs disclosure:** other markdown files under a collapsed "Docs"
  subgroup.
- **Row click** opens the file in the workspace's editor tabs (rendered
  markdown, per the universal-file-viewers spec) via the existing
  `openFileTab(at:)` path; context menu offers Run Plan / Add to Queue
  / Open Raw / Reveal in Finder.
- **Section header:** a `+` (New plan…, §7), a refresh button, and the
  queue entry point (§6).

Ordering: running first, then awaiting review, then ready/in-progress
by date (newest first), merged in a collapsed "Done" subgroup.

### 5. Running a plan

Context-menu or hover **Run Plan** on a `ready`/`inProgress` plan:

1. **Confirm sheet** (reusing `AddFeatureSheet` internals): branch name
   prefilled from the plan slug (date prefix stripped), linked repos
   preselected to all. For `inProgress` plans with a live worktree, the
   sheet becomes "Resume" and skips provisioning.
2. **Provision** via `FeatureProvisioner.provision` (now including the
   docs symlink). Write the run-ledger record.
3. **Launch:** open the feature workspace, create a terminal tab, and
   drive claude with the established prompt-to-file pattern
   (`RunSetupView` precedent): wait for shell quiescence, then send
   `claude "$(cat <promptfile>)"`. The prompt: read
   `docs/plans/<file>`, implement it task-by-task following the plan's
   own execution instructions, tick each `- [ ]` checkbox in the plan
   file as the step completes, and commit as the plan directs. (Plan
   headers already mandate their execution sub-skill; Dreamux adds no
   prompt engineering beyond the checkbox-ticking requirement.)
4. **Progress** comes from the DocStore watcher reading checkbox state;
   **completion** from the existing Stop-hook OSC notification
   (unread badge + banner), flipping status to `awaitingReview` when
   all boxes are checked.
5. **Merge** is the existing `MergeFlow` via the feature's context
   menu; a merged branch flips the plan to `merged`.

### 6. Queue

- **State:** `.dreamux/plan-queue.json` — ordered plan paths plus queue
  status (`idle`, `running`, `atGate`, `attention`) and the current
  entry. Owned by a `PlanQueueController` (`@MainActor @Observable`)
  that composes §5's run machinery; registered with `E2ERegistry`.
- **UI:** a queue subsection at the top of Plans & Specs listing queued
  plans in order (drag to reorder, swipe/context to remove), with a
  Start/Pause button. "Add to Queue" appears on ready plans' context
  menus.
- **Execution:** strictly sequential in v1. Start → run the first plan
  exactly as §5. When it reaches `awaitingReview`, the queue enters
  `atGate` and surfaces a **review gate card** in the queue subsection:
  the plan, its feature, and three actions — *Open feature* (inspect
  the work), *Merge & Continue* (runs `MergeFlow`; on success,
  optionally closes the feature, then auto-starts the next plan), and
  *Stop queue*. No auto-merge in v1.
- **Failure:** if the session's Stop hook fires with boxes unchecked,
  the queue enters `attention` and pauses — the card offers *Resume
  plan* (relaunch claude in the same worktree with a "continue the
  plan" prompt) or *Skip* / *Stop*.
- Manual single-plan runs (§5) remain available while the queue is
  idle, and concurrent independent runs stay possible outside the queue
  — the existing dynamic-port isolation already supports parallel
  worktrees.

### 7. Creation — "New plan…" and "Write plan"

Brainstorming is interactive dialogue, so creation is a terminal, not a
headless run:

- The app gains one **project-scope planning session**: a terminal tab
  hosted in the existing tab/session infrastructure but cwd'd at
  `<project>/` (where `repos/<repo>/<default>/` worktrees and `docs/`
  are visible), created on demand, one per project. If session
  infrastructure currently assumes a workspace, extending it to host
  this workspace-less tab is part of this work.
- **New plan…** (section header `+`): opens the planning session and
  sends a kickoff prompt — use `superpowers:brainstorming`, explore
  `repos/*` read-only, and write the spec (and plan, when the dialogue
  gets there) to `docs/specs/` / `docs/plans/`. The user conducts the
  dialogue in the terminal; the files appear in the sidebar via the
  watcher the moment they're written.
- **Write plan** (on a spec-only row): same session, kickoff prompt is
  `superpowers:writing-plans` against that spec path.

### 8. E2E

New automation commands: `listDocs` (entries with kind, status,
progress, pairing), `runPlan(path)`, `queueState`, and queue
mutation commands (`enqueuePlan`, `startQueue`). Sidebar section state
joins the existing state dump.

## Error handling

- Missing or empty `docs/` is normal — the section shows a short empty
  state explaining the convention, with the New plan… action.
- Malformed plans (checkboxes but no parseable tasks) still list and
  render; progress falls back to raw checkbox counts.
- A plan file deleted mid-run: the row disappears; the session and
  worktree are untouched; the run-ledger record is dropped on the next
  reconcile.
- Queue entries whose plan file vanished are skipped with a Signal
  logged.
- Run-ledger records referencing features that no longer exist are
  pruned at load (same launch-time reconcile pattern as feature
  rediscovery).
- Symlink creation failures during provisioning follow the existing
  rollback behavior in `FeatureProvisioner`.

## Testing

- Unit: DocStore classification (plan/spec/doc by shape), pairing
  (back-link and filename), progress counting, date parsing, status
  derivation (table above, driven by fixture ledger + fake git state),
  queue state machine transitions (including `attention` on incomplete
  stop), run-ledger reconcile.
- Fixtures under `TestSandbox` with real markdown files exercising the
  superpowers conventions and near-miss shapes.
- E2E: fixture project with docs → assert `listDocs`; `runPlan` →
  assert provision + ledger + terminal tab; tick a checkbox on disk →
  assert live progress + `awaitingReview`; queue scenario driving gate
  → merge → auto-advance.

## Out of scope

- Auto-merge at the gate (always user-approved in v1)
- Parallel queue execution
- Per-repo `docs/superpowers/` scanning (future read-only source)
- Git history for the project docs dir
- Parsing review findings / verdicts out of session output
- Feature-forward removal: ad-hoc feature creation stays as-is
