# Plan Intake (Phase 1) — Implementation Plan

**Spec:** docs/superpowers/specs/2026-07-04-plan-intake-design.md — authoritative for the disposition model, digest contents, enactment rules, and the resolved Decisions.

**Goal:** New ideas get dispositioned by the planning agent — `parallel` (own worktree, ready), `wait` (`**Runs:** after <path>`, auto-enqueued behind its blocker), or `integrate` (tasks appended to an existing idle plan). The app assembles the intake digest, enriches the New Plan kickoff, parses the disposition, and enacts it. The live-agent nudge for RUNNING plans is Phase 2 (`2026-07-05-intake-live-nudge.md`).

## Global Constraints

- Swift 6 strict concurrency; stores stay `@MainActor @Observable`; no new dependencies.
- `PlanQueueController`'s state machine, gates, and persistence format are untouched except for the one additive API named in Task 4.
- `Scripts/e2e/PROTOCOL.md` stays in lockstep; e2e server inert without the socket env.
- All existing tests keep passing (279 at time of writing).
- The `**Runs:**` header uses the same `headerValue`/token discipline as `**Spec:**`; a blocker path that doesn't resolve degrades to plain `ready` with a visible `after <missing>` caption — never a silent drop, never a crash.

### Task 1: `**Runs:**` header parse

- [ ] **Step 1:** `PlanDoc` gains `let runsAfter: String?` (the blocker's raw relative path) parsed from a `**Runs:** after <path>` header line via the existing `headerValue` + `specPathToken` machinery; `**Runs:** parallel` and an absent header both yield nil. Default-nil in the memberwise/explicit init so existing construction sites compile.
- [ ] **Step 2:** Tests in `PlanDocTests`: `after` with trailing prose/qualifiers (token survives), `parallel`, absent, malformed (`**Runs:** whenever` → nil).
- [ ] **Step 3: `swift test` green.**

### Task 2: Intake digest builder

- [ ] **Step 1:** New `Sources/Dreamux/Shell/IntakeDigest.swift`: a pure formatter `IntakeDigest.render(plans: [(title: String, path: String, status: PlanStatus, feature: String?, remainingTasks: [String])], territories: [String: [String]], queue: [String]) -> String` producing a compact fenced block — per plan one line (`- <title> — <status>, <path>, feature <name>`) plus up to 6 remaining task titles (then `… +N more`), per running plan a `touches: <top-level paths>` line, then the queue order. Deterministic ordering, hard length cap (~2 KB) with truncation markers.
- [ ] **Step 2:** Async assembly lives beside it: gather plan inventory from `DocStore` (already in memory) and, for running plans, `git -C <worktree> diff --stat` top-level paths per repo via `GitOperations` (add a small helper if none fits); tolerate missing worktrees (skip, don't fail).
- [ ] **Step 3:** Tests: formatter table-tests (truncation, empty inventory, no running plans); assembly tested with an injected diffstat closure.
- [ ] **Step 4: `swift test` green.**

### Task 3: Kickoff prompt enrichment

- [ ] **Step 1:** `PlanPrompts.brainstormKickoff` (and the write-plan kickoff) gain an optional `intakeDigest: String?` parameter; when present, the prompt carries the digest plus disposition instructions verbatim from the spec's "How the decision is made" section: decide parallel/wait/integrate; new file with `**Runs:**` header for parallel/wait; append a dated task group (`### Task N+1: … *(added <date>)*`) to the target plan file for integrate and write no new file; NEVER integrate into a plan at a merge gate or awaiting review; state the disposition and reasoning as the final summary line.
- [ ] **Step 2:** `WorkspaceSidebar.openPlanningSession` call sites pass the digest (assembled at send time; empty inventory → nil digest → prompt identical to today).
- [ ] **Step 3:** Tests in `PlanPromptsTests`: digest included when present, byte-identical prompt when nil, instructions mention all three dispositions and the gate rail.
- [ ] **Step 4: `swift test` green.**

### Task 4: Enactment — auto-enqueue behind the blocker

- [ ] **Step 1:** `PlanQueueController` gains one additive API: `ensureQueued(_ path: String, after blockerPath: String)` — inserts `path` immediately after the blocker's position (blocker queued) or appends blocker-then-path? NO: never enqueue the blocker implicitly; if the blocker is not in the queue and not running, insert `path` at the end and let status captions carry the relationship. Idempotent (no duplicates), persisted like `enqueue`.
- [ ] **Step 2:** Wiring in `ProjectSession`: on `DocStore` refresh (the existing watcher path), any plan whose `runsAfter` resolves to a known, non-merged plan and that isn't yet queued/running/merged gets `ensureQueued(after:)`. A `runsAfter` pointing at a merged plan or at nothing enacts nothing (caption still renders per Task 5).
- [ ] **Step 3:** Tests: `PlanQueueControllerTests` for `ensureQueued` (positioning, idempotence, persistence); an integration-style test for the refresh wiring using on-disk fixtures (blocker running → new plan lands behind it; blocker merged → not enqueued).
- [ ] **Step 4: `swift test` green.**

### Task 5: Sidebar caption + auto-run toggle

- [ ] **Step 1:** Plan rows with `runsAfter` render a caption `after <blocker title>` (resolved via DocStore; `after <filename> (missing)` when unresolved) alongside the existing status label — same `.caption` styling as `blocked by k`.
- [ ] **Step 2:** Per-project auto-run toggle: a persisted flag on `SidebarLayoutStore` (matches its existing per-project persistence), surfaced as a checkbox in the New Plan sheet footer ("Run parallel plans automatically"). When ON and a fresh plan appears with no `runsAfter` and a stated-parallel disposition (header `**Runs:** parallel` — require the explicit header, absence stays manual), enact `runPlan` via `PlanRunCoordinator` with the derived branch and all repos.
- [ ] **Step 3:** Tests: caption resolution (pure helper); toggle persistence; auto-run decision logic as a pure predicate (`IntakeEnactment.shouldAutoRun(doc:toggle:) -> Bool`) covering: header present+toggle on → run, toggle off → no, `runsAfter` present → never.
- [ ] **Step 4: `swift test` green.**

### Task 6: e2e observability

- [ ] **Step 1:** `state`'s plan payloads (flat and initiatives) gain `runsAfter` (omitted when nil); `queueState` unchanged.
- [ ] **Step 2:** PROTOCOL.md documents the field and the enactment (drop a `**Runs:** after` file → it self-enqueues behind its blocker on the next watcher tick).
- [ ] **Step 3:** Unit test via `E2EStateDump` helper; e2e scenario steps belong to Task 7's GUI pass.
- [ ] **Step 4: `swift test` green.**

### Task 7: Whole-branch verification

- [ ] **Step 1:** Full build (zero warnings from changed files) + suite.
- [ ] **Step 2:** GUI/e2e pass: seed a running plan (runPlan on a fixture), drop a `**Runs:** after` plan file → assert queue order via `queueState` and the `after <title>` caption via screenshot; drop an integrate-style appended task group onto an idle plan → assert its task rows grew; verify the New Plan sheet shows the auto-run toggle.
- [ ] **Step 3:** Update the spec status once merged.
