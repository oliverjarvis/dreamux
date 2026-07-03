# Plan Queue + Merge Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An ordered queue of ready plans that executes sequentially through the single-plan machinery, pausing at a user-approved merge gate between plans (with an attention state when a session stalls incomplete).

**Architecture:** A `PlanQueueController` (`@MainActor @Observable`, persisted to `.dreamux/plan-queue.json`) owns the queue order and a four-state machine (`idle / running / atGate / attention`). All external effects are injected closures (`statusForPlan`, `runPlan`, `isFeatureQuiescent`, `requestMerge`), so transitions are unit-testable with fakes; the real wiring composes `DocStore`, `PlanRunCoordinator`, `WorkspaceStore`, and the existing `MergeFeatureSheet` (via the sidebar's `pendingMerge` presentation, reached through a new pending-request channel). A polling tick derives transitions from the same derived plan statuses the sidebar shows.

**Tech Stack:** Swift 6 / SwiftUI, XCTest with injected clocks/fakes.

**Spec:** `docs/superpowers/specs/2026-07-02-plans-specs-orchestration-design.md` (§6 Queue) — read it before starting.

**Prerequisite:** `2026-07-02-plans-specs-sidebar-execution.md` fully implemented (DocStore, PlanRunCoordinator, PlansSpecsSection, e2e docs commands all exist).

## Global Constraints

- macOS 14 floor, Swift 6 strict concurrency; no new dependencies.
- Sequential execution only; no auto-merge — the gate always waits for the user.
- Queue state lives in `.dreamux/plan-queue.json`; nothing is written into docs.
- Manual single-plan runs stay available while the queue is idle (the UI disables queue Start only, never the per-row Run).
- `swift build` and `swift test` green per task; commit per task, staging only named files.

---

### Task 1: `PlanQueueController` — state machine + persistence

**Files:**
- Create: `Sources/Dreamux/Models/PlanQueueController.swift`
- Test: `Tests/DreamuxTests/PlanQueueControllerTests.swift`

**Interfaces:**
- Consumes: `PlanStatus` (from the B1 plan), `Project.rootPath`.
- Produces:
  - `enum PlanQueueState: String, Codable, Sendable { case idle, running, atGate, attention }`
  - `@MainActor @Observable final class PlanQueueController`:
    - `init(project: Project)` — loads `.dreamux/plan-queue.json`.
    - Injected effects (set after init): `var statusForPlan: (String) -> PlanStatus?`, `var runPlan: (String) async throws -> Void`, `var isFeatureQuiescent: (String) -> Bool`, `var featureNameForPlan: (String) -> String?`, `var requestMerge: (String) -> Void`, `var now: () -> Date` (defaults `Date.init`).
    - `private(set) var entries: [String]` (plan paths, project-relative), `private(set) var state: PlanQueueState`, `private(set) var currentPlanPath: String?`, `private(set) var lastError: String?`.
    - Mutations: `func enqueue(_ path: String)`, `func remove(_ path: String)`, `func move(fromOffsets: IndexSet, toOffset: Int)`, `func start()`, `func stopQueue()`, `func mergeAndContinue()`, `func skipCurrent()`, `func resumeCurrent()`.
    - `func tick()` — derive transitions; `func startPolling()` / `func stopPolling()`.
  - Stall rule: while `running`, if the current plan's status is `.running`, its feature's shell has been quiescent on every tick for ≥ 120 s (tracked via `quiescentSince`), and boxes are unchecked since the last change, the queue flips to `.attention`.

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/PlanQueueControllerTests.swift`:

```swift
import XCTest
@testable import Dreamux

@MainActor
final class PlanQueueControllerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var controller: PlanQueueController!
    private var ran: [String] = []
    private var mergeRequests: [String] = []
    private var statuses: [String: PlanStatus] = [:]
    private var quiescent = false
    private var fakeNow = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "demo")
        controller = PlanQueueController(project: project)
        controller.statusForPlan = { [weak self] in self?.statuses[$0] }
        controller.runPlan = { [weak self] path in self?.ran.append(path) }
        controller.isFeatureQuiescent = { [weak self] _ in self?.quiescent ?? false }
        controller.featureNameForPlan = { path in (path as NSString).lastPathComponent }
        controller.requestMerge = { [weak self] in self?.mergeRequests.append($0) }
        controller.now = { [weak self] in self?.fakeNow ?? Date() }
    }
    override func tearDown() { sandbox?.destroy(); sandbox = nil }

    func testEnqueuePersistsAndDedupes() {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        XCTAssertEqual(controller.entries, ["docs/plans/a.md", "docs/plans/b.md"])
        let reloaded = PlanQueueController(project: project)
        XCTAssertEqual(reloaded.entries, ["docs/plans/a.md", "docs/plans/b.md"])
    }

    func testStartRunsFirstEntry() {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/a.md")
        XCTAssertEqual(ran, ["docs/plans/a.md"])
    }

    func testTickMovesToGateWhenAwaitingReview() {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        statuses["docs/plans/a.md"] = .awaitingReview
        controller.tick()
        XCTAssertEqual(controller.state, .atGate)
    }

    func testMergedAtGateAdvancesToNextPlan() {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        statuses["docs/plans/a.md"] = .awaitingReview
        controller.tick()
        controller.mergeAndContinue()
        XCTAssertEqual(mergeRequests, ["a.md"], "merge requested for the plan's feature")
        statuses["docs/plans/a.md"] = .merged
        controller.tick()
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/b.md")
        XCTAssertEqual(ran, ["docs/plans/a.md", "docs/plans/b.md"])
    }

    func testQueueGoesIdleAfterLastPlan() {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        statuses["docs/plans/a.md"] = .merged
        controller.tick()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentPlanPath)
        XCTAssertTrue(controller.entries.isEmpty, "finished entries leave the queue")
    }

    func testStalledQuiescentSessionFlipsToAttention() {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        statuses["docs/plans/a.md"] = .running
        quiescent = true
        controller.tick()                       // arms quiescentSince
        XCTAssertEqual(controller.state, .running)
        fakeNow = fakeNow.addingTimeInterval(121)
        controller.tick()
        XCTAssertEqual(controller.state, .attention)
    }

    func testActivityResetsStallTimer() {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        statuses["docs/plans/a.md"] = .running
        quiescent = true
        controller.tick()
        fakeNow = fakeNow.addingTimeInterval(60)
        quiescent = false                       // output arrived
        controller.tick()
        fakeNow = fakeNow.addingTimeInterval(61)
        quiescent = true
        controller.tick()                       // re-arms, only 0s quiescent
        XCTAssertEqual(controller.state, .running)
    }

    func testSkipAndStopAndResume() {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        statuses["docs/plans/a.md"] = .running
        quiescent = true
        controller.tick()
        fakeNow = fakeNow.addingTimeInterval(121)
        controller.tick()
        XCTAssertEqual(controller.state, .attention)

        controller.resumeCurrent()
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(ran, ["docs/plans/a.md", "docs/plans/a.md"], "resume re-runs current")

        fakeNow = fakeNow.addingTimeInterval(200)
        controller.tick()                       // stalls again
        controller.skipCurrent()
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/b.md")

        controller.stopQueue()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentPlanPath)
        XCTAssertEqual(controller.entries.first, "docs/plans/b.md",
                       "stop keeps remaining entries for a later start")
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlanQueueControllerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'PlanQueueController' in scope`.

- [x] **Step 3: Implement**

Create `Sources/Dreamux/Models/PlanQueueController.swift`:

```swift
import Foundation
import Observation

