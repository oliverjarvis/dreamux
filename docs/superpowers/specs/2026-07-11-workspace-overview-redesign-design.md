# Workspace Overview Redesign — Design

**Date:** 2026-07-11
**Status:** approved (design), pending plan
**Direction:** "Polished & restrained" (chosen from a 3-way interactive mockup)

## Goal

Make the workspace **Overview** page — the pinned, non-closable home tab of
every workspace — read as a modern, professional run dashboard instead of a
flat text list on the pane. Keep the app's existing cool, minimal language
(no new visual world); add hierarchy, meaningful status color, and a primary
action that matches the run's moment.

Covers **both** modes of `WorkspaceOverviewView`:
- **Mode A** — a plan backs this workspace (the run dashboard).
- **Mode B** — a plain `main`/scratch workspace (working-tree home + Project
  Runs board).

## Context

The whole page lives in `Sources/Dreamux/Views/WorkspaceOverviewView.swift`.
It is fed by `WorkspaceOverviewDependencies` (built in `ContentView`), a bundle
of closures over already-tested helpers. Today it is a `ScrollView` of
`header → Divider → specAndProgress → Divider → checklist → Divider →
actionsRow → gateSection` (Mode A) and `headerB → Divider → actionsRowB →
Divider → projectRunsSection` (Mode B).

Diagnosis of why it reads unpolished (from the current screenshot):
- No surfaces or hierarchy — raw text on the pane, segmented by thin gray
  `Divider()` rules that cheapen it.
- The status ("awaiting review") is muted gray text — the single most
  important fact, rendered as an afterthought.
- The progress bar is a generic blue system `ProgressView`; 56/56 complete
  looks identical to 3/56.
- The checklist is 11 identical low-contrast gray rows; counts drift out
  across a ~2000px empty gutter.
- The primary action (review → merge) is buried as one of three equal
  buttons at the bottom, and only appears at all when the queue is gated.

## Non-goals

- No new status-color vocabulary. Reuse `FlowStatusGlyph` / `FlowStatus`.
- No change to `WorkspaceOverviewDependencies`' public shape or to how
  `ContentView`/`WorkspaceTerminalContainer` wire it — the redesign is
  internal to `WorkspaceOverviewView`. (Keeps e2e and the window wiring
  untouched.)
- No behavior change to merge/diff/course-correct/run mechanics — the same
  closures are called; only their presentation and placement change.
- Not touching the rail (`PlansSpecsSection`), the Flows page, or
  `GateActionCard` (still used by Flows).

## Global constraints

- **Status color + glyph come from `FlowStatusGlyph`** (`FlowStatus.running`
  and `.waiting` → `.orange`; `.done` → `.green`; `.queued` → `.secondary`;
  symbols per `FlowStatusGlyph.symbol`). Do NOT introduce a blue/green
  "running" tint that diverges from the shared vocabulary — the header glyph
  and any new status pill must agree.
- **Progress bars** are the app's own `Capsule`-based bar (as in
  `PlansSpecsSection.planProgressBar`), NOT the system `ProgressView`. Bar
  fill color is a *separate* axis from status color: **green (`.green`) when
  the run is complete** (awaiting review / merged), **accent
  (`Color.accentColor`) while incomplete**.
- **Surfaces, not rules.** No `Divider()` between sections. Group content on
  subtle surface cards (`RoundedRectangle(cornerRadius: 12–14)` filled
  `Color.primary.opacity(~0.04)` + a `Color.primary.opacity(~0.06)` hairline
  border) and separate sections with uppercase section labels + spacing.
- **Type scale (CLAUDE.md house style — generous, not dense):** hero title
  20–22pt `.rounded` semibold; section labels 12–13pt semibold uppercase
  kern ~0.09 `.secondary`; task/run titles 15pt; all numeric counts
  `.monospacedDigit()` 12–13pt; meta 13pt `.secondary`.
- **Constrained reading column:** Mode A/B content sits in a column capped at
  ~`860pt` max width (leading-aligned), so checklist counts don't drift
  across the full pane width.
- The `WorkspaceOverviewDependencies` interface is frozen for this work.

## Design language (shared by both modes)

A reusable set of small view pieces, used by A and B so they read as one page:

- **`OverviewHero`** — the top band: a status **pill**, the title/identity, a
  meta line, an optional colored progress capsule, and a state-aware primary
  action row. Rendered on a surface card (radius 14).
- **Status pill** — `Capsule` with `FlowStatusGlyph.color(flow).opacity(0.16)`
  fill, `FlowStatusGlyph.color(flow)` text/glyph, 12.5pt semibold. A small
  leading dot (the glyph or a filled circle). The `.running` pill's dot gets
  a gentle pulse (opacity breathe) so "active" reads as motion, not warning
  — respect `prefers-reduced-motion` (no pulse when reduced).
