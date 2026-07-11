# Workspace Overview Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the workspace Overview page (both plan-backed Mode A and plain-workspace Mode B) as a polished, restrained run dashboard with a state-aware hero, surfaces instead of divider rules, and meaningful status color.

**Architecture:** Two new pure mappers (`RunHeroState`, `OverviewModeBStatus`) turn run/working-tree state into a hero treatment and are TDD'd directly. A small set of shared SwiftUI primitives (status pill, colored progress capsule, section label, surface modifier) is built once and reused by both modes. The rest is a rewrite of `WorkspaceOverviewView`'s body over those pieces, keeping the injected `WorkspaceOverviewDependencies` closures — and their mechanics — unchanged.

**Tech Stack:** Swift 6 / SwiftUI / SwiftPM, XCTest. Build: `swift build`. Tests: `swift test` (filter with `--filter <Suite>`).

## Global Constraints

- Status color + glyph come from the shared `FlowStatusGlyph` vocabulary: `FlowStatus.running` and `.waiting` → `.orange`; `.done` → `.green`; `.queued` → `.secondary`. Never introduce a divergent "running" tint.
- Progress bars are the app's `Capsule`-based bar, NEVER the system `ProgressView`. Fill color is a separate axis from status: **green (`Color.green`) when the run is complete** (awaiting review / merged), **`Color.accentColor` while incomplete**.
- No `Divider()` between Overview sections. Group content on subtle surface cards (`RoundedRectangle(cornerRadius: 14)` fill `Color.primary.opacity(0.04)` + `Color.primary.opacity(0.06)` hairline) and separate sections with uppercase section labels + spacing.
- Type scale (generous, per CLAUDE.md): hero title 22pt `.rounded` semibold; section labels 12pt semibold uppercase kern ~0.6 `.secondary`; task/run titles 15pt; all numeric counts `.monospacedDigit()` 12–13pt; meta 13pt `.secondary`.
- Content sits in a column capped at **860pt** max width, leading-aligned.
- The `WorkspaceOverviewDependencies` public shape is FROZEN — no new closures, no signature changes. The redesign is internal to `WorkspaceOverviewView`.
- Respect `prefers-reduced-motion` (the pulsing "Running" dot must not animate under Reduce Motion).

---

### Task 1: `RunHeroState` mapper

**Files:**
- Create: `Sources/Dreamux/Models/RunHeroState.swift`
- Test: `Tests/DreamuxTests/RunHeroStateTests.swift`

**Interfaces:**
- Consumes: `PlanStatus` (`Sources/Dreamux/Models/PlanStatus.swift` — cases `specOnly, ready, inProgress, running, awaitingReview, merged`), `FlowStatus` (`Sources/Dreamux/Models/FlowGraph.swift` — `queued, running, waiting, done, failed`).
- Produces: `RunHeroState` value with `phase: Phase`, `pillText: String`, `flow: FlowStatus`, `progressComplete: Bool`, `primary: PrimaryAction`; `enum Phase { ready, running, paused, awaitingReview, merged }`; `enum PrimaryAction { run, running, reviewAndMerge, noPrimary }`; `static func resolve(status: PlanStatus, hasLiveAgent: Bool) -> RunHeroState`.

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/RunHeroStateTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class RunHeroStateTests: XCTestCase {
    func testMergedIsDoneWithNoPrimary() {
        let s = RunHeroState.resolve(status: .merged, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .merged)
        XCTAssertEqual(s.flow, .done)
        XCTAssertTrue(s.progressComplete)
        XCTAssertEqual(s.primary, .noPrimary)
        XCTAssertEqual(s.pillText, "Merged")
    }

    func testAwaitingReviewOffersReviewAndMerge() {
        let s = RunHeroState.resolve(status: .awaitingReview, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .awaitingReview)
        XCTAssertEqual(s.flow, .waiting)
        XCTAssertTrue(s.progressComplete)
        XCTAssertEqual(s.primary, .reviewAndMerge)
        XCTAssertEqual(s.pillText, "Awaiting your review")
    }

    func testRunningWithLiveAgent() {
        let s = RunHeroState.resolve(status: .running, hasLiveAgent: true)
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.flow, .running)
        XCTAssertFalse(s.progressComplete)
        XCTAssertEqual(s.primary, .running)
        XCTAssertEqual(s.pillText, "Running")
    }

    func testRunningWithoutAgentIsPaused() {
        let s = RunHeroState.resolve(status: .running, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.flow, .queued)
        XCTAssertEqual(s.primary, .run)
        XCTAssertEqual(s.pillText, "Paused")
    }

    func testInProgressWithoutAgentIsPaused() {
        let s = RunHeroState.resolve(status: .inProgress, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.primary, .run)
    }

    func testInProgressWithAgentRuns() {
        let s = RunHeroState.resolve(status: .inProgress, hasLiveAgent: true)
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.primary, .running)
    }

    func testReadyIsRunnable() {
        let s = RunHeroState.resolve(status: .ready, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.flow, .queued)
        XCTAssertEqual(s.primary, .run)
        XCTAssertEqual(s.pillText, "Ready to run")
    }

    func testSpecOnlyFallsBackToReady() {
        let s = RunHeroState.resolve(status: .specOnly, hasLiveAgent: false)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.primary, .run)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter RunHeroStateTests 2>&1 | tail -20`
Expected: FAIL — compile error "cannot find 'RunHeroState' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Dreamux/Models/RunHeroState.swift`:

