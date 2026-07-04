# Intake Phase 2 — Live Nudge & Course Correction — Implementation Plan

**Spec:** docs/superpowers/specs/2026-07-04-plan-intake-design.md (sections "Phase 2 — integrating into a RUNNING plan" and "Phase 2 — course correction"). Prerequisite: `2026-07-04-plan-intake.md` fully merged.

**Goal:** Work can be injected into a plan whose agent is already running: intake-integrate appends detected by the app trigger a re-read nudge, and the user can file **course corrections** from task/phase/plan rows — tracked fix-tasks written into the plan file and delivered with Fix now / Fix next / Add to queue priority (default Fix next), quiescence-gated, never at a merge gate.

## Global Constraints

- Swift 6 strict concurrency; `@MainActor @Observable` stores; no new dependencies.
- All programmatic terminal sends go through the existing quiescence discipline (`isShellQuiescent`, echo-verified typing via `ClaudePromptDriver`) — never type into a streaming agent.
- Plan-file writes are plain text edits the parser round-trips (the fix-task shape must parse as a task with steps under the anchor phase — `PlanDocTests` proves it).
- Gate rail: a plan at `atGate`/`awaitingReview` never receives a nudge; the fix-task is still written and the nudge parks.
- All existing tests keep passing; PROTOCOL.md in lockstep for any e2e additions.

### Task 1: Fix-task writer

- [ ] **Step 1:** New `Sources/Dreamux/Shell/CourseCorrection.swift`: pure functions that, given a parsed `PlanDoc`, an anchor (task line / phase / nil → current phase), a summary, and body text, produce the insertion — `### Task <next dotted number in phase>: Fix — <summary> *(course correction, <date>)*` plus `- [ ] **Step 1: …**` — and the byte-range/line where it goes (end of the anchor phase's task block, before the next `## `). Date injected by caller (no Date.now in pure code paths); dotted-number derivation covers both `Task N` and `Task N.M` schemes.
- [ ] **Step 2:** A `@MainActor` applier that reads the file, applies the insertion, writes atomically, and lets the existing DocStore watcher pick up the change (no manual refresh).
- [ ] **Step 3:** Tests: insertion-point table (mid-phase anchor, last phase, unsectioned plan, plan-level anchor resolving to current phase); numbering (`Task 1.10` after `Task 1.9`, `Task 8: Fix` in integer plans); round-trip (apply → `PlanDoc.parse` shows the new task, counts grow by 1, phase correct).
- [ ] **Step 4: `swift test` green.**

### Task 2: Nudge delivery engine

- [ ] **Step 1:** `Sources/Dreamux/Shell/PlanNudgeCenter.swift` (`@MainActor @Observable`): holds pending nudges keyed by plan path — `{featureName, prompt, createdAt}`. `deliverIfQuiescent(session:)` sends via the same echo-verified pattern `ClaudePromptDriver` uses into the feature's agent tab; retries from `PlanQueueController`'s existing poll tick (additive hook, no state-machine change) and from a session-quiescence check. Gate rail enforced here: skip delivery while the plan's status is `atGate`/`awaitingReview`.
- [ ] **Step 2:** Nudge prompts in `PlanPrompts`: `courseCorrection(taskTitle:priority:)` — Fix now ("pause your current task, do <task> first, then resume"), Fix next ("finish your current task, then do <task> before anything else"), Add to queue ("new task appended; pick it up in order") — and `planUpdated(taskRange:)` for intake-integrate appends.
- [ ] **Step 3:** Appended-task detection for intake-integrate: DocStore refresh callback compares totals for running plans (previous parse vs new); growth without a course-correction marker → `planUpdated` nudge enqueued.
- [ ] **Step 4:** Tests: nudge-center state machine (park → deliver on quiescence, gate rail, no double-delivery), prompt content per priority, growth detection (injected before/after PlanDocs).
- [ ] **Step 5: `swift test` green.**

### Task 3: Course-correct sheet + entry points

- [ ] **Step 1:** `CourseCorrectSheet` (house sheet style, like `NewPlanSheet`): anchor description header, multiline text field, `Picker` — Fix now / Fix next / Add to queue, default Fix next. Submit → fix-task write (Task 1) + nudge enqueue (Task 2) when the plan is running; idle plans just get the task (no nudge).
- [ ] **Step 2:** Entry points in `PlansSpecsSection`: *Course correct…* context-menu item on task rows, phase rows, and the plan row; the clicked row supplies the anchor (plan row → nil anchor → current phase).
- [ ] **Step 3:** Sidebar: fix-tasks render like any task (they are); the appended task's `*(course correction, …)*` suffix renders as-is in v1.
- [ ] **Step 4:** Build + tests green; sheet-open wiring verified in Task 5's GUI pass (context menus aren't harness-drivable).

### Task 4: e2e observability

- [ ] **Step 1:** e2e command `courseCorrect {"plan": <path>, "task"?: <title>, "text": …, "priority": "now|next|queue"}` driving the same code path as the sheet (needed because context menus can't be driven); `state` plan payloads gain `pendingNudges: Int`.
- [ ] **Step 2:** PROTOCOL.md documents both.
- [ ] **Step 3:** Unit tests for the command's parameter resolution; scenario steps in Task 5.
- [ ] **Step 4: `swift test` green.**

### Task 5: Whole-branch verification

- [ ] **Step 1:** Full build (zero warnings from changed files) + suite.
- [ ] **Step 2:** GUI/e2e: run a fixture plan (real agent via runPlan), `courseCorrect` with Fix next → assert the fix-task appears in the plan file and the row expansion (`state` dump), and the nudge lands in the agent's terminal (`terminalText` contains the priority wording) once quiescent; verify the gate rail by driving the queue to `atGate` and confirming the nudge parks (`pendingNudges` stays 1).
- [ ] **Step 3:** Update the spec status once merged.
