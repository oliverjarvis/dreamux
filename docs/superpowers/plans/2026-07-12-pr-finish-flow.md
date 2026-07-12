# PR Finish Flow Implementation Plan

**Goal:** Surface the existing publish/PR action at a run's gate, then lift
PR status into a persistent, reactive axis rendered across the app.

**Architecture:** The push/PR engine (`GhOperations`, `MergeFlow.publish`,
`MergeFeatureSheet`) already ships — this plan reuses it, never reimplements
it. Increment A adds a "Create PR" primary action to `GateActionCard` that
opens the existing merge sheet with publish emphasized. Increment B adds a
`PRLifecycle` sibling to `FlowStatus`, a `@MainActor @Observable`
`PRStatusStore` fed by a `ClaudeRegistryPoller`-shaped `PRStatusPoller`, a
`FlowsBoard.Lane.prState` seam, and a `PRStatusGlyph` badge rendered at five
sites.

**Tech Stack:** Swift / SwiftPM, SwiftUI, XCTest. `gh` via the existing
`runGh` plumbing (`DREAMUX_GH_BIN` override for tests). No new
dependencies.

## Global Constraints

- Swift/SwiftPM. Tests are XCTest under `Tests/DreamuxTests/`. Build:
  `swift build`. Test: `swift test --filter <Name>`.
- `FlowStatus` MUST stay CLI-agnostic — `PRLifecycle` is a separate enum;
  never add GitHub cases to `FlowStatus`/`PlanStatus`.
- Reuse the existing engine — do NOT reimplement push/PR/gh logic.
  `MergeFlow.publish` and `GhOperations` are the source of truth.
- `publish` must NOT touch shared local `main` (integration is remote-only;
  local main only ff-fetches at cleanup). Preserve this.
- No new third-party dependencies. `gh` is invoked via the existing `runGh`
  plumbing only.
- Keep it non-spammy: the PR poller must not call `gh` for plans without a
  pushed branch.

---

### Task 1: `PublishAvailability.decide` pure verdict, reused by MergeFlow
**Files:** Modify `Sources/Dreamux/Models/MergeFlow.swift`. Test
`Tests/DreamuxTests/PublishFlowTests.swift`.
**Interfaces:** Produces `PublishAvailability.decide(anyRemote: Bool,
ghAvailable: Bool) -> PublishAvailability` (consumed by Task 2's
`fetchPublishAvailability`).

- [ ] Step: Write the failing test — append to `PublishFlowTests`:
```swift
func testDecideNoRemoteIsNoRemote() {
    XCTAssertEqual(PublishAvailability.decide(anyRemote: false, ghAvailable: true), .noRemote)
    XCTAssertEqual(PublishAvailability.decide(anyRemote: false, ghAvailable: false), .noRemote)
}
func testDecideRemoteButNoGhIsGhMissing() {
    XCTAssertEqual(PublishAvailability.decide(anyRemote: true, ghAvailable: false), .ghMissing)
}
func testDecideRemoteAndGhIsAvailable() {
    XCTAssertEqual(PublishAvailability.decide(anyRemote: true, ghAvailable: true), .available)
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter PublishFlowTests`
  → "type 'PublishAvailability' has no member 'decide'".
- [ ] Step: Implement — add to `MergeFlow.swift` after the
  `PublishAvailability` enum:
```swift
extension PublishAvailability {
    /// Pure verdict from the two probes the pre-check gathers: no remote
    /// ⇒ the option can never apply (hidden); a remote but no gh ⇒
    /// fixable, shown disabled; both present ⇒ available.
    static func decide(anyRemote: Bool, ghAvailable: Bool) -> PublishAvailability {
        guard anyRemote else { return .noRemote }
        return ghAvailable ? .available : .ghMissing
    }
}
```
  Then refactor `initializeStates`' availability block to reuse it (keeps
  behaviour identical — noRemote repos stay noRemote, available flips to
  ghMissing when gh is absent):
```swift
var availability: [String: PublishAvailability] = [:]
var hasRemote: [String: Bool] = [:]
var anyRemote = false
for repo in repos {
    let remote = await GitOperations.remoteURL(in: repo.rootURL) != nil
    hasRemote[repo.name] = remote
    if remote { anyRemote = true }
}
let ghAvailable = anyRemote ? await GhOperations.isAvailable() : false
for repo in repos {
    availability[repo.name] = PublishAvailability.decide(
        anyRemote: hasRemote[repo.name] ?? false, ghAvailable: ghAvailable)
}
publishAvailability = availability
```
- [ ] Step: Run — expect PASS. `swift test --filter PublishFlowTests`
  (new cases pass AND the existing availability tests stay green).
- [ ] Step: Commit — `git add Sources/Dreamux/Models/MergeFlow.swift
  Tests/DreamuxTests/PublishFlowTests.swift && git commit -m "MergeFlow:
  extract PublishAvailability.decide"`.

---

