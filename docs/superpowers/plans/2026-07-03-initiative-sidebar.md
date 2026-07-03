# Initiative-Grouped Plans Sidebar — Implementation Plan

**Spec:** docs/superpowers/specs/2026-07-03-initiative-sidebar-design.md — read it first; it is authoritative for grouping rules, hierarchy, and UI semantics.

**Goal:** Rebuild the Plans & Specs section around plans as the main item: task expansion on plan rows, doc chips, initiative grouping for multi-plan families only, queue affordances anchored to rows. Features section stays put in this plan (its retirement is `2026-07-03-features-retirement.md`).

## Global Constraints

- Swift 6 strict concurrency; stores stay `@MainActor @Observable`.
- Native macOS controls over custom chrome; match the sidebar's existing visual language (11pt section headers, `.snappy(duration: 0.18)` disclosure animation, hover-reveal affordances).
- No new dependencies.
- `PlanQueueController`, `PlanRunCoordinator`, `PlanRunLedger`, and `PlanStatus` semantics are untouched — this plan only changes how they're presented.
- e2e server remains inert without `DREAMUX_E2E_SOCKET`; `Scripts/e2e/PROTOCOL.md` stays in lockstep with command/state changes.
- All existing tests keep passing (212 at time of writing).
- Existing callbacks into the section (`onOpenDoc`, `onRunPlan`, `onNewPlan`, `onWritePlan`, `onOpenFeature`, `onEnqueue`, `featureExists`) keep their meanings.

### Task 1: PlanDoc task-level parse

- [ ] **Step 1: Model.** In `Sources/Dreamux/Models/PlanDoc.swift`, add `struct PlanTask: Equatable { let title: String; let steps: [PlanStep] }` and `struct PlanStep: Equatable { let title: String; let checked: Bool }`; give `PlanDoc` a `let tasks: [PlanTask]`.
- [ ] **Step 2: Parse.** Extend `PlanDoc.parse` (same single pass): a line matching `### Task N: <title>` (also accept `### Task N — <title>` and bare `### <title>` after the first task heading) opens a task; `- [ ]` / `- [x]` lines (case-insensitive x, any indent) append steps to the open task, with `**Step k: …**` decoration stripped to the readable title. Checkbox lines before any task heading count toward totals but land in a synthetic untitled task only if any exist. `checkedSteps`/`totalSteps` must remain exactly the sums over parsed steps (keep the existing counters as the source of truth and assert equality in tests).
- [ ] **Step 3: Tests.** In `Tests/DreamuxTests/PlanDocTests.swift`: multi-task fixture with mixed checked states; steps before first heading; em-dash task heading; nested/indented checkboxes; a no-task plan (tasks empty, counts still right). Also parse this repo's own `docs/superpowers/plans/2026-07-02-universal-file-viewers.md` via `RepoFixtures`-style `#filePath` anchoring and assert task count > 3 and counts match aggregates.
- [ ] **Step 4: Run `swift test` — all green.**

### Task 2: Initiative model + grouping in DocStore

- [ ] **Step 1: Model.** New `Sources/Dreamux/Models/Initiative.swift`: `struct Initiative: Identifiable, Equatable { let id: String /* family key */; let title: String; let spec: PlanDoc?; let plans: [PlanDoc] /* ordered */; let supportingDocs: [PlanDoc] }` plus `var isSinglePlan: Bool`, `var needsPlan: Bool` (spec-only).
- [ ] **Step 2: Family key.** Pure helper (static, testable): date-prefix-stripped stem, minus a trailing `-design`/`-roadmap`/`-plan`, minus any `phase-N`/`part-N` segment anywhere in the stem. `2026-07-02-gameboy-phase-1.md` → `gameboy`; `2026-07-02-gameboy-design.md` → `gameboy`.
- [ ] **Step 3: Grouping.** In `DocStore`, derive `private(set) var initiatives: [Initiative]` and `private(set) var looseDocs: [PlanDoc]` inside `refresh()`, applying the spec's signals in order: (1) `**Spec:**` backlink binds plan→spec (existing `pairedSpec(for:)` logic generalized); a `.doc`-kind file whose body contains a member's filename or relative path joins as supporting doc; (2) slug family union; (3) plans ordered by explicit `Phase N` title number, else (date, filename). Title: spec title (strip ` — …`), else common plan-title prefix (≥ 4 chars, word boundary), else humanized family key. Docs pairing with nothing → `looseDocs`. Keep `plans`/`unpairedSpecs`/`otherDocs` working until the UI migrates.
- [ ] **Step 4: Tests.** In `Tests/DreamuxTests/DocStoreTests.swift` (or a new `InitiativeGroupingTests.swift`): lone spec → needsPlan initiative; lone plan → single-plan initiative; spec+plan pair via backlink; 3-phase family + roadmap absorbed via body link; explicit-N ordering beats date order; unrelated `notes.md` stays loose; adversarial slug `x-design-2.md` does NOT join family `x`; two families sharing a date don't merge.
- [ ] **Step 5: Run `swift test` — all green.**

### Task 3: Initiative aggregation resolver

