# PR Finish Flow — Design

## Goal

Make "create a PR" a first-class finish action at the moment a run reaches
its gate, and give the whole interface a reactive PR-status axis so a
workspace's readiness-to-merge is visible everywhere — not just inside the
merge sheet while it happens to be open.

The push/PR **engine already exists and ships** (`GhOperations`,
`GitOperations.push`, `MergeFlow.publish`/`commitAndPublish`, the
`MergeFeatureSheet` publish button). This slice does **not** rebuild git/gh
plumbing. It (A) surfaces the existing publish action at the gate, and (B)
lifts PR status out of the transient sheet into a persistent, observable
axis rendered across the app.

## Non-goals / Follow-ups

- Editable PR title/body from the gate (today: title = `workspace.name`,
  body = `MergeFlow.prBody`'s commit list). Deferred.
- Multi-repo PR aggregation: a feature spanning several repos tracks **one**
  PR (the first linked repo with a remote / the repo published through the
  sheet). Per-repo PR fan-out is a follow-up.
- OAuth / stored tokens: unchanged — everything funnels through the user's
  `gh` auth via the existing `runGh` plumbing.
- Extending the fake-gh fixture to emit `isDraft`/`reviewDecision`/
  `statusCheckRollup` for an end-to-end poll test — the mapping is unit
  tested from JSON literals instead; a fixture upgrade is optional.

---

## Increment A — surface publish at the finish moment

Today publish is reachable **only** from `MergeFeatureSheet`; the Flows gate
card (`GateActionCard`) offers just **View diff** + **Merge & continue**
(local merge). Increment A adds the PR path to the gate.

**Behaviour**

- When publish is **available** for the gate's workspace
  (`PublishAvailability.available` — a remote exists **and** `gh` is
  installed) and the gate is merge-actionable, the card shows **"Create PR"
  as the primary (prominent) action** and **"Merge locally" as secondary**.
- When publish is **not** available (`.noRemote` / `.ghMissing`), the card
  keeps today's behaviour: a single primary **"Merge & continue"** (local
  merge only). No broken/dead PR button ever renders.
- When the gate is not merge-actionable (`mergeActionable == false`), the
  card stays diff-only, exactly as today.

**How availability is known without a live `MergeFlow`.** The card already
fetches its diff stat async on appear (`FlowGateActions.fetchDiffStat`). We
mirror that: a new `fetchPublishAvailability: (UUID) async ->
PublishAvailability` is fetched in the same `.task`, and the card renders
Create-PR-primary only once it resolves `.available`. No new persistent
availability store; no synchronous git/gh on the render path.

**How "Create PR" reuses the engine.** A new `requestPublish: (UUID) ->
Void` closure on `FlowGateActions`, wired in `ContentView.flowGateActions`,
parks the workspace id on the **existing** merge-sheet channel
(`ProjectSession.pendingGateMergeWorkspaceID`) — the same path
`requestGateMerge` already uses — so "Create PR" presents the existing
`MergeFeatureSheet`, where `MergeFlow.publish` is the source of truth.
`requestPublish` additionally sets a new
`ProjectSession.emphasizePublishWorkspaceID`; `WorkspaceSidebar` reads it
when it presents the sheet and passes `emphasizePublish: true` so the
sheet's publish button renders as the prominent action. **No publish logic
is duplicated.**

**Pure verdict, shared.** `PublishAvailability.decide(anyRemote:
ghAvailable:) -> PublishAvailability` centralises the tri-state rule (no
remote ⇒ `.noRemote`; remote but no gh ⇒ `.ghMissing`; both ⇒ `.available`).
`MergeFlow.initializeStates` is refactored to call it so the sheet and the
gate can't drift on what "available" means.

**"View PR" on the card** is fed by Increment B (needs `prState`).

---

## Increment B — a reactive, persistent PR-status axis

Today PR status is polled **only** inside the open `MergeFlow`
(`pollPRStatus`, ~10s, sheet-lifetime only) and nothing outside the sheet
sees it. Increment B lifts it into a persistent observable axis.

