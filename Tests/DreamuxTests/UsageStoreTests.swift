import XCTest
@testable import Dreamux

/// Persistence, last-writer-wins ingestion, and the menu bar
/// preference. Every store here is built with the injectable init: a
/// sandboxed file, its own defaults suite, and no timer — nothing
/// touches real Application Support or the user's defaults.
@MainActor
final class UsageStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let now = Date(timeIntervalSince1970: 1_785_931_200)

    override func setUpWithError() throws {
        sandbox = try TestSandbox()
        suiteName = "UsageStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        sandbox.destroy()
        sandbox = nil
    }

    private var fileURL: URL { sandbox.root.appendingPathComponent("usage.json") }

    private func makeStore() -> UsageStore {
        UsageStore(fileURL: fileURL, defaults: defaults, now: now, startTicking: false)
    }

    private func snapshot(percent: Double, observedOffset: TimeInterval) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: .init(usedPercentage: percent, resetsAt: now.addingTimeInterval(600)),
            sevenDay: nil,
            observedAt: now.addingTimeInterval(observedOffset)
        )
    }

    func testStartsEmptyWhenNoReadingHasEverArrived() {
        XCTAssertNil(makeStore().snapshot)
    }

    func testPersistsAndReloadsAcrossInstances() {
        let store = makeStore()
        store.ingest(snapshot(percent: 41.2, observedOffset: -60))
        // A fresh instance over the same file is a cold start.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.snapshot?.fiveHour?.usedPercentage, 41.2)
        XCTAssertEqual(reloaded.snapshot?.observedAt, now.addingTimeInterval(-60))
    }

    func testNewerReadingWins() {
        let store = makeStore()
        store.ingest(snapshot(percent: 41.2, observedOffset: -600))
        store.ingest(snapshot(percent: 55.0, observedOffset: -60))
        XCTAssertEqual(store.snapshot?.fiveHour?.usedPercentage, 55.0)
    }

    func testAnOlderReadingArrivingSecondIsDropped() {
        // Several sessions report concurrently; a late-arriving but
        // earlier-observed reading must not overwrite a newer one.
        let store = makeStore()
        store.ingest(snapshot(percent: 55.0, observedOffset: -60))
        store.ingest(snapshot(percent: 41.2, observedOffset: -600))
        XCTAssertEqual(store.snapshot?.fiveHour?.usedPercentage, 55.0)
    }

    func testDroppedReadingIsNotPersistedEither() {
        let store = makeStore()
        store.ingest(snapshot(percent: 55.0, observedOffset: -60))
        store.ingest(snapshot(percent: 41.2, observedOffset: -600))
        XCTAssertEqual(makeStore().snapshot?.fiveHour?.usedPercentage, 55.0)
    }

    func testTickAdvancesTheRenderedMoment() {
        let store = makeStore()
        XCTAssertEqual(store.now, now)
        store.tick(to: now.addingTimeInterval(60))
        XCTAssertEqual(store.now, now.addingTimeInterval(60))
    }

    func testMenuBarIsVisibleByDefault() {
        XCTAssertTrue(makeStore().menuBarVisible)
    }

    func testMenuBarPreferencePersists() {
        let store = makeStore()
        store.menuBarVisible = false
        XCTAssertFalse(makeStore().menuBarVisible, "hiding must survive relaunch")

        let restoring = makeStore()
        restoring.menuBarVisible = true
        XCTAssertTrue(makeStore().menuBarVisible, "and it must be restorable from the footer")
    }

    func testAnUnavailableFileDegradesToMemoryOnly() {
        // No path (App Support unreachable) — the store still works, it
        // just doesn't survive relaunch.
        let store = UsageStore(fileURL: nil, defaults: defaults, now: now, startTicking: false)
        store.ingest(snapshot(percent: 41.2, observedOffset: 0))
        XCTAssertEqual(store.snapshot?.fiveHour?.usedPercentage, 41.2)
    }
}