### Task 2: Gate card offers "Create PR" (primary) / "Merge locally" (secondary)
**Files:** Modify `Sources/Dreamux/Views/GateActionCard.swift`,
`Sources/Dreamux/Views/ContentView.swift`,
`Sources/Dreamux/Views/MergeFeatureSheet.swift`,
`Sources/Dreamux/Views/WorkspaceSidebar.swift`,
`Sources/Dreamux/Models/ProjectSession.swift`.
**Interfaces:** Consumes `PublishAvailability.decide` (Task 1). Produces
`FlowGateActions.requestPublish: (UUID) -> Void` and
`FlowGateActions.fetchPublishAvailability: (UUID) async ->
PublishAvailability`; `MergeFeatureSheet(emphasizePublish: Bool = false)`;
`ProjectSession.emphasizePublishWorkspaceID: UUID?`.

- [ ] Step: (View wiring — verified by `swift build` + visual check, no
  unit test: this is button placement + closure plumbing.) Extend
  `FlowGateActions`:
```swift
struct FlowGateActions {
    let openDiff: (UUID) -> Void
    let requestMerge: (UUID) -> Void
    let fetchDiffStat: (UUID) async -> GitBranchDiffStat?
    /// Present the merge sheet with publish emphasized (reuses the
    /// existing pendingGateMergeWorkspaceID channel + MergeFlow.publish).
    let requestPublish: (UUID) -> Void
    /// Async, appearance-time — mirrors fetchDiffStat. Decides whether
    /// "Create PR" is offered for this workspace.
    let fetchPublishAvailability: (UUID) async -> PublishAvailability
}
```
  In `GateActionCard`, add `@State private var publish: PublishAvailability
  = .noRemote`, fetch it in the existing `.task`, and rewrite the button
  row so that when `mergeActionable`:
```swift
if publish == .available {
    Button("Merge locally") { actions.requestMerge(workspaceID) }
    Button("Create PR") { actions.requestPublish(workspaceID) }
        .buttonStyle(.borderedProminent)
} else {
    Button("Merge & continue") { actions.requestMerge(workspaceID) }
        .buttonStyle(.borderedProminent)
}
```
  `.task { stat = await actions.fetchDiffStat(workspaceID);
  publish = await actions.fetchPublishAvailability(workspaceID) }`.
- [ ] Step: Wire in `ContentView.flowGateActions` (~line 943):
```swift
requestPublish: { workspaceID in requestGatePublish(workspaceID: workspaceID) },
fetchPublishAvailability: { workspaceID in await gatePublishAvailability(workspaceID: workspaceID) }
```
  Add near `requestGateMerge` (~1120):
```swift
private func requestGatePublish(workspaceID: UUID) {
    session.emphasizePublishWorkspaceID = workspaceID
    session.pendingGateMergeWorkspaceID = workspaceID
}
private func gatePublishAvailability(workspaceID: UUID) async -> PublishAvailability {
    guard let ws = store.workspaces.first(where: { $0.id == workspaceID }) else { return .noRemote }
    let repos = repoStore.repositories.filter { ws.linkedRepoIDs.contains($0.name) }
    var anyRemote = false
    for repo in repos where await GitOperations.remoteURL(in: repo.rootURL) != nil { anyRemote = true }
    let gh = anyRemote ? await GhOperations.isAvailable() : false
    return PublishAvailability.decide(anyRemote: anyRemote, ghAvailable: gh)
}
```
  Add `var emphasizePublishWorkspaceID: UUID?` to `ProjectSession` (beside
  `pendingGateMergeWorkspaceID`). In `MergeFeatureSheet` add
  `emphasizePublish: Bool = false` (stored) and, in `publishButton`, use
  `.borderedProminent` when `emphasizePublish` (and drop `.borderedProminent`
  from the local Merge/Commit&Merge buttons in that case). In
  `WorkspaceSidebar`'s `.onChange(of: gateMergeWorkspaceID)` handler (~215),
  read+clear `emphasizePublishWorkspaceID` and pass `emphasizePublish:` into
  `MergeFeatureSheet` (thread a `@State private var emphasizePublish = false`
  set alongside `pendingMerge`).
- [ ] Step: Run — `swift build` succeeds. Visual check: at a
  merge-actionable gate in a repo **with** a remote + gh, the card shows
  "Merge locally" (secondary) + "Create PR" (prominent); "Create PR" opens
  the merge sheet with the publish button emphasized. In a repo with **no**
  remote, the card shows only "Merge & continue".
- [ ] Step: Commit — `git add` the five files + commit
  `"Gate card: Create PR primary when publish is available"`.

---

### Task 3: `PRLifecycle` + `GhOperations.PRDetailPayload` mapping + `prDetail`
**Files:** Create `Sources/Dreamux/Models/PRLifecycle.swift`. Modify
`Sources/Dreamux/Shell/GhOperations.swift`. Test
`Tests/DreamuxTests/PRLifecycleTests.swift`.
**Interfaces:** Produces `enum PRLifecycle: String, Codable, Hashable,
Sendable, CaseIterable { draft, open, checksRunning, checksFailed,
changesRequested, approved, merged, closed }`; `struct PRLaneState {
lifecycle: PRLifecycle; url: String }`; `GhOperations.PRDetailPayload` (with
`.lifecycle`) and `GhOperations.prDetail(branch:in:) async -> (lifecycle:
PRLifecycle, url: String)?`.

