# Sidebar Dependency Legibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Workspaces rail show dependency structure through flat, signal-rich cards — waiting runs dim and their `after ↳ ⟨blocker⟩` becomes a scroll-to-and-flash link — with the multi-plan container gone.

**Architecture:** A pure `PlanBlocking` helper decides when a plan is waiting (and on whom); `PlansSpecsSection` flattens its rows (container deleted), dims a blocked card, and turns the after-caption into a `ScrollViewReader`-driven link. Parallel needs no code (already unmarked).

**Tech Stack:** SwiftUI, existing `PlanDoc`/`PlanStatus`/`DocStore`/`IntakeEnactment`, XCTest. No new dependencies.

**Spec:** docs/superpowers/specs/2026-07-12-sidebar-dependency-legibility-design.md — read it first.

## Global Constraints

- **Flat cards only** — no initiative container; family plans stay adjacent so a phased family reads as an `after ↳` chain.
- **Parallel is unmarked** (style C) — do NOT add any parallel marker; nothing renders `declaresParallel` today and it stays that way.
- **House style** (CLAUDE.md): hover wash `Color.primary.opacity(0.04)`; `RoundedRectangle(cornerRadius: 8, style: .continuous)`; the after-link uses `Color.accentColor`; reduce-motion honored for scroll/flash.
- **Waiting rule** (single source): a plan waits iff `Runs: after <blocker>`, the blocker is known + non-merged, and the waiter is still `.ready` — computed only in `PlanBlocking`.
- **Merged plans stay excluded** from the rail (archived to Flows) — unchanged.
- **Leave `InitiativeProgress`** (model + tests) in place; just stop calling it from this view.

## File Structure

- `Sources/Dreamux/Models/PlanBlocking.swift` (new) — pure waiting-detection helper.
- `Sources/Dreamux/Views/PlansSpecsSection.swift` (modify) — flatten rows, delete container, dim blocked card, after-link + scroll/flash.
- `Tests/DreamuxTests/PlanBlockingTests.swift` (new).

---

### Task 1: `PlanBlocking` — waiting detection

**Files:**
- Create: `Sources/Dreamux/Models/PlanBlocking.swift`
- Test: `Tests/DreamuxTests/PlanBlockingTests.swift`

**Interfaces:**
- Consumes: `PlanDoc` (`runsAfter`, `title`, `fileURL`), `PlanStatus`.
- Produces: `PlanBlocking.Blocker` (`title`, `fileURL`, `Equatable`) and `PlanBlocking.blocker(for:status:resolveBlocker:statusOf:) -> Blocker?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/DreamuxTests/PlanBlockingTests.swift
import XCTest
@testable import Dreamux

final class PlanBlockingTests: XCTestCase {
    private func plan(_ name: String, runsAfter: String? = nil) -> PlanDoc {
        PlanDoc(fileURL: URL(fileURLWithPath: "/p/\(name).md"), kind: .plan,
                title: name, date: nil, goal: nil, specReference: nil,
                runsAfter: runsAfter, declaresParallel: false,
                checkedSteps: 0, totalSteps: 1, tasks: [])
    }

    func testWaitingReturnsBlocker() {
        let blocker = plan("a")
        let waiter = plan("b", runsAfter: "docs/plans/a.md")
        let result = PlanBlocking.blocker(
            for: waiter, status: .ready,
            resolveBlocker: { _ in blocker }, statusOf: { _ in .running })
        XCTAssertEqual(result, PlanBlocking.Blocker(title: "a", fileURL: blocker.fileURL))
    }
    func testMergedBlockerIsNil() {
        let blocker = plan("a"); let waiter = plan("b", runsAfter: "docs/plans/a.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in blocker }, statusOf: { _ in .merged }))
    }
    func testWaiterNotReadyIsNil() {
        let blocker = plan("a"); let waiter = plan("b", runsAfter: "docs/plans/a.md")
        for s in [PlanStatus.running, .inProgress, .awaitingReview, .merged, .specOnly] {
            XCTAssertNil(PlanBlocking.blocker(for: waiter, status: s,
                resolveBlocker: { _ in blocker }, statusOf: { _ in .running }))
        }
    }
    func testNoRunsAfterIsNil() {
        let waiter = plan("b")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in nil }, statusOf: { _ in .running }))
    }
    func testUnresolvableBlockerIsNil() {
        let waiter = plan("b", runsAfter: "docs/plans/missing.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in nil }, statusOf: { _ in .running }))
    }
    func testSelfReferenceIsNil() {
        let waiter = plan("b", runsAfter: "docs/plans/b.md")
        XCTAssertNil(PlanBlocking.blocker(for: waiter, status: .ready,
            resolveBlocker: { _ in waiter }, statusOf: { _ in .running }))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter PlanBlockingTests`