- [ ] **Step 1:** New pure helper (house style of `PlanStatusResolver`) `InitiativeProgress.resolve(statuses: [PlanStatus], checked: Int, total: Int)` → `(currentIndex: Int?, label: String, fraction: Double?)`: current = first non-merged plan; label like `plan 2/3`; fraction = checked/total across plans (nil when total == 0). All merged → current nil, label `done`.
- [ ] **Step 2:** Unit tests: none started, mid-family, all merged, empty-steps plans.
- [ ] **Step 3: Run `swift test` — all green.**

### Task 4: Section rewrite — flat plan rows, task expansion, doc chips

- [ ] **Step 1:** Rework `PlansSpecsSection.rows` to iterate `docStore.initiatives`: single-plan initiatives render one plan row (spec chip line beneath when a spec exists); needs-plan initiatives render today's `specOnlyRow` semantics (hover *Write plan* stays). Merged single-plan initiatives fold into the existing `Done (n)` disclosure. `looseDocs` render behind the existing Docs disclosure, hidden when empty.
- [ ] **Step 2: Plan row.** Keep `docRow` chrome (click opens doc, hover play button for ready/inProgress, context menu with Run Plan…/Add to Queue/Reveal in Finder). Add a leading disclosure chevron that expands to task rows: glyph ✓ (all steps checked) / ▶ (first task with an unchecked step, labeled `← current`) / ○, title, `checked/total` per task, `.caption` secondary styling, indented under the row. Expansion state per plan path in section `@State` (not persisted).
- [ ] **Step 3: Doc chips.** Compact chip line (`⌘ spec · roadmap`-style, `.caption2`, tertiary, hover underline) under the owning row; click routes through `onOpenDoc`. Chip label = doc kind (`spec`, `roadmap` when title contains "roadmap", else first word of title).
- [ ] **Step 4:** Empty-state copy in `emptyState` unchanged; section header/refresh/plus unchanged.
- [ ] **Step 5: Build + existing tests green; add a UI-logic test only if a pure helper emerges (chip labeling is one — test it).**

### Task 5: Multi-plan family rows

- [ ] **Step 1: Grouping row.** For initiatives with ≥ 2 plans: disclosure row with aggregate glyph, title, `plan k/n · pct` (Task 3 resolver), doc-chip line; child plan rows indented with ordinal (`1 ·`, `2 ·`) and, when not runnable because a predecessor isn't merged, a `blocked by k` caption. Expanded state per initiative id in `@State`, default expanded when any child is running/atGate.
- [ ] **Step 2: Blocking is presentational.** A blocked plan's hover-play and context-menu Run stay enabled (the user may know better) but the row shows the annotation; *Run remaining plans* on the grouping row's context menu enqueues non-merged plans in order via `onEnqueue`.
- [ ] **Step 3: Gate anchoring.** Extract today's `gateCardIfAny` so the card renders directly under the plan row whose relative path == `queue.currentPlanPath` when that row is visible in the section; the queue box keeps a fallback copy when the row isn't rendered (e.g. section collapsed states). No queue-controller changes.
- [ ] **Step 4: Build + tests green; screenshot-based sanity via `Scripts/e2e` (`screenshot` command) against a seeded multi-phase family.**

### Task 6: Workspace presence on plan rows

- [ ] **Step 1: Feature-name resolution.** Section gains `let featureName: (PlanDoc) -> String?` (wired in `WorkspaceSidebar` from `docStore.ledger.recordForPlan(path)?.featureName ?? PlanDoc.branchName(forFileName:)` — ledger record wins).
- [ ] **Step 2: → workspace affordance.** On rows whose status is `.running` (and `.awaitingReview`): trailing hover affordance (arrow.right.circle) calling `onOpenFeature(name)`; context menu gains *Open workspace*.
- [ ] **Step 3: Unread dot.** Section gains `let hasUnread: (String) -> Bool` (wired from `store.hasUnread` by feature name); red 5pt dot on the plan row title line, matching `WorkspaceSidebar.nameLine`.
- [ ] **Step 4: Build + tests green.**

### Task 7: e2e observability

- [ ] **Step 1:** `E2ECommands.stateReply()` gains `initiatives`: `[{"title", "id", "specPath"?, "docPaths": [], "plans": [{"path", "status", "ordinal", "tasks": [{"title","checked","total"}]}]}]` using relative paths; `plans` top-level dump stays for compatibility.
- [ ] **Step 2:** Document the new state shape in `Scripts/e2e/PROTOCOL.md` (`state` section).
- [ ] **Step 3:** e2e-driven test isn't runnable in CI — instead unit-test the dump builder by extracting it into a pure helper taking `[Initiative]` + status lookup, returning the dictionary.
- [ ] **Step 4: Run `swift test` — all green.**

### Task 8: Whole-branch verification

- [ ] **Step 1:** Full `swift build` (zero warnings from changed files) + `swift test`.
- [ ] **Step 2:** GUI verification via the e2e harness: seed a project with (a) one single-plan initiative with spec, (b) one 3-phase family with roadmap, (c) a loose notes.md, (d) a merged plan; assert the `state.initiatives` dump matches the grouping table; screenshots of collapsed/expanded initiative, expanded task list, gate card anchored to its row (drive the queue to a gate with a fake-merged plan if feasible, else screenshot the queue box fallback).
- [ ] **Step 3:** Update `docs/superpowers/specs/2026-07-03-initiative-sidebar-design.md` status once merged.