- [ ] Step: Write the failing test — `PRLifecycleTests.swift`:
```swift
import XCTest
@testable import Dreamux

final class PRLifecycleTests: XCTestCase {
    private func lifecycle(_ json: String) throws -> PRLifecycle {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(GhOperations.PRDetailPayload.self, from: data).lifecycle
    }
    private func json(state: String = "OPEN", draft: Bool = false,
                      review: String = "", rollup: String = "[]") -> String {
        #"{"state":"\#(state)","url":"u","isDraft":\#(draft),"reviewDecision":"\#(review)","statusCheckRollup":\#(rollup)}"#
    }
    func testMergedWinsOverEverything() throws {
        XCTAssertEqual(try lifecycle(json(state: "MERGED", review: "CHANGES_REQUESTED")), .merged)
    }
    func testClosed() throws { XCTAssertEqual(try lifecycle(json(state: "CLOSED")), .closed) }
    func testDraftBeatsFailingChecks() throws {
        XCTAssertEqual(try lifecycle(json(draft: true,
            rollup: #"[{"status":"COMPLETED","conclusion":"FAILURE"}]"#)), .draft)
    }
    func testChangesRequestedBeatsChecks() throws {
        XCTAssertEqual(try lifecycle(json(review: "CHANGES_REQUESTED",
            rollup: #"[{"status":"IN_PROGRESS"}]"#)), .changesRequested)
    }
    func testCheckRunFailure() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]"#)), .checksFailed)
    }
    func testCheckRunRunning() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"status":"IN_PROGRESS"}]"#)), .checksRunning)
    }
    func testStatusContextFailure() throws {
        XCTAssertEqual(try lifecycle(json(rollup: #"[{"state":"FAILURE"}]"#)), .checksFailed)
    }
    func testApprovedWhenChecksPass() throws {
        XCTAssertEqual(try lifecycle(json(review: "APPROVED",
            rollup: #"[{"status":"COMPLETED","conclusion":"SUCCESS"}]"#)), .approved)
    }
    func testOpenIsDefault() throws { XCTAssertEqual(try lifecycle(json()), .open) }
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter PRLifecycleTests`
  → "type 'GhOperations' has no member 'PRDetailPayload'".
- [ ] Step: Implement — `PRLifecycle.swift`:
```swift
import Foundation

/// GitHub pull-request lifecycle — a SIBLING to `FlowStatus`, deliberately
/// kept out of it: `FlowStatus` is contractually CLI-agnostic
/// (FlowGraph.swift), so GitHub concepts live here. Ordered draft→terminal
/// for display grouping only; precedence lives in PRDetailPayload.lifecycle.
enum PRLifecycle: String, Codable, Hashable, Sendable, CaseIterable {
    case draft, open, checksRunning, checksFailed, changesRequested, approved, merged, closed
}

/// PR state carried on a `FlowsBoard.Lane` — a sibling axis to
/// `effectiveStatus`, never folded into the CLI-agnostic Flow model.
struct PRLaneState: Equatable, Sendable {
    let lifecycle: PRLifecycle
    let url: String
    init(lifecycle: PRLifecycle, url: String) { self.lifecycle = lifecycle; self.url = url }
}
```
  Extend `GhOperations` (same file, so it can call private `runGh`):