```swift
import Foundation

/// Maps a plan-backed run's derived state to the Overview hero's treatment:
/// which status pill to show, which `FlowStatus` color it takes, whether the
/// progress bar reads "complete" (green) or "in flight" (accent), and which
/// primary action the run's moment calls for. Pure and total so it can be
/// table-tested without the view.
struct RunHeroState: Equatable {
    enum Phase: Equatable { case ready, running, paused, awaitingReview, merged }
    enum PrimaryAction: Equatable {
        case run             // lime RunPlanButton — start or resume the plan agent
        case running         // RunningIndicator — agent is live; not a button
        case reviewAndMerge  // filled button → gateActions.requestMerge
        case noPrimary       // merged — no primary action
    }

    let phase: Phase
    let pillText: String
    let flow: FlowStatus        // -> FlowStatusGlyph.color/.symbol for the pill
    let progressComplete: Bool  // green bar when true, accent bar when false
    let primary: PrimaryAction

    /// `status` is `docStore.status(for:)`; `hasLiveAgent` is whether a live
    /// claude agent tab is working this workspace (the same signal the rail
    /// uses). A materialized Mode-A workspace never actually reports
    /// `.ready`/`.specOnly`, but both are handled for totality.
    static func resolve(status: PlanStatus, hasLiveAgent: Bool) -> RunHeroState {
        switch status {
        case .merged:
            return RunHeroState(phase: .merged, pillText: "Merged",
                                flow: .done, progressComplete: true, primary: .noPrimary)
        case .awaitingReview:
            return RunHeroState(phase: .awaitingReview, pillText: "Awaiting your review",
                                flow: .waiting, progressComplete: true, primary: .reviewAndMerge)
        case .running, .inProgress:
            if hasLiveAgent {
                return RunHeroState(phase: .running, pillText: "Running",
                                    flow: .running, progressComplete: false, primary: .running)
            }
            return RunHeroState(phase: .paused, pillText: "Paused",
                                flow: .queued, progressComplete: false, primary: .run)
        case .ready, .specOnly:
            return RunHeroState(phase: .ready, pillText: "Ready to run",
                                flow: .queued, progressComplete: false, primary: .run)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter RunHeroStateTests 2>&1 | tail -6`
Expected: PASS — "Executed 8 tests, with 0 failures".

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/RunHeroState.swift Tests/DreamuxTests/RunHeroStateTests.swift
git commit -m "Overview: RunHeroState — run state -> hero treatment mapper"
```

---

### Task 2: `OverviewModeBStatus` mapper

**Files:**
- Create: `Sources/Dreamux/Models/OverviewModeBStatus.swift`
- Test: `Tests/DreamuxTests/OverviewModeBStatusTests.swift`

**Interfaces:**
- Consumes: `FlowStatus` (`Sources/Dreamux/Models/FlowGraph.swift`).
- Produces: `enum OverviewModeBStatus` with `struct Pill: Equatable { let text: String; let flow: FlowStatus }` and `static func pill(insertions: Int?, deletions: Int?) -> Pill?` (nil = unknown → no pill).

- [ ] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/OverviewModeBStatusTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class OverviewModeBStatusTests: XCTestCase {
    func testUnknownWhenNil() {
        XCTAssertNil(OverviewModeBStatus.pill(insertions: nil, deletions: nil))
    }

    func testCleanTree() {
        XCTAssertEqual(OverviewModeBStatus.pill(insertions: 0, deletions: 0),
                       OverviewModeBStatus.Pill(text: "Clean", flow: .done))
    }

    func testInsertionsAreDirty() {
        let p = OverviewModeBStatus.pill(insertions: 12, deletions: 3)
        XCTAssertEqual(p?.text, "Uncommitted changes")
        XCTAssertEqual(p?.flow, .waiting)
    }

    func testDeletionsOnlyAreDirty() {
        let p = OverviewModeBStatus.pill(insertions: 0, deletions: 5)
        XCTAssertEqual(p?.flow, .waiting)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter OverviewModeBStatusTests 2>&1 | tail -20`
