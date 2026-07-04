# Plan Intake — Parallel / Wait / Integrate — Design

**Date:** 2026-07-04
**Status:** Approved 2026-07-04 (open questions resolved in chat — see Decisions)

## Problem

Throwing a new idea at a project currently forces the user to be the
scheduler: is this independent of what's running? Does it collide with
the Snip! worktree? Should it even be its own plan, or is it really
three more tasks for the plan that's already executing? The user has
to answer all of that before they can even type the idea — the exact
"uhh, I need to wait for this plan to finish before I can send this
prompt" friction this feature removes.

The mechanics already exist: plans run in their own worktrees
(parallel is free), the queue serializes plans that must wait, and
plan docs are live files an agent can re-read. What's missing is the
**decision** — and it should be made by the planning agent, not the
user.

## The disposition model

Every new idea gets one of three dispositions, decided during the
planning session that writes it up:

| Disposition | Meaning | Enactment |
|---|---|---|
| **parallel** | Independent scope — no meaningful overlap with any active plan's territory | New plan file; row appears `ready`; runs in its own worktree whenever the user hits Run (or auto-runs, see Open Questions) |
| **wait** | Overlaps a running/queued plan's territory — same files, same subsystem, or depends on its outcome | New plan file carrying `**Runs:** after <plan path>`; the app auto-enqueues it behind its blocker; sidebar caption `queued · after <title>` |
| **integrate** | Not really a new plan — it's more work for an existing, unfinished plan | The planning agent APPENDS a clearly-marked task group to that plan's file (`### Task N+1: … *(added 2026-07-04)*`); no new file. If that plan is currently running, the app nudges its live agent (Phase 2) |

## How the decision is made

Intake happens **inside the existing New Plan flow** — no second
agent, no post-hoc classifier. The brainstorm/plan kickoff prompt
(`PlanPrompts`) is enriched with an **intake digest** the app
assembles at send time:

- Every non-merged plan: title, relative path, status, feature/branch
  name, remaining task titles (from the parse — cheap and already in
  memory).
- For running plans: the worktree's touched territory —
  `git diff --stat` top-level paths per repo, truncated.
- The queue's current order.

…plus instructions: *decide the disposition; for `parallel`/`wait`
write a new plan with a `**Runs:**` header line; for `integrate`
append a dated task group to the target plan file and write no new
file. State your disposition and why as the final line of your
summary.* The agent has repo access and the digest — it's positioned
to judge overlap far better than filename heuristics.

## Enactment (app side)

DocStore already watches the docs folder; enactment is reactive, not
imperative:

- **New plan with `**Runs:** after <path>`** → `PlanDoc` parses the
  header (same `headerValue` machinery as `**Spec:**`); on discovery,
  the app enqueues it behind its blocker (append after the blocker's
  queue position, starting the queue is still the user's call — the
  gate/queue semantics stay untouched). Sidebar renders the existing
  `blocked by` treatment plus `after <title>` in the row caption.
- **New plan without `**Runs:**`** (or `**Runs:** parallel`) → today's
  behavior: `ready`, run whenever.
- **Appended tasks to an existing plan** → checkbox counts change; the
  row's progress updates on the watcher tick, and the new task rows
  appear in the expansion (already works). A `*(added <date>)*` marker
  in the task title renders a small `new` badge for one session
  (cosmetic, optional).

### Phase 2 — integrating into a RUNNING plan

Appending tasks to a file whose agent already read it needs a nudge:

- The app detects appended tasks on a running plan (totalSteps grew
  while status == running) and sends the feature's agent tab a
  standard prompt via `ClaudePromptDriver`: *"The plan file has been
  updated — new tasks were appended (Task N+1…N+k). Re-read the plan
  and fold them into your remaining work."*
- Send only when the shell is quiescent (existing
  `isShellQuiescent` discipline — a busy agent gets the nudge parked
  and delivered on the next quiet moment; `PlanQueueController`'s
  poller is the natural place to retry).