enum PlanQueueState: String, Codable, Sendable {
    case idle, running, atGate, attention
}

/// Sequential plan-queue orchestration. Owns the ordered entries and a
/// small state machine; every external effect is an injected closure so
/// transitions are unit-testable. Persisted to
/// `<project>/.dreamux/plan-queue.json` so a relaunch resumes where it
/// left off (in `atGate`/`attention` the user decides; a `running`
/// state reloads as `running` and the next tick re-derives reality).
@MainActor
@Observable
final class PlanQueueController {
    // MARK: - Injected effects (wired in ContentView; fakes in tests)

    @ObservationIgnored var statusForPlan: (String) -> PlanStatus? = { _ in nil }
    @ObservationIgnored var runPlan: (String) async throws -> Void = { _ in }
    @ObservationIgnored var isFeatureQuiescent: (String) -> Bool = { _ in false }
    @ObservationIgnored var featureNameForPlan: (String) -> String? = { _ in nil }
    @ObservationIgnored var requestMerge: (String) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = Date.init

    // MARK: - State

    private(set) var entries: [String]
    private(set) var state: PlanQueueState
    private(set) var currentPlanPath: String?
    private(set) var lastError: String?

    /// How long an unchanged, quiescent session may sit before the
    /// queue asks for attention.
    static let stallThreshold: TimeInterval = 120