```swift
extension GhOperations {
    /// Decoded `gh pr view <branch> --json
    /// isDraft,reviewDecision,statusCheckRollup,state,url`. Internal so the
    /// mapping to PRLifecycle is unit-testable straight from gh JSON.
    struct PRDetailPayload: Decodable, Equatable {
        let state: String
        let url: String
        let isDraft: Bool
        let reviewDecision: String?        // "", APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
        let statusCheckRollup: [Check]?

        struct Check: Decodable, Equatable {
            var status: String?      // CheckRun: QUEUED/IN_PROGRESS/COMPLETED
            var conclusion: String?  // CheckRun: SUCCESS/FAILURE/...
            var state: String?       // StatusContext: SUCCESS/FAILURE/PENDING/...
        }

        enum ChecksVerdict { case none, running, passing, failing }

        var checksVerdict: ChecksVerdict {
            guard let rollup = statusCheckRollup, !rollup.isEmpty else { return .none }
            var running = false
            for c in rollup {
                if let s = c.state?.uppercased() {           // StatusContext
                    switch s {
                    case "FAILURE", "ERROR": return .failing
                    case "PENDING", "EXPECTED": running = true
                    default: break
                    }
                } else {                                      // CheckRun
                    if (c.status?.uppercased() ?? "") != "COMPLETED" { running = true; continue }
                    switch c.conclusion?.uppercased() {
                    case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED":
                        return .failing
                    default: break                            // SUCCESS/NEUTRAL/SKIPPED
                    }
                }
            }
            return running ? .running : .passing
        }

        /// Precedence, first match wins: merged, closed, draft,
        /// changesRequested, checksFailed, checksRunning, approved, open.
        var lifecycle: PRLifecycle {
            switch state.uppercased() {
            case "MERGED": return .merged
            case "CLOSED": return .closed
            default: break
            }
            if isDraft { return .draft }
            if reviewDecision?.uppercased() == "CHANGES_REQUESTED" { return .changesRequested }
            switch checksVerdict {
            case .failing: return .checksFailed
            case .running: return .checksRunning
            case .none, .passing: break
            }
            if reviewDecision?.uppercased() == "APPROVED" { return .approved }
            return .open
        }
    }

    /// Richer sibling of `prStatus`: the full lifecycle for the poller.
    /// nil when there's no PR / gh unavailable — treated as "nothing to
    /// report", never an error.
    static func prDetail(branch: String, in worktreeURL: URL) async -> (lifecycle: PRLifecycle, url: String)? {
        guard let output = try? await runGh(
            ["pr", "view", branch, "--json", "isDraft,reviewDecision,statusCheckRollup,state,url"],
            in: worktreeURL
        ), let data = output.data(using: .utf8),
           let payload = try? JSONDecoder().decode(PRDetailPayload.self, from: data)
        else { return nil }
        return (payload.lifecycle, payload.url)
    }
}
```
- [ ] Step: Run — expect PASS. `swift test --filter PRLifecycleTests`.
- [ ] Step: Commit — `git add Sources/Dreamux/Models/PRLifecycle.swift
  Sources/Dreamux/Shell/GhOperations.swift
  Tests/DreamuxTests/PRLifecycleTests.swift && git commit -m "GhOperations:
  PRLifecycle mapping from gh pr view JSON"`.

---

### Task 4: `PRStatusStore` — the persistent PR axis
**Files:** Create `Sources/Dreamux/Models/PRStatusStore.swift`. Test
`Tests/DreamuxTests/PRStatusStoreTests.swift`.
**Interfaces:** Consumes `PRLifecycle` (Task 3). Produces `@MainActor
@Observable final class PRStatusStore` with nested `struct Entry {
lifecycle: PRLifecycle; url: String }`, `track(feature:worktreeURL:)`,
`untrack(feature:)`, `state(for:) -> Entry?`, `trackedFeatures: [(feature:
String, worktreeURL: URL)]`, `apply(_ snapshot: [String: Entry])`.

- [ ] Step: Write the failing test — `PRStatusStoreTests.swift`:
```swift
import XCTest
@testable import Dreamux

@MainActor
final class PRStatusStoreTests: XCTestCase {
    func testTrackRegistersFeatureForPolling() {
        let store = PRStatusStore()
        store.track(feature: "feat-a", worktreeURL: URL(fileURLWithPath: "/wt/a"))
        XCTAssertEqual(store.trackedFeatures.map(\.feature), ["feat-a"])
        XCTAssertNil(store.state(for: "feat-a"))   // tracked but not yet polled
    }
    func testApplyPublishesStateKeyedByFeature() {
        let store = PRStatusStore()
        store.apply(["feat-a": .init(lifecycle: .approved, url: "u-a")])
        XCTAssertEqual(store.state(for: "feat-a"), .init(lifecycle: .approved, url: "u-a"))
    }
    func testApplyMergesWithoutClobberingAbsentFeatures() {
        let store = PRStatusStore()
        store.apply(["a": .init(lifecycle: .open, url: "ua")])
        store.apply(["b": .init(lifecycle: .merged, url: "ub")])   // a not in this snapshot
        XCTAssertEqual(store.state(for: "a")?.lifecycle, .open)     // preserved
        XCTAssertEqual(store.state(for: "b")?.lifecycle, .merged)
    }
    func testUntrackDropsTrackingAndState() {
        let store = PRStatusStore()
        store.track(feature: "a", worktreeURL: URL(fileURLWithPath: "/wt/a"))
        store.apply(["a": .init(lifecycle: .open, url: "u")])
        store.untrack(feature: "a")
        XCTAssertTrue(store.trackedFeatures.isEmpty)
        XCTAssertNil(store.state(for: "a"))
    }
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter PRStatusStoreTests`
  → "cannot find 'PRStatusStore' in scope".