- **Rail:** never integrate into a plan at a merge gate or
  `awaitingReview` — the planning prompt's instructions say so, and
  the enactment refuses (falls back to `wait` behind it) if it
  happens anyway.

### Phase 2 — course correction (added 2026-07-04)

Corrections are the third intake flow, sharing the nudge machinery: a
completed-looking task turns out wrong (the rope drops the candy but
isn't visually severed) while the agent is phases ahead. Waiting for
the plan to finish, or typing untracked prose into the agent's
terminal, are both failures — corrections must be tracked tasks with
delivery priority.

- **Entry points:** *Course correct…* in the context menu of task
  rows, phase rows, and the plan row — one sheet behind all three.
  The clicked row is the anchor; the plan-level entry (no natural
  anchor, e.g. "the whole game feels stiff") defaults the anchor to
  the phase holding the current task.
- **The sheet:** a text field for the observation plus a delivery
  picker — **Fix now / Fix next / Add to queue**, **default Fix
  next** (finish the current task cleanly, then do the fix before
  anything else; Fix now interrupts mid-task and accepts the
  half-done-worktree risk; Add to queue reaches it in document
  order). Deeper queue semantics (reordering multiple corrections,
  Spotify-style queue management) are deliberately deferred.
- **On send:** a fix-task is written into the plan file under the
  anchor phase — `### Task N.k: Fix — <summary> *(course correction,
  <date>)*` with a checkbox step from the typed text — then the
  running agent gets the quiescence-gated nudge whose wording carries
  the chosen priority. The task is real: it renders in the expansion,
  counts in progress, and the whole-branch review covers it.
- Same rail as integrate: a plan at a merge gate or `awaitingReview`
  refuses course-correct delivery (the fix-task is still written; the
  nudge parks until the plan resumes or the user re-runs it).

## Sidebar surfacing

No new sections. The disposition is visible where work already lives:

- `wait` plans: `queued · after <blocker title>` caption (the queue
  box shows them too, as today).
- `integrate` results: the target plan's task list grows; optional
  `new` badge on appended tasks.
- `parallel`: indistinguishable from any ready plan — that's the
  point.

## Out of scope

- Cross-worktree conflict *resolution* (merging two parallel plans
  that turned out to collide stays a human merge-gate decision).
- Retroactive re-disposition (moving an already-running plan behind
  another).
- Multi-idea batching in one New Plan session.

## Decisions (resolved 2026-07-04)

1. **Auto-run parallel plans:** per-project toggle, **default OFF** —
   parallel plans land `ready` for an explicit Run click until the
   user opts into zero-friction launching.
2. **Phase split:** **two staged plans.** Plan 1: digest +
   disposition + enactment for parallel / wait / integrate-into-idle.
   Plan 2: the live-agent nudge for running plans + course
   correction (added 2026-07-04 — same delivery machinery, so they
   ship together).
4. **Course-correct delivery (resolved in chat):** all three
   priorities ship — Fix now / Fix next / Add to queue — **default
   Fix next**; both row-anchored and plan-level entry points ship in
   v1 (same sheet, anchor is a parameter).
3. **`**Runs:**` grammar: path only** — `after <project-relative
   path>`, parsed with the same token discipline as `**Spec:**`. A
   blocker path that doesn't resolve degrades to plain `ready` with a
   visible `after <missing>` caption, never a silent drop.

## Verification

- Unit: `**Runs:**` parse (path extraction, decoration stripping);
  digest builder (plan inventory + diffstat truncation); enactment
  resolver (new-plan-with-runs → queue position; appended-tasks
  detection; gate/awaitingReview refusal).
- e2e: seed an active plan + drop a `**Runs:** after` plan file into
  docs/ → assert queue order via `queueState`; append tasks to a
  running plan fixture → assert the nudge lands (`terminalText`).
- GUI: captions and badges via the seeded-corpus screenshot flow.
