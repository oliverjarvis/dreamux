# Sidebar Dependency Legibility — Design

**Slice 2 of the graph roadmap** (1 subagents ✓ → **2 sidebar** → 3 Flows-as-graph). Makes the Workspaces rail show dependency *structure* through flat, signal-rich cards instead of opaque text captions.

## Goal

In the Workspaces rail: a run **waiting** on another reads as waiting (dimmed) and its `after ↳ ⟨blocker⟩` becomes a **clickable link** that scrolls to and flashes the blocker; everything else is a plain flat card. Drop the multi-plan **initiative container** — a phased family renders as a flat `after ↳` chain, not a grouping row that isn't a workspace.

## Design decisions (settled in brainstorming)

- **Flat cards only.** No initiative container. (Nothing in the app's prompts creates multi-plan `-phase-N` families — verified in `PlanPrompts.swift`/`DREAMUX.md`; the container renders a case the app never generates and reads as "a workspace that isn't a workspace.")
- **Parallel is unmarked (style C).** Independence is the default; only *waits* get a marker. Confirmed no code renders `declaresParallel` today, so this needs **no change** — it's already the behavior.
- **Phases live in the Overview**, not the sidebar: `phase → task → step` is already rendered per-plan by the Overview checklist (`PlanPhases` + `phaseSection`). The sidebar shows the *between-plan* relationship only (`after ↳`).

## Scope

- **In:** flatten `rows`; delete the container; dim a blocked card; turn `after ↳` into a scroll-to-and-flash link; a pure `PlanBlocking` helper + tests.
- **Out (deferred):**
  - **The mini-map (the "C" bridge) rides with slice 3.** It's a thumbnail of a *project plan-dependency graph* that doesn't exist yet; building that graph model once and rendering it as both the mini-map and the full Flows canvas is DRY. Building a bespoke mini-map here and a separate graph in slice 3 duplicates layout. So the mini-map is the first task of slice 3, not slice 2.
  - Any change to intake/prompts (per-phase plan generation) — a separate future slice.

## Current state (grounded in `PlansSpecsSection.swift`)

- **`rows`** (`:285`) iterates `docStore.initiatives` (active first); `initiative.plans.count > 1` → `multiPlanBlock` (container), else → `planRow(…, ordinal: nil, blockedBy: nil)`.
- **`multiPlanBlock`** (`:348`) + **`initiativeGroupingRow`** (`:375`): the collapsible container — an aggregate glyph/title/`plan k/n · pct` parent, then each phase as an indented child `planRow` carrying an `ordinal` and a **positional** `blockedBy` (from `InitiativeProgress.blockingOrdinal`, i.e. "phase 2 is blocked because it's 2nd" — not from a declared `Runs: after`).
- **`planRow`** (`:653`): the card — status glyph, optional `ordinal`, title, `liveFlowDot`, unread dot, `planMetaLine`, progress bar, `Current: …` line, action row. Hover wash; click activates the workspace (or opens the doc pre-run).
- **`planMetaLine`** (`:763`): renders `blocked by k` (positional), the **`afterCaption`** (`after ⟨title⟩`, from `IntakeEnactment.afterCaption(runsAfter:)`, resolved via `DocStore`), and `auto-run failed` — all plain `Text` in `.tertiary`.
- `afterCaption` is computed in `planRow` (`:665`) from `plan.runsAfter`.

## Components

### 1. `PlanBlocking` (new, pure helper)

`Sources/Dreamux/Models/PlanBlocking.swift`

A plan is **waiting** when it declares `Runs: after <blocker>`, the blocker resolves to a **known, non-merged** plan, and the waiter itself is still `.ready` (mirrors `IntakeEnactment.enact`'s condition — the same rule the queue enacts). The helper returns the blocker so the view can both dim the card and link to it.

```swift
enum PlanBlocking {
    struct Blocker: Equatable {
        let title: String    // for the `after ↳ <title>` caption
        let fileURL: URL     // the scroll-to / flash target
    }

    /// The plan this one is currently waiting on, or nil (not waiting).
    /// `resolveBlocker` maps the raw `runsAfter` reference to its PlanDoc
    /// (DocStore's resolve discipline); `statusOf` gives any plan's derived
    /// status. Waiting requires: a runsAfter reference, a known non-merged
    /// blocker that isn't the plan itself, and the waiter still `.ready`.
    static func blocker(
        for plan: PlanDoc,
        status: PlanStatus,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> Blocker? {
        guard status == .ready, let reference = plan.runsAfter,
              let blocker = resolveBlocker(reference),
              blocker.fileURL != plan.fileURL,
              statusOf(blocker) != .merged
        else { return nil }
        return Blocker(title: blocker.title, fileURL: blocker.fileURL)
    }
}
```

### 2. `rows` — flatten (delete the container)

`PlansSpecsSection.swift:285`. Render **every** active plan as a flat `planRow`, keeping a family's plans adjacent (so a phased family reads as an `after ↳` chain) by iterating initiatives then their plans:

```swift
VStack(spacing: 2) {
    ForEach(active) { initiative in
        ForEach(initiative.plans) { plan in
            let status = statuses[plan.fileURL] ?? .ready
            if status != .merged {                 // merged runs stay archived to Flows
                planRow(plan, status: status)
                    .id(plan.fileURL)              // scroll-to target (Component 4)
            }
        }
    }
    ForEach(needsPlan) { initiative in /* unchanged: specOnlyRow + chips */ }
    // loose docs disclosure: unchanged
}
```

Then **delete** the now-unreachable container code, verifying each has no other caller before removing: `multiPlanBlock`, `initiativeGroupingRow`, `progressSummary`, `runRemaining`, `isInitiativeExpanded`, `setInitiative`, `queueParked` (if container-only), and the `@State` `hoveredInitiativeID` + the expanded-initiatives state. **Leave `InitiativeProgress`** (the model) and its tests in place — it's still valid and slice 3's mini-map will likely reuse it for aggregates; we simply stop calling it from this view.

### 3. `planRow` — drop ordinal/blockedBy, dim when blocked

- Change the signature to `planRow(_ plan: PlanDoc, status: PlanStatus)` — remove `ordinal` and `blockedBy` (container-only). Remove the `if let ordinal { Text("\(ordinal) ·") }` block.
- Compute the blocker and dim:

```swift
let blocker = PlanBlocking.blocker(
    for: plan, status: status,
    resolveBlocker: { ref in
        let target = docStore.resolvedURL(forReference: ref)
        return docStore.plans.first { $0.fileURL.standardizedFileURL == target }
    },
    statusOf: { docStore.status(for: $0, featureExists: featureExists) })
```

- Apply `.opacity(blocker != nil ? 0.78 : 1)` to the card's content (the outer `VStack`), so a waiting run visibly recedes.
- Pass `blocker` into `planMetaLine` (replacing `blockedBy`/`afterCaption`).

### 4. `planMetaLine` — the `after ↳` link (scroll + flash)

- New signature: `planMetaLine(_ plan: PlanDoc, blocker: PlanBlocking.Blocker?)`. Drop the positional `blocked by k` entirely. Keep `auto-run failed`.
- When `blocker != nil`, render a **button** (not `Text`):

```swift
Button {
    withAnimation(.easeInOut(duration: 0.25)) {
        scrollProxy?.scrollTo(blocker.fileURL, anchor: .center)
    }
    flashPlan(blocker.fileURL)
} label: {
    Text("after ↳ \(blocker.title)")
        .font(.system(size: 13))
        .foregroundStyle(Color.accentColor)
        .lineLimit(1).truncationMode(.tail)
}
.buttonStyle(.plain)
.help("Waiting on “\(blocker.title)” — jump to it")
```

- **Scroll plumbing:** wrap the section's content in `ScrollViewReader { proxy in … }` and thread the `proxy` down (a stored `scrollProxy` on the view, or a small `@Environment`-free pass-through). `scrollTo` scrolls the sidebar's existing `ScrollView` ancestor to the `.id(plan.fileURL)` set in Component 2.
- **Flash:** `@State private var flashedPlanURL: URL?`. `flashPlan(url)` sets it, then clears after ~1.1s (`Task { try? await Task.sleep(for: .seconds(1.1)); if flashedPlanURL == url { withAnimation { flashedPlanURL = nil } } }`). In `planRow`'s `.background`, when `flashedPlanURL == plan.fileURL` fill the rounded rect with `Color.accentColor.opacity(0.22)` (fades out when cleared). Honor reduce-motion: if `accessibilityReduceMotion`, skip the scroll animation and use a brief outline instead of a fade.

### 5. Parallel — no change

Confirmed nothing renders `declaresParallel`; unmarked (C) is already the behavior. No code.

## Data flow

`plan.runsAfter` → `PlanBlocking.blocker(…)` (pure) → the card dims + `planMetaLine` shows the link → click → `scrollProxy.scrollTo(blocker.fileURL)` + `flashPlan` → the blocker's `.id`'d card flashes. All derived; no persistence.

## States & edge cases

| Condition | Behavior |
|---|---|
| Plan not `.ready`, or no `runsAfter` | `blocker == nil` — plain card, no dim, no link |
| `runsAfter` resolves to a **merged** blocker | `blocker == nil` — the wait is over; plain card |
| `runsAfter` path doesn't resolve to a known plan | `blocker == nil` (no link); the *existing* `afterCaption` `<file> (missing)` fallback is **out of scope here** — a missing blocker just renders as a normal ready plan (documented tradeoff; the queue already treats it as ready) |
| Blocker is off-screen | `scrollTo(anchor: .center)` brings it into view, then it flashes |
| Reduce motion | no scroll animation / fade; brief outline on the target |
| Merged plans | still excluded from the rail (archived to Flows) — unchanged |

## Testing

- **`PlanBlockingTests`** (pure):
  - `runsAfter` → non-merged known blocker + waiter `.ready` → returns `Blocker(title, fileURL)`.
  - blocker is `.merged` → nil. Waiter not `.ready` (running/inProgress/awaitingReview/merged) → nil.
  - `runsAfter == nil` → nil. Reference resolves to nothing → nil. Reference resolves to the plan itself → nil.
- View changes (flatten, dim, link, scroll/flash) have no unit harness in this codebase (same as slices past); verified by `swift build` + inspection. The flatten is also covered indirectly: existing `PlansSpecsSection`-adjacent tests must stay green, and `InitiativeProgressTests` stay green (model untouched).

## Files

- Create: `Sources/Dreamux/Models/PlanBlocking.swift`
- Create: `Tests/DreamuxTests/PlanBlockingTests.swift`
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift` — flatten `rows`, delete container + its exclusive helpers/state, simplify `planRow`/`planMetaLine`, add `ScrollViewReader`/`.id`/flash.
