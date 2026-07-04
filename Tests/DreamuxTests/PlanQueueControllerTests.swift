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

    /// launch() runs its runPlan effect in an unstructured Task; yield
    /// until the observable consequence lands (bounded, deterministic).
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    func testEnqueuePersistsAndDedupes() {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        XCTAssertEqual(controller.entries, ["docs/plans/a.md", "docs/plans/b.md"])
        let reloaded = PlanQueueController(project: project)
        XCTAssertEqual(reloaded.entries, ["docs/plans/a.md", "docs/plans/b.md"])
    }

    // MARK: - ensureQueued (intake enactment, Task 4)

    func testEnsureQueuedInsertsAfterBlockerMidQueue() {
        controller.enqueue("docs/plans/x.md")
        controller.enqueue("docs/plans/blocker.md")
        controller.enqueue("docs/plans/y.md")
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        XCTAssertEqual(controller.entries,
                       ["docs/plans/x.md", "docs/plans/blocker.md",
                        "docs/plans/new.md", "docs/plans/y.md"])
    }

    func testEnsureQueuedLandsBehindRunningBlocker() async {
        controller.enqueue("docs/plans/blocker.md")
        controller.enqueue("docs/plans/y.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/blocker.md")
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        // The running blocker still holds its queue slot, so the new plan
        // slots immediately behind it — never ahead of it, never enqueuing
        // the blocker a second time.
        XCTAssertEqual(controller.entries,
                       ["docs/plans/blocker.md", "docs/plans/new.md", "docs/plans/y.md"])
    }

    func testEnsureQueuedAppendsWhenBlockerAbsent() {
        controller.enqueue("docs/plans/x.md")
        controller.enqueue("docs/plans/y.md")
        // Blocker is neither queued nor running: never enqueue it
        // implicitly — append and let the caption carry the relationship.
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        XCTAssertEqual(controller.entries,
                       ["docs/plans/x.md", "docs/plans/y.md", "docs/plans/new.md"])
        XCTAssertFalse(controller.entries.contains("docs/plans/blocker.md"),
                       "the blocker is never enqueued as a side effect")
    }

    func testEnsureQueuedIsIdempotent() {
        controller.enqueue("docs/plans/blocker.md")
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        XCTAssertEqual(controller.entries,
                       ["docs/plans/blocker.md", "docs/plans/new.md"],
                       "a second call adds no duplicate")
    }

    func testEnsureQueuedNoOpsWhenPathIsRunning() async {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        // `a.md` is the running plan; enacting it again must not re-add it.
        controller.ensureQueued("docs/plans/a.md", after: "docs/plans/blocker.md")
        XCTAssertEqual(controller.entries, ["docs/plans/a.md"])
    }

    func testEnsureQueuedPersists() {
        controller.enqueue("docs/plans/blocker.md")
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        let reloaded = PlanQueueController(project: project)
        XCTAssertEqual(reloaded.entries,
                       ["docs/plans/blocker.md", "docs/plans/new.md"])
    }

    func testEnactedPairsPersistAndEdgeTriggerAfterReload() {
        controller.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        // The enacted map round-trips, and a reloaded controller treats the
        // same pair as already-enacted: removing the waiter then re-enacting
        // it (the watcher tick) is a no-op — removal sticks across relaunch.
        let reloaded = PlanQueueController(project: project)
        XCTAssertEqual(reloaded.enactedBlockers,
                       ["docs/plans/new.md": "docs/plans/blocker.md"])
        reloaded.remove("docs/plans/new.md")
        reloaded.ensureQueued("docs/plans/new.md", after: "docs/plans/blocker.md")
        XCTAssertTrue(reloaded.entries.isEmpty,
                      "an already-enacted pair does not re-add after a reload")
    }

    func testStartRunsFirstEntry() async {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
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

    func testMergedAtGateAdvancesToNextPlan() async {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        statuses["docs/plans/a.md"] = .awaitingReview
        controller.tick()
        controller.mergeAndContinue()
        XCTAssertEqual(mergeRequests, ["a.md"], "merge requested for the plan's feature")
        statuses["docs/plans/a.md"] = .merged
        controller.tick()
        await settle(until: { ran.count == 2 })
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

    func testSkipAndStopAndResume() async {
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        statuses["docs/plans/a.md"] = .running
        quiescent = true
        controller.tick()
        fakeNow = fakeNow.addingTimeInterval(121)
        controller.tick()
        XCTAssertEqual(controller.state, .attention)

        controller.resumeCurrent()
        await settle(until: { ran.count == 2 })
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

    private struct FakeRunError: Error {}

    func testStaleLaunchFailureDoesNotClobberAdvancedQueue() async {
        var releaseA: CheckedContinuation<Void, Never>?
        controller.runPlan = { [weak self] path in
            self?.ran.append(path)
            if path == "docs/plans/a.md" {
                // Suspend (rather than busy-spin) until the test releases us,
                // so a.md's completion lands strictly after skipCurrent().
                await withCheckedContinuation { releaseA = $0 }
                throw FakeRunError()
            }
        }
        controller.enqueue("docs/plans/a.md")
        controller.enqueue("docs/plans/b.md")
        controller.start()
        await settle(until: { releaseA != nil })  // a.md's launch is in flight, parked on the continuation
        controller.skipCurrent()         // advances the queue to b.md while a.md is still running
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/b.md")
        releaseA?.resume()
        await settle(until: { ran.count == 2 })   // let a.md's now-stale throw complete, and b.md's launch land
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(controller.currentPlanPath, "docs/plans/b.md")
        XCTAssertNil(controller.lastError)
    }

    func testRelaunchMidRunFlipsToAttention() async {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        statuses["docs/plans/a.md"] = .inProgress
        controller.tick()
        XCTAssertEqual(controller.state, .attention)
    }

    func testRecordLossFlipsToAttention() async {
        controller.enqueue("docs/plans/a.md")
        controller.start()
        await settle(until: { !ran.isEmpty })
        // `!ran.isEmpty` only proves runPlan was entered. runPlan is a
        // plain (non-MainActor-isolated) closure value, so the call hops
        // off MainActor to invoke it and back on to run the launch Task's
        // post-await tail (clearing launchInFlight, starting the poller) —
        // that resumed continuation can land a beat after the closure body
        // itself runs. Give it a few more turns so this test observes the
        // launch as fully settled, not still mid-flight.
        await settleLaunchTail()
        statuses["docs/plans/a.md"] = .ready
        controller.tick()
        XCTAssertEqual(controller.state, .attention)
        XCTAssertNotNil(controller.lastError)
    }

    /// Extra scheduling turns beyond `settle`'s condition-based wait, for
    /// spots that depend on a launch Task's post-`await runPlan` tail
    /// (clearing `launchInFlight`, calling `startPolling()`) having fully
    /// executed rather than merely having been entered.
    private func settleLaunchTail() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testEnqueueRejectsEmptyPath() {
        controller.enqueue("")
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testInFlightLaunchIsNotRecordLoss() async {
        var releaseA: CheckedContinuation<Void, Never>?
        controller.runPlan = { [weak self] path in
            self?.ran.append(path)
            if path == "docs/plans/a.md" {
                // Suspend (rather than busy-spin) until the test releases us,
                // so the ledger record for a.md still hasn't been written
                // when the poller ticks below — this is the launch window
                // between runPlan starting and the worktree/ledger write.
                await withCheckedContinuation { releaseA = $0 }
                self?.ran.append("a-resumed")
            }
        }
        controller.enqueue("docs/plans/a.md")
        controller.start()
        await settle(until: { releaseA != nil })  // a.md's launch is in flight, parked before the ledger write

        statuses["docs/plans/a.md"] = .ready      // no record yet, but the launch hasn't failed
        controller.tick()
        XCTAssertEqual(controller.state, .running,
                        "an in-flight launch must not be flagged as record loss")
        XCTAssertNil(controller.lastError)

        releaseA?.resume()
        await settle(until: { ran.contains("a-resumed") })  // launch completes, launchInFlight clears

        statuses["docs/plans/a.md"] = .running
        controller.tick()
        XCTAssertEqual(controller.state, .running)
    }
}