### `PRLifecycle` — a sibling to `FlowStatus`, never folded in

`FlowStatus` is contractually **CLI-agnostic** (`FlowGraph.swift:1-6` — no
Claude/GitHub vocabulary; adapters translate). GitHub PR concepts must not
enter it. `PRLifecycle` is a **separate** enum living in its own file.

Case set (tight, 8 cases — each maps to a distinct visual/text state and a
distinct user decision):

| case | meaning | user read |
| --- | --- | --- |
| `draft` | PR opened as draft | not ready for review yet |
| `open` | open, no blocking signal | awaiting review |
| `checksRunning` | CI in progress | wait |
| `checksFailed` | CI failed | fix required |
| `changesRequested` | reviewer requested changes | address feedback |
| `approved` | approved, checks not failing | **ready to merge** |
| `merged` | merged on the remote (any method) | done — cleanup safe |
| `closed` | closed **without** merging | abandoned / re-open |

**Mapping precedence** (first match wins), computed by
`GhOperations.PRDetailPayload.lifecycle` from `gh pr view <branch> --json
isDraft,reviewDecision,statusCheckRollup,state,url`:

1. `state == MERGED` → `.merged`
2. `state == CLOSED` → `.closed`
3. `isDraft` → `.draft`
4. `reviewDecision == CHANGES_REQUESTED` → `.changesRequested`
   (a human's block outranks a transient CI state)
5. checks failing → `.checksFailed`
6. checks running/pending → `.checksRunning`
7. `reviewDecision == APPROVED` → `.approved`
8. otherwise → `.open`

`statusCheckRollup` is reduced to a `ChecksVerdict {none, running, passing,
failing}` handling both gh shapes: `CheckRun` (`status` QUEUED/IN_PROGRESS/
COMPLETED + `conclusion`) and `StatusContext` (`state` SUCCESS/FAILURE/
PENDING). Any failing ⇒ `failing`; else any incomplete/pending ⇒ `running`;
else `passing`; empty/absent ⇒ `none`.

`GhOperations.prStatus` (the existing `state,url` call `MergeFlow` uses for
merged/closed detection) is left untouched; the richer `prDetail` is
additive.

### `PRStatusStore` — the persistent axis

`@MainActor @Observable`, keyed by **feature/branch name** (which equals
`workspace.name` throughout the engine — `publish` pushes `branch:
workspace.name` and creates the PR for it):

```
struct Entry: Equatable, Sendable { var lifecycle: PRLifecycle; var url: String }
private(set) var states:  [String: Entry]   // feature/branch → latest PR state
private(set) var tracked: [String: URL]     // feature/branch → gh working dir (feature worktree)

func track(feature:worktreeURL:)   // register a feature worth polling (idempotent)
func untrack(feature:)             // drop on cleanup; also clears its state
func state(for feature:) -> Entry?
var trackedFeatures: [(feature: String, worktreeURL: URL)]
func apply(_ snapshot: [String: Entry])   // merge a poll pass; absent features left as-is
```

`apply` merges rather than replaces so a transient gh miss on one feature
never blanks a known PR.

### `PRStatusPoller` — mirrors `ClaudeRegistryPoller`

Same shape as `ClaudeRegistryPoller` (`ProjectSession` wires it the same
way, next to `registryPoller`): injected closures + a `Task` heartbeat.

```
init(tracked: @MainActor () -> [(feature, worktreeURL)],
     fetch:   @Sendable (String, URL) async -> PRStatusStore.Entry?,
     onSnapshot: ([String: PRStatusStore.Entry]) -> Void)
func startPolling(interval: TimeInterval = 10)   // throttle ~10s
func pollOnce() async
func stopPolling()
```

**Non-spammy gating rule (contractual):** `pollOnce` fetches **only** the
features returned by `tracked()`. Nothing tracked ⇒ zero `gh` calls. A
feature enters the tracked set exactly two ways:

1. Dreamux **publishes** its PR this session — `MergeFlow.publish` fires an
   `onPublished(repo, url)` hook that `track(feature: workspace.name,
   worktreeURL:)`s the feature. It then stays fresh (checks → approved →
   merged) after the sheet closes.
2. **Session-start seed** — for each feature workspace, a cheap **offline**
   probe (`git rev-parse --verify --quiet refs/remotes/origin/<branch>`)
   confirms a pushed branch; matches are tracked. Plans whose branch was
   never pushed are never polled.

The real `fetch` is `GhOperations.prDetail`; tests inject a fake fetch so no
test touches gh or the network.

### `FlowsBoard.Lane.prState` — the render seam

`FlowsBoard.Lane` gains `var prState: PRLaneState?` right beside
`effectiveStatus`/`sessionChip` (`PRLaneState { lifecycle: PRLifecycle; url:
String }`). `compose` gains a defaulted parameter:

```
static func compose(planLanes:, sessionLanes:,
                    prStatesByWorkspace: [UUID: PRLaneState] = [:]) -> FlowsBoard
```

Each lane sets `prState = flow.workspaceID.flatMap { prStatesByWorkspace[$0] }`.
The default keeps the other three `compose` call sites (E2E, sidebar-badge
aggregate) compiling unchanged.

**Where the map comes from (simplification vs. the brief).** Because the
store key **is** `workspace.name`, the `[UUID: PRLaneState]` map is built
directly in the Flows glue from the workspace store —
`store.workspaces.compactMap { ws in prStatus.state(for: ws.name).map {
(ws.id, …) } }` — rather than threading `prState` through `PlanLaneInput` /
`PlanLaneAssembler` / `PlanFlowBuilder` (which would leak GitHub concepts
into the plan-lane model). Same testable seam (`compose` population), fewer
touched files, and the CLI-agnostic plan model stays clean. Plan lanes
recompute every render, so a store publish auto-recomposes — no persistence.

### `PRStatusGlyph` / `PRStatusBadge` — the visual vocabulary

A sibling to `FlowStatusGlyph` centralising `symbol`/`color`/`label` per
`PRLifecycle` (blocking states red, checks amber, approved/merged green,
draft/open/closed secondary). `PRStatusBadge` renders the pill (optional
`onOpen` → opens `url`). Rendered at:

- `GateActionCard` — badge + a **"View PR"** button when `prState` exists;
  the gate line can read "Checks running / Changes requested / Approved".
- `FlowLaneView` header — beside the title.
- `WorkspaceOverviewView.projectRunRow` — the run row.
- `WorkspaceSidebar` feature row — beside the workspace's status.
- `PlansSpecsSection.planRow` — beside the plan title / live-flow dot.

(FlowDetailView breadcrumb optional.) The overview/sidebar/plan sites read
PR state via a `prState(forFeature:) -> PRLaneState?` lookup threaded from
`ProjectSession.prStatus`.

---

## Data flow

```
gate "Create PR"  ──requestPublish──▶ pendingGateMergeWorkspaceID
                                       + emphasizePublishWorkspaceID
                                          │
                          WorkspaceSidebar presents MergeFeatureSheet
                                          │  (emphasizePublish: true)
                                MergeFlow.publish  ──▶ push + GhOperations.createPR
                                          │
                                   onPublished ──▶ PRStatusStore.track(feature,worktree)
                                          │
   PRStatusPoller (10s) ── tracked() ──▶ GhOperations.prDetail ──▶ PRLifecycle
                                          │
                                 PRStatusStore.apply(snapshot)   [@Observable]
                                          │
        Flows glue: [UUID:PRLaneState] from store.workspaces  ──▶ FlowsBoard.compose
                                          │
             Lane.prState ──▶ PRStatusBadge at gate / lane / overview / sidebar / plan row
```

## States & edge cases

- **No remote** → `PublishAvailability.noRemote`: gate stays local-merge
  only; feature never tracked; no badge.
- **gh missing** → `.ghMissing`: gate stays local-merge only (no dead PR
  button); if a branch is somehow tracked, `prDetail` returns nil and the
  badge simply doesn't appear.
- **Draft / open / checksRunning / checksFailed / changesRequested /
  approved** → badge + colour per the table; gate offers "View PR".
- **PR merged** → `.merged` badge (green); merge sheet's existing
  `.prMerged` path still owns cleanup + local-main fast-forward.
- **PR closed without merging** → `.closed` badge; `MergeFlow.pollPRStatus`
  already bounces its per-repo state back to `.pending` so the user can
  merge locally or push afresh; the persistent axis shows `.closed`.
- **Nothing tracked** → poller makes zero gh calls (non-spammy invariant).
- **Multi-repo feature** → one tracked PR (documented follow-up).
- **`publish` must not touch shared local `main`** — integration is
  remote-only; local main only ff-fetches at cleanup. Preserved (no change
  to `publish`).

## Testing

Pure/logic pieces get real XCTest:

- `PRLifecycle` mapping — decode ~9 gh JSON literals into
  `GhOperations.PRDetailPayload`, assert `.lifecycle` for each precedence
  branch and both `statusCheckRollup` shapes (`PRLifecycleTests`).
- `PublishAvailability.decide` — the tri-state truth table
  (`PublishFlowTests` or a small new case).
- `PRStatusStore` keying — `track`/`trackedFeatures`/`state(for:)`/
  `untrack`/`apply` merge semantics (`PRStatusStoreTests`).
- `PRStatusPoller` — injected `tracked`/`fetch`: fetches only tracked
  features, publishes the snapshot, and makes zero fetches when nothing is
  tracked (`PRStatusPollerTests`).
- `FlowsBoard.Lane.prState` population from `prStatesByWorkspace`
  (`FlowsBoardTests`).
- `PRStatusGlyph` totality — every `PRLifecycle` has a non-empty
  symbol/label.

View-only wiring (gate-card buttons, header/row badges, sheet emphasis,
poller/seed wiring in `ProjectSession`) is verified by `swift build` + a
described visual check.

## File list

New:

- `Sources/Dreamux/Models/PRLifecycle.swift` — `PRLifecycle`, `PRLaneState`.
- `Sources/Dreamux/Models/PRStatusStore.swift` — `PRStatusStore`,
  `PRStatusPoller`.
- `Sources/Dreamux/Views/PRStatusGlyph.swift` — `PRStatusGlyph`,
  `PRStatusBadge`.
- `Tests/DreamuxTests/PRLifecycleTests.swift`,
  `PRStatusStoreTests.swift`, `PRStatusPollerTests.swift`.

Modified:

- `Sources/Dreamux/Models/MergeFlow.swift` — `PublishAvailability.decide`;
  `initializeStates` reuse; `publish` `onPublished` hook.
- `Sources/Dreamux/Shell/GhOperations.swift` — `PRDetailPayload` +
  `prDetail`.
- `Sources/Dreamux/Models/FlowsBoard.swift` — `Lane.prState` + `compose`
  param.
- `Sources/Dreamux/Models/ProjectSession.swift` — `prStatus` store,
  `prStatusPoller`, `emphasizePublishWorkspaceID`, seed.
- `Sources/Dreamux/Views/GateActionCard.swift` — Create-PR primary /
  Merge-locally secondary; `prState` + View PR.
- `Sources/Dreamux/Views/ContentView.swift` — `flowGateActions`
  (`requestPublish`, `fetchPublishAvailability`); pass
  `prStatesByWorkspace`.
- `Sources/Dreamux/Views/MergeFeatureSheet.swift` — `emphasizePublish`.
- `Sources/Dreamux/Views/WorkspaceSidebar.swift` — consume emphasis; feature-row badge.
- `Sources/Dreamux/Views/FlowLaneView.swift`,
  `WorkspaceOverviewView.swift`, `PlansSpecsSection.swift` — badges.
- `Sources/Dreamux/Shell/GitOperations.swift` — offline
  `hasRemoteBranch` probe for the seed.