- [ ] Step: Implement — `PRStatusStore.swift`:
```swift
import Foundation

/// The persistent PR-status axis: latest known `PRLifecycle` + url per
/// feature/branch (== `workspace.name`), plus the set of features worth
/// polling. `@Observable`, so a poll pass that mutates `states`
/// re-renders every view that read `state(for:)`. Lives on ProjectSession,
/// fed by `PRStatusPoller`.
@MainActor
@Observable
final class PRStatusStore {
    struct Entry: Equatable, Sendable {
        var lifecycle: PRLifecycle
        var url: String
        init(lifecycle: PRLifecycle, url: String) { self.lifecycle = lifecycle; self.url = url }
    }

    private(set) var states: [String: Entry] = [:]
    private(set) var tracked: [String: URL] = [:]

    /// Register a feature worth polling (idempotent). Only tracked
    /// features are ever fetched — a plan whose branch was never pushed
    /// never hits gh.
    func track(feature: String, worktreeURL: URL) { tracked[feature] = worktreeURL }

    func untrack(feature: String) {
        tracked.removeValue(forKey: feature)
        states.removeValue(forKey: feature)
    }

    func state(for feature: String) -> Entry? { states[feature] }

    var trackedFeatures: [(feature: String, worktreeURL: URL)] {
        tracked.map { (feature: $0.key, worktreeURL: $0.value) }
    }

    /// Merge one poll pass. Absent features are left as-is so a transient
    /// gh miss can't blank a known PR.
    func apply(_ snapshot: [String: Entry]) {
        for (feature, entry) in snapshot { states[feature] = entry }
    }
}
```
- [ ] Step: Run — expect PASS. `swift test --filter PRStatusStoreTests`.
- [ ] Step: Commit — `git add Sources/Dreamux/Models/PRStatusStore.swift
  Tests/DreamuxTests/PRStatusStoreTests.swift && git commit -m
  "PRStatusStore: persistent PR-status axis keyed by feature"`.

---

### Task 5: `PRStatusPoller` — mirrors `ClaudeRegistryPoller`
**Files:** Modify `Sources/Dreamux/Models/PRStatusStore.swift` (add the
poller alongside the store). Test
`Tests/DreamuxTests/PRStatusPollerTests.swift`.
**Interfaces:** Consumes `PRStatusStore.Entry` (Task 4). Produces
`@MainActor final class PRStatusPoller(tracked:fetch:onSnapshot:)` with
`startPolling(interval: TimeInterval = 10)`, `pollOnce() async`,
`stopPolling()`.

- [ ] Step: Write the failing test — `PRStatusPollerTests.swift`:
```swift
import XCTest
@testable import Dreamux

@MainActor
final class PRStatusPollerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable { var features: [String] = [] }

    func testPollOnceFetchesOnlyTrackedAndPublishes() async {
        let rec = Recorder()
        var published: [String: PRStatusStore.Entry] = [:]
        let poller = PRStatusPoller(
            tracked: { [(feature: "feat-a", worktreeURL: URL(fileURLWithPath: "/a"))] },
            fetch: { feature, _ in rec.features.append(feature); return .init(lifecycle: .approved, url: "u-\(feature)") },
            onSnapshot: { published = $0 })
        await poller.pollOnce()
        XCTAssertEqual(rec.features, ["feat-a"])
        XCTAssertEqual(published["feat-a"], .init(lifecycle: .approved, url: "u-feat-a"))
    }

    func testPollOnceWithNothingTrackedNeverFetches() async {
        let rec = Recorder()
        let poller = PRStatusPoller(
            tracked: { [] },
            fetch: { feature, _ in rec.features.append(feature); return nil },
            onSnapshot: { _ in })
        await poller.pollOnce()
        XCTAssertTrue(rec.features.isEmpty)   // non-spammy invariant
    }

    func testPollOnceSkipsFeaturesFetchReturnsNilFor() async {
        var published: [String: PRStatusStore.Entry] = [:]
        let poller = PRStatusPoller(
            tracked: { [(feature: "a", worktreeURL: URL(fileURLWithPath: "/a")),
                        (feature: "b", worktreeURL: URL(fileURLWithPath: "/b"))] },
            fetch: { feature, _ in feature == "a" ? .init(lifecycle: .open, url: "ua") : nil },
            onSnapshot: { published = $0 })
        await poller.pollOnce()
        XCTAssertEqual(Set(published.keys), ["a"])
    }
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter PRStatusPollerTests`
  → "cannot find 'PRStatusPoller' in scope".
