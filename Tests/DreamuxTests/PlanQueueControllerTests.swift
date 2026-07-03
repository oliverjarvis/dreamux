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
        statuses["docs/plans/a.md"] = .ready
        controller.tick()
        XCTAssertEqual(controller.state, .attention)
        XCTAssertNotNil(controller.lastError)
    }

    func testEnqueueRejectsEmptyPath() {
        controller.enqueue("")
        XCTAssertTrue(controller.entries.isEmpty)
    }
}