    @ObservationIgnored private var quiescentSince: Date?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init(project: Project) {
        fileURL = project.rootPath
            .appendingPathComponent(".dreamux", isDirectory: true)
            .appendingPathComponent("plan-queue.json")
        let loaded = Self.load(from: fileURL)
        entries = loaded?.entries ?? []
        state = loaded?.state ?? .idle
        currentPlanPath = loaded?.currentPlanPath
    }

    // MARK: - Mutations

    func enqueue(_ path: String) {
        guard !entries.contains(path) else { return }
        entries.append(path)
        save()
    }

    func remove(_ path: String) {
        entries.removeAll { $0 == path }
        if currentPlanPath == path { currentPlanPath = nil }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func start() {
        guard state == .idle, let first = entries.first else { return }
        state = .running
        launch(first)
    }

    func stopQueue() {
        state = .idle
        currentPlanPath = nil
        quiescentSince = nil
        stopPolling()
        save()
    }

    /// Gate action: hand the current plan's feature to the merge flow.
    /// Advancing happens on a later tick, when the plan reads `merged`.
    func mergeAndContinue() {
        guard state == .atGate, let path = currentPlanPath,
              let feature = featureNameForPlan(path) else { return }
        requestMerge(feature)
    }

    func skipCurrent() {
        guard let path = currentPlanPath else { return }
        entries.removeAll { $0 == path }
        advance(after: path)
    }

    func resumeCurrent() {
        guard state == .attention, let path = currentPlanPath else { return }
        state = .running
        quiescentSince = nil
        launch(path)
    }

    // MARK: - Ticking

    func startPolling() {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                if self.state != .idle { self.tick() }
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    /// Derive transitions from the same derived statuses the sidebar
    /// shows. Pure function of injected probes — the tests drive this
    /// directly with fakes.
    func tick() {
        guard let path = currentPlanPath else { return }
        guard let status = statusForPlan(path) else {
            // Plan file vanished mid-queue: skip it.
            lastError = "Plan disappeared: \(path)"
            entries.removeAll { $0 == path }
            advance(after: path)
            return
        }

        switch (state, status) {
        case (.running, .awaitingReview):
            state = .atGate
            quiescentSince = nil
            save()
        case (.running, .merged), (.atGate, .merged):
            entries.removeAll { $0 == path }
            advance(after: path)
        case (.running, .running):
            trackStall(for: path)
        case (.running, _), (.atGate, _), (.attention, _), (.idle, _):
            break
        }
    }

    private func trackStall(for path: String) {
        guard let feature = featureNameForPlan(path),
              isFeatureQuiescent(feature) else {
            quiescentSince = nil
            return
        }
        let since = quiescentSince ?? now()
        quiescentSince = since
        if now().timeIntervalSince(since) >= Self.stallThreshold {
            state = .attention
            save()
        }
    }

    private func advance(after path: String) {
        quiescentSince = nil
        if let next = entries.first {
            state = .running
            launch(next)
        } else {
            state = .idle
            currentPlanPath = nil
            save()
        }
    }

    private func launch(_ path: String) {
        currentPlanPath = path
        save()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runPlan(path)
                self.startPolling()
            } catch {
                self.lastError = error.localizedDescription
                self.state = .attention
                self.save()
            }
        }
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var entries: [String]
        var state: PlanQueueState
        var currentPlanPath: String?
    }