- [ ] Step: Implement — append to `PRStatusStore.swift`:
```swift
/// ~10s heartbeat over the tracked PR set — the ClaudeRegistryPoller shape.
/// `tracked` runs on the main actor (reads the store); `fetch` runs off it
/// (gh is network IO); snapshots land back on main. Fetches ONLY tracked
/// features, so an empty tracked set makes zero gh calls.
@MainActor
final class PRStatusPoller {
    private let tracked: @MainActor () -> [(feature: String, worktreeURL: URL)]
    private let fetch: @Sendable (String, URL) async -> PRStatusStore.Entry?
    private let onSnapshot: ([String: PRStatusStore.Entry]) -> Void
    private var poller: Task<Void, Never>?

    init(
        tracked: @escaping @MainActor () -> [(feature: String, worktreeURL: URL)],
        fetch: @escaping @Sendable (String, URL) async -> PRStatusStore.Entry?,
        onSnapshot: @escaping ([String: PRStatusStore.Entry]) -> Void
    ) {
        self.tracked = tracked
        self.fetch = fetch
        self.onSnapshot = onSnapshot
    }

    func startPolling(interval: TimeInterval = 10) {
        guard poller == nil else { return }
        poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() { poller?.cancel(); poller = nil }

    func pollOnce() async {
        let items = tracked()
        guard !items.isEmpty else { return }
        var snapshot: [String: PRStatusStore.Entry] = [:]
        for item in items {
            if let entry = await fetch(item.feature, item.worktreeURL) {
                snapshot[item.feature] = entry
            }
        }
        guard !Task.isCancelled else { return }
        onSnapshot(snapshot)
    }

    deinit { poller?.cancel() }
}
```
- [ ] Step: Run — expect PASS. `swift test --filter PRStatusPollerTests`.
- [ ] Step: Commit — `git add Sources/Dreamux/Models/PRStatusStore.swift
  Tests/DreamuxTests/PRStatusPollerTests.swift && git commit -m
  "PRStatusPoller: non-spammy 10s PR-status heartbeat"`.

---

### Task 6: `FlowsBoard.Lane.prState` seam + `compose` population
**Files:** Modify `Sources/Dreamux/Models/FlowsBoard.swift`. Test
`Tests/DreamuxTests/FlowsBoardTests.swift`.
**Interfaces:** Consumes `PRLaneState` (Task 3). Produces
`FlowsBoard.Lane.prState: PRLaneState?` and the `compose(...,
prStatesByWorkspace: [UUID: PRLaneState] = [:])` parameter.

- [ ] Step: Write the failing test — append to `FlowsBoardTests`:
```swift
func testComposeCarriesPRStateByWorkspace() {
    let wsID = UUID()
    let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: wsID)
    let board = FlowsBoard.compose(
        planLanes: [plan], sessionLanes: [],
        prStatesByWorkspace: [wsID: PRLaneState(lifecycle: .approved, url: "u")])
    let out = board.sections.flatMap(\.lanes).first { $0.id == "plan-p" }
    XCTAssertEqual(out?.prState, PRLaneState(lifecycle: .approved, url: "u"))
}
func testComposeLeavesPRStateNilWhenWorkspaceUntracked() {
    let plan = lane(id: "plan-p", kind: .plan, status: .running, workspaceID: UUID())
    let board = FlowsBoard.compose(planLanes: [plan], sessionLanes: [])
    XCTAssertNil(board.sections.flatMap(\.lanes).first?.prState)
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter FlowsBoardTests`
  → "value of type 'FlowsBoard.Lane' has no member 'prState'".
- [ ] Step: Implement — add `var prState: PRLaneState? = nil` to
  `FlowsBoard.Lane` (after `sessionChip`). Add the parameter to `compose`:
```swift
static func compose(
    planLanes: [Flow], sessionLanes: [Flow],
    prStatesByWorkspace: [UUID: PRLaneState] = [:]
) -> FlowsBoard {
```
  At each of the three `Lane(...)` constructions in `compose` (unmatched
  sessions, extra sessions, plan lanes), add:
  `prState: <flowVar>.workspaceID.flatMap { prStatesByWorkspace[$0] }`
  (using each site's flow — `session` for the session sites, `flow` for the
  plan-lane site).
- [ ] Step: Run — expect PASS. `swift test --filter FlowsBoardTests`
  (new cases + all existing compose cases stay green — the default
  parameter keeps the other three call sites compiling).
- [ ] Step: Commit — `git add Sources/Dreamux/Models/FlowsBoard.swift
  Tests/DreamuxTests/FlowsBoardTests.swift && git commit -m "FlowsBoard:
  carry PR lifecycle on Lane via compose"`.

---

### Task 7: `PRStatusGlyph` + `PRStatusBadge` visual vocabulary
**Files:** Create `Sources/Dreamux/Views/PRStatusGlyph.swift`. Test
`Tests/DreamuxTests/PRLifecycleTests.swift` (append a totality test — pure
mapping).
**Interfaces:** Consumes `PRLifecycle`/`PRLaneState`. Produces
`enum PRStatusGlyph { symbol/color/label(_:) }` and
`struct PRStatusBadge: View`.

- [ ] Step: Write the failing test — append to `PRLifecycleTests`:
```swift
func testEveryLifecycleHasSymbolAndLabel() {
    for s in PRLifecycle.allCases {
        XCTAssertFalse(PRStatusGlyph.symbol(s).isEmpty, "\(s)")
        XCTAssertFalse(PRStatusGlyph.label(s).isEmpty, "\(s)")
    }
}
```
- [ ] Step: Run it — expect FAIL. `swift test --filter PRLifecycleTests`
  → "cannot find 'PRStatusGlyph' in scope".
