# Flows Group 5 — Gate Action Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plan lane whose gate node is `waiting` renders an expanded action card — branch-vs-base diff stat, `[view diff]` into the existing diff tab, `[merge & continue]` into `PlanQueueController.mergeAndContinue` / the existing merge-sheet channel — in both the overview lane and the zoom inspector. Plus the deferred aggregates decision: the Flows tile badge unifies with the board's counts. e2e drives a real plan to `atGate` and screenshots both surfaces.

**Architecture:** No new stores, no new git *machinery* — one new read-only git helper (`branchDiffStat`, the numbers the card displays) and one new pure predicate (`PlanFlowBuilder.isGateMergeActionable`, whether the card may offer merge). All actions are closures injected from `ContentView` (bundled in a small `FlowGateActions` struct), landing on channels that already exist and are already tested: diff tabs via `WorkspaceSession.openDiffTab`, merge via `PlanQueueController.mergeAndContinue` → `requestMerge` → `pendingGateMergeWorkspaceID` → WorkspaceSidebar's sheet. The card itself is one shared SwiftUI view (`GateActionCard`) embedded by both `FlowLaneView` and `FlowDetailView`, so overview and zoom can't drift. Views never mutate stores.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, XCTest for the pure/git layers (real-git sandbox tests, house style of `GitCommitLogTests`), e2e via the unix-socket NDJSON harness (`Scripts/e2e/driver.py`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-flows-observatory-design.md`, "Gate cards" section + delivery group 5. Groups 1–3 are merged; Group 4 (loop detection) executes BEFORE this plan per the user's ordering — expect its lane/detail-view loop-badge additions to be present and re-verify line anchors (they are orthogonal to this work; file-level anchors below were verified at main `96b1341`).
- The card renders ONLY when the lane's gate node has `status == .waiting` (plan lanes are the only lanes with a gate node). The board's bubbled `effectiveStatus` plays no part in the render condition.
- Diff stat is fetched ONCE on card appearance (`.task`, cached in view `@State`). No new poller; a stat that is seconds stale is acceptable — the card is rare and short-lived.
- Actions are injected closures from `ContentView`; no view reaches git or mutates a store directly. `mergeAndContinue` guards `state == .atGate` internally (`PlanQueueController.swift:202`) — the glue routes non-queue reviews through `pendingGateMergeWorkspaceID` instead (both paths end at the same merge sheet).
- Native macOS controls for the card's buttons (`.bordered`/`.borderedProminent`, `.controlSize(.small)`) — no custom-painted buttons.
- `PlansSpecsSection`'s existing gate affordances (its `gateCard()`, Resume/Skip) are UNTOUCHED — the Flows card is an additive second front door, same as spec decision 3 treated plan rows.
- Stores/pure types: no new package dependencies; commits stage ONLY named files (never `git add -A`); parallel sessions may touch the repo.
- Run tests with `swift test --filter <TestClassName>`; run the full suite + `swift build` before each commit of an integration task.
- e2e: screenshots capture native SwiftUI fine; the harness has NO click synthesis — button *presses* are not e2e-testable (see Task 5 for what is asserted instead, and Deferred for why no `gateMerge` command).

## Adaptation ground rules (integration tasks 2, 3, 4, 5)

Task 1 and Task 2's pure predicate contain complete code — transcribe. The view/glue/e2e work modifies large existing files; those code blocks are sketches with verified anchors: adapt names to what you find (especially after Group 4 merges), and if an anchor doesn't exist in the described shape, STOP and report NEEDS_CONTEXT. Verified anchors as of `96b1341`:

- Merge channel: `ProjectSession.pendingGateMergeWorkspaceID` (`Models/ProjectSession.swift:39`); `planQueue.requestMerge` wiring at `:212-223` (parks BOTH the e2e bridge's `pendingMergeWorkspaceID` and the bundle channel); `ContentView` passes `gateMergeWorkspaceID: $session.pendingGateMergeWorkspaceID` at `ContentView.swift:135`; `WorkspaceSidebar` adopts it via `.onChange(of: gateMergeWorkspaceID)` at `Views/WorkspaceSidebar.swift:178-183` → `pendingMerge` → the merge sheet at `:90`.
- Queue: `PlanQueueController.mergeAndContinue()` (`Models/PlanQueueController.swift:202`, guards `state == .atGate`); `featureNameForPlan` injected closure (`:22`); `tick()`'s `(.running, .awaitingReview) → .atGate` at `:258-265` — synchronous on the e2e `queueState` command (`E2ECommands.handleQueueState`, `E2E/E2ECommands.swift:656`, ticks before replying); `statusForPlan` wiring calls `docStore.refresh()` itself (`ProjectSession.swift:122-130`), so a plan-file rewrite is visible on the very next `queueState`.
- Status derivation: `PlanStatusResolver.status` (`Models/PlanStatus.swift:42`): `awaitingReview` = ledger record + all boxes checked + feature workspace exists.
- Diff front door: `CommitTrailPopover.swift:66-75` — `GitOperations.mergeBase(of: base, in: worktree) ?? base` → `DiffRequest(worktreeURL:fromRevision:toRevision:"HEAD":title:)`; `DiffRequest` in `Models/DiffTabSession.swift:7`; multi-repo per-repo diff-tab loop idiom in `WorkspaceSidebar.openTaskDiff` (`:844-866`, resolves `GitOperations.worktreeURL(forBranch:in:)` per linked repo, activates the workspace, opens via `store.session(for:).openDiffTab`).
- Git helpers: `Sources/Dreamux/Shell/GitOperations.swift` — `mergeBase(of:in:)` `:809`, `worktreeURL(forBranch:in:)` `:642`, `headStatus(in:)` `:660` (its `--numstat` summing loop at `:666-677` is the parse this plan's helper mirrors; binary files report `-` and `Int()` skips them), `GitHeadStatus` struct `:632`, `runGit` throwing static used directly by tests.
- Builder: `PlanFlowBuilder` (`Models/PlanFlowBuilder.swift`) — gate node `FlowNode(id: "gate", kind: .gate, label: "review & merge", status: .waiting)` at `:68-70`; `needsHuman = status == .awaitingReview || (isCurrentQueuePlan && (queueState == .atGate || .attention))` at `:46-47`; `PlanLaneInput` fields `:15-25`; lane id `"plan-<planPath>"`.
- Views: `FlowLaneView` — needs-you chip renders as a SIBLING below the tappable header+pipeline block (`Views/FlowLaneView.swift:58-60`; the card must be a sibling too, outside the `onTapGesture { onZoom?() }` area at `:56`); `FlowStatusGlyph` shared vocabulary `:7-27`. `FlowsOverviewView` — init takes `flows`/`planLaneInputs`/`$zoomedLaneID`/4 closures (`Views/FlowsOverviewView.swift:7-21`); `board` computed var `:25-30`; `lanesList` `:126-135`; zoom branch constructs `FlowDetailView` `:34-53`. `FlowDetailView` — `selectedNodeID` `@State` `:15`; `nodeInspector(_:)` `:202-257`; `.onAppear { pulsing = true }` `:50`.
- Glue: `ContentView` — `.flows` arm `:303-322`; `planLaneInputs()` `:663` (delegates to `PlanLaneAssembler.inputs(docStore:queue:store:)`, `Models/PlanLaneAssembler.swift:13` — `@MainActor`, also used by e2e `flowsState`); `openDiffTab(_:)` `:706` is ACTIVE-workspace-bound (the gate glue activates the target workspace first, mirroring `openTaskDiff`, rather than reusing it); worktree-resolution idiom `resolveGitStatus()` `:598-614`; `repoStore.repositories`, `store.workspaces`, `session`, `planQueue`, `docStore` all in scope.
- Sidebar badge: `WorkspaceSidebar.tileRow` flows badge at `:443-450` reads `flows.aggregates` (session lanes only — the divergence Task 4 ends); the view already holds `store`, `docStore`, `flows`, `planQueue` (`:10-21`); `badgeText` helper `:474`.
- e2e: `E2ECommands.flowsState` `:677` (returns `lanes` + `planLanes` built from the same `PlanLaneAssembler`+`PlanFlowBuilder`, plus store-aggregate `running`/`needsYou`); `flowLanePayload` `:700`; `zoomFlow` `:721` (works for any lane id, including plan lanes); queue commands `enqueuePlan`/`startQueue`/`stopQueue`/`queueState` `:102-108`. `driver.py`: `SCENARIOS` list `:1081`; helpers `worktree(repo,branch)` `:392`, `git(*args,cwd)` `:85`, `PROJECT_DIR` `:64`, `d.wait_until`/`d.screenshot`/`d.cmd`; driver-side commit-in-worktree pattern `scenario_merge_and_cleanup:696-702`; no existing scenario drives the queue commands — Task 5's is the first. Fake claude: `DREAMUX_CLAUDE_BIN=$ROOT/Tests/Fixtures/bin/claude` exported in `run-e2e.sh:62`.

---

### Task 1: `GitOperations.branchDiffStat` — the card's numbers

**Files:**
- Modify: `Sources/Dreamux/Shell/GitOperations.swift` (new struct + extension func, after the `GitHeadStatus` extension ending `:685`)
- Test: `Tests/DreamuxTests/GitCommitLogTests.swift` (append — its sandbox/`makeRepo`/`commit`/`write` helpers are exactly what these tests need; update the class doc comment's "three primitives" phrasing)

**Interfaces:**
- Consumes: `GitOperations.mergeBase(of:in:)`, `runGit`.
- Produces (Tasks 2/3 rely on these exact names):
  - `struct GitBranchDiffStat: Equatable, Sendable { var insertions: Int; var deletions: Int; var filesChanged: Int }`
  - `static func branchDiffStat(vs baseBranch: String, in worktreeURL: URL) async -> GitBranchDiffStat?`
- Semantics: committed branch-vs-base totals from the merge-base fork point (`git diff --numstat <mergeBase> HEAD`). Uncommitted work is excluded — the card describes what a merge would bring, and the merge flow merges commits. Unresolvable base → `nil`; on the base branch itself → all-zeros (not nil).

- [ ] **Step 1: Write the failing tests**

Append to `GitCommitLogTests`:

```swift
    // MARK: - testBranchDiffStatTotalsAcrossCommitsAndFiles

    /// The gate card's stat must span the WHOLE branch (merge-base →
    /// HEAD), not just HEAD's own diff, and count a binary change as a
    /// changed file without poisoning the line totals.
    func testBranchDiffStatTotalsAcrossCommitsAndFiles() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("one\ntwo\nthree\n", to: "a.txt", in: repoURL)
        _ = try await commit("Main commit", in: repoURL)

        let featWorktree = sandbox.root.appendingPathComponent("repo-feat", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["worktree", "add", "-b", "feat", featWorktree.path], in: repoURL)
        // Two commits: modify a.txt (+1 −1), then add b.txt (+2) and a
        // binary (a changed file with no countable lines).
        try write("one\nTWO\nthree\n", to: "a.txt", in: featWorktree)
        _ = try await commit("Feat commit 1", in: featWorktree)
        try write("b1\nb2\n", to: "b.txt", in: featWorktree)
        try writeBinary(Data([0, 1, 2]), to: "c.bin", in: featWorktree)
        _ = try await commit("Feat commit 2", in: featWorktree)

        let maybe = await GitOperations.branchDiffStat(vs: "main", in: featWorktree)
        let stat = try XCTUnwrap(maybe)
        XCTAssertEqual(stat.insertions, 3)   // 1 in a.txt + 2 in b.txt
        XCTAssertEqual(stat.deletions, 1)
        XCTAssertEqual(stat.filesChanged, 3) // a.txt, b.txt, c.bin
    }

    // MARK: - testBranchDiffStatIgnoresUncommittedAndBaseDrift

    /// Two exclusions in one fixture: a dirty (uncommitted) edit in the
    /// feature worktree must not count — the merge flow merges commits —
    /// and a base branch that moved on after the fork must not reverse
    /// its own commits into the stat (fork point, not base tip).
    func testBranchDiffStatIgnoresUncommittedAndBaseDrift() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("v1\n", to: "app.txt", in: repoURL)
        _ = try await commit("Main commit", in: repoURL)

        let featWorktree = sandbox.root.appendingPathComponent("repo-feat", isDirectory: true)
        _ = try await GitOperations.runGit(
            ["worktree", "add", "-b", "feat", featWorktree.path], in: repoURL)
        try write("f1\n", to: "f1.txt", in: featWorktree)
        _ = try await commit("Feat commit", in: featWorktree)

        // Dirty edit on the branch + main moving on after the fork.
        try write("f1\nlocal-uncommitted\n", to: "f1.txt", in: featWorktree)
        try write("v2\nv2b\n", to: "app.txt", in: repoURL)
        _ = try await commit("Main commit after fork", in: repoURL)

        let maybe = await GitOperations.branchDiffStat(vs: "main", in: featWorktree)
        let stat = try XCTUnwrap(maybe)
        XCTAssertEqual(stat.insertions, 1, "committed f1.txt line only")
        XCTAssertEqual(stat.deletions, 0)
        XCTAssertEqual(stat.filesChanged, 1)
    }

    // MARK: - testBranchDiffStatUnknownBaseAndOnBaseItself

    /// Unresolvable base → nil (the card shows no stat line rather than
    /// lying); sitting ON the base branch → an all-zeros stat, not nil
    /// (merge-base of HEAD with itself is HEAD — an empty diff is a
    /// true answer, and multi-repo callers sum stats per repo).
    func testBranchDiffStatUnknownBaseAndOnBaseItself() async throws {
        let repoURL = try await makeRepo(named: "repo")
        try write("v1\n", to: "app.txt", in: repoURL)
        _ = try await commit("Main commit", in: repoURL)

        let unknown = await GitOperations.branchDiffStat(vs: "no-such-branch", in: repoURL)
        XCTAssertNil(unknown)

        let onBase = await GitOperations.branchDiffStat(vs: "main", in: repoURL)
        XCTAssertEqual(onBase, GitBranchDiffStat(insertions: 0, deletions: 0, filesChanged: 0))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitCommitLogTests`
Expected: compile FAILURE — `cannot find 'branchDiffStat'` / `cannot find 'GitBranchDiffStat' in scope`.

- [ ] **Step 3: Write the implementation**

In `GitOperations.swift`, after the header-status extension (`:685`), mirroring `headStatus`'s numstat parse:

```swift
// MARK: - Gate card diff stat

/// Committed branch-vs-base totals for the Flows gate card: everything
/// a merge of this branch would bring, summed from the merge-base fork
/// point to HEAD. Working-tree changes are deliberately excluded (the
/// merge flow merges commits; `GitHeadStatus` covers the dirty tree).
struct GitBranchDiffStat: Equatable, Sendable {
    var insertions: Int
    var deletions: Int
    var filesChanged: Int
}

extension GitOperations {
    /// `git diff --numstat <mergeBase> HEAD` summed. Nil when the base
    /// doesn't resolve (deleted branch, unrelated histories) — the card
    /// then omits its stat line rather than showing zeros it can't
    /// stand behind. On the base branch itself the diff is empty and
    /// the result is a true all-zeros.
    static func branchDiffStat(vs baseBranch: String, in worktreeURL: URL) async -> GitBranchDiffStat? {
        guard let base = await mergeBase(of: baseBranch, in: worktreeURL),
              let numstat = try? await runGit(
                ["diff", "--numstat", base, "HEAD"], in: worktreeURL)
        else { return nil }
        var insertions = 0
        var deletions = 0
        var files = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            files += 1
            // Binary files report "-" for both counts; Int() skips them
            // but the file still changed.
            insertions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
        }
        return GitBranchDiffStat(insertions: insertions, deletions: deletions, filesChanged: files)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitCommitLogTests`
Expected: PASS (existing 11 + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/GitOperations.swift Tests/DreamuxTests/GitCommitLogTests.swift
git commit -m "Flows: branchDiffStat sums committed branch-vs-base totals for the gate card"
```

---

### Task 2: Gate card in the overview — predicate, `GateActionCard`, lane embed, ContentView glue

**Files:**
- Modify: `Sources/Dreamux/Models/PlanFlowBuilder.swift` (one static func)
- Create: `Sources/Dreamux/Views/GateActionCard.swift`
- Modify: `Sources/Dreamux/Views/FlowLaneView.swift`, `Sources/Dreamux/Views/FlowsOverviewView.swift`, `Sources/Dreamux/Views/ContentView.swift`
- Test: `Tests/DreamuxTests/PlanFlowBuilderTests.swift` (append)

**Interfaces:**
- Consumes: `GitBranchDiffStat`/`branchDiffStat` (Task 1), `PlanLaneInput`, `FlowsBoard.Lane`, `FlowStatusGlyph`, `DiffRequest`, `GitOperations.worktreeURL`/`mergeBase`, `PlanQueueController.mergeAndContinue`/`featureNameForPlan`, `ProjectSession.pendingGateMergeWorkspaceID`.
- Produces (Task 3/5 rely on these exact names):
  - `PlanFlowBuilder.isGateMergeActionable(_ input: PlanLaneInput) -> Bool`
  - `struct FlowGateActions { let openDiff: (UUID) -> Void; let requestMerge: (UUID) -> Void; let fetchDiffStat: (UUID) async -> GitBranchDiffStat? }`
  - `struct GateActionCard: View` with `init(workspaceID: UUID, mergeActionable: Bool, actions: FlowGateActions)`
  - `FlowLaneView` gains `var gateActions: FlowGateActions?` + `var gateMergeActionable: Bool = false` (nil/false = inert, existing call sites unaffected until updated)
  - `FlowsOverviewView` gains a required `gateActions: FlowGateActions` parameter

Semantics decision baked in: the card renders for EVERY waiting gate (atGate, attention, off-queue awaitingReview — the spec's "a gate node in waiting renders expanded"), but the merge button only when merging is truly on the table. `attention` means the session stalled with steps UNCHECKED — offering a merge would ship half a plan, and `mergeAndContinue` would silently no-op anyway (it guards `.atGate`). The attention card degrades to diff-inspection; Resume/Skip stay in `PlansSpecsSection`'s queue box (see Deferred).

- [ ] **Step 1: Write the failing predicate test**

Append to `PlanFlowBuilderTests` (reuses the existing `input(...)` helper, `:6-22`):

```swift
    func testGateMergeActionability() {
        // Truly at review — merge is on the table:
        XCTAssertTrue(PlanFlowBuilder.isGateMergeActionable(
            input(status: .awaitingReview)))                       // off-queue review
        XCTAssertTrue(PlanFlowBuilder.isGateMergeActionable(
            input(status: .awaitingReview, isCurrent: true, queueState: .atGate)))
        // Course correction re-opened a step while the queue holds the
        // gate (ProjectSession.swift:232-238's rail): still mergeable.
        XCTAssertTrue(PlanFlowBuilder.isGateMergeActionable(
            input(status: .running, isCurrent: true, queueState: .atGate)))

        // Not at review — never offer merge:
        XCTAssertFalse(PlanFlowBuilder.isGateMergeActionable(
            input(status: .running, isCurrent: true, queueState: .attention))) // stalled, steps unchecked
        XCTAssertFalse(PlanFlowBuilder.isGateMergeActionable(
            input(status: .running, isCurrent: false, queueState: .atGate)))   // someone else's gate
        XCTAssertFalse(PlanFlowBuilder.isGateMergeActionable(input(status: .ready)))
        XCTAssertFalse(PlanFlowBuilder.isGateMergeActionable(input(status: .merged)))
    }
```

Run: `swift test --filter PlanFlowBuilderTests` — expected compile FAILURE (`isGateMergeActionable` not found).

- [ ] **Step 2: Implement the predicate**

In `PlanFlowBuilder` (below `isFirstUnfinished`):

```swift
    /// Whether the gate card may offer "merge & continue" for this plan.
    /// True exactly when the plan is truly at review: derived
    /// `.awaitingReview` (all boxes checked, feature open), or the queue
    /// holds THIS plan at its gate (which survives a course correction
    /// flipping the derived status back to `.running`). `attention`
    /// deliberately fails — steps are unchecked, and the queue box's
    /// Resume/Skip is the recovery surface, not a merge.
    static func isGateMergeActionable(_ input: PlanLaneInput) -> Bool {
        input.status == .awaitingReview
            || (input.isCurrentQueuePlan && input.queueState == .atGate)
    }
```

Run: `swift test --filter PlanFlowBuilderTests` — expected PASS (existing 10 + 1 new).

- [ ] **Step 3: Write `GateActionCard` (complete — new file, transcribe)**

```swift
// Sources/Dreamux/Views/GateActionCard.swift
import SwiftUI

/// Gate-card actions, injected from ContentView — the only layer that
/// can reach git, the workspace store, and the plan queue. Each closure
/// lands on an existing, already-tested channel: diff tabs via
/// `WorkspaceSession.openDiffTab`, merge via
/// `PlanQueueController.mergeAndContinue` or
/// `ProjectSession.pendingGateMergeWorkspaceID` (the sidebar's sheet).
struct FlowGateActions {
    let openDiff: (UUID) -> Void
    let requestMerge: (UUID) -> Void
    let fetchDiffStat: (UUID) async -> GitBranchDiffStat?
}

/// The expanded gate card (spec "Gate cards"): headline, branch-vs-base
/// diff stat, [view diff], and — only when the plan is truly at review —
/// [merge & continue]. One shared view embedded by both the overview
/// lane (FlowLaneView) and the zoom inspector (FlowDetailView) so the
/// two surfaces can't drift.
struct GateActionCard: View {
    let workspaceID: UUID
    /// False for the queue-`attention` gate: the plan stalled with steps
    /// unchecked, so a merge would ship half a plan (and the queue's
    /// mergeAndContinue would refuse anyway). The card degrades to
    /// diff-inspection; Resume/Skip live in the sidebar's queue box.
    let mergeActionable: Bool
    let actions: FlowGateActions

    /// One-shot fetch on appearance; a stat seconds stale is fine and
    /// the card is rare (spec: no new pollers).
    @State private var stat: GitBranchDiffStat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                mergeActionable ? "waiting: review & merge" : "waiting: needs attention",
                systemImage: mergeActionable ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FlowStatusGlyph.color(.waiting))
            if let stat {
                HStack(spacing: 6) {
                    Text("+\(stat.insertions)")
                        .foregroundStyle(.green)
                    Text("−\(stat.deletions)")
                        .foregroundStyle(.red)
                    Text("· \(stat.filesChanged) file\(stat.filesChanged == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button("View diff") { actions.openDiff(workspaceID) }
                if mergeActionable {
                    Button("Merge & continue") { actions.requestMerge(workspaceID) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FlowStatusGlyph.color(.waiting).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(FlowStatusGlyph.color(.waiting).opacity(0.25), lineWidth: 1)
        )
        .task { stat = await actions.fetchDiffStat(workspaceID) }
    }
}
```

- [ ] **Step 4: Embed in `FlowLaneView` (sketch — adapt)**

Add the two properties after `onZoom` (`:37`):

```swift
    /// Gate-card wiring; nil renders no card (previews, read-only hosts).
    var gateActions: FlowGateActions?
    var gateMergeActionable: Bool = false
```

Render the card as a SIBLING below the tappable header+pipeline block, next to the needs-you chip (`:58-60`) — like the chip, it must stay OUTSIDE the `onTapGesture { onZoom?() }` area so a card click never also zooms:

```swift
            if lane.effectiveStatus == .waiting, let detail = lane.flow.detail {
                needsYouChip(detail)
            }
            if let actions = gateActions, let workspaceID = waitingGateWorkspaceID {
                GateActionCard(
                    workspaceID: workspaceID,
                    mergeActionable: gateMergeActionable,
                    actions: actions)
            }
```

with the render condition as a helper:

```swift
    /// Spec: "a gate node in waiting renders expanded". Plan lanes are
    /// the only lanes with a gate node; a workspace is required because
    /// every card action is workspace-scoped (a gate whose feature is
    /// gone has nothing to diff or merge). The board's bubbled
    /// effectiveStatus deliberately plays no part.
    private var waitingGateWorkspaceID: UUID? {
        guard lane.flow.kind == .plan,
              lane.flow.nodes.contains(where: { $0.kind == .gate && $0.status == .waiting })
        else { return nil }
        return lane.flow.workspaceID
    }
```

(Both the chip and the card can render together when a suppressed live session grafted a `detail` onto the gated plan lane — different affordances, jump vs act; that's fine.)

- [ ] **Step 5: Thread through `FlowsOverviewView` (sketch — adapt)**

Add a required parameter alongside the other injected closures (`:14-21`):

```swift
    let gateActions: FlowGateActions
```

The body needs the plan-lane INPUTS (for actionability), not just the composed board — replace the `board` computed var (`:25-30`) with locals at the top of `body` (result builders accept `let`s):

```swift
    var body: some View {
        let inputs = planLaneInputs()
        let board = FlowsBoard.compose(
            planLanes: PlanFlowBuilder.lanes(from: inputs),
            sessionLanes: flows.flows
        )
        let mergeActionableLaneIDs = Set(
            inputs.filter(PlanFlowBuilder.isGateMergeActionable)
                .map { "plan-\($0.planPath)" })
        ...
    }
```

(delete the now-duplicate `let board = self.board` line and the computed var). Pass down through `sectionView`/`lanesList`:

```swift
    private func lanesList(_ lanes: [FlowsBoard.Lane], mergeActionableLaneIDs: Set<String>) -> some View {
        ForEach(lanes) { lane in
            FlowLaneView(
                lane: lane,
                onJumpToTerminal: onJumpToTerminal,
                onZoom: { zoomedLaneID = lane.id },
                gateActions: gateActions,
                gateMergeActionable: mergeActionableLaneIDs.contains(lane.id)
            )
            .opacity(lane.effectiveStatus == .done ? 0.6 : 1.0)
        }
    }
```

(Adapt `sectionView`'s two `lanesList` call sites to forward the set; Task 3 wires the zoom branch's `FlowDetailView`, so leave it untouched here — the build stays green because `FlowDetailView` gains its parameters only in Task 3.)

- [ ] **Step 6: ContentView glue (sketch — adapt names to what's really there)**

Construction in the `.flows` arm (`:303-322`) gains one argument:

```swift
            FlowsOverviewView(
                flows: session.flows,
                planLaneInputs: planLaneInputs,
                zoomedLaneID: $flowsZoomLaneID,
                gateActions: flowGateActions,
                onJumpToTerminal: ...unchanged...
```

New helpers near `planLaneInputs()` (`:663`):

```swift
    private var flowGateActions: FlowGateActions {
        FlowGateActions(
            openDiff: { workspaceID in openGateDiff(workspaceID: workspaceID) },
            requestMerge: { workspaceID in requestGateMerge(workspaceID: workspaceID) },
            fetchDiffStat: { workspaceID in await gateDiffStat(workspaceID: workspaceID) }
        )
    }

    /// The spec's front door: when this lane IS the queue's current
    /// plan at its gate, go through `mergeAndContinue` (which parks the
    /// e2e bridge channel too); an off-queue review parks the bundle
    /// channel directly. Both paths end at the same WorkspaceSidebar
    /// merge sheet — the branch only decides bookkeeping.
    private func requestGateMerge(workspaceID: UUID) {
        if planQueue.state == .atGate,
           let path = planQueue.currentPlanPath,
           let feature = planQueue.featureNameForPlan(path),
           store.featureWorkspace(named: feature)?.id == workspaceID {
            planQueue.mergeAndContinue()
        } else {
            session.pendingGateMergeWorkspaceID = workspaceID
        }
    }

    /// One "everything this branch changes" diff tab per linked repo —
    /// the commit-trail popover's "Diff vs base" request shape
    /// (merge-base fork point → HEAD), multi-repo like
    /// WorkspaceSidebar.openTaskDiff, activating the workspace so the
    /// tabs are visible.
    private func openGateDiff(workspaceID: UUID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let repos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        Task { @MainActor in
            for repo in repos {
                guard let worktree = await GitOperations.worktreeURL(
                    forBranch: workspace.name, in: repo.rootURL) else { continue }
                let from = await GitOperations.mergeBase(of: repo.defaultBranch, in: worktree)
                    ?? repo.defaultBranch
                sidebarMode = .workspace
                store.activate(workspace.id)
                store.session(for: workspace).openDiffTab(DiffRequest(
                    worktreeURL: worktree,
                    fromRevision: from,
                    toRevision: "HEAD",
                    title: repos.count > 1
                        ? "\(workspace.name) vs \(repo.defaultBranch) — \(repo.name)"
                        : "\(workspace.name) vs \(repo.defaultBranch)"))
            }
        }
    }

    /// Card stat = sum across the workspace's linked repos (a feature
    /// can span several); repos where the branch has no worktree or no
    /// resolvable base contribute nothing. Nil only when NO repo
    /// yielded a stat — the card then omits the line entirely.
    private func gateDiffStat(workspaceID: UUID) async -> GitBranchDiffStat? {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        let repos = repoStore.repositories.filter { workspace.linkedRepoIDs.contains($0.name) }
        var total: GitBranchDiffStat?
        for repo in repos {
            guard let worktree = await GitOperations.worktreeURL(
                    forBranch: workspace.name, in: repo.rootURL),
                  let stat = await GitOperations.branchDiffStat(
                    vs: repo.defaultBranch, in: worktree)
            else { continue }
            total = GitBranchDiffStat(
                insertions: (total?.insertions ?? 0) + stat.insertions,
                deletions: (total?.deletions ?? 0) + stat.deletions,
                filesChanged: (total?.filesChanged ?? 0) + stat.filesChanged)
        }
        return total
    }
```

(`planQueue`, `session`, `store`, `repoStore`, `sidebarMode` are all in `ContentView` scope today — `planLaneInputs()` and the `.flows` arm use them; adapt if names differ.)

- [ ] **Step 7: Build + full suite**

Run: `swift build && swift test`
Expected: clean/green. `FlowDetailView` still compiles unchanged (its params arrive in Task 3); `FlowLaneView`'s new properties are defaulted so the detail-view construction site in `FlowsOverviewView` is the only other call site and it doesn't construct `FlowLaneView` directly.

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/Models/PlanFlowBuilder.swift Tests/DreamuxTests/PlanFlowBuilderTests.swift Sources/Dreamux/Views/GateActionCard.swift Sources/Dreamux/Views/FlowLaneView.swift Sources/Dreamux/Views/FlowsOverviewView.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Flows: gate action card on waiting plan lanes wired to diff tabs and the merge gate"
```

---

### Task 3: Zoom inspector gate actions + gate preselect

**Files:**
- Modify: `Sources/Dreamux/Views/FlowDetailView.swift`
- Modify: `Sources/Dreamux/Views/FlowsOverviewView.swift` (zoom-branch pass-through)

**Interfaces:**
- Consumes: `GateActionCard`/`FlowGateActions` (Task 2), `FlowDetailView`'s existing `nodeInspector` (`:202`) and `.onAppear { pulsing = true }` (`:50`).
- Produces: `FlowDetailView` gains `let gateActions: FlowGateActions?` and `let gateMergeActionable: Bool`; zooming into a lane whose gate is waiting preselects the gate node (the e2e screenshot's load-bearing behavior).

- [ ] **Step 1: Add the parameters and pass them from the overview**

`FlowDetailView` properties, after `onOpenTranscript` (`:13`):

```swift
    /// Gate-card wiring (Task 2's shared card); nil renders no actions.
    let gateActions: FlowGateActions?
    let gateMergeActionable: Bool
```

In `FlowsOverviewView`'s zoom branch (`:35-40`), pass both:

```swift
            FlowDetailView(
                lane: lane,
                onBack: { self.zoomedLaneID = nil },
                onJumpToTerminal: onJumpToTerminal,
                onOpenTranscript: onOpenTranscript,
                gateActions: gateActions,
                gateMergeActionable: mergeActionableLaneIDs.contains(lane.id)
            )
```

(`mergeActionableLaneIDs` is the local computed in Task 2 Step 5 — it's in scope in `body` where the zoom branch lives.)

- [ ] **Step 2: Gate section in `nodeInspector`**

In `nodeInspector(_:)` (`:202`), directly after the status/elapsed block and BEFORE the existing `Divider()` + transcript/jump buttons (the gate's actions are the headline; the generic buttons stay below — "Jump to terminal" still works for plan lanes, "Open transcript" stays disabled since plan lanes have no `sessionID`):

```swift
            if node.kind == .gate, node.status == .waiting,
               let actions = gateActions, let workspaceID = lane.flow.workspaceID {
                GateActionCard(
                    workspaceID: workspaceID,
                    mergeActionable: gateMergeActionable,
                    actions: actions)
            }
```

- [ ] **Step 3: Preselect the waiting gate on appear**

Extend `.onAppear` (`:50`):

```swift
        .onAppear {
            pulsing = true
            // Zooming into a gated lane: the gate IS the story — land on
            // its actions instead of the empty lane summary. Only as the
            // initial selection; a user click still wins afterwards.
            if selectedNodeID == nil,
               lane.flow.nodes.contains(where: { $0.kind == .gate && $0.status == .waiting }) {
                selectedNodeID = "gate"
            }
        }
```

(`FlowsOverviewView` already re-ids the detail view per lane — `.id(zoomedLaneID)` at `:47` — so this fires per zoomed lane, not once per pane lifetime.)

- [ ] **Step 4: Build + full suite**

Run: `swift build && swift test`
Expected: clean/green (view-only change).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/FlowDetailView.swift Sources/Dreamux/Views/FlowsOverviewView.swift
git commit -m "Flows: zoom inspector carries the gate card and preselects a waiting gate"
```

---

### Task 4: Unify tile badge with board aggregates

**Decision (the G2→G3 deferred item, "revisit with Group 5's gate cards"): UNIFY.** The tile badge currently counts `FlowStore.aggregates` — session lanes only. A plan at its gate usually has NO live session (claude exited when the plan completed), so the board says "1 needs you" while the tile — the thing that tells you to open the pane — stays dark. Group 5 builds its whole feature around exactly that state; shipping it with a silent tile would be self-defeating. Unify = the badge computes the SAME numbers the pane header shows, through the same `PlanLaneAssembler → PlanFlowBuilder → FlowsBoard.compose` path, so they agree by construction. Cost: one compose over in-memory state per sidebar render — the same order of work `PlansSpecsSection` already does per render for its status rows.

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (tile badge `:443-450`)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (`flowsState` `:677`)
- Modify: `Scripts/e2e/PROTOCOL.md` (`flowsState` entry)

**Interfaces:**
- Consumes: `FlowsBoard.compose` (tested), `PlanLaneAssembler.inputs`, stores `WorkspaceSidebar` already holds (`store`, `docStore`, `flows`, `planQueue` — `:10-21`).
- Produces: tile badge counts == pane header counts; `flowsState` gains `boardRunning`/`boardNeedsYou` (the existing session-store `running`/`needsYou` keys stay — `scenario_flows` asserts them).

- [ ] **Step 1: Sidebar badge reads the board**

Replace the `flows.aggregates` read in `tileRow` (`:443-450`) — and its G2-era "intentionally counts SESSION lanes only" comment — with:

```swift
                if tile == .flows {
                    let agg = flowsBoardAggregates
                    if agg.needsYou > 0 {
                        badgeText("!\(agg.needsYou)", color: FlowStatusGlyph.color(.waiting))
                    }
                    if agg.running > 0 {
                        badgeText("●\(agg.running)", color: FlowStatusGlyph.color(.running))
                    }
                }
```

```swift
    /// Tile badge = the Flows pane header's counts, by construction:
    /// same assembler, same builder, same compose. Ends the documented
    /// G2 divergence (session-only badge) — a plan sitting at its gate
    /// now lights the tile even though its claude session has exited.
    /// One compose over in-memory plan/lane state per sidebar render;
    /// docStore/planQueue/store reads are Observation-tracked here, so
    /// queue transitions re-render the badge on their own.
    private var flowsBoardAggregates: (running: Int, needsYou: Int) {
        let board = FlowsBoard.compose(
            planLanes: PlanFlowBuilder.lanes(
                from: PlanLaneAssembler.inputs(docStore: docStore, queue: planQueue, store: store)),
            sessionLanes: flows.flows)
        return (board.runningCount, board.needsYouCount)
    }
```

- [ ] **Step 2: `flowsState` reports board counts**

In `flowsState` (`:677`), the plan-lane block already builds the plan flows — compose there and add two keys (keep `running`/`needsYou` exactly as they are):

```swift
        var planLanes: [[String: Any]] = []
        var boardRunning = flows.aggregates.runningCount
        var boardNeedsYou = flows.aggregates.needsYouCount
        if let docStore = handles.docStore, let queue = handles.planQueue {
            let planFlows = PlanFlowBuilder.lanes(
                from: PlanLaneAssembler.inputs(docStore: docStore, queue: queue, store: store))
            planLanes = planFlows.map(flowLanePayload)
            let board = FlowsBoard.compose(planLanes: planFlows, sessionLanes: flows.flows)
            boardRunning = board.runningCount
            boardNeedsYou = board.needsYouCount
        }
```

and in the returned dictionary: `"boardRunning": boardRunning, "boardNeedsYou": boardNeedsYou`.

- [ ] **Step 3: Document**

In `PROTOCOL.md`'s `flowsState` entry: `boardRunning`/`boardNeedsYou` are the composed board's counts (plan lanes + session lanes after ad-hoc suppression and status bubbling) — what the pane header and the sidebar tile badge both show; `running`/`needsYou` remain the raw session-store aggregates.

- [ ] **Step 4: Build + full suite**

Run: `swift build && swift test`
Expected: clean/green (compose is pure and already covered by `FlowsBoardTests`; this task is wiring). The rendered-badge path is asserted by Task 5's e2e (`boardNeedsYou >= 1` at the gate) and its screenshots.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/E2E/E2ECommands.swift Scripts/e2e/PROTOCOL.md
git commit -m "Flows: tile badge unifies with board aggregates; flowsState reports board counts"
```

---

### Task 5: e2e `scenario_plan_gate` — a real plan driven to its gate

**Files:**
- Modify: `Scripts/e2e/driver.py` (new scenario + `SCENARIOS` registration after `("flows", scenario_flows)`, `:1081`)
- Modify: `Scripts/e2e/PROTOCOL.md` (only if anything beyond Task 4's `flowsState` note needs documenting)

**Interfaces:**
- Consumes: `enqueuePlan`/`startQueue`/`stopQueue`/`queueState` (synchronous tick), `listDocs`, `flowsState` (`planLanes` + Task 4's `boardNeedsYou`), `zoomFlow` (plan lane ids work — it's just a lane id), `setSidebarMode`, driver helpers `worktree`/`git`/`PROJECT_DIR`/`wait_until`/`screenshot`; the fake claude (`DREAMUX_CLAUDE_BIN`) typed by `runPlan`'s launch.
- Produces: screenshots `NN-flows-gate-card.png` (overview) and `NN-flows-gate-zoom.png` (zoom, gate preselected in the inspector).

**What is and is not asserted:** the harness cannot click SwiftUI buttons, so the card's *press* effects are NOT e2e-driven. They are covered where they live: `mergeAndContinue` in `PlanQueueControllerTests`, the `pendingGateMergeWorkspaceID` → merge-sheet adoption by the existing sidebar behavior (exercised by `openMergeSheet` in `scenario_merge_and_cleanup`), and the diff-tab channel by existing diff coverage. What e2e DOES pin: the data condition that renders the card (gate node `waiting` in `planLanes`), the unified badge count (`boardNeedsYou`), and the two screenshots for visual truth.

- [ ] **Step 1: Write the scenario (near-complete — the two ADAPT notes are the only expected deltas)**

```python
def scenario_plan_gate(d):
    """Drive a real plan through the queue to atGate and verify the
    Flows gate card: plan lane's gate node waiting in flowsState, the
    expanded card in the overview, and the gate-preselected inspector
    in zoom. Buttons aren't clickable from the harness — their channels
    are unit/scenario-covered elsewhere; this pins the rendered state."""
    plans_dir = os.path.join(PROJECT_DIR, "docs", "plans")
    os.makedirs(plans_dir, exist_ok=True)
    plan_rel = "docs/plans/2026-07-06-gate-demo.md"
    plan_abs = os.path.join(PROJECT_DIR, plan_rel)

    def write_plan(checked):
        mark = "x" if checked else " "
        with open(plan_abs, "w", encoding="utf-8") as f:
            f.write(
                "# Gate Demo\n\n"
                "### Task 1: Do the work\n\n"
                f"- [{mark}] Step one\n"
                f"- [{mark}] Step two\n")

    write_plan(checked=False)
    docs = d.cmd("listDocs")
    entry = next((doc for doc in docs["docs"] if doc["path"] == plan_rel), None)
    require(entry is not None and entry["status"] == "ready",
            f"gate-demo plan should be ready, got {entry}")

    d.cmd("enqueuePlan", path=plan_rel)
    d.cmd("startQueue")

    # runPlan provisions worktrees on every repo (branch = filename
    # minus date prefix -> gate-demo) and types the fake claude; wait
    # for the launch to land.
    def queue_running():
        qs = d.cmd("queueState")
        return qs if qs["state"] == "running" and qs.get("current") == plan_rel else None
    d.wait_until(queue_running, 30.0, "queue running the gate-demo plan")

    # Real committed work on the feature branch so the card's diff stat
    # has true numbers (+2 -0, 1 file; the other repos' gate-demo
    # branches have no commits and contribute zeros).
    wt = worktree("portenv-server", "gate-demo")
    with open(os.path.join(wt, "GATE-NOTES.md"), "w", encoding="utf-8") as f:
        f.write("gate card payload\nsecond line\n")
    git("add", "-A", cwd=wt)
    git("commit", "-m", "gate-demo: payload", cwd=wt)

    # All boxes checked -> statusForPlan (which refreshes DocStore
    # itself) reads awaitingReview -> queueState's synchronous tick
    # flips running -> atGate.
    write_plan(checked=True)
    def at_gate():
        qs = d.cmd("queueState")
        return qs if qs["state"] == "atGate" else None
    d.wait_until(at_gate, 15.0, "queue to reach atGate")

    # The card's data condition + the unified badge count.
    state = d.cmd("flowsState")
    plan_lane_id = f"plan-{plan_rel}"
    lane = next((l for l in state["planLanes"] if l["id"] == plan_lane_id), None)
    require(lane is not None,
            f"plan lane {plan_lane_id} missing from planLanes")
    gate = next((n for n in lane["nodes"] if n["id"] == "gate"), None)
    require(gate is not None and gate["status"] == "waiting",
            f"gate node should be waiting, got {gate}")
    require(state.get("boardNeedsYou", 0) >= 1,
            "board needs-you should count the waiting gate")

    # Overview: the expanded card under the gate-demo lane.
    d.cmd("setSidebarMode", mode="flows")
    time.sleep(1.5)  # render + the card's one-shot diff-stat fetch
    d.screenshot("flows-gate-card")

    # Zoom: gate node preselected -> inspector carries the same card.
    d.cmd("zoomFlow", laneID=plan_lane_id)
    time.sleep(1.5)
    d.screenshot("flows-gate-zoom")
    d.cmd("zoomFlow", laneID=None)

    d.cmd("stopQueue")
```

Register it in `SCENARIOS` (`:1081`) as `("plan-gate", scenario_plan_gate)` immediately after `("flows", scenario_flows)` — it needs the repos from `repos-and-feature` and tolerates the still-live flows-demo session lane from `scenario_flows` (that lane simply co-renders in the overview screenshot, which is realistic).

ADAPT notes: (1) confirm `git(...)` / `worktree(...)` helper signatures at `driver.py:85/:392` — sketched from `scenario_merge_and_cleanup`'s usage; (2) if `listDocs` reports the plan as something other than `ready` (e.g. doc-kind derivation needs a `**Spec:**` line or different heading shape), fix the plan FIXTURE to satisfy `PlanDoc` parsing rather than weakening the `require` — `Tests/DreamuxTests/PlanDocTests.swift` shows the accepted shapes.

- [ ] **Step 2: Run the suite**

Run: `Scripts/e2e/run-e2e.sh`
Expected: all scenarios pass including `plan-gate`. Then LOOK at the artifacts:
- `NN-flows-gate-card.png`: the "Gate Demo" lane in the Needs-you section, pipeline `plan → Do the work ✓ → gate(!) → merge`, and below it the card — "waiting: review & merge", a stat line around `+2 −0 · 1 file` (provisioning may add a commit; plausibility over exactness), `View diff` and a prominent `Merge & continue`. The sidebar Flows tile must show the `!1` badge (Task 4's unify made this the board count).
- `NN-flows-gate-zoom.png`: the DAG with the gate node selection-ringed, inspector showing "review & merge" heading, the same card, and Jump to terminal beneath.

If a screenshot contradicts an expectation, treat it as a failure to investigate, not a note.

- [ ] **Step 3: Commit**

```bash
git add Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md
git commit -m "Flows e2e: drive a queued plan to its gate; screenshot card and zoom inspector"
```

---

## Deferred (explicitly NOT this plan)

- **e2e-clicking the card's buttons.** The harness has no click synthesis; adding a `gateMerge` e2e command was considered and rejected — it would exercise a command, not the button, while the channels behind the button are already unit-covered (`PlanQueueControllerTests`) and scenario-covered (`openMergeSheet`).
- **Resume/Skip on the attention-state card.** The Flows card degrades to diff-inspection under `attention`; recovery actions stay in `PlansSpecsSection`'s queue box. Duplicating them here doubles surface for the rarest state — revisit only if real usage shows people camped in the Flows pane during stalls.
- **Consolidating `PlansSpecsSection.gateCard()` with `GateActionCard`.** Different vocabulary (green "plan complete" vs Flows' waiting-orange), different context (queue box vs lane), and spec decision 3 established the sidebar stays untouched. Not worth a shared abstraction for two ~30-line views.
- **Live-refreshing the diff stat.** One-shot by design; a poller for a card whose lifetime is "until the human merges" buys nothing.
- **Gate cards on session lanes.** Waiting ad-hoc lanes keep the needs-you chip (jump to terminal); gates are a plan-lane concept.
- **`FlowEvent.sessionID` DRY-up and other G2/G3 minors** — tracked in the ledger, still riding.