Expected: FAIL — "cannot find 'OverviewModeBStatus' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/Dreamux/Models/OverviewModeBStatus.swift`:

```swift
import Foundation

/// Maps a plain (plan-less) workspace's working-tree summary to the Overview
/// hero pill. `nil` insertions/deletions mean the git status hasn't resolved
/// yet — no pill. Pure for testing; the view passes
/// `headStatus?.insertions` / `headStatus?.deletions`.
enum OverviewModeBStatus {
    struct Pill: Equatable {
        let text: String
        let flow: FlowStatus
    }

    static func pill(insertions: Int?, deletions: Int?) -> Pill? {
        guard let insertions, let deletions else { return nil }
        if insertions == 0 && deletions == 0 {
            return Pill(text: "Clean", flow: .done)
        }
        return Pill(text: "Uncommitted changes", flow: .waiting)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter OverviewModeBStatusTests 2>&1 | tail -6`
Expected: PASS — "Executed 4 tests, with 0 failures".

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/OverviewModeBStatus.swift Tests/DreamuxTests/OverviewModeBStatusTests.swift
git commit -m "Overview: OverviewModeBStatus — working-tree -> hero pill mapper"
```

---

### Task 3: Shared Overview view primitives

**Files:**
- Create: `Sources/Dreamux/Views/OverviewPrimitives.swift`

**Interfaces:**
- Consumes: `FlowStatus`, `FlowStatusGlyph` (`Sources/Dreamux/Views/FlowLaneView.swift` — `static func color(_:) -> Color`, `static func symbol(_:) -> String`).
- Produces (used by Tasks 4–6):
  - `OverviewStatusPill(text: String, flow: FlowStatus, pulse: Bool = false)`
  - `OverviewProgressBar(fraction: Double, complete: Bool)`
  - `OverviewSectionLabel(title: String, trailing: String? = nil)`
  - `View.overviewSurface(padding: CGFloat = 18, radius: CGFloat = 14) -> some View`

- [ ] **Step 1: Write the primitives**

Create `Sources/Dreamux/Views/OverviewPrimitives.swift`:

```swift
import SwiftUI

/// Shared building blocks for the workspace Overview (Mode A + Mode B), so
/// both read as one page: a status pill colored from the FlowStatus
/// vocabulary, the app's Capsule progress bar, an uppercase section label,
/// and the subtle surface-card modifier used in place of Divider rules.

/// A `Capsule` status chip. Color/glyph come from the shared FlowStatus
/// vocabulary (Global Constraint). `pulse` breathes the leading dot for the
/// live "Running" state, suppressed under Reduce Motion.
struct OverviewStatusPill: View {
    let text: String
    let flow: FlowStatus
    var pulse: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let color = FlowStatusGlyph.color(flow)
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(pulse && !reduceMotion && breathing ? 0.35 : 1)
                .animation(pulse && !reduceMotion
                           ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                           : nil,
                           value: breathing)
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.16)))
        .onAppear { if pulse { breathing = true } }
    }
}

/// The app's Capsule progress bar (matches `PlansSpecsSection.planProgressBar`),
/// green when the run is complete and accent while it's in flight.
struct OverviewProgressBar: View {
    let fraction: Double
    let complete: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(complete ? Color.green : Color.accentColor)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 7)
    }
}