- [ ] Step: Implement — `PRStatusGlyph.swift`:
```swift
import SwiftUI

/// PR-status visual vocabulary — a SIBLING to `FlowStatusGlyph`. Blocking
/// states red, checks amber, approved/merged green, draft/open/closed
/// secondary.
enum PRStatusGlyph {
    static func symbol(_ s: PRLifecycle) -> String {
        switch s {
        case .draft: return "pencil.circle"
        case .open: return "arrow.triangle.pull"
        case .checksRunning: return "clock.arrow.circlepath"
        case .checksFailed: return "xmark.octagon.fill"
        case .changesRequested: return "arrow.uturn.left.circle.fill"
        case .approved: return "checkmark.seal.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }
    static func color(_ s: PRLifecycle) -> Color {
        switch s {
        case .draft, .open, .closed: return .secondary
        case .checksRunning: return .orange
        case .checksFailed, .changesRequested: return .red
        case .approved, .merged: return .green
        }
    }
    static func label(_ s: PRLifecycle) -> String {
        switch s {
        case .draft: return "Draft"
        case .open: return "PR open"
        case .checksRunning: return "Checks running"
        case .checksFailed: return "Checks failed"
        case .changesRequested: return "Changes requested"
        case .approved: return "Approved"
        case .merged: return "Merged"
        case .closed: return "PR closed"
        }
    }
}

/// Pill badge for a lane's PR state; `onOpen` opens the PR url.
struct PRStatusBadge: View {
    let state: PRLaneState
    var onOpen: (() -> Void)? = nil
    var body: some View {
        let pill = HStack(spacing: 4) {
            Image(systemName: PRStatusGlyph.symbol(state.lifecycle))
                .font(.system(size: 10, weight: .semibold))
            Text(PRStatusGlyph.label(state.lifecycle)).font(.caption)
        }
        .foregroundStyle(PRStatusGlyph.color(state.lifecycle))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(PRStatusGlyph.color(state.lifecycle).opacity(0.12)))
        if let onOpen {
            Button(action: onOpen) { pill }.buttonStyle(.plain).help("Open pull request")
        } else {
            pill
        }
    }
}
```
- [ ] Step: Run — expect PASS. `swift test --filter PRLifecycleTests`.
- [ ] Step: Commit — `git add Sources/Dreamux/Views/PRStatusGlyph.swift
  Tests/DreamuxTests/PRLifecycleTests.swift && git commit -m "PRStatusGlyph:
  PR badge visual vocabulary"`.

---

### Task 8: Wire the poller into `ProjectSession` (track-on-publish, seed, glue map)
**Files:** Modify `Sources/Dreamux/Models/ProjectSession.swift`,
`Sources/Dreamux/Models/MergeFlow.swift`,
`Sources/Dreamux/Views/MergeFeatureSheet.swift`,
`Sources/Dreamux/Views/ContentView.swift`,
`Sources/Dreamux/Views/FlowsOverviewView.swift`,
`Sources/Dreamux/Shell/GitOperations.swift`.
**Interfaces:** Consumes `PRStatusStore`/`PRStatusPoller` (Tasks 4-5),
`GhOperations.prDetail` (Task 3), `FlowsBoard.compose` map (Task 6).
Produces `ProjectSession.prStatus: PRStatusStore`; `MergeFlow`'s
`onPublished: (Repository, String) -> Void` hook;
`GitOperations.hasRemoteBranch(_:in:) async -> Bool`.

- [ ] Step: (Wiring — verified by `swift build` + visual check; the pieces
  it composes are already unit-tested in Tasks 3-6.) Add
  `GitOperations.hasRemoteBranch`:
```swift
/// Offline probe: does `origin/<branch>` exist locally? Used to seed PR
/// tracking without a network round-trip.
static func hasRemoteBranch(_ branch: String, in repoRootURL: URL) async -> Bool {
    (try? await runGit(["rev-parse", "--verify", "--quiet",
                        "refs/remotes/origin/\(branch)"], in: repoRootURL)) != nil
}
```
- [ ] Step: In `MergeFlow`, add `let onPublished: (Repository, String) ->
  Void` (default `{ _, _ in }`, threaded through `init`). In `publish`,
  after `states[repo.name] = .prOpen(url: url)`, call
  `onPublished(repo, url)`. In `MergeFeatureSheet.init`, add
  `onPublished:` param and forward it into `MergeFlow`.
- [ ] Step: In `ProjectSession`, add `let prStatus = PRStatusStore()` and
  `@ObservationIgnored private var prStatusPoller: PRStatusPoller?`. Where
  `registryPoller` is built (~509), build + start the PR poller:
```swift
let prStore = self.prStatus
let prPoller = PRStatusPoller(
    tracked: { [weak prStore] in prStore?.trackedFeatures ?? [] },
    fetch: { feature, worktree in
        guard let d = await GhOperations.prDetail(branch: feature, in: worktree) else { return nil }
        return PRStatusStore.Entry(lifecycle: d.lifecycle, url: d.url)
    },
    onSnapshot: { [weak prStore] snap in prStore?.apply(snap) })
prStatusPoller = prPoller
prPoller.startPolling()
```
  Seed once at start: for each feature workspace `ws`, its first linked repo
  `repo` with a remote where `await GitOperations.hasRemoteBranch(ws.name,
  in: repo.rootURL)`, call `prStatus.track(feature: ws.name, worktreeURL:
  repo.rootURL.appendingPathComponent(ws.name))`. Stop the poller wherever
  `registryPoller` is torn down.