Expected: FAIL — `PlanBlocking` undefined.

- [ ] **Step 3: Implement**

```swift
// Sources/Dreamux/Models/PlanBlocking.swift
import Foundation

/// Decides when a plan is *waiting* on another, for the Workspaces rail's
/// blocked treatment. A plan waits iff it declares `**Runs:** after
/// <blocker>`, the blocker resolves to a known, non-merged plan (and isn't
/// the plan itself), and the waiter is still `.ready` — the same condition
/// `IntakeEnactment.enact` uses to enqueue it. Pure over its resolvers.
enum PlanBlocking {
    struct Blocker: Equatable {
        let title: String    // for the `after ↳ <title>` caption
        let fileURL: URL     // the scroll-to / flash target
    }

    static func blocker(
        for plan: PlanDoc,
        status: PlanStatus,
        resolveBlocker: (String) -> PlanDoc?,
        statusOf: (PlanDoc) -> PlanStatus
    ) -> Blocker? {
        guard status == .ready,
              let reference = plan.runsAfter,
              let blocker = resolveBlocker(reference),
              blocker.fileURL != plan.fileURL,
              statusOf(blocker) != .merged
        else { return nil }
        return Blocker(title: blocker.title, fileURL: blocker.fileURL)
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter PlanBlockingTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanBlocking.swift Tests/DreamuxTests/PlanBlockingTests.swift
git commit -m "Sidebar: PlanBlocking — waiting detection"
```

---

### Task 2: Flatten `rows` — delete the multi-plan container

No unit-test harness for this view (verified by `swift build` + inspection, as in prior slices).

**Files:**
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift`

**Interfaces:**
- Consumes: `docStore.initiatives`, `docStore.status(for:featureExists:)`.
- Produces: a flat `planRow(_ plan: PlanDoc, status: PlanStatus)` (signature loses `ordinal`/`blockedBy`).

- [ ] **Step 1: Flatten the `rows` loop** (`PlansSpecsSection.swift:285`)

Replace the `active` loop body so every non-merged plan renders as a flat `planRow`, keeping family plans adjacent, and tag each row for scroll-targeting (Task 3 uses the `.id`):

```swift
ForEach(active) { initiative in
    ForEach(initiative.plans) { plan in
        let status = statuses[plan.fileURL] ?? .ready
        if status != .merged {
            planRow(plan, status: status)
                .id(plan.fileURL)
        }
    }
}
```
Leave the `needsPlan` and loose-docs blocks unchanged.

- [ ] **Step 2: Delete the container + its now-orphaned helpers/state**

Remove `multiPlanBlock` and `initiativeGroupingRow`. Then remove every helper and `@State` that has **no remaining caller** (grep each before deleting): likely `progressSummary`, `runRemaining`, `isInitiativeExpanded`, `setInitiative`, `queueParked`, the `hoveredInitiativeID` state, the expanded-initiatives state, and a `docChips(for: Initiative)` overload if it's now callerless. Do NOT delete anything still referenced (e.g. `supportingChips`/`chipLine` used by `needsPlan`, or `InitiativeProgress` the model). If unsure whether a symbol is orphaned, `grep -rn "<name>" Sources` — keep it if any non-deleted code calls it.

- [ ] **Step 3: Simplify `planRow` + `planMetaLine` signatures**

- `planRow(_ plan: PlanDoc, status: PlanStatus, ordinal: Int?, blockedBy: Int?)` → `planRow(_ plan: PlanDoc, status: PlanStatus)`. Delete the `if let ordinal { Text("\(ordinal) ·") … }` block from the title `HStack`.
- `planMetaLine(_ plan:, blockedBy: Int?, afterCaption: String?)` → `planMetaLine(_ plan:, afterCaption: String?)`. Delete the `if let blockedBy { Text("blocked by \(blockedBy)") … }` block. Keep the `afterCaption` (plain `Text`, for now) and the `auto-run failed` block. Update `planRow`'s call site to drop `blockedBy:`.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!` (no unused-symbol errors — confirms the deletions were complete and no live caller was cut).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift
git commit -m "Sidebar: flat cards — drop the multi-plan container"
```

---

### Task 3: Blocked dim + clickable `after ↳` link (scroll + flash)

Verified by `swift build` + inspection.

**Files:**
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift`

**Interfaces:**
- Consumes: `PlanBlocking.blocker(...)` (Task 1), `docStore.resolvedURL(forReference:)`, `docStore.plans`, `docStore.status(for:featureExists:)`, the `.id(plan.fileURL)` set in Task 2.
- Produces: a dimmed blocked card and an `after ↳` link that scrolls to + flashes the blocker.

- [ ] **Step 1: Wrap the section content in a `ScrollViewReader` + add flash state**

Add state near the other `@State`:
```swift
    @State private var flashedPlanURL: URL?
    @State private var scrollProxy: ScrollViewProxy?
```
Wrap the `rows` VStack (or the smallest ancestor that contains all `planRow`s) in `ScrollViewReader { proxy in … }` and capture it: `.onAppear { scrollProxy = proxy }` (or thread `proxy` directly if cleaner). `scrollTo` will scroll the sidebar's existing `ScrollView` ancestor to the `.id(plan.fileURL)` rows.

- [ ] **Step 2: Compute the blocker in `planRow` and dim**

At the top of `planRow`:
```swift
let blocker = PlanBlocking.blocker(
    for: plan, status: status,
    resolveBlocker: { ref in
        let target = docStore.resolvedURL(forReference: ref)
        return docStore.plans.first { $0.fileURL.standardizedFileURL == target }
    },
    statusOf: { docStore.status(for: $0, featureExists: featureExists) })
```
Apply to the card's outer `VStack`: `.opacity(blocker != nil ? 0.78 : 1)`.
Pass `blocker` into `planMetaLine` (replace the `afterCaption:` argument): `planMetaLine(plan, blocker: blocker)`.

Add the flash to `planRow`'s `.background` (alongside the existing hover wash):
```swift
.background {
    if flashedPlanURL == plan.fileURL {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .padding(.horizontal, 4)
    } else if isHovered {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .padding(.horizontal, 4)
    }
}
```

- [ ] **Step 3: Turn the after-caption into a link in `planMetaLine`**

Change `planMetaLine(_ plan:, afterCaption: String?)` → `planMetaLine(_ plan:, blocker: PlanBlocking.Blocker?)`. Replace the plain `afterCaption` `Text` with a link (keep the `auto-run failed` block):
```swift
if let blocker {
    Button {
        jumpToBlocker(blocker.fileURL)
    } label: {
        Text("after ↳ \(blocker.title)")
            .font(.system(size: 13))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1).truncationMode(.tail)
    }
    .buttonStyle(.plain)
    .help("Waiting on “\(blocker.title)” — jump to it")
}
```
Also update the guard that decides whether the meta line renders anything (it now keys on `blocker != nil || failure != nil`).

- [ ] **Step 4: Add the jump-to-blocker action** (respecting reduce-motion)

```swift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // ...
    private func jumpToBlocker(_ url: URL) {
        if reduceMotion {
            scrollProxy?.scrollTo(url, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy?.scrollTo(url, anchor: .center)
            }
        }
        flashedPlanURL = url
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            if flashedPlanURL == url {
                withAnimation(.easeInOut(duration: 0.3)) { flashedPlanURL = nil }
            }
        }
    }
```
(If `@Environment` for reduce-motion is already present on the view, reuse it.)

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Manually verify**

On a project with a `Runs: after` chain: the waiting card is dimmed and shows `after ↳ ⟨blocker⟩`; clicking it scrolls to + flashes the blocker card. A ready/running plan with no blocker is undimmed with no link. A plan whose blocker has merged is undimmed. Reduce Motion → no scroll animation / fade.

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift
git commit -m "Sidebar: dim blocked runs + clickable after-link (scroll + flash)"
```

---

## Self-Review

- **Spec coverage:** flatten + delete container (Task 2), `PlanBlocking` (Task 1), dim + clickable after-link + scroll/flash + reduce-motion (Task 3), parallel-unmarked (no code, per Global Constraints), mini-map deferred (out of scope). All spec sections map to a task or a constraint.
- **Type consistency:** `PlanBlocking.blocker(for:status:resolveBlocker:statusOf:)` and `Blocker(title:fileURL:)` used identically in Task 1 and Task 3; `planRow(_:status:)` and `planMetaLine(_:blocker:)` are the final signatures after Tasks 2–3.
- **No placeholders:** Task 1 carries full code + commands; Tasks 2–3 give the exact edits with grep-before-delete guidance and build checks.