    private static func load(from url: URL) -> Payload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func save() {
        let payload = Payload(entries: entries, state: state, currentPlanPath: currentPlanPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

Note for the test on `start()`/`launch`: `runPlan` fires inside a `Task`, so tests that assert `ran` immediately after `start()` need a spin of the main queue. If the assertions in Step 1 flake, make the test methods `async` and insert `await Task.yield()` after `start()`/`resumeCurrent()`/the advancing `tick()` calls — that is the intended fix, not changing `launch` to be synchronous.

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlanQueueControllerTests 2>&1 | tail -5`
Expected: PASS (8 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/PlanQueueController.swift Tests/DreamuxTests/PlanQueueControllerTests.swift
git commit -m "Add PlanQueueController state machine with persistence"
```

---

### Task 2: Wire the controller into the window

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift`
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift`

**Interfaces:**
- Consumes: Task 1; B1's `DocStore`/`PlanRunCoordinator`; `E2EBridge`.
- Produces: a fully wired `PlanQueueController` owned by ContentView; `E2EBridge.pendingMergeWorkspaceID` reused as the gate's merge channel; `E2EProjectHandles.planQueue`.

- [x] **Step 1: Wire in ContentView**

In `Sources/Dreamux/Views/ContentView.swift`:

- Add `@State private var planQueue: PlanQueueController`.
- In `init`, after the `planRunner` setup:

```swift
        let planQueue = PlanQueueController(project: repoStore.project)
        planQueue.statusForPlan = { [weak docStore, weak store] path in
            guard let docStore, let store else { return nil }
            docStore.refresh()
            guard let doc = docStore.docs.first(where: { docStore.relativePath(of: $0) == path })
            else { return nil }
            return docStore.status(for: doc) { name in
                store.workspaces.contains { $0.name == name }
            }
        }
        planQueue.featureNameForPlan = { [weak docStore] path in
            docStore?.ledger.recordForPlan(path)?.featureName
        }
        planQueue.isFeatureQuiescent = { [weak store] feature in
            guard let store,
                  let workspace = store.workspaces.first(where: { $0.name == feature })
            else { return true }
            // Quiescent = no tab in the feature's session produced output
            // in the last 5 s. (Session-level helper added below.)
            return store.session(for: workspace).allShellsQuiescent(for: 5)
        }
        _planQueue = State(initialValue: planQueue)
```

- `runPlan` and `requestMerge` need `docStore`/`planRunner`/the bridge; close the loop in `.onAppear` (weak-capturing the @State stores is awkward in init because `self` isn't available — `.onAppear` runs once per window and can capture directly):

```swift
            planQueue.runPlan = { [docStore, planRunner, repoStore] path in
                docStore.refresh()
                guard let doc = docStore.docs.first(
                    where: { docStore.relativePath(of: $0) == path }) else {
                    throw PlanRunError.notAPlan
                }
                try await planRunner.runPlan(
                    doc,
                    branchName: PlanDoc.branchName(forFileName: doc.fileURL.lastPathComponent),
                    repoNames: repoStore.repositories.map(\.name))
            }
            planQueue.requestMerge = { [store, repoStore] featureName in
                guard let workspace = store.workspaces.first(where: { $0.name == featureName })
                else { return }
                // The merge sheet is owned by WorkspaceSidebar; reuse the
                // same pending channel the e2e openMergeSheet command uses.
                E2ERegistry.shared.bridge(forProject: repoStore.project.id)?
                    .pendingMergeWorkspaceID = workspace.id
                // When e2e is inactive the bridge is nil — park on the
                // queue-local channel the sidebar also observes.
                pendingGateMerge.wrappedValue = workspace.id
            }
            planQueue.startPolling()
```

- The non-e2e merge channel: add `@State private var gateMergeWorkspaceID: UUID?` to ContentView, pass `$gateMergeWorkspaceID` into `WorkspaceSidebar` (new `@Binding var gateMergeWorkspaceID: UUID?`), and in the `requestMerge` closure set it via a captured binding (`let pendingGateMerge = $gateMergeWorkspaceID` before the closure). In `WorkspaceSidebar`, consume it exactly like `consumePendingMergeIfAny()`:

```swift
        .onChange(of: gateMergeWorkspaceID) { _, id in
            guard let id, let workspace = store.workspaces.first(where: { $0.id == id })
            else { return }
            gateMergeWorkspaceID = nil
            pendingMerge = workspace
        }
```

- Pass `planQueue` into `WorkspaceSidebar` (new property `let planQueue: PlanQueueController`).

In `Sources/Dreamux/E2E/E2ERegistry.swift`, add `weak var planQueue: PlanQueueController?` to `E2EProjectHandles` and a `planQueue` parameter to `registerDocStores(...)` (update the ContentView call site to pass it).

- [x] **Step 2: Session quiescence helper**

In `Sources/Dreamux/Models/WorkspaceSession.swift`, add near `anyTabHasUnread`:

```swift
    /// True when every terminal tab's shell has been silent for at
    /// least `interval` — the queue's cheap "agent finished or stalled"
    /// probe.
    func allShellsQuiescent(for interval: TimeInterval) -> Bool {
        tabSessions.values.allSatisfy { $0.isShellQuiescent(for: interval) }
    }
```

- [x] **Step 3: Build + suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass (nothing user-visible yet).

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/E2E/E2ERegistry.swift Sources/Dreamux/Models/WorkspaceSession.swift
git commit -m "Wire PlanQueueController into the project window"
```

---

### Task 3: Queue UI — subsection + gate card

**Files:**
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: a Queue subsection at the top of Plans & Specs (ordered entries, reorder via `.onMove`-style drag using the existing `ReorderDropDelegate` pattern or Move Up/Down context actions — pick the drag pattern used by feature rows), Start/Stop button, gate card (`atGate`) with Open Feature / Merge & Continue / Stop, attention card with Resume / Skip / Stop, and an "Add to Queue" context action on ready plan rows.

- [x] **Step 1: Queue subsection**

In `Sources/Dreamux/Views/PlansSpecsSection.swift`, add properties to `PlansSpecsSection`:

```swift
    @Bindable var queue: PlanQueueController
    let onOpenFeature: (String) -> Void   // feature name → activate workspace
```

Insert `queueSection` at the top of `rows` (before the `ForEach(active)`), and implement:

```swift
    @ViewBuilder
    private var queueSection: some View {
        if !queue.entries.isEmpty || queue.state != .idle {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Queue")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if queue.state == .idle {
                        Button("Start") { queue.start() }
                            .controlSize(.mini).buttonStyle(.bordered)
                            .disabled(queue.entries.isEmpty)
                    } else {
                        Button("Stop") { queue.stopQueue() }
                            .controlSize(.mini).buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)

                ForEach(queue.entries, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: path == queue.currentPlanPath
                              ? "arrowtriangle.right.fill" : "line.3.horizontal")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text((path as NSString).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            queue.remove(path)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(path == queue.currentPlanPath && queue.state != .idle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                .onMove { from, to in queue.move(fromOffsets: from, toOffset: to) }

                gateCardIfAny
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
        }
    }

    @ViewBuilder
    private var gateCardIfAny: some View {
        if let path = queue.currentPlanPath,
           queue.state == .atGate || queue.state == .attention {
            let feature = queue.featureNameForPlan(path)
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    queue.state == .atGate
                        ? "Plan complete — review before merging"
                        : (queue.lastError ?? "Session stalled with steps unchecked"),
                    systemImage: queue.state == .atGate
                        ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(queue.state == .atGate ? Color.green : .orange)
                HStack(spacing: 6) {
                    if let feature {
                        Button("Open feature") { onOpenFeature(feature) }
                    }
                    if queue.state == .atGate {
                        Button("Merge & Continue") { queue.mergeAndContinue() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Resume") { queue.resumeCurrent() }
                            .buttonStyle(.borderedProminent)
                        Button("Skip") { queue.skipCurrent() }
                    }
                }
                .controlSize(.mini)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
```

Note: `ForEach.onMove` inside a plain `VStack` needs `List` semantics on macOS; if drag-reorder doesn't engage, reuse the `ReorderDropDelegate` pattern from the feature rows (`WorkspaceSidebar.swift:140-149`) with `queue.entries` — the delegate is generic over identifiable items (wrap paths: `struct QueueItem: Identifiable { let path: String; var id: String { path } }`). Either mechanism satisfies the spec; prefer whichever compiles without a `List`.

Also add to the runnable plans' context menu in `docRow` (only when `canRun`):

```swift
                if canRun {
                    Button("Add to Queue") { onEnqueue(doc) }
                }
```

with a new `let onEnqueue: (PlanDoc) -> Void` property.

- [x] **Step 2: Sidebar + ContentView plumbing**

In `Sources/Dreamux/Views/WorkspaceSidebar.swift`, pass through to `PlansSpecsSection`:

```swift
                queue: planQueue,
                onOpenFeature: { name in
                    guard let workspace = store.workspaces.first(where: { $0.name == name })
                    else { return }
                    sidebarMode = .workspace
                    store.activate(workspace.id)
                },
                onEnqueue: { doc in planQueue.enqueue(docStore.relativePath(of: doc)) },
```

(Also add the new `@Binding var gateMergeWorkspaceID: UUID?` + `.onChange` consumption from Task 2 if not already landed there.)

Update the `WorkspaceSidebar(...)` call in `ContentView.swift` with the new arguments.

- [x] **Step 3: Build, test, and walk the queue**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

Manual walk (scratch project, `DREAMUX_CLAUDE_BIN` fake): enqueue two toy plans → Start → first provisions and runs; tick all its boxes on disk → gate card appears → Merge & Continue opens the merge sheet; completing the merge (fake-friendly: merge + cleanup) flips the plan to merged and the queue auto-starts the second plan; Stop works at any point; a stalled session (fake claude exits without ticking) shows the attention card with Resume/Skip.

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Add queue subsection with merge-gate and attention cards"
```

---

### Task 4: E2E — queue commands

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`
- Modify: `scripts/e2e/PROTOCOL.md`

**Interfaces:**
- Consumes: `E2EProjectHandles.planQueue` (Task 2).
- Produces: commands `enqueuePlan {path}`, `startQueue`, `stopQueue`, `queueState`; the `state` dump gains `"queue"`.

- [x] **Step 1: Implement the commands**

In `Sources/Dreamux/E2E/E2ECommands.swift`, add cases beside `runPlan`:

```swift
        case "enqueuePlan":
            return handleQueueMutation(request) { $0.enqueue($1) }
        case "startQueue":
            return handleQueueMutation(request) { queue, _ in queue.start() }
        case "stopQueue":
            return handleQueueMutation(request) { queue, _ in queue.stopQueue() }
        case "queueState":
            return handleQueueState()
```

And the handlers:

```swift
    private func handleQueueMutation(
        _ request: [String: Any],
        _ mutate: (PlanQueueController, String) -> Void
    ) -> [String: Any] {
        guard let queue = activeHandles()?.planQueue else {
            return ["ok": false, "error": "no plan queue registered"]
        }
        mutate(queue, (request["path"] as? String) ?? "")
        return ["ok": true]
    }

    private func handleQueueState() -> [String: Any] {
        guard let queue = activeHandles()?.planQueue else {
            return ["ok": false, "error": "no plan queue registered"]
        }
        queue.tick()   // deterministic: scenarios don't wait for the poller
        var payload: [String: Any] = [
            "ok": true,
            "state": queue.state.rawValue,
            "entries": queue.entries,
        ]
        if let current = queue.currentPlanPath { payload["current"] = current }
        if let error = queue.lastError { payload["lastError"] = error }
        return payload
    }
```

Add `"queue": ["state": …, "entries": …, "current": …]` to the main `state` dump with the same fields (nil-safe, mirroring the handler above).

- [x] **Step 2: PROTOCOL.md**

Document the four commands and the `state.queue` field, in the file's per-command format, including the note that `queueState` runs a synchronous `tick()` so scenarios can drive transitions deterministically (write plan checkboxes → `queueState` → assert `atGate`).

- [x] **Step 3: Build + suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/E2E/E2ECommands.swift scripts/e2e/PROTOCOL.md
git commit -m "Expose plan queue to the e2e automation server"
```

---

## Final verification

- `swift build && swift test` — clean.
- Manual queue walk from Task 3 Step 3.
- `git log --oneline` — one commit per task.