- [ ] Step: In `WorkspaceSidebar`'s `MergeFeatureSheet` presentation
  (~113), pass `onPublished: { repo, url in prStatus.track(feature:
  workspace.name, worktreeURL: repo.rootURL.appendingPathComponent(
  workspace.name)) }` (thread `prStatus` into `WorkspaceSidebar` from
  `ContentView` as `session.prStatus`).
- [ ] Step: In `ContentView`, compute the glue map and hand it to
  `FlowsOverviewView` (add a `prStatesByWorkspace: [UUID: PRLaneState]`
  property):
```swift
private var prStatesByWorkspace: [UUID: PRLaneState] {
    Dictionary(uniqueKeysWithValues: store.workspaces.compactMap { ws in
        session.prStatus.state(for: ws.name).map {
            (ws.id, PRLaneState(lifecycle: $0.lifecycle, url: $0.url))
        }
    })
}
```
  In `FlowsOverviewView.body`, pass it into `FlowsBoard.compose(...,
  prStatesByWorkspace: prStatesByWorkspace)`.
- [ ] Step: Run — `swift build` succeeds; `swift test` stays green. Visual
  check: publish a PR through the gate's "Create PR"; within ~10s the Flows
  lane shows a PR badge; ticking the PR to approved/merged on the remote
  flips the badge without reopening the sheet.
- [ ] Step: Commit — `git add` the six files + commit `"Wire PRStatusPoller
  into ProjectSession: track-on-publish + seed"`.

---

### Task 9: Render the PR badge on the Flows surfaces (gate card + lane header)
**Files:** Modify `Sources/Dreamux/Views/GateActionCard.swift`,
`Sources/Dreamux/Views/FlowLaneView.swift`.
**Interfaces:** Consumes `FlowsBoard.Lane.prState` (Task 6),
`PRStatusBadge` (Task 7).
**Verification:** `swift build` + visual check (view-only wiring — no unit
test).

- [ ] Step: Add `let prState: PRLaneState?` (default nil) to
  `GateActionCard`. When `prState != nil`, render `PRStatusBadge(state:
  prState!, onOpen: { open the url via NSWorkspace })` in the card, and add
  a **"View PR"** button next to the action row. In `FlowLaneView`, pass
  `prState: lane.prState` when constructing `GateActionCard`, and in
  `header` (after the title `Text`) render `if let pr = lane.prState {
  PRStatusBadge(state: pr) }`.
- [ ] Step: Run — `swift build` succeeds. Visual check: a gate with an open
  PR shows the badge + "View PR"; the lane header shows the badge; clicking
  "View PR" opens the PR url.
- [ ] Step: Commit — `git add Sources/Dreamux/Views/GateActionCard.swift
  Sources/Dreamux/Views/FlowLaneView.swift && git commit -m "Gate card +
  Flow lane: render PR badge and View PR"`.

---

### Task 10: Render the PR badge on the sidebar/overview surfaces
**Files:** Modify `Sources/Dreamux/Views/WorkspaceOverviewView.swift`,
`Sources/Dreamux/Views/WorkspaceSidebar.swift`,
`Sources/Dreamux/Views/PlansSpecsSection.swift`,
`Sources/Dreamux/Views/ContentView.swift` (thread the lookup).
**Interfaces:** Consumes `PRStatusStore.state(for:)` (Task 4),
`PRStatusBadge` (Task 7).
**Verification:** `swift build` + visual check (view-only wiring — no unit
test).

- [ ] Step: Thread a `prState(forFeature: String) -> PRLaneState?` lookup
  (backed by `session.prStatus.state(for:)` mapped to `PRLaneState`) into
  `WorkspaceOverviewDependencies`, `WorkspaceSidebar`, and
  `PlansSpecsSection`. Render `PRStatusBadge` at:
  `WorkspaceOverviewView.projectRunRow` (beside the run title, keyed by the
  run's feature); the `WorkspaceSidebar` feature row (beside its status);
  `PlansSpecsSection.planRow` (beside the title / live-flow dot, keyed by
  `featureName(plan)`).
- [ ] Step: Run — `swift build` succeeds. Visual check: a plan/workspace
  with an open PR shows the badge on its overview row, its sidebar row, and
  its plan row; all three update within ~10s as the PR advances.
- [ ] Step: Commit — `git add
  Sources/Dreamux/Views/WorkspaceOverviewView.swift
  Sources/Dreamux/Views/WorkspaceSidebar.swift
  Sources/Dreamux/Views/PlansSpecsSection.swift
  Sources/Dreamux/Views/ContentView.swift && git commit -m "Overview,
  sidebar, plan rows: render PR badge"`.