/// A 12pt uppercase section label with an optional trailing count.
struct OverviewSectionLabel: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// The Overview's shared surface card: subtle fill + hairline border,
    /// radius 14 — used in place of `Divider()` rules to group content.
    func overviewSurface(padding: CGFloat = 18, radius: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: "Build complete!" (the primitives are unused so far — Swift does not warn on unused types).

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/OverviewPrimitives.swift
git commit -m "Overview: shared primitives — status pill, progress bar, section label, surface"
```

---

### Task 4: Mode A hero

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — replace `modeA(_:)`, and remove `header(_:status:)`, `specAndProgress(_:)`, `actionsRow(_:)`, `gateSection(_:)`. Keep `flowStatus(for:)` (Mode B uses it), `docChips(for:)`, `checklist(_:)` (Task 5 restyles it), and `openOrFocusTerminal()`.

**Interfaces:**
- Consumes: `RunHeroState.resolve(status:hasLiveAgent:)` (Task 1); `OverviewStatusPill`, `OverviewProgressBar`, `OverviewSectionLabel`, `overviewSurface` (Task 3); existing injected members `docStore`, `repoStore`, `planQueue`, `session`, `hasLiveAgent`, `makeRunControls`, `onRunPlan`, `gateActions`, `onOpenDoc`; existing `RunPlanButton`, `RunningIndicator`, `BranchChangesButton` (bottom of this file).
- Produces: nothing new consumed downstream (Task 5 owns `checklist`).

- [ ] **Step 1: Replace `modeA(_:)` and add the hero helpers**

In `WorkspaceOverviewView.swift`, replace the entire `modeA(_ plan:)` function (currently the `ScrollView` with `header → Divider → specAndProgress → Divider → checklist → Divider → actionsRow → gateSection`) with:

```swift
    // MARK: - Mode A

    private func modeA(_ plan: PlanDoc) -> some View {
        // The workspace exists (we're rendering its tab), so `featureExists`
        // is trivially true here.
        let status = docStore.status(for: plan, featureExists: { _ in true })
        let hero = RunHeroState.resolve(status: status, hasLiveAgent: hasLiveAgent(session.workspace))
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard(plan, hero: hero)
                OverviewSectionLabel(title: "Tasks", trailing: "\(tasks.count) tasks")
                checklist(plan)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Mode A hero

    private func heroCard(_ plan: PlanDoc, hero: RunHeroState) -> some View {
        let startedAt = docStore.ledger.recordForPlan(docStore.relativePath(of: plan))?.startedAt
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OverviewStatusPill(text: hero.pillText, flow: hero.flow,
                                   pulse: hero.phase == .running)
                Spacer(minLength: 0)
                if let startedAt {
                    (Text("Started ") + Text(startedAt, style: .relative) + Text(" ago"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
                makeRunControls(session.workspace)
            }
            Text(plan.title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
            heroMeta(plan)
                .padding(.top, 9)
            if plan.totalSteps > 0 {
                heroProgress(plan, complete: hero.progressComplete)
                    .padding(.top, 17)
            }
            if hero.phase == .merged {
                mergedNote()
                    .padding(.top, 16)
            }
            heroActions(plan, hero: hero)
                .padding(.top, 16)
        }
        .overviewSurface(padding: 20)
    }

    private func heroMeta(_ plan: PlanDoc) -> some View {
        let chips = docChips(for: plan)
        return HStack(spacing: 9) {
            Label(session.workspace.name, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
            if !session.workspace.linkedRepoIDs.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
            }
            if !chips.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.tertiary)
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    if index > 0 { Text("·").foregroundStyle(.tertiary) }
                    Button { onOpenDoc(chip.url) } label: {
                        Text(chip.label).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func heroProgress(_ plan: PlanDoc, complete: Bool) -> some View {
        let fraction = Double(plan.checkedSteps) / Double(max(1, plan.totalSteps))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(plan.checkedSteps) / \(plan.totalSteps) steps")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(complete ? Color.green : Color.secondary)
                Spacer(minLength: 0)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            OverviewProgressBar(fraction: fraction, complete: complete)
        }
    }

    private func mergedNote() -> some View {
        let base = repoStore.repositories.first?.defaultBranch ?? "main"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.green)
            Text("Merged — this run's changes are on \(base).")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func heroActions(_ plan: PlanDoc, hero: RunHeroState) -> some View {
        HStack(spacing: 10) {
            switch hero.primary {
            case .run:
                RunPlanButton { onRunPlan(plan) }
            case .running:
                RunningIndicator()
            case .reviewAndMerge:
                Button {
                    gateActions.requestMerge(session.workspace.id)
                } label: {
                    Label(mergePrimaryLabel(plan), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            case .noPrimary:
                EmptyView()
            }
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Button(action: openOrFocusTerminal) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.soft)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    /// "Merge & continue" when this plan is the queue's current gate (so the
    /// queue advances), else "Review & merge". Both call the same
    /// `gateActions.requestMerge`, which itself routes queue-gated vs. off-queue.
    private func mergePrimaryLabel(_ plan: PlanDoc) -> String {
        if planQueue.state == .atGate,
           planQueue.currentPlanPath == docStore.relativePath(of: plan) {
            return "Merge & continue"
        }
        return "Review & merge"
    }
```

Then DELETE the now-unused functions `header(_:status:)`, `specAndProgress(_:)`, `actionsRow(_:)`, and `gateSection(_:)`. Leave `flowStatus(for:)`, `docChips(for:)`, `checklist(_:)`, `phaseSection`, `taskRows`, `taskRow`, and `openOrFocusTerminal()` in place.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -6`
Expected: "Build complete!" (If the compiler flags an unused `GateActionCard` import or `status` binding, remove only the dead reference — do not touch the Mode B code.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceOverviewView.swift
git commit -m "Overview: Mode A hero — state-aware pill, colored progress, primary action"
```

---

### Task 5: Mode A checklist restyle

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — replace `checklist(_:)`, `phaseSection(_:plan:isCurrentGroup:)`, `taskRows(_:plan:)`, `taskRow(_:plan:isCurrent:)`; add helpers `cleanTitle`, `checkGlyph`, `currentTag`.

**Interfaces:**
- Consumes: `overviewSurface` (Task 3); `PlanPhases.shouldGroup/groups/currentGroupIndex` and `PlanPhases.Group` (`Sources/Dreamux/Models/PlanPhases.swift`, fields `phase: String?`, `tasks: [PlanTask]`, `checkedSteps`, `totalSteps`); `PlanTask` (`title`, `steps`, `line`, `phaseLine`); existing `hoveredTaskLine`, `onOpenDocAtLine`, `onViewTaskChanges`, `correcting`, `CorrectionTarget`, `CourseCorrection.Anchor`.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Replace the checklist functions**

Replace `checklist(_:)`, `phaseSection(...)`, `taskRows(...)`, and `taskRow(...)` with:

```swift
    // MARK: - Checklist

    @ViewBuilder
    private func checklist(_ plan: PlanDoc) -> some View {
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        // Global 1-based task numbers, keyed by line (unique per task).
        let numbers = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($1.line, $0 + 1) })
        VStack(alignment: .leading, spacing: PlanPhases.shouldGroup(tasks) ? 14 : 2) {
            if PlanPhases.shouldGroup(tasks) {
                let groups = PlanPhases.groups(tasks)
                let currentGroup = PlanPhases.currentGroupIndex(groups)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    phaseSection(group, plan: plan, numbers: numbers,
                                 isCurrentGroup: index == currentGroup)
                }
            } else {
                let currentIndex = tasks.firstIndex { $0.steps.contains { !$0.checked } }
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    taskRow(task, number: index + 1, plan: plan, isCurrent: index == currentIndex)
                }
            }
        }
        .overviewSurface(padding: 8)
    }

    private func phaseSection(
        _ group: PlanPhases.Group, plan: PlanDoc, numbers: [Int: Int], isCurrentGroup: Bool
    ) -> some View {
        let currentTaskIndex = group.tasks.firstIndex { $0.steps.contains { !$0.checked } }
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if let line = group.tasks.first?.phaseLine ?? group.tasks.first?.line {
                    onOpenDocAtLine(plan.fileURL, line)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(group.phase ?? "Steps")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if isCurrentGroup { currentTag() }
                    Spacer(minLength: 0)
                    Text("\(group.checkedSteps)/\(group.totalSteps)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Course correct…") {
                    correcting = CorrectionTarget(
                        plan: plan,
                        anchor: .phase(name: group.phase ?? ""),
                        description: group.phase ?? "Steps")
                }
            }
            ForEach(Array(group.tasks.enumerated()), id: \.offset) { index, task in
                taskRow(task, number: numbers[task.line] ?? (index + 1),
                        plan: plan, isCurrent: index == currentTaskIndex)
            }
        }
    }

    private func taskRow(_ task: PlanTask, number: Int, plan: PlanDoc, isCurrent: Bool) -> some View {
        let checked = task.steps.filter(\.checked).count
        let total = task.steps.count
        let allChecked = checked == total
        return Button {
            onOpenDocAtLine(plan.fileURL, task.line)
        } label: {
            HStack(spacing: 11) {
                Text("\(number)")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, alignment: .trailing)
                checkGlyph(allChecked: allChecked, isCurrent: isCurrent)
                Text(cleanTitle(task.title))
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                if isCurrent { currentTag() }
                Spacer(minLength: 0)
                if checked > 0 {
                    let show = hoveredTaskLine == task.line
                    Button {
                        onViewTaskChanges(plan, task)
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View this task's changes")
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                }
                Text("\(checked)/\(total)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent
                      ? Color.accentColor.opacity(0.08)
                      : (hoveredTaskLine == task.line ? Color.primary.opacity(0.04) : Color.clear))
        }
        .contextMenu {
            Button("View changes") { onViewTaskChanges(plan, task) }
            Button("Course correct…") {
                correcting = CorrectionTarget(
                    plan: plan,
                    anchor: .task(line: task.line),
                    description: task.title.isEmpty ? "this task" : task.title)
            }
        }
        .onHover { inside in
            if inside { hoveredTaskLine = task.line }
            else if hoveredTaskLine == task.line { hoveredTaskLine = nil }
        }
    }

    /// A leading "Task 12:" is redundant once a number badge carries the
    /// index — strip it; keep any other title verbatim.
    private func cleanTitle(_ title: String) -> String {
        if let range = title.range(of: #"^Task\s+\d+:\s*"#, options: .regularExpression) {
            let rest = String(title[range.upperBound...])
            return rest.isEmpty ? "Steps" : rest
        }
        return title.isEmpty ? "Steps" : title
    }

    @ViewBuilder
    private func checkGlyph(allChecked: Bool, isCurrent: Bool) -> some View {
        if allChecked {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.green)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.green.opacity(0.16)))
        } else if isCurrent {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 19, height: 19)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 19, height: 19)
        }
    }

    private func currentTag() -> some View {
        Text("current")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -6`
Expected: "Build complete!"

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceOverviewView.swift
git commit -m "Overview: Mode A checklist restyle — number badge, check states, count chip, phases"
```

---

### Task 6: Mode B redesign (main / scratch)

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceOverviewView.swift` — replace `modeB()`, `headerB()`, `actionsRowB()`, `projectRunsSection()`, `projectRunRow(_:)`.

**Interfaces:**
- Consumes: `OverviewModeBStatus.pill(insertions:deletions:)` (Task 2); `OverviewStatusPill`, `OverviewProgressBar`, `OverviewSectionLabel`, `overviewSurface` (Task 3); existing `headStatus`, `resolveWorktreeGitStatus`, `session`, `makeRunControls`, `onNewPlan`, `gateActions`, `flowStatus(for:)`, `ProjectRunsSummary.runs(...)`, `ProjectRun` (`title`, `status`, `checked`, `total`), `FlowStatusGlyph`, `openRun(_:)`, `BranchChangesButton`.
- Produces: nothing.

- [ ] **Step 1: Replace the Mode B functions**

Replace `modeB()`, `headerB()`, `actionsRowB()`, `projectRunsSection()`, `projectRunRow(_:)` with:

```swift
    // MARK: - Mode B (plain workspace: no plan behind it)

    private func modeB() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerB()
                if session.workspace.isMain {
                    OverviewSectionLabel(title: "Project Runs")
                    projectRunsSection()
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.workspace.id) {
            headStatus = await resolveWorktreeGitStatus(for: session.workspace)
        }
    }

    private func headerB() -> some View {
        let pill = OverviewModeBStatus.pill(
            insertions: headStatus?.insertions, deletions: headStatus?.deletions)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let pill {
                    OverviewStatusPill(text: pill.text, flow: pill.flow)
                }
                Spacer(minLength: 0)
                makeRunControls(session.workspace)
            }
            Text(session.workspace.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.top, 13)
            HStack(spacing: 9) {
                if let headStatus {
                    Text(headStatus.shortSHA)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if headStatus.insertions > 0 || headStatus.deletions > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("+\(headStatus.insertions)").foregroundStyle(.green)
                        Text("−\(headStatus.deletions)").foregroundStyle(.red)
                    }
                }
                if !session.workspace.linkedRepoIDs.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 9)
            actionsRowB()
                .padding(.top, 16)
        }
        .overviewSurface(padding: 20)
    }

    private func actionsRowB() -> some View {
        HStack(spacing: 10) {
            Button(action: onNewPlan) {
                Label("Plan something here", systemImage: "sparkles")
            }
            .buttonStyle(.soft)
            Button(action: session.createTab) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.soft)
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    // MARK: - Main's mini-dashboard (project runs)

    @ViewBuilder
    private func projectRunsSection() -> some View {
        let runs = ProjectRunsSummary.runs(
            plans: docStore.plans,
            status: { docStore.status(for: $0, featureExists: featureExists) },
            featureName: featureName,
            relativePath: { docStore.relativePath(of: $0) })
        if runs.isEmpty {
            Text("No active runs. Kick one off from a plan in the sidebar.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .overviewSurface(padding: 16)
        } else {
            VStack(spacing: 4) {
                ForEach(runs) { run in
                    projectRunRow(run)
                }
            }
            .overviewSurface(padding: 8)
        }
    }

    private func projectRunRow(_ run: ProjectRun) -> some View {
        let flow = flowStatus(for: run.status)
        let complete = run.total > 0 && run.checked == run.total
        return Button { openRun(run) } label: {
            HStack(spacing: 12) {
                Image(systemName: FlowStatusGlyph.symbol(flow))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowStatusGlyph.color(flow))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(run.status.label)
                        if run.total > 0 {
                            Text("·").foregroundStyle(.tertiary)
                            Text("\(run.checked)/\(run.total)")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    if run.total > 0 {
                        OverviewProgressBar(
                            fraction: Double(run.checked) / Double(max(1, run.total)),
                            complete: complete)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03)))
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -6`
Expected: "Build complete!"

- [ ] **Step 3: Run the full test suite (no regressions)**

Run: `swift test 2>&1 | tail -6`
Expected: "Executed 779 tests, with 1 test skipped and 0 failures" (767 prior + 12 new: 8 `RunHeroStateTests` + 4 `OverviewModeBStatusTests`).

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceOverviewView.swift
git commit -m "Overview: Mode B redesign — working-tree hero + restyled Project Runs"
```

---

## Self-Review

**Spec coverage:**
- Shared language (surfaces/type/hero) → Tasks 3, 4, 6. ✓
- Mode A state model (`RunHeroState`) → Task 1 + wired in Task 4. ✓
- "Merge & continue vs Review & merge" label → Task 4 `mergePrimaryLabel`. ✓
- Merged celebratory note → Task 4 `mergedNote`. ✓
- Checklist flat + phase-grouped, number badge, check states, count chip, current highlight, hover "View changes" + context menu → Task 5. ✓
- Mode B working-tree hero (`OverviewModeBStatus`) + action row + Project Runs board → Tasks 2, 6. ✓
- Removed: `Divider()`s, standalone gate card, bottom actions row → Task 4 (Mode A), Task 6 (Mode B). ✓
- Colored Capsule progress (green complete / accent incomplete), no system `ProgressView` → Task 3 `OverviewProgressBar`, used in Tasks 4/6. ✓
- Status color on `FlowStatusGlyph` vocabulary → Task 3 pill, Task 6 run rows. ✓
- `WorkspaceOverviewDependencies` frozen → no task touches it. ✓
- Reduce-motion on the pulsing dot → Task 3. ✓

**Type consistency:** `RunHeroState.PrimaryAction` cases (`run/running/reviewAndMerge/noPrimary`) match the switch in Task 4. `OverviewModeBStatus.Pill(text:flow:)` matches Task 2's test and Task 6's use. `OverviewProgressBar(fraction:complete:)`, `OverviewStatusPill(text:flow:pulse:)`, `OverviewSectionLabel(title:trailing:)`, `overviewSurface(padding:radius:)` signatures are identical across Tasks 3/4/5/6. `PlanPhases.Group` fields (`phase`, `tasks`, `checkedSteps`, `totalSteps`) and `PlanTask` fields (`title`, `steps`, `line`, `phaseLine`) match their source. `flowStatus(for:)` is retained (Task 4 note) and reused in Task 6.

**Placeholder scan:** No TBD/TODO; every code step carries full code; every command has an expected result.