- **Section label** — 12pt uppercase kerned `.secondary`, optional trailing
  `.secondary` count ("· 11 tasks").
- **Surface card / list surface** — the shared rounded surface described in
  Global Constraints.
- **`OverviewProgressBar(fraction:complete:)`** — the Capsule bar; green when
  `complete`, accent otherwise.

## Mode A — hero + run state model (the crux)

The hero's pill, bar color, and primary action all derive from ONE pure
mapper so the page always shows the right thing:

```swift
struct RunHeroState: Equatable {
    enum Phase: Equatable { case ready, running, paused, awaitingReview, merged }
    enum PrimaryAction: Equatable {
        case run            // lime RunPlanButton (start or resume the plan agent)
        case running        // RunningIndicator (agent is live; not a button)
        case reviewAndMerge // opens the merge flow via gateActions.requestMerge
        case none           // merged — no primary
    }
    let phase: Phase
    let pillText: String
    let flow: FlowStatus        // -> FlowStatusGlyph.color/.symbol for the pill
    let progressComplete: Bool  // green bar vs accent bar
    let primary: PrimaryAction

    /// `status` from docStore.status(for:), `hasLiveAgent` from the
    /// injected liveness signal (a live claude agent tab on this workspace).
    static func resolve(status: PlanStatus, hasLiveAgent: Bool) -> RunHeroState {
        switch status {
        case .merged:
            return .init(phase: .merged, pillText: "Merged",
                         flow: .done, progressComplete: true, primary: .none)
        case .awaitingReview:
            return .init(phase: .awaitingReview, pillText: "Awaiting your review",
                         flow: .waiting, progressComplete: true, primary: .reviewAndMerge)
        case .running, .inProgress:
            // A run is recorded (workspace exists) but incomplete.
            if hasLiveAgent {
                return .init(phase: .running, pillText: "Running",
                             flow: .running, progressComplete: false, primary: .running)
            }
            return .init(phase: .paused, pillText: "Paused",
                         flow: .queued, progressComplete: false, primary: .run)
        case .ready, .specOnly:
            // Not reachable for a materialized Mode-A workspace, handled for
            // totality: never run yet.
            return .init(phase: .ready, pillText: "Ready to run",
                         flow: .queued, progressComplete: false, primary: .run)
        }
    }
}
```

Resulting hero per moment:

| Run state (status, liveAgent) | Pill (color) | Bar | Primary |
|---|---|---|---|
| incomplete + agent live (`.running`, true) | "Running" · orange, pulsing dot | accent | **Running…** indicator + *Course correct* on the checklist |
| incomplete + no agent (`.running`/`.inProgress`, false) | "Paused" · secondary | accent | **▶ Run the plan** (resume) |
| complete, open (`.awaitingReview`) | "Awaiting your review" · orange | **green, full** | **✓ Review & merge** |
| complete, closed (`.merged`) | "Merged" · green | green, full | — (subtle merged note) |

**Primary action wiring (unchanged mechanics):**
- `.run` → `RunPlanButton { onRunPlan(plan) }` (existing lime pill).
- `.running` → `RunningIndicator()` (existing).
- `.reviewAndMerge` → a filled button calling `gateActions.requestMerge(workspaceID)`.
  This already routes correctly both ways: when this plan is the queue's
  current gate it runs `mergeAndContinue()`; otherwise it parks
  `pendingGateMergeWorkspaceID` and the sidebar opens the merge sheet.
  **Label:** "Merge & continue" when this plan IS the queue's current gate
  (`planQueue.state == .atGate && currentPlanPath == relativePath(plan)`),
  else "Review & merge".
- `.none` → no primary; instead a subtle **merged note**: a single 13pt line
  with a green `checkmark.seal.fill` — "Merged — this run's changes are on
  `<base>`." (celebratory but quiet; base = the first linked repo's default
  branch, else "main"). "View changes" still available as a secondary.

**Hero layout:**
- Row 1: status pill · spacer · elapsed ("Started 1 day, 11 hr ago", from the
  ledger `startedAt`) · the run.toml **services** control
  (`makeRunControls(workspace)`) at the far right — it is about the
  workspace's dev servers, not the plan lifecycle.
- Title (rounded semibold) + optional subtitle.
- Meta line: `arrow.triangle.branch` branch chip · linked repos · attachment
  chips (spec / roadmap) via the existing `docChips(for:)`. No sha here — the
  pane's context-header git chip already carries branch + sha + `+X −Y`, so
  the hero doesn't duplicate it.
- Progress: "`X / Y steps` · `<phrase>`" label (phrase = "complete" when
  done, else the pill phrase) + `OverviewProgressBar`.
- Action row: **primary** (above) + **View changes** (`gateActions.openDiff`,
  showing the fetched `+X −Y` like today's `BranchChangesButton`) +
  **Open terminal** (`openOrFocusTerminal`), the latter two as quiet
  `.soft`/ghost buttons.

**Removed from Mode A:** the three `Divider()`s, the standalone
`gateSection`/`GateActionCard` (its merge CTA + "review before merging"
message are absorbed into the hero pill + primary), and the flat bottom
`actionsRow` (its buttons move into the hero action row).

## Mode A — checklist

On a single list surface, in the constrained column:

- **Flat plans:** rows = number badge (mono, `.secondary`, fixed 20pt column)
  + check + clean title (drop the redundant "Task N:" prefix — the badge is
  the number; keep any inline `` `code` `` spans) + a tabular count chip
  (`k/n` on a `surface-2` chip).
- **Check styling:** done = `checkmark` in a soft green circle
  (`.green.opacity(0.16)` fill, `.green` glyph); current =
  `arrowtriangle.right.fill` in `Color.accentColor`; pending = hollow
  `circle` `.tertiary`.
- **Current task** keeps its accent-tinted row background + a trailing
  "current" label (as today, `taskRow(isCurrent:)`).
- **Phase-grouped plans** (`PlanPhases.shouldGroup(tasks)`): each phase is a
  14pt semibold sub-header row (phase name + trailing `k/n` + "current" on the
  active phase per `PlanPhases.currentGroupIndex`); its tasks render beneath,
  slightly indented; phases separated by spacing (no rules). The phase header
  keeps its "Course correct…" context menu and opens the plan at the phase
  line (`onOpenDocAtLine`).
- **Per-task affordances unchanged:** hover-revealed "View changes"
  (`onViewTaskChanges`, only when the task has ≥1 checked step) and the
  context menu (View changes / Course correct…) — same behavior, restyled to
  the new row.

## Mode B — plain workspace (main / scratch)

Same hero surface, working-tree flavored. Working-tree status is loaded once
on appear via the existing `resolveWorktreeGitStatus` `@State headStatus`.

- **Pill:** clean tree (`insertions == 0 && deletions == 0`) → "Clean" ·
  green (`.done`). Dirty → "Uncommitted changes" · orange (`.waiting`), with
  the `+X −Y` shown in the meta line. Unknown (headStatus nil) → no pill.
- **Identity:** the workspace/branch name (rounded semibold).
- **Meta:** short sha (mono) · `+X −Y` when dirty · linked repos.
- **No progress bar** (there's no plan to measure).
- **Action row:** **Plan something here** (`sparkles`, `onNewPlan`) as the
  encouraged next step (soft-accent, not the green completion fill) +
  **Open terminal** (`session.createTab`) + **View changes**
  (`gateActions.openDiff`) + services control (`makeRunControls`).

**Project Runs board (main only):** the existing `projectRunsSection`
restyled onto the shared surface list. Section label "PROJECT RUNS". Each
`ProjectRun` row: `FlowStatusGlyph` glyph (via the existing `flowStatus(for:)`
map on `run.status`) + title + "`status.label · k/n`" meta + an
`OverviewProgressBar` (green when that run is complete, accent otherwise).
Empty state: the existing "No active runs…" hint, restyled `.tertiary`.

## New / changed files

- **New:** `Sources/Dreamux/Models/RunHeroState.swift` — the pure mapper above.
- **New:** `Sources/Dreamux/Models/OverviewModeBStatus.swift` (or a small
  helper in `RunHeroState.swift`) — the working-tree → pill mapping
  (`clean/dirty/unknown → text + FlowStatus`), kept pure for testing.
- **Changed:** `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — the whole
  view body (hero, checklist, actions, Mode B, Project Runs), plus small
  shared subviews (`OverviewHero`, status pill, section label,
  `OverviewProgressBar`). May be split into a couple of files if it grows
  unwieldy (e.g. `WorkspaceOverviewView+Hero.swift`), following the existing
  one-file-per-responsibility norm.

## Testing

- **`RunHeroStateTests`** — table-drive `resolve(status:hasLiveAgent:)` across
  every `(PlanStatus × hasLiveAgent)` combination, asserting `phase`,
  `pillText`, `flow`, `progressComplete`, and `primary`. This is the core new
  logic and is fully pure.
- **`OverviewModeBStatusTests`** — clean / dirty / unknown → correct pill text
  + `FlowStatus`.
- The label rule "Merge & continue vs Review & merge" is a pure branch on
  `(queue.state, currentPlanPath)`; if extracted to a tiny helper, unit-test
  it; otherwise it's exercised by the view.
- View rendering itself is not unit-tested (SwiftUI); everything it composes
  over (`WorkspacePlanResolver`, `ProjectRunsSummary`, `PlanPhases`,
  `docStore.status`) already has coverage.

## Open questions

None outstanding. Decisions locked: both modes in scope; Merged keeps a
subtle celebratory note; status/glyph color stays on the shared
`FlowStatusGlyph` vocabulary; primary action is state-derived.
